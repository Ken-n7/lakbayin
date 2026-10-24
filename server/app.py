"""Lakbayin's single-process authoritative HTTP/WebSocket server.

SQLite owns accounts, hashed sessions and atomic match checkpoints. The legacy
REST/Phoenix envelope keeps existing Godot game code independent of hosting.
There are no outgoing Supabase requests or email services.
"""
import asyncio
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import secrets
import sqlite3
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from uuid import uuid4

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

ROOT = Path(__file__).resolve().parents[1]
TOPIC = "realtime:numxventure"  # Existing client's protocol identifier.
WORDS = json.loads((ROOT / "game/data/words.json").read_text())
HASHER = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1)
DUMMY = HASHER.hash(secrets.token_hex(24))
CODES = "ACDEFHJKMNPQRTUWXY23456789"
# A custom room's third side: a member whose team is this watches the match
# from above and never plays -- no answers, no results, no records.
SPECTATE = "spectate"
# The two sides, in Filipino: Bughaw (blue, the native word over Spanish
# "asul") and Pula (red). The client's Match.NAMES says the same.
TEAM_NAMES = ("Bughaw", "Pula")
# Spectators see the match this many seconds late, as in MOBAs (Dota 2: 120 s,
# LoL: 180 s, for 30-40 min games), so nobody watching can call positions to
# a player. Scaled to a 15-minute match. Enforced here, not in the client.
SPECTATOR_DELAY_S = float(os.environ.get("LAKBAYIN_SPECTATOR_DELAY_S", 60))


def stamp(value=None):
    return datetime.fromtimestamp(time.time() if value is None else value, timezone.utc).isoformat()


def uid():
    return str(uuid4())


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def require(ok, message="Forbidden", code=403):
    if not ok:
        raise HTTPException(code, message)


class Store:
    def __init__(self, filename):
        path = Path(filename)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
          pragma journal_mode=WAL;
          pragma foreign_keys=ON;
          create table if not exists users (
            id text primary key, username text not null unique collate nocase,
            password text not null);
          create table if not exists tokens (
            hash text primary key, user_id text not null references users(id), expires real not null);
          create table if not exists checkpoint (id integer primary key check(id=1), data text not null);
          create table if not exists matches (id text primary key, data text not null);
        """)
        self.db.execute("insert or ignore into checkpoint values(1,?)", (json.dumps({"sessions": {}, "config": {"id": 1, "team_size": 1, "duration_s": 900, "monks": 10, "search_s": 90}}),))
        self.db.commit()
        self.cache, self.version = None, None

    def load(self):
        # The parsed checkpoint stays in memory; data_version only changes when
        # another connection (manage.py, a test) commits, so reparse just then.
        # Callers must not mutate the result outside commit().
        version = self.db.execute("pragma data_version").fetchone()[0]
        if self.cache is None or version != self.version:
            self.cache = json.loads(self.db.execute("select data from checkpoint where id=1").fetchone()[0])
            self.version = version
        return self.cache

    def save(self, state):
        self.db.execute("update checkpoint set data=? where id=1", (json.dumps(state),))
        self.db.commit()
        self.cache = state

    def archive(self, s):
        # Joins the caller's open transaction; save() commits both together.
        self.db.execute("insert or replace into matches values(?,?)", (s["id"], json.dumps(s)))

    def archived(self, sid):
        row = self.db.execute("select data from matches where id=?", (sid,)).fetchone() if isinstance(sid, str) else None
        return json.loads(row[0]) if row else None

    def archives(self):
        # ponytail: parses every finished match per Records request; keep a
        # per-player results table if Records gets slow.
        return (json.loads(d) for (d,) in self.db.execute("select data from matches"))

    def user(self, token):
        require(isinstance(token, str) and len(token) <= 512, "Sign in again", 401)
        row = self.db.execute("select u.* from users u join tokens t on t.user_id=u.id where t.hash=? and t.expires>?", (digest(token), time.time())).fetchone()
        require(row is not None, "Sign in again", 401)
        return dict(row)

    def profile(self, who):
        row = self.db.execute("select id,username from users where id=?", (who,)).fetchone()
        return {**dict(row), "role": "player"} if row else {}

    def session(self, who):
        token = secrets.token_urlsafe(32)
        self.db.execute("delete from tokens where expires<=?", (time.time(),))
        self.db.execute("insert into tokens values(?,?,?)", (digest(token), who, time.time() + 30 * 86400))
        self.db.commit()
        return {"access_token": token, "refresh_token": token, "user": {"id": who}}


def public_session(s):
    # `matchmade` was a Supabase column the client still branches on: without
    # it a Find Match lobby looked like a custom room and polled poll_room,
    # which rejects it, so the player silently fell out of the queue.
    return {**{k: v for k, v in s.items() if k not in ("members", "teams", "words", "answers", "locks", "watchers", "deadline", "ended_ts")}, "admin_id": s.get("owner_id"), "matchmade": not s.get("custom", True)}


def find(store, state, sid):
    """A live session, or a finished one already moved to the archive."""
    return state["sessions"].get(sid) or store.archived(sid)


def member(s, who):
    return s["members"].get(who)


def plays(s, who):
    """A member on a side -- not a spectator, not a visitor with the code."""
    m = s["members"].get(who)
    return m is not None and m["team_id"] not in (None, SPECTATE)


def may_read(s, who):
    return who in s["members"] or s["watchers"].get(who, 0) > time.time()


def standings(s):
    out = []
    for t in s["teams"]:
        answers = [a for a in s["answers"] if a["team_id"] == t["id"]]
        deposited = [a for a in answers if a["deposited_at"] is not None]
        out.append({**t, "team_id": t["id"], "deposited": len(deposited), "carried": len(answers) - len(deposited), "reached_at": max((a["deposited_at"] for a in deposited), default=None), "finished": len(deposited) == len(s["words"])})
    return out


def player_standings(store, s, spectators=False):
    out = []
    for who, m in s["members"].items():
        if m["team_id"] == SPECTATE and not spectators:
            continue
        aa = [a for a in s["answers"] if a["profile_id"] == who]
        dd = [a for a in aa if a["deposited_at"] is not None]
        out.append({**m, "username": store.profile(who)["username"], "deposited": len(dd), "carried": len(aa) - len(dd), "reached_at": max((a["deposited_at"] for a in dd), default=None)})
    return out


def rank_key(p):
    return (-p["deposited"], p["reached_at"] or "9999")


def finish(s):
    if s["state"] != "running":
        return
    teams = sorted(standings(s), key=rank_key)
    if teams[0]["finished"] or s["deadline"] <= time.time():
        s["state"] = "ended"
        s["completed_at"] = stamp(min(time.time(), s["deadline"]))
        s["winner_team"] = teams[0]["id"] if rank_key(teams[0]) != rank_key(teams[1]) else None


def cleanup(s):
    finish(s)
    if s["state"] != "lobby":
        return
    now = time.time()
    ttl = 30 if s["custom"] else 15
    for who, m in list(s["members"].items()):
        if m["seen"] < now - ttl or (not s["custom"] and now - m["joined"] >= s["search_s"]):
            del s["members"][who]
    if s["owner_id"] not in s["members"]:
        s["owner_id"] = next(iter(s["members"]), None)
    if not s["members"]:
        s["state"] = "ended"


def start(s):
    require(s["state"] == "lobby", "Room already started")
    require(all(any(m["team_id"] == t["id"] for m in s["members"].values()) for t in s["teams"]), "Both sides need a player")
    require(all(m["team_id"] for m in s["members"].values()), "Pick a side first")
    s.update(state="running", starts_at=stamp(), ends_at=stamp(time.time() + s["duration_s"]), deadline=time.time() + s["duration_s"])


def add_member(s, who, team=None):
    s["members"].setdefault(who, {"session_id": s["id"], "profile_id": who, "team_id": team, "joined": time.time(), "seen": time.time()})


def make_session(state, who, custom):
    cfg = state["config"]
    code = "".join(secrets.choice(CODES) for _ in range(4))
    while any(s["code"] == code and s["state"] != "ended" for s in state["sessions"].values()):
        code = "".join(secrets.choice(CODES) for _ in range(4))
    sid = uid()
    s = {"id": sid, "code": code, "owner_id": who, "custom": custom, "state": "lobby", "created_at": stamp(), "starts_at": None, "ends_at": None, "winner_team": None, "duration_s": cfg["duration_s"], "search_s": cfg["search_s"], "team_size": cfg["team_size"], "monk_count": cfg["monks"], "hints": False, "members": {}, "teams": [{"id": uid(), "session_id": sid, "name": n} for n in TEAM_NAMES], "words": random.SystemRandom().sample(WORDS, cfg["monks"]), "answers": [], "locks": {}, "watchers": {}}
    add_member(s, who, s["teams"][0]["id"])
    state["sessions"][sid] = s
    return s


def snapshot(store, s):
    return {"session": {**public_session(s), "server_now": stamp()}, "monks": len(s["words"]), "teams": standings(s), "players": player_standings(store, s), "answers": [{**a, "deposited": a["deposited_at"] is not None} for a in s["answers"]]}


def rpc(store, state, who, name, body):
    sessions = state["sessions"]
    if name in ("my_matches", "player_board", "my_summary"):
        history, board = [], {}
        for s in [*sessions.values(), *store.archives()]:
            if s["state"] != "ended" or not s.get("starts_at"):
                continue
            ranked = sorted(player_standings(store, s), key=rank_key)
            for i, p in enumerate(ranked):
                place = next(j + 1 for j, q in enumerate(ranked) if rank_key(q) == rank_key(p))
                result = "draw" if not s["winner_team"] else "win" if s["winner_team"] == p["team_id"] else "loss"
                if p["profile_id"] == who:
                    history.append({**p, "place": place, "result": result, "custom": s["custom"], "code": s["code"], "completed_at": s["completed_at"], "session_id": s["id"]})
                if not s["custom"]:
                    row = board.setdefault(p["profile_id"], {"profile_id": p["profile_id"], "username": p["username"], "wins": 0, "deposited": 0, "played": 0})
                    row["wins"] += result == "win"
                    row["deposited"] += p["deposited"]
                    row["played"] += 1
        if name == "my_summary":
            # The profile strip over My Matches: every completed game, custom too.
            return {"played": len(history), "wins": sum(h["result"] == "win" for h in history),
                    "draws": sum(h["result"] == "draw" for h in history),
                    "deposited": sum(h["deposited"] for h in history)}
        rows = sorted(history, key=lambda x: x["completed_at"], reverse=True) if name == "my_matches" else sorted(board.values(), key=lambda x: (-x["wins"], -x["deposited"], x["username"]))
        if name == "player_board":
            for i, row in enumerate(rows):
                row["place"] = next(j + 1 for j, q in enumerate(rows) if (q["wins"], q["deposited"]) == (row["wins"], row["deposited"]))
        offset = max(0, min(int(body.get("p_offset", 0)), 100000))
        return rows[offset:offset + 21]
    if name == "create_room":
        return public_session(make_session(state, who, True))
    if name == "find_match":
        for s in sessions.values():
            if not s["custom"] and member(s, who) and s["state"] in ("lobby", "running"):
                s["members"][who]["seen"] = time.time()
                return public_session(s)
        s = next((s for s in sessions.values() if not s["custom"] and s["state"] == "lobby" and len(s["members"]) < 2 * s["team_size"]), None)
        if s is None:
            s = make_session(state, who, False)
        else:
            team = min(s["teams"], key=lambda t: sum(m["team_id"] == t["id"] for m in s["members"].values()))
            add_member(s, who, team["id"])
        if len(s["members"]) == 2 * s["team_size"]:
            start(s)
        return public_session(s)
    if name == "watch_match":
        code = str(body.get("p_code", "")).upper()
        s = next((s for s in reversed(list(sessions.values())) if s["code"] == code and s["custom"] and s["state"] != "ended"), None)
        require(s, "No live room with that code", 404)
        require(not member(s, who) or member(s, who)["team_id"] == SPECTATE, "Players cannot watch their own match")
        s["watchers"][who] = time.time() + 30
        return s["id"]
    s = find(store, state, body.get("p_session"))
    require(s, "No such session", 404)
    if name in ("watch_snapshot", "leave_watch"):
        require(s["watchers"].get(who, 0) > time.time(), "watch expired")
        if name == "leave_watch":
            s["watchers"].pop(who, None)
            return None
        s["watchers"][who] = time.time() + 30
        return snapshot(store, s)
    m = member(s, who)
    if name == "poll_match" and not m:
        return {"session": public_session(s), "queued": False, "waited_s": s["search_s"], "search_s": s["search_s"], "players": len(s["members"]), "needed": s["team_size"] * 2}
    if name == "poll_room" and not m:
        return {"member": False}
    require(m, "Not a member")
    if name in ("poll_match", "poll_room"):
        m["seen"] = time.time()
        if name == "poll_room":
            require(s["custom"], "Not a custom room")
            return {"member": True, "session": public_session(s), "roster": player_standings(store, s, spectators=True)}
        return {"session": public_session(s), "queued": True, "waited_s": int(time.time() - m["joined"]), "search_s": s["search_s"], "players": len(s["members"]), "needed": s["team_size"] * 2}
    if name in ("leave_match", "leave_room"):
        if s["state"] == "lobby":
            del s["members"][who]
            cleanup(s)
        return None
    if name in ("start_room", "move_room_member", "shuffle_room", "set_room_hints"):
        require(s["custom"] and s["owner_id"] == who and s["state"] == "lobby", "Only the host can change this lobby")
        if name == "start_room":
            start(s)
        elif name == "set_room_hints":
            # The Latin syllable under each key, for everyone in the room's match.
            require(type(body.get("p_hints")) is bool, "Hints are on or off", 400)
            s["hints"] = body["p_hints"]
        elif name == "move_room_member":
            target = s["members"].get(body.get("p_profile"))
            require(target and body.get("p_team") in [t["id"] for t in s["teams"]], "Invalid member or side", 400)
            target["team_id"] = body["p_team"]
        else:
            players = [m for m in s["members"].values() if m["team_id"] != SPECTATE]
            random.SystemRandom().shuffle(players)
            for i, player in enumerate(players):
                player["team_id"] = s["teams"][i % 2]["id"]
        return None
    require(s["state"] == "running" and m["team_id"], "Match is not running")
    require(m["team_id"] != SPECTATE, "Spectators only watch")
    if name == "answer_monk":
        index = body.get("p_monk")
        require(type(index) is int and 0 <= index < len(s["words"]), "Invalid monk", 400)
        if any(a["team_id"] == m["team_id"] and a["monk"] == index for a in s["answers"]):
            return "taken"
        key = f"{who}:{index}"
        if s["locks"].get(key, 0) > time.time():
            return "locked"
        typed = str(body.get("p_typed", "")).strip().replace("᜕", "᜔")
        w = s["words"][index]
        if typed not in (w["modern"], w["traditional"]):
            s["locks"][key] = time.time() + 10
            return "wrong"
        s["answers"].append({"session_id": s["id"], "team_id": m["team_id"], "profile_id": who, "monk": index, "answered_at": stamp(), "deposited_at": None})
        return "correct"
    if name == "deposit":
        count, now = 0, stamp()
        for a in s["answers"]:
            if a["profile_id"] == who and a["deposited_at"] is None:
                a["deposited_at"] = now
                count += 1
        finish(s)
        return count
    raise HTTPException(404, "Unknown operation")


def read_rows(store, state, who, table, params):
    if table == "profiles":
        return [store.profile(who)]
    if table == "session_relays":
        return []
    if table == "relay":
        return [{"id": 1, "url": None, "hz": 20}]
    if table == "match_config":
        return [state["config"]]
    sid = params.get("session_id", params.get("id", "")).removeprefix("eq.")
    if table == "sessions":
        rows, pool = [], list(state["sessions"].values())
        if sid and sid not in state["sessions"]:
            pool += filter(None, [store.archived(sid)])
        for s in reversed(pool):
            if sid and s["id"] != sid:
                continue
            if "code" in params and s["code"] != params["code"].removeprefix("eq."):
                continue
            if params.get("custom") == "is.true" and not s["custom"]:
                continue
            if not may_read(s, who) and not (s["custom"] and "code" in params):
                continue
            row = public_session(s)
            if "teams" in params.get("select", ""):
                row["teams"] = s["teams"]
                row["members"] = [{**m, "profiles": store.profile(pid)} for pid, m in s["members"].items()]
            rows.append(row)
        return rows
    s = find(store, state, sid)
    require(s, "No such session", 404)
    require(may_read(s, who), "Not a member or viewer")
    if table == "teams":
        return s["teams"]
    if table == "members":
        return [{**m, "profiles": store.profile(pid)} for pid, m in s["members"].items() if "profile_id" not in params or pid == params["profile_id"].removeprefix("eq.")]
    if table == "session_words":
        ended = s["state"] == "ended"
        return [{"monk": i, "words": {k: v for k, v in w.items() if ended or k not in ("modern", "traditional")}} for i, w in enumerate(s["words"])]
    # Watching is the delayed feed (watch_snapshot); the live tables are the
    # players' while the match is on.
    if table in ("monk_answers", "team_standings", "player_standings"):
        require(s["state"] != "running" or plays(s, who), "Spectators see the delayed feed")
    if table == "monk_answers":
        return s["answers"]
    if table == "team_standings":
        return standings(s)
    if table == "player_standings":
        return player_standings(store, s)
    raise HTTPException(404, "Unknown table")


def write_rows(state, who, method, table, params, body):
    require(table == "members", "Direct writes are disabled")
    sid = body.get("session_id") if method == "POST" else params.get("session_id", "").removeprefix("eq.")
    s = state["sessions"].get(sid)
    require(s and s["custom"], "No custom room", 404)
    target = body.get("profile_id", who) if method == "POST" else params.get("profile_id", "").removeprefix("eq.")
    require(target == who, "Cannot change another player")
    if method == "POST":
        require(set(body) <= {"session_id", "profile_id"}, "Invalid fields", 400)
        if member(s, who):
            return []
        require(s["state"] == "lobby" and len(s["members"]) < 10, "Room full or already started")
        add_member(s, who)
    elif method == "PATCH":
        require(s["state"] == "lobby" and member(s, who), "Cannot change sides now")
        require(set(body) == {"team_id"} and body["team_id"] in [t["id"] for t in s["teams"]] + [SPECTATE], "Invalid side", 400)
        s["members"][who]["team_id"] = body["team_id"]
    else:
        raise HTTPException(405, "Unsupported method")
    return [s["members"][who]]


class Hub:
    def __init__(self, store):
        self.store = store
        self.peers = {}

    async def send(self, ws, topic, event, payload, ref=None):
        # Queue only: callers may hold the commit lock, so one slow phone must
        # never stall everyone. Each socket's writer() drains its own queue in
        # order; a peer that falls 256 messages behind is dropped.
        peer = self.peers.get(ws)
        if peer is None:
            return
        try:
            peer["out"].put_nowait({"topic": topic, "event": event, "payload": payload, "ref": ref})
        except asyncio.QueueFull:
            self.peers.pop(ws, None)
            peer["writer"].cancel()
            asyncio.create_task(self.close(ws))

    async def close(self, ws):
        try:
            await asyncio.wait_for(ws.close(code=1013), 2)
        except (RuntimeError, OSError, WebSocketDisconnect, asyncio.TimeoutError):
            pass

    async def writer(self, ws, out):
        try:
            while True:
                await ws.send_json(await out.get())
        except (RuntimeError, OSError, WebSocketDisconnect):
            self.peers.pop(ws, None)

    async def presence(self):
        # Group once (O(peers), not O(peers²)), then send each peer its own
        # session's roster only when it differs from what it last received.
        state = self.store.load()
        groups = defaultdict(dict)
        for p in self.peers.values():
            meta = p.get("meta", {})
            if meta:
                groups[meta.get("sid")].setdefault(p["who"], {"metas": []})["metas"].append({**meta, "phx_ref": p["ref"]})
        for ws, peer in list(self.peers.items()):
            if TOPIC not in peer["topics"]:
                continue
            sid = peer.get("meta", {}).get("sid")
            s = state["sessions"].get(sid)
            live = s and s["state"] == "running" and not plays(s, peer["who"])
            people = groups.get(sid, {}) if s and may_read(s, peer["who"]) and not live else {}
            if peer.get("presence") != people:
                peer["presence"] = people
                await self.send(ws, TOPIC, "presence_state", people)

    async def changes(self, before, after):
        # Diff committed checkpoints. Only authenticated session participants
        # receive rows, and only the tables/filters they subscribed to.
        for sid, s in after["sessions"].items():
            old = before["sessions"].get(sid, {})
            events = []
            if public_session(s) != public_session(old):
                events.append(("sessions", "UPDATE", public_session(s)))
            for who, m in s["members"].items():
                if m != old.get("members", {}).get(who):
                    events.append(("members", "UPDATE", {**m, "username": self.store.profile(who)["username"]}))
            for who, m in old.get("members", {}).items():
                if who not in s["members"]:
                    events.append(("members", "DELETE", m))
            for a in s["answers"]:
                prev = next((b for b in old.get("answers", []) if (b["team_id"], b["monk"]) == (a["team_id"], a["monk"])), None)
                if prev != a:
                    events.append(("monk_answers", "UPDATE" if prev else "INSERT", a))
            during = s["state"] != "lobby" and old.get("state", "lobby") != "lobby"
            for ws, peer in list(self.peers.items()):
                if not may_read(s, peer["who"]) or (during and not plays(s, peer["who"])):
                    continue
                for table, kind, row in events:
                    for watch in peer["topics"].get(TOPIC, {}).get("postgres_changes", []):
                        expected = ("id" if table == "sessions" else "session_id") + "=eq." + sid
                        if watch.get("table") == table and watch.get("filter", "") in ("", expected) and watch.get("event", "*") in ("*", kind):
                            await self.send(ws, TOPIC, "postgres_changes", {"data": {"table": table, "type": kind, "record": row, "old_record": row}})
                            break


def create_app(db_path=None):
    store = Store(db_path or os.environ.get("LAKBAYIN_DB", ROOT / "server/data/lakbayin.sqlite3"))
    hub = Hub(store)
    lock = asyncio.Lock()
    attempts = defaultdict(deque)
    # sid -> [(time, snapshot)] while a match runs: the delayed feed's past.
    history = defaultdict(deque)

    def record(before, state):
        now = time.time()
        for sid, s in state["sessions"].items():
            if s["state"] != "lobby" and s != before["sessions"].get(sid):
                history[sid].append((now, snapshot(store, s)))

    def delayed(live):
        """The watch snapshot as it was SPECTATOR_DELAY_S ago."""
        session = live["session"]
        if session["state"] == "lobby":
            return live
        past = history[session["id"]]
        if not past:                 # e.g. after a server restart: start the clock now
            past.append((time.time(), live))
        cutoff = time.time() - SPECTATOR_DELAY_S
        seen = [snap for t, snap in past if t <= cutoff]
        if seen:
            out = {**seen[-1], "delay_s": SPECTATOR_DELAY_S}
        else:
            # Not yet SPECTATOR_DELAY_S into it: the start, still to come here.
            first_t, first = past[0]
            out = copy.deepcopy(first)
            out["session"].update(state="lobby", server_now=stamp(cutoff))
            out.update(answers=[], delay_s=SPECTATOR_DELAY_S, starts_in=int(first_t - cutoff) + 1)
        return out

    def prune_history():
        cutoff = time.time() - SPECTATOR_DELAY_S
        for sid in list(history):
            past = history[sid]
            while len(past) > 1 and past[1][0] <= cutoff:
                past.popleft()
            if past and past[-1][0] < cutoff - 120:
                del history[sid]

    def limited(key, limit):
        queue = attempts[key]
        while queue and queue[0] < time.time() - 60:
            queue.popleft()
        return len(queue) >= limit

    async def commit(operation):
        async with lock:
            store.db.execute("begin immediate")
            try:
                before = store.load()
                state = copy.deepcopy(before)
                now = time.time()
                for sid, s in list(state["sessions"].items()):
                    cleanup(s)
                    # Finished matches leave the live checkpoint after 10
                    # minutes (Results has fetched by then), so per-request
                    # work stays proportional to live matches, not history.
                    if s["state"] == "ended" and s.setdefault("ended_ts", now) < now - 600:
                        store.archive(state["sessions"].pop(sid))
                result = operation(state)
                if state != before:
                    store.save(state)
                    record(before, state)
                else:
                    store.db.rollback()
            except Exception:
                store.db.rollback()
                raise
            if state != before:
                await hub.changes(before, state)
            return result

    async def ticker():
        while True:
            await asyncio.sleep(1)
            await commit(lambda state: None)
            for key in [k for k, q in attempts.items() if not q or q[-1] < time.time() - 60]:
                del attempts[key]
            prune_history()

    @asynccontextmanager
    async def lifespan(app):
        task = asyncio.create_task(ticker())
        yield
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        store.db.close()

    app = FastAPI(title="Lakbayin server", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.store = store

    @app.exception_handler(HTTPException)
    async def error(request, exc):
        return JSONResponse({"message": str(exc.detail)}, status_code=exc.status_code)

    @app.exception_handler(ValueError)
    async def invalid_value(request, exc):
        return JSONResponse({"message": "Invalid request"}, status_code=400)

    @app.get("/health")
    def health():
        try:
            store.db.execute("select 1 from checkpoint").fetchone()
        except sqlite3.Error:
            return JSONResponse({"ok": False, "server": "lakbayin"}, status_code=503)
        return {"ok": True, "server": "lakbayin"}

    @app.middleware("http")
    async def size_limit(request, call_next):
        if len(await request.body()) > 16384:
            return JSONResponse({"message": "Request too large"}, status_code=413)
        return await call_next(request)

    def bearer(request):
        return request.headers.get("authorization", "").removeprefix("Bearer ")

    @app.post("/auth/register")
    @app.post("/auth/login")
    async def auth(request: Request):
        # client.host is the player's address: uvicorn takes it from the
        # X-Forwarded-For that Cloudflare sets, trusting it only from loopback
        # (the tunnel). A classroom shares one address, so the per-address cap
        # is generous; guessing is capped per address and username.
        ip = request.client.host
        require(not limited(ip, 200), "Too many attempts. Try again in a minute.", 429)
        attempts[ip].append(time.time())
        body = await request.json()
        require(isinstance(body, dict), "Invalid form", 400)
        username, password = body.get("username", ""), body.get("password", "")
        require(isinstance(username, str) and isinstance(password, str) and len(password) <= 256, "Invalid credentials", 400)
        username = username.strip()
        guess = (ip, username.lower())
        require(not limited(guess, 10), "Too many attempts. Try again in a minute.", 429)
        if request.url.path == "/auth/register":
            require(re.fullmatch(r"[A-Za-z0-9_-]{3,20}", username) and len(password) >= 8, "Username: 3–20 letters/digits/_/-. Password: 8–256 characters.", 400)
            hashed = await asyncio.to_thread(HASHER.hash, password)
            who = uid()
            try:
                store.db.execute("insert into users values(?,?,?)", (who, username, hashed))
                store.db.commit()
            except sqlite3.IntegrityError:
                store.db.rollback()
                raise HTTPException(409, "Username already taken")
        else:
            row = store.db.execute("select * from users where username=? collate nocase", (username,)).fetchone()
            try:
                valid = await asyncio.to_thread(HASHER.verify, row["password"] if row else DUMMY, password)
            except (VerificationError, InvalidHashError):
                valid = False
            if not (row and valid):
                attempts[guess].append(time.time())
            require(row and valid, "Invalid login credentials", 401)
            who = row["id"]
        return store.session(who)

    @app.post("/auth/restore")
    async def restore(request: Request):
        body = await request.json()
        token = body.get("refresh_token", "")
        who = store.user(token)["id"]
        return {"access_token": token, "refresh_token": token, "user": {"id": who}}

    @app.post("/auth/logout")
    async def logout(request: Request):
        store.db.execute("delete from tokens where hash=?", (digest(bearer(request)),))
        store.db.commit()
        return None

    @app.api_route("/rest/v1/{path:path}", methods=["GET", "POST", "PATCH", "DELETE", "PUT"])
    async def rest(path: str, request: Request):
        who = store.user(bearer(request))["id"]
        raw = await request.body()
        require(len(raw) <= 16384, "Request too large", 413)
        body = json.loads(raw) if raw else {}
        require(isinstance(body, dict), "Invalid request", 400)
        def operation(state):
            if path.startswith("rpc/"):
                return rpc(store, state, who, path[4:], body)
            if request.method == "GET":
                return read_rows(store, state, who, path, request.query_params)
            return write_rows(state, who, request.method, path, request.query_params, body)
        out = await commit(operation)
        return delayed(out) if path == "rpc/watch_snapshot" else out

    @app.websocket("/realtime/v1/websocket")
    async def socket(ws: WebSocket):
        await ws.accept()
        out = asyncio.Queue(256)
        peer = {"who": "", "token": "", "topics": {}, "meta": {}, "ref": uid(), "out": out, "writer": asyncio.create_task(hub.writer(ws, out))}
        hub.peers[ws] = peer
        count, window = 0, time.monotonic()
        try:
            while True:
                msg = await asyncio.wait_for(ws.receive_json(), 20)
                require(isinstance(msg, dict) and len(json.dumps(msg)) <= 32768, "Invalid message", 400)
                count += 1
                if time.monotonic() - window >= 1:
                    count, window = 1, time.monotonic()
                require(count <= 100, "Too many messages", 429)
                event, topic = msg.get("event"), msg.get("topic", "")
                payload, ref = msg.get("payload", {}), msg.get("ref")
                require(isinstance(payload, dict), "Invalid payload", 400)
                if event == "phx_join":
                    token = payload.get("access_token", "")
                    who = store.user(token)["id"]
                    require(not peer["who"] or peer["who"] == who, "Identity changed")
                    state = store.load()
                    if topic != TOPIC:
                        sid = topic.removeprefix(TOPIC + ":snap:")
                        require(topic == TOPIC + ":snap:" + sid and sid in state["sessions"] and may_read(state["sessions"][sid], who), "Private channel denied")
                    peer.update(who=who, token=token)
                    peer["topics"][topic] = payload.get("config", {})
                    await hub.send(ws, topic, "phx_reply", {"status": "ok", "response": {}}, ref)
                    if topic == TOPIC:
                        await hub.send(ws, topic, "system", {"status": "ok", "extension": "postgres_changes"})
                        peer.pop("presence", None)  # a (re)join always gets a roster
                        await hub.presence()
                    continue
                require(peer["who"], "Authenticate first", 401)
                store.user(peer["token"])
                if event == "heartbeat":
                    await hub.send(ws, topic, "phx_reply", {"status": "ok", "response": {}}, ref)
                elif event == "phx_leave":
                    peer["topics"].pop(topic, None)
                    if topic == TOPIC:
                        peer["meta"] = {}
                        await hub.presence()
                elif event == "access_token":
                    require(store.user(payload.get("access_token", ""))["id"] == peer["who"], "Identity changed")
                    peer["token"] = payload["access_token"]
                elif event == "presence" and topic in peer["topics"]:
                    meta = payload.get("payload", {}) if payload.get("event") == "track" else {}
                    require(isinstance(meta, dict), "Invalid presence", 400)
                    if meta:
                        s = store.load()["sessions"].get(meta.get("sid"))
                        require(s and may_read(s, peer["who"]), "Presence denied")
                        meta = {k: v for k, v in meta.items() if k in ("sid", "where", "typing_monk", "typing_until", "hero")}
                        meta["name"] = store.profile(peer["who"])["username"]
                    peer["meta"] = meta
                    await hub.presence()
                elif event == "broadcast" and topic in peer["topics"]:
                    data, kind = payload.get("payload", {}), payload.get("event", "")
                    require(isinstance(data, dict), "Invalid broadcast", 400)
                    sid = data.get("sid")
                    s = store.load()["sessions"].get(sid)
                    require(s and member(s, peer["who"]), "Spectators cannot publish")
                    if kind == "snap":
                        require(s["state"] == "running" and topic == TOPIC + ":snap:" + sid, "Movement denied")
                        paths = data.get("p", [])
                        require(isinstance(paths, list) and len(paths) == 1 and isinstance(paths[0], dict) and paths[0].get("id") == peer["who"] and not data.get("r"), "Cannot move another player")
                        points = paths[0].get("p", [])
                        require(isinstance(points, list) and 1 <= len(points) <= 80 and all(isinstance(p, list) and len(p) == 3 and all(type(v) in (int, float) and math.isfinite(v) and abs(v) < 1e12 for v in p) for p in points), "Invalid movement", 400)
                    else:
                        # Lobby broadcasts only ring a reload; DB rows remain authoritative.
                        require(topic == TOPIC and kind == "row", "Unsupported broadcast")
                    for other, target in list(hub.peers.items()):
                        if other != ws and topic in target["topics"] and may_read(s, target["who"]):
                            if kind == "snap" and not plays(s, target["who"]):
                                asyncio.get_running_loop().call_later(SPECTATOR_DELAY_S,
                                    lambda o=other: asyncio.ensure_future(hub.send(o, topic, "broadcast", payload)))
                            else:
                                await hub.send(other, topic, "broadcast", payload)
        except (WebSocketDisconnect, asyncio.TimeoutError, HTTPException, ValueError, TypeError, KeyError):
            peer["writer"].cancel()  # no send may race the close
            try:
                await ws.close(code=1008)
            except (RuntimeError, WebSocketDisconnect):
                pass
        finally:
            hub.peers.pop(ws, None)
            peer["writer"].cancel()
            await hub.presence()

    return app
