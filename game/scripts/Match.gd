class_name Match
extends RefCounted

## One match's state, apart from anything drawn (DESIGN.md 3): the monks'
## words, which of them your team has, what you carry, and the deposits.
##
## Two kinds, one interface. **Practice** is offline and alone: the words come
## from the bundled list, `Baybayin.matches` checks an answer, and everything
## happens here. **Online** the server decides (schema 4e): an answer goes to
## `Monks.answer`, a deposit to `Monks.deposit`, and the team's rows come back
## from `monk_answers`, read once and then kept current off the socket
## (`take_row`) -- a teammate's answer greys that monk out for you too.

signal changed

## The sides' colours: the art's names for them (Blue_House, a Red monk...).
const TEAMS := ["Blue", "Red"]
## What players read: the Filipino names. The server names a match's teams
## the same (server/app.py), so lobby, results and records agree.
const NAMES := ["Bughaw", "Pula"]

var practice := true
var session_id := ""
var seed := 1
## Monk i's word: {word, meaning, modern, traditional}.
var words: Array = []
## 0 Blue, 1 Red: which side this player is on, and the two teams' ids online.
var team := 0
var team_ids: Array[String] = []
## (team index, monk) -> {profile_id, deposited}: every answer either team has.
var answers := {}
## When this player's last deposit went in, seconds into the match.
var reached_s := -1.0
## Seconds into the match when each team reached its total; -1 none yet.
var team_reached_s := [-1.0, -1.0]
## The team that deposited every word, or -1.
var winner := -1


# --- Asking -----------------------------------------------------------------
func monk_count() -> int:
	return words.size()


## Has my team answered monk `m` (carried by one of us, or deposited)?
func ours(m: int) -> bool:
	return answers.has(Vector2i(team, m))


## The monks I carry, answered and not yet deposited.
func carried() -> Array[int]:
	var out: Array[int] = []
	for k: Vector2i in answers:
		var a: Dictionary = answers[k]
		if k.x == team and str(a.profile_id) == _me() and not bool(a.deposited):
			out.append(k.y)
	out.sort()
	return out


## Deposited words: a team's, and this player's own.
func deposited(of_team := -1) -> int:
	var t := team if of_team < 0 else of_team
	var n := 0
	for k: Vector2i in answers:
		if k.x == t and bool(answers[k].deposited):
			n += 1
	return n


func my_deposits() -> int:
	var n := 0
	for k: Vector2i in answers:
		if k.x == team and str(answers[k].profile_id) == _me() and bool(answers[k].deposited):
			n += 1
	return n


func _me() -> String:
	return "me" if practice else Net.user_id


# --- Practice ---------------------------------------------------------------
func start_practice(match_seed: int, n: int) -> void:
	practice = true
	seed = match_seed
	var rng := RandomNumberGenerator.new()
	rng.seed = match_seed
	words = Baybayin.draw(n, rng)
	team = 0
	answers.clear()


# --- Online -----------------------------------------------------------------
## The match's words, its teams, which one is mine, and every answer so far
## (a rejoin picks up where it was). "" or what went wrong.
func start_online(session: String) -> String:
	practice = false
	session_id = session
	seed = Game.seed_of(session)
	words = await Monks.words_of(session)
	if words.is_empty():
		return "The match's words did not arrive"
	team_ids.clear()
	for t: Dictionary in await Teams.teams_of(session):
		team_ids.append(str(t.get("id", "")))
	var mine: Dictionary = await Teams.membership(session)
	if mine.has("error"):
		return str(mine.error)
	team = maxi(team_ids.find(str(mine.get("team_id", ""))), 0)
	return await reload()


## Every answer in the match, read again: on start, and when the socket comes
## back from a drop and may have missed some.
func reload() -> String:
	var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET,
		"/rest/v1/monk_answers?select=team_id,monk,profile_id,deposited_at&session_id=eq." + session_id)
	if got.error != "":
		return got.error
	answers.clear()
	for row: Dictionary in (got.data if got.data is Array else []):
		take_row("INSERT", row, false)
	changed.emit()
	return ""


## A row off the socket, or from a read.
func take_row(type: String, row: Dictionary, tell := true) -> void:
	if type == "DELETE" or not row.has("monk"):
		return
	var t := team_ids.find(str(row.get("team_id", "")))
	if t < 0:
		return
	answers[Vector2i(t, int(row.monk))] = {"profile_id": str(row.get("profile_id", "")),
		"deposited": row.get("deposited_at") != null}
	if tell:
		changed.emit()


# --- Playing ----------------------------------------------------------------
## Writes `typed` at monk `m`: "correct", "wrong", "locked", "taken" or
## "error: ...". Practice decides here; online the server does.
func answer(m: int, typed: String) -> String:
	if ours(m):
		return "taken"
	if practice:
		if not Baybayin.matches(typed, words[m]):
			return "wrong"
		answers[Vector2i(team, m)] = {"profile_id": _me(), "deposited": false}
		changed.emit()
		return "correct"
	var result: String = await Monks.answer(session_id, m, typed)
	if result == "correct":
		# The socket will say so too; shown at once rather than after it.
		answers[Vector2i(team, m)] = {"profile_id": _me(), "deposited": false}
		changed.emit()
	return result


## Deposits everything carried, at `elapsed_s` into the match. {error, deposited}.
func deposit(elapsed_s: float) -> Dictionary:
	var mine := carried()
	if mine.is_empty():
		return {"error": "", "deposited": 0}
	if not practice:
		var got: Dictionary = await Monks.deposit(session_id)
		if got.error != "":
			return got
	for m in mine:
		answers[Vector2i(team, m)].deposited = true
	reached_s = elapsed_s
	team_reached_s[team] = elapsed_s
	if deposited() >= monk_count():
		winner = team
	changed.emit()
	return {"error": "", "deposited": mine.size()}


## What the results screen shows: who won and why, the totals, and every word.
func result(time_up: bool) -> Dictionary:
	var words_out: Array = []
	for i in words.size():
		var w: Dictionary = words[i]
		var k := Vector2i(team, i)
		var state := "missed"
		if answers.has(k):
			state = "deposited" if bool(answers[k].deposited) else "lost"
		words_out.append({"word": w.get("word", ""), "meaning": w.get("meaning", ""),
			"modern": w.get("modern", ""), "state": state})
	return {
		"practice": practice,
		"session_id": session_id,
		"team": team,
		"winner": winner,
		"time_up": time_up,
		"deposited": [deposited(0), deposited(1)],
		"monks": monk_count(),
		"my_deposits": my_deposits(),
		"reached_s": reached_s,
		"words": words_out,
	}
