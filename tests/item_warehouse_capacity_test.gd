extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var content := ContentDatabase.new()
	_check(content.load_from_file("res://data/content.json"), "content loads")
	var simulation := SimulationEngine.new(content)
	var state := SpaceGameState.create_new(content.domains.keys(), content.regions)
	simulation.ensure_frontier_state(state)
	var inventory: Dictionary = state.location_inventory("earth_orbit")
	inventory.clear()
	inventory["iron_ore"] = 200
	_check(simulation.location_item_storage_capacity(state, "earth_orbit", "iron_ore") == 200, "new-game independent item limit is 200")
	_check(simulation.location_storage_free_quantity_for_item(state, "earth_orbit", "iron_ore") == 0 and simulation.location_storage_free_quantity_for_item(state, "earth_orbit", "copper_ore") == 200, "a full iron warehouse cannot crowd copper of the same class")
	_check(simulation.location_item_storage_capacity(state, "lunar_space", "copper_ore") == 0, "unsurveyed remote Location receives no free warehouse")
	state.logistics_network["shipments"] = [{"id":"incoming-iron", "destination":"earth_orbit", "cargo":{"iron_ore":10}}, {"id":"incoming-copper", "destination":"earth_orbit", "cargo":{"copper_ore":30}}]
	_check(simulation.location_storage_free_quantity_for_item(state, "earth_orbit", "copper_ore") == 170, "in-transit reservations only reserve their own material")
	_check(simulation.logistics._destination_free_capacity_excluding_shipment(state, "earth_orbit", "copper_ore", "incoming-copper") == 200, "arrival excludes its own reservation without excluding another item")
	_check(simulation.storage_can_apply_transaction(state, "earth_orbit", {"copper_ore":170}) and not simulation.storage_can_apply_transaction(state, "earth_orbit", {"copper_ore":171}), "atomic ingress honors same-item in-transit reservations")
	_check(not simulation.storage_can_apply_transaction(state, "earth_orbit", {"iron_ore":1}, {"copper_ore":200}), "consuming copper cannot create iron capacity")
	inventory["iron_ore"] = 230
	_check(simulation.storage_can_apply_transaction(state, "earth_orbit", {"iron_ore":2}, {"iron_ore":3}) and not simulation.storage_can_apply_transaction(state, "earth_orbit", {"iron_ore":1}), "over-cap stock survives and can be consumed but cannot grow")
	var storage: Dictionary = simulation.location_storage_snapshot(state, "earth_orbit")
	_check(storage["storage_mode"] == "PER_ITEM" and storage["items"]["iron_ore"]["capacity"] == 200 and storage["items"]["copper_ore"]["free"] == 170, "public item snapshot matches the actual acceptance limit")
	var planned: Dictionary = simulation.economy_planner._planned_storage({"iron_ore":40, "copper_ore":30})
	_check(float(planned.get("BULK", 0)) == 40.0, "warehouse planning requests the peak per-material limit, not a pooled volume")
	var factory := simulation.factory_grid
	var world := factory.create_world("storage-fixture", "earth_orbit", Vector2i(128, 128))
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i.ZERO, "", "depot")
	var depot: Dictionary = world["entities"]["depot"]
	var capacity := int(content.factory_buildings["grid_bulk_depot"]["inventory_capacity"])
	factory.deposit_storage_inventory(world, "depot", "iron_ore", capacity)
	var copper_deposit := factory.deposit_storage_inventory(world, "depot", "copper_ore", 7)
	_check(int(copper_deposit.get("moved", 0)) == 7 and int(depot["inventory"]["iron_ore"]) == capacity, "Factory warehouse accepts copper while iron is full")
	_check(factory._target_free_capacity(depot, "iron_ore") == 0 and factory._target_free_capacity(depot, "copper_ore") == capacity - 7, "Factory ports expose independent item headroom")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(40, 0), "", "source")
	world["entities"]["source"]["inventory"] = {"iron_ore":10, "copper_ore":10}
	factory.connect_entities(world, "CARGO", "source", "depot", "iron_ore", 10.0)
	factory.connect_entities(world, "CARGO", "source", "depot", "copper_ore", 10.0)
	factory.advance_world(world, 1000.0)
	_check(int(depot["inventory"].get("copper_ore", 0)) == 17 and int(world["entities"]["source"]["inventory"].get("iron_ore", 0)) == 10, "live multi-item links deliver copper without consuming blocked iron")
	depot["inventory"] = {"iron_ore":capacity - 5, "copper_ore":capacity - 5}
	world["entities"]["source"]["inventory"] = {"iron_ore":10, "copper_ore":10}
	factory.advance_world(world, 1000.0)
	_check(int(depot["inventory"]["iron_ore"]) == capacity and int(depot["inventory"]["copper_ore"]) == capacity, "target arbitration independently fills both nearly-full item slots in one tick")
	state.factory_worlds.clear()
	state.factory_worlds["storage-fixture"] = world
	var capability: Dictionary = simulation.location_industry_constraint_profile(state, "earth_orbit")
	_check(capability["storage_capacities"]["BULK"] == capacity * 2 and capability["storage_capacities"]["COMPONENT"] == capacity * 2, "site capability reflects every material accepted by installed warehouses")
	world["entities"]["source"]["status"] = "UNDER_CONSTRUCTION"
	capability = simulation.location_industry_constraint_profile(state, "earth_orbit")
	_check(capability["storage_capacities"]["BULK"] == capacity, "unfinished warehouses cannot satisfy site capacity requirements")
	var router_definition: Dictionary = {}
	for definition in content.factory_buildings.values():
		if str(definition.get("kind", "")) == "ROUTER":
			router_definition = definition
			break
	var router := {"definition_id":router_definition.get("id", ""), "kind":"ROUTER", "inventory":{"iron_ore":router_definition.get("inventory_capacity", 0)}}
	_check(not router_definition.is_empty() and factory._target_free_capacity(router, "copper_ore") == 0, "router remains a finite shared transit buffer")
	var normalized := factory.normalize_world(world)
	_check(normalized["entities"]["depot"]["inventory"] == depot["inventory"], "normalization does not trim valid independent warehouse stock")
	for failure in failures:
		push_error(failure)
	print("ITEM_WAREHOUSE_CAPACITY_PASS" if failures.is_empty() else "ITEM_WAREHOUSE_CAPACITY_FAIL")
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
