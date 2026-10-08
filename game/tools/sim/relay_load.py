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
"""
import argparse
import json
import math
import random
import statistics
import struct
import threading
import time

import websocket

SESSION = "5e55a5e5-0000-4000-8000-00000000beef"


def now_ms():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


class Phone(threading.Thread):
    def __init__(self, i, url, seconds, hz, go, token=None, session=SESSION):
        super().__init__(daemon=True)
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
                else:
                    self.heard[idx] = self.heard.get(idx, 0) + 1

    def _read(self, ws):
        """Takes a message if one is waiting; False once the relay has closed."""
        try:
            op, data = ws.recv_data()
        except websocket.WebSocketTimeoutException:
            return True
        except Exception as e:
            self.trouble.append(f"recv: {e}")
            return False
        if op == websocket.ABNF.OPCODE_CLOSE:          # a refusal says why in the close
            code = struct.unpack("!H", data[:2])[0] if len(data) >= 2 else 0
            self.trouble.append(f"closed {code} {data[2:].decode(errors='replace')}")
            return False
        self._take(data.decode() if op == websocket.ABNF.OPCODE_TEXT else data)
        return True

    def run(self):
        try:
            ws = websocket.create_connection(self.url, timeout=15)
        except Exception as e:
            self.trouble.append(f"connect: {e}")
            return
        self.hello_at = time.time()
        ws.send(json.dumps({"e": "hello", "p": {"v": 1, "token": self.token,
                                                "session": self.session, "role": "player", "hero": 1}}))
        ws.settimeout(0.005)
        while not self.idx and time.time() - self.hello_at < 30:
            if not self._read(ws):
                return
        self.go.wait()
        end = time.time() + self.seconds
        nxt = time.time() + random.uniform(0, self.every)
        heading = random.uniform(0, 2 * math.pi)
        x, y = random.uniform(500, 2500), random.uniform(400, 1300)
        last_ping = time.time()
        while time.time() < end:
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
            if t - last_ping > 5:
                last_ping = t
                ws.send(json.dumps({"e": "ping", "p": {"t": t}}))
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
    ap.add_argument("--phones", type=int, default=40)
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--hz", type=float, default=10)
    a = ap.parse_args()
    sid, tokens = real_class(a) if a.code else (SESSION, [None] * a.phones)
    a.url = a.url or "ws://127.0.0.1:47317"
    go = threading.Event()
    phones = [Phone(i, a.url, a.seconds, a.hz, go, tokens[i], sid) for i in range(a.phones)]
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
    bad = [t for p in phones for t in p.trouble]
    print(f"   trouble: {len(bad)}" + (f"  e.g. {bad[0]}" if bad else ""))


if __name__ == "__main__":
    main()
