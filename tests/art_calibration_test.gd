extends SceneTree

const SCENE := preload("res://src/ui/art_calibration/art_calibration.tscn")
var failures: Array[String] = []
var scene: Control
var output := "res://artifacts/ui/art-calibration"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game := root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var state_before: String = JSON.stringify(game.state.to_dictionary())
	root.size = Vector2i(3840, 2160)
	scene = SCENE.instantiate()
	root.add_child(scene)
	scene.stage.playing = false
	var pack: RefCounted = scene.assets
	_check(pack.errors.is_empty(), "all selected reference images load")
	if not pack.errors.is_empty():
		_finish()
		return
	_check(pack.frames.base.size() == 60 and pack.frames.emission.size() == 60, "60 valid animation frames; unused atlas cells excluded")
	_check(pack.frames.shadow.size() == 1 and pack.frames.mask.size() == 1, "shadow and mask keep independent static frames")
	_check(pack.frames.smoke.size() == 30, "all 30 numbered smoke frames load")
	_check(pack.frame_index("base", 59.0 / 30.0 + 0.00001) == 59 and pack.frame_index("base", 2.0) == 0, "last valid frame and loop boundary")
	_check(pack.frame_index("base", 0.8, false) == 0 and pack.frame_index("shadow", 8.0) == 0, "stopped body and independent shadow use static frames")
	_check(pack.texture("base", 0.0).get_image().has_mipmaps(), "per-frame mip chains are generated")
	_check(pack.texture("base", 0.0).get_image().get_data() != pack.texture("base", 0.5).get_image().get_data(), "source contains real mechanical animation")
	var body: Rect2 = pack.layer_rect("base", Vector2.ZERO, 32)
	var shadow: Rect2 = pack.layer_rect("shadow", Vector2.ZERO, 32)
	_check(is_equal_approx(body.size.x, 128.0), "explicit 4-tile calibration width")
	_check(shadow.size.x > body.size.x and shadow.get_center().x > body.get_center().x, "authored larger shadow and offset preserved")
	var double_body: Rect2 = pack.layer_rect("base", Vector2.ZERO, 64)
	_check(double_body.size.is_equal_approx(body.size * 2) and double_body.position.is_equal_approx(body.position * 2), "scale and anchor offset convert together")
	var cursor := Vector2(410, 260)
	var before: Vector2 = scene.stage.world_at(cursor)
	scene.stage.set_zoom(1.75, cursor)
	_check(before.is_equal_approx(scene.stage.world_at(cursor)), "cursor-centered zoom retains world anchor")
	scene._reset_view()
	var toggle_ids := {"建筑主体":"base", "独立阴影":"shadow", "等级色罩":"mask", "运行发光":"emission", "烟雾动画":"smoke", "铁矿样本":"ore"}
	for control in scene.controls:
		if control is CheckButton and toggle_ids.has(control.text):
			var id: String = toggle_ids[control.text]
			control.button_pressed = false
			_check(not scene.stage.visible_layers[id], "UI toggle targets its own layer: " + id)
			control.button_pressed = true
		elif control is Button and control.text in ["50%", "100%", "150%", "200%"]:
			control.pressed.emit()
			_check(is_equal_approx(scene.stage.zoom, control.text.trim_suffix("%").to_float() / 100), "UI zoom preset: " + control.text)
	scene._reset_view()
	scene.playback_button.pressed.emit()
	_check(scene.stage.playing, "play button activates presentation clock")
	scene.playback_button.pressed.emit()
	scene.frame_slider.value = 15
	_check(not scene.stage.playing and pack.frame_index("base", scene.stage.elapsed) == 15, "scrub pauses at requested frame")
	await process_frame
	var panels := _control_rects()
	for window in [Vector2i(1920,1080), Vector2i(2560,1440), Vector2i(3440,1440), Vector2i(3840,2160)]:
		root.size = window
		await process_frame
		_check(_control_rects() == panels, "window %s keeps authored control positions" % window)
		_check(scene.scale == Vector2.ONE and scene.stage.scale == Vector2.ONE, "no second root or stage scale")
	for rect in panels:
		_check(Rect2(0,0,1920,1080).encloses(rect), "controls fit design viewport")
	if DisplayServer.get_name() == "headless":
		print("ART_CALIBRATION_PIXELS_SKIPPED: run normal renderer for visual acceptance")
	else:
		await _render_checks()
	_check(JSON.stringify(game.state.to_dictionary()) == state_before, "scene and controls never mutate economic state")
	scene.queue_free()
	await process_frame
	_finish()

func _render_checks() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	scene._reset_view()
	scene.stage.elapsed = 0.5
	var overview := await _capture("01-overview")
	_check(overview.get_size() == Vector2i(3840,2160), "real 4K render target")
	var first := _region(Vector2(-7,0), Vector2(4.5,5.5))
	var second := _region(Vector2.ZERO, Vector2(4.5,5.5))
	scene.stage.elapsed = 1.0
	var next := await _capture("")
	_check(_changed(overview, next, first) > 150, "running sample visibly animates")
	_check(_changed(overview, next, second) == 0, "stopped comparison remains pixel-stable")
	for id in ["shadow", "mask", "emission", "smoke"]:
		scene.stage.visible_layers[id] = false
		var hidden := await _capture("")
		_check(_changed(next, hidden, Rect2i(72,320,2720,1460)) > 20, "independent %s layer changes actual pixels" % id)
		scene.stage.visible_layers[id] = true
	scene.stage.visible_layers.base = false
	scene.stage.visible_layers.mask = false
	var ore_only := await _capture("")
	_check(_changed(next, ore_only, _region(Vector2(7,0), Vector2(3,3))) > 300, "building preview stays visible above ore")
	scene.stage.visible_layers.base = true
	scene.stage.visible_layers.mask = true
	scene.stage.daylight = 0.35
	await _capture("02-low-light")
	scene.stage.daylight = 1.0
	scene.stage.show_grid = true
	scene.stage.show_anchors = true
	await _capture("03-anchors-and-footprints")
	scene.stage.show_grid = false
	scene.stage.show_anchors = false
	scene.stage.set_zoom(0.5)
	await _capture("04-zoom-50")
	scene.stage.set_zoom(2.0)
	scene.stage.camera = Vector2(-7,0)
	await _capture("05-zoom-200")
	scene.state_button.pressed.emit()
	var stopped := await _capture("")
	scene.stage.elapsed += 0.75
	var stopped_next := await _capture("")
	_check(_changed(stopped, stopped_next, Rect2i(72,320,2720,1460)) == 0, "stop disables animation, emission and smoke")
	scene.state_button.pressed.emit()

func _control_rects() -> Array:
	var result := []
	for control in scene.controls:
		result.append(control.get_global_rect())
	return result

func _region(world: Vector2, tiles: Vector2) -> Rect2i:
	var center: Vector2 = scene.stage.position + scene.stage.point(world)
	var extent: Vector2 = tiles * scene.stage.TILE_PIXELS * scene.stage.zoom
	return Rect2i((center - extent * 0.5) * 2, extent * 2)

func _capture(name: String) -> Image:
	scene.stage.refresh()
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if not name.is_empty():
		_check(image.save_png(output.path_join(name + ".png")) == OK, "capture " + name)
	return image

func _changed(a: Image, b: Image, area: Rect2i) -> int:
	var count := 0
	area = area.intersection(Rect2i(Vector2i.ZERO, a.get_size()))
	for y in range(area.position.y, area.end.y, 3):
		for x in range(area.position.x, area.end.x, 3):
			var ca := a.get_pixel(x,y)
			var cb := b.get_pixel(x,y)
			if absf(ca.r-cb.r) + absf(ca.g-cb.g) + absf(ca.b-cb.b) > 0.025:
				count += 1
	return count

func _check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _finish() -> void:
	if failures.is_empty():
		print("ART_CALIBRATION_TEST_PASS: source frames, independent layers, animation state, world anchors, fixed layout and source isolation")
		quit(0)
	else:
		push_error("ART_CALIBRATION_TEST_FAIL: " + "; ".join(failures))
		quit(1)
