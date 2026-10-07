"""Phones on the map, as far as Realtime can tell: each one joins the app's
topic the way scripts/net/Realtime.gd does, says it is on the map (presence),
and broadcasts its hero's position at the app's own rate while it walks --
POS_EVERY_S, AdventureScreen.gd. Everyone hears everyone: the app has one
topic for every session, so this is the fan-out a class actually produces.

Used by classroom.py --move SECONDS. Counts what each phone sent and heard,
how late it heard it, and anything Realtime said was wrong.
"""
import json
import random
import statistics
import threading
import time

import websocket

from api import KEY, URL

TOPIC = "realtime:numxventure"
## "shared": one channel for everyone (the app today). "team": one per session
## and team. "hub": every phone sends on a channel of its own that only the
## teacher joins; the teacher sends everyone one snapshot of all positions,
## SNAP_EVERY_S apart, on the session's snapshot channel -- the whole class on
## one map, without every position going to every phone.
CHANNEL = "shared"
SNAP_EVERY_S = 0.25
## Send like the app does since it sends on change: on each turn (here every
## 1.5-4.5s, a real player's straight stretches) and a POS_EVERY_S heartbeat
## between. Off: a position every POS_EVERY_S, every one a new direction.
ON_CHANGE = False
## Answering questions: walk 8-15s, then stand at a tower 8-15s and submit an
## answer (apply_answer, a real row change). QUIET_QUIZ: send nothing while
## answering (the app now); else a standing keepalive every 3s (before).
ANSWER = False
QUIET_QUIZ = False
## Which member changes a phone gets: "session" (every classmate's, before),
## "own" (its own row, the app now), "" (none).
MEMBERS = ""
POS_EVERY_S = 0.15          # AdventureScreen.POS_EVERY_S, while walking
HEARTBEAT_S = 25.0


class Mover(threading.Thread):
    def __init__(self, label, user, token, session, team, seconds, go, walks=True, api=None):
        super().__init__(daemon=True)
        self.label, self.user, self.token = label, user, token
        self.session, self.team = session, team
        # `go` is the teacher's Start: connected and on the map before it,
        # walking from it for `seconds`.
        self.seconds, self.go, self.walks = seconds, go, walks
        self.sent = self.heard = self.presence_msgs = self.db_changes = 0
        self.lag = []                 # seconds, send -> heard, sampled
        self.trouble = []             # what Realtime said was wrong
        self.closed = None
        self.cut_at = None            # seconds from the teacher's Start, when cut off
        self.t0 = None
        self.joined = False
        self._ref = 0
        self._lock = threading.Lock()
        self.topic = TOPIC if CHANNEL in ("shared", "hub") else f"{TOPIC}:{session}:{team.replace(' ', '_')}"
        # hub: where this phone's positions go, and where snapshots come from.
        self.in_topic = f"{TOPIC}:in:{session}:{user}"
        self.snap_topic = f"{TOPIC}:snap:{session}"
        self.hub_inputs = []          # the teacher: every phone's in_topic
        self._latest = {}             # the teacher: id -> latest position
        self.api = api
        self.answers = 0
        self.rows_heard = 0           # classmates' progress rows inside snapshots
        self.snaps_sent = 0
        self.snaps_heard = 0
        self.snap_bytes = 0

    def _send(self, ws, event, payload, topic=None):
        self._ref += 1
        with self._lock:
            ws.send(json.dumps({"topic": "phoenix" if event == "heartbeat" else (topic or self.topic),
                                "event": event, "payload": payload, "ref": str(self._ref)}))

    def _join_plain(self, ws, topic):
        """A broadcast-only channel: no presence, no table changes."""
        self._send(ws, "phx_join", {"config": {"broadcast": {"self": False},
                                               "presence": {"enabled": False},
                                               "postgres_changes": []},
                                    "access_token": self.token}, topic)

    def run(self):
        ws_url = URL.replace("https://", "wss://") + f"/realtime/v1/websocket?apikey={KEY}&vsn=1.0.0"
        try:
            ws = websocket.create_connection(ws_url, timeout=10)
        except Exception as e:
            self.trouble.append(f"connect: {e}")
            return
        changes = [{"event": "*", "schema": "public", "table": "sessions",
                    "filter": f"id=eq.{self.session}"}]
        if MEMBERS and self.walks:
            changes.append({"event": "*", "schema": "public", "table": "members",
                            "filter": f"session_id=eq.{self.session}" if MEMBERS == "session"
                            else f"profile_id=eq.{self.user}"})
        self._send(ws, "phx_join", {
            "config": {"postgres_changes": changes,
                       "broadcast": {"self": False},
                       "presence": {"key": self.user, "enabled": True}},
            "access_token": self.token})
        self._send(ws, "presence", {"type": "presence", "event": "track",
                                    "payload": {"sid": self.session, "where": "map", "name": self.label}})
        if CHANNEL == "hub":
            self._join_plain(ws, self.snap_topic)
            for t in (self.hub_inputs if not self.walks else [self.in_topic]):
                self._join_plain(ws, t)
        ws.settimeout(0.02)
        next_snap = time.time()
        next_turn = time.time()
        quiz_until = 0.0              # answering a question until then
        walk_until = None
        x, y = random.uniform(400, 2800), random.uniform(300, 1500)
        heading = random.uniform(0, 6.28)
        next_pos = next_beat = time.time()
        end = None
        while end is None or time.time() < end:
            now = time.time()
            if end is None and self.go.is_set():
                end = now + self.seconds
                self.t0 = now
            if ANSWER and self.walks and end is not None:
                if walk_until is None:
                    walk_until = now + random.uniform(8, 15)
                if quiz_until == 0.0 and now >= walk_until:
                    quiz_until = now + random.uniform(8, 15)
                elif quiz_until and now >= quiz_until:
                    quiz_until, walk_until = 0.0, now + random.uniform(8, 15)
                    threading.Thread(target=self._answer, daemon=True).start()
            in_quiz = quiz_until > 0.0
            if in_quiz and (QUIET_QUIZ or now < next_pos):
                pass                  # silent, or between keepalives
            elif in_quiz:
                next_pos = now + 3.0  # a standing keepalive, as the app did
                try:
                    self._send(ws, "broadcast", {"type": "broadcast", "event": "pos", "payload": {
                        "sid": self.session, "id": self.user, "x": round(x), "y": round(y),
                        "vx": 0, "vy": 0, "face": "down", "moving": False,
                        "ts": round(now, 2), "sent": now}}, self.in_topic if CHANNEL == "hub" else None)
                    self.sent += 1
                except Exception as e:
                    self.trouble.append(f"send: {e}")
                    break
            turn = ON_CHANGE and now >= next_turn and not in_quiz
            if self.walks and end is not None and not in_quiz and (now >= next_pos or turn):
                if turn:
                    next_turn = now + random.uniform(1.5, 4.5)
                heading += random.uniform(-0.4, 0.4) if (turn or not ON_CHANGE) else 0.0
                x += 150 * POS_EVERY_S * (1 if random.random() < 0.5 else -1)
                y += 150 * POS_EVERY_S * (1 if random.random() < 0.5 else -1)
                try:
                    self._send(ws, "broadcast", {"type": "broadcast", "event": "pos", "payload": {
                        "sid": self.session, "id": self.user, "name": self.label, "team": self.team,
                        "hero": 1, "x": round(x) if ON_CHANGE else x, "y": round(y) if ON_CHANGE else y,
                        "vx": 150, "vy": 0, "face": "right",
                        "moving": True, "ts": round(now, 2) if ON_CHANGE else now, "sent": now}},
                        self.in_topic if CHANNEL == "hub" else None)
                    self.sent += 1
                except Exception as e:
                    self.trouble.append(f"send: {e}")
                    break
                next_pos = now + POS_EVERY_S
            if CHANNEL == "hub" and not self.walks and end is not None and now >= next_snap:
                next_snap = now + SNAP_EVERY_S
                if self._latest:
                    try:
                        self._send(ws, "broadcast", {"type": "broadcast", "event": "snap",
                                                     "payload": {"p": list(self._latest.values())}},
                                   self.snap_topic)
                        self.snaps_sent += 1
                    except Exception as e:
                        self.trouble.append(f"snap: {e}")
                        break
                    self._latest = {}
            if now >= next_beat:
                try:
                    self._send(ws, "heartbeat", {})
                except Exception as e:
                    self.trouble.append(f"heartbeat: {e}")
                    break
                next_beat = now + HEARTBEAT_S
            try:
                raw = ws.recv()
            except websocket.WebSocketTimeoutException:
                continue
            except Exception as e:
                self.closed = f"{type(e).__name__}: {e}"
                break
            if not raw:
                continue
            self._take(json.loads(raw), raw)
        try:
            ws.close()
        except Exception:
            pass

    def _answer(self):
        try:
            self.api.rpc("apply_answer", {"p_session": self.session,
                                          "p_correct": random.random() < 0.7})
            self.answers += 1
        except Exception as e:
            self.trouble.append(f"answer: {str(e)[:80]}")

    def _take(self, msg, raw=""):
        ev, p = msg.get("event"), msg.get("payload") or {}
        if ev == "broadcast" and p.get("event") == "snap":
            self.snaps_heard += 1
            self.snap_bytes += len(raw)
            self.rows_heard += sum(1 for r in (p.get("payload") or {}).get("r", [])
                                   if r.get("profile_id") != self.user)
            now = time.time()
            for q in (p.get("payload") or {}).get("p", []):
                # Simulated walkers only (they carry "sent"): a real phone in
                # the same session is not in what they were sent.
                if q.get("id") != self.user and q.get("sent"):
                    self.heard += 1
                    if self.heard % 7 == 0:
                        self.lag.append(now - q["sent"])
        elif ev == "broadcast" and p.get("event") == "pos" and CHANNEL == "hub":
            # The teacher, collecting for the next snapshot.
            q = p.get("payload") or {}
            self._latest[q.get("id")] = q
            self.heard += 1
        elif ev == "broadcast" and p.get("event") == "pos":
            self.heard += 1
            sent = (p.get("payload") or {}).get("sent")
            if sent and self.heard % 7 == 0:
                self.lag.append(time.time() - sent)
        elif ev in ("presence_diff", "presence_state"):
            self.presence_msgs += 1
        elif ev == "postgres_changes":
            self.db_changes += 1
        elif ev == "phx_reply":
            if p.get("status") == "ok" and msg.get("topic") == self.topic:
                self.joined = True
            elif p.get("status") != "ok":
                self.trouble.append(f"reply {p.get('status')}: {json.dumps(p.get('response'))[:160]}")
        elif ev == "system":
            if p.get("status") not in (None, "ok"):
                self.trouble.append(f"system: {json.dumps(p)[:200]}")
                if self.cut_at is None:
                    self.cut_at = time.time() - (self.t0 or time.time())
        elif ev in ("phx_error", "phx_close"):
            self.trouble.append(f"{ev}: {json.dumps(p)[:160]}")


def report(movers, seconds):
    walkers = [m for m in movers if m.walks]
    sent = sum(m.sent for m in walkers)
    print(f"\n== realtime: {len(movers)} connections ({len(walkers)} walking) for {seconds}s, "
          f"channel {CHANNEL} ({len({m.topic for m in movers})} channel(s)) ==")
    print(f"   joined: {sum(m.joined for m in movers)}/{len(movers)}")
    print(f"   positions sent: {sent}  ({sent / seconds:.0f}/s in)")
    # Each walker's position should reach every other phone on its channel
    # (self: false).
    by_topic = {}
    for w in walkers:
        by_topic[w.topic] = by_topic.get(w.topic, 0) + w.sent
    expected = [by_topic.get(m.topic, 0) - (m.sent if m.walks else 0) for m in movers] \
        if CHANNEL == "team" else [sent - m.sent for m in movers]
    if CHANNEL == "hub":
        heard = sum(m.snaps_heard for m in movers)
        print(f"   snapshots: {sum(m.snaps_sent for m in movers)} sent by a sim teacher, "
              f"{heard} heard ({heard / seconds:.0f}/s), "
              f"avg {sum(m.snap_bytes for m in movers) / max(heard, 1):.0f} bytes each")
    heard = [m.heard for m in movers]
    ratio = [h / e for h, e in zip(heard, expected) if e]
    print(f"   delivered: {sum(heard)}  ({sum(heard) / seconds:.0f}/s out)  "
          f"per phone {min(ratio) * 100:.0f}%..{max(ratio) * 100:.0f}% of what was sent"
          if ratio else "   delivered: nothing expected")
    lag = sorted(x for m in movers for x in m.lag)
    if lag:
        print(f"   lag send->heard: median {statistics.median(lag) * 1000:.0f}ms  "
              f"p95 {lag[int(len(lag) * 0.95) - 1] * 1000:.0f}ms  max {lag[-1] * 1000:.0f}ms")
    db = sum(m.db_changes for m in movers)
    print(f"   presence messages: {sum(m.presence_msgs for m in movers)}  "
          f"db changes heard: {db} ({db / seconds:.1f}/s)  "
          f"answers given: {sum(m.answers for m in movers)}  "
          f"classmates' progress rows in snapshots: {sum(m.rows_heard for m in movers)}")
    bad = [(m.label, t) for m in movers for t in m.trouble] + \
          [(m.label, "closed: " + m.closed) for m in movers if m.closed]
    # By kind, with how many phones each hit: thousands of lines say one thing.
    kinds = {}
    for label, t in bad:
        k = t.split(":")[0] + (": " + t.split('"message": "')[1].split('"')[0] if '"message": "' in t else
                               ": " + t.split('"reason": "')[1].split('"')[0] if '"reason": "' in t else "")
        kinds.setdefault(k, [0, set()])
        kinds[k][0] += 1
        kinds[k][1].add(label)
    cuts = sorted(m.cut_at for m in movers if m.cut_at is not None)
    if cuts:
        print(f"   cut off at (s after Start, negative = before): "
              f"{', '.join(f'{c:.1f}' for c in cuts)}")
    for k, (n, who) in sorted(kinds.items(), key=lambda kv: -len(kv[1][1])):
        print(f"   ! {k}  x{n}, on {len(who)} phone(s)")
    return 1 if bad or (ratio and min(ratio) < 0.9) else 0
