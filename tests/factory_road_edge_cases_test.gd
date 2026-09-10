extends SceneTree

## Deterministic road-regression probes. These work directly against the Factory
## domain boundary and deliberately avoid Game, UI, save, and content fixtures.

const GridScript = preload("res://src/core/factory_grid_simulation.gd")
const TransportScript = preload("res://src/core/factory_road_transport.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_test_shared_machine_buffer_fairness()
	_test_recreated_location_capacity_and_transit_hold()
	_test_graph_cache_fingerprint_includes_roads()
	_test_disconnected_components_share_location_warehouse()
	_test_ghost_roads_do_not_conduct()
	_test_courier_limits_and_loading_bays()
	_test_partial_road_upgrade_updates_active_trip()
	_test_recipe_change_returns_loaded_cargo()
	_test_malformed_manifest_preserves_all_cargo()
	_finish()


func _test_shared_machine_buffer_fairness() -> void:
	var grid = _grid(2, {"road_input_buffer_cycles":2})
	var world: Dictionary = grid.create_world("two-input", "earth", Vector2i(16, 8), 1)
	if not _place(grid, world, "power", Vector2i(1, 1), "power") or not _place(grid, world, "machine", Vector2i(4, 1), "machine", "two") or not _place(grid, world, "storage", Vector2i(7, 1), "store"):
		return
	_roads(grid, world, _line(1, 7, 2))
	grid.refresh_derived_state(world)
	var context := _context({"ore":8, "coal":8}, {"ore":92, "coal":92, "alloy":100})
	for _tick in range(20):
		grid.advance_world(world, 1000.0, context)
	_check(int(context["inventory"].get("alloy", 0)) > 0, "a two-input recipe eventually produces when a shared input buffer fits one full recipe; the first ingredient cannot permanently fill it")


func _test_recreated_location_capacity_and_transit_hold() -> void:
	var grid = _grid(1)
	var world: Dictionary = grid.create_world("capacity", "earth", Vector2i(12, 8), 2)
	if not _place(grid, world, "machine", Vector2i(1, 1), "source", "ship") or not _place(grid, world, "storage", Vector2i(5, 1), "store"):
		return
	_roads(grid, world, _line(1, 5, 2))
	world["entities"]["source"]["outputs"] = {"ore":2}
	grid.advance_world(world, 1.0, _context({}, {"ore":1}))
	var jobs: Dictionary = world.get("road_shipments", {})
	_check(jobs.size() == 1 and int(world["entities"]["source"].get("outputs", {}).get("ore", 0)) == 1, "a re-created location capacity context excludes its own in-transit reservation exactly once and cannot queue past one free slot")
	grid.advance_world(world, 1000.0, _context({}, {"ore":0}))
	jobs = world.get("road_shipments", {})
	var retained_cargo := 0
	for job_value in jobs.values():
		retained_cargo += int((job_value as Dictionary).get("cargo", {}).get("ore", 0))
	_check(jobs.size() == 1 and retained_cargo == 1, "reducing destination capacity to zero during transit blocks delivery without deleting cargo")
	var reopened := _context({}, {"ore":1})
	grid.advance_world(world, 1000.0, reopened)
	_check(int(reopened["inventory"].get("ore", 0)) == 1 and world.get("road_shipments", {}).is_empty() and int(world["entities"]["source"].get("outputs", {}).get("ore", 0)) == 1, "restored capacity accepts exactly the retained shipment and never overfills the location item slot")


func _test_graph_cache_fingerprint_includes_roads() -> void:
	var grid = _grid(1)
	var connected: Dictionary = grid.create_world("same-id", "earth", Vector2i(12, 8), 3)
	var disconnected: Dictionary = grid.create_world("same-id", "earth", Vector2i(12, 8), 3)
	if not _place(grid, connected, "power", Vector2i(1, 1), "power") or not _place(grid, connected, "machine", Vector2i(5, 1), "machine", "one"):
		return
	if not _place(grid, disconnected, "power", Vector2i(1, 1), "power") or not _place(grid, disconnected, "machine", Vector2i(5, 1), "machine", "one"):
		return
	_roads(grid, connected, _line(1, 5, 2))
	_roads(grid, disconnected, _line(1, 5, 5))
	grid.refresh_derived_state(connected)
	grid.refresh_derived_state(disconnected)
	_check(int(connected.get("topology_revision", -1)) == int(disconnected.get("topology_revision", -2)) and float(connected["entities"]["machine"].get("power_factor", 0.0)) > 0.99 and is_zero_approx(float(disconnected["entities"]["machine"].get("power_factor", 1.0))), "two worlds with identical IDs and revisions but different road geometry do not share a stale graph cache")


func _test_disconnected_components_share_location_warehouse() -> void:
	var grid = _grid(1)
	var world: Dictionary = grid.create_world("components", "earth", Vector2i(24, 8), 4)
	if not _place(grid, world, "power", Vector2i(1, 1), "power-a") or not _place(grid, world, "machine", Vector2i(3, 1), "machine-a", "one") or not _place(grid, world, "storage", Vector2i(5, 1), "store-a"):
		return
	if not _place(grid, world, "power", Vector2i(13, 1), "power-b") or not _place(grid, world, "machine", Vector2i(15, 1), "machine-b", "one") or not _place(grid, world, "storage", Vector2i(17, 1), "store-b"):
		return
	_roads(grid, world, _line(1, 5, 2) + _line(13, 17, 2))
	grid.refresh_derived_state(world)
	var context := _context({"ore":2}, {"ore":98, "ingot":100})
	for _tick in range(16):
		grid.advance_world(world, 1000.0, context)
	var snapshot: Dictionary = grid.workspace_snapshot(world)
	var components := {}
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")).begins_with("machine"):
			components[str(entity.get("road_component_id", ""))] = true
	_check(world.get("links", {}).is_empty() and components.size() == 2 and int(context["inventory"].get("ingot", 0)) >= 2, "two disconnected road components can independently use their local warehouse access to one shared Location inventory without warehouse-to-warehouse links")


func _test_ghost_roads_do_not_conduct() -> void:
	var grid = _grid(1)
	var world: Dictionary = grid.create_world("ghosts", "earth", Vector2i(8, 8), 5)
	if not _place(grid, world, "power", Vector2i(1, 1), "power") or not _place(grid, world, "machine", Vector2i(4, 1), "machine", "one"):
		return
	for x in range(1, 5):
		world["roads"]["%d,2" % x] = {"x":x, "y":2, "tier":1, "ghost":x % 2 == 0, "status":"GHOST" if x % 2 == 1 else "READY"}
	_check(bool(grid.can_place_entity(world, "power", Vector2i(2, 2)).get("ok", false)), "a raw ghost road does not block placement before normalization")
	var normalized: Dictionary = grid.normalize_world(world)
	grid.refresh_derived_state(normalized)
	var snapshot: Dictionary = grid.workspace_snapshot(normalized)
	_check(normalized.get("roads", {}).is_empty() and snapshot.get("roads", []).is_empty() and is_zero_approx(float(normalized["entities"]["machine"].get("power_factor", 1.0))), "ghost-flagged or GHOST-status road records are discarded by normalization and never conduct electricity")


func _test_courier_limits_and_loading_bays() -> void:
	var grid = _grid(1)
	var world: Dictionary = grid.create_world("couriers", "earth", Vector2i(16, 8), 6)
	for index in range(3):
		if not _place(grid, world, "machine", Vector2i(1 + index * 3, 1), "source-%d" % index, "ship"):
			return
		world["entities"]["source-%d" % index]["outputs"] = {"ore":4}
	if not _place(grid, world, "storage", Vector2i(10, 1), "store"):
		return
	_roads(grid, world, _line(1, 10, 2))
	var context := _context({}, {"ore":100})
	var rules := {"road_couriers_per_building":1, "road_warehouse_loading_bays":1, "road_loading_seconds":1.0}
	TransportScript.queue(world, grid.building_definitions, grid.recipe_definitions, rules, context)
	_check(world["road_shipments"].size() == 3, "courier slots belong to individual buildings, not one global courier for the planet")
	TransportScript.queue(world, grid.building_definitions, grid.recipe_definitions, rules, context)
	_check(world["road_shipments"].size() == 3, "busy buildings cannot dispatch unlimited couriers")
	for job_value in world["road_shipments"].values():
		(job_value as Dictionary)["remaining_ms"] = 0.0
	TransportScript.advance(world, 1.0, grid.building_definitions, grid.recipe_definitions, rules, context)
	_check(int(context["inventory"].get("ore", 0)) == 1, "one warehouse loading bay unloads only one one-second job per second")
	var capped: Dictionary = grid.normalize_world(world)
	capped["road_shipments"] = {}
	capped["road_dispatch_after"] = ""
	rules["road_max_active_shipments"] = 1
	var owners := {}
	for _round in range(3):
		TransportScript.queue(capped, grid.building_definitions, grid.recipe_definitions, rules, context)
		for job_value in capped["road_shipments"].values():
			owners[str((job_value as Dictionary)["courier_owner_id"])] = true
		TransportScript.advance(capped, 100.0, grid.building_definitions, grid.recipe_definitions, rules, context)
	_check(owners.size() == 3, "a global courier safety cap rotates dispatch across producers instead of starving later IDs")


func _test_partial_road_upgrade_updates_active_trip() -> void:
	var grid = _grid(1)
	var world: Dictionary = grid.create_world("upgrade", "earth", Vector2i(16, 8), 7)
	if not _place(grid, world, "machine", Vector2i(1, 1), "source", "ship") or not _place(grid, world, "storage", Vector2i(9, 1), "store"):
		return
	_roads(grid, world, _line(1, 9, 2))
	world["entities"]["source"]["outputs"] = {"ore":1}
	var context := _context({}, {"ore":100})
	TransportScript.queue(world, grid.building_definitions, grid.recipe_definitions, {}, context)
	var job: Dictionary = world["road_shipments"].values()[0]
	var before := float(job["travel_ms"])
	grid.edit_roads(world, _line(5, 9, 2), 2)
	TransportScript.advance(world, 0.0, grid.building_definitions, grid.recipe_definitions, {}, context)
	_check(float(job["travel_ms"]) < before and float(job["travel_ms"]) > before * 0.5 and int(job["road_topology_revision"]) == int(world["topology_revision"]), "upgrading part of an active route improves its actual travel time and refreshes the cached topology revision")


func _test_recipe_change_returns_loaded_cargo() -> void:
	var grid = _grid(2)
	var world: Dictionary = grid.create_world("recipe-return", "earth", Vector2i(12, 8), 8)
	if not _place(grid, world, "machine", Vector2i(1, 1), "machine", "one") or not _place(grid, world, "storage", Vector2i(5, 1), "store"):
		return
	_roads(grid, world, _line(1, 5, 2))
	var context := _context({"ore":2}, {"ore":98})
	TransportScript.queue(world, grid.building_definitions, grid.recipe_definitions, {}, context)
	_check(int(context["inventory"]["ore"]) == 1 and world["road_shipments"].size() == 1, "warehouse pickup transfers one actual item into courier custody")
	grid.set_entity_recipe(world, "machine", "ship")
	TransportScript.advance(world, 10.0, grid.building_definitions, grid.recipe_definitions, {}, context)
	_check(int(context["inventory"]["ore"]) == 2 and world["road_shipments"].is_empty(), "changing to an incompatible recipe returns loaded cargo to shared inventory without duplication or loss")


func _test_malformed_manifest_preserves_all_cargo() -> void:
	var grid = _grid(1)
	var world: Dictionary = grid.create_world("malformed-cargo", "earth", Vector2i(12, 8), 9)
	if not _place(grid, world, "machine", Vector2i(1, 1), "source", "ship") or not _place(grid, world, "storage", Vector2i(5, 1), "store"):
		return
	_roads(grid, world, _line(1, 5, 2))
	world["entities"]["source"]["outputs"] = {"ore":1}
	var context := _context({}, {"ore":100, "coal":100})
	TransportScript.queue(world, grid.building_definitions, grid.recipe_definitions, {}, context)
	var job: Dictionary = world["road_shipments"].values()[0]
	job["cargo"]["coal"] = 1
	world = grid.normalize_world(world)
	TransportScript.advance(world, 100.0, grid.building_definitions, grid.recipe_definitions, {}, context)
	job = world["road_shipments"].values()[0]
	_check(job["cargo"] == {"ore":1, "coal":1} and str(job["status"]) == "BLOCKED_MANIFEST" and context["inventory"].is_empty(), "unsupported multi-item manifests retain all cargo instead of delivering one item and deleting the rest")


func _grid(input_capacity: int, extra_rules: Dictionary = {}):
	var definitions := {
		"power":{"id":"power", "kind":"POWER", "footprint":{"width":1, "height":1}, "power_generation_kw":100.0},
		"machine":{"id":"machine", "kind":"MACHINE", "footprint":{"width":1, "height":1}, "power_demand_kw":10.0, "speed":1.0, "input_capacity":input_capacity, "output_capacity":8, "recipe_ids":["two", "one", "ship"]},
		"storage":{"id":"storage", "kind":"STORAGE", "footprint":{"width":1, "height":1}, "inventory_capacity":100}
	}
	var recipes := {
		"two":{"id":"two", "duration_seconds":1.0, "inputs":[{"item":"ore", "quantity":1}, {"item":"coal", "quantity":1}], "outputs":[{"item":"alloy", "quantity":1}]},
		"one":{"id":"one", "duration_seconds":1.0, "inputs":[{"item":"ore", "quantity":1}], "outputs":[{"item":"ingot", "quantity":1}]},
		"ship":{"id":"ship", "duration_seconds":1.0, "inputs":[], "outputs":[{"item":"ore", "quantity":1}]}
	}
	var rules := {"simulation_step_seconds":1.0, "road_courier_capacity_per_second":1.0, "road_courier_cargo_capacity":1, "road_courier_bays":1, "road_min_travel_seconds":0.05}
	rules.merge(extra_rules, true)
	return GridScript.new(definitions, recipes, rules)


func _place(grid, world: Dictionary, definition_id: String, origin: Vector2i, entity_id: String, recipe_id: String = "") -> bool:
	var result: Dictionary = grid.place_entity_immediate(world, definition_id, origin, recipe_id, entity_id)
	if bool(result.get("ok", false)):
		return true
	failures.append("fixture failed to place %s: %s" % [entity_id, str(result)])
	return false


func _roads(grid, world: Dictionary, tiles: Array) -> void:
	var result: Dictionary = grid.edit_roads(world, tiles, 1)
	if not bool(result.get("ok", false)):
		failures.append("fixture failed to build roads: %s" % str(result))


func _line(first_x: int, last_x: int, y: int) -> Array:
	var result: Array = []
	for x in range(first_x, last_x + 1):
		result.append({"x":x, "y":y})
	return result


func _context(inventory: Dictionary, free_capacity: Dictionary) -> Dictionary:
	return {"inventory":inventory.duplicate(true), "available":inventory.duplicate(true), "free_capacity":free_capacity.duplicate(true)}


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_ROAD_EDGE_CASES_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
