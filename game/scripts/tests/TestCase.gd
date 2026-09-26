class_name TestCase
extends Node

## What the three scene suites share: the check counter, the save-file backup,
## and the verdict.
##
## The verdict is the point. A suite used to print PASS after a `SCRIPT ERROR`
## killed it mid-run -- an aborted coroutine unwinds to its caller, which then
## reports on however few checks it managed. `e2e_test` sat at 12 of its 267
## for a while, green the whole time, and `test_collisions` erred on every run
## and still exited 0. `finish()` refuses to pass a suite that did not reach
## its own last line.

var failures := 0
var checks := 0

## Set by the suite as its final act, just before `finish()`. Anything that
## stops it early leaves this false.
var completed := false

var _save_backup: PackedByteArray = []
var _session_backup: PackedByteArray = []


func check(name: String, condition: bool, detail := "") -> void:
	checks += 1
	if condition:
		print("  ok    ", name)
	else:
		failures += 1
		print("  FAIL  ", name, "  ", detail)


## The suites write to the real save file, so the profile on this machine has to
## survive them.
func backup_save() -> void:
	if FileAccess.file_exists(Game.SAVE_PATH):
		var f := FileAccess.open(Game.SAVE_PATH, FileAccess.READ)
		_save_backup = f.get_buffer(f.get_length())
		f.close()
	# A signed-in session left behind by one of the live tools would make the
	# splash wait on a token refresh before routing, and these suites are
	# offline by design. Taken away for the run, put back afterwards.
	if FileAccess.file_exists(Net.SESSION_PATH):
		var g := FileAccess.open(Net.SESSION_PATH, FileAccess.READ)
		_session_backup = g.get_buffer(g.get_length())
		g.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(Net.SESSION_PATH))


func restore_save() -> void:
	if _session_backup.size() > 0:
		var g := FileAccess.open(Net.SESSION_PATH, FileAccess.WRITE)
		g.store_buffer(_session_backup)
		g.close()
	if _save_backup.size() > 0:
		var f := FileAccess.open(Game.SAVE_PATH, FileAccess.WRITE)
		f.store_buffer(_save_backup)
		f.close()


func finish(label: String) -> void:
	restore_save()
	if not completed:
		failures += 1
		print("  FAIL  suite aborted before its last line — see the SCRIPT ERROR above")
	var verdict := "PASS" if failures == 0 else "FAIL"
	print("---- %s %s ---- %d checks, %d failures" % [label, verdict, checks, failures])
	get_tree().quit(0 if failures == 0 else 1)
