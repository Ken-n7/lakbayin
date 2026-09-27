#!/usr/bin/env python3
"""Rescue, against the live project -- the Python twin of tools/rescue_check.gd.

    SUPABASE_URL=... SUPABASE_ANON_KEY=... python3 tools/sim/rescue_live.py

For machines where Godot cannot reach the project but Python can (a proxy
Godot's HTTP client does not use). A teacher, four players -- ana, ben and dee
on Reds, cal on Blues -- and every rule `public.rescue()` enforces, through the
same RPC the phone calls. The session is deleted at the end; the accounts stay
in Auth (deleting those needs the service key), all @numxventure-test.dev.
"""
import sys
import time

from api import Api, ApiError

failures = 0


def check(name, ok, detail=""):
    global failures
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok else f"   <{detail}>"))
    if not ok:
        failures += 1


def refused(api, session, to, amount, needle):
    """The rescue is refused, with `needle` in the server's reason."""
    try:
        api.rpc("rescue", {"p_session": session, "p_to": to, "p_amount": amount})
        return False, "it went through"
    except ApiError as e:
        return needle in str(e), str(e)


def gems(teacher, session, who):
    row = teacher.get(f"members?select=gems,rescued_at,eliminated&session_id=eq.{session}"
                      f"&profile_id=eq.{who}")
    return row[0] if row else {}


def main():
    stamp = str(int(time.time()))
    teacher = Api("teacher")
    check("teacher signs up", teacher.sign_up(f"rladmin{stamp}@numxventure-test.dev",
                                               f"rla{stamp}", "letmein123", "admin"))
    session = teacher.post("sessions", {"admin_id": teacher.user, "duration_s": 600})[0]["id"]
    teams = {}
    for name in ["Reds", "Blues"]:
        teams[name] = teacher.post("teams", {"session_id": session, "name": name})[0]["id"]

    players = {}
    for who, team in [("ana", "Reds"), ("ben", "Reds"), ("dee", "Reds"), ("cal", "Blues")]:
        p = Api(who)
        check(f"{who} signs up", p.sign_up(f"rl{who}{stamp}@numxventure-test.dev",
                                           f"rl{who}{stamp}", "letmein123", "player"))
        p.post("members", {"session_id": session, "team_id": teams[team], "profile_id": p.user})
        players[who] = p
    ana, ben, dee, cal = (players[k] for k in ["ana", "ben", "dee", "cal"])

    try:
        # Not before the teacher starts.
        ok, why = refused(ana, session, ben.user, 5, "not running")
        check("no rescue before the adventure starts", ok, why)

        ends = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 600)) + "Z"
        teacher.patch(f"sessions?id=eq.{session}", {"state": "running", "ends_at": ends})

        # The list the phone shows: your team, not you.
        mates = ana.get(f"members?select=profile_id,gems,eliminated,finished"
                        f"&session_id=eq.{session}&team_id=eq.{teams['Reds']}")
        others = [m for m in mates if m["profile_id"] != ana.user]
        check("the teammate list is your team without you", len(others) == 2
              and {m["profile_id"] for m in others} == {ben.user, dee.user}, str(others))

        for name, to, amount, needle in [
                ("another team's player is refused", cal.user, 5, "not on your team"),
                ("rescuing yourself is refused", ana.user, 5, "yourself"),
                ("giving 0 is refused", ben.user, 0, "at least 1"),
                ("giving every gem is refused, keep 1", ben.user, 50, "at most 49")]:
            ok, why = refused(ana, session, to, amount, needle)
            check(name, ok, why)
        check("refusals move nothing", gems(teacher, session, ana.user).get("gems") == 50
              and gems(teacher, session, ana.user).get("rescued_at") is None)

        # The rescuer picks the amount: 15.
        row = ana.rpc("rescue", {"p_session": session, "p_to": ben.user, "p_amount": 15})
        row = row[0] if isinstance(row, list) else row
        check("a teammate can be rescued with a chosen amount", True)
        check("the reply is the rescuer's row, 15 lighter", row.get("gems") == 35, str(row))
        check("the teammate gains 15", gems(teacher, session, ben.user).get("gems") == 65,
              str(gems(teacher, session, ben.user)))
        check("the rescue is recorded", gems(teacher, session, ana.user).get("rescued_at") is not None)

        ok, why = refused(ana, session, dee.user, 1, "already used")
        check("ONE rescue per player", ok, why)
        dee.rpc("rescue", {"p_session": session, "p_to": ben.user, "p_amount": 5})
        check("a player can be rescued by more than one teammate",
              gems(teacher, session, ben.user).get("gems") == 70)

        # Paused by the teacher: no rescue.
        teacher.patch(f"sessions?id=eq.{session}", {"state": "paused", "remaining_s": 500})
        ok, why = refused(ben, session, ana.user, 5, "not running")
        check("no rescue while paused", ok, why)
        teacher.patch(f"sessions?id=eq.{session}", {"state": "running", "ends_at": ends})

        # Out of gems: cannot be rescued. Three skips from 45 is 0.
        for _ in range(3):
            dee.rpc("skip_item", {"p_session": session})
        check("dee is out", gems(teacher, session, dee.user).get("eliminated") is True,
              str(gems(teacher, session, dee.user)))
        ok, why = refused(ben, session, dee.user, 5, "already out")
        check("an eliminated teammate cannot be rescued", ok, why)

        # A phone cannot just write its own gems.
        try:
            ben.patch(f"members?session_id=eq.{session}&profile_id=eq.{ben.user}", {"gems": 999})
            wrote = gems(teacher, session, ben.user).get("gems") == 999
        except ApiError:
            wrote = False
        check("a player cannot write their own gems", not wrote)
    finally:
        teacher._call("DELETE", f"/rest/v1/sessions?id=eq.{session}")
        print("   test session deleted")

    print(f"---- RESCUE LIVE {'PASS' if failures == 0 else 'FAIL'} ---- {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
