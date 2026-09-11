extends SceneTree

const Canvas = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This pixel regression requires a rendered window.")
		quit(1)
		return
	root.size = Vector2i(3840,2160)
	root.get_node("Game").set_process(false)
	var host := Control.new()
	host.size = Vector2(1920,1080)
	root.add_child(host)
	var canvas := Canvas.new()
	canvas.size = host.size
	host.add_child(canvas)
	var snapshot := {"protocol_version":1,"valid":true,"world_id":"surface-pixel-fixture",
		"bounds":{"origin":{"x":0,"y":0},"size":{"x":112,"y":56}},
		"terrain_enabled":true,"seed":611,"terrain_safe_rect":{"origin":{"x":0,"y":0},"size":{"x":112,"y":56}},
		"tile_deltas":{},"resource_fields":[],"entities":[],"links":[],"construction_orders":[],"roads":[]}
	for index in range(4):
		for y in range(8,40):
			for x in range(24 + index * 16, 40 + index * 16):
				snapshot.tile_deltas["%d:%d" % [x,y]] = {"terrain_override":["WATER","DESERT","FOREST","MOUNTAIN"][index]}
	canvas.apply_snapshot(snapshot)
	canvas.set("_overview_mode", false)
	canvas.set("_zoom", 4.0)
	canvas.set("_camera", Vector2(32,64))
	canvas.queue_redraw()
	await _settle()
	var first := root.get_texture().get_image()
	_check(first.get_size() == Vector2i(3840,2160), "surface acceptance uses an actual 4K framebuffer")
	var soil := _sample(first, canvas, Vector2(16.5,16.5))
	var water := _sample(first, canvas, Vector2(30.5,16.5))
	var sand := _sample(first, canvas, Vector2(46.5,16.5))
	var forest := _sample(first, canvas, Vector2(62.5,16.5))
	var rock := _sample(first, canvas, Vector2(78.5,16.5))
	_check(water.b > water.r * 1.15 and water.get_luminance() < soil.get_luminance(), "water has its own dark cool material")
	_check(sand.get_luminance() > water.get_luminance() + 0.08, "dry land is distinguishable from blocked water")
	_check(_distance(soil, forest) > 0.035 and _distance(sand, rock) > 0.035, "forest, rock and soil do not collapse into one atlas tint")
	var seam_delta := 0.0
	for y in range(2,7):
		seam_delta += _distance(_sample(first, canvas, Vector2(16.0 - 0.025,y + 0.5)), _sample(first, canvas, Vector2(16.0 + 0.025,y + 0.5)))
	_check(seam_delta / 5.0 < 0.09, "neighbour chunks do not introduce material seams in continuous soil")
	var directory := "res://artifacts/ui/factory-natural-surface"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	first.save_png(directory.path_join("01-materials-and-transitions.png"))
	canvas.set("_camera", Vector2(128,128))
	canvas.queue_redraw()
	await _settle()
	var panned := root.get_texture().get_image()
	_check(_distance(soil, _sample(panned,canvas,Vector2(16.5,16.5))) < 0.012, "panning does not slide or recolor the world material")
	_check(_distance(water, _sample(panned,canvas,Vector2(30.5,16.5))) < 0.012, "shoreline and water remain fixed in world coordinates")
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_NATURAL_SURFACE_PASS")
		quit(0)
	else:
		for failure in failures: push_error(failure)
		quit(1)

func _sample(picture: Image, canvas: Control, tile: Vector2) -> Color:
	var screen: Vector2 = canvas.call("_world_to_screen", tile)
	return picture.get_pixelv(Vector2i(screen * 2.0))

func _distance(a: Color, b: Color) -> float:
	return Vector3(a.r-b.r,a.g-b.g,a.b-b.b).length()

func _settle() -> void:
	for frame in range(5): await process_frame
	await RenderingServer.frame_post_draw

func _check(value: bool, message: String) -> void:
	if not value: failures.append(message)
