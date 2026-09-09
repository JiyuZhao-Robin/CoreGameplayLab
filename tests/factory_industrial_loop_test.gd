extends SceneTree

## Real new-game industrial path. All player mutations cross Game's versioned
## command boundary; no test grants inventory, finished buildings or technology.
const WORLD := "earth-surface-grid"
var failures: Array[String] = []
var game: Node
var sequence := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	game.reset_game()
	var opening_holdings: Dictionary = game.state.factory_world_item_holdings()
	_test_bootstrap_plans()
	var powers: Array[String] = []
	for index in 4:
		powers.append(_build("grid_solar_array", Vector2i(index * 10, 0)))
	var mine_iron := _build("grid_surface_mine", Vector2i(32, 32))
	var mine_copper := _build("grid_surface_mine", Vector2i(72, 32))
	var iron := _build("grid_engineering_works", Vector2i(32, 70), "grid_refine_iron")
	var copper := _build("grid_engineering_works", Vector2i(60, 70), "grid_refine_copper")
	var frame := _build("grid_engineering_works", Vector2i(92, 70), "grid_assemble_frame")
	var electronics := _build("grid_engineering_works", Vector2i(124, 70), "grid_fabricate_electronics")
	var stock := _build("grid_engineering_works", Vector2i(156, 70), "grid_reclaim_metal_stock")
	game.advance_game_time(200_000.0)
	_check(_world().get("construction_orders", {}).is_empty(), "starter materials commission a complete player-authored production chain")
	for index in range(1, powers.size()):
		_link("POWER", powers[index], mine_iron)
	for entity_id in [mine_iron, mine_copper, iron, copper, frame, electronics, stock]:
		_link("POWER", powers[0], entity_id)
	_link("CARGO", mine_iron, iron, "iron_ore")
	_link("CARGO", mine_copper, copper, "copper_ore")
	_link("CARGO", iron, "starter-depot", "iron_ingot")
	_link("CARGO", copper, "starter-depot", "copper_ingot")
	_link("CARGO", copper, "starter-depot", "industrial_waste")
	for consumer in [frame, electronics, stock]:
		_link("CARGO", "starter-depot", consumer, "iron_ingot")
	for consumer in [frame, electronics]:
		_link("CARGO", "starter-depot", consumer, "copper_ingot")
	_link("CARGO", frame, "starter-depot", "structural_frame")
	_link("CARGO", electronics, "starter-depot", "electronics")
	_link("CARGO", stock, "starter-depot", "scrap_metal")

	var expansion := _build("grid_bulk_depot", Vector2i(192, 96))
	var foundry := _build("grid_arc_smelter", Vector2i(152, 96), "grid_refine_iron")
	var renewed_power: Array[String] = []
	for index in 8:
		renewed_power.append(_build("grid_solar_array", Vector2i(index * 10, 124)))
	var waiting: Array = _world().get("construction_orders", {}).values().filter(func(order): return str(order.get("status", "")) == "WAITING_MATERIALS")
	_check(waiting.size() >= 3, "expansion orders genuinely await new iron, frames and renewable construction stock")
	var report: Dictionary = game.advance_game_time(360_000.0)
	var entities: Dictionary = _world().get("entities", {})
	_check(entities.has(expansion) and entities.has(foundry), "extracted and refined material automatically funds and completes physical capacity expansion")
	_check(renewed_power.all(func(id): return entities.has(id)), "renewable metal stock sustains construction beyond finite bootstrap scrap")
	_check(_world().get("construction_orders", {}).is_empty(), "the entire queued expansion completes without repeated funding clicks")
	var statistics: Dictionary = _world().get("statistics", {})
	var final_holdings: Dictionary = game.state.factory_world_item_holdings()
	var tracked_items: Dictionary = opening_holdings.duplicate(true)
	tracked_items.merge(statistics.get("produced", {}), true)
	tracked_items.merge(statistics.get("consumed", {}), true)
	for item_id in tracked_items.keys():
		var expected := int(opening_holdings.get(item_id, 0)) + int(statistics.get("produced", {}).get(item_id, 0)) + int(statistics.get("external_imported", {}).get(item_id, 0)) - int(statistics.get("consumed", {}).get(item_id, 0)) - int(statistics.get("external_exported", {}).get(item_id, 0))
		_check(int(final_holdings.get(item_id, 0)) == expected, "industrial production and automatic construction preserve per-item custody: %s" % item_id)
	_check(int(statistics.get("produced", {}).get("scrap_metal", 0)) > 0 and int(statistics.get("produced", {}).get("structural_frame", 0)) > 0, "construction stock and structural capital goods are produced by powered recipes")
	_check((report.get("events", []) as Array).any(func(event): return str(event.get("type", "")) == "FactoryConstructionFunded" and bool(event.get("automatic", false))), "automatic deliveries emit concrete material-custody events")
	_check(float(report.get("unprocessed_ms", -1)) < 0.01, "application processes the full industrial simulation window")
	_test_automatic_custody_and_priority()
	_test_application_cancellation_custody()
	if failures.is_empty():
		print("FACTORY_INDUSTRIAL_LOOP_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_bootstrap_plans() -> void:
	var operations: Dictionary = game.factory_workspace_snapshot(WORLD).get("operations", {})
	var production_stage: Dictionary = operations.get("stages", [])[1]
	_check(str(production_stage.get("action", {}).get("target_id", "")) == "grid_engineering_works", "fresh production entry selects affordable starter works, not an unbuildable foundry")
	for plan in operations.get("build_plans", []):
		if str(plan.get("definition_id", "")) not in ["grid_bulk_depot", "grid_arc_smelter"]:
			continue
		_check((plan.get("dependencies", []) as Array).any(func(dependency): return str(dependency.get("item_id", "")) == "iron_ore" and str(dependency.get("kind", "")) == "EXTRACTION" and str(dependency.get("action", {}).get("target_id", "")) == "grid_surface_mine"), "construction plans trace raw iron through mapped physical mining")
		for material in plan.get("materials", []):
			if str(material.get("item_id", "")) == "iron_ingot":
				_check(str(material.get("producer_building_id", "")) == "grid_engineering_works" and str(material.get("recipe_id", "")) == "grid_refine_iron", "fresh expansion plans use the affordable starter producer for iron")
		if str(plan.get("definition_id", "")) == "grid_arc_smelter":
			_check(not (plan.get("dependencies", []) as Array).any(func(dependency): return str(dependency.get("building_id", "")) == "grid_arc_smelter"), "the first foundry never prescribes itself as its own prerequisite")


func _test_automatic_custody_and_priority() -> void:
	var grid = game.simulation.factory_grid
	var world: Dictionary = grid.create_world("funding-test", "earth_orbit", Vector2i(256, 160))
	grid.place_entity_immediate(world, "grid_bulk_depot", Vector2i(100, 0), "", "depot")
	var low: Dictionary = grid.queue_construction(world, "grid_bulk_depot", Vector2i(0, 0), "", 10, "AUTO_SAME_LOCATION")
	var high: Dictionary = grid.queue_construction(world, "grid_bulk_depot", Vector2i(30, 0), "", 90, "AUTO_SAME_LOCATION")
	var manual: Dictionary = grid.queue_construction(world, "grid_bulk_depot", Vector2i(60, 0))
	world.entities.depot.inventory["iron_ingot"] = 15
	grid.advance_world(world, 1000.0)
	var orders: Dictionary = world.construction_orders
	_check(int(orders[high.order_id].delivered_items.get("iron_ingot", 0)) == 10 and int(orders[low.order_id].delivered_items.get("iron_ingot", 0)) == 5, "automatic staging respects descending priority and never duplicates scarce material")
	_check(orders[manual.order_id].delivered_items.is_empty(), "manual orders remain manual")
	_check(int(world.statistics.get("consumed", {}).get("iron_ingot", 0)) == 0, "staging does not consume materials before completion")
	_check(int(world.entities.depot.inventory.get("iron_ingot", 0)) == 0, "staged materials leave physical depot custody exactly once")
	var chunked: Dictionary = world.duplicate(true)
	grid.advance_world(world, 30_000.0)
	for index in 30:
		grid.advance_world(chunked, 1000.0)
	_check(world.entities == chunked.entities and world.construction_orders == chunked.construction_orders and world.statistics == chunked.statistics, "automatic deliveries and construction are equivalent for whole and chunked time")
	# A funded order cancelled before completion still owns all staged material.
	var refund: Dictionary = grid.cancel_construction(world, str(low.order_id))
	_check(bool(refund.get("ok", false)) and int(refund.get("returned_items", refund.get("refund", {})).get("iron_ingot", 0)) == 5, "domain cancellation reports its staged refund manifest for application transfer")


func _test_application_cancellation_custody() -> void:
	game.reset_game()
	var before := _live_materials()
	var queued := _command("QUEUE_CONSTRUCTION", {"definition_id":"grid_solar_array", "origin":{"x":12, "y":12}, "funding_policy":"AUTO_SAME_LOCATION"})
	var order_id := str(queued.get("order_id", ""))
	var staged: Dictionary = _world().get("construction_orders", {}).get(order_id, {}).get("delivered_items", {})
	_check(not staged.is_empty(), "cancellation regression actually stages automatic construction materials")
	_command("CANCEL_CONSTRUCTION", {"order_id":order_id})
	_check(_live_materials() == before and not _world().get("construction_orders", {}).has(order_id), "application cancellation transfers staged assets back to live custody without loss or duplication")
	_check(_world().get("statistics", {}).get("consumed", {}).is_empty(), "cancelled automatic work does not enter the construction consumption ledger")


func _live_materials() -> Dictionary:
	var result: Dictionary = game.state.aggregate_inventory().duplicate(true)
	for item_id in game.state.factory_world_item_holdings().keys():
		result[item_id] = int(result.get(item_id, 0)) + int(game.state.factory_world_item_holdings().get(item_id, 0))
	for item_id in result.keys():
		if int(result[item_id]) == 0:
			result.erase(item_id)
	return result


func _world() -> Dictionary:
	return game.state.factory_worlds[WORLD]


func _command(kind: String, payload: Dictionary) -> Dictionary:
	sequence += 1
	var result: Dictionary = game.execute_factory_command({
		"protocol_version":1, "command_id":"industrial-loop-%d" % sequence,
		"kind":kind, "world_id":WORLD,
		"base_topology_revision":int(_world().get("topology_revision", 0)),
		"payload":payload
	})
	_check(bool(result.get("accepted", false)), "%s accepted: %s" % [kind, result.get("reason_code", "")])
	return result.get("result", {})


func _build(definition_id: String, origin: Vector2i, recipe_id: String = "") -> String:
	var result := _command("QUEUE_CONSTRUCTION", {"definition_id":definition_id, "origin":{"x":origin.x, "y":origin.y}, "recipe_id":recipe_id, "funding_policy":"AUTO_SAME_LOCATION"})
	return str(result.get("entity_id", ""))


func _link(kind: String, source_id: String, target_id: String, item_id: String = "") -> void:
	_command("CONNECT_ENTITIES", {"link_kind":kind, "source_id":source_id, "target_id":target_id, "item_id":item_id, "capacity_per_second":1.0})


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		print("FAIL: %s" % message)
