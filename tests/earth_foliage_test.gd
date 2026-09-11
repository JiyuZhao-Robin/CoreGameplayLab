extends SceneTree

const Terrain = preload("res://src/core/factory_terrain.gd")
const Renderer = preload("res://src/ui/workspaces/factory/factory_terrain_renderer.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var world := {
		"world_id":"earth-foliage-test", "terrain_enabled":true, "terrain_profile":"earth_v2",
		"seed":730201, "terrain_seed":730201, "generator_version":4, "terrain_scale_tiles":48.0,
		"bounds":{"origin":{"x":0,"y":0},"size":{"x":1024,"y":640}}, "terrain_safe_rect":{},
		"tile_deltas":{}, "entities":[], "roads":[], "construction_orders":[], "resource_fields":[]}
	var center := _forest_center(world)
	_check(center != Vector2i.ZERO, "actual Earth sample contains a dense forest fixture")
	var view := Rect2(Vector2(center) - Vector2(24,24), Vector2(48,48))
	var host := Control.new()
	host.size = Vector2(768,768)
	root.add_child(host)
	var painter := Renderer.new()
	painter.configure(world)
	painter.draw_ground(host, world, view, 12.0, -view.position * 12.0)
	var foliage: RefCounted = painter.get("_foliage")
	var original: Array[Rect2] = _canopies(foliage)
	_check(original.size() > 5, "dense natural forest generates real canopy mesh quads")
	_check(foliage.get("_texture") != null, "checked-in tree art loads for the production mesh")
	if original.is_empty():
		host.queue_free()
		await process_frame
		_finish()
		return
	var asset: Texture2D = foliage.get("_texture")
	_check(asset.resource_path.ends_with("kenney_nature/kenney_earth_canopies_v1.png"), "canopies use the adopted Kenney model atlas")
	var pristine := world.duplicate(true)
	var ground_builds := painter.mesh_build_count
	var tree_builds: int = foliage.get("mesh_build_count")
	painter.configure(world)
	painter.draw_ground(host, world, view, 12.0, Vector2(10,20))
	_check(painter.mesh_build_count == ground_builds and int(foliage.get("mesh_build_count")) == tree_builds, "stationary snapshot and changed camera transform reuse all meshes")
	world["elapsed_ms"] = 1234
	world["runtime_revision"] = 57
	painter.configure(world)
	painter.draw_ground(host, world, view, 12.0, Vector2.ZERO)
	_check(int(foliage.get("mesh_build_count")) == tree_builds, "runtime-only updates retain canopy meshes")
	_check(_canopies(foliage) == original, "unchanged geography yields identical world-space canopies")

	var tree_tile := Vector2i(original[0].get_center().floor())
	var road := Rect2(Vector2(tree_tile), Vector2.ONE)
	world.roads = [{"x":tree_tile.x,"y":tree_tile.y,"tier":1}]
	_redraw(painter,host,world,view)
	_check(painter.mesh_build_count == ground_builds, "road occupancy does not invalidate continuous ground")
	_check(int(foliage.get("mesh_build_count")) > tree_builds, "new road invalidates canopy geometry")
	_check(not _intersects_any(_canopies(foliage), road), "no tree crown overlaps a built road tile")
	_check(_canopies(foliage).size() < original.size(), "road construction removes the previously visible crown")
	world.roads = []
	_redraw(painter,host,world,view)
	_check(_canopies(foliage) == original, "removing road restores exactly the deterministic original forest")

	var building := _footprint(tree_tile - Vector2i(2,2),Vector2i(5,5))
	for category in ["entities", "construction_orders"]:
		world[category] = [{"id":"forest-clearance", "footprint":building}]
		_redraw(painter,host,world,view)
		_check(not _intersects_any(_canopies(foliage), Rect2(Vector2(tree_tile-Vector2i(2,2)),Vector2(5,5))), "%s clears the full canopy, including overhang from adjacent cells" % category)
		_check(painter.mesh_build_count == ground_builds, "%s leaves ground chunks intact" % category)
		world[category] = []

	var field := {"id":"forest-ore", "shape":"IRREGULAR", "seed":611, "resource_id":"iron_ore",
		"footprint":_footprint(tree_tile-Vector2i(16,12),Vector2i(32,24))}
	world.resource_fields = [field]
	_redraw(painter,host,world,view)
	_check(_field_clear(_canopies(foliage),field), "ore clearance follows actual mineable cells beneath every crown")
	_check(_canopies(foliage).size() < original.size(), "actual ore field removes forest at its center")
	var corner_tile := tree_tile-Vector2i(16,12)
	var corner := Rect2(Vector2(corner_tile)+Vector2(0.1,0.1),Vector2(0.5,0.5))
	_check(not Terrain.field_contains(field,corner_tile), "irregular ore fixture has a transparent bounding-box corner")
	_check(not bool(foliage.call("_blocked",corner)), "irregular deposit's empty corner remains available to vegetation")
	var previous_tree_builds: int = foliage.get("mesh_build_count")
	field.shape = "RECTANGLE"
	world.resource_fields = [field]
	_redraw(painter,host,world,view)
	_check(bool(foliage.call("_blocked",corner)), "changing resource shape clears the newly mineable corner")
	_check(int(foliage.get("mesh_build_count")) > previous_tree_builds and painter.mesh_build_count == ground_builds, "resource geometry invalidates only vegetation")

	world = pristine.duplicate(true)
	painter.configure(world)
	for index in range(110):
		var moving_view := Rect2(float(index % 11)*16.0,float(index / 11)*16.0,16.0,16.0)
		painter.draw_ground(host,world,moving_view,12.0,-moving_view.position*12.0)
		_check(int(foliage.call("cached_chunk_count")) <= 96 and painter.cached_chunk_count() <= 96, "long-distance panning respects both 96-chunk cache budgets")
	_check(world == pristine, "all rendering and occupancy inspection preserve the source snapshot")
	var clearing := pristine.duplicate(true)
	clearing.terrain_safe_rect = clearing.bounds.duplicate(true)
	_redraw(painter,host,clearing,Rect2(0,0,128,64))
	_check(_canopies(foliage).is_empty(), "zero-density protected ground never produces a stray crown")
	painter.hide_ground()
	_check(int(foliage.get("visible_tree_count")) == 0, "hiding geography resets visible tree accounting")
	host.queue_free()
	await process_frame
	painter.configure({"world_id":"next"})
	_check(int(foliage.call("cached_chunk_count")) == 0, "freeing the canvas and changing worlds releases foliage safely")
	_finish()

func _forest_center(world: Dictionary) -> Vector2i:
	for y in range(48,592,16):
		for x in range(48,976,16):
			var sample: Dictionary = Terrain.surface_sample(world,Vector2i(x,y))
			if str(sample.terrain) == "FOREST" and float(sample.forest_density) > 0.8:
				return Vector2i(x,y)
	return Vector2i.ZERO

func _redraw(painter: RefCounted, host: Control, world: Dictionary, view: Rect2) -> void:
	painter.configure(world)
	painter.draw_ground(host,world,view,12.0,-view.position*12.0)

func _canopies(foliage: RefCounted) -> Array[Rect2]:
	var result: Array[Rect2] = []
	var cache: Dictionary = foliage.get("_cache")
	for entry in cache.values():
		var node: MeshInstance2D = entry.node
		if not node.visible or node.mesh == null:
			continue
		var arrays := node.mesh.surface_get_arrays(0)
		var vertices: PackedVector2Array = arrays[Mesh.ARRAY_VERTEX]
		for index in range(0,vertices.size(),4):
			result.append(Rect2(vertices[index]+Vector2(entry.origin),vertices[index+2]-vertices[index]))
	return result

func _intersects_any(canopies: Array[Rect2], rect: Rect2) -> bool:
	for canopy in canopies:
		if canopy.intersects(rect):
			return true
	return false

func _field_clear(canopies: Array[Rect2], field: Dictionary) -> bool:
	for canopy in canopies:
		for y in range(floori(canopy.position.y),ceili(canopy.end.y)):
			for x in range(floori(canopy.position.x),ceili(canopy.end.x)):
				if Terrain.field_contains(field,Vector2i(x,y)):
					return false
	return true

func _footprint(origin: Vector2i, extent: Vector2i) -> Dictionary:
	return {"origin":{"x":origin.x,"y":origin.y},"size":{"x":extent.x,"y":extent.y}}

func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)

func _finish() -> void:
	if failures.is_empty():
		print("EARTH_FOLIAGE_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)
