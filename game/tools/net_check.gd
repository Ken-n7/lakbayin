extends Node

## How quick is the line to the server from here? Six small calls, timed: the
## first makes the connection, the rest go over it (HttpPool).
##   godot --headless --path game res://tools/net_check.tscn
## Against the server in project settings unless LAKBAYIN_SERVER_URL says
## another. Exit 0 if all six got through.

func _ready() -> void:
	var ok := 0
	for i in 6:
		var t0 := Time.get_ticks_msec()
		var got: Dictionary = await Net.rest(HTTPClient.METHOD_GET, "/health")
		var good: bool = got.error == "" and got.data is Dictionary and str(got.data.get("server", "")) == "lakbayin"
		ok += int(good)
		print("call %d: %4d ms  %s" % [i + 1, Time.get_ticks_msec() - t0, "ok" if good else str(got.error)])
	print("%s  %s  connections made %d, calls over a kept one %d" % ["NET PASS" if ok == 6 else "NET FAIL",
		Net.url, Net.pool.opened, Net.pool.reused])
	get_tree().quit(0 if ok == 6 else 1)
