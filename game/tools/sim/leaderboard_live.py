#!/usr/bin/env python3
"""The players' Leaderboards, against the live project.

    SUPABASE_URL=... SUPABASE_ANON_KEY=... python3 tools/sim/leaderboard_live.py

A teacher runs a short game -- Reds (ana, ben) and Blues (cal) -- and ends
it; then a player from outside that game reads `public.team_results`, the
same view and query the phone's board uses (`Board.all_time`), and taps into
a team (`Board.team_players`). The session is deleted at the end, so the test
game never stays on the real board; the accounts stay in Auth (deleting those
needs the service key), all @numxventure-test.dev.
"""
import sys
import time

from api import Api

BOARD = ("team_results?select=team_id,session_id,name,gems,members,game_no,played_at,player_ids"
         "&order=gems.desc,game_no.asc&limit=500")
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok else f"   <{detail}>"))
    if not ok:
        failures += 1


def mine(rows, session):
    return [r for r in rows if r["session_id"] == session]


def main():
    stamp = str(int(time.time()))
    teacher = Api("teacher")
    check("teacher signs up", teacher.sign_up(f"lbadmin{stamp}@numxventure-test.dev",
                                               f"lba{stamp}", "letmein123", "admin"))
    session = teacher.post("sessions", {"admin_id": teacher.user, "duration_s": 600})[0]["id"]
    teams = {n: teacher.post("teams", {"session_id": session, "name": n})[0]["id"]
             for n in ["Reds", "Blues", "Empty"]}
    players = {}
    for who, team in [("ana", "Reds"), ("ben", "Reds"), ("cal", "Blues")]:
        p = Api(who)
        check(f"{who} signs up", p.sign_up(f"lb{who}{stamp}@numxventure-test.dev",
                                           f"lb{who}{stamp}", "letmein123", "player"))
        p.post("members", {"session_id": session, "team_id": teams[team], "profile_id": p.user})
        players[who] = p
    ana, ben, cal = players["ana"], players["ben"], players["cal"]
    outsider = Api("dee")
    check("an outsider signs up", outsider.sign_up(f"lbdee{stamp}@numxventure-test.dev",
                                                   f"lbdee{stamp}", "letmein123", "player"))

    try:
        check("a game still in the lobby is not on the board", mine(outsider.get(BOARD), session) == [])
        ends = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 600)) + "Z"
        teacher.patch(f"sessions?id=eq.{session}", {"state": "running", "ends_at": ends})
        # ana and cal each skip one item: the gems move on the server.
        ana.rpc("skip_item", {"p_session": session})
        cal.rpc("skip_item", {"p_session": session})
        check("a game being played is not on the board", mine(outsider.get(BOARD), session) == [])

        teacher.patch(f"sessions?id=eq.{session}", {"state": "ended"})
        rows = outsider.get(BOARD)
        ours = mine(rows, session)
        names = [r["name"] for r in ours]
        check("once ended, its teams are on the board, read by a player from outside it",
              sorted(names) == ["Blues", "Reds"], str(ours))
        check("the team nobody played for is left out", "Empty" not in names)
        reds = next((r for r in ours if r["name"] == "Reds"), {})
        blues = next((r for r in ours if r["name"] == "Blues"), {})
        check("Reds: 2 players, both listed", reds.get("members") == 2
              and sorted(reds.get("player_ids", [])) == sorted([ana.user, ben.user]), str(reds))
        check("the whole board is best first",
              [r["gems"] for r in rows] == sorted((r["gems"] for r in rows), reverse=True))
        check("each team has its game number and date", isinstance(reds.get("game_no"), int)
              and reds.get("game_no") == blues.get("game_no") and bool(reds.get("played_at")), str(reds))
        print(f"   board now: {len(rows)} teams; this game is Game {reds.get('game_no')}, "
              f"Reds {reds.get('gems')}, Blues {blues.get('gems')}")

        # Tapping Reds: the phone's own query.
        team = outsider.get(f"members?select=profile_id,gems,correct,items_done,finish_s,eliminated,"
                            f"profiles(username)&team_id=eq.{teams['Reds']}&order=gems.desc")
        who = sorted(m["profiles"]["username"] for m in team if m.get("profiles"))
        check("tapping a team shows who played for it, by name",
              who == sorted([f"lbana{stamp}", f"lbben{stamp}"]), str(team))
        # Its score adds up the way the panel explains it.
        total = (sum(m["gems"] for m in team) - 50 * sum(1 for m in team if m["eliminated"])
                 - 25 * sum(1 for m in team if m["items_done"] < 14))
        check("the team's score adds up as the panel shows it", total == reds.get("gems"),
              f"{total} vs {reds.get('gems')}")
    finally:
        teacher._call("DELETE", f"/rest/v1/sessions?id=eq.{session}")
        left = mine(outsider.get(BOARD), session)
        check("test game deleted: gone from the board", left == [], str(left))

    print(f"---- LEADERBOARD LIVE {'PASS' if failures == 0 else 'FAIL'} ---- {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
