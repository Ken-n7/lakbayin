class_name RelayHost
extends Node

## The teacher's laptop as the home relay's backup (SPECS §10, Movement).
## While Game Controls has a session, this looks at Supabase's `relay` row
## every CHECK_S. When no relay holds it -- the home laptop off, or its
## internet down for 3 minutes -- it starts one here, a RelayServer and a
## Cloudflare quick tunnel to it, and takes the row (claim_relay, schema 7b),
## so the phones' next retry finds it. It keeps the row while the session
## lasts and lets it go after. A relay still refreshing the row is never
## replaced, so a class is never split between two.
##
## Needs cloudflared: beside the game (cloudflared.exe on Windows) or on the
## PATH (winget install --id Cloudflare.cloudflared). Without it this stays
## idle, and phones move through the hub as they would anyway.

const CHECK_S := 30.0
const HZ := 20
const PORT := RelayServer.PORT + 1      # not the home relay's: tests run both on one machine
const TUNNEL_WAIT_S := 30

## Off where nobody should host: phones, and headless runs (tests, tools).
static var enabled := OS.has_feature("pc") and DisplayServer.get_name() != "headless"

var state := "standby"         # standby | starting | serving | no cloudflared -- the dev panel shows it
var url := ""                  # wss://, while serving
var relay_owner := "game-controls:" + OS.get_unique_id().left(8)
var _relay: RelayServer = null
var _tunnel := 0               # cloudflared's process id
var _log := ProjectSettings.globalize_path("user://cloudflared.log")
var _next := 0.0
var _busy := false


func _ready() -> void:
	add_to_group("relay_host")


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not enabled or _busy or now < _next:
		return
	_next = now + CHECK_S
	_busy = true
	await _check()
	_busy = false


func _check() -> void:
	if state == "serving":
		if not OS.is_process_running(_tunnel):
			print("backup relay: the tunnel stopped")
			_stop()                     # the row goes stale; a later check starts afresh
		elif await _net().claim_relay(relay_owner, url, HZ) == "held":
			print("backup relay: another relay has the row")
			_stop()                     # ours went stale meanwhile; never two at once
		return
	if await _net().relay().published() != "":
		return                          # the home relay (or another) is up
	var cf := cloudflared()
	if cf == "":
		state = "no cloudflared"
		return
	state = "starting"
	var err := await _start(cf)
	if err == "":
		err = await _net().claim_relay(relay_owner, url, HZ)
	if err != "":
		print("backup relay: not started (%s)" % err)
		_stop()
		return
	state = "serving"
	print("backup relay: serving at ", url)


## A relay on PORT and a tunnel to it: "" once the tunnel is up, or why not.
func _start(cf: String) -> String:
	_relay = RelayServer.new()
	_relay.hz = HZ
	add_child(_relay)
	var err := _relay.start(PORT)
	if err != "":
		return err
	DirAccess.remove_absolute(_log)
	_tunnel = OS.create_process(cf, ["tunnel", "--no-autoupdate", "--logfile", _log,
		"--url", "http://127.0.0.1:%d" % PORT])
	if _tunnel <= 0:
		return "cloudflared would not start"
	for i in TUNNEL_WAIT_S:
		await get_tree().create_timer(1.0).timeout
		var text := FileAccess.get_file_as_string(_log)
		if "Registered tunnel connection" in text and address_in(text) != "":
			url = address_in(text)
			return ""
	return "no tunnel after %ds" % TUNNEL_WAIT_S


## The quick tunnel's address in cloudflared's log, as wss://, or "".
static func address_in(text: String) -> String:
	var m := RegEx.create_from_string("https://([a-z0-9-]+\\.trycloudflare\\.com)").search(text)
	return "wss://" + m.get_string(1) if m != null else ""


## cloudflared beside the game, on the PATH, or where winget puts it; "".
static func cloudflared() -> String:
	var win := OS.has_feature("windows")
	var exe := "cloudflared.exe" if win else "cloudflared"
	var dirs: Array = [OS.get_executable_path().get_base_dir()]
	dirs.append_array(OS.get_environment("PATH").split(";" if win else ":", false))
	if win:
		dirs.append(OS.get_environment("ProgramFiles(x86)").path_join("cloudflared"))
	for d: String in dirs:
		var at := d.path_join(exe)
		if d != "" and FileAccess.file_exists(at):
			return at.replace("/", "\\") if win else at
	return ""


func _stop() -> void:
	if _tunnel > 0:
		OS.kill(_tunnel)
		_tunnel = 0
	if _relay != null:
		_relay.stop()
		_relay.queue_free()
		_relay = null
	url = ""
	if state != "no cloudflared":
		state = "standby"


## The session is over, or Game Controls is going: the row goes back for the
## home relay to take at once, and the tunnel and relay stop.
func stop() -> void:
	if state == "serving":
		_net().release_relay(relay_owner)        # not awaited: it finishes on its own
	_stop()


func _exit_tree() -> void:
	stop()


## Looked up, not named: the relay test loads this before the autoloads.
func _net() -> Node:
	return get_node("/root/Net")
