#!/usr/bin/env python3
"""Phones against the movement relay (scripts/relay/RelayServer.gd).

    godot --headless --path game --script res://tools/relay.gd -- --test-auth --hz 20
    python3 tools/sim/relay_load.py --phones 40 --hz 20 [--url wss://....trycloudflare.com]

Each phone says hello (a test:<id> token -- the relay must run with
--test-auth), walks a weaving path sending one sample every 1/hz, and reads
the snapshots: how much of everyone else's walk arrives, and how long its own
samples take to come back (the full trip a classmate sees, on its own clock).

A real class instead, through the published relay and its real sign-in check:

    SUPABASE_URL=... SUPABASE_ANON_KEY=... \\
      python3 tools/sim/relay_load.py --code K7QM --phones 40 --hz 20

signs in the reusable roster (simclass000...), puts it in the session's teams,
and says hello with each student's own token. Sign-ins are limited per IP
(about 30 per 5 minutes): past that it waits.

A weak line: --slow N --kbps K gives the first N phones K kbit/s down, and
--adapt has them ask the relay for fewer snapshots the way the app does
(RelayLink: a pong queued RATE_DOWN_S over the best twice running halves the
rate, down to a quarter; copied here, not imported). Reports how far behind
each slow phone's own walk comes back, early and late in the run.
"""
import argparse
import json
import math
import random
import socket
import statistics
import struct
import threading
import time

import websocket

SESSION = "5e55a5e5-0000-4000-8000-00000000beef"


def now_ms():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


class Phone(threading.Thread):
    def __init__(self, i, url, seconds, hz, go, token=None, session=SESSION, kbps=0, adapt=False):
        super().__init__(daemon=True)
        self.kbps, self.adapt = kbps, adapt
        self.trips = []          # (seconds into the run, own sample's trip)
        self.rates = []          # (seconds into the run, snapshots a second asked for)
        self.started = 0.0
        self.i, self.url, self.seconds, self.every, self.go = i, url, seconds, 1.0 / hz, go
        self.token, self.session = token or f"test:phone{i}", session
        self.hello_at = 0.0
        self.let_in_s = None     # hello to welcome: the relay checking who this is
        self.idx = 0
        self.sent = 0
        self.heard = {}          # idx -> points received
        self.lag = []
        self.bytes = 0
        self.trouble = []

    def _take(self, data):
        self.bytes += len(data)
        if isinstance(data, str):
            m = json.loads(data)
            if m.get("e") == "welcome":
                self.idx = int(m["p"]["idx"])
                self.let_in_s = time.time() - self.hello_at
            return
        if len(data) < 2 or data[0] != 2:
            return
        at, now = 2, now_ms()
        for _ in range(data[1]):
            idx, n = data[at], data[at + 1]
            at += 2
            for _ in range(n):
                t, _x, _y = struct.unpack_from("<Ihh", data, at)
                at += 8
                if idx == self.idx:
                    self.lag.append(((now - t) & 0xFFFFFFFF) / 1000.0)
                    self.trips.append((time.time() - self.started, self.lag[-1]))
                else:
                    self.heard[idx] = self.heard.get(idx, 0) + 1

    def _read(self, ws):
        """Takes a message if one is waiting; False once the relay has closed."""
        try:
            op, data = ws.recv_data()
            if self.kbps:                               # a line this slow, roughly
                time.sleep(len(data) * 8 / (self.kbps * 1000.0))
        except websocket.WebSocketTimeoutException:
            return True
        except Exception as e:
            self.trouble.append(f"recv: {e}")
            return False
        if op == websocket.ABNF.OPCODE_TEXT and self.adapt:
            m = json.loads(data.decode())
            if m.get("e") == "pong":
                self._judge(time.monotonic() - float(m["p"]["t"]), ws)
        if op == websocket.ABNF.OPCODE_CLOSE:          # a refusal says why in the close
            code = struct.unpack("!H", data[:2])[0] if len(data) >= 2 else 0
            self.trouble.append(f"closed {code} {data[2:].decode(errors='replace')}")
            return False
        self._take(data.decode() if op == websocket.ABNF.OPCODE_TEXT else data)
        return True

    def _judge(self, trip, ws):
        """RelayLink._judge_rate / next_rate, in Python."""
        now = time.monotonic()
        self.best = min(self.best, trip)
        queued = trip - min(self.best, 0.5)               # RTT_CAP
        if queued > 0.15:                                 # RATE_UP_S
            self.calm_since = now
        least = max(-(-self.hz // 4), 1)
        if queued > 2.0:                                  # FLUSH_S: start over at the least
            self._slower(now)
            self.flush = least
            return
        if now < self.hold_until:
            return
        self.over = self.over + 1 if queued > 0.5 else 0  # RATE_DOWN_S
        want = self.rate
        if self.over >= 2 and self.rate > least:
            want = max(self.rate // 2, least)
        elif now - self.calm_since >= self.calm_need and self.rate < self.hz:
            want = min(self.rate * 2, self.hz)
        if want != self.rate:
            if want < self.rate:
                self._slower(now)
                self.hold_until = now + 3.0               # RATE_HOLD_S
            else:
                self.raised_at = now
            self.rate, self.over, self.calm_since = want, 0, now
            self.rates.append((time.time() - self.started, want))
            ws.send(json.dumps({"e": "rate", "p": {"hz": want}}))

    def _slower(self, now):
        if now - self.raised_at < 30.0:                   # RATE_TRY_S
            self.calm_need = min(self.calm_need * 2, 160.0)
        self.raised_at = float("-inf")

    def _open(self, rate=0):
        """Connected and welcomed (asking for `rate` snapshots a second), or None."""
        try:
            opts = ((socket.SOL_SOCKET, socket.SO_RCVBUF, 4096),) if self.kbps else ()
            ws = websocket.create_connection(self.url, timeout=15, sockopt=opts)
        except Exception as e:
            self.trouble.append(f"connect: {e}")
            return None
        self.hello_at = time.time()
        hello = {"v": 1, "token": self.token, "session": self.session, "role": "player", "hero": 1}
        if rate:
            hello["rate"] = rate
        ws.send(json.dumps({"e": "hello", "p": hello}))
        ws.settimeout(0.005)
        self.idx = 0
        while not self.idx and time.time() - self.hello_at < 30:
            if not self._read(ws):
                return None
        now = time.monotonic()
        self.rate, self.over, self.calm_since = rate or self.hz, 0, now
        self.best, self.flush, self.hold_until, self.raised_at = float("inf"), 0, 0.0, float("-inf")
        if not rate:
            self.calm_need = 10.0                         # RATE_CALM_S, from a fresh join
        return ws

    def run(self):
        self.hz = round(1.0 / self.every)
        ws = self._open()
        if ws is None:
            return
        self.go.wait()
        self.started = time.time()
        end = time.time() + self.seconds
        nxt = time.time() + random.uniform(0, self.every)
        heading = random.uniform(0, 2 * math.pi)
        x, y = random.uniform(500, 2500), random.uniform(400, 1300)
        last_ping = time.time()
        while time.time() < end:
            if getattr(self, "flush", 0):
                self.rates.append((time.time() - self.started, f"started over at {self.flush}"))
                ws.close()
                ws = self._open(self.flush)
                if ws is None:
                    break
                continue
            t = time.time()
            if t >= nxt and self.idx:
                heading += random.uniform(-0.4, 0.4)       # a thumb that weaves
                x = min(3000, max(0, x + math.cos(heading) * 150 * self.every))
                y = min(1700, max(0, y + math.sin(heading) * 150 * self.every))
                try:
                    ws.send_binary(struct.pack("<BIhh", 1, now_ms(), int(x), int(y)))
                    self.sent += 1
                except Exception as e:
                    self.trouble.append(f"send: {e}")
                    break
                nxt += self.every
            if t - last_ping > (1 if self.adapt else 5):
                last_ping = t
                ws.send(json.dumps({"e": "ping", "p": {"t": time.monotonic()}}))
            if not self._read(ws):
                break
        time.sleep(0.5)                  # the last snapshots
        ws.settimeout(0.2)
        while True:
            try:
                op, data = ws.recv_data()
                self._take(data.decode() if op == websocket.ABNF.OPCODE_TEXT else data)
            except Exception:
                break
        ws.close()


def real_class(a):
    """The roster signed in and put in the session: its id and their tokens."""
    from api import Api, ApiError                     # needs SUPABASE_URL / SUPABASE_ANON_KEY
    sid, teams, tokens = None, [], []
    for i in range(a.phones):
        api = Api()
        name = f"simclass{a.first + i:03d}"
        while True:
            try:
                api.sign_in(f"{name}@numxventure-test.dev", "letmein123")
                break
            except ApiError as e:
                if "429" not in str(e):
                    raise
                print(f"   sign-in limit reached at {name}; trying again in 30s")
                time.sleep(30)
        if sid is None:
            s = api.get(f"sessions?select=id&code=eq.{a.code.upper()}&state=neq.ended")
            if not s:
                raise SystemExit(f"no live session {a.code}")
            sid = s[0]["id"]
            teams = api.get(f"teams?select=id&session_id=eq.{sid}&order=name")
            if not teams:
                raise SystemExit("the session has no teams yet")
            a.url = a.url or api.get("relay?select=url")[0]["url"]
        try:
            api.post("members", {"session_id": sid, "team_id": teams[i % len(teams)]["id"],
                                 "profile_id": api.user})
        except ApiError as e:
            if "duplicate" not in str(e):
                print(f"   {name} not in the session: {e}")
        tokens.append(api.token)
    return sid, tokens


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", help="default: this laptop's relay, or the published one with --code")
    ap.add_argument("--code", help="a live session: real accounts instead of test tokens")
    ap.add_argument("--first", type=int, default=0, help="first simclass index to use")
    ap.add_argument("--slow", type=int, default=0, help="this many phones on a weak line")
    ap.add_argument("--kbps", type=float, default=24, help="the weak line's speed down")
    ap.add_argument("--adapt", action="store_true", help="slow phones ask for fewer snapshots, as the app does")
    ap.add_argument("--phones", type=int, default=40)
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--hz", type=float, default=10)
    a = ap.parse_args()
    sid, tokens = real_class(a) if a.code else (SESSION, [None] * a.phones)
    a.url = a.url or "ws://127.0.0.1:47317"
    go = threading.Event()
    phones = [Phone(i, a.url, a.seconds, a.hz, go, tokens[i], sid,
                    a.kbps if i < a.slow else 0, a.adapt and i < a.slow) for i in range(a.phones)]
    for p in phones:
        p.start()
    waited = time.time()
    while time.time() - waited < 30 and not all(p.idx or p.trouble for p in phones):
        time.sleep(0.1)
    go.set()
    for p in phones:
        p.join(a.seconds + 20)
    sent = {p.idx: p.sent for p in phones if p.idx}
    ratio = []
    for p in phones:
        want = sum(n for idx, n in sent.items() if idx != p.idx)
        if want:
            ratio.append(sum(p.heard.values()) / want)
    lag = sorted(x for p in phones for x in p.lag)
    print(f"== {a.phones} phones -> {a.url} for {a.seconds}s, {a.hz:g} samples/s each ==")
    print(f"   joined {len(sent)}/{a.phones}, sent {sum(sent.values())} ({sum(sent.values()) / a.seconds:.0f}/s)")
    let_in = sorted(p.let_in_s for p in phones if p.let_in_s is not None)
    if let_in:
        print(f"   let in: median {statistics.median(let_in) * 1000:.0f}ms  max {let_in[-1] * 1000:.0f}ms")
    if ratio:
        print(f"   delivered per phone: {min(ratio) * 100:.1f}%..{max(ratio) * 100:.1f}%")
    if lag:
        print(f"   own trip: median {statistics.median(lag) * 1000:.0f}ms  p95 {lag[int(len(lag) * .95) - 1] * 1000:.0f}ms"
              f"  max {lag[-1] * 1000:.0f}ms")
    print(f"   down per phone: {statistics.mean(p.bytes for p in phones) / a.seconds / 1024:.1f} KB/s (payload)")
    for p in phones[:a.slow]:
        early = [d for (at, d) in p.trips if at < a.seconds / 3]
        late = [d for (at, d) in p.trips if at >= a.seconds * 2 / 3]
        if early and late:
            print(f"   slow phone {p.i} ({a.kbps:g} kbit/s{', adapting' if p.adapt else ''}): own walk back "
                  f"{statistics.median(early):.2f}s early, {statistics.median(late):.2f}s late, worst {max(d for _, d in p.trips):.2f}s;"
                  f" down {p.bytes / a.seconds / 1024:.1f} KB/s; asked {p.rates or 'nothing'}")
    bad = [t for p in phones for t in p.trouble]
    print(f"   trouble: {len(bad)}" + (f"  e.g. {bad[0]}" if bad else ""))


if __name__ == "__main__":
    main()
