extends Node
var index := 0
var main: Control
var started := 0.0
var answered := false
var deposited := false
var seen := false
var moved := false
var delay := -1.0
var finishing := false
var test_file := OS.get_environment("LAKBAYIN_TEST_INFO")
var output_dir := OS.get_environment("LAKBAYIN_TEST_OUTPUT")
func _ready() -> void:
	Engine.max_fps = 60
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--player="): index=int(arg.trim_prefix("--player="))
	var info:Dictionary=JSON.parse_string(FileAccess.get_file_as_string(test_file))
	var account:Dictionary=info.accounts[index]
	var error:=await Net.sign_in(account.username,account.password)
	if error!="":push_error(error);get_tree().quit(1);return
	Game.joined_session=info.session
	Game.joined_code=info.code
	main=load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	main.open("adventure")
	started=Time.get_unix_time_from_system()
func _process(delta:float) -> void:
	if main==null:return
	var screen:Control=main.current
	if screen.get_script().resource_path.ends_with("ResultsScreen.gd"):
		var words: Array = screen.result.get("words", [])
		if words.size() != 10 or words.any(func(w: Dictionary) -> bool: return str(w.get("modern", "")) == ""):
			return
		var output:={"player":index,"peer_seen":seen,"movement_received":moved,"playback_buffer":delay,"seed":Game.seed_of(str(screen.result.session_id)),"results":true,"words":words.size(),"deposited_blue":int(screen.result.deposited[0]),"deposited_red":int(screen.result.deposited[1])}
		var file:=FileAccess.open(output_dir.path_join("client-%d.json"%index),FileAccess.WRITE)
		file.store_string(JSON.stringify(output))
		Net.realtime().close_socket()
		Net.relay().leave()
		get_tree().quit(0 if seen and moved else 1)
		return
	if not screen.get_script().resource_path.ends_with("AdventureScreen.gd") or screen.get("hud")==null:return
	screen.skip_intro()
	var elapsed:=Time.get_unix_time_from_system()-started
	if index==0 and elapsed<7.0:
		Input.action_press("move_right")
	else:Input.action_release("move_right")
	if screen._peers!=null:
		for id:String in screen._peers.get("_markers"):
			seen=true
			var marker:Node2D=screen._peers.get("_markers")[id]
			if screen._peers.get("_live").has(id):
				moved=true
				delay=float(screen._peers.get("_live")[id].get("lag",0.0))
	if elapsed>3 and index==0 and not answered:
		answered=true
		_answer(screen)
	if elapsed>5 and index==0 and not deposited:
		deposited=true
		_deposit(screen)
	if elapsed>13 and index==0 and not finishing:
		finishing=true
		_complete(screen)

func _answer(screen:Control) -> void:
	var info:Dictionary=JSON.parse_string(FileAccess.get_file_as_string(test_file))
	var result:String=await screen.play.answer(0,str(info.answer))
	if result!="correct":push_error(result)
func _deposit(screen:Control) -> void:
	var result:Dictionary=await screen.play.deposit(5)
	if result.error!="":push_error(result.error)

func _complete(screen:Control) -> void:
	# Source spellings are used by the test driver only. Normal online panels
	# still receive no spelling before the server ends the match.
	var source: Array = JSON.parse_string(FileAccess.get_file_as_string("res://data/words.json"))
	for i in range(1, screen.play.words.size()):
		for word: Dictionary in source:
			if word.word == screen.play.words[i].word:
				var result: String = await Monks.answer(screen.play.session_id, i, str(word.modern))
				if result != "correct": push_error(result)
				break
	var result: Dictionary = await Monks.deposit(screen.play.session_id)
	if result.error != "": push_error(result.error)
