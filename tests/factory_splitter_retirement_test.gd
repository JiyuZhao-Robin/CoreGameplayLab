extends SceneTree

const WORLD := "earth-surface-grid"
const LOCATION := "earth_orbit"
const SPLITTER := "grid_dsp_splitter_4way"
const ITEM := "building_grid_dsp_splitter_4way"
const RECIPE := "manufacture_grid_dsp_splitter_4way"
var failures: Array[String] = []
var game: Node
var serial := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	game.state = SpaceGameState.create_new(game.content.domains.keys(), game.content.regions)
	game.simulation = SimulationEngine.new(game.content)
	game.simulation.ensure_frontier_state(game.state)
	for technology in game.content.technologies:
		game.state.technologies[technology] = true
	var world: Dictionary = game.state.factory_worlds[WORLD]
	world["starter_package_delivered"] = true
	world["terrain_enabled"] = false
	_test_catalog_and_commands(world)
	_test_old_save(world)
	if failures.is_empty():
		print("FACTORY_SPLITTER_RETIREMENT_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_catalog_and_commands(world: Dictionary) -> void:
	_check(game.content.factory_buildings[SPLITTER].get("legacy_only", false), "splitter definition remains only for saved assets")
	_check(game.content.items[ITEM].get("legacy_only", false), "saved finished items keep their canonical identity")
	_check(game.content.factory_recipes[RECIPE].get("legacy_only", false), "historical manufacture recipe is retired")
	_check(game.content.factory_buildings[SPLITTER]["art_index"] == 33, "retirement never shifts source artwork indices")
	for definition in game.content.factory_buildings.values():
		_check(not definition.get("recipe_ids", []).has(RECIPE), "no manufacturing machine offers the retired recipe")
	for snapshot in [game.simulation.factory_grid.workspace_snapshot(world), game.factory_workspace_snapshot(WORLD)]:
		for building in snapshot["palette"]["buildings"]:
			_check(building["id"] != SPLITTER, "splitter is absent from build selection even with every technology")
		for recipe in snapshot["palette"]["recipes"]:
			_check(recipe["id"] != RECIPE, "splitter manufacture is absent from recipe selection")
	game.state.location_inventory(LOCATION)[ITEM] = 5
	_check(game.simulation.factory_grid.place_entity_immediate(world, "grid_engineering_works", Vector2i(20,20), "", "machine").get("ok", false), "ordinary machine fixture deploys")
	for kind in ["DEPLOY_BUILDING", "QUEUE_CONSTRUCTION"]:
		_rejected_without_changes(kind, {"definition_id":SPLITTER, "origin":{"x":60,"y":20}}, "BUILDING_LOCKED")
	_rejected_without_changes("DEPLOY_BUILDING", {"definition_id":"grid_engineering_works", "origin":{"x":90,"y":20}, "recipe_id":RECIPE}, "RECIPE_LOCKED")
	_rejected_without_changes("SET_RECIPE", {"entity_id":"machine", "recipe_id":RECIPE}, "RECIPE_LOCKED")
	var before := world.duplicate(true)
	_check(not game.simulation.factory_grid.queue_construction(world, SPLITTER, Vector2i(60,20)).get("ok", false), "domain deployment also blocks splitter ghosts")
	_check(not game.simulation.factory_grid.set_entity_recipe(world, "machine", RECIPE).get("ok", false), "domain recipe command also rejects retired production")
	_check(world == before, "domain rejection preserves inventory and world state")


func _test_old_save(world: Dictionary) -> void:
	# Build a real pre-retirement world using the historical catalog contract.
	var buildings: Dictionary = game.content.factory_buildings.duplicate(true)
	var recipes: Dictionary = game.content.factory_recipes.duplicate(true)
	buildings[SPLITTER].erase("legacy_only")
	recipes[RECIPE].erase("legacy_only")
	buildings["grid_engineering_works"]["recipe_ids"].append(RECIPE)
	var old_grid := FactoryGridSimulation.new(buildings, recipes, game.content.factory_grid_rules)
	_check(old_grid.place_entity_immediate(world, SPLITTER, Vector2i(60,20), "", "legacy-splitter").get("ok", false), "old placed splitter fixture")
	world["entities"]["legacy-splitter"]["inventory"] = {"iron_ore":7}
	_check(old_grid.set_entity_recipe(world, "machine", RECIPE).get("ok", false), "old recipe fixture")
	for input in recipes[RECIPE]["inputs"]:
		world["entities"]["machine"]["inputs"][input["item"]] = int(input["quantity"])
	world["entities"]["machine"]["outputs"][ITEM] = 1
	world["entities"]["machine"]["progress"] = 0.75
	var queued := old_grid.queue_construction(world, SPLITTER, Vector2i(90,20))
	_check(queued.get("ok", false), "old ghost fixture")
	var order_id := str(queued.get("order_id", ""))
	world["construction_orders"][order_id]["delivered_items"] = {"iron_ingot":2}
	var stock_before: int = game.state.item_quantity("iron_ingot", LOCATION)
	var ore_before: int = game.state.item_quantity("iron_ore", LOCATION)
	var serialized: Dictionary = game.state.to_dictionary().duplicate(true)
	game.state = SpaceGameState.from_dictionary(serialized, game.content.domains.keys(), game.content.regions)
	game.simulation.ensure_frontier_state(game.state)
	world = game.state.factory_worlds[WORLD]
	_check(world["entities"].has("legacy-splitter") and game.state.item_quantity(ITEM, LOCATION) == 5, "saved placed splitter and owned kits survive loading")
	_check(game.state.item_quantity("iron_ore", LOCATION) == ore_before + 7 and game.state.item_quantity("iron_ingot", LOCATION) == stock_before + 2, "legacy warehouse cargo and ghost staging return to shared stock exactly once")
	var machine: Dictionary = world["entities"]["machine"]
	var inputs_before: Dictionary = machine["inputs"].duplicate(true)
	var outputs_before: Dictionary = machine["outputs"].duplicate(true)
	var events: Array[Dictionary] = []
	game.simulation.factory_grid._run_machines(world, 60.0, {"machine":1.0}, events)
	_check(events.is_empty() and machine["inputs"] == inputs_before and machine["outputs"] == outputs_before and machine["progress"] == 0.75, "saved production stops without consuming ingredients or duplicating finished splitters")
	_check(machine["status"] == "NO_RECIPE" and machine["actual_rate"] == 0.0, "retired production reports no active recipe")
	var before_reload: Dictionary = game.state.to_dictionary().duplicate(true)
	game.state = SpaceGameState.from_dictionary(before_reload, game.content.domains.keys(), game.content.regions)
	game.simulation.ensure_frontier_state(game.state)
	_check(game.state.item_quantity("iron_ingot", LOCATION) == stock_before + 2 and game.state.item_quantity("iron_ore", LOCATION) == ore_before + 7, "reloading cannot repeat legacy cargo refunds")
	world = game.state.factory_worlds[WORLD]
	var deployment_events: Array = game.simulation.factory_grid.deploy_pending_buildings(world, game.simulation.factory_inventory_context(game.state, world))
	_check(deployment_events.is_empty() and world["construction_orders"].has(order_id) and game.state.item_quantity(ITEM, LOCATION) == 5, "old ghost remains cancelable and never deploys or consumes a retired kit")
	_check(_command("CANCEL_CONSTRUCTION", {"order_id":order_id}).get("accepted", false), "old ghost can be canceled normally")
	_check(_command("SET_RECIPE", {"entity_id":"machine", "recipe_id":"manufacture_grid_solar_array"}).get("accepted", false), "old assembler can be retooled to current production")
	machine = game.state.factory_worlds[WORLD]["entities"]["machine"]
	for item_id in inputs_before:
		_check(machine["outputs"].get(item_id, 0) == inputs_before[item_id], "retooling returns every old input instead of deleting it")
	_check(machine["outputs"].get(ITEM, 0) == 1, "retooling preserves previously manufactured splitter")
	_check(_command("REMOVE_ENTITY", {"entity_id":"legacy-splitter"}).get("accepted", false), "legacy placed splitter remains safely removable")
	_check(game.state.item_quantity(ITEM, LOCATION) == 6, "dismantling returns the owned splitter kit")


func _rejected_without_changes(kind: String, payload: Dictionary, reason: String) -> void:
	var before: Dictionary = game.state.to_dictionary().duplicate(true)
	var result := _command(kind, payload)
	_check(not result.get("accepted", false) and result.get("reason_code") == reason and game.state.to_dictionary() == before, "%s rejects retired content atomically" % kind)


func _command(kind: String, payload: Dictionary) -> Dictionary:
	serial += 1
	return game.execute_factory_command({"protocol_version":1, "world_id":WORLD, "command_id":"splitter-retirement-%d" % serial, "base_topology_revision":int(game.state.factory_worlds[WORLD]["topology_revision"]), "kind":kind, "payload":payload})


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
