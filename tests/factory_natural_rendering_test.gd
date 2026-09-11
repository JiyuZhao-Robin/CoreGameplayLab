extends SceneTree

const Terrain = preload("res://src/core/factory_terrain.gd")
const Renderer = preload("res://src/ui/workspaces/factory/factory_terrain_renderer.gd")
const ResourceRenderer = preload("res://src/ui/workspaces/factory/factory_resource_renderer.gd")
const Grid = preload("res://src/core/factory_grid_simulation.gd")
const Canvas = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_test_semantic_halos()
	_test_snapshot_authority()
	_test_resource_geometry()
	await _test_cache_lifetime()
	await _test_transparent_field_input()
	if failures.is_empty():
		print("FACTORY_NATURAL_RENDERING_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _world() -> Dictionary:
	return {"world_id":"natural-render-fixture", "seed":43191, "terrain_seed":77451,
		"terrain_enabled":true, "generator_version":3, "terrain_scale_tiles":29.0,
		"terrain_safe_rect":{}, "bounds":{"origin":{"x":-37,"y":-19}, "size":{"x":512,"y":320}}, "tile_deltas":{}}

func _test_semantic_halos() -> void:
	var world := _world()
	world.tile_deltas["15:7"] = {"terrain_override":"WATER"}
	world.tile_deltas["16:7"] = {"terrain_override":"MOUNTAIN"}
	var original := JSON.stringify(world)
	for step in [1, 2, 8]:
		var origin: Vector2i = Vector2i(-16, -16) * int(step)
		var left := Renderer.semantic_mask(world, origin, step)
		var right := Renderer.semantic_mask(world, origin + Vector2i(16 * step, 0), step)
		for y in range(18):
			_check(left.get_pixel(16, y) == right.get_pixel(0, y), "same coordinates in opposite halo/interior columns agree")
			_check(left.get_pixel(17, y) == right.get_pixel(1, y), "an unloaded neighbour and loaded chunk have identical terrain")
		for y in range(18):
			for x in range(18):
				var tile: Vector2i = origin + Vector2i(x - 1, y - 1) * int(step) + Vector2i(step / 2, step / 2)
				_check(left.get_pixel(x, y) == Renderer.MASK_COLORS[Terrain.terrain_type(world, tile)], "every semantic texel is from the authoritative terrain sampler")
	_check(JSON.stringify(world) == original, "mask generation never mutates world inputs")
	var boundary := Renderer.semantic_mask(world, Vector2i(16, 0), 1)
	_check(boundary.get_pixel(0, 8) == Renderer.MASK_COLORS.PLAIN and boundary.get_pixel(1, 8) == Renderer.MASK_COLORS.PLAIN, "historical water/mountain deltas render plain across chunk borders")

func _test_snapshot_authority() -> void:
	var grid := Grid.new({})
	var world := grid.create_world("natural-render-fixture", "earth", Vector2i(256,160))
	world.merge(_world(), true)
	var restored: Dictionary = grid.normalize_world(world)
	for key in ["terrain_seed", "generator_version", "terrain_scale_tiles"]:
		_check(restored.get(key) == world.get(key), "save normalization preserves " + key)
	var snapshot: Dictionary = grid.workspace_snapshot(world)
	for key in ["terrain_seed", "generator_version", "terrain_scale_tiles"]:
		_check(snapshot.get(key) == world.get(key), "workspace snapshot exports " + key)
	for y in range(0, 96, 7):
		for x in range(0, 128, 7):
			_check(Terrain.terrain_type(world, Vector2i(x,y)) == Terrain.terrain_type(snapshot, Vector2i(x,y)), "nondefault terrain parameters match between simulation and UI")

func _test_resource_geometry() -> void:
	var painter := ResourceRenderer.new()
	var field := {"id":"edge", "resource_id":"iron_ore", "shape":"IRREGULAR", "seed":611,
		"footprint":{"origin":{"x":12,"y":18}, "size":{"x":32,"y":24}}}
	# Synthetic texture only isolates geometry; authored asset validation is a
	# separate test. This is not shipped or claimed as finished mineral art.
	var texture := ImageTexture.create_from_image(Image.create(1024,512,false,Image.FORMAT_RGBA8))
	_check(painter._cluster_mesh({}, texture) == null and painter._survey_mesh({}) == null, "empty fields create no invalid render mesh")
	var mesh: ArrayMesh = painter._cluster_mesh(field, texture)
	_check(mesh.get_surface_count() == 1, "mineral clusters produce a mesh")
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector2Array = arrays[Mesh.ARRAY_VERTEX]
	_check(vertices.size() > 100, "quad append helpers actually populate caller arrays")
	var second: ArrayMesh = painter._cluster_mesh(field, texture)
	_check(arrays[Mesh.ARRAY_TEX_UV] == second.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV], "sprite stages and variations are deterministic")
	for point in vertices:
		_check(Rect2(12,18,32,24).grow(0.001).has_point(point), "ore geometry stays inside the field bounding footprint")
	var variant := field.duplicate(true)
	variant.shape = "RECTANGLE"
	_check(painter._key(field) != painter._key(variant), "shape changes invalidate cached mineral geometry")
	variant = field.duplicate(true)
	variant.resource_id = "copper_ore"
	_check(painter._key(field) != painter._key(variant), "resource changes invalidate the sprite atlas choice")
	_check(painter.is_fluid_field({"resource_id":"helium_3","resource_category":"gas"}), "gas resources never inherit the fallback rock cluster")
	_check(painter.is_fluid_field({"resource_id":"new-liquid","resource_category":"liquid"}), "new liquid IDs follow category authority")
	_check(not painter.is_fluid_field({"resource_id":"new-solid","resource_category":"solid"}), "new solid resources retain the mineral fallback")
	var survey: ArrayMesh = painter._survey_mesh(field)
	var survey_vertices: PackedVector2Array = survey.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for index in range(0,survey_vertices.size(),4):
		var cell := Rect2(survey_vertices[index],survey_vertices[index+2]-survey_vertices[index])
		for y in range(int(cell.position.y),int(cell.end.y)):
			for x in range(int(cell.position.x),int(cell.end.x)):
				_check(Terrain.field_contains(field,Vector2i(x,y)), "survey quads cannot fill an irregular non-resource hole")

func _test_cache_lifetime() -> void:
	var painter := Renderer.new()
	var world := _world()
	painter.configure(world)
	_check(painter.has_art(), "four real terrain materials load")
	if not painter.has_art():
		return
	var host := Control.new()
	host.size = Vector2(900,600)
	root.add_child(host)
	painter.draw_ground(host, world, Rect2(-37,-19,90,60), 10.0, Vector2(370,190))
	var builds := painter.mesh_build_count
	painter.draw_ground(host, world, Rect2(-37,-19,90,60), 10.0, Vector2(370,190))
	_check(painter.mesh_build_count == builds, "stationary view reuses terrain masks/materials")
	for key in ["terrain_seed", "generator_version", "terrain_scale_tiles", "terrain_enabled", "bounds"]:
		var alternate := world.duplicate(true)
		if key == "terrain_enabled": alternate[key] = false
		elif key == "bounds": alternate.bounds.size.x += 16
		else: alternate[key] += 1
		painter.configure(alternate)
		_check(painter.cached_chunk_count() == 0, "input change clears terrain cache: " + key)
		painter.draw_ground(host, alternate, Rect2(0,0,90,60), 10.0, Vector2.ZERO)
	var large := world.duplicate(true)
	large.bounds = {"origin":{"x":0,"y":0}, "size":{"x":4096,"y":2560}}
	painter.configure(large)
	painter.draw_ground(host, large, Rect2(0,0,4096,2560), 0.2, Vector2.ZERO)
	_check(painter.cached_chunk_count() <= Renderer.MAX_CACHED_CHUNKS and painter.last_lod > 1, "large overview stays within chunk and LOD budgets")
	painter.hide_ground()
	_check(not painter._ground_layer.visible, "invalid/legacy snapshot can hide all prior natural ground")
	host.queue_free()
	await process_frame
	painter.configure({"world_id":"next-world"})
	_check(painter.cached_chunk_count() == 0, "freeing the canvas then switching worlds leaves no stale node access")

func _test_transparent_field_input() -> void:
	var canvas := Canvas.new()
	canvas.size = Vector2(900,600)
	root.add_child(canvas)
	var field := {"id":"pan-field","shape":"IRREGULAR","seed":611,"resource_id":"iron_ore",
		"footprint":{"origin":{"x":80,"y":80},"size":{"x":32,"y":24}}}
	var snapshot := _world()
	snapshot.merge({"protocol_version":1,"valid":true,"entities":[],"roads":[],"links":[],"construction_orders":[],"resource_fields":[field]},true)
	canvas.apply_snapshot(snapshot)
	canvas.set("_zoom",2.0)
	canvas.set("_camera",Vector2(-500,-500))
	canvas.set("_overview_mode",false)
	var point: Vector2 = canvas.call("_world_to_screen",Vector2(80.5,80.5))
	_check(not Terrain.field_contains(field,Vector2i(80,80)), "input fixture begins in the transparent corner of the field")
	_check(not canvas.call("_point_has_interactive_hit",point), "transparent resource corners are empty ground for input")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	canvas.call("_on_gui_input",press)
	var before: Vector2 = canvas.get("_camera")
	var motion := InputEventMouseMotion.new()
	motion.position = point + Vector2(30,24)
	motion.relative = Vector2(30,24)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	canvas.call("_on_gui_input",motion)
	_check(not before.is_equal_approx(canvas.get("_camera")), "left drag beginning in a transparent ore corner pans the canvas")
	canvas.queue_free()
	await process_frame

func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)
