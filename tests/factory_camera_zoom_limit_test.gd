extends SceneTree

const Canvas = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game := root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var canvas := Canvas.new()
	canvas.size = Vector2(1600, 800)
	root.add_child(canvas)
	await process_frame
	for world_size in [Vector2i(1024, 640), Vector2i(4096, 2560)]:
		var snapshot := {"valid":true, "protocol_version":1, "world_id":str(world_size), "bounds":{"origin":{"x":0,"y":0}, "size":{"x":world_size.x,"y":world_size.y}}, "entities":[], "resource_fields":[], "links":[], "construction_orders":[], "roads":[], "palette":{"buildings":[],"recipes":[]}}
		canvas.apply_snapshot(snapshot)
		canvas.reset_camera()
		_budget(canvas, "reset " + str(world_size))
		_check(canvas._world_screen_rect().size.x > canvas.size.x and canvas._world_screen_rect().size.y > canvas.size.y, "entire planet cannot fit " + str(world_size))
		canvas.focus_tile(world_size / 2)
		for index in 80:
			canvas._adjust_zoom(0.8)
		_budget(canvas, "repeated keyboard zoom-out")
		var anchor := canvas.size * Vector2(0.43, 0.57)
		var before: Vector2 = canvas._screen_to_world(anchor)
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = true
		wheel.position = anchor
		canvas._on_gui_input(wheel)
		_budget(canvas, "wheel at lower limit")
		_check(canvas._screen_to_world(anchor).distance_to(before) < 0.001, "wheel at limit preserves world anchor")
		var gesture := InputEventMagnifyGesture.new()
		gesture.position = anchor
		gesture.factor = 0.001
		canvas._on_gui_input(gesture)
		_budget(canvas, "pinch zoom-out")
		canvas.focus_operational_region()
		_budget(canvas, "operational fit")
		canvas.set("_zoom", 0.00001)
		canvas.focus_tile(world_size / 2)
		_budget(canvas, "focus after legacy zoom restore")
		canvas.set("_zoom", 0.00001)
		canvas.apply_snapshot(snapshot)
		_budget(canvas, "snapshot after legacy zoom restore")
		for extent in [Vector2(1000, 650), Vector2(1920, 1080), Vector2(1600, 800)]:
			canvas.size = extent
			await process_frame
			_budget(canvas, "resize " + str(extent))
		canvas.focus_tile(world_size / 2)
		var zoom_before: float = canvas.get("_zoom")
		var logical_size := canvas.size
		root.size = Vector2i(3840, 2160)
		await process_frame
		_check(canvas.size == logical_size and is_equal_approx(canvas.get("_zoom"), zoom_before), "physical 4K window keeps logical camera")
		root.size = Vector2i(1920, 1080)
		await process_frame
		for index in 80:
			canvas._adjust_zoom(1.14)
		_check(is_equal_approx(canvas._tile_scale(), Canvas.MAX_DETAIL_TILE_PIXELS), "existing zoom-in ceiling remains")
	canvas.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_CAMERA_ZOOM_LIMIT_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _budget(canvas: Control, context: String) -> void:
	var visible_area := canvas.size.x * canvas.size.y / pow(canvas._tile_scale(), 2)
	_check(visible_area <= Canvas.MAX_VISIBLE_CAMERA_TILES + 0.01, context + " respects visible tile budget")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
