extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "starter construction test loads content: %s" % str(database.errors))
	if failures.is_empty():
		_test_starter_auto_funding_and_replay(database)
	if failures.is_empty():
		_test_legacy_manual_receipt_replay(database)
	if failures.is_empty():
		_test_mixed_source_auto_funding(database)
	if failures.is_empty():
		_test_partial_auto_funding(database)
	_finish()


func _test_starter_auto_funding_and_replay(database: ContentDatabase) -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)

	var world_id := "earth-surface-grid"
	var world: Dictionary = game.state.factory_worlds.get(world_id, {})
	var depot: Dictionary = world.get("entities", {}).get("starter-depot", {})
	_check(not world.is_empty() and int(depot.get("inventory", {}).get("scrap_metal", 0)) == 44, "fresh game exposes one funded starter depot")
	var owned_before := int(game.state.factory_world_item_holdings().get("scrap_metal", 0))
	var consumed_before := int(world.get("statistics", {}).get("consumed", {}).get("scrap_metal", 0))
	var intent := {
		"protocol_version":1,
		"command_id":"starter-auto-solar",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":world_id,
		"base_topology_revision":int(world.get("topology_revision", -1)),
		"payload":{
			"definition_id":"grid_solar_array",
			"recipe_id":"",
			"funding_policy":"AUTO_SAME_LOCATION",
			"origin":{"x":0, "y":0},
			"priority":50
		}
	}
	var queued: Dictionary = game.execute_factory_command(intent)
	var order_id := str(queued.get("result", {}).get("order_id", ""))
	var entity_id := str(queued.get("result", {}).get("entity_id", ""))
	var funding: Dictionary = queued.get("result", {}).get("funding", {})
	world = game.state.factory_worlds.get(world_id, {})
	depot = world.get("entities", {}).get("starter-depot", {})
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	_check(
		bool(queued.get("accepted", false))
		and not order_id.is_empty()
		and bool(funding.get("fully_funded", false))
		and str(order.get("status", "")) == "READY",
		"one placement creates and fully stages an affordable starter building"
	)
	_check(
		int(depot.get("inventory", {}).get("scrap_metal", 0)) == 42
		and int(order.get("delivered_items", {}).get("scrap_metal", 0)) == 2
		and int(game.state.factory_world_item_holdings().get("scrap_metal", 0)) == owned_before
		and int(world.get("statistics", {}).get("consumed", {}).get("scrap_metal", 0)) == consumed_before,
		"automatic funding moves the exact bill of materials into staging without consuming it early"
	)

	var replayed: Dictionary = game.execute_factory_command(intent)
	world = game.state.factory_worlds.get(world_id, {})
	_check(
		bool(replayed.get("accepted", false))
		and bool(replayed.get("replayed", false))
		and world.get("construction_orders", {}).size() == 1
		and int(world.get("entities", {}).get("starter-depot", {}).get("inventory", {}).get("scrap_metal", 0)) == 42,
		"command replay neither duplicates the order nor charges starter materials twice"
	)

	var report: Dictionary = game.simulation.factory_grid.advance_world(world, 10_000.0)
	var completion_count := 0
	for event_value in report.get("events", []):
		if str((event_value as Dictionary).get("type", "")) == "FactoryConstructionCompleted":
			completion_count += 1
	_check(
		world.get("entities", {}).has(entity_id)
		and not world.get("construction_orders", {}).has(order_id)
		and int(world.get("statistics", {}).get("consumed", {}).get("scrap_metal", 0)) == consumed_before + 2
		and completion_count == 1,
		"base construction capacity completes the first building once and consumes staged material once"
	)

	var machine_intent := {
		"protocol_version":1,
		"command_id":"starter-auto-unconfigured-machine",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":world_id,
		"base_topology_revision":int(world.get("topology_revision", -1)),
		"base_runtime_revision":int(world.get("runtime_revision", -1)),
		"payload":{
			"definition_id":"grid_engineering_works",
			"recipe_id":"",
			"funding_policy":"AUTO_SAME_LOCATION",
			"origin":{"x":20, "y":0},
			"priority":50
		}
	}
	var machine_queued: Dictionary = game.execute_factory_command(machine_intent)
	var machine_order_id := str(machine_queued.get("result", {}).get("order_id", ""))
	var machine_entity_id := str(machine_queued.get("result", {}).get("entity_id", ""))
	world = game.state.factory_worlds.get(world_id, {})
	_check(
		bool(machine_queued.get("accepted", false))
		and str(world.get("construction_orders", {}).get(machine_order_id, {}).get("recipe_id", "not-empty")) == ""
		and str(world.get("construction_orders", {}).get(machine_order_id, {}).get("status", "")) == "READY",
		"starter construction accepts and funds a machine before its production recipe is configured"
	)
	game.simulation.factory_grid.advance_world(world, 20_000.0)
	_check(
		str(world.get("entities", {}).get(machine_entity_id, {}).get("recipe_id", "not-empty")) == ""
		and str(world.get("entities", {}).get(machine_entity_id, {}).get("status", "")) == "NO_RECIPE",
		"completed machine remains safely unconfigured until the player selects its recipe"
	)


func _test_legacy_manual_receipt_replay(database: ContentDatabase) -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var world: Dictionary = game.simulation.factory_grid.create_world("legacy-receipt-grid", "earth_orbit", Vector2i(128, 128), 7)
	var command_id := "legacy-manual-queue"
	var legacy_payload := {
		"definition_id":"grid_solar_array",
		"recipe_id":"",
		"origin":{"x":0, "y":0},
		"priority":50
	}
	world["command_receipts"][command_id] = {
		"accepted":true,
		"protocol_version":1,
		"command_id":command_id,
		"command_kind":"QUEUE_CONSTRUCTION",
		"world_id":"legacy-receipt-grid",
		"topology_revision":int(world.get("topology_revision", 0)),
		"runtime_revision":int(world.get("runtime_revision", 0)),
		"result":{"order_id":"legacy-order", "entity_id":"legacy-entity"},
		"request_fingerprint":game._legacy_factory_command_request_fingerprint(1, "QUEUE_CONSTRUCTION", "legacy-receipt-grid", legacy_payload),
		"message_key":"factory.success.queue_construction"
	}
	game.state.factory_worlds["legacy-receipt-grid"] = world
	var replayed: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":command_id,
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":"legacy-receipt-grid",
		"base_topology_revision":int(world.get("topology_revision", 0)),
		"payload":legacy_payload
	})
	_check(
		bool(replayed.get("accepted", false))
		and bool(replayed.get("replayed", false))
		and str(replayed.get("result", {}).get("order_id", "")) == "legacy-order"
		and world.get("construction_orders", {}).is_empty(),
		"legacy manual QUEUE receipt replays after the funding-policy field is introduced"
	)


func _test_mixed_source_auto_funding(database: ContentDatabase) -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var factory: FactoryGridSimulation = game.simulation.factory_grid
	var world: Dictionary = factory.create_world("mixed-auto-grid", "earth_orbit", Vector2i(128, 128), 19)
	_check(bool(factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(40, 0), "", "a-depot").get("ok", false)), "mixed funding fixture creates first same-world storage")
	_check(bool(factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(70, 0), "", "z-depot").get("ok", false)), "mixed funding fixture creates second same-world storage")
	world["entities"]["a-depot"]["inventory"] = {"scrap_metal":1, "electronics":1}
	world["entities"]["z-depot"]["inventory"] = {"scrap_metal":1}
	game.state.location_inventory("earth_orbit")["scrap_metal"] = 2
	game.state.location_inventory("earth_orbit")["electronics"] = 1
	game.state.factory_worlds["mixed-auto-grid"] = world

	var other_world: Dictionary = factory.create_world("other-auto-grid", "lunar_space", Vector2i(128, 128), 23)
	_check(bool(factory.place_entity_immediate(other_world, "grid_bulk_depot", Vector2i(40, 0), "", "other-depot").get("ok", false)), "mixed funding fixture creates an out-of-world storage")
	other_world["entities"]["other-depot"]["inventory"] = {"scrap_metal":9, "electronics":9}
	game.state.factory_worlds["other-auto-grid"] = other_world

	var owned_scrap_before := int(game.state.aggregate_inventory().get("scrap_metal", 0)) + int(game.state.factory_world_item_holdings().get("scrap_metal", 0))
	var owned_electronics_before := int(game.state.aggregate_inventory().get("electronics", 0)) + int(game.state.factory_world_item_holdings().get("electronics", 0))
	var queued: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"mixed-auto-machine",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":"mixed-auto-grid",
		"base_topology_revision":int(world.get("topology_revision", -1)),
		"payload":{
			"definition_id":"grid_engineering_works",
			"recipe_id":"",
			"funding_policy":"AUTO_SAME_LOCATION",
			"origin":{"x":0, "y":0},
			"priority":50
		}
	})
	var order_id := str(queued.get("result", {}).get("order_id", ""))
	var funding: Dictionary = queued.get("result", {}).get("funding", {})
	world = game.state.factory_worlds.get("mixed-auto-grid", {})
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	_check(
		bool(queued.get("accepted", false))
		and bool(funding.get("fully_funded", false))
		and int(funding.get("moved_from_storage", {}).get("a-depot", {}).get("scrap_metal", 0)) == 1
		and int(funding.get("moved_from_storage", {}).get("z-depot", {}).get("scrap_metal", 0)) == 1
		and int(funding.get("moved_from_location", {}).get("scrap_metal", 0)) == 2
		and int(funding.get("moved_from_location", {}).get("electronics", 0)) == 1
		and int(order.get("delivered_items", {}).get("scrap_metal", 0)) == 4
		and int(order.get("delivered_items", {}).get("electronics", 0)) == 2,
		"automatic funding combines stable same-world storage custody with the remaining Location inventory"
	)
	_check(
		int(game.state.aggregate_inventory().get("scrap_metal", 0)) + int(game.state.factory_world_item_holdings().get("scrap_metal", 0)) == owned_scrap_before
		and int(game.state.aggregate_inventory().get("electronics", 0)) + int(game.state.factory_world_item_holdings().get("electronics", 0)) == owned_electronics_before
		and int(game.state.factory_worlds.get("other-auto-grid", {}).get("entities", {}).get("other-depot", {}).get("inventory", {}).get("scrap_metal", 0)) == 9,
		"mixed automatic funding conserves total assets and cannot draw from another Factory world"
	)

	var order_world: Dictionary = factory.create_world("ordered-auto-grid", "earth_orbit", Vector2i(128, 128), 29)
	_check(bool(factory.place_entity_immediate(order_world, "grid_bulk_depot", Vector2i(40, 0), "", "a-depot").get("ok", false)), "ordered funding fixture creates first storage")
	_check(bool(factory.place_entity_immediate(order_world, "grid_bulk_depot", Vector2i(70, 0), "", "z-depot").get("ok", false)), "ordered funding fixture creates second storage")
	order_world["entities"]["a-depot"]["inventory"] = {"scrap_metal":2}
	order_world["entities"]["z-depot"]["inventory"] = {"scrap_metal":2}
	game.state.location_inventory("earth_orbit")["scrap_metal"] = 0
	game.state.factory_worlds["ordered-auto-grid"] = order_world
	var ordered: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"ordered-auto-solar",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":"ordered-auto-grid",
		"base_topology_revision":int(order_world.get("topology_revision", -1)),
		"payload":{"definition_id":"grid_solar_array", "recipe_id":"", "funding_policy":"AUTO_SAME_LOCATION", "origin":{"x":0, "y":0}, "priority":50}
	})
	order_world = game.state.factory_worlds.get("ordered-auto-grid", {})
	_check(
		bool(ordered.get("accepted", false))
		and int(order_world.get("entities", {}).get("a-depot", {}).get("inventory", {}).get("scrap_metal", -1)) == 0
		and int(order_world.get("entities", {}).get("z-depot", {}).get("inventory", {}).get("scrap_metal", -1)) == 2,
		"automatic funding consumes same-world storages in stable storage-id order"
	)


func _test_partial_auto_funding(database: ContentDatabase) -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var factory: FactoryGridSimulation = game.simulation.factory_grid
	var world := factory.create_world("partial-auto-grid", "earth_orbit", Vector2i(128, 128), 13)
	_check(bool(factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(40, 0), "", "partial-depot").get("ok", false)), "partial funding fixture creates same-world storage")
	world["entities"]["partial-depot"]["inventory"] = {"scrap_metal":1}
	game.state.location_inventory("earth_orbit")["scrap_metal"] = 0
	game.state.factory_worlds["partial-auto-grid"] = world
	var queued: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"partial-auto-solar",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":"partial-auto-grid",
		"base_topology_revision":int(world.get("topology_revision", -1)),
		"payload":{
			"definition_id":"grid_solar_array",
			"recipe_id":"",
			"funding_policy":"AUTO_SAME_LOCATION",
			"origin":{"x":0, "y":0},
			"priority":50
		}
	})
	var order_id := str(queued.get("result", {}).get("order_id", ""))
	var funding: Dictionary = queued.get("result", {}).get("funding", {})
	world = game.state.factory_worlds.get("partial-auto-grid", {})
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	_check(
		bool(queued.get("accepted", false))
		and not bool(funding.get("fully_funded", true))
		and int(funding.get("remaining", {}).get("scrap_metal", 0)) == 1
		and int(order.get("delivered_items", {}).get("scrap_metal", 0)) == 1
		and str(order.get("status", "")) == "WAITING_MATERIALS"
		and int(world.get("entities", {}).get("partial-depot", {}).get("inventory", {}).get("scrap_metal", -1)) == 0,
		"automatic funding keeps a partially staged order without negative inventory or free materials"
	)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)


func _finish() -> void:
	if failures.is_empty():
		print("Factory starter construction tests passed")
		quit(0)
		return
	push_error("Factory starter construction tests failed: %s" % "; ".join(failures))
	quit(1)
