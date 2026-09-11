extends SceneTree

## Must run with the real Compatibility renderer. Writes only ignored artifacts.
const Preview = preload("res://demos/earth_terrain/earth_terrain_preview.gd")
const Renderer = preload("res://src/ui/workspaces/factory/factory_terrain_renderer.gd")
const Canvas = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const OUTPUT := "res://artifacts/ui/earth-terrain"
const NAMES := ["01-meadow","02-forest-edge","03-water-shore","04-mountain-foothills"]
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game: Node = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	if DisplayServer.get_name() == "headless":
		push_error("Earth visual acceptance requires a real renderer, not --headless")
		quit(1)
		return
	root.size = Vector2i(3840,2160)
	var before: Dictionary = game.state.to_dictionary().duplicate(true)
	var preview := Preview.new()
	root.add_child(preview)
	await _settle()
	_check(preview.size.is_equal_approx(Vector2(1920,1080)), "4K window retains the 1920 by 1080 logical design viewport")
	var canvas: Control = preview.canvas
	var renderer: RefCounted = canvas.get("_terrain_renderer")
	_check(renderer.call("has_art"), "production ground renderer loads real project art")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var signatures := {}
	for index in range(NAMES.size()):
		preview.show_view(index)
		await _settle()
		var visible_tiles: float = canvas.size.x * canvas.size.y / pow(float(canvas.call("_tile_scale")),2)
		_check(visible_tiles <= Canvas.MAX_VISIBLE_CAMERA_TILES + 1.0, "each bookmark respects the local camera budget")
		_check(int(renderer.get("last_visible_chunks")) > 0 and int(renderer.call("cached_chunk_count")) <= Renderer.MAX_CACHED_CHUNKS, "geography chunks render within their fixed cache budget")
		if index == 1:
			var foliage: RefCounted = renderer.get("_foliage")
			_check(int(foliage.get("visible_tree_count")) > 0, "forest bookmark displays actual tree canopies")
		var built: int = renderer.get("mesh_build_count")
		canvas.queue_redraw()
		await _settle()
		_check(int(renderer.get("mesh_build_count")) == built, "stationary view reuses generated geography")
		await RenderingServer.frame_post_draw
		var capture := root.get_texture().get_image()
		_check(capture != null and capture.get_size() == Vector2i(3840,2160), "actual viewport capture has full 4K resolution")
		if capture != null:
			_check(capture.save_png(OUTPUT + "/" + NAMES[index] + ".png") == OK, "4K capture saves for %s" % NAMES[index])
			var review := capture.duplicate() as Image
			review.resize(1440,810,Image.INTERPOLATE_LANCZOS)
			_check(review.save_png(OUTPUT + "/" + NAMES[index] + "-review.png") == OK, "inspection copy saves")
			# Sample only the ground interior, excluding labels and navigation.
			var colors := {}
			var checksum := 0
			for y in range(300,1980,47):
				for x in range(96,3744,47):
					var pixel := capture.get_pixel(x,y)
					var bucket := Vector3i(int(pixel.r*31),int(pixel.g*31),int(pixel.b*31))
					colors[bucket] = true
					checksum += pixel.to_rgba32()
			_check(colors.size() > 24, "%s has textured ground detail, not a flat semantic color" % NAMES[index])
			signatures[checksum] = true
		_test_chunk_halos(preview.snapshot,preview.viewpoints[index])
	_check(signatures.size() == 4, "four bookmarks capture different real landscapes")
	_check(game.state.to_dictionary() == before, "the isolated viewer and all navigation leave the player state untouched")
	preview.queue_free()
	await process_frame
	if failures.is_empty():
		print("EARTH_TERRAIN_VISUAL_PASS: " + ProjectSettings.globalize_path(OUTPUT))
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_chunk_halos(snapshot: Dictionary, tile: Vector2i) -> void:
	var span: int = Renderer.CHUNK_CELLS
	var origin := Vector2i(floori(float(tile.x)/span)*span,floori(float(tile.y)/span)*span)
	var base: Dictionary = Renderer.surface_masks(snapshot,origin,1)
	var right: Dictionary = Renderer.surface_masks(snapshot,origin+Vector2i(span,0),1)
	var lower: Dictionary = Renderer.surface_masks(snapshot,origin+Vector2i(0,span),1)
	var continuous := true
	for field in ["surface","rock"]:
		var first: Image = base[field]
		var adjacent_x: Image = right[field]
		var adjacent_y: Image = lower[field]
		for coordinate in range(span+2):
			for halo in range(2):
				continuous = continuous and first.get_pixel(span+halo,coordinate).is_equal_approx(adjacent_x.get_pixel(halo,coordinate))
				continuous = continuous and first.get_pixel(coordinate,span+halo).is_equal_approx(adjacent_y.get_pixel(coordinate,halo))
	_check(continuous, "adjacent chunk halos preserve identical continuous fields and relief normals")


func _settle() -> void:
	for frame in range(5):
		await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
