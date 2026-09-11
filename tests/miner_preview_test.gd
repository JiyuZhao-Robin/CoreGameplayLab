extends SceneTree

const Preview := preload("res://src/ui/art_calibration/miner_preview.tscn")
var scene: Control
var stage: Control
var failures: Array[String] = []
var transitions: Array[String] = []
const OUTPUT := "res://artifacts/ui/miner"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game := root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var before: String = JSON.stringify(game.state.to_dictionary())
	root.size = Vector2i(3840,2160)
	scene = Preview.instantiate()
	root.add_child(scene)
	stage = scene.stage
	stage.set_process(false)
	stage.state_changed.connect(func(mode, running): transitions.append("%s:%s" % [mode, str(running)]))
	_check(scene.assets.errors.is_empty(), "all original miner layers and clips load")
	if not scene.assets.errors.is_empty():
		_finish()
		return
	_check(scene.assets.frame_count("startup") == 24 and scene.assets.frame_count("working") == 60 and scene.assets.frame_count("shutdown") == 24, "24/60/24 valid frames")
	_check(scene.assets.frame_texture("base",0) == scene.assets.frame_texture("working",0), "identical bake paths share GPU textures")
	_check(scene.assets.frame_texture("working",0).get_image().has_mipmaps(), "independent frames have mip chains")
	_check(stage.mode == "STARTUP", "initial start plays lowering sequence")
	_advance(0.9)
	_check(stage.mode == "WORKING", "startup reaches working loop")
	scene.seek_frame(55)
	scene.request_running(false)
	_check(stage.mode == "WORKING", "stop waits for work cycle endpoint")
	_check(scene.frame_slider.value == 55, "long clip slider starts above short clip maximum")
	transitions.clear()
	_advance(0.2)
	_check(stage.mode == "SHUTDOWN", "cycle endpoint enters shutdown")
	_check(transitions.has("SHUTDOWN:false"), "shutdown start is signalled to listeners")
	var shutdown_frame: int = stage.current_frame()
	scene._update_status()
	_check(stage.mode == "SHUTDOWN" and not stage.running and stage.playing, "passive 60 to 24 slider clamp preserves stop request and playback")
	_check(stage.current_frame() == shutdown_frame and scene.frame_slider.max_value == 23, "passive status never scrubs shutdown")
	_advance(0.9)
	_check(stage.mode == "STOPPED" and stage.current_frame() == 23, "shutdown holds retracted final pose")
	scene.request_running(true)
	_advance(0.2)
	scene.request_running(false)
	_check(stage.mode == "STARTUP", "interrupted startup does not rewind")
	_advance(1.5)
	_check(stage.mode == "STOPPED", "interrupted startup completes then retracts")
	scene.request_running(true)
	_advance(0.9)
	scene.seek_frame(15)
	_check(stage.current_frame() == 15 and not stage.playing, "working frame scrub")
	_check_ui_bindings()
	var cursor := Vector2(330,310)
	var world: Vector2 = stage.world_at(cursor)
	stage.set_zoom(1.7,cursor)
	_check(world.is_equal_approx(stage.world_at(cursor)), "cursor remains anchored through zoom")
	scene.reset_view()
	await process_frame
	for window in [Vector2i(1920,1080),Vector2i(3440,1440),Vector2i(3840,2160)]:
		root.size = window
		await process_frame
		_check(scene.scale == Vector2.ONE and stage.scale == Vector2.ONE, "single global scale")
		_check(stage.size == Vector2(1362,738), "window preserves authored stage size")
		for control in scene.controls:
			_check(Rect2(0,0,1920,1080).encloses(control.get_global_rect()), "control bounds: " + str(control.name))
	if DisplayServer.get_name() != "headless":
		await _render_checks()
	else:
		print("MINER_PREVIEW_PIXELS_SKIPPED")
	_check(JSON.stringify(game.state.to_dictionary()) == before, "preview does not change economic state")
	scene.queue_free()
	await process_frame
	_finish()

func _check_ui_bindings() -> void:
	var layer_buttons := {"主体烘焙":"base", "独立阴影":"shadow", "遮罩着色":"mask", "静态发光":"emission", "烟雾参考":"smoke", "铁矿参考":"ore", "地面参考":"ground"}
	var zoom_buttons := {"50%":0.5, "100%":1.0, "150%":1.5, "200%":2.0}
	for control in scene.controls:
		if control is CheckButton and layer_buttons.has(control.text):
			var layer: String = layer_buttons[control.text]
			control.button_pressed = false
			for id in stage.visible_layers:
				_check(stage.visible_layers[id] == (id != layer), "layer toggle targets only " + layer)
			control.button_pressed = true
		elif control is Button and zoom_buttons.has(control.text):
			control.pressed.emit()
			_check(is_equal_approx(stage.zoom, zoom_buttons[control.text]), "zoom button " + control.text)

func _advance(seconds: float) -> void:
	stage.playing = true
	for step in ceili(seconds/0.05):
		stage._process(0.05)

func _render_checks() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	stage.mode = "WORKING"
	stage.running = true
	scene.seek_frame(15)
	var working := await _capture("01-miner-working")
	_check(working.get_size() == Vector2i(3840,2160), "4K actual target")
	scene.seek_frame(35)
	var later := await _capture("")
	_check(_changed(working,later) > 150, "drill rotation/feed change visible pixels")
	for id in ["shadow","mask","emission"]:
		stage.visible_layers[id] = false
		var hidden := await _capture("")
		_check(_changed(later,hidden) > 10, "independent layer: " + id)
		stage.visible_layers[id] = true
	stage.playing = true
	scene.request_running(false)
	_advance(3.0)
	_check(stage.mode == "STOPPED", "render path reaches stopped pose")
	var stopped := await _capture("02-miner-stopped")
	_check(_changed(later,stopped) > 100, "retracted stopped pose differs")
	_advance(0.3)
	var still := await _capture("")
	_check(_changed(stopped,still) == 0, "stopped frame is pixel stable")
	stage.show_anchors = true
	stage.show_grid = true
	await _capture("03-miner-anchors")
	stage.show_anchors = false
	stage.show_grid = false
	stage.set_zoom(2.0)
	stage.camera = Vector2(0,-1.0)
	await _capture("04-miner-closeup")
	stage.set_zoom(0.5)
	await _capture("05-miner-zoom-50")

func _capture(name: String) -> Image:
	stage.refresh()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if not name.is_empty():
		_check(image.save_png(OUTPUT.path_join(name+".png")) == OK,"save "+name)
	return image

func _changed(a: Image,b: Image) -> int:
	var count := 0
	for y in range(320,1796,3):
		for x in range(68,2792,3):
			var first := a.get_pixel(x,y)
			var second := b.get_pixel(x,y)
			if absf(first.r-second.r)+absf(first.g-second.g)+absf(first.b-second.b) > 0.035:
				count += 1
	return count

func _check(value: bool,message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _finish() -> void:
	if failures.is_empty():
		print("MINER_PREVIEW_TEST_PASS")
		quit(0)
	else:
		push_error("MINER_PREVIEW_TEST_FAIL: "+"; ".join(failures))
		quit(1)
