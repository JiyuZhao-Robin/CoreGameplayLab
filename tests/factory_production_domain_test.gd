extends SceneTree

var failures: Array[String] = []
var database: ContentDatabase
var factory: FactoryGridSimulation


func _initialize() -> void:
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "production-domain fixture loads Factory content: %s" % str(database.errors))
	if failures.is_empty():
		var buildings := database.factory_buildings.duplicate(true)
		buildings["test_router"] = {
			"id":"test_router",
			"name":"Test Router",
			"kind":"ROUTER",
			"footprint":{"width":4, "height":4},
			"inventory_capacity":24
		}
		buildings["test_tiny_depot"] = {
			"id":"test_tiny_depot",
			"name":"Test Tiny Depot",
			"kind":"STORAGE",
			"footprint":{"width":2, "height":2},
			"inventory_capacity":1
		}
		buildings["test_tiny_router"] = {
			"id":"test_tiny_router",
			"name":"Test Tiny Router",
			"kind":"ROUTER",
			"footprint":{"width":2, "height":2},
			"inventory_capacity":1
		}
		buildings["test_dual_output_machine"] = {
			"id":"test_dual_output_machine",
			"name":"Test Dual Output Machine",
			"kind":"MACHINE",
			"footprint":{"width":2, "height":2},
			"recipe_ids":["test_dual_output"],
			"speed":1.0,
			"power_demand_kw":1.0,
			"input_capacity":10,
			"output_capacity":3
		}
		var recipes := database.factory_recipes.duplicate(true)
		recipes["test_dual_output"] = {
			"id":"test_dual_output",
			"duration_seconds":1.0,
			"inputs":[{"item":"iron_ingot", "quantity":1}],
			"outputs":[{"item":"copper_ingot", "quantity":2}, {"item":"iron_ore", "quantity":2}]
		}
		factory = FactoryGridSimulation.new(buildings, recipes, database.factory_grid_rules)
		_test_structured_ports_paths_and_router_fan_io()
		_test_splitter_merger_connection_contracts()
		_test_congestion_and_atomic_link_configuration()
		_test_powered_live_router_and_healthy_utilization()
		_test_merger_input_fairness()
		_test_merger_multi_item_capacity_fairness()
		_test_pre_output_capacity_reservation()
		_test_cancellation_manifest_and_fail_closed_demolition()
	_finish()


func _test_structured_ports_paths_and_router_fan_io() -> void:
	var world := _router_world()
	var first_in: Dictionary = factory.connect_entities(world, "CARGO", "source-a", "router", "iron_ingot", 4.0)
	var second_in: Dictionary = factory.connect_entities(world, "CARGO", "source-b", "router", "iron_ingot", 4.0)
	var first_out: Dictionary = factory.connect_entities(world, "CARGO", "router", "target-a", "iron_ingot", 4.0)
	var second_out: Dictionary = factory.connect_entities(world, "CARGO", "router", "target-b", "iron_ingot", 4.0)
	_check(bool(first_in.get("ok", false)) and bool(second_in.get("ok", false)) and bool(first_out.get("ok", false)) and bool(second_out.get("ok", false)), "ROUTER accepts multiple same-item inputs and outputs while preserving ordinary endpoint checks")
	var snapshot := factory.workspace_snapshot(world)
	var router := _entity_snapshot(snapshot, "router")
	var ports: Dictionary = router.get("ports", {})
	var input_ports: Array = ports.get("input_ports", [])
	var output_ports: Array = ports.get("output_ports", [])
	_check(
		str(router.get("node_kind", "")) == "ROUTER"
		and input_ports.size() == 1
		and output_ports.size() == 1
		and str((input_ports[0] as Dictionary).get("id", "")) == "router:INPUT:ITEM:*"
		and str((input_ports[0] as Dictionary).get("direction", "")) == "INPUT"
		and str((input_ports[0] as Dictionary).get("channel", "")) == "ITEM"
		and bool((input_ports[0] as Dictionary).get("occupied", false))
		and (input_ports[0] as Dictionary).get("connected_link_ids", []).size() == 2
		and (output_ports[0] as Dictionary).get("connected_link_ids", []).size() == 2,
		"workspace ports are stable structured DTOs with direction, ITEM channel, stable IDs and deterministic connected-link occupancy"
	)
	for link_value in snapshot.get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) != "CARGO":
			continue
		var path_tiles: Array = link.get("path_tiles", [])
		_check(
			not str(link.get("source_port_id", "")).is_empty()
			and not str(link.get("target_port_id", "")).is_empty()
			and int(link.get("lane_count", 0)) == 1
			and str(link.get("tier", "")) == "MK1"
			and bool(link.get("path_in_bounds", false))
			and not path_tiles.is_empty()
			and path_tiles.size() <= 3,
			"new Cargo links persist endpoint ports, lane/tier metadata and a compact bounded orthogonal path"
		)
		for tile_value in path_tiles:
			var tile := tile_value as Dictionary
			_check(int(tile.get("x", -1)) >= 0 and int(tile.get("y", -1)) >= 0 and int(tile.get("x", 128)) < 128 and int(tile.get("y", 128)) < 128, "every persisted Cargo path tile remains inside the finite world bounds")
	var production_rows: Array = snapshot.get("production_rows", [])
	var router_row := _production_row(production_rows, "router")
	_check(
		str(router_row.get("kind", "")) == "ROUTER"
		and router_row.has("theoretical_rate")
		and router_row.has("utilization")
		and router_row.has("blocker")
		and router_row.get("upstream", []).size() == 2
		and router_row.get("downstream", []).size() == 2,
		"production rows expose theoretical/utilization/blocker and stable upstream/downstream topology for routers"
	)


func _test_splitter_merger_connection_contracts() -> void:
	var ordinary := factory.create_world("ordinary-output", "earth_orbit", Vector2i(96, 64), 30)
	factory.place_entity_immediate(ordinary, "test_dual_output_machine", Vector2i(0, 0), "test_dual_output", "machine")
	factory.place_entity_immediate(ordinary, "grid_bulk_depot", Vector2i(32, 0), "", "target-a")
	factory.place_entity_immediate(ordinary, "grid_bulk_depot", Vector2i(64, 0), "", "target-b")
	var ordinary_first := factory.connect_entities(ordinary, "CARGO", "machine", "target-a", "copper_ingot", 1.0)
	var ordinary_second := factory.connect_entities(ordinary, "CARGO", "machine", "target-b", "copper_ingot", 1.0)
	_check(bool(ordinary_first.get("ok", false)) and str(ordinary_second.get("reason_code", "")) == "CARGO_OUTPUT_OCCUPIED", "ordinary production outputs require a Cargo Splitter before the same item can fan out")

	var split := factory.create_world("split-contract", "earth_orbit", Vector2i(160, 96), 31)
	factory.place_entity_immediate(split, "grid_bulk_depot", Vector2i(0, 0), "", "source-a")
	factory.place_entity_immediate(split, "grid_bulk_depot", Vector2i(0, 32), "", "source-b")
	factory.place_entity_immediate(split, "grid_cargo_splitter", Vector2i(40, 16), "", "splitter")
	factory.place_entity_immediate(split, "grid_bulk_depot", Vector2i(80, 0), "", "target-a")
	factory.place_entity_immediate(split, "grid_bulk_depot", Vector2i(112, 32), "", "target-b")
	var split_input := factory.connect_entities(split, "CARGO", "source-a", "splitter", "iron_ingot", 1.0)
	var split_second_input := factory.connect_entities(split, "CARGO", "source-b", "splitter", "iron_ingot", 1.0)
	var split_first_output := factory.connect_entities(split, "CARGO", "splitter", "target-a", "iron_ingot", 1.0)
	var split_second_output := factory.connect_entities(split, "CARGO", "splitter", "target-b", "iron_ingot", 1.0)
	_check(bool(split_input.get("ok", false)) and str(split_second_input.get("reason_code", "")) == "CARGO_INPUT_OCCUPIED" and bool(split_first_output.get("ok", false)) and bool(split_second_output.get("ok", false)), "Cargo Splitter accepts one same-item input and fans it out across multiple outputs")

	var merge := factory.create_world("merge-contract", "earth_orbit", Vector2i(160, 96), 32)
	factory.place_entity_immediate(merge, "grid_bulk_depot", Vector2i(0, 0), "", "source-a")
	factory.place_entity_immediate(merge, "grid_bulk_depot", Vector2i(0, 32), "", "source-b")
	factory.place_entity_immediate(merge, "grid_cargo_merger", Vector2i(40, 16), "", "merger")
	factory.place_entity_immediate(merge, "grid_bulk_depot", Vector2i(80, 0), "", "target-a")
	factory.place_entity_immediate(merge, "grid_bulk_depot", Vector2i(112, 32), "", "target-b")
	var merge_first_input := factory.connect_entities(merge, "CARGO", "source-a", "merger", "iron_ingot", 1.0)
	var merge_second_input := factory.connect_entities(merge, "CARGO", "source-b", "merger", "iron_ingot", 1.0)
	var merge_output := factory.connect_entities(merge, "CARGO", "merger", "target-a", "iron_ingot", 1.0)
	var merge_second_output := factory.connect_entities(merge, "CARGO", "merger", "target-b", "iron_ingot", 1.0)
	_check(bool(merge_first_input.get("ok", false)) and bool(merge_second_input.get("ok", false)) and bool(merge_output.get("ok", false)) and str(merge_second_output.get("reason_code", "")) == "CARGO_OUTPUT_OCCUPIED", "Cargo Merger combines multiple same-item inputs into one output route")


func _test_congestion_and_atomic_link_configuration() -> void:
	var world := factory.create_world("congestion", "earth_orbit", Vector2i(128, 128), 2)
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 0), "", "source")
	factory.place_entity_immediate(world, "test_tiny_depot", Vector2i(40, 0), "", "target")
	world["entities"]["source"]["inventory"]["iron_ingot"] = 4
	var linked := factory.connect_entities(world, "CARGO", "source", "target", "iron_ingot", 4.0)
	var link_id := str(linked.get("link_id", ""))
	_check(bool(linked.get("ok", false)), "congestion fixture creates its Cargo link")
	factory.advance_world(world, 1000.0)
	var link: Dictionary = world.get("links", {}).get(link_id, {})
	_check(int(world["entities"]["target"].get("inventory", {}).get("iron_ingot", 0)) == 1 and str(link.get("blocked_reason", "")) == "TARGET_FULL" and is_equal_approx(float(link.get("congestion", 0.0)), 1.0), "full target inventory produces visible Cargo backpressure without losing source assets")
	var configured := factory.configure_link(world, link_id, {"priority":2})
	_check(bool(configured.get("ok", false)) and bool(configured.get("changed", false)) and int(world["links"][link_id].get("lane_count", 0)) == 1 and str(world["links"][link_id].get("tier", "")) == "MK1" and int(world["links"][link_id].get("priority", 0)) == 2, "configure_link persists routing priority without granting physical equipment")
	var before := JSON.stringify(world["links"][link_id])
	var invalid := factory.configure_link(world, link_id, {"capacity_per_second":9.0, "lane_count":12, "tier":"MK3", "path_tiles":[{"x":-1, "y":0}]})
	_check(not bool(invalid.get("ok", true)) and str(invalid.get("reason_code", "")) == "LINK_UPGRADE_REQUIRES_CONSTRUCTION" and JSON.stringify(world["links"][link_id]) == before, "configure_link rejects free physical route upgrades atomically")


func _test_powered_live_router_and_healthy_utilization() -> void:
	var world := factory.create_world("powered-router", "earth_orbit", Vector2i(128, 128), 20)
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 0), "", "source")
	factory.place_entity_immediate(world, "grid_cargo_splitter", Vector2i(40, 8), "", "router")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(72, 0), "", "target")
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(40, 56), "", "power")
	world["entities"]["source"]["inventory"]["iron_ingot"] = 4
	var incoming := factory.connect_entities(world, "CARGO", "source", "router", "iron_ingot", 1.0)
	var outgoing := factory.connect_entities(world, "CARGO", "router", "target", "iron_ingot", 1.0)
	_check(bool(incoming.get("ok", false)) and bool(outgoing.get("ok", false)), "live Cargo splitter fixture creates its bounded routes")
	factory.advance_world(world, 1000.0)
	_check(str(world["entities"]["router"].get("status", "")) == "NO_POWER" and int(world["entities"]["target"].get("inventory", {}).get("iron_ingot", 0)) == 0, "live powered router stops transport while disconnected from electricity")
	var power_link := factory.connect_entities(world, "POWER", "power", "router")
	_check(bool(power_link.get("ok", false)), "live router accepts a physical power route")
	var invalid_power_configuration := factory.configure_link(world, str(power_link.get("link_id", "")), {"priority":2})
	_check(not bool(invalid_power_configuration.get("ok", true)) and str(invalid_power_configuration.get("reason_code", "")) == "LINK_CONFIGURATION_UNSUPPORTED", "power links reject Cargo-only route-priority controls")
	factory.advance_world(world, 1000.0)
	_check(int(world["entities"]["target"].get("inventory", {}).get("iron_ingot", 0)) > 0 and str(world["entities"]["router"].get("status", "")) in ["FLOWING", "READY"], "power restores live router transport")

	var direct := factory.create_world("healthy-utilization", "earth_orbit", Vector2i(64, 64), 21)
	factory.place_entity_immediate(direct, "grid_bulk_depot", Vector2i(0, 0), "", "source")
	factory.place_entity_immediate(direct, "grid_bulk_depot", Vector2i(32, 0), "", "target")
	direct["entities"]["source"]["inventory"]["iron_ingot"] = 1
	var direct_link := factory.connect_entities(direct, "CARGO", "source", "target", "iron_ingot", 1.0)
	factory.advance_world(direct, 1000.0)
	var healthy: Dictionary = direct.get("links", {}).get(str(direct_link.get("link_id", "")), {})
	_check(is_equal_approx(float(healthy.get("last_flow", 0.0)), 1.0) and is_equal_approx(float(healthy.get("congestion", 1.0)), 0.0), "full healthy utilization is not mislabeled as Cargo congestion")

	var blocked := factory.create_world("blocked-router", "earth_orbit", Vector2i(96, 96), 33)
	factory.place_entity_immediate(blocked, "grid_solar_array", Vector2i(0, 48), "", "power")
	factory.place_entity_immediate(blocked, "grid_cargo_splitter", Vector2i(32, 16), "", "router")
	factory.place_entity_immediate(blocked, "test_tiny_depot", Vector2i(64, 16), "", "target")
	blocked["entities"]["router"]["inventory"]["iron_ingot"] = 1
	blocked["entities"]["target"]["inventory"]["iron_ingot"] = 1
	_check(bool(factory.connect_entities(blocked, "POWER", "power", "router").get("ok", false)), "blocked-router fixture creates a physical power route")
	factory.refresh_derived_state(blocked)
	_check(str(blocked["entities"]["router"].get("status", "")) == "OUTPUT_FULL", "a router with buffered cargo and no matching output route is not reported as ready")
	_check(bool(factory.connect_entities(blocked, "CARGO", "router", "target", "iron_ingot", 1.0).get("ok", false)), "blocked-router fixture creates its physical Cargo route")
	factory.advance_world(blocked, 1000.0)
	var blocked_snapshot := factory.workspace_snapshot(blocked)
	var blocked_row := _production_row(blocked_snapshot.get("production_rows", []), "router")
	_check(str(blocked["entities"]["router"].get("status", "")) == "OUTPUT_FULL" and str(blocked_row.get("blocker", "")) == "OUTPUT_FULL" and int(blocked_snapshot.get("production", {}).get("summary", {}).get("output_full", 0)) == 1, "a powered router with buffered cargo reports downstream backpressure in entity, row, and Production summary views")

	var partial := factory.create_world("partial-router", "earth_orbit", Vector2i(128, 96), 34)
	factory.place_entity_immediate(partial, "grid_solar_array", Vector2i(0, 48), "", "power")
	factory.place_entity_immediate(partial, "grid_cargo_splitter", Vector2i(32, 16), "", "router")
	factory.place_entity_immediate(partial, "test_tiny_depot", Vector2i(64, 0), "", "full-target")
	factory.place_entity_immediate(partial, "grid_bulk_depot", Vector2i(88, 32), "", "open-target")
	partial["entities"]["router"]["inventory"]["iron_ingot"] = 1
	partial["entities"]["full-target"]["inventory"]["iron_ingot"] = 1
	factory.connect_entities(partial, "POWER", "power", "router")
	factory.connect_entities(partial, "CARGO", "router", "full-target", "iron_ingot", 1.0)
	factory.connect_entities(partial, "CARGO", "router", "open-target", "iron_ingot", 0.25)
	factory.advance_world(partial, 1000.0)
	_check(str(partial["entities"]["router"].get("status", "")) == "READY", "one full splitter branch does not mark the whole router blocked while another matching output can still accept cargo")


func _test_merger_input_fairness() -> void:
	var world := factory.create_world("merger-fairness", "earth_orbit", Vector2i(128, 128), 22)
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 0), "", "source-a")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 40), "", "source-b")
	factory.place_entity_immediate(world, "test_tiny_router", Vector2i(40, 28), "", "router")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(72, 16), "", "sink")
	world["entities"]["source-a"]["inventory"]["iron_ingot"] = 4
	world["entities"]["source-b"]["inventory"]["iron_ingot"] = 4
	world["entities"]["router"]["inventory"]["iron_ingot"] = 1
	factory.connect_entities(world, "CARGO", "source-a", "router", "iron_ingot", 1.0)
	factory.connect_entities(world, "CARGO", "source-b", "router", "iron_ingot", 1.0)
	factory.connect_entities(world, "CARGO", "router", "sink", "iron_ingot", 1.0)
	for tick in 4:
		factory.advance_world(world, 1000.0)
	_check(int(world["entities"]["source-a"]["inventory"].get("iron_ingot", 0)) < 4 and int(world["entities"]["source-b"]["inventory"].get("iron_ingot", 0)) < 4, "capacity-limited merger rotates target reservations so no persistent source is starved")


func _test_merger_multi_item_capacity_fairness() -> void:
	var world := factory.create_world("merger-multi-item", "earth_orbit", Vector2i(160, 128), 23)
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 0), "", "iron-source")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 40), "", "copper-source")
	factory.place_entity_immediate(world, "test_tiny_router", Vector2i(40, 28), "", "router")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(72, 0), "", "iron-sink")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(104, 40), "", "copper-sink")
	world["entities"]["iron-source"]["inventory"]["iron_ingot"] = 4
	world["entities"]["copper-source"]["inventory"]["copper_ingot"] = 4
	world["entities"]["router"]["inventory"]["iron_ingot"] = 1
	factory.connect_entities(world, "CARGO", "iron-source", "router", "iron_ingot", 1.0)
	factory.connect_entities(world, "CARGO", "copper-source", "router", "copper_ingot", 1.0)
	factory.connect_entities(world, "CARGO", "router", "iron-sink", "iron_ingot", 1.0)
	factory.connect_entities(world, "CARGO", "router", "copper-sink", "copper_ingot", 1.0)
	for tick in 6:
		factory.advance_world(world, 1000.0)
	_check(int(world["entities"]["iron-source"]["inventory"].get("iron_ingot", 0)) < 4 and int(world["entities"]["copper-source"]["inventory"].get("copper_ingot", 0)) < 4, "shared one-slot merger capacity rotates fairly across different incoming item types")


func _test_cancellation_manifest_and_fail_closed_demolition() -> void:
	var world := _router_world()
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(100, 80), "", "construction-source")
	world["entities"]["construction-source"]["inventory"]["iron_ingot"] = 10
	var queued := factory.queue_construction(world, "grid_bulk_depot", Vector2i(72, 80))
	var order_id := str(queued.get("order_id", ""))
	_check(bool(queued.get("ok", false)) and bool(factory.fund_construction_from_storage(world, order_id, "construction-source").get("ok", false)), "cancellation fixture stages a fully funded construction order")
	var cancelled := factory.cancel_construction(world, order_id)
	_check(bool(cancelled.get("ok", false)) and int(cancelled.get("staging_manifest", {}).get("iron_ingot", 0)) == 10 and not world.get("construction_orders", {}).has(order_id), "cancel_construction atomically removes the order and returns its physical staging manifest for application-layer custody routing")
	var first_in: Dictionary = factory.connect_entities(world, "CARGO", "source-a", "router", "iron_ingot", 1.0)
	var first_out: Dictionary = factory.connect_entities(world, "CARGO", "router", "target-a", "iron_ingot", 1.0)
	_check(bool(first_in.get("ok", false)) and bool(first_out.get("ok", false)), "demolition fixture creates links incident to the router")
	world["entities"]["router"]["inventory"]["iron_ingot"] = 1
	var blocked := factory.remove_entity(world, "router")
	_check(not bool(blocked.get("ok", true)) and str(blocked.get("reason_code", "")) == "ENTITY_BUFFER_NOT_EMPTY" and world.get("entities", {}).has("router") and world.get("links", {}).size() == 2, "remove_entity fails closed while physical router buffers contain cargo")
	world["entities"]["router"]["inventory"] = {}
	var removed := factory.remove_entity(world, "router")
	_check(bool(removed.get("ok", false)) and not world.get("entities", {}).has("router") and world.get("links", {}).is_empty() and removed.get("removed_link_ids", []).size() == 2, "remove_entity atomically removes an empty entity and every incident link")


func _test_pre_output_capacity_reservation() -> void:
	var world := factory.create_world("output-reservation", "earth_orbit", Vector2i(64, 64), 3)
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power")
	factory.place_entity_immediate(world, "test_dual_output_machine", Vector2i(16, 0), "test_dual_output", "machine")
	factory.connect_entities(world, "POWER", "power", "machine")
	world["entities"]["machine"]["inputs"]["iron_ingot"] = 1
	factory.advance_world(world, 1000.0)
	var machine: Dictionary = world.get("entities", {}).get("machine", {})
	_check(
		str(machine.get("status", "")) == "OUTPUT_FULL"
		and machine.get("outputs", {}).is_empty()
		and int(machine.get("inputs", {}).get("iron_ingot", 0)) == 1,
		"machine output capacity is reserved before cycle completion, so a multi-output recipe cannot overflow its buffer or consume inputs into nowhere"
	)


func _router_world() -> Dictionary:
	var world := factory.create_world("router", "earth_orbit", Vector2i(128, 128), 1)
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 0), "", "source-a")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 40), "", "source-b")
	factory.place_entity_immediate(world, "test_router", Vector2i(40, 28), "", "router")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(70, 0), "", "target-a")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(70, 40), "", "target-b")
	return world


func _entity_snapshot(snapshot: Dictionary, entity_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity
	return {}


func _production_row(rows: Array, entity_id: String) -> Dictionary:
	for row_value in rows:
		var row := row_value as Dictionary
		if str(row.get("entity_id", "")) == entity_id:
			return row
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Factory production domain contract")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
