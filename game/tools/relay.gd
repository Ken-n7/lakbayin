extends SceneTree

## The movement relay on its own (scripts/relay/RelayServer.gd):
##   godot --headless --path game --script res://tools/relay.gd -- [--hz 10] [--port 47317]
## Prints who is connected and the message rates every 5 seconds.
##
## --test-auth lets in any token "test:<id>" as <id>, member of every session --
## for tools/sim/relay_load.py on this machine only; refused with --bind other
## than 127.0.0.1 or with --url.
##
## --url wss://... publishes that address to Supabase's `relay` row, so phones
## find it, and refreshes it every PUBLISH_S -- while no other relay holds the
## row (the teacher's Game Controls standing in, RelayHost): a class is never
## split between two. --unpublish lets the row go, if it is this machine's,
## and quits (tools/relay/run.sh, when it stops). Both sign in as the admin in
## NUMX_RELAY_EMAIL / NUMX_RELAY_PASSWORD -- ~/.config/numxventure/relay.env,
## never the repo.

const PUBLISH_S := 60
## This relay, to the row: one per machine.
var relay_owner := "home:" + OS.get_unique_id().left(8)

func _initialize() -> void:
	_run.call_deferred()


func _arg(args: PackedStringArray, name: String, fallback: String) -> String:
	var i := args.find(name)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var url := _arg(args, "--url", "")
	if args.has("--unpublish"):
		if await _sign_in():
			var err: String = await root.get_node("Net").release_relay(relay_owner)
			print("unpublished" if err == "" else "unpublish failed: " + err)
		quit()
		return
	if url != "" and args.has("--test-auth"):
		print("--test-auth never with --url: anyone with the address would get in")
		quit(1)
		return
	if url != "" and not await _sign_in():
		quit(1)
		return
	var relay := RelayServer.new()
	relay.hz = int(_arg(args, "--hz", "10"))
	var bind := _arg(args, "--bind", "127.0.0.1")
	if args.has("--test-auth"):
		if bind != "127.0.0.1":
			print("--test-auth only on 127.0.0.1")
			quit(1)
			return
		relay.check = TestAuth.new()
		print("WARNING: test auth -- any token test:<id> gets in")
	root.add_child(relay)
	var err := relay.start(int(_arg(args, "--port", str(RelayServer.PORT))), bind)
	if err != "":
		print(err)
		quit(1)
		return
	print("relay on %s:%s, %d snapshots a second" % [bind, _arg(args, "--port", str(RelayServer.PORT)), relay.hz])
	var last := [0, 0, 0]
	var t := 0
	var held := "-"
	var was_busy := false
	while true:
		if url != "" and t % PUBLISH_S == 0:
			var got: String = await root.get_node("Net").claim_relay(relay_owner, url, relay.hz)
			if got != held:
				held = got
				print("published " + url if got == ""
					else "another relay holds the row; this one waits" if got == "held"
					else "publish failed (again in %ds): %s" % [PUBLISH_S, got])
		await create_timer(5.0).timeout
		t += 5
		# Every 5s while anyone is on it (and once after); idle, every 10
		# minutes -- an idle relay logged 17,000 lines a day.
		var busy: bool = relay.peer_count() > 0 or relay.msgs_in != int(last[0])
		if busy or was_busy or t % 600 == 0:
			print("t=%4d  peers %3d  rooms %2d  in %5.0f/s  out %6.0f/s  %6.1f KB/s out  denied %d" % [t,
				relay.peer_count(), relay.room_count(), (relay.msgs_in - last[0]) / 5.0,
				(relay.msgs_out - last[1]) / 5.0, (relay.bytes_out - last[2]) / 5120.0, relay.denied])
		was_busy = busy
		last = [relay.msgs_in, relay.msgs_out, relay.bytes_out]


func _sign_in() -> bool:
	var email := OS.get_environment("NUMX_RELAY_EMAIL")
	if email == "":
		print("NUMX_RELAY_EMAIL / NUMX_RELAY_PASSWORD not set (an admin account)")
		return false
	var err: String = await root.get_node("Net").sign_in(email, OS.get_environment("NUMX_RELAY_PASSWORD"))
	if err != "":
		print("sign in failed: ", err)
	return err == ""


class TestAuth:
	func who(token: String, _session: String, _role: String) -> String:
		return token.trim_prefix("test:") if token.begins_with("test:") else ""
