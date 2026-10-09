class_name RelayHost
extends Node

## The teacher's laptop hosts its own class's relay (SPECS §10, Movement;
## client, 2026-10-09: the home laptop cannot be counted on, the teacher's is
## there whenever a class is). While Game Controls has a session this runs a
## RelayServer and a Cloudflare quick tunnel to it, and puts the address on
## that session (host_relay, schema 7d), refreshed every CHECK_S, so that
## class's phones come here. Should it fail -- no cloudflared, a crash, the
## internet down -- the address goes stale and the class falls back to the
## home relay if it is on, else to the hub. The session over, it lets go.
##
## Needs cloudflared: beside the game (cloudflared.exe on Windows) or on the
## PATH (winget install --id Cloudflare.cloudflared). Without it this stays
## idle, and the class moves on the home relay or the hub.

const CHECK_S := 30.0
const HZ := 20
const PORT := RelayServer.PORT + 1      # not the home relay's: tests run both on one machine
const TUNNEL_WAIT_S := 30
const PID_FILE := "user://cloudflared.pid"     # the tunnel's process, while it runs

## Off where nobody should host: phones, and headless runs (tests, tools).
static var enabled := OS.has_feature("pc") and DisplayServer.get_name() != "headless"

var state := "standby"         # standby | starting | serving | no cloudflared -- the dev panel shows it
var url := ""                  # wss://, while serving
var session_id := ""           # the class this hosts, set by Game Controls
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
	if session_id == "":
		return
	if state == "serving":
		if not OS.is_process_running(_tunnel):
			print("class relay: the tunnel stopped")
			_stop()                     # its address goes stale; the next check starts afresh
			return
		var stale: String = await _net().host_relay(session_id, url, HZ)
		if stale != "":
			print("class relay: address not refreshed (%s)" % stale)   # tried again next check
		return
	var cf := cloudflared()
	if cf == "":
		state = "no cloudflared"
		return
	state = "starting"
	var err := await _start(cf)
	if err == "":
		err = await _net().host_relay(session_id, url, HZ)
	if err != "":
		print("class relay: not started (%s)" % err)
		_stop()
		return
	state = "serving"
	print("class relay: serving at ", url)


## A relay on PORT and a tunnel to it: "" once the tunnel is up, or why not.
func _start(cf: String) -> String:
	_relay = RelayServer.new()
	_relay.hz = HZ
	add_child(_relay)
	var err := _relay.start(PORT)
	if err != "":
		return err
	end_leftover()
	DirAccess.remove_absolute(_log)
	_tunnel = OS.create_process(cf, ["tunnel", "--no-autoupdate", "--logfile", _log,
		"--url", "http://127.0.0.1:%d" % PORT])
	if _tunnel <= 0:
		return "cloudflared would not start"
	var f := FileAccess.open(PID_FILE, FileAccess.WRITE)
	if f != null:
		f.store_string(str(_tunnel))
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


## The tunnel a Game Controls left running when it crashed or was ended
## from the task manager: nothing else stops it. Only a cloudflared: after a
## restart of the computer the number can be another program's.
static func end_leftover(pid_file := PID_FILE) -> void:
	var pid := FileAccess.get_file_as_string(pid_file).to_int()
	if pid > 0 and is_cloudflared(pid):
		OS.kill(pid)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(pid_file))


static func is_cloudflared(pid: int) -> bool:
	var out := []
	if OS.has_feature("windows"):
		OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/NH"], out)
	else:
		OS.execute("ps", ["-p", str(pid), "-o", "comm="], out)
	return "cloudflared" in "".join(PackedStringArray(out)).to_lower()


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
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PID_FILE))
	if _relay != null:
		_relay.stop()
		_relay.queue_free()
		_relay = null
	url = ""
	if state != "no cloudflared":
		state = "standby"


## The session is over, or Game Controls is going: the class's address goes,
## and the tunnel and relay stop.
func stop() -> void:
	if state == "serving" and session_id != "":
		_net().unhost_relay(session_id)          # not awaited: it finishes on its own
	_stop()


func _exit_tree() -> void:
	stop()


## Looked up, not named: the relay test loads this before the autoloads.
func _net() -> Node:
	return get_node("/root/Net")
