extends SceneTree

const Terrain = preload("res://src/core/factory_terrain.gd")
const WORLD := "earth-surface-grid"
var failures: Array[String] = []
var game: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "real content catalog loads")
	game.content = database
	game.state = SpaceGameState.create_new(database.domains.keys(),database.regions)
	game.simulation = SimulationEngine.new(database)
	game.simulation.ensure_frontier_state(game.state)
	var world: Dictionary = game.state.factory_worlds[WORLD]
	_check(world.get("terrain_profile", "") == "earth_v2", "new Earth explicitly opts into detailed geography")
	var grid: FactoryGridSimulation = game.simulation.factory_grid
	var normalized := grid.normalize_world(world)
	var snapshot: Dictionary = game.factory_workspace_snapshot(WORLD)
	_check(normalized.get("terrain_profile", "") == "earth_v2" and snapshot.get("terrain_profile", "") == "earth_v2", "normalization and player snapshot preserve the generator identity")
	_check(snapshot.get("seed") == world.get("seed") and snapshot.get("terrain_safe_rect") == world.get("terrain_safe_rect"), "player rendering receives the same seed and starter geography")
	var encoded: String = JSON.stringify(game.state.to_dictionary())
	var restored := SpaceGameState.from_dictionary(JSON.parse_string(encoded),database.domains.keys(),database.regions)
	game.simulation.ensure_frontier_state(restored)
	var loaded: Dictionary = restored.factory_worlds[WORLD]
	_check(loaded.get("terrain_profile", "") == "earth_v2", "actual state serialization retains explicit Earth profile")
	for tile in [Vector2i(40,40),Vector2i(199,220),Vector2i(380,300),Vector2i(214,430),Vector2i(800,500)]:
		var original: Dictionary = Terrain.surface_sample(world,tile)
		_check(original == Terrain.surface_sample(normalized,tile) and original == Terrain.surface_sample(snapshot,tile) and original == Terrain.surface_sample(loaded,tile), "save, normalization and rendering agree on geography at %s" % tile)
	_test_legacy_world(database, world)
	_test_blocked_landing(world)
	_test_starter_miners(grid, world)
	if failures.is_empty():
		print("EARTH_TERRAIN_INTEGRATION_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_legacy_world(database: ContentDatabase, earth: Dictionary) -> void:
	var legacy := earth.duplicate(true)
	legacy.erase("terrain_profile")
	var samples := {}
	for tile in [Vector2i(180,140),Vector2i(280,220),Vector2i(500,400),Vector2i(800,520)]:
		samples[tile] = Terrain.terrain_type(legacy,tile)
	var state := SpaceGameState.create_new(database.domains.keys(),database.regions)
	state.factory_worlds[WORLD] = legacy
	var simulation := SimulationEngine.new(database)
	simulation.ensure_frontier_state(state)
	var retained: Dictionary = state.factory_worlds[WORLD]
	_check(str(retained.get("terrain_profile", "")) != "earth_v2", "opening an unmarked existing Earth never silently regenerates it")
	for tile in samples:
		_check(Terrain.terrain_type(retained,tile) == samples[tile], "legacy terrain stays unchanged after frontier normalization")
	var disabled := legacy.duplicate(true)
	disabled["terrain_enabled"] = false
	var normalized := simulation.factory_grid.normalize_world(disabled)
	_check(Terrain.terrain_type(normalized,Vector2i(300,300)) == "PLAIN", "terrain-disabled saves stay buildable")


func _test_blocked_landing(world: Dictionary) -> void:
	# Discover naturally generated blockers; no tile override can hide a mismatch
	# between the new terrain generator and the actual command boundary.
	var blocked := {}
	for y in range(112,600,8):
		for x in range(152,980,8):
			var tile := Vector2i(x,y)
			var terrain: String = Terrain.terrain_type(world,tile)
			if terrain in ["WATER","MOUNTAIN"] and not blocked.has(terrain):
				blocked[terrain] = tile
			if blocked.size() == 2:
				break
		if blocked.size() == 2:
			break
	_check(blocked.size() == 2, "real new Earth provides water and mountain placement blockers")
	for terrain in blocked:
		var tile: Vector2i = blocked[terrain]
		var before: Dictionary = game.state.to_dictionary().duplicate(true)
		var result: Dictionary = game.execute_factory_command({
			"protocol_version":1,"command_id":"earth-blocked-%s" % terrain,
			"world_id":WORLD,"base_topology_revision":int(world.topology_revision),
			"kind":"DEPLOY_BUILDING","payload":{"definition_id":"grid_planetary_core","origin":{"x":tile.x,"y":tile.y}}
		})
		_check(not result.get("accepted",false) and result.get("reason_code") == "TERRAIN_BLOCKED", "%s rejects actual core deployment" % terrain)
		_check(game.state.to_dictionary() == before, "blocked %s landing is atomic and consumes no building" % terrain)


func _test_starter_miners(grid: FactoryGridSimulation, world: Dictionary) -> void:
	var isolated := world.duplicate(true)
	for field_id in ["starter-iron-field","starter-copper-field"]:
		var field: Dictionary = isolated.resource_fields[field_id]
		var footprint: Dictionary = field.footprint
		var origin := Vector2i(int(footprint.origin.x) + (int(footprint.size.x)-11)/2,int(footprint.origin.y) + (int(footprint.size.y)-11)/2)
		var solid_core := true
		for y in range(origin.y,origin.y+11):
			for x in range(origin.x,origin.x+11):
				solid_core = solid_core and Terrain.is_buildable(isolated,Vector2i(x,y)) and Terrain.field_contains(field,Vector2i(x,y))
		_check(solid_core, "%s preserves the buildable 11 by 11 mining core" % field_id)
		var placed := grid.place_entity_immediate(isolated,"grid_surface_mine",origin,"",field_id + "-miner")
		_check(placed.get("ok",false), "%s accepts the real current miner footprint and resource rules: %s" % [field_id,placed])
		if placed.get("ok",false):
			var entity: Dictionary = isolated.entities[placed.entity_id]
			_check(entity.footprint.size == {"x":11,"y":11} and entity.resource_id == field.resource_id, "starter miner retains the current size and correct resource")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
