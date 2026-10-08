#!/usr/bin/env python3
"""Hear the network reports debug builds send from phones (scripts/net/NetReport.gd).

    python3 tools/sim/netreport_listen.py [--out reports.jsonl]

Joins the `netreport` broadcast channel and prints one line per report;
every report also goes to --out as JSON, one per line.
"""
import argparse
import json
import os
import re
import threading
import time

import websocket

HERE = os.path.dirname(os.path.abspath(__file__))


def _conf():
    url, key = os.environ.get("SUPABASE_URL", ""), os.environ.get("SUPABASE_ANON_KEY", "")
    if not (url and key):
        text = open(os.path.join(HERE, "..", "..", "project.godot")).read()
        url = url or re.search(r'^supabase/url="([^"]+)"', text, re.M).group(1)
        key = key or re.search(r'^supabase/anon_key="([^"]+)"', text, re.M).group(1)
    return url.rstrip("/"), key


def line(p):
    rt = p.get("rt", {})
    dial = "; ".join(f"{d.get('pick') or 'by name'} of {len(d.get('addrs', []))} in {d.get('ms')}ms"
                     f" (lookup {d.get('resolve_ms', '?')}ms)"
                     for d in p.get("dial", {}).values()) or "-"
    h = p.get("http", {})
    return (f"{time.strftime('%H:%M:%S')}  {p.get('device')} {p.get('user') or '(signed out)'}  up {p.get('up_s')}s"
            f"  line {p.get('line')}  dial {dial}"
            f"  http ok {h.get('ok')} failed {h.get('failed')} (last {h.get('last_failure')}) rtt {h.get('rtt_ms')}ms"
            f"  rt {rt.get('socket', '-')} state {rt.get('state', '-')} rtt {rt.get('rtt_ms', '-')}ms"
            f" opens {rt.get('opens', '-')} closes {rt.get('closes', '-')} first open {rt.get('first_open_s', '-')}s"
            f"  reports lost {p.get('reports', {}).get('lost')}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="netreports.jsonl")
    a = ap.parse_args()
    url, key = _conf()
    ws_url = url.replace("https://", "wss://") + f"/realtime/v1/websocket?apikey={key}&vsn=1.0.0"
    while True:
        try:
            ws = websocket.create_connection(ws_url, timeout=30)
            ws.send(json.dumps({"topic": "realtime:netreport", "event": "phx_join", "ref": "1",
                                "payload": {"config": {"broadcast": {"self": False}}}}))

            def beat():
                while ws.connected:
                    time.sleep(25)
                    try:
                        ws.send(json.dumps({"topic": "phoenix", "event": "heartbeat", "payload": {}, "ref": "hb"}))
                    except Exception:
                        return
            threading.Thread(target=beat, daemon=True).start()
            print("listening on netreport", flush=True)
            while True:
                m = json.loads(ws.recv())
                if m.get("event") == "broadcast":
                    p = m["payload"].get("payload", {})
                    print(line(p), flush=True)
                    with open(a.out, "a") as f:
                        f.write(json.dumps({"at": time.time(), **p}) + "\n")
        except KeyboardInterrupt:
            return
        except Exception as e:
            print(f"listener: {e}; again in 3s", flush=True)
            time.sleep(3)


if __name__ == "__main__":
    main()
