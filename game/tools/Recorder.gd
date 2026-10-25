class_name Recorder
extends Node

## Records the window as it plays, in real time, for the trailer and the
## gameplay video (tools/showcase.gd): every frame's picture piped to ffmpeg,
## and the game's own sound off the Master bus into a WAV beside it.
##
## Not Movie Maker (--write-movie): that runs at its own pace, slower than the
## clock on this laptop, and the match clock, the server and the other
## players all run on the real one -- they sped up on the recording.

const FPS := 30

var path := ""
## What is recorded: a SubViewport of a fixed size (a window's own size
## follows the desktop's scaling -- 5398x2840 here for 1920x1080).
var view: Viewport
var _pipe: FileAccess
var _pid := -1
var _started := 0
var _frames := 0
var _record: AudioEffectRecord
## The sound effects alone, beside the mix: the edit lays music of its own
## under cuts and speed-ups.
var _sfx: AudioEffectRecord


func start(of: Viewport, to: String) -> void:
	view = of
	path = to
	var size := view.get_texture().get_size()
	var got := OS.execute_with_pipe("ffmpeg", ["-y", "-loglevel", "error",
		"-f", "rawvideo", "-pix_fmt", "rgba", "-s", "%dx%d" % [size.x, size.y], "-r", str(FPS),
		"-i", "-", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "14",
		"-pix_fmt", "yuv420p", path + ".mp4"])
	_pipe = got.stdio
	_pid = got.pid
	var bus := AudioServer.get_bus_index("Master")
	_record = AudioEffectRecord.new()
	AudioServer.add_bus_effect(bus, _record)
	_record.set_recording_active(true)
	_sfx = AudioEffectRecord.new()
	AudioServer.add_bus_effect(AudioServer.get_bus_index(Sfx.BUS), _sfx)
	_sfx.set_recording_active(true)
	_started = Time.get_ticks_usec()
	_frames = 0
	RenderingServer.frame_post_draw.connect(_grab)


func _grab() -> void:
	# Frames by the clock: a slow frame is written twice, so the picture
	# keeps time with the sound.
	var due := int((Time.get_ticks_usec() - _started) * FPS / 1000000) + 1
	if due <= _frames:
		return
	var img := view.get_texture().get_image()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	while _frames < due:
		_pipe.store_buffer(data)
		_frames += 1


## A moment worth finding in the edit: its name and the second it happened,
## written beside the recording at the end (`<path>.marks.json`).
var marks: Array = []


func mark(name: String) -> void:
	marks.append([name, snappedf((Time.get_ticks_usec() - _started) / 1000000.0, 0.01)])


func stop() -> void:
	FileAccess.open(path + ".marks.json", FileAccess.WRITE).store_string(JSON.stringify(marks))
	RenderingServer.frame_post_draw.disconnect(_grab)
	_record.set_recording_active(false)
	_record.get_recording().save_to_wav(path + ".wav")
	_sfx.set_recording_active(false)
	_sfx.get_recording().save_to_wav(path + "-sfx.wav")
	_pipe.close()
	while OS.is_process_running(_pid):
		OS.delay_msec(50)
	print("recorded %s: %d frames (%.1fs)" % [path, _frames, float(_frames) / FPS])
