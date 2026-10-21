#!/usr/bin/env python3
"""Player rankings and History cards through real Godot HTTP/UI calls.

Run with python3 game/tools/test_rankings.py. A local HTTP fixture executes
the client's ordering as SQL; it never uses the live project or saved login.
"""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


PROJECT = Path(__file__).resolve().parents[1]
# session, profile, username, gems, finish seconds, items done, eliminated
MEMBERS = [
    ("screenshot", "1", "missu", 220, 258, 14, False),
    ("screenshot", "2", "nessa", 220, 260, 14, False),
    ("screenshot", "3", "kai", 220, 176, 14, False),
    ("screenshot", "4", "bibor", 180, 260, 14, False),
    ("screenshot", "5", "gsss", 180, 187, 14, False),
    ("screenshot", "6", "zia", 140, 193, 14, False),
    ("screenshot", "7", "shang", 140, None, 12, False),
    ("screenshot", "8", "last", 0, None, 6, True),
    ("edges", "01", "unfinished", 220, None, 10, False),
    ("edges", "02", "out", 220, None, 6, True),
    ("edges", "06", "same-b", 220, 176, 14, False),
    ("edges", "05", "same-a", 220, 176, 14, False),
    ("edges", "07", "slow", 220, 260, 14, False),
    ("edges", "08", "zero", 220, 0, 14, False),
    ("edges", "09", "more-gems", 300, 600, 14, False),
    ("edges", "10", "fewer-gems", 180, 1, 14, False),
    ("personal", "2", "finisher", 220, 176, 14, False),
    ("personal", "1", "personal-best", 230, None, 10, False),
    ("exact", "2", "second", 220, 176, 14, False),
    ("exact", "1", "first", 220, 176, 14, False),
    ("missing", "2", "unknown-second", 100, None, 10, False),
    ("missing", "1", "unknown-first", 100, None, 10, False),
    ("zero", "1", "later", 100, 10, 14, False),
    ("zero", "2", "zero-finish", 100, 0, 14, False),
    ("unfinished", "1", "still-playing", 220, None, 14, False),
    ("unfinished", "2", "finished", 220, 176, 14, False),
]
GROUPS = list(dict.fromkeys(row[0] for row in MEMBERS))
ERRORS = []


def ordered_members(group, order="", fields=None):
    clauses = []
    for term in order.split(",") if order else []:
        field, *options = term.split(".")
        assert field in {"gems", "finish_s", "profile_id"}, field
        assert set(options) <= {"asc", "desc", "nullslast", "nullsfirst"}
        direction = "DESC" if "desc" in options else "ASC"
        nulls = " NULLS LAST" if "nullslast" in options else " NULLS FIRST" if "nullsfirst" in options else ""
        clauses.append(f"{field} {direction}{nulls}")
    with sqlite3.connect(":memory:") as db:
        db.row_factory = sqlite3.Row
        db.execute("CREATE TABLE members (group_id TEXT, profile_id TEXT, username TEXT, gems INT, finish_s INT, items_done INT, eliminated BOOL)")
        db.executemany("INSERT INTO members VALUES (?, ?, ?, ?, ?, ?, ?)", MEMBERS)
        sql = "SELECT * FROM members WHERE group_id = ?"
        if clauses:
            sql += " ORDER BY " + ", ".join(clauses)
        rows = db.execute(sql, (group,)).fetchall()
    out = []
    for row in rows:
        member = dict(profile_id=row["profile_id"], profiles={"username": row["username"]},
                      gems=row["gems"], correct=14, items_done=row["items_done"],
                      finish_s=row["finish_s"], finished=row["finish_s"] is not None,
                      eliminated=bool(row["eliminated"]), sessions={"state": "ended"})
        # Honor the embedded projection, so a missing fetch field cannot be
        # hidden by a fixture that supplies more data than the real server.
        out.append({k: v for k, v in member.items() if fields is None or k in fields})
    return out


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        try:
            request = urlsplit(self.path)
            query = parse_qs(request.query)
            if request.path == "/rest/v1/members":
                group = query.get("session_id", query.get("team_id"))[0].removeprefix("eq.")
                if group == "error":
                    self.reply(403, {"message": "fixture refusal"})
                    return
                body = ordered_members(group, query["order"][0])
            elif request.path == "/rest/v1/sessions":
                assert query["admin_id"] == ["eq.teacher"]
                select = query["select"][0]
                fields = select.split("members(", 1)[1].rsplit(")", 1)[0].replace("profiles(username)", "profiles").split(",")
                body = [dict(id=group, created_at="2026-10-20T13:37:00Z",
                             ends_at="2026-10-20T13:42:00Z", ended_at="2026-10-20T13:42:00Z",
                             state="ended", remaining_s=0,
                             members=ordered_members(group, query.get("members.order", [""])[0], fields))
                        for group in GROUPS]
            elif request.path == "/rest/v1/team_scores":
                body = [dict(session_id=group, name="Team 3", gems=540) for group in GROUPS]
            else:
                raise AssertionError(request.path)
            self.reply(200, body)
        except Exception as error:
            ERRORS.append(repr(error))
            self.reply(500, {"message": str(error)})

    def reply(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


SCRIPT = '''extends Node
var failures := 0
var checks := 0
class MainStub extends Control:
    var opened: Array = []
    func open(what: String, data := {}) -> void:
        opened.append({"screen": what, "data": data})
func check(label: String, ok: bool) -> void:
    checks += 1
    if not ok:
        failures += 1
    print(("  ok    " if ok else "  FAIL  ") + label)
func names(rows: Array) -> Array:
    return rows.map(func(row: Dictionary) -> String: return row.username)
func _ready() -> void:
    Net.url = "http://127.0.0.1:PORT"
    Net.anon_key = "test"
    Net.access_token = "test"
    Net.user_id = "teacher"
    var shot: Array = await Board.players("screenshot")
    check("screenshot ranking: kai, missu, nessa", names(shot).slice(0, 3) == ["kai", "missu", "nessa"])
    var team: Dictionary = await Board.team_players("screenshot")
    check("team details use the same ranking", team.error == "" and names(team.rows).slice(0, 3) == ["kai", "missu", "nessa"])
    var edge: Array = await Board.players("edges")
    var expected := ["more-gems", "zero", "same-a", "same-b", "slow", "unfinished", "out", "fewer-gems"]
    check("gems first, fastest next, exact ties stable, missing times last", names(edge) == expected)
    team = await Board.team_players("edges")
    check("team details handle all tie cases", team.error == "" and names(team.rows) == expected)
    check("missing finish time remains -1", edge.size() == 8 and edge[5].finish_s == -1)
    check("zero seconds is a valid finish time", edge.size() == 8 and edge[1].finish_s == 0)
    var screen: Control = load("res://scripts/LeaderboardScreen.gd").new()
    add_child(screen)
    var list := VBoxContainer.new()
    screen.add_child(list)
    screen.set("_list", list)
    screen.set("_sid", "screenshot")
    await screen._fill_players()
    for i in 3:
        var cells: Array = list.get_child(i + 1).get_children().map(func(label: Label) -> String: return label.text)
        var expected_row: Array = [["1", "kai", "220", "14", "02:56"], ["2", "missu", "220", "14", "04:18"], ["3", "nessa", "220", "14", "04:20"]][i]
        check("displayed screenshot row %d" % (i + 1), cells == expected_row)
    check("DNF still displays correctly", screen._time_of({"finish_s": -1, "eliminated": false, "over": true}) == "DNF")
    check("eliminated still displays Out", screen._time_of({"finish_s": -1, "eliminated": true, "over": true}) == "Out")
    check("in-progress still displays a dash", screen._time_of({"finish_s": -1, "eliminated": false, "over": false}) == "—")
    check("empty player list", (await Board.players("empty")).is_empty())
    team = await Board.team_players("empty")
    check("empty team list", team.error == "" and team.rows.is_empty())
    check("player query failure returns no rows", (await Board.players("error")).is_empty())
    team = await Board.team_players("error")
    check("team query failure preserves its error", team.error != "" and team.rows.is_empty())
    screen.free()

    var history: Control = load("res://scripts/HistoryScreen.gd").new()
    var main := MainStub.new()
    history.main = main
    add_child(history)
    list = VBoxContainer.new()
    history.add_child(list)
    history.set("_list", list)
    await history._load()
    await get_tree().process_frame
    check("History loaded every played session", list.get_child_count() == 7)
    var expected_winners := ["kai · 220", "more-gems · 300", "personal-best · 230", "first · 220", "unknown-first · 100", "zero-finish · 100", "finished · 220"]
    for i in expected_winners.size():
        var card := list.get_child(i)
        var winner: String = card.get_child(0).get_child(2).get_child(1).text
        check("History winner: " + expected_winners[i], winner == expected_winners[i])
    var photo_row := list.get_child(0).get_child(0)
    check("History keeps the top team and its score", photo_row.get_child(1).get_child(1).text == "Team 3 · 540")
    check("History keeps all eight players and the end reason", photo_row.get_child(0).get_child(1).text == "Time's up · 8 played")
    list.get_child(0).pressed.emit()
    check("History opens this game's full results", main.opened == [{"screen": "board", "data": {"session": "screenshot", "title": "Results · " + history._when({"created_at": "2026-10-20T13:37:00Z"}), "back": "history", "live": false}}])
    history.free()
    main.free()
    print("---- RANKINGS %s ---- %d checks, %d failures" % ["PASS" if failures == 0 else "FAIL", checks, failures])
    get_tree().quit(0 if failures == 0 else 1)
'''


def main():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="numxventure-rankings-") as folder:
                root = Path(folder)
                script = root / "rankings.gd"
                script.write_text(SCRIPT.replace("PORT", str(server.server_port)))
                scene = root / "rankings.tscn"
                scene.write_text('[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="' + str(script) + '" id="1"]\n[node name="RankingsTest" type="Node"]\nscript = ExtResource("1")\n')
                env = dict(os.environ, XDG_DATA_HOME=str(root / "user-data"))
                result = subprocess.run(["godot", "--headless", "--path", str(PROJECT), str(scene)],
                                        env=env, text=True, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=60)
                print(result.stdout, end="")
                if ERRORS:
                    print("Fixture errors:", ERRORS)
                return int(result.returncode != 0 or bool(ERRORS) or "SCRIPT ERROR" in result.stdout
                           or "---- RANKINGS PASS ----" not in result.stdout)
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    raise SystemExit(main())
