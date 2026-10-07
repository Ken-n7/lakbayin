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
POS_EVERY_S = 0.15          # AdventureScreen.POS_EVERY_S, while walking
HEARTBEAT_S = 25.0


class Mover(threading.Thread):
    def __init__(self, label, user, token, session, team, seconds, go, walks=True):
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

    def _send(self, ws, event, payload):
        self._ref += 1
        with self._lock:
            ws.send(json.dumps({"topic": TOPIC if event != "heartbeat" else "phoenix",
                                "event": event, "payload": payload, "ref": str(self._ref)}))

    def run(self):
        ws_url = URL.replace("https://", "wss://") + f"/realtime/v1/websocket?apikey={KEY}&vsn=1.0.0"
        try:
            ws = websocket.create_connection(ws_url, timeout=10)
        except Exception as e:
            self.trouble.append(f"connect: {e}")
            return
        self._send(ws, "phx_join", {
            "config": {"postgres_changes": [{"event": "*", "schema": "public", "table": "sessions",
                                             "filter": f"id=eq.{self.session}"}],
                       "broadcast": {"self": False},
                       "presence": {"key": self.user, "enabled": True}},
            "access_token": self.token})
        self._send(ws, "presence", {"type": "presence", "event": "track",
                                    "payload": {"sid": self.session, "where": "map", "name": self.label}})
        ws.settimeout(0.02)
        x, y = random.uniform(400, 2800), random.uniform(300, 1500)
        heading = random.uniform(0, 6.28)
        next_pos = next_beat = time.time()
        end = None
        while end is None or time.time() < end:
            now = time.time()
            if end is None and self.go.is_set():
                end = now + self.seconds
                self.t0 = now
            if self.walks and end is not None and now >= next_pos:
                heading += random.uniform(-0.4, 0.4)
                x += 150 * POS_EVERY_S * (1 if random.random() < 0.5 else -1)
                y += 150 * POS_EVERY_S * (1 if random.random() < 0.5 else -1)
                try:
                    self._send(ws, "broadcast", {"type": "broadcast", "event": "pos", "payload": {
                        "sid": self.session, "id": self.user, "name": self.label, "team": self.team,
                        "hero": 1, "x": x, "y": y, "vx": 150.0, "vy": 0.0, "face": "right",
                        "moving": True, "ts": now, "sent": now}})
                    self.sent += 1
                except Exception as e:
                    self.trouble.append(f"send: {e}")
                    break
                next_pos = now + POS_EVERY_S
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
            self._take(json.loads(raw))
        try:
            ws.close()
        except Exception:
            pass

    def _take(self, msg):
        ev, p = msg.get("event"), msg.get("payload") or {}
        if ev == "broadcast" and p.get("event") == "pos":
            self.heard += 1
            sent = (p.get("payload") or {}).get("sent")
            if sent and self.heard % 7 == 0:
                self.lag.append(time.time() - sent)
        elif ev in ("presence_diff", "presence_state"):
            self.presence_msgs += 1
        elif ev == "postgres_changes":
            self.db_changes += 1
        elif ev == "phx_reply":
            if p.get("status") == "ok" and msg.get("topic") == TOPIC:
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
    print(f"\n== realtime: {len(movers)} phones ({len(walkers)} walking) for {seconds}s ==")
    print(f"   joined: {sum(m.joined for m in movers)}/{len(movers)}")
    print(f"   positions sent: {sent}  ({sent / seconds:.0f}/s in)")
    # Each walker's position should reach every other phone (self: false).
    expected = [sent - m.sent for m in movers]
    heard = [m.heard for m in movers]
    ratio = [h / e for h, e in zip(heard, expected) if e]
    print(f"   delivered: {sum(heard)}  ({sum(heard) / seconds:.0f}/s out)  "
          f"per phone {min(ratio) * 100:.0f}%..{max(ratio) * 100:.0f}% of what was sent"
          if ratio else "   delivered: nothing expected")
    lag = sorted(x for m in movers for x in m.lag)
    if lag:
        print(f"   lag send->heard: median {statistics.median(lag) * 1000:.0f}ms  "
              f"p95 {lag[int(len(lag) * 0.95) - 1] * 1000:.0f}ms  max {lag[-1] * 1000:.0f}ms")
    print(f"   presence messages: {sum(m.presence_msgs for m in movers)}  "
          f"db changes heard: {sum(m.db_changes for m in movers)}")
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
