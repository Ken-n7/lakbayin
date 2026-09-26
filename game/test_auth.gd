extends SceneTree

## Self-check for local accounts. Run:
##   godot --headless --path game --script res://test_auth.gd
##
## Writes to its own file, not `user://accounts.cfg`, so a run cannot wipe
## whatever accounts exist on this machine.

const TEST_PATH := "user://test_accounts.cfg"

func _init() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	var A := load("res://scripts/AuthStore.gd")
	var auth = A.new(TEST_PATH)

	assert(auth.register("mayorga8", "letmein123", "player") == "", "valid registration lands")
	assert(auth.register("MAYORGA8", "other12345", "admin") != "", "username unique regardless of case")
	assert(auth.register("shorty", "1234567", "player") != "", "7-char password refused")
	assert(auth.register("shorty", "12345678", "player") == "", "8 characters is the floor")
	assert(auth.register("teach", "letmein123", "wizard") != "", "unknown role refused")
	assert(auth.register("a b", "letmein123", "player") != "", "spaces refused in a username")
	assert(auth.register("ok", "letmein123", "player") != "", "2 chars is too short a username")

	# Roles round-trip, and the login is case-insensitive like the uniqueness check.
	assert(auth.register("teacher1", "letmein123", "admin") == "", "admin registers")
	assert(auth.login("teacher1", "letmein123").role == "admin", "role survives the save")
	assert(auth.login("Mayorga8", "letmein123").role == "player", "login ignores case")
	assert(auth.login("mayorga8", "letmein123").name == "mayorga8", "display name kept as typed")

	assert(auth.login("mayorga8", "letmein124").is_empty(), "wrong password refused")
	assert(auth.login("nobody", "letmein123").is_empty(), "unknown username refused")

	# A second store over the same file sees the first one's accounts.
	var reopened = A.new(TEST_PATH)
	assert(reopened.login("mayorga8", "letmein123").role == "player", "accounts persist")

	# The point of the salt+hash: nothing readable is written down.
	var f := FileAccess.open(TEST_PATH, FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	assert(not raw.contains("letmein123"), "password never appears in the save file")
	assert(raw.contains("hash="), "a hash does")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	print("test_auth: all assertions passed")
	quit()
