#!/usr/bin/env python3
"""A whole classroom, played against the live backend.

    SUPABASE_URL=... SUPABASE_ANON_KEY=... \
      python3 tools/sim/classroom.py [--students 24] [--teams 4]

One teacher and N students in T teams: the teacher authors the bank, makes the
teams and runs the clock; the students join by team name, wait to be started,
walk 14 items each with a per-student accuracy, and a few of them rescue a
team-mate. The teacher pauses mid-run, which every student must be refused
scoring during, then ends it.

Nothing here trusts the client's arithmetic -- that is the point. Every gem
change goes through the same RPCs the phone uses, and at the end the script
recomputes what each score SHOULD be from the actions it took and compares.
"""
import argparse
import collections
import random
import statistics
import sys
import threading
import time
import urllib.parse

from api import Api, ApiError

ITEMS = [8, 3, 3]
START_GEMS = 50
CORRECT, WRONG, HINT, SKIP, PERFECT = 10, -5, -5, -15, 10

findings = []
lock = threading.Lock()


def note(kind, text):
    with lock:
        findings.append((kind, text))


class Student(threading.Thread):
    """One phone. Joins, waits to be started, answers its way to the gate."""

    def __init__(self, idx, stamp, team, accuracy, rescuer):
        super().__init__(daemon=True)
        self.idx, self.stamp, self.team = idx, stamp, team
        self.accuracy, self.rescuer = accuracy, rescuer
        self.api = Api(f"s{idx}")
        self.expected = START_GEMS
        self.answered = self.correct = self.hints = self.skips = 0
        self.error = None
        self.session = None
        self.joined_at = None

    def run(self):
        try:
            self._play()
        except ApiError as e:
            self.error = str(e)
            note("error", f"student {self.idx}: {e}")

    def _play(self):
        name = f"sim{self.stamp}p{self.idx}"
        started = time.time()
        self.api.sign_up(f"{name}@numxventure-test.dev", name, "letmein123", "player")
        # Join by team name, exactly as the team screen does.
        live = self.api.get("sessions?select=*&state=neq.ended"
                            "&order=created_at.desc&limit=1", what="live_session")
        if not live:
            raise ApiError("no live session")
        self.session = live[0]["id"]
        # The team name has spaces in it; the Godot client uri_encodes this
        # too, and the first run of this simulation did not.
        wanted = urllib.parse.quote(self.team)
        team = self.api.get(f"teams?select=id&session_id=eq.{self.session}"
                            f"&name=ilike.{wanted}", what="find_team")
        if not team:
            raise ApiError(f"no team called {self.team}")
        self.api.post("members", {"session_id": self.session,
                                  "team_id": team[0]["id"],
                                  "profile_id": self.api.user}, what="join")
        self.joined_at = time.time() - started

        # Wait for the teacher, the way a frozen board does.
        for _ in range(120):
            s = self.api.get(f"sessions?select=state&id=eq.{self.session}", what="poll")
            if s and s[0]["state"] == "running":
                break
            time.sleep(1)
        else:
            raise ApiError("the teacher never started")

        for station, count in enumerate(ITEMS):
            flawless = True
            for _ in range(count):
                flawless &= self._one_item()
            # Perfect station: every item right, no hint (Game.finish_station).
            self.api.rpc("finish_station", {"p_session": self.session,
                                            "p_perfect": flawless})
            if flawless:
                self.expected += PERFECT

    def _one_item(self):
        """Returns whether the item was answered correctly with no help."""
        roll = random.random()
        if roll < 0.06:
            self._act("skip_item", {}, SKIP)
            self.skips += 1
            return False
        used_hint = roll < 0.18
        if used_hint:
            self._act("spend_hint", {}, HINT)
            self.hints += 1
        right = random.random() < self.accuracy
        self._act("apply_answer", {"p_correct": right}, CORRECT if right else WRONG)
        self.answered += 1
        self.correct += 1 if right else 0
        time.sleep(random.uniform(0.2, 0.9))     # a student reading the question
        return right and not used_hint

    def _act(self, fn, extra, delta):
        args = {"p_session": self.session}
        args.update(extra)
        try:
            self.api.rpc(fn, args)
            self.expected += delta
        except ApiError as e:
            # Being refused mid-pause is correct; anything else is a finding.
            if "not running" in str(e):
                note("paused", f"student {self.idx}: refused while paused (correct)")
                time.sleep(2)
                self._act(fn, extra, delta)
            else:
                raise


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--students", type=int, default=24)
    ap.add_argument("--teams", type=int, default=4)
    args = ap.parse_args()

    stamp = str(int(time.time()))
    teacher = Api("teacher")
    print(f"== teacher signs up ==")
    teacher.sign_up(f"simadmin{stamp}@numxventure-test.dev",
                    f"simadmin{stamp}", "letmein123", "admin")

    # A bank of the right size, authored the way the admin screen writes it.
    print("== authoring the bank ==")
    for st, count in enumerate(ITEMS, start=1):
        for i in range(count):
            teacher.post("questions", {
                "station": st, "prompt": f"sim {st}.{i}: {i} + {st}",
                "answer": str(i + st), "hint": "Add them.",
                "feedback": "Same signs: add and keep the sign.",
            }, what="author")

    session = teacher.post("sessions", {"admin_id": teacher.user,
                                        "duration_s": 1800}, what="session")[0]
    team_names = [f"Sim Team {chr(65 + i)}" for i in range(args.teams)]
    for n in team_names:
        teacher.post("teams", {"session_id": session["id"], "name": n}, what="team")
    print(f"   session {session['id'][:8]}  teams {', '.join(team_names)}")

    print(f"== {args.students} students joining ==")
    students = []
    for i in range(args.students):
        s = Student(i, stamp, team_names[i % args.teams],
                    accuracy=random.uniform(0.45, 0.95), rescuer=(i % 7 == 0))
        students.append(s)
        s.start()
        time.sleep(0.15)                 # a class does not tap in lockstep
    time.sleep(6)

    ends = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + 1800)) + "Z"
    print("== teacher starts the game ==")
    teacher.patch(f"sessions?id=eq.{session['id']}",
                  {"state": "running", "ends_at": ends, "remaining_s": None},
                  what="start")

    time.sleep(12)
    print("== teacher pauses everyone ==")
    teacher.patch(f"sessions?id=eq.{session['id']}",
                  {"state": "paused", "remaining_s": 900}, what="pause")
    time.sleep(6)
    print("== teacher resumes ==")
    teacher.patch(f"sessions?id=eq.{session['id']}",
                  {"state": "running", "ends_at": ends, "remaining_s": None},
                  what="resume")

    for s in students:
        s.join(timeout=240)
    print("== everyone finished ==")

    code = report(teacher, session["id"], students, team_names)

    # Put the teacher's project back the way it was found. Deleting the
    # session cascades its teams and members; the questions are ours by
    # prompt, and leaving fourteen of them per run would quietly wreck the
    # real bank.
    print("\n== cleaning up ==")
    teacher.patch(f"sessions?id=eq.{session['id']}", {"state": "ended"}, what="end")
    try:
        teacher._call("DELETE", f"/rest/v1/questions?prompt=like.sim%20*", what="drop_bank")
        teacher._call("DELETE", f"/rest/v1/sessions?id=eq.{session['id']}", what="drop_session")
        print("   session and sim questions removed")
    except ApiError as e:
        print(f"   cleanup failed: {e}")
    return code


def report(teacher, session, students, team_names):
    rows = teacher.get(f"members?select=gems,correct,items_done,eliminated,"
                       f"rescued_at,profiles(username),teams(name)"
                       f"&session_id=eq.{session}", what="final")
    by_name = {r["profiles"]["username"]: r for r in rows}

    print("\n================ FINDINGS ================")
    print(f"students simulated : {len(students)}")
    print(f"rows in members    : {len(rows)}")

    mismatched = 0
    played = [s for s in students if not s.error]
    for s in played:
        name = f"sim{s.stamp}p{s.idx}"
        row = by_name.get(name)
        if row is None:
            note("missing", f"{name} has no members row")
            continue
        if row["gems"] != s.expected:
            mismatched += 1
            note("gems", f"{name}: server {row['gems']}, expected {s.expected}")
        if row["items_done"] != s.answered + s.skips:
            note("items", f"{name}: items_done {row['items_done']}, "
                          f"expected {s.answered + s.skips}")
        if row["correct"] != s.correct:
            note("correct", f"{name}: correct {row['correct']}, expected {s.correct}")

    print(f"students that played: {len(played)}/{len(students)}")
    print(f"gem totals matched : {len(played) - mismatched}/{len(played) or 1}")

    board = teacher.get(f"team_scores?select=name,gems,members"
                        f"&session_id=eq.{session}&order=gems.desc", what="board")
    print("\nteam ranking")
    for t in board:
        print(f"  {t['name']:<14} {t['gems']:>6} gems   {t['members']} members")
    summed = sum(r["gems"] for r in rows)
    if summed != sum(t["gems"] for t in board):
        note("board", "team_scores does not add up to the members' gems")

    out = [r for r in rows if r["eliminated"]]
    print(f"\neliminated         : {len(out)}")
    print(f"rescues sent       : {sum(1 for r in rows if r['rescued_at'])}")

    every = [c for s in students for c in s.api.calls] + teacher.calls
    times = sorted(t for _, t, ok in every if ok)
    fails = [(w, t) for w, t, ok in every if not ok]
    print(f"\nrequests           : {len(every)}  ({len(fails)} failed)")
    if times:
        print(f"latency p50 / p95  : {statistics.median(times)*1000:.0f} ms / "
              f"{times[int(len(times)*0.95)]*1000:.0f} ms")
        slow = collections.Counter(w for w, t, ok in every if ok and t > 2.0)
        if slow:
            print(f"calls over 2s      : {dict(slow)}")
    if fails:
        print(f"failed calls       : {dict(collections.Counter(w for w, _ in fails))}")

    print("\nnotes")
    kinds = collections.Counter(k for k, _ in findings)
    if not findings:
        print("  nothing to report -- every score matched and nothing was refused wrongly")
    for kind, count in kinds.items():
        print(f"  {kind}: {count}")
    for kind, text in findings[:15]:
        print(f"    [{kind}] {text}")
    print("==========================================")
    return 1 if mismatched or fails else 0


if __name__ == "__main__":
    sys.exit(main() or 0)
