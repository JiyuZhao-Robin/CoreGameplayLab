extends SceneTree

var failures: Array[String] = []
var game: Variant
var command_serial := 0
const WORLD := "planet-road-fixture"
const LOCATION := "earth_orbit"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content loads")
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	_test_shared_stock_migration()
	_fixture()
	_test_commands_and_power()
	_test_transport_custody()
	_test_shared_capacity_and_projection()
	_test_reservation_contract()
	if failures.is_empty():
		print("PASS: planetary road application flow")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_shared_stock_migration() -> void:
	var starter: Dictionary = game.state.factory_worlds["earth-surface-grid"]
	_check(game.state.item_quantity("scrap_metal", LOCATION) == 44, "founding goods remain in the shared planetary inventory")
	_check(starter["entities"]["starter-depot"]["inventory"].is_empty(), "warehouse does not duplicate shared stock")
	starter["entities"]["starter-depot"]["inventory"] = {"iron_ore":7}
	var before: Dictionary = game.state.asset_ledger_snapshot()
	game.simulation._reconcile_planetary_factory_inventory(game.state)
	_check(game.state.item_quantity("iron_ore", LOCATION) == 7, "legacy depot stock moves into Location custody")
	_check(_owned("iron_ore") == 7, "legacy reconciliation conserves stock")
	var saved: Dictionary = game.state.to_dictionary()
	game.simulation._reconcile_planetary_factory_inventory(game.state)
	_check(game.state.to_dictionary() == saved, "reconciliation is idempotent")
	_check(not before.is_empty(), "asset ledger is available for migration auditing")


func _fixture() -> void:
	game.state.factory_worlds.clear()
	game.state.location_inventory(LOCATION).clear()
	var footprint := {"width":1, "height":1}
	var definitions := {
		"road_test_power":{"id":"road_test_power", "kind":"POWER", "footprint":footprint, "power_generation_kw":100.0},
		"road_test_machine":{"id":"road_test_machine", "kind":"MACHINE", "footprint":footprint, "power_demand_kw":20.0, "recipe_ids":["road_test_recipe"], "speed":1.0, "input_capacity":8, "output_capacity":8},
		"road_test_store":{"id":"road_test_store", "kind":"STORAGE", "footprint":footprint, "inventory_capacity":20}
	}
	var recipes := {"road_test_recipe":{"id":"road_test_recipe", "duration_seconds":1.0, "inputs":[{"item":"iron_ore", "quantity":1}], "outputs":[{"item":"iron_ingot", "quantity":1}]}}
	game.content.factory_buildings.merge(definitions, true)
	game.content.factory_recipes.merge(recipes, true)
	game.simulation.factory_grid.configure(game.content.factory_buildings, game.content.factory_recipes, game.content.factory_grid_rules)
	var factory: Variant = game.simulation.factory_grid
	var world: Dictionary = factory.create_world(WORLD, LOCATION, Vector2i(32, 16), 2)
	game.state.factory_worlds[WORLD] = world
	_check(factory.place_entity_immediate(world, "road_test_power", Vector2i(1, 0), "", "power").get("ok", false), "fixture power placed")
	_check(factory.place_entity_immediate(world, "road_test_machine", Vector2i(5, 0), "road_test_recipe", "machine").get("ok", false), "fixture machine placed")
	_check(factory.place_entity_immediate(world, "road_test_store", Vector2i(9, 0), "", "warehouse").get("ok", false), "fixture warehouse placed")
	game.simulation.refresh_factory_runtime_views(game.state)


func _test_commands_and_power() -> void:
	_check(float(_world()["entities"]["machine"].get("power_factor", 0.0)) == 0.0, "machine starts without electricity when not road-connected")
	var tiles: Array = []
	for x in range(1, 10):
		tiles.append({"x":x, "y":1})
	var intent := _intent("BUILD_ROAD", {"tiles":tiles, "tier":1})
	var built: Dictionary = game.execute_factory_command(intent)
	_check(built.get("accepted", false), "basic road is affordable before the first iron production")
	_check(_world().get("roads", {}).size() == 9, "road batch creates exactly its tiles")
	_check(float(_world()["entities"]["machine"].get("power_factor", 0.0)) > 0.99, "paused-clock road command immediately supplies power")
	var replay: Dictionary = game.execute_factory_command(intent)
	_check(replay.get("replayed", false) and _world()["roads"].size() == 9, "replay does not duplicate road construction")
	var before: Dictionary = game.state.to_dictionary()
	var invalid := _command("BUILD_ROAD", {"tiles":[{"x":12, "y":1}, {"x":32, "y":1}], "tier":1})
	_check(not invalid.get("accepted", true) and game.state.to_dictionary() == before, "out-of-bounds batch is atomic and leaves no partial road")
	var malformed := _command("BUILD_ROAD", {"tiles":[{"x":1.2, "y":2}], "tier":1})
	_check(not malformed.get("accepted", true), "fractional road coordinates are rejected")
	var upgrade := _command("BUILD_ROAD", {"tiles":[{"x":1, "y":1}], "tier":2})
	_check(not upgrade.get("accepted", true), "reinforced road cannot bypass material cost")
	game.state.location_inventory(LOCATION)["iron_ingot"] = 2
	upgrade = _command("BUILD_ROAD", {"tiles":[{"x":1, "y":1}, {"x":1, "y":1}], "tier":2})
	_check(upgrade.get("accepted", false) and game.state.item_quantity("iron_ingot", LOCATION) == 1, "duplicate input tiles charge only one upgrade")
	upgrade = _command("BUILD_ROAD", {"tiles":[{"x":1, "y":1}], "tier":2})
	_check(upgrade.get("accepted", false) and game.state.item_quantity("iron_ingot", LOCATION) == 1, "existing upgrade is not charged twice")
	var old_link := _command("CONNECT_ENTITIES", {"link_kind":"POWER", "source_id":"power", "target_id":"machine"})
	_check(old_link.get("reason_code", "") == "LEGACY_LINKS_RETIRED", "old port commands cannot bypass the road network")
	var removed := _command("REMOVE_ROAD", {"tiles":[{"x":3, "y":1}]})
	_check(removed.get("accepted", false) and float(_world()["entities"]["machine"].get("power_factor", 1.0)) == 0.0, "cutting road immediately splits electricity")
	_check(game.state.item_quantity("iron_ingot", LOCATION) == 1, "road break leaves planetary stock untouched")
	_command("BUILD_ROAD", {"tiles":[{"x":3, "y":1}], "tier":1})


func _test_transport_custody() -> void:
	game.state.location_inventory(LOCATION)["iron_ore"] = 8
	var initial_iron := _owned("iron_ore") + _owned("iron_ingot")
	var observed_transit := false
	for tick in range(40):
		game.simulation._progress_runtime(game.state, 1000.0)
		if not _world().get("road_shipments", {}).is_empty():
			observed_transit = true
			var ledger: Dictionary = game.state.factory_world_item_ledger()
			_check(not ledger.get("RoadTransit", {}).is_empty(), "in-transit cargo appears in the asset ledger")
		_check(_owned("iron_ore") + _owned("iron_ingot") == initial_iron, "each unit has exactly one live custodian through road delivery and 1:1 production")
	_check(observed_transit, "road delivery has actual in-transit state")
	_check(game.state.item_quantity("iron_ingot", LOCATION) > 1, "machine automatically picks up ore and delivers produced ingots to planetary inventory")
	var saved: Dictionary = game.state.to_dictionary()
	var restored := SpaceGameState.from_dictionary(saved, game.content.domains.keys())
	_check(restored.factory_worlds[WORLD].get("roads", {}) == _world().get("roads", {}), "road topology survives normalization")
	_check(restored.factory_world_item_holdings() == game.state.factory_world_item_holdings(), "transport custody survives transaction/save normalization")


func _test_shared_capacity_and_projection() -> void:
	var capacity: int = game.simulation.location_item_storage_capacity(game.state, LOCATION, "iron_ore")
	game.state.location_inventory(LOCATION)["iron_ore"] = capacity
	game.state.location_inventory(LOCATION)["copper_ore"] = 0
	_check(game.simulation.location_storage_free_quantity_for_item(game.state, LOCATION, "iron_ore") == 0, "full resource slot blocks only that item")
	_check(game.simulation.location_storage_free_quantity_for_item(game.state, LOCATION, "copper_ore") > 0, "iron cannot crowd out copper")
	var snapshot: Dictionary = game.factory_workspace_snapshot(WORLD)
	_check(snapshot.get("logistics_mode", "") == "PLANET_SHARED_ROADS" and snapshot.get("links", []).is_empty(), "workspace exposes only the road logistics model")
	_check(snapshot.get("shared_inventory", {}).get("iron_ore", 0) == capacity, "workspace exposes the shared inventory")
	var location_snapshot: Dictionary = game.location_operations_snapshot(LOCATION)
	for row in location_snapshot.get("inventory", []):
		if str(row.get("item_id", "")) == "iron_ore":
			_check(int(row.get("quantity", 0)) == capacity and int(row.get("capacity", 0)) == capacity, "location stock card does not duplicate warehouse capacity or goods")


func _world() -> Dictionary:
	return game.state.factory_worlds[WORLD]


func _test_reservation_contract() -> void:
	var world := _world()
	var saved_jobs: Dictionary = world.get("road_shipments", {}).duplicate(true)
	world["road_shipments"] = {"own-reservation":{"destination_kind":"WAREHOUSE", "cargo":{"copper_ore":3}}}
	var remote: Dictionary = game.simulation.factory_grid.create_world("same-planet", LOCATION, Vector2i(8, 8))
	remote["road_shipments"] = {"other-reservation":{"destination_kind":"WAREHOUSE", "cargo":{"copper_ore":5}}}
	game.state.factory_worlds["same-planet"] = remote
	var capacity: int = game.simulation.location_item_storage_capacity(game.state, LOCATION, "copper_ore")
	var context: Dictionary = game.simulation.factory_inventory_context(game.state, world)
	_check(int(context["free_capacity"].get("copper_ore", 0)) == capacity - 5, "context excludes own road reservations but includes other worlds on the same planet")
	_check(game.simulation.location_storage_free_quantity_for_item(game.state, LOCATION, "copper_ore") == capacity - 8, "global ingress reserves every warehouse-bound road shipment once")
	game.state.factory_worlds.erase("same-planet")
	world["road_shipments"] = saved_jobs


func _owned(item_id: String) -> int:
	return game.state.item_quantity(item_id, LOCATION) + int(game.state.factory_world_item_holdings().get(item_id, 0))


func _intent(kind: String, payload: Dictionary) -> Dictionary:
	command_serial += 1
	return {"protocol_version":1, "command_id":"road-flow-%d" % command_serial, "kind":kind, "world_id":WORLD, "base_topology_revision":int(_world().get("topology_revision", 0)), "payload":payload}


func _command(kind: String, payload: Dictionary) -> Dictionary:
	return game.execute_factory_command(_intent(kind, payload))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
