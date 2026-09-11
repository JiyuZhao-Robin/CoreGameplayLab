extends SceneTree

const DEMO := preload("res://src/ui/art_calibration/reference_mining_demo.tscn")
const OUTPUT := "res://artifacts/ui/reference-miners"
var demo: Control
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game := root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var before: String = JSON.stringify(game.state.to_dictionary())
	root.size = Vector2i(3840,2160)
	# No frame is yielded while these flags are true: scene entry suspends them
	# synchronously, and scene exit below is checked/reset before yielding again.
	game.persistence_enabled = true
	game.set_process(true)
	demo = DEMO.instantiate()
	root.add_child(demo)
	_check(not game.persistence_enabled and not game.is_processing(), "preview temporarily suspends existing Game processing")
	_check(demo.assets.errors.is_empty(), "both reference packs load")
	if not demo.assets.errors.is_empty():
		_finish()
		return
	var mk2: Control = demo.stages.mk2
	var core: Control = demo.stages.core
	for stage in demo.stages.values():
		stage.set_process(false)
		stage.playing = false
	_check(mk2.current_frame_count() == 195, "MK2 uses authored 195-step sequence over 30 source frames")
	_check(core.current_frame_count() == 120, "Core Extractor spans both sheets")
	_check_ui_bindings()
	var moving_layer: Dictionary = demo.assets.layer_definition("mk2_N_drill_back")
	_check(demo.assets.texture_frame(moving_layer, 1.0/24.0) == demo.assets.frame_texture("mk2_N_drill_back",0), "sequence holds repeated initial source frame")
	_check(demo.assets.texture_frame(moving_layer, 32.0/24.0) == demo.assets.frame_texture("mk2_N_drill_back",20), "sequence repeats working source frames")
	mk2.elapsed = 8.75
	_check(mk2._motion_offset(moving_layer).is_equal_approx(Vector2(0,0.2)*mk2.TILE_PIXELS*mk2.zoom), "waypoint transition retains fractional time")
	for stage in demo.stages.values():
		stage.seek_frame(17)
		_check(stage.current_frame() == 17 and not stage.playing, "scrub pauses requested frame")
		stage.request_running(false)
		var elapsed: float = stage.elapsed
		stage.playing = true
		stage._process(0.1)
		_check(is_equal_approx(stage.elapsed,elapsed), "stopped machine holds source pose")
		stage.request_running(true)
		stage._process(0.1)
		_check(stage.elapsed > elapsed, "start resumes source animation")
		stage.playing = false
		var cursor := Vector2(310,280)
		var anchor: Vector2 = stage.world_at(cursor)
		stage.set_zoom(1.4,cursor)
		_check(anchor.is_equal_approx(stage.world_at(cursor)), "world point stays under zoom cursor")
		stage.reset_view()
	core.seek_frame(100)
	mk2.seek_frame(5)
	mk2.playing = true
	mk2._process(0.1)
	_check(core.current_frame() == 100, "demo clocks are independent")
	mk2.playing = false
	await process_frame
	var rects := _rects()
	for window in [Vector2i(1920,1080),Vector2i(3440,1440),Vector2i(3840,2160)]:
		root.size = window
		await process_frame
		_check(_rects() == rects, "window preserves authored layout")
		_check(demo.scale == Vector2.ONE and mk2.scale == Vector2.ONE and core.scale == Vector2.ONE, "only global window stretch")
	for rect in rects:
		_check(Rect2(0,0,1920,1080).encloses(rect), "all controls fit design viewport")
	if DisplayServer.get_name() != "headless":
		await _render_checks()
	else:
		print("REFERENCE_MINING_DEMO_PIXELS_SKIPPED")
	_check(JSON.stringify(game.state.to_dictionary()) == before, "demos never change economic state")
	demo.free()
	_check(game.persistence_enabled and game.is_processing(), "closing demo restores previous Game flags")
	game.persistence_enabled = false
	game.set_process(false)
	await process_frame
	_finish()

func _check_ui_bindings() -> void:
	for key in ["mk2","core"]:
		var prefix: String = key.capitalize()
		var stage: Control = demo.stages[key]
		var other: Control = demo.stages["core" if key == "mk2" else "mk2"]
		var other_time: float = other.elapsed
		var run_button: Button = demo.get_node(prefix+"RunToggle")
		run_button.pressed.emit()
		_check(not stage.running and other.running, "run button is local to " + key)
		run_button.pressed.emit()
		var slider: HSlider = demo.get_node(prefix+"FrameSlider")
		slider.value = 12
		_check(stage.current_frame() == 12 and not stage.playing and other.elapsed == other_time, "slider is local to " + key)
		for role in ["base","shadow","emission","ground","ore"]:
			var toggle: CheckButton = demo.get_node(prefix+"Layer"+role.capitalize())
			toggle.button_pressed = false
			for id in stage.visible_layers:
				_check(stage.visible_layers[id] == (id != role), "toggle targets only " + key + "/" + role)
			toggle.button_pressed = true
		for percent in [50,100,150,200]:
			var button: Button = demo.get_node(prefix+"Zoom"+str(percent))
			button.pressed.emit()
			_check(is_equal_approx(stage.zoom,percent/100.0), "zoom binding " + key + str(percent))
		stage.reset_view()
	for direction in ["N","E","S","W"]:
		var button: Button = demo.get_node_or_null("mk2".capitalize()+"Direction"+direction)
		_check(button != null, "direction button exists " + direction)
		if button == null:
			continue
		button.pressed.emit()
		_check(demo.stages.mk2.direction == direction, "direction binding " + direction)
	demo.stages.mk2.set_direction("N")

func _render_checks() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for stage in demo.stages.values():
		stage.reset_view()
		stage.request_running(true)
		stage.seek_frame(5)
	var overview := await _capture("01-two-miner-demos")
	_check(overview.get_size() == Vector2i(3840,2160), "actual 4K capture")
	for key in ["mk2","core"]:
		var stage: Control = demo.stages[key]
		stage.seek_frame(20)
		var moving := await _capture("")
		_check(_changed(overview,moving,stage) > 35, "real source animation changes " + key)
		for layer in ["shadow","emission"]:
			stage.visible_layers[layer] = false
			var hidden := await _capture("")
			_check(_changed(moving,hidden,stage) > 8, "independent " + key + " " + layer)
			stage.visible_layers[layer] = true
		stage.request_running(false)
		var stopped := await _capture("")
		stage.playing = true
		for index in 10:
			stage._process(0.1)
		var later := await _capture("")
		_check(_changed(stopped,later,stage) == 0, "stopped image is stable " + key)
		stage.playing = false
		stage.request_running(true)
	var mk2: Control = demo.stages.mk2
	var prior: Image
	for direction in ["N","E","S","W"]:
		mk2.set_direction(direction)
		mk2.seek_frame(12)
		var current := await _capture("02-mk2-"+direction)
		if prior != null:
			_check(_changed(prior,current,mk2) > 100, "actual directional parts " + direction)
		prior = current
	mk2.set_direction("N")
	var core: Control = demo.stages.core
	core.seek_frame(63)
	var last_sheet_one := await _capture("")
	core.seek_frame(64)
	var first_sheet_two := await _capture("03-core-second-sheet")
	_check(_changed(last_sheet_one,first_sheet_two,core) > 5, "animation advances across sheet boundary")
	for stage in demo.stages.values():
		stage.show_anchors = true
	await _capture("04-anchors")
	for stage in demo.stages.values():
		stage.show_anchors = false
		stage.set_zoom(0.5)
	await _capture("05-zoom-50")

func _capture(name: String) -> Image:
	for stage in demo.stages.values():
		stage.refresh()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	if not name.is_empty():
		_check(result.save_png(OUTPUT.path_join(name+".png")) == OK, "save " + name)
	return result

func _changed(a: Image,b: Image,stage: Control) -> int:
	var rect: Rect2 = stage.get_global_rect()
	var area := Rect2i(rect.position*2,rect.size*2).intersection(Rect2i(Vector2i.ZERO,a.get_size()))
	var count := 0
	for y in range(area.position.y+60,area.end.y,3):
		for x in range(area.position.x,area.end.x,3):
			var ca := a.get_pixel(x,y)
			var cb := b.get_pixel(x,y)
			if absf(ca.r-cb.r)+absf(ca.g-cb.g)+absf(ca.b-cb.b) > 0.025:
				count += 1
	return count

func _rects() -> Array:
	var result := []
	for control in demo.controls:
		result.append(control.get_global_rect())
	return result

func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _finish() -> void:
	if failures.is_empty():
		print("REFERENCE_MINING_DEMO_TEST_PASS")
		quit(0)
	else:
		push_error("REFERENCE_MINING_DEMO_TEST_FAIL: " + "; ".join(failures))
		quit(1)
