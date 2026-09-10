extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_test_neutral_environment_is_unchanged()
	_test_solar_and_non_solar_generation()
	_test_operating_overheads_and_sanitization()
	_test_definition_records_are_not_mutated()
	_test_finished_building_deployment_has_no_work_timer()
	_test_finished_building_deployment_respects_priority_once()
	_test_workspace_effective_ratings_match_simulation()
	_test_environment_normalization_preserves_location_copy()
	_test_sliced_and_one_shot_finished_deployment_match()
	_finish()


func _test_neutral_environment_is_unchanged() -> void:
	var factory := _factory()
	var world := factory.create_world("neutral", "", Vector2i(128, 128), 1)
	var effects := factory.environment_effects(world)
	_check(
		is_equal_approx(float(effects.get("solar_generation_multiplier", 0.0)), 1.0)
		and is_equal_approx(float(effects.get("power_demand_multiplier", 0.0)), 1.0)
		and is_equal_approx(float(effects.get("construction_work_multiplier", 0.0)), 1.0)
		and is_equal_approx(float(effects.get("construction_speed_multiplier", 0.0)), 1.0),
		"missing world environment resolves to neutral Factory effects"
	)
	_check(
		is_equal_approx(factory.effective_generation_kw(world, _definitions()["grid_solar_array"]), 100.0)
		and is_equal_approx(factory.effective_demand_kw(world, _definitions()["consumer"]), 40.0),
		"neutral fixtures retain nominal solar generation and operating demand"
	)


func _test_solar_and_non_solar_generation() -> void:
	var factory := _factory()
	var world := factory.create_world("solar", "", Vector2i(128, 128), 2)
	world["environment"] = {"solar_flux":0.0}
	var solar: Dictionary = _definitions()["grid_solar_array"]
	var fusion: Dictionary = _definitions()["grid_fusion_array"]
	_check(
		is_zero_approx(factory.effective_generation_kw(world, solar))
		and is_equal_approx(factory.effective_generation_kw(world, fusion), 200.0),
		"zero sunlight disables only an authored solar generator"
	)
	world["environment"] = {"solar_flux":4.0}
	_check(
		is_equal_approx(factory.effective_generation_kw(world, solar), 200.0)
		and is_equal_approx(factory.effective_generation_kw(world, fusion), 200.0),
		"solar generation follows sqrt(flux) without boosting non-solar generation"
	)
	var optional_solar := {"id":"custom_collector", "solar_generator":true, "power_generation_kw":25.0}
	_check(is_equal_approx(factory.effective_generation_kw(world, optional_solar), 50.0), "solar_generator definitions opt into the same deterministic flux adjustment")


func _test_operating_overheads_and_sanitization() -> void:
	var effects := FactoryEnvironmentEffects.snapshot({
		"thermal_environment":"EXTREME_COLD",
		"radiation":"HIGH",
		"gravity":0.5,
		"atmosphere":"GAS_GIANT",
		"construction_difficulty":2.0
	})
	var expected_demand := 1.30 * 1.15 * 1.05 * 1.15
	_check(
		is_equal_approx(float(effects.get("thermal_power_multiplier", 0.0)), 1.30)
		and is_equal_approx(float(effects.get("radiation_power_multiplier", 0.0)), 1.15)
		and is_equal_approx(float(effects.get("gravity_power_multiplier", 0.0)), 1.05)
		and is_equal_approx(float(effects.get("atmosphere_power_multiplier", 0.0)), 1.15)
		and is_equal_approx(float(effects.get("power_demand_multiplier", 0.0)), expected_demand)
		and is_equal_approx(float(effects.get("construction_work_multiplier", 0.0)), 2.0)
		and is_equal_approx(float(effects.get("construction_speed_multiplier", 0.0)), 0.5),
		"thermal, radiation, gravity and gas-atmosphere overheads compose explicitly"
	)
	var malformed := FactoryEnvironmentEffects.snapshot({
		"solar_flux":INF,
		"gravity":NAN,
		"construction_difficulty":-5.0,
		"thermal_environment":"UNKNOWN",
		"radiation":"UNKNOWN"
	})
	_check(
		is_equal_approx(float(malformed.get("solar_generation_multiplier", 0.0)), 1.0)
		and is_equal_approx(float(malformed.get("gravity_power_multiplier", 0.0)), 1.0)
		and is_equal_approx(float(malformed.get("construction_speed_multiplier", 0.0)), 10.0),
		"non-finite environment magnitudes fall back safely and difficulty is clamped to 0.1"
	)


func _test_definition_records_are_not_mutated() -> void:
	var definitions := _definitions()
	var original := definitions.duplicate(true)
	var factory := FactoryGridSimulation.new(definitions, {}, {"simulation_step_seconds":1.0})
	var world := factory.create_world("immutable", "", Vector2i(128, 128), 3)
	world["environment"] = {"solar_flux":0.25, "thermal_environment":"COLD", "construction_difficulty":1.5}
	factory.effective_generation_kw(world, definitions["grid_solar_array"])
	factory.effective_demand_kw(world, definitions["consumer"])
	factory.workspace_snapshot(world)
	_check(definitions == original, "environment projection never mutates caller-owned building definitions")


func _test_finished_building_deployment_has_no_work_timer() -> void:
	var factory := _factory()
	var world := factory.create_world("deployment-hard", "", Vector2i(128, 128), 6)
	world["environment"] = {"construction_difficulty":2.0}
	var order_id := _queue_target(factory, world, 60, Vector2i(20, 0))
	var inventory := {"building_target":0}
	var available := {"building_target":0}
	var context := _deployment_context(inventory, available)
	factory.advance_world(world, 60000.0, context)
	var ghost: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	_check(
		world.get("entities", {}).is_empty()
		and str(ghost.get("status", "")) == "WAITING_BUILDING"
		and str(ghost.get("blocked_reason", "")) == "MISSING_BUILDING"
		and not ghost.has("work_done")
		and not ghost.has("work_required"),
		"environment difficulty never turns a missing finished building into timed on-site construction"
	)
	inventory["building_target"] = 1
	available["building_target"] = 1
	var events := factory.deploy_pending_buildings(world, context)
	_check(
		events.size() == 1
		and world.get("construction_orders", {}).is_empty()
		and world.get("entities", {}).has(str(events[0].get("entity_id", "")))
		and int(inventory.get("building_target", -1)) == 0
		and int(available.get("building_target", -1)) == 0,
		"one available finished building deploys immediately and transfers exactly one item from shared inventory"
	)
	factory.advance_world(world, 60000.0, context)
	_check(int(inventory.get("building_target", -1)) == 0 and world.get("entities", {}).size() == 1, "later simulation time cannot consume a second building or redeploy the completed ghost")


func _test_finished_building_deployment_respects_priority_once() -> void:
	var factory := _factory()
	var world := factory.create_world("deployment-priority", "", Vector2i(128, 128), 7)
	var high_order := _queue_target(factory, world, 90, Vector2i(20, 0))
	var low_order := _queue_target(factory, world, 10, Vector2i(40, 0))
	var inventory := {"building_target":1}
	var available := {"building_target":1}
	var context := _deployment_context(inventory, available)
	var first := factory.deploy_pending_buildings(world, context)
	_check(
		first.size() == 1
		and str(first[0].get("order_id", "")) == high_order
		and world.get("construction_orders", {}).has(low_order)
		and int(inventory.get("building_target", -1)) == 0
		and int(available.get("building_target", -1)) == 0,
		"one finished building resolves only the highest-priority ghost and cannot be double-spent"
	)
	inventory["building_target"] = 1
	available["building_target"] = 1
	var second := factory.deploy_pending_buildings(world, context)
	_check(second.size() == 1 and str(second[0].get("order_id", "")) == low_order and world.get("construction_orders", {}).is_empty(), "the next arriving finished building resolves the remaining ghost in deterministic priority order")


func _test_workspace_effective_ratings_match_simulation() -> void:
	var factory := _factory()
	var world := factory.create_world("snapshot", "", Vector2i(128, 128), 4)
	world["environment"] = {
		"solar_flux":0.25,
		"thermal_environment":"THERMAL_CYCLING",
		"radiation":"MODERATE",
		"gravity":0.2,
		"atmosphere":"NONE"
	}
	_check(bool(factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "solar").get("ok", false)), "snapshot fixture places solar generation")
	_check(bool(factory.place_entity_immediate(world, "grid_fusion_array", Vector2i(20, 0), "", "fusion").get("ok", false)), "snapshot fixture places non-solar generation")
	_check(bool(factory.place_entity_immediate(world, "consumer", Vector2i(40, 0), "", "consumer").get("ok", false)), "snapshot fixture places a demand endpoint")
	var roads: Array = []
	for x in range(44):
		roads.append({"x":x, "y":4})
	_check(bool(factory.edit_roads(world, roads, 1).get("ok", false)), "one actual road component touches the solar, fusion and consumer footprints")
	factory.advance_world(world, 1.0)
	var snapshot := factory.workspace_snapshot(world)
	var solar := _entity(snapshot, "solar")
	var consumer := _entity(snapshot, "consumer")
	var effects: Dictionary = snapshot.get("environment_effects", {})
	var expected_generation := factory.effective_generation_kw(world, _definitions()["grid_solar_array"])
	var expected_demand := factory.effective_demand_kw(world, _definitions()["consumer"])
	var palette_solar := _palette_building(snapshot, "grid_solar_array")
	_check(
		is_equal_approx(float(solar.get("power_generation_kw", 0.0)), expected_generation)
		and is_equal_approx(float(solar.get("nominal_power_generation_kw", 0.0)), 100.0)
		and is_equal_approx(float(consumer.get("power_demand_kw", 0.0)), expected_demand)
		and is_equal_approx(float(palette_solar.get("power_generation_kw", 0.0)), expected_generation)
		and is_equal_approx(float(snapshot.get("power", {}).get("generation_kw", 0.0)), expected_generation + 200.0)
		and bool(solar.get("road_connected", false))
		and bool(consumer.get("road_connected", false))
		and float(consumer.get("power_factor", 0.0)) >= 0.99
		and snapshot.get("environment", {}) == world.get("environment", {})
		and is_equal_approx(float(effects.get("solar_generation_multiplier", 0.0)), 0.5),
		"effective entity, palette and workspace power snapshots use environment helpers on a real shared road component"
	)


func _test_environment_normalization_preserves_location_copy() -> void:
	var factory := _factory()
	var world := factory.create_world("normalized", "deep_system", Vector2i(128, 128), 5)
	world["environment"] = {"solar_flux":0.02, "thermal_environment":"EXTREME_COLD", "custom_future_field":{"enabled":true}}
	var normalized := factory.normalize_world(world)
	normalized["environment"]["solar_flux"] = 1.0
	_check(is_equal_approx(float(world.get("environment", {}).get("solar_flux", 0.0)), 0.02) and bool(normalized.get("environment", {}).get("custom_future_field", {}).get("enabled", false)), "normalization preserves a detached world environment copy for later canonical reprojection")


func _test_sliced_and_one_shot_finished_deployment_match() -> void:
	var factory := _factory()
	var one_shot := factory.create_world("one-shot", "", Vector2i(128, 128), 10)
	var sliced := factory.create_world("sliced", "", Vector2i(128, 128), 10)
	one_shot["environment"] = {"construction_difficulty":1.6}
	sliced["environment"] = {"construction_difficulty":1.6}
	var one_shot_order := _queue_target(factory, one_shot, 70, Vector2i(20, 0))
	var sliced_order := _queue_target(factory, sliced, 70, Vector2i(20, 0))
	var one_shot_inventory := {"building_target":0}
	var one_shot_available := {"building_target":0}
	var sliced_inventory := {"building_target":0}
	var sliced_available := {"building_target":0}
	factory.advance_world(one_shot, 7000.0, _deployment_context(one_shot_inventory, one_shot_available))
	factory.advance_world(sliced, 2000.0, _deployment_context(sliced_inventory, sliced_available))
	factory.advance_world(sliced, 3000.0, _deployment_context(sliced_inventory, sliced_available))
	factory.advance_world(sliced, 2000.0, _deployment_context(sliced_inventory, sliced_available))
	_check(
		one_shot.get("construction_orders", {}).has(one_shot_order)
		and sliced.get("construction_orders", {}).has(sliced_order)
		and one_shot.get("entities", {}).is_empty()
		and sliced.get("entities", {}).is_empty()
		and is_equal_approx(float(one_shot.get("elapsed_ms", 0.0)), float(sliced.get("elapsed_ms", 0.0))),
		"one-shot and sliced time both leave a missing finished-building ghost untouched"
	)
	one_shot_inventory["building_target"] = 1
	one_shot_available["building_target"] = 1
	sliced_inventory["building_target"] = 1
	sliced_available["building_target"] = 1
	var one_shot_events := factory.deploy_pending_buildings(one_shot, _deployment_context(one_shot_inventory, one_shot_available))
	var sliced_events := factory.deploy_pending_buildings(sliced, _deployment_context(sliced_inventory, sliced_available))
	_check(
		one_shot_events.size() == 1
		and sliced_events.size() == 1
		and one_shot.get("construction_orders", {}).is_empty()
		and sliced.get("construction_orders", {}).is_empty()
		and int(one_shot_inventory.get("building_target", -1)) == 0
		and int(sliced_inventory.get("building_target", -1)) == 0,
		"once finished stock arrives, sliced and one-shot worlds both deploy exactly one building without a construction-time delta"
	)


func _factory() -> FactoryGridSimulation:
	return FactoryGridSimulation.new(_definitions(), {}, {"simulation_step_seconds":1.0})


func _definitions() -> Dictionary:
	return {
		"grid_solar_array":{"id":"grid_solar_array", "kind":"POWER", "footprint":{"width":4, "height":4}, "power_generation_kw":100.0},
		"grid_fusion_array":{"id":"grid_fusion_array", "kind":"POWER", "footprint":{"width":4, "height":4}, "power_generation_kw":200.0},
		"consumer":{"id":"consumer", "kind":"STORAGE", "footprint":{"width":4, "height":4}, "power_demand_kw":40.0},
		"target":{"id":"target", "kind":"STORAGE", "footprint":{"width":4, "height":4}, "deployment_item_id":"building_target"}
	}


func _queue_target(factory: FactoryGridSimulation, world: Dictionary, priority: int, origin: Vector2i) -> String:
	var queued := factory.queue_construction(world, "target", origin, "", priority)
	_check(bool(queued.get("ok", false)), "target fixture queues a finished-building deployment ghost")
	return str(queued.get("order_id", ""))


func _deployment_context(inventory: Dictionary, available: Dictionary) -> Dictionary:
	return {"inventory":inventory, "available":available, "free_capacity":{}}


func _entity(snapshot: Dictionary, entity_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity
	return {}


func _palette_building(snapshot: Dictionary, definition_id: String) -> Dictionary:
	for building_value in snapshot.get("palette", {}).get("buildings", []):
		var building := building_value as Dictionary
		if str(building.get("id", "")) == definition_id:
			return building
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Factory environment effects")
		quit(0)
		return
	print("FAIL: %d Factory environment effect assertion(s) failed" % failures.size())
	quit(1)
