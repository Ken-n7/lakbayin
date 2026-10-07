#!/usr/bin/env python3
"""Fill a REAL session with walking students: the app's own Game Controls is
the teacher (and so PosHub, the position hub), these are the class.

    SUPABASE_URL=... SUPABASE_ANON_KEY=... \\
      python3 tools/sim/join_and_walk.py --code K7QM [--students 29] [--seconds 90]

Signs in the reusable roster (simclass000...), joins the session by its code,
spreads them over its teams, says each is on the map (presence), and from the
moment the teacher presses Start walks them, sending positions the app's way
(movers.py, channel "hub"). Reports what reached them in the hub's snapshots.
"""
import argparse
import threading
import time

from api import Api, ApiError
import movers as rt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--code", required=True)
    ap.add_argument("--students", type=int, default=29)
    ap.add_argument("--seconds", type=int, default=90)
    ap.add_argument("--pos-every", type=float, default=0.5)
    ap.add_argument("--first", type=int, default=0, help="first simclass index to use")
    ap.add_argument("--on-change", action="store_true",
                    help="send on turns + a heartbeat, as the app does now")
    ap.add_argument("--answer", action="store_true", help="walk, then stand and answer, repeat")
    ap.add_argument("--quiet-quiz", action="store_true", help="send nothing while answering")
    ap.add_argument("--members", choices=["", "session", "own"], default="",
                    help="member changes each phone subscribes to")
    a = ap.parse_args()
    rt.CHANNEL = "hub"
    rt.POS_EVERY_S = a.pos_every
    rt.ON_CHANGE = a.on_change
    rt.ANSWER = a.answer
    rt.QUIET_QUIZ = a.quiet_quiz
    rt.MEMBERS = a.members

    look = Api("look")
    look.sign_in(f"simclass{a.first:03d}@numxventure-test.dev", "letmein123")
    s = look.get(f"sessions?select=id,state&code=eq.{a.code.upper()}&state=neq.ended", what="find")
    if not s:
        raise SystemExit(f"no live session {a.code}")
    sid = s[0]["id"]
    teams = look.get(f"teams?select=id,name&session_id=eq.{sid}&order=name", what="teams")
    if not teams:
        raise SystemExit("the session has no teams yet")
    print(f"session {sid[:8]}, teams: {', '.join(t['name'] for t in teams)}")

    go = threading.Event()
    walkers = []
    for i in range(a.students):
        n = a.first + i
        api = Api(f"s{n}")
        email = f"simclass{n:03d}@numxventure-test.dev"
        try:
            api.sign_in(email, "letmein123")
        except ApiError:
            api.sign_up(email, f"simclass{n:03d}", "letmein123", "player")
        team = teams[i % len(teams)]
        try:
            api.post("members", {"session_id": sid, "team_id": team["id"],
                                 "profile_id": api.user}, what="join")
        except ApiError as e:
            if "duplicate" not in str(e) and "already" not in str(e):
                print(f"  student {n}: {e}")
        m = rt.Mover(f"simclass{n:03d}", api.user, api.token, sid, team["id"], a.seconds, go, api=api)
        walkers.append(m)
        m.start()
        time.sleep(0.1)
    print(f"{len(walkers)} on the map; walking once the teacher presses Start")
    for _ in range(600):
        st = look.get(f"sessions?select=state&id=eq.{sid}", what="poll")
        if st and st[0]["state"] == "running":
            break
        time.sleep(1)
    print("started")
    go.set()
    for m in walkers:
        m.join(a.seconds + 30)
    rt.report(walkers, a.seconds)


if __name__ == "__main__":
    main()
