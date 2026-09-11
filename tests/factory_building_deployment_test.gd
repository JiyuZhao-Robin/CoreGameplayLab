extends SceneTree

var failures: Array[String] = []
var game: Node
var serial := 0
const WORLD := "earth-surface-grid"
const LOCATION := "earth_orbit"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	_test_content_and_start()
	_test_deploy_transactions()
	_test_ore_to_new_building()
	if failures.is_empty():
		print("FACTORY_BUILDING_DEPLOYMENT_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _fresh(land: bool = true) -> void:
	game.state = SpaceGameState.create_new(game.content.domains.keys(), game.content.regions)
	game.simulation = SimulationEngine.new(game.content)
	game.simulation.ensure_frontier_state(game.state)
	if land:
		_check(_deploy("grid_planetary_core", Vector2i(110,32)).get("accepted", false), "player chooses and deploys the starting core")


func _command(kind: String, payload: Dictionary) -> Dictionary:
	serial += 1
	return game.execute_factory_command({
		"protocol_version":1, "command_id":"building-test-%d" % serial,
		"kind":kind, "world_id":WORLD,
		"base_topology_revision":int(game.state.factory_worlds[WORLD].get("topology_revision", 0)),
		"payload":payload
	})


func _deploy(definition: String, at: Vector2i, recipe: String = "") -> Dictionary:
	return _command("DEPLOY_BUILDING", {"definition_id":definition,"origin":{"x":at.x,"y":at.y},"recipe_id":recipe})


func _test_content_and_start() -> void:
	_fresh(false)
	_check(game.state.factory_worlds[WORLD]["entities"].is_empty(), "no warehouse or base is preplaced")
	_check(not _deploy("grid_surface_mine", Vector2i(52,52)).get("accepted", false), "initial expansion requires core landing first")
	var inventory: Dictionary = game.state.location_inventory(LOCATION)
	var expected := {"building_grid_planetary_core":1}
	for item_id in expected:
		_check(int(inventory.get(item_id, 0)) == expected[item_id], "starter kit includes %s" % item_id)
	var before: Dictionary = game.state.to_dictionary().duplicate(true)
	game.simulation.ensure_frontier_state(game.state)
	_check(game.state.to_dictionary() == before, "starter package is not granted twice")
	var restored := SpaceGameState.from_dictionary(before, game.content.domains.keys(), game.content.regions)
	game.simulation.ensure_frontier_state(restored)
	for item_id in expected:
		_check(restored.item_quantity(item_id, LOCATION) == expected[item_id], "roundtrip does not duplicate %s" % item_id)
	_check(_deploy("grid_planetary_core",Vector2i(110,32)).get("accepted",false), "core deploys immediately at the chosen site")
	for item_id in {"building_grid_surface_mine":2,"building_grid_arc_smelter":2,"building_grid_engineering_works":1}:
		_check(game.state.item_quantity(item_id,LOCATION) == {"building_grid_surface_mine":2,"building_grid_arc_smelter":2,"building_grid_engineering_works":1}[item_id], "landing releases the specified starter equipment: %s" % item_id)
	_check(game.state.item_quantity("building_grid_solar_array",LOCATION) == 0, "base generation replaces starter solar equipment")
	for value in game.content.factory_buildings.values():
		var definition: Dictionary = value
		if definition.get("kind") == "ROUTER" or bool(definition.get("legacy_only", false)):
			continue
		var id := str(definition["id"])
		var recipe: Dictionary = game.content.factory_recipes.get("manufacture_" + id, {})
		_check(not definition.has("construction_cost") and not definition.has("construction_work"), "%s has no onsite BOM/timer" % id)
		_check(recipe.get("outputs", []).size() == 1 and str(recipe.get("outputs", [{}])[0].get("item", "")) == "building_" + id and int(recipe.get("outputs", [{}])[0].get("quantity", 0)) == 1, "%s has a finished building recipe" % id)
		_check(game.content.factory_buildings["grid_engineering_works"]["recipe_ids"].has("manufacture_" + id), "%s is selectable on the engineering machine" % id)


func _test_deploy_transactions() -> void:
	_fresh()
	var item := "building_grid_solar_array"
	game.state.location_inventory(LOCATION)[item] = 4
	var initial_total := _total(item)
	var inventory: Dictionary = game.state.location_inventory(LOCATION)
	inventory["scrap_metal"] = 0
	inventory["electronics"] = 0
	var invalid := _deploy("grid_solar_array", Vector2i(1023,639))
	_check(not invalid.get("accepted", false) and _total(item) == initial_total, "invalid placement is atomic and never charges a building")
	var result := _deploy("grid_solar_array", Vector2i(8,8))
	_check(result.get("accepted", false), "deploy accepts finished stock with no raw materials")
	var entity_id := str(result.get("result", {}).get("entity_id", ""))
	# Public response carries the operation under result.
	if entity_id.is_empty():
		for id in game.state.factory_worlds[WORLD]["entities"]:
			if game.state.factory_worlds[WORLD]["entities"][id].get("definition_id","") == "grid_solar_array":
				entity_id = str(id)
	_check(game.state.factory_worlds[WORLD]["entities"].has(entity_id), "deployment is immediate without a simulation tick")
	_check(game.state.item_quantity(item, LOCATION) == 3 and _total(item) == initial_total, "deploy transfers one building from stock to installed custody")
	var consumed: Dictionary = game.state.factory_world_item_ledger().get("Consumed", {})
	_check(int(consumed.get(item, 0)) == 0, "deploy is not manufacturing consumption")
	var removed := _command("REMOVE_ENTITY", {"entity_id":entity_id})
	_check(removed.get("accepted", false) and game.state.item_quantity(item, LOCATION) == 4 and _total(item) == initial_total, "empty building dismantles to one finished item")
	game.state.set_item_reserve(item, 4, LOCATION)
	var ghost := _deploy("grid_solar_array", Vector2i(8,8))
	_check(ghost.get("accepted", false) and game.state.factory_worlds[WORLD]["entities"].size() == 1, "reserved building stock cannot be deployed")
	var orders: Dictionary = game.state.factory_worlds[WORLD]["construction_orders"]
	_check(orders.size() == 1, "shortage creates one ghost")
	if orders.is_empty():
		return
	var order_id := str(orders.keys()[0])
	_check(orders[order_id]["status"] == "WAITING_BUILDING" and orders[order_id]["required_items"] == {item:1}, "ghost requests finished item only")
	var funded := _command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":order_id})
	_check(funded.get("reason_code", "") == "CONSTRUCTION_RETIRED", "legacy raw-material funding command is rejected")
	game.advance_game_time(1000.0)
	_check(game.state.factory_worlds[WORLD]["construction_orders"].size() == 1, "time cannot build a reserved or missing item")
	game.state.set_item_reserve(item, 0, LOCATION)
	game.advance_game_time(100.0)
	_check(game.state.factory_worlds[WORLD]["construction_orders"].is_empty() and game.state.item_quantity(item, LOCATION) == 3, "ghost deploys exactly once when unreserved stock becomes available")
	game.advance_game_time(1000.0)
	_check(game.state.item_quantity(item, LOCATION) == 3 and _total(item) == initial_total, "later ticks cannot duplicate deployment")
	game.state.location_inventory(LOCATION)[item] = 0
	var cancel_ghost := _deploy("grid_solar_array", Vector2i(20,8))
	_check(cancel_ghost.get("accepted", false), "empty stock still allows ghost planning")
	orders = game.state.factory_worlds[WORLD]["construction_orders"]
	order_id = str(orders.keys()[0])
	_check(_command("CANCEL_CONSTRUCTION", {"order_id":order_id}).get("accepted", false), "cancel removes an unfunded ghost")
	_check(game.state.item_quantity(item, LOCATION) == 0, "cancelling a ghost grants no item")
	# Minimal old-order conversion refunds staged raw material once.
	var world: Dictionary = game.state.factory_worlds[WORLD]
	world["construction_orders"]["legacy"] = {"id":"legacy","entity_id":"legacy-entity","definition_id":"grid_solar_array","footprint":{"origin":{"x":30,"y":8},"size":{"x":8,"y":8}},"delivered_items":{"scrap_metal":2},"required_items":{"scrap_metal":2},"work_done":9,"work_required":10}
	var scrap_before: int = game.state.item_quantity("scrap_metal", LOCATION)
	game.simulation.ensure_frontier_state(game.state)
	game.simulation.ensure_frontier_state(game.state)
	_check(game.state.item_quantity("scrap_metal", LOCATION) == scrap_before + 2, "old staged BOM returns once without being consumed or duplicated")
	_check(world["construction_orders"]["legacy"].get("deployment_item_id") == item, "old construction layout now waits for a finished building")


func _test_ore_to_new_building() -> void:
	_fresh()
	var inventory: Dictionary = game.state.location_inventory(LOCATION)
	for item_id in inventory.keys():
		if not str(item_id).begins_with("building_grid_"):
			inventory[item_id] = 0
	for entry in [
		["grid_surface_mine",Vector2i(42,42),""],["grid_surface_mine",Vector2i(82,42),""],
		["grid_arc_smelter",Vector2i(8,61),"grid_refine_iron"],
		["grid_arc_smelter",Vector2i(28,61),"grid_refine_copper"],
		["grid_engineering_works",Vector2i(52,61),"grid_fabricate_electronics"]
	]:
		var placed := _deploy(str(entry[0]), entry[1], str(entry[2]))
		_check(placed.get("accepted", false), "starter deploy: %s at %s" % [entry[0],entry[1]])
	var world: Dictionary = game.state.factory_worlds[WORLD]
	_check(world["construction_orders"].is_empty() and world["entities"].size() == 6, "complete starter kit deploys without raw inventory")
	var tiles: Array = []
	for x in range(8,110):
		tiles.append({"x":x,"y":60})
	for x in [42,82]:
		for y in range(53,60):
			tiles.append({"x":x,"y":y})
	for y in range(32,60):
		tiles.append({"x":109,"y":y})
	_check(_command("BUILD_ROAD", {"tiles":tiles,"tier":1}).get("accepted", false), "free starter roads connect the full production chain")
	world = game.state.factory_worlds[WORLD]
	var manufacturer := ""
	for entity_value in world["entities"].values():
		var entity: Dictionary = entity_value
		if entity.get("definition_id", "") == "grid_engineering_works":
			manufacturer = str(entity["id"])
		if entity.get("kind") in ["EXTRACTOR","MACHINE"]:
			_check(float(entity.get("power_factor", 0)) >= 0.99, "starter generation fully powers %s" % entity["id"])
	var configured := false
	var making_scrap := false
	for tick in range(1800):
		game.simulation.advance(game.state, 1000.0)
		if not making_scrap and game.state.item_quantity("electronics", LOCATION) >= 2:
			_check(_command("SET_RECIPE", {"entity_id":manufacturer,"recipe_id":"grid_reclaim_metal_stock"}).get("accepted",false), "single assembler switches from electronics to manufacturing material")
			making_scrap = true
		if not configured and game.state.item_quantity("scrap_metal", LOCATION) >= 4 and game.state.item_quantity("electronics", LOCATION) >= 1:
			var selected := _command("SET_RECIPE", {"entity_id":manufacturer,"recipe_id":"manufacture_grid_surface_mine"})
			_check(selected.get("accepted", false), "existing production machine selects a building recipe")
			configured = true
		if game.state.item_quantity("building_grid_surface_mine", LOCATION) >= 1:
			break
	_check(configured, "ore extraction, ingot refining, scrap and electronics bootstrap with zero starting materials")
	_check(game.state.item_quantity("building_grid_surface_mine", LOCATION) >= 1, "manufactured building is automatically delivered to planetary stock")
	if game.state.item_quantity("building_grid_surface_mine", LOCATION) >= 1:
		var total_before := _total("building_grid_surface_mine")
		_check(_deploy("grid_surface_mine", Vector2i(30,45)).get("accepted", false), "manufactured mining building deploys for the next expansion")
		_check(_total("building_grid_surface_mine") == total_before, "expansion preserves finished building custody")


func _total(item_id: String) -> int:
	return game.state.item_quantity(item_id, LOCATION) + int(game.state.factory_world_item_ledger().get("Items", {}).get(item_id, 0))


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
