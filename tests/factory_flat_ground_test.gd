extends SceneTree

const Terrain = preload("res://src/core/factory_terrain.gd")
const Canvas = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const WORLD := "earth-surface-grid"
# Captured from real new-game content immediately before the flat-ground change.
const ORE_BASELINE := "3fb7f89db0c946d9f482243eaa73eb424e4ec42ec581e947fdde8a80ebe17cbc"
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game: Node = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content loads")
	game.content = database
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation = SimulationEngine.new(database)
	game.simulation.ensure_frontier_state(game.state)
	var world: Dictionary = game.state.factory_worlds[WORLD]
	_check(world.resource_fields.size() == 27 and JSON.stringify(world.resource_fields).sha256_text() == ORE_BASELINE, "all new-game ore descriptors exactly match the pre-change baseline")
	var fields: Dictionary = world.resource_fields.duplicate(true)
	for profile in ["earth_v2", "", "legacy"]:
		var old := world.duplicate(true)
		old.terrain_profile = profile
		old.tile_deltas["8:8"] = {"terrain_override":"WATER"}
		old.tile_deltas["24:8"] = {"terrain_override":"MOUNTAIN"}
		old.tile_deltas["47:47"] = {"terrain_override":"FOREST", "resource_cleared":true}
		var original := old.duplicate(true)
		var loaded: Dictionary = game.simulation.factory_grid.normalize_world(JSON.parse_string(JSON.stringify(old)))
		var snapshot: Dictionary = game.simulation.factory_grid.workspace_snapshot(loaded)
		for tile in [Vector2i(8,8), Vector2i(24,8), Vector2i(47,47), Vector2i(400,300), Vector2i(900,600)]:
			for source in [old, loaded, snapshot]:
				var surface := Terrain.surface_sample(source, tile)
				_check(Terrain.terrain_type(source,tile) == "PLAIN" and Terrain.is_buildable(source,tile), "new/old/snapshot geography is buildable plain")
				_check(surface.forest_density == 0.0 and surface.water_depth == 0.0 and surface.rock == 0.0 and surface.elevation == 0.38, "flat surface has no forest, water, rock or relief")
		var tile_snapshot: Dictionary = game.simulation.factory_grid.tile_snapshot(loaded,Vector2i(47,47))
		_check(tile_snapshot.terrain_type == "PLAIN" and tile_snapshot.terrain_buildable and tile_snapshot.resource_id == "", "inspector suppresses old terrain overrides and retains cleared-resource deltas")
		_check(_save_equal(loaded.resource_fields,fields) and _save_equal(loaded.tile_deltas,old.tile_deltas) and old == original, "loading and sampling preserve ore and saved deltas")
	_check(not Terrain.is_buildable(world,Vector2i(-1,0)) and not Terrain.is_buildable(world,Vector2i(1024,0)), "flat ground retains map bounds")
	world.tile_deltas["8:8"] = {"terrain_override":"WATER"}
	world.tile_deltas["100:8"] = {"terrain_override":"MOUNTAIN"}
	var result: Dictionary = game.execute_factory_command({"protocol_version":1,"command_id":"flat-core","world_id":WORLD,"base_topology_revision":int(world.topology_revision),"kind":"DEPLOY_BUILDING","payload":{"definition_id":"grid_planetary_core","origin":{"x":8,"y":8}}})
	_check(result.get("accepted",false), "actual core deployment accepts former water")
	world = game.state.factory_worlds[WORLD]
	var road: Dictionary = game.simulation.factory_grid.edit_roads(world,[{"x":100,"y":8}],1)
	_check(road.get("ok",false), "roads accept former mountain: %s" % road)
	var collision: Dictionary = game.simulation.factory_grid.can_place_entity(world,"grid_planetary_core",Vector2i(8,8))
	_check(not collision.get("ok",false) and collision.get("reason_code") == "FOOTPRINT_OCCUPIED", "flat ground retains building collision")
	var restored := SpaceGameState.from_dictionary(JSON.parse_string(JSON.stringify(game.state.to_dictionary())),database.domains.keys(),database.regions)
	_check(_save_equal(restored.factory_worlds[WORLD].resource_fields,fields) and _save_equal(restored.factory_worlds[WORLD].entities,world.entities) and _save_equal(restored.factory_worlds[WORLD].roads,world.roads), "real save roundtrip preserves ore, buildings and roads")
	var snapshot: Dictionary = game.factory_workspace_snapshot(WORLD)
	await _check_rendering(snapshot)
	if failures.is_empty():
		print("FACTORY_FLAT_GROUND_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _check_rendering(snapshot: Dictionary) -> void:
	var capture := OS.get_cmdline_user_args().has("--capture")
	if capture:
		_check(DisplayServer.get_name() != "headless", "capture uses real renderer")
		root.size = Vector2i(3840,2160)
	var canvas := Canvas.new()
	canvas.size = Vector2(1920,1080)
	root.add_child(canvas)
	canvas.apply_snapshot(snapshot)
	canvas.set("_zoom",3.0)
	canvas.focus_tile(Vector2i(64,48))
	for frame in range(5):
		await process_frame
	var renderer: RefCounted = canvas.get("_terrain_renderer")
	var foliage: RefCounted = renderer.get("_foliage")
	_check(foliage.get("visible_tree_count") == 0 and foliage.get("_texture") == null and foliage.call("cached_chunk_count") == 0, "flat canvas neither loads nor renders tree art")
	_check(renderer.get("last_visible_chunks") > 0, "production ground is drawn")
	for entry in renderer.get("_cache").values():
		var material: ShaderMaterial = entry.node.material
		_check(not material.get_shader_parameter("earth_surface"), "mountain relief shader is disabled")
		var mask: Image = entry.mask.get_image()
		for y in range(mask.get_height()):
			for x in range(mask.get_width()):
				_check(mask.get_pixel(x,y) == Color(0,0,0,0), "visible geography mask contains only plain ground")
	if capture:
		await RenderingServer.frame_post_draw
		var picture := root.get_texture().get_image()
		_check(picture.get_size() == Vector2i(3840,2160), "actual 4K capture")
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts/ui/flat-ground"))
		picture.save_png("res://artifacts/ui/flat-ground/plain-with-ore.png")
		picture.resize(1440,810,Image.INTERPOLATE_LANCZOS)
		picture.save_png("res://artifacts/ui/flat-ground/plain-with-ore-review.png")
	canvas.queue_free()
	await process_frame

func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)

func _save_equal(left: Dictionary, right: Dictionary) -> bool:
	# JSON stores both integer and float numbers as floats on load.
	return JSON.parse_string(JSON.stringify(left)) == JSON.parse_string(JSON.stringify(right))
