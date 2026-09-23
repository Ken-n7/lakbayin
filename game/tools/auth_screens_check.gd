extends Node

## Drives the real login screen against a real project: registers an account,
## signs out, then types into the form and presses the button the way a player
## would. Same env vars and same caveat as `supabase_check.gd` -- network only.
##
##   SUPABASE_URL=... SUPABASE_ANON_KEY=... \
##     godot --headless --path game res://tools/auth_screens.tscn
##
## A scene and not a --script: autoloads are only registered when the project
## boots normally, and these screens call `Net`.

var _failures := 0


func _ready() -> void:
	await get_tree().process_frame
	if not Net.configured():
		print("SKIP  SUPABASE_URL / SUPABASE_ANON_KEY not set")
		get_tree().quit(0)
		return

	var stamp := str(int(Time.get_unix_time_from_system()))
	var email := "screens-" + stamp + "@numxventure-test.dev"
	var pw := "letmein123"

	_check("register through the client", await Net.sign_up(email, "sc" + stamp, pw, "player"))
	_check("profile name loaded", "" if Net.username == "sc" + stamp else "got '%s'" % Net.username)
	_check("role loaded", "" if Net.role == "player" else "got '%s'" % Net.role)

	Net.sign_out()
	_check("sign_out clears the session", "" if not Net.signed_in() else "still signed in")

	var main: Control = load("res://scripts/Main.gd").new()
	get_tree().root.add_child(main)
	await get_tree().process_frame
	_check("splash gates on sign-in",
		"" if main.current.get_script().resource_path.ends_with("SplashScreen.gd")
		else "opened %s" % main.current.get_script().resource_path)
	main.current.skip()
	await get_tree().process_frame
	var login: Control = main.current
	_check("splash -> login when signed out",
		"" if login.get_script().resource_path.ends_with("LoginScreen.gd")
		else "opened %s" % login.get_script().resource_path)

	# Wrong password first: the form must report, not crash or navigate.
	login._email.text = email
	login._pass.text = "wrongpassword"
	await login._submit()
	_check("bad password keeps you on the form",
		"" if main.current == login else "navigated away on a failed sign-in")
	_check("bad password says so", "" if login._msg.text != "" else "no message shown")

	login._email.text = email
	login._pass.text = pw
	await login._submit()
	await get_tree().process_frame
	_check("good password signs in", "" if Net.signed_in() else "no session")
	_check("lands on the home screen",
		"" if main.current.get_script().resource_path.ends_with("HomeScreen.gd")
		else "opened %s" % main.current.get_script().resource_path)
	_check("name survives into the session",
		"" if Net.username == "sc" + stamp else "got '%s'" % Net.username)

	print("---- AUTH SCREENS %s ----" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _check(name: String, err: String) -> void:
	if err == "":
		print("  ok    ", name)
	else:
		_failures += 1
		print("  FAIL  ", name, "  ", err)
