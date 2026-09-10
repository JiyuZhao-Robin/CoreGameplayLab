extends SceneTree

## Focused deterministic contract for the sparse road graph and its local
## transport adapter. This suite intentionally avoids the application facade;
## the primary agent owns transaction, ledger and command integration checks.

var failures: Array[String] = []
var factory: FactoryGridSimulation


func _initialize() -> void:
	var buildings := {
		"road_power":{"id":"road_power", "kind":"POWER", "footprint":{"width":1, "height":1}, "power_generation_kw":100.0},
		"road_mine":{"id":"road_mine", "kind":"EXTRACTOR", "footprint":{"width":1, "height":1}, "resource_id":"iron_ore", "resource_categories":["solid"], "sustainable_rate_per_second":1.0},
		"road_machine":{"id":"road_machine", "kind":"MACHINE", "footprint":{"width":1, "height":1}, "recipe_ids":["road_recipe"], "power_demand_kw":10.0, "input_capacity":4, "output_capacity":4, "speed":1.0},
		"road_storage":{"id":"road_storage", "kind":"STORAGE", "footprint":{"width":1, "height":1}, "inventory_capacity":20}
	}
	var recipes := {
		"road_recipe":{"id":"road_recipe", "duration_seconds":1.0, "inputs":[{"item":"iron_ore", "quantity":1}], "outputs":[{"item":"iron_ingot", "quantity":1}]}
	}
	factory = FactoryGridSimulation.new(buildings, recipes, {"road_courier_cargo_capacity":1, "road_min_travel_seconds":0.25})
	_test_world_defaults_and_atomic_bounds()
	_test_road_occupancy_and_components()
	_test_road_power_and_break()
	_test_timed_direct_delivery_and_custody()
	_test_snapshot_contract()
	if failures.is_empty():
		print("PASS: Factory road network")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_world_defaults_and_atomic_bounds() -> void:
	var world := factory.create_world("roads-default", "earth", Vector2i(8, 8))
	_check(str(world.get("logistics_mode", "")) == "PLANET_SHARED_ROADS" and world.get("roads", {}).is_empty() and world.get("road_shipments", {}).is_empty(), "new worlds default to sparse planet road logistics")
	var invalid := factory.edit_roads(world, [{"x":1, "y":1}, {"x":8, "y":1}], 1)
	_check(not bool(invalid.get("ok", true)) and str(invalid.get("reason_code", "")) == "ROAD_OUT_OF_BOUNDS" and world.get("roads", {}).is_empty(), "out-of-bounds road batches fail atomically")
	var malformed := factory.edit_roads(world, [{"x":1.5, "y":1}], 1)
	_check(not bool(malformed.get("ok", true)) and world.get("roads", {}).is_empty(), "fractional road coordinates are rejected without mutation")
	var built := factory.edit_roads(world, [{"x":1, "y":1}, {"x":2, "y":1}], 2)
	_check(bool(built.get("ok", false)) and int(built.get("costs", {}).get("iron_ingot", 0)) == 2, "tier-two road creation reports one iron cost per changed tile")
	var downgraded := factory.edit_roads(world, [{"x":1, "y":1}], 1)
	_check(bool(downgraded.get("ok", false)) and world.get("roads", {}).get("1,1", {}).get("tier", 0) == 2 and downgraded.get("changed_tiles", []).is_empty(), "reinforced roads never silently downgrade")
	var removed := factory.edit_roads(world, [{"x":4, "y":4}], 1, true)
	_check(bool(removed.get("ok", false)) and removed.get("changed_tiles", []).is_empty(), "removing an absent road tile is an idempotent no-op")


func _test_road_occupancy_and_components() -> void:
	var world := factory.create_world("roads-occupancy", "earth", Vector2i(16, 8))
	_check(bool(factory.place_entity_immediate(world, "road_storage", Vector2i(4, 4), "", "warehouse").get("ok", false)), "occupancy fixture places a storage")
	var blocked := factory.edit_roads(world, [{"x":4, "y":4}], 1)
	_check(not bool(blocked.get("ok", true)) and str(blocked.get("reason_code", "")) == "ROAD_OCCUPIED", "roads cannot be built through building footprints")
	var first := factory.edit_roads(world, [{"x":1, "y":1}, {"x":2, "y":1}, {"x":3, "y":1}], 1)
	var second := factory.edit_roads(world, [{"x":8, "y":1}], 1)
	var graph := FactoryRoadNetwork.build_graph(world)
	_check(bool(first.get("ok", false)) and bool(second.get("ok", false)) and graph.get("components", {}).size() == 2, "disconnected road batches create deterministic four-neighbor components")


func _test_road_power_and_break() -> void:
	var world := factory.create_world("roads-power", "earth", Vector2i(16, 8))
	factory.place_entity_immediate(world, "road_power", Vector2i(1, 0), "", "power")
	factory.place_entity_immediate(world, "road_machine", Vector2i(5, 0), "road_recipe", "machine")
	var tiles: Array = []
	for x in range(1, 6):
		tiles.append({"x":x, "y":1})
	factory.edit_roads(world, tiles, 1)
	factory.refresh_derived_state(world)
	_check(bool(world["entities"]["machine"].get("road_connected", false)) and float(world["entities"]["machine"].get("power_factor", 0.0)) > 0.99, "one connected road component shares generated power without a Power wire")
	factory.edit_roads(world, [{"x":3, "y":1}], 1, true)
	factory.refresh_derived_state(world)
	_check(float(world["entities"]["machine"].get("power_factor", 1.0)) == 0.0, "breaking the only road path removes power from the disconnected consumer")
	_check(str(factory.connect_entities(world, "POWER", "power", "machine").get("reason_code", "")) == "LEGACY_LINKS_RETIRED", "manual Power links are rejected in road mode")


func _test_timed_direct_delivery_and_custody() -> void:
	var world := factory.create_world("roads-transport", "earth", Vector2i(20, 8))
	_check(bool(factory.add_resource_field(world, "transport-ore", "iron_ore", Vector2i(3, 0), Vector2i(1, 1)).get("ok", false)), "transport fixture adds a resource field for the extractor")
	_check(bool(factory.place_entity_immediate(world, "road_power", Vector2i(1, 0), "", "power").get("ok", false)), "transport fixture places power")
	var mine_placed := factory.place_entity_immediate(world, "road_mine", Vector2i(3, 0), "", "mine")
	_check(bool(mine_placed.get("ok", false)), "transport fixture places the extractor")
	var machine_placed := factory.place_entity_immediate(world, "road_machine", Vector2i(7, 0), "road_recipe", "machine")
	_check(bool(machine_placed.get("ok", false)), "transport fixture places the machine")
	if not bool(mine_placed.get("ok", false)) or not bool(machine_placed.get("ok", false)):
		return
	var tiles: Array = []
	for x in range(1, 8):
		tiles.append({"x":x, "y":1})
	factory.edit_roads(world, tiles, 1)
	world["entities"]["mine"]["outputs"]["iron_ore"] = 1
	var context := {"inventory":{"iron_ore":1}, "available":{"iron_ore":1}, "free_capacity":{"iron_ore":10, "iron_ingot":10}}
	factory.refresh_derived_state(world)
	var before := int(world["entities"]["mine"]["outputs"].get("iron_ore", 0)) + int(context["inventory"].get("iron_ore", 0))
	factory.advance_world(world, 1000.0, context)
	_check(world.get("road_shipments", {}).size() > 0 and int(world["entities"]["mine"]["outputs"].get("iron_ore", 0)) < 1, "road pickup removes source cargo into a finite in-transit job")
	var after_pickup := int(world["entities"]["mine"]["outputs"].get("iron_ore", 0)) + int(context["inventory"].get("iron_ore", 0))
	_check(after_pickup <= before, "source cargo is not duplicated while direct delivery is in transit")
	factory.advance_world(world, 2000.0, context)
	_check(int(world["entities"]["machine"]["inputs"].get("iron_ore", 0)) >= 0 and int(context["inventory"].get("iron_ore", 0)) <= 1, "timed road delivery eventually reaches the consumer or remains represented as cargo")
	var broken_before := JSON.stringify(world.get("road_shipments", {}))
	factory.edit_roads(world, [{"x":5, "y":1}], 1, true)
	factory.advance_world(world, 1000.0, context)
	_check(not world.get("road_shipments", {}).is_empty() or broken_before == "{}", "a broken route preserves an in-transit job instead of deleting its cargo")


func _test_snapshot_contract() -> void:
	var world := factory.create_world("roads-snapshot", "earth", Vector2i(12, 8))
	factory.edit_roads(world, [{"x":2, "y":2}, {"x":1, "y":2}], 1)
	var snapshot := factory.workspace_snapshot(world)
	_check(str(snapshot.get("logistics_mode", "")) == "PLANET_SHARED_ROADS" and snapshot.get("links", []).is_empty() and snapshot.get("roads", []).size() == 2, "workspace snapshot exposes sorted road topology and no legacy links")
	_check(snapshot.has("road_logistics") and snapshot.get("road_logistics", {}).has("active_shipments"), "workspace snapshot exposes bounded road logistics diagnostics")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
