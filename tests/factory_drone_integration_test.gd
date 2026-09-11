extends SceneTree

## Integration probes use the actual content database, state serialization,
## simulation custody adapter and interstellar reservation authority.
var failures: Array[String] = []
var database: ContentDatabase
var simulation: SimulationEngine
var state: SpaceGameState
const WORLD := "drone-integration"
const LOCATION := "earth_orbit"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game: Variant = root.get_node_or_null("Game")
	if game != null:
		game.set_process(false)
		game.persistence_enabled = false
	database = ContentDatabase.new()
	if not database.load_from_file("res://data/content.json"):
		_check(false, "actual content database loads")
		_finish()
		return
	simulation = SimulationEngine.new(database)
	_test_content_contracts()
	_test_new_world_and_tower_eligibility()
	_test_legacy_roundtrip_and_overcapacity()
	_test_empty_and_loaded_flights_roundtrip()
	_test_shared_incoming_reservations()
	_test_startup_chain_without_roads()
	_finish()


func _fresh() -> Dictionary:
	state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.factory_worlds.clear()
	state.location_inventory(LOCATION).clear()
	state.logistics_network["shipments"] = []
	var world := simulation.factory_grid.create_world(WORLD, LOCATION, Vector2i(192, 128), 7311)
	state.factory_worlds[WORLD] = world
	return world


func _place(world: Dictionary, definition: String, position: Vector2i, id: String, recipe: String = "") -> bool:
	var result: Dictionary = simulation.factory_grid.place_entity_immediate(world, definition, position, recipe, id)
	_check(bool(result.get("ok", false)), "place %s: %s" % [id, result])
	return bool(result.get("ok", false))


func _test_content_contracts() -> void:
	var towers: Array[String] = []
	for definition_id in database.factory_buildings:
		var definition: Dictionary = database.factory_buildings[definition_id]
		if bool(definition.get("drone_tower", false)):
			towers.append(str(definition_id))
		if str(definition.get("kind", "")) in ["EXTRACTOR", "MACHINE"]:
			_check(int(definition.get("output_capacity", 0)) == 20, "%s production output buffer is 20" % definition_id)
		for recipe_id in definition.get("recipe_ids", []):
			var recipe: Dictionary = database.factory_recipes.get(str(recipe_id), {})
			var ten_batches := 0
			for ingredient in recipe.get("inputs", []):
				ten_batches += int(ingredient.get("quantity", 0)) * 10
			_check(int(definition.get("input_capacity", 0)) >= ten_batches, "%s fits all ten-batch inputs for %s simultaneously" % [definition_id, recipe_id])
	towers.sort()
	_check(towers == ["grid_drone_tower", "grid_planetary_core"], "only the explicit drone tower and development core dispatch drones")
	_check(int(database.factory_grid_rules.get("drone_cargo_capacity", 0)) == 10, "actual content configures ten-item drones")
	_check(int(database.factory_grid_rules.get("drone_input_batches", 0)) == 10, "actual content configures ten recipe batches as demand targets")
	var world := _fresh()
	if not _place(world, "grid_engineering_works", Vector2i(30, 10), "works"):
		return
	var configured: Dictionary = simulation.factory_grid.set_entity_recipe(world, "works", "manufacture_grid_drone_tower")
	_check(bool(configured.get("ok", false)), "engineering works can select the tower manufacturing recipe through the real domain API")
	var recipe: Dictionary = database.factory_recipes.get("manufacture_grid_drone_tower", {})
	_check(recipe.get("outputs", []).any(func(output): return str(output.get("item", "")) == "building_grid_drone_tower" and int(output.get("quantity", 0)) == 1), "tower manufacturing yields one deployable tower item")
	var snapshot: Dictionary = simulation.factory_grid.workspace_snapshot(world)
	for entity in snapshot.get("entities", []):
		if str(entity.get("id", "")) != "works":
			continue
		for ingredient in recipe.get("inputs", []):
			_check(int(entity.get("input_targets", {}).get(str(ingredient.get("item", "")), 0)) == int(ingredient.get("quantity", 0)) * 10, "workspace projects recipe-proportional ten-batch targets")
	if not bool(configured.get("ok", false)) or not _place(world, "grid_planetary_core", Vector2i(10, 40), "core"):
		return
	for ingredient in recipe.get("inputs", []):
		state.location_inventory(LOCATION)[str(ingredient.get("item", ""))] = int(ingredient.get("quantity", 0))
	for tick in range(70):
		simulation._progress_runtime(state, 1000.0)
	_check(_owned("building_grid_drone_tower") == 1, "engineering works actually manufactures one tower kit from drone-delivered ingredients without roads")
	if not _place(world, "grid_engineering_works", Vector2i(80, 20), "circuit", "dsp_circuit_board"):
		return
	var circuit_found := false
	for entity in simulation.factory_grid.workspace_snapshot(world).get("entities", []):
		if str(entity.get("id", "")) == "circuit":
			circuit_found = true
			var targets: Dictionary = entity.get("input_targets", {})
			_check(int(targets.get("copper_ingot", 0)) == 10 and int(targets.get("iron_ingot", 0)) == 20, "the actual circuit recipe projects copper target ten and iron target twenty")
	_check(circuit_found, "configured circuit assembler is projected into the workspace")


func _test_new_world_and_tower_eligibility() -> void:
	var world := _fresh()
	_check(str(world.get("logistics_mode", "")) == "PLANET_SHARED_DRONES", "new worlds use drone logistics")
	_check(world.get("roads", {}).is_empty() and world.get("road_shipments", {}).is_empty(), "new worlds contain no live roads or road cargo")
	if not _place(world, "grid_bulk_depot", Vector2i(10, 10), "ordinary-depot") or not _place(world, "grid_engineering_works", Vector2i(32, 10), "works", "grid_reclaim_metal_stock"):
		return
	world["entities"]["works"]["outputs"] = {"scrap_metal":10}
	simulation._progress_runtime(state, 1.0)
	_check(world.get("drone_shipments", {}).is_empty(), "ordinary storage cannot launch drones even with collectible output nearby")
	if not _place(world, "grid_planetary_core", Vector2i(10, 40), "core") or not _place(world, "grid_drone_tower", Vector2i(60, 10), "tower"):
		return
	var covering: Array = FactoryDroneTransport.covering_towers(world, world["entities"]["works"], database.factory_buildings, database.factory_grid_rules)
	covering.sort()
	_check(covering == ["core", "tower"], "real core and drone tower cover the nearby producer while ordinary depot is excluded")
	var power: Dictionary = simulation.factory_grid.refresh_derived_state(world)
	_check(float(power.get("works", 0.0)) > 0.99, "development core supplies production wirelessly without any road tiles")


func _test_legacy_roundtrip_and_overcapacity() -> void:
	var world := _fresh()
	if not _place(world, "grid_planetary_core", Vector2i(10, 10), "core") or not _place(world, "grid_engineering_works", Vector2i(50, 10), "works", "grid_reclaim_metal_stock"):
		return
	world["entities"]["works"]["outputs"] = {"scrap_metal":27}
	var roads := {"41,9":{"x":41, "y":9, "tier":2, "historic_note":"keep"}}
	world["roads"] = roads.duplicate(true)
	world["road_shipments"] = {
		"ROAD-SHIP-5":{"id":"ROAD-SHIP-5", "source_id":"works", "target_id":"core", "item_id":"scrap_metal", "cargo":{"scrap_metal":7}, "destination_kind":"WAREHOUSE", "remaining_ms":2500.0, "travel_ms":5000.0, "path_tiles":["50,9", "41,9", "20,9"]}
	}
	var serialized := state.to_dictionary()
	var input_save := serialized
	var original := serialized.duplicate(true)
	for round_index in range(3):
		state = SpaceGameState.from_dictionary(serialized, database.domains.keys(), database.regions)
		world = state.factory_worlds[WORLD]
		_check(world.get("roads", {}).is_empty() and world.get("road_shipments", {}).is_empty(), "legacy roads and shipments are inert after roundtrip %d" % round_index)
		_check(world.get("legacy_roads_archive", {}) == roads, "original road records survive unchanged in the inert archive")
		_check(int(world["entities"]["works"]["outputs"].get("scrap_metal", 0)) == 27, "old output above the new cap remains intact on load")
		_check(int(state.factory_world_item_ledger().get("DroneTransit", {}).get("scrap_metal", 0)) == 7, "old loaded road cargo has exactly one drone-transit custodian")
		_check(_owned("scrap_metal") == 34, "buffer and loaded cargo retain all 34 items through repeated save normalization")
		serialized = state.to_dictionary()
	_check(input_save == original, "normalization never mutates the caller's old save dictionary")
	world = simulation.factory_grid.normalize_world(world)
	state.factory_worlds[WORLD] = world
	_check(int(world["entities"]["works"]["outputs"].get("scrap_metal", 0)) == 27, "configured normalization also retains over-capacity output")


func _test_empty_and_loaded_flights_roundtrip() -> void:
	var world := _fresh()
	if not _place(world, "grid_planetary_core", Vector2i(10, 10), "core") or not _place(world, "grid_engineering_works", Vector2i(50, 10), "works", "grid_reclaim_metal_stock"):
		return
	world["entities"]["works"]["outputs"] = {"scrap_metal":10}
	simulation._progress_runtime(state, 1.0)
	var jobs: Dictionary = world.get("drone_shipments", {})
	_check(jobs.size() == 1, "ten finished items dispatch one real collection flight")
	if jobs.size() != 1:
		return
	var id := str(jobs.keys()[0])
	_check(str(jobs[id].get("phase", "")) == "TO_PICKUP" and jobs[id].get("cargo", {}).is_empty(), "collection starts empty and leaves stock in producer custody")
	_check(int(world["entities"]["works"]["outputs"].get("scrap_metal", 0)) == 10, "dispatch reserves ten items without removing them before pickup")
	state = SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	world = state.factory_worlds[WORLD]
	jobs = world.get("drone_shipments", {})
	_check(jobs.has(id) and str(jobs[id].get("phase", "")) == "TO_PICKUP", "empty collection flight survives a real state save/load")
	_check(_owned("scrap_metal") == 10 and state.factory_world_item_ledger().get("DroneTransit", {}).is_empty(), "empty flight reservation is never counted as a second asset")
	if not jobs.has(id):
		return
	var pickup_ms := float(jobs[id].get("remaining_ms", 0.0))
	simulation._progress_runtime(state, pickup_ms + 1.0)
	jobs = world.get("drone_shipments", {})
	_check(jobs.has(id) and int(jobs[id].get("cargo", {}).get("scrap_metal", 0)) == 10, "the actual pickup transfers ten items into drone custody")
	_check(int(world["entities"]["works"]["outputs"].get("scrap_metal", 0)) == 0, "pickup removes producer stock exactly once")
	state = SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	world = state.factory_worlds[WORLD]
	_check(_owned("scrap_metal") == 10 and int(state.factory_world_item_ledger().get("DroneTransit", {}).get("scrap_metal", 0)) == 10, "loaded return flight remains live and conserved through save/load")
	simulation._progress_runtime(state, 15000.0)
	_check(state.item_quantity("scrap_metal", LOCATION) == 10 and world.get("drone_shipments", {}).is_empty(), "restored loaded flight deposits into shared Location storage once")
	_check(world["entities"]["core"].get("inventory", {}).is_empty(), "tower never duplicates Location-owned inventory")


func _test_shared_incoming_reservations() -> void:
	var world := _fresh()
	if not _place(world, "grid_planetary_core", Vector2i(10, 10), "core"):
		return
	world["drone_shipments"] = {"own":{"destination_kind":"WAREHOUSE", "cargo":{"iron_ingot":3}}}
	var remote := simulation.factory_grid.create_world("same-location", LOCATION, Vector2i(32, 32), 4)
	remote["drone_shipments"] = {"other":{"destination_kind":"WAREHOUSE", "cargo":{"iron_ingot":5}}, "consumer":{"destination_kind":"MACHINE", "cargo":{"iron_ingot":11}}}
	state.factory_worlds["same-location"] = remote
	state.logistics_network["shipments"] = [{"id":"external", "destination":LOCATION, "cargo":{"iron_ingot":7}}]
	_check(simulation.logistics.incoming_storage_reservation(state, LOCATION, "iron_ingot") == 15, "LogisticsEngine sums local drone returns and interstellar cargo, excluding consumer deliveries")
	_check(simulation.logistics.incoming_storage_reservation(state, LOCATION, "iron_ingot", "external") == 8, "interstellar delivery can exclude its own reservation while retaining drone claims")
	var capacity := simulation.location_item_storage_capacity(state, LOCATION, "iron_ingot")
	var context := simulation.factory_inventory_context(state, world)
	_check(int(context.get("free_capacity", {}).get("iron_ingot", -1)) == capacity - 12, "factory context subtracts external claims while its own dispatcher counts its three incoming units once")
	state.location_inventory(LOCATION)["iron_ingot"] = capacity - 15
	_check(simulation.location_storage_free_quantity_for_item(state, LOCATION, "iron_ingot") == 0, "combined interstellar and drone reservations prevent shared storage overbooking")


func _test_startup_chain_without_roads() -> void:
	var world := _fresh()
	var deposit: Dictionary = simulation.factory_grid.add_resource_field(world, "iron", "iron_ore", Vector2i(32, 40), Vector2i(24, 24), 1.0, 1.0)
	_check(bool(deposit.get("ok", false)), "real iron deposit can be placed for startup integration")
	if not _place(world, "grid_planetary_core", Vector2i(10, 10), "core") or not _place(world, "grid_surface_mine", Vector2i(36, 43), "mine") or not _place(world, "grid_arc_smelter", Vector2i(58, 12), "smelter", "grid_refine_iron") or not _place(world, "grid_engineering_works", Vector2i(60, 38), "consumer", "grid_reclaim_metal_stock"):
		return
	var saw_flight := false
	var saw_input := false
	for tick in range(180):
		simulation._progress_runtime(state, 1000.0)
		saw_flight = saw_flight or not world.get("drone_shipments", {}).is_empty()
		saw_input = saw_input or int(world["entities"]["consumer"].get("inputs", {}).get("iron_ingot", 0)) > 0
		for id in ["mine", "smelter", "consumer"]:
			_check(_total(world["entities"][id].get("outputs", {})) <= 20, "%s output respects twenty-item capacity during live chain tick %d" % [id, tick])
	var produced: Dictionary = world.get("statistics", {}).get("produced", {})
	_check(int(produced.get("iron_ore", 0)) > 0, "startup miner extracts without roads")
	_check(int(produced.get("iron_ingot", 0)) > 0, "drones deliver mined ore to the actual smelter recipe")
	_check(saw_input and int(produced.get("scrap_metal", 0)) > 0, "downstream consumer receives produced ingots and manufactures its own product")
	_check(saw_flight and state.item_quantity("scrap_metal", LOCATION) >= 10, "surplus downstream production returns in drone batches to shared storage")
	_check(world.get("roads", {}).is_empty() and world.get("road_shipments", {}).is_empty(), "full startup chain neither creates nor requires any roads")


func _owned(item: String) -> int:
	return state.item_quantity(item, LOCATION) + int(state.factory_world_item_holdings().get(item, 0))


func _total(items: Dictionary) -> int:
	var total := 0
	for quantity in items.values():
		total += int(quantity)
	return total


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: drone content, startup production, custody migration, save/load and shared reservations")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)
