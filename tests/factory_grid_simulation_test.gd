extends SceneTree

var failures: Array[String] = []
var database: ContentDatabase
var factory: FactoryGridSimulation


func _initialize() -> void:
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "grid-factory content loads: %s" % str(database.errors))
	if not failures.is_empty():
		_finish()
		return
	factory = FactoryGridSimulation.new(database.factory_buildings, database.factory_recipes, database.factory_grid_rules)
	_test_sparse_square_world_and_tile_resources()
	_test_world_profile_contracts()
	_test_resource_field_exclusion_and_coverage()
	_test_placement_and_port_contracts()
	_test_unconfigured_machine_contracts()
	_test_fair_and_priority_routing()
	_test_transport_capacity_does_not_bank()
	_test_resource_potential_caps_high_grade_extraction()
	_test_mining_production_power_and_conservation()
	_test_backpressure_and_recovery()
	_test_empty_construction_funding_is_rejected()
	_test_production_funds_real_construction()
	_test_simulation_engine_integration()
	_test_new_game_factory_bootstrap()
	_test_factory_bound_force_crop()
	_test_application_command_boundary()
	_test_removed_aggregate_runtime_cannot_restart()
	_test_save_round_trip()
	_finish()


func _test_sparse_square_world_and_tile_resources() -> void:
	var world := factory.create_world("earth-grid", "earth_orbit", Vector2i(512, 384), 730201)
	_check(world.get("entities", {}).is_empty() and world.get("resource_fields", {}).is_empty() and world.get("tile_deltas", {}).is_empty(), "finite world bounds do not allocate a width-by-height tile array")
	_check(factory.chunk_coordinate(world, Vector2i(63, 63)) == Vector2i(0, 0), "tile 63 remains in chunk zero")
	_check(factory.chunk_coordinate(world, Vector2i(64, 64)) == Vector2i(1, 1) and factory.chunk_local_coordinate(world, Vector2i(64, 64)) == Vector2i.ZERO, "tile 64 crosses to the next 64-metre chunk")
	var first := factory.tile_snapshot(world, Vector2i(100, 200))
	var second_world := factory.create_world("earth-grid-copy", "earth_orbit", Vector2i(512, 384), 730201)
	var second := factory.tile_snapshot(second_world, Vector2i(100, 200))
	_check(first.get("terrain_type", "") == second.get("terrain_type", "") and str(first.get("terrain_type", "")) in ["MOUNTAIN", "WATER", "FOREST", "PLAIN", "DESERT"] and not str(first.get("terrain_color", "")).is_empty(), "seed plus integer metre coordinate deterministically regenerates a colored terrain attribute")
	_check(not bool(factory.tile_snapshot(world, Vector2i(-1, 0)).get("valid", true)), "world bounds reject negative out-of-canvas coordinates")
	_check(bool(factory.tile_snapshot(world, Vector2i(511, 383)).get("valid", false)) and not bool(factory.tile_snapshot(world, Vector2i(512, 383)).get("valid", true)), "finite bounds include the final tile and reject the first tile beyond the upper-right edge")
	var field_result := factory.add_resource_field(world, "iron-field-a", "iron_ore", Vector2i(128, 128), Vector2i(24, 20), 1.25, 0.5, "solid")
	_check(bool(field_result.get("ok", false)) and world.get("entities", {}).is_empty() and world.get("resource_fields", {}).has("iron-field-a"), "a resource field is registered as tile-layer data rather than an entity")
	var mineral_tile := factory.tile_snapshot(world, Vector2i(130, 135))
	_check(str(mineral_tile.get("resource_field_id", "")) == "iron-field-a" and str(mineral_tile.get("resource_id", "")) == "iron_ore" and not str(mineral_tile.get("resource_color", "")).is_empty() and is_equal_approx(float(mineral_tile.get("grade", 0.0)), 1.25), "resource view data exposes field identity, resource color and grade independently from terrain view data")
	var terrain_view := factory.tile_view_snapshot(world, Vector2i(130, 135), "TERRAIN")
	var resource_view := factory.tile_view_snapshot(world, Vector2i(130, 135), "RESOURCE")
	_check(terrain_view.get("display_color", "") == mineral_tile.get("terrain_color", "") and resource_view.get("display_color", "") == mineral_tile.get("resource_color", "") and resource_view.get("display_value", "") == "iron_ore", "terrain and resource view modes project independent colors from the same authoritative tile")
	var normalized := factory.normalize_world(world)
	_check(factory.tile_snapshot(normalized, Vector2i(130, 135)).get("resource_field_id", "") == "iron-field-a", "normalization preserves fixed resource-tile coordinates")
	var legacy_world := factory.create_world("legacy", "earth_orbit", Vector2i(256, 256), 1)
	legacy_world["schema_version"] = 1
	legacy_world.erase("resource_fields")
	legacy_world["entities"]["legacy-iron"] = {"id":"legacy-iron", "kind":"DEPOSIT", "resource_id":"iron_ore", "resource_category":"solid", "footprint":{"origin":{"x":32, "y":32}, "size":{"x":3, "y":3}}, "grade":1.0, "potential_density":1.0}
	var migrated := factory.normalize_world(legacy_world)
	_check(int(migrated.get("schema_version", 0)) == 3 and migrated.get("resource_fields", {}).has("legacy-iron") and not migrated.get("entities", {}).has("legacy-iron"), "World Schema 1 deposit entities migrate into the Schema 3 tile resource layer")


func _test_world_profile_contracts() -> void:
	var expected := {
		"earth_orbit":Vector2i(256, 160),
		"lunar_space":Vector2i(384, 240),
		"asteroid_belt":Vector2i(384, 240),
		"gas_giant_region":Vector2i(768, 480),
		"outer_system":Vector2i(512, 320),
		"deep_system":Vector2i(768, 480),
		"earth_sun_lagrange":Vector2i(384, 240),
		"inner_solar_orbit":Vector2i(512, 320)
	}
	var profiles: Dictionary = database.factory_grid_rules.get("world_profiles", {})
	var max_size_data: Dictionary = database.factory_grid_rules.get("max_world_size_tiles", {})
	var max_size := Vector2i(int(max_size_data.get("x", 0)), int(max_size_data.get("y", 0)))
	_check(max_size == Vector2i(768, 480), "Factory content defines one finite maximum canvas size")
	_check(profiles.size() == database.regions.size(), "every Location has exactly one finite factory world profile")
	for location_id_value in expected.keys():
		var location_id := str(location_id_value)
		var profile: Dictionary = profiles.get(location_id, {})
		var size_data: Dictionary = profile.get("size_tiles", {})
		var actual_size := Vector2i(int(size_data.get("x", 0)), int(size_data.get("y", 0)))
		_check(actual_size == expected[location_id] and actual_size.x > 0 and actual_size.y > 0 and actual_size.x <= max_size.x and actual_size.y <= max_size.y, "%s uses its designed finite canvas within the authored maximum" % location_id)
	var earth_world := factory.create_world("earth-partial-chunk", "earth_orbit", expected["earth_orbit"], 1)
	_check(
		factory.chunk_coordinate(earth_world, Vector2i(255, 159)) == Vector2i(3, 2)
		and factory.chunk_local_coordinate(earth_world, Vector2i(255, 159)) == Vector2i(63, 31)
		and bool(factory.tile_snapshot(earth_world, Vector2i(255, 159)).get("valid", false))
		and not bool(factory.tile_snapshot(earth_world, Vector2i(256, 159)).get("valid", true)),
		"Earth keeps its partial final 64-tile chunk while enforcing the logical edge"
	)


func _test_resource_field_exclusion_and_coverage() -> void:
	var exclusion_world := factory.create_world("field-exclusion", "earth_orbit", Vector2i(128, 128), 41)
	_check(bool(factory.add_resource_field(exclusion_world, "iron", "iron_ore", Vector2i(32, 32), Vector2i(3, 3), 1.0, 10.0, "solid").get("ok", false)), "exclusion fixture registers its first resource field")
	var too_close := factory.add_resource_field(exclusion_world, "copper-close", "copper_ore", Vector2i(36, 32), Vector2i(3, 3), 1.0, 10.0, "solid")
	_check(not bool(too_close.get("ok", true)) and str(too_close.get("reason_code", "")) == "RESOURCE_FIELD_EXCLUSION", "different resource fields are rejected when one 3x3 miner could touch both")
	_check(bool(factory.add_resource_field(exclusion_world, "copper-safe", "copper_ore", Vector2i(37, 32), Vector2i(3, 3), 1.0, 10.0, "solid").get("ok", false)), "different resources are allowed once no available miner footprint can cover both")

	var coverage_world := factory.create_world("coverage", "earth_orbit", Vector2i(128, 128), 42)
	factory.add_resource_field(coverage_world, "iron", "iron_ore", Vector2i(32, 32), Vector2i(3, 3), 1.0, 10.0, "solid")
	factory.place_entity_immediate(coverage_world, "grid_solar_array", Vector2i(0, 0), "", "power")
	var placed := factory.place_entity_immediate(coverage_world, "grid_surface_mine", Vector2i(32, 32), "", "mine")
	_check(bool(placed.get("ok", false)) and is_equal_approx(float(coverage_world["entities"]["mine"].get("coverage_efficiency", 0.0)), 1.0), "a 3x3 miner covering nine matching resource tiles starts at 100% efficiency")
	coverage_world["tile_deltas"]["34:34"] = {"resource_cleared":true}
	factory.connect_entities(coverage_world, "POWER", "power", "mine")
	factory.advance_world(coverage_world, 1000.0)
	var mine: Dictionary = coverage_world["entities"]["mine"]
	_check(int(mine.get("covered_resource_tiles", 0)) == 8 and int(mine.get("missing_resource_tiles", 0)) == 1 and is_equal_approx(float(mine.get("coverage_efficiency", 0.0)), 0.9), "one missing resource tile lowers 3x3 mining efficiency from 100% to 90%")
	_check(absf(float(mine.get("actual_rate", 0.0)) - 3.6) < 0.0001, "coverage efficiency directly scales physical extraction throughput")


func _test_placement_and_port_contracts() -> void:
	var world := factory.create_world("placement", "earth_orbit", Vector2i(256, 256), 42)
	_check(bool(factory.add_resource_field(world, "iron-field", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid").get("ok", false)), "placement fixture has a resource field")
	var blocked_machine := factory.place_entity_immediate(world, "grid_arc_smelter", Vector2i(34, 34), "grid_refine_iron")
	_check(bool(blocked_machine.get("ok", false)) and str(factory.tile_snapshot(world, Vector2i(35, 35)).get("resource_id", "")) == "iron_ore", "non-extractor structures may cover but never erase the independent resource tile layer")
	world["entities"].erase(str(blocked_machine.get("entity_id", "")))
	var missing_resource := factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(80, 80))
	_check(not bool(missing_resource.get("ok", true)) and str(missing_resource.get("reason_code", "")) == "RESOURCE_REQUIRED", "extractors must physically overlap a compatible resource field")
	var mine := factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "mine")
	var power := factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power")
	var smelter := factory.place_entity_immediate(world, "grid_arc_smelter", Vector2i(72, 32), "grid_refine_iron", "smelter")
	var depot := factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(110, 32), "", "depot")
	_check(bool(mine.get("ok", false)) and bool(power.get("ok", false)) and bool(smelter.get("ok", false)) and bool(depot.get("ok", false)), "compatible macro facilities occupy explicit square-metre footprints")
	_check(not bool(factory.connect_entities(world, "RESOURCE", "iron-field", "mine").get("ok", true)), "resource tiles are read through footprint coverage and cannot become network links")
	_check(str(factory.connect_entities(world, "POWER", "mine", "power").get("reason_code", "")) == "INVALID_LINK", "power links reject a consumer-to-generator reverse edge at the Domain boundary")
	_check(str(factory.connect_entities(world, "POWER", "mine", "smelter").get("reason_code", "")) == "INVALID_LINK", "power links reject consumer-to-consumer edges")
	_check(str(factory.connect_entities(world, "POWER", "power", "depot").get("reason_code", "")) == "INVALID_LINK", "power links reject targets without a physical power-demand port")
	_check(bool(factory.connect_entities(world, "POWER", "power", "mine").get("ok", false)) and bool(factory.connect_entities(world, "POWER", "power", "smelter").get("ok", false)), "power links form an explicit local network")
	_check(str(factory.connect_entities(world, "power", "power", "mine", "bogus-item").get("reason_code", "")) == "DUPLICATE_LINK" and world.get("links", {}).size() == 2, "POWER duplicate detection canonicalizes link-kind casing and ignored item payload before writing topology")
	_check(bool(factory.connect_entities(world, "CARGO", "mine", "smelter", "iron_ore", 8.0).get("ok", false)), "cargo link accepts a compatible item route")
	var second_input := factory.connect_entities(world, "CARGO", "depot", "smelter", "iron_ore", 8.0)
	_check(not bool(second_input.get("ok", true)) and str(second_input.get("reason_code", "")) == "CARGO_INPUT_OCCUPIED", "ordinary item input ports cannot silently fan in and bypass a merger")


func _test_unconfigured_machine_contracts() -> void:
	var world := factory.create_world("unconfigured-machine", "earth_orbit", Vector2i(128, 128), 43)
	var machine := factory.place_entity_immediate(world, "grid_engineering_works", Vector2i(0, 0), "", "unconfigured")
	var entity: Dictionary = world.get("entities", {}).get("unconfigured", {})
	_check(bool(machine.get("ok", false)) and str(entity.get("recipe_id", "")) == "" and str(entity.get("status", "")) == "NO_RECIPE" and is_zero_approx(float(entity.get("actual_rate", -1.0))), "a MACHINE can be placed without a recipe and is immediately authoritative NO_RECIPE at zero rate")

	var snapshot_entity: Dictionary = {}
	for entity_value in factory.workspace_snapshot(world).get("entities", []):
		var candidate := entity_value as Dictionary
		if str(candidate.get("id", "")) == "unconfigured":
			snapshot_entity = candidate
			break
	var cargo_port_count := 0
	var ports: Dictionary = snapshot_entity.get("ports", {})
	for port_value in ports.get("input_ports", []):
		if str((port_value as Dictionary).get("channel", "")) == "ITEM":
			cargo_port_count += 1
	for port_value in ports.get("output_ports", []):
		if str((port_value as Dictionary).get("channel", "")) == "ITEM":
			cargo_port_count += 1
	_check(str(snapshot_entity.get("status", "")) == "NO_RECIPE" and is_zero_approx(float(snapshot_entity.get("actual_rate", -1.0))) and cargo_port_count == 0, "an unconfigured MACHINE snapshot exposes NO_RECIPE, zero production rate and no cargo input/output ports")

	var source := factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(30, 0), "", "source")
	var cargo := factory.connect_entities(world, "CARGO", "source", "unconfigured", "iron_ingot", 1.0)
	_check(bool(source.get("ok", false)) and not bool(cargo.get("ok", true)) and str(cargo.get("reason_code", "")) == "CARGO_INCOMPATIBLE", "an unconfigured MACHINE cannot accept cargo before a recipe creates item ports")

	var queued := factory.queue_construction(world, "grid_engineering_works", Vector2i(60, 0), "")
	var order_id := str(queued.get("order_id", ""))
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	if bool(queued.get("ok", false)) and not order.is_empty():
		order["delivered_items"] = order.get("required_items", {}).duplicate(true)
	factory.advance_world(world, 20_000.0)
	var completed: Dictionary = world.get("entities", {}).get(str(queued.get("entity_id", "")), {})
	_check(bool(queued.get("ok", false)) and not completed.is_empty() and str(completed.get("recipe_id", "")) == "" and str(completed.get("status", "")) == "NO_RECIPE" and is_zero_approx(float(completed.get("actual_rate", -1.0))), "a queued empty-recipe MACHINE completes while retaining NO_RECIPE and zero production rate")

	var incompatible_place := factory.place_entity_immediate(world, "grid_engineering_works", Vector2i(60, 30), "grid_refine_titanium")
	var incompatible_queue := factory.queue_construction(world, "grid_engineering_works", Vector2i(60, 45), "grid_refine_titanium")
	_check(not bool(incompatible_place.get("ok", true)) and str(incompatible_place.get("reason_code", "")) == "INCOMPATIBLE_RECIPE" and not bool(incompatible_queue.get("ok", true)) and str(incompatible_queue.get("reason_code", "")) == "INCOMPATIBLE_RECIPE", "non-empty recipes remain required to exist and be compatible for both immediate placement and queued construction")


func _test_mining_production_power_and_conservation() -> void:
	var world := _working_factory(true)
	var report := factory.advance_world(world, 60_000.0)
	var mine: Dictionary = world["entities"]["mine"]
	var smelter: Dictionary = world["entities"]["smelter"]
	var depot: Dictionary = world["entities"]["depot"]
	var expected_power := 100.0 / 130.0
	_check(int(report.get("steps", 0)) == 60, "one-minute simulation uses deterministic one-second factory steps")
	_check(absf(float(mine.get("power_factor", 0.0)) - expected_power) < 0.0001 and absf(float(smelter.get("power_factor", 0.0)) - expected_power) < 0.0001, "brownout proportionally throttles every consumer on the shared power network")
	_check(int(depot.get("inventory", {}).get("iron_ingot", 0)) > 10, "fixed deposit, mine, belt, smelter and storage form a productive vertical slice")
	var produced_ore := int(world.get("statistics", {}).get("produced", {}).get("iron_ore", 0))
	var consumed_ore := int(world.get("statistics", {}).get("consumed", {}).get("iron_ore", 0))
	var remaining_ore := int(mine.get("outputs", {}).get("iron_ore", 0)) + int(smelter.get("inputs", {}).get("iron_ore", 0))
	_check(produced_ore == consumed_ore + remaining_ore, "ore is conserved across extraction buffers, transfer and recipe consumption")
	var produced_ingots := int(world.get("statistics", {}).get("produced", {}).get("iron_ingot", 0))
	var remaining_ingots := int(smelter.get("outputs", {}).get("iron_ingot", 0)) + int(depot.get("inventory", {}).get("iron_ingot", 0))
	_check(produced_ingots == remaining_ingots, "manufactured output is conserved across machine and storage buffers")


func _test_fair_and_priority_routing() -> void:
	var fair_world := factory.create_world("fair-routing", "earth_orbit", Vector2i(256, 256), 7)
	factory.place_entity_immediate(fair_world, "grid_bulk_depot", Vector2i(0, 0), "", "source")
	factory.place_entity_immediate(fair_world, "grid_bulk_depot", Vector2i(40, 0), "", "target-a")
	factory.place_entity_immediate(fair_world, "grid_bulk_depot", Vector2i(80, 0), "", "target-b")
	fair_world["entities"]["source"]["inventory"]["iron_ingot"] = 12
	factory.connect_entities(fair_world, "CARGO", "source", "target-a", "iron_ingot", 10.0, 1)
	factory.connect_entities(fair_world, "CARGO", "source", "target-b", "iron_ingot", 10.0, 1)
	factory.advance_world(fair_world, 1000.0)
	_check(int(fair_world["entities"]["target-a"]["inventory"].get("iron_ingot", 0)) == 6 and int(fair_world["entities"]["target-b"]["inventory"].get("iron_ingot", 0)) == 6, "equal-priority outputs share a source snapshot fairly instead of depending on link array order")

	var priority_world := factory.create_world("priority-routing", "earth_orbit", Vector2i(256, 256), 8)
	factory.place_entity_immediate(priority_world, "grid_bulk_depot", Vector2i(0, 0), "", "source")
	factory.place_entity_immediate(priority_world, "grid_bulk_depot", Vector2i(40, 0), "", "high")
	factory.place_entity_immediate(priority_world, "grid_bulk_depot", Vector2i(80, 0), "", "low")
	priority_world["entities"]["source"]["inventory"]["iron_ingot"] = 10
	factory.connect_entities(priority_world, "CARGO", "source", "low", "iron_ingot", 10.0, 0)
	factory.connect_entities(priority_world, "CARGO", "source", "high", "iron_ingot", 10.0, 2)
	factory.advance_world(priority_world, 1000.0)
	_check(int(priority_world["entities"]["high"]["inventory"].get("iron_ingot", 0)) == 10 and int(priority_world["entities"]["low"]["inventory"].get("iron_ingot", 0)) == 0, "high-priority cargo is satisfied before lower-priority routes")


func _test_transport_capacity_does_not_bank() -> void:
	var world := factory.create_world("non-banking-capacity", "earth_orbit", Vector2i(128, 128), 9)
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 0), "", "source")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(40, 0), "", "target")
	var connected := factory.connect_entities(world, "CARGO", "source", "target", "iron_ingot", 2.0, 1)
	_check(bool(connected.get("ok", false)), "capacity fixture creates a two-item-per-second cargo link")
	factory.advance_world(world, 10_000.0)
	world["entities"]["source"]["inventory"]["iron_ingot"] = 10
	factory.advance_world(world, 1000.0)
	_check(int(world["entities"]["target"]["inventory"].get("iron_ingot", 0)) == 2, "an idle cargo link cannot bank unused capacity for a later burst")


func _test_resource_potential_caps_high_grade_extraction() -> void:
	var world := factory.create_world("potential-cap", "earth_orbit", Vector2i(128, 128), 10)
	factory.add_resource_field(world, "rich-small-field", "iron_ore", Vector2i(32, 32), Vector2i(3, 3), 2.0, 0.01, "solid")
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power")
	factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(32, 32), "", "mine")
	factory.connect_entities(world, "POWER", "power", "mine")
	factory.advance_world(world, 1000.0)
	_check(absf(float(world["entities"]["mine"].get("actual_rate", 0.0)) - 0.09) < 0.0001, "covered tiles' sustainable potential remains a hard cap after grade and power modifiers")


func _test_backpressure_and_recovery() -> void:
	var world := _working_factory(false)
	factory.advance_world(world, 300_000.0)
	_check(str(world["entities"]["smelter"].get("status", "")) == "OUTPUT_FULL" and str(world["entities"]["mine"].get("status", "")) == "OUTPUT_FULL", "downstream output blockage propagates upstream without deleting resources")
	var depot_result := factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(110, 32), "", "depot")
	_check(bool(depot_result.get("ok", false)), "storage can be added after a blocked line")
	_check(bool(factory.connect_entities(world, "CARGO", "smelter", "depot", "iron_ingot", 4.0).get("ok", false)), "new output route connects to blocked production")
	factory.advance_world(world, 60_000.0)
	_check(int(world["entities"]["depot"].get("inventory", {}).get("iron_ingot", 0)) > 0, "free output space automatically resumes the line")
	_check(str(world["entities"]["mine"].get("status", "")) in ["RUNNING", "POWER_LIMITED"], "backpressure clears all the way to extraction")


func _test_empty_construction_funding_is_rejected() -> void:
	var world := factory.create_world("empty-construction-funding", "earth_orbit", Vector2i(128, 128), 16)
	_check(bool(factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(0, 0), "", "empty-depot").get("ok", false)), "empty-funding fixture creates an operational storage entity")
	var queued := factory.queue_construction(world, "grid_bulk_depot", Vector2i(40, 0))
	_check(bool(queued.get("ok", false)), "empty-funding fixture creates a material-backed construction order")
	var runtime_revision_before := int(world.get("runtime_revision", 0))
	var funded := factory.fund_construction_from_storage(world, str(queued.get("order_id", "")), "empty-depot")
	var order := world.get("construction_orders", {}).get(str(queued.get("order_id", "")), {}) as Dictionary
	_check(not bool(funded.get("ok", true)) and str(funded.get("reason_code", "")) == "INPUT_SHORTAGE", "an empty storage does not report a successful construction delivery")
	_check(order.get("delivered_items", {}).is_empty() and int(world.get("runtime_revision", 0)) == runtime_revision_before, "rejected empty construction funding leaves the order and runtime revision unchanged")


func _test_production_funds_real_construction() -> void:
	var world := _working_factory(true)
	factory.advance_world(world, 60_000.0)
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.factory_worlds["construction-grid"] = world
	var queued := factory.queue_construction(world, "grid_bulk_depot", Vector2i(150, 32), "", 70)
	_check(bool(queued.get("ok", false)), "a macro storage footprint enters the construction queue instead of appearing instantly")
	var order_id := str(queued.get("order_id", ""))
	var entity_id := str(queued.get("entity_id", ""))
	var before := int(world["entities"]["depot"].get("inventory", {}).get("iron_ingot", 0))
	var owned_before_delivery := int(state.factory_world_item_holdings().get("iron_ingot", 0))
	var consumed_before_delivery := int(world.get("statistics", {}).get("consumed", {}).get("iron_ingot", 0))
	var funded := factory.fund_construction_from_storage(world, order_id, "depot")
	_check(bool(funded.get("ok", false)) and bool(funded.get("fully_funded", false)), "construction is funded with manufactured items from a physical storage entity")
	_check(int(world["entities"]["depot"].get("inventory", {}).get("iron_ingot", 0)) == before - 10, "construction delivery removes exactly the declared bill of materials")
	var funded_ledger := state.asset_ledger_snapshot().get("FactoryWorld", {}) as Dictionary
	_check(int(state.factory_world_item_holdings().get("iron_ingot", 0)) == owned_before_delivery, "construction delivery changes custody without deleting physical material")
	_check(int(funded_ledger.get("ConstructionStaging", {}).get("iron_ingot", 0)) == 10 and int(funded_ledger.get("EntityBuffers", {}).get("iron_ingot", 0)) == owned_before_delivery - 10, "factory asset ledger separates entity buffers from construction staging")
	_check(int(world.get("statistics", {}).get("consumed", {}).get("iron_ingot", 0)) == consumed_before_delivery, "delivery is not reported as material consumption before construction completes")
	var produced_before_completion := int(world.get("statistics", {}).get("produced", {}).get("iron_ingot", 0))
	var report := factory.advance_world(world, 30_000.0)
	_check(world.get("entities", {}).has(entity_id) and not world.get("construction_orders", {}).has(order_id), "funded construction work completes into a persistent factory entity")
	var produced_during_completion := int(world.get("statistics", {}).get("produced", {}).get("iron_ingot", 0)) - produced_before_completion
	_check(int(world.get("statistics", {}).get("consumed", {}).get("iron_ingot", 0)) == consumed_before_delivery + 10, "completed construction records its staged bill of materials as consumed exactly once")
	_check(int(state.factory_world_item_holdings().get("iron_ingot", 0)) == owned_before_delivery - 10 + produced_during_completion and int(state.factory_world_item_ledger().get("ConstructionStaging", {}).get("iron_ingot", 0)) == 0, "factory holdings reconcile construction consumption with concurrent production")
	_check(report.get("events", []).any(func(event): return str((event as Dictionary).get("type", "")) == "FactoryConstructionCompleted" and str((event as Dictionary).get("entity_id", "")) == entity_id), "construction completion emits a structured domain event")


func _test_save_round_trip() -> void:
	var world := _working_factory(true)
	factory.advance_world(world, 10_000.0)
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.factory_worlds["earth-grid"] = world
	var payload := state.to_dictionary()
	var json_text := JSON.stringify(payload)
	var parsed = JSON.parse_string(json_text)
	_check(parsed is Dictionary, "schema-36 grid world contains only JSON-safe persistent values")
	if parsed is not Dictionary:
		return
	var restored := SpaceGameState.from_dictionary(parsed, database.domains.keys(), database.regions)
	_check(restored.factory_worlds.has("earth-grid"), "grid world survives the authoritative save round trip")
	var restored_world: Dictionary = restored.factory_worlds.get("earth-grid", {})
	_check(restored_world.get("entities", {}).keys().size() == world.get("entities", {}).keys().size() and restored_world.get("links", {}).keys().size() == world.get("links", {}).keys().size(), "entity and link topology survives save normalization")
	_check(int(restored_world.get("entities", {}).get("depot", {}).get("inventory", {}).get("iron_ingot", 0)) == int(world.get("entities", {}).get("depot", {}).get("inventory", {}).get("iron_ingot", 0)), "physical factory inventory survives without becoming Location Inventory")


func _test_simulation_engine_integration() -> void:
	var world := _working_factory(true)
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.factory_worlds["earth-grid"] = world
	var simulation := SimulationEngine.new(database)
	var report := simulation.advance(state, 5000.0)
	_check(is_equal_approx(float(state.factory_worlds["earth-grid"].get("elapsed_ms", 0.0)), 5000.0), "main SimulationEngine advances every active factory world through the shared time authority")
	_check(int(state.factory_worlds["earth-grid"].get("statistics", {}).get("produced", {}).get("iron_ore", 0)) > 0, "factory production participates in ordinary online/offline simulation advancement")
	_check(is_equal_approx(float(report.get("simulated_ms", 0.0)), 5000.0), "factory integration does not retain or discard requested simulation time")


func _test_new_game_factory_bootstrap() -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var scrap_before := state.item_quantity("scrap_metal", "earth_orbit")
	var electronics_before := state.item_quantity("electronics", "earth_orbit")
	var simulation := SimulationEngine.new(database)
	simulation.ensure_frontier_state(state)
	var world: Dictionary = state.factory_worlds.get("earth-surface-grid", {})
	var depot: Dictionary = world.get("entities", {}).get("starter-depot", {})
	var earth_bounds: Dictionary = world.get("bounds", {}).get("size", {})
	var earth_size := Vector2i(int(earth_bounds.get("x", 0)), int(earth_bounds.get("y", 0)))
	var solar_size := Vector2i(8, 8)
	var exact_edge := earth_size - solar_size
	_check(not world.is_empty() and earth_size == Vector2i(256, 160), "new saves bootstrap the smaller finite Earth factory world")
	_check(bool(simulation.factory_grid.can_place_entity(world, "grid_solar_array", exact_edge).get("ok", false)) and str(simulation.factory_grid.can_place_entity(world, "grid_solar_array", exact_edge + Vector2i.RIGHT).get("reason_code", "")) == "OUT_OF_BOUNDS", "Earth bounds accept an exact-edge footprint and reject a footprint one tile beyond it")
	_check(str(world.get("resource_fields", {}).get("starter-iron-field", {}).get("resource_id", "")) == "iron_ore" and not world.get("entities", {}).has("starter-iron-field"), "new factory bootstrap stores the starter iron field outside the entity registry")
	_check(int(depot.get("inventory", {}).get("scrap_metal", 0)) == scrap_before and int(depot.get("inventory", {}).get("electronics", 0)) == electronics_before, "founding industrial cargo moves into the starter entity depot")
	_check(state.item_quantity("scrap_metal", "earth_orbit") == 0 and state.item_quantity("electronics", "earth_orbit") == 0, "starter cargo is moved rather than duplicated in Location Inventory")


func _test_factory_bound_force_crop() -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var simulation := SimulationEngine.new(database)
	var legacy_world := simulation.factory_grid.create_world("earth-surface-grid", "earth_orbit", Vector2i(20_000_000, 20_000_000), 730201)
	var inside_power: Dictionary = simulation.factory_grid.place_entity_immediate(legacy_world, "grid_solar_array", Vector2i(64, 64), "", "inside-power")
	var inside_field: Dictionary = simulation.factory_grid.add_resource_field(legacy_world, "inside-field", "iron_ore", Vector2i(128, 128), Vector2i(24, 24), 1.0, 0.25, "solid")
	var inside_mine: Dictionary = simulation.factory_grid.place_entity_immediate(legacy_world, "grid_surface_mine", Vector2i(128, 128), "", "inside-mine")
	var inside_link: Dictionary = simulation.factory_grid.connect_entities(legacy_world, "POWER", "inside-power", "inside-mine")
	legacy_world["links"][str(inside_link.get("link_id", ""))]["path_tiles"] = [{"x":68,"y":71}, {"x":300,"y":71}, {"x":300,"y":128}, {"x":129,"y":128}]
	var inside_order: Dictionary = simulation.factory_grid.queue_construction(legacy_world, "grid_solar_array", Vector2i(200, 120))
	var far_power: Dictionary = simulation.factory_grid.place_entity_immediate(legacy_world, "grid_solar_array", Vector2i(1000, 400), "", "far-power")
	var orphan_machine: Dictionary = simulation.factory_grid.place_entity_immediate(legacy_world, "grid_arc_smelter", Vector2i(220, 128), "grid_refine_iron", "orphan-machine")
	var field_result: Dictionary = simulation.factory_grid.add_resource_field(legacy_world, "legacy-far-field", "iron_ore", Vector2i(1500, 700), Vector2i(24, 24), 1.0, 0.25, "solid")
	var mine_result: Dictionary = simulation.factory_grid.place_entity_immediate(legacy_world, "grid_surface_mine", Vector2i(1500, 700), "", "legacy-far-mine")
	var far_link: Dictionary = simulation.factory_grid.connect_entities(legacy_world, "POWER", "far-power", "legacy-far-mine")
	var cross_link: Dictionary = simulation.factory_grid.connect_entities(legacy_world, "POWER", "inside-power", "legacy-far-mine")
	var orphan_link: Dictionary = simulation.factory_grid.connect_entities(legacy_world, "POWER", "far-power", "orphan-machine")
	var order_result: Dictionary = simulation.factory_grid.queue_construction(legacy_world, "grid_solar_array", Vector2i(2000, 800))
	var partial_entity: Dictionary = simulation.factory_grid.place_entity_immediate(legacy_world, "grid_solar_array", Vector2i(252, 156), "", "partial-power")
	var partial_field: Dictionary = simulation.factory_grid.add_resource_field(legacy_world, "partial-field", "iron_ore", Vector2i(248, 150), Vector2i(24, 24), 1.0, 0.25, "solid")
	var partial_order: Dictionary = simulation.factory_grid.queue_construction(legacy_world, "grid_solar_array", Vector2i(240, 156))
	legacy_world["tile_deltas"]["100:100"] = {"terrain_override":"PLAIN"}
	legacy_world["tile_deltas"]["2500:900"] = {"terrain_override":"PLAIN"}
	legacy_world["tile_deltas"]["malformed"] = {"terrain_override":"PLAIN"}
	legacy_world["revealed_chunks"]["0:0"] = true
	legacy_world["revealed_chunks"]["100:100"] = true
	legacy_world["revealed_chunks"]["malformed"] = true
	legacy_world["command_receipts"]["legacy-command"] = {"accepted":true, "command_kind":"QUEUE_CONSTRUCTION", "message_key":"factory.success.queue_construction"}
	legacy_world["command_receipt_order"].append("legacy-command")
	legacy_world["entities"]["far-power"]["inventory"]["scrap_metal"] = 3
	legacy_world["entities"]["legacy-far-mine"]["outputs"]["iron_ore"] = 4
	var far_order_id := str(order_result.get("order_id", ""))
	legacy_world["construction_orders"][far_order_id]["delivered_items"]["scrap_metal"] = 2
	_check(bool(inside_power.get("ok", false)) and bool(inside_field.get("ok", false)) and bool(inside_mine.get("ok", false)) and bool(inside_link.get("ok", false)) and bool(inside_order.get("ok", false)), "force-crop fixture contains valid in-bounds factory data")
	_check(bool(far_power.get("ok", false)) and bool(orphan_machine.get("ok", false)) and bool(field_result.get("ok", false)) and bool(mine_result.get("ok", false)) and bool(far_link.get("ok", false)) and bool(cross_link.get("ok", false)) and bool(orphan_link.get("ok", false)) and bool(order_result.get("ok", false)) and bool(partial_entity.get("ok", false)) and bool(partial_field.get("ok", false)) and bool(partial_order.get("ok", false)), "force-crop fixture covers fully and partially out-of-bounds records")
	simulation.factory_grid.refresh_derived_state(legacy_world)
	_check(float(legacy_world.get("entities", {}).get("orphan-machine", {}).get("power_factor", 0.0)) > 0.0, "force-crop fixture starts with a retained machine powered only by an out-of-bounds generator")
	var topology_before := int(legacy_world.get("topology_revision", 0))
	var runtime_before := int(legacy_world.get("runtime_revision", 0))
	var statistics_before: Dictionary = legacy_world.get("statistics", {}).duplicate(true)
	var location_scrap_before := state.item_quantity("scrap_metal", "earth_orbit")
	var location_iron_before := state.item_quantity("iron_ore", "earth_orbit")
	state.factory_worlds["earth-surface-grid"] = legacy_world
	simulation.ensure_frontier_state(state)
	var migrated: Dictionary = state.factory_worlds.get("earth-surface-grid", {})
	var migrated_size_data: Dictionary = migrated.get("bounds", {}).get("size", {})
	var migrated_size := Vector2i(int(migrated_size_data.get("x", 0)), int(migrated_size_data.get("y", 0)))
	_check(migrated_size == Vector2i(256, 160), "legacy 20M Earth bounds are force-cropped to the authored Location profile")
	_check(migrated.get("resource_fields", {}).keys() == ["inside-field"] and migrated.get("entities", {}).has("inside-power") and migrated.get("entities", {}).has("inside-mine") and migrated.get("entities", {}).has("orphan-machine") and migrated.get("entities", {}).size() == 3 and migrated.get("construction_orders", {}).size() == 1, "force crop retains only records whose complete footprints fit the new bounds")
	_check(migrated.get("links", {}).size() == 1 and migrated.get("links", {}).values().all(func(link): return migrated.get("entities", {}).has(str((link as Dictionary).get("source_id", ""))) and migrated.get("entities", {}).has(str((link as Dictionary).get("target_id", "")))), "force crop removes every link with a discarded endpoint")
	_check((migrated.get("links", {}).values()[0] as Dictionary).get("path_tiles", []).all(func(tile): return int((tile as Dictionary).get("x", -1)) >= 0 and int((tile as Dictionary).get("x", 256)) < 256 and int((tile as Dictionary).get("y", -1)) >= 0 and int((tile as Dictionary).get("y", 160)) < 160), "force crop rebuilds surviving authored route detours inside the new planet boundary")
	_check(is_zero_approx(float(migrated.get("entities", {}).get("orphan-machine", {}).get("power_factor", -1.0))) and str(migrated.get("entities", {}).get("orphan-machine", {}).get("status", "")) == "NO_POWER", "force crop immediately refreshes surviving runtime state after removing a power provider")
	_check(migrated.get("tile_deltas", {}).keys() == ["100:100"] and migrated.get("revealed_chunks", {}).keys() == ["0:0"], "force crop retains in-bounds survey revelation while discarding out-of-bounds tile and chunk data")
	_check(migrated.get("command_receipts", {}).has("legacy-command") and migrated.get("command_receipt_order", []) == ["legacy-command"] and migrated.get("statistics", {}) == statistics_before, "force crop preserves durable command idempotency and historical statistics")
	_check(state.item_quantity("scrap_metal", "earth_orbit") == location_scrap_before and state.item_quantity("iron_ore", "earth_orbit") == location_iron_before, "force crop intentionally discards old out-of-bounds buffers and staged materials without save-migration refunds")
	_check(int(migrated.get("topology_revision", 0)) == topology_before + 1 and int(migrated.get("runtime_revision", 0)) == runtime_before + 1, "force crop bumps topology and runtime revisions exactly once when runtime records are discarded")
	var migrated_revision := int(migrated.get("topology_revision", 0))
	var migrated_runtime_revision := int(migrated.get("runtime_revision", 0))
	simulation.ensure_frontier_state(state)
	_check(int(migrated.get("topology_revision", 0)) == migrated_revision and int(migrated.get("runtime_revision", 0)) == migrated_runtime_revision and Vector2i(int(migrated.get("bounds", {}).get("size", {}).get("x", 0)), int(migrated.get("bounds", {}).get("size", {}).get("y", 0))) == migrated_size, "factory force crop is idempotent after the first enforcement")
	var restored := SpaceGameState.from_dictionary(JSON.parse_string(JSON.stringify(state.to_dictionary())), database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(restored)
	var restored_world: Dictionary = restored.factory_worlds.get("earth-surface-grid", {})
	_check(Vector2i(int(restored_world.get("bounds", {}).get("size", {}).get("x", 0)), int(restored_world.get("bounds", {}).get("size", {}).get("y", 0))) == migrated_size and int(restored_world.get("topology_revision", 0)) == migrated_revision and int(restored_world.get("runtime_revision", 0)) == migrated_runtime_revision and not restored_world.get("entities", {}).has("far-power"), "force-cropped records do not revive or bump revisions across save reload")
	var alias_state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	alias_state.factory_worlds["earth-orbit-grid"] = simulation.factory_grid.create_world("earth-orbit-grid", "earth_orbit", Vector2i(20_000_000, 20_000_000), 730201)
	simulation.ensure_frontier_state(alias_state)
	var alias_world: Dictionary = alias_state.factory_worlds.get("earth-orbit-grid", {})
	var alias_size: Dictionary = alias_world.get("bounds", {}).get("size", {})
	_check(alias_state.factory_worlds.size() == 1 and not alias_state.factory_worlds.has("earth-surface-grid") and Vector2i(int(alias_size.get("x", 0)), int(alias_size.get("y", 0))) == Vector2i(256, 160) and int(alias_world.get("topology_revision", 0)) == 1 and int(alias_world.get("runtime_revision", 0)) == 0, "empty legacy Earth world is force-cropped with one topology revision and no false runtime revision")
	var restored_alias_state := SpaceGameState.from_dictionary(JSON.parse_string(JSON.stringify(alias_state.to_dictionary())), database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(restored_alias_state)
	var restored_alias_world: Dictionary = restored_alias_state.factory_worlds.get("earth-orbit-grid", {})
	_check(Vector2i(int(restored_alias_world.get("bounds", {}).get("size", {}).get("x", 0)), int(restored_alias_world.get("bounds", {}).get("size", {}).get("y", 0))) == Vector2i(256, 160) and int(restored_alias_world.get("topology_revision", 0)) == int(alias_world.get("topology_revision", -1)), "legacy Earth alias force crop remains idempotent across save reload")
	var custom_state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var custom_world := simulation.factory_grid.create_world("custom-earth-grid", "earth_orbit", Vector2i(768, 512), 730201)
	custom_world["bounds"]["origin"] = {"x":100, "y":200}
	simulation.factory_grid.place_entity_immediate(custom_world, "grid_solar_array", Vector2i(348, 352), "", "custom-edge-power")
	simulation.factory_grid.place_entity_immediate(custom_world, "grid_solar_array", Vector2i(400, 400), "", "custom-far-power")
	custom_state.factory_worlds["custom-earth-grid"] = custom_world
	simulation.ensure_frontier_state(custom_state)
	var custom_cropped: Dictionary = custom_state.factory_worlds.get("custom-earth-grid", {})
	var custom_size: Dictionary = custom_cropped.get("bounds", {}).get("size", {})
	_check(Vector2i(int(custom_size.get("x", 0)), int(custom_size.get("y", 0))) == Vector2i(256, 160) and custom_cropped.get("entities", {}).has("custom-edge-power") and not custom_cropped.get("entities", {}).has("custom-far-power"), "custom world IDs and non-zero origins obey the Location profile while retaining an exact-edge footprint")
	var undersized_state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var undersized_world := simulation.factory_grid.create_world("undersized-earth-grid", "earth_orbit", Vector2i(192, 128), 730201)
	undersized_state.factory_worlds["undersized-earth-grid"] = undersized_world
	var undersized_before: Dictionary = undersized_world.duplicate(true)
	simulation.ensure_frontier_state(undersized_state)
	undersized_before["environment"] = simulation.location_environment(undersized_state, "earth_orbit").duplicate(true)
	_check(undersized_state.factory_worlds.get("undersized-earth-grid", {}) == undersized_before, "undersized worlds retain their spatial state while adopting canonical Location environment")
	var reconciled_before: Dictionary = undersized_state.factory_worlds["undersized-earth-grid"].duplicate(true)
	simulation.ensure_frontier_state(undersized_state)
	_check(undersized_state.factory_worlds["undersized-earth-grid"] == reconciled_before, "reconciled undersized worlds remain byte-stable")
	var dirty_state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var dirty_world := simulation.factory_grid.create_world("dirty-profile-grid", "earth_orbit", Vector2i(1024, 640), 730201)
	simulation.factory_grid.place_entity_immediate(dirty_world, "grid_solar_array", Vector2i(700, 400), "", "hidden-power")
	dirty_world["tile_deltas"]["700:400"] = {"terrain_override":"PLAIN"}
	dirty_world["revealed_chunks"]["12:8"] = true
	dirty_world["bounds"]["size"] = {"x":256, "y":160}
	var dirty_topology_before := int(dirty_world.get("topology_revision", 0))
	dirty_state.factory_worlds["dirty-profile-grid"] = dirty_world
	simulation.ensure_frontier_state(dirty_state)
	var cleaned_world: Dictionary = dirty_state.factory_worlds.get("dirty-profile-grid", {})
	_check(cleaned_world.get("entities", {}).is_empty() and cleaned_world.get("tile_deltas", {}).is_empty() and cleaned_world.get("revealed_chunks", {}).is_empty() and int(cleaned_world.get("topology_revision", 0)) == dirty_topology_before + 1 and int(cleaned_world.get("runtime_revision", 0)) == 1, "profile-sized dirty saves still purge hidden out-of-bounds records exactly once")
	var cleaned_once: Dictionary = cleaned_world.duplicate(true)
	simulation.ensure_frontier_state(dirty_state)
	_check(cleaned_world == cleaned_once, "spatial cleanup is idempotent even when the world size did not need cropping")
	var unprofiled_state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	unprofiled_state.factory_worlds["unprofiled-grid"] = simulation.factory_grid.create_world("unprofiled-grid", "unknown_location", Vector2i(1024, 768), 730201)
	simulation.ensure_frontier_state(unprofiled_state)
	_check(unprofiled_state.factory_worlds.get("unprofiled-grid", {}).get("bounds", {}).get("size", {}) == {"x":768, "y":480}, "the global canvas maximum force-crops even an unprofiled legacy world")


func _test_application_command_boundary() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var earth_workspace: Dictionary = game.factory_workspace_snapshot("earth-surface-grid")
	var canvas_limit_data: Dictionary = earth_workspace.get("canvas_limits", {}).get("max_world_size_tiles", {})
	_check(Vector2i(int(canvas_limit_data.get("x", 0)), int(canvas_limit_data.get("y", 0))) == Vector2i(768, 480), "Factory workspace snapshot publishes the authored canvas limit without owning world bounds")
	_check(not game.initialize_factory_world("oversized-width-grid", "earth_orbit", Vector2i(257, 160), 123), "application boundary rejects a new world wider than the Location profile")
	_check(not game.initialize_factory_world("oversized-height-grid", "earth_orbit", Vector2i(256, 161), 123), "application boundary rejects a new world taller than the Location profile")
	_check(game.initialize_factory_world("command-grid", "earth_orbit", Vector2i(192, 128), 123), "Game command creates a factory world transactionally")
	_check(game.register_factory_resource_field("command-grid", "command-iron", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid"), "generator-facing Game command registers a tile resource field transactionally")
	_check(game.queue_factory_construction("command-grid", "grid_surface_mine", Vector2i(34, 34)), "player-facing Game command creates a construction order rather than an instant mine")
	var command_world: Dictionary = game.state.factory_worlds.get("command-grid", {})
	_check(command_world.get("construction_orders", {}).size() == 1 and command_world.get("entities", {}).is_empty() and command_world.get("resource_fields", {}).size() == 1, "application boundary persists the order while resource fields remain outside the entity registry")
	var snapshot: Dictionary = game.factory_tile_snapshot("command-grid", Vector2i(35, 35))
	_check(str(snapshot.get("resource_field_id", "")) == "command-iron", "UI query reads a terrain/resource projection without owning tile state")
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation = SimulationEngine.new(database)
	game.simulation.ensure_frontier_state(game.state)
	var expected_remote_sizes := {
		"lunar_space":Vector2i(384, 240),
		"asteroid_belt":Vector2i(384, 240),
		"gas_giant_region":Vector2i(768, 480),
		"outer_system":Vector2i(512, 320),
		"deep_system":Vector2i(768, 480),
		"earth_sun_lagrange":Vector2i(384, 240),
		"inner_solar_orbit":Vector2i(512, 320)
	}
	for location_id_value in expected_remote_sizes.keys():
		var location_id := str(location_id_value)
		game.state.location_state(location_id)["survey_state"] = LocationState.SURVEYED
		_check(game.initialize_surveyed_factory_world(location_id), "surveyed %s initializes its canonical finite factory world" % location_id)
		var profile: Dictionary = database.factory_grid_rules.get("world_profiles", {}).get(location_id, {})
		var remote_world: Dictionary = game.state.factory_worlds.get(str(profile.get("world_id", "")), {})
		var remote_size_data: Dictionary = remote_world.get("bounds", {}).get("size", {})
		var remote_size := Vector2i(int(remote_size_data.get("x", 0)), int(remote_size_data.get("y", 0)))
		_check(remote_size == expected_remote_sizes[location_id], "%s uses its location-specific factory bounds" % location_id)


func _test_removed_aggregate_runtime_cannot_restart() -> void:
	var seed := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var legacy := seed.to_dictionary()
	legacy["save_version"] = 35
	legacy["mining_operations"] = [{"slot":0, "domain":"mining", "status":"RUNNING", "activity_id":"legacy_ship_mining_activity", "assigned_ship_ids":[]}]
	legacy["industrial_operations"] = [{"slot":0, "domain":"industry", "status":"RUNNING", "activity_id":"smelt_iron", "reserved_costs":{"iron_ore":1}}]
	legacy["construction_operations"] = [{"slot":0, "domain":"construction", "status":"RUNNING", "activity_id":"build_orbital_foundry", "project_id":"CONSTRUCTION-OLD"}]
	legacy["extraction_network_states"] = {"earth_extraction_network":{"status":"RUNNING", "integrated_site_ids":["earth_resource_cluster_prospect"]}}
	legacy["mining_site_states"] = {"earth_resource_cluster_prospect":{"survey_state":LocationState.DEEP_SURVEYED, "developed":true, "mastery_level":9}}
	legacy["extraction_command"] = {"capacity":999}
	legacy["extraction_assets"] = {"ship_ids":[str(seed.ships[0].get("instance_id", ""))]}
	legacy["automation_rules"] = [{"rule_id":"AUTOMATION-OLD", "enabled":true, "action":{"type":"PAUSE_FACTORY", "slot":0}}]
	legacy["automation_audit"] = [{"rule_id":"AUTOMATION-OLD", "result":{"executed":true}}]
	legacy["background_economy"] = {"mining_sources":{"iron_ore":{"per_second":1.0}}}
	legacy["facilities"] = {"orbital_starport":{"level":1, "status":"ACTIVE"}, "orbital_foundry":{"level":3, "status":"ACTIVE"}, "fission_reactor":{"level":2, "status":"ACTIVE"}}
	legacy["manufacturing_module_inventory"] = {"precision_tooling":2}
	legacy["locations"]["earth_orbit"]["industry"]["industries"] = {"orbital_foundry":{"level":3, "production_method_id":"smelt_iron"}}
	legacy["ships"] = seed.ships.duplicate(true)
	legacy["ships"][0]["status"] = "EXTRACTION_OPERATION"
	legacy["ships"][0]["assignment"] = {"domain":"mining", "slot":0}
	var migrated := SpaceGameState.from_dictionary(legacy, database.domains.keys(), database.regions)
	var migrated_payload := migrated.to_dictionary()
	_check(not migrated_payload.has("mining_operations") and migrated.industrial_operations.is_empty() and migrated.construction_operations.is_empty() and not migrated_payload.has("extraction_network_states") and not migrated_payload.has("mining_site_states"), "schema-36 migration removes every aggregate mining, mining-site, production, construction and extraction-network runtime")
	_check(migrated.automation_rules.is_empty() and migrated.automation_audit.is_empty() and migrated.background_economy.get("mining_sources", {}).is_empty(), "legacy automation and background production cannot survive as a live side channel")
	_check(not migrated.facilities.has("orbital_foundry") and not migrated.facilities.has("fission_reactor") and migrated.facilities.has("orbital_starport") and migrated.location_industries("earth_orbit").is_empty(), "abstract manufacturing, power and location-industry ownership is removed while the independent Starport domain remains")
	_check(not migrated.retired_aggregate_industry_archive.get("industrial_operations", []).is_empty() and not migrated.retired_aggregate_industry_archive.get("automation_rules", []).is_empty() and not migrated.retired_aggregate_industry_archive.get("mining_site_states", {}).is_empty() and int(migrated.retired_aggregate_industry_archive.get("extraction_command", {}).get("capacity", 0)) == 999 and migrated.retired_aggregate_industry_archive.get("facilities", {}).has("orbital_foundry") and int(migrated.retired_aggregate_industry_archive.get("retired_in_schema", 0)) == 36, "removed aggregate runtime and facility metadata survive only as immutable migration evidence")
	_check(str(migrated.ships[0].get("status", "")) == "DOCKED" and migrated.ships[0].get("assignment", {}).is_empty(), "migration releases ships owned by removed extraction or construction runtimes")
	var persisted := migrated.to_dictionary()
	_check(not persisted.has("mining_operations") and not persisted.has("industrial_operations") and not persisted.has("construction_operations") and not persisted.has("extraction_network_states") and not persisted.has("mining_site_states") and not persisted.has("extraction_command") and not persisted.has("automation_rules") and not persisted.has("background_economy") and not persisted.has("manufacturing_module_inventory"), "current saves no longer serialize removed aggregate runtime fields")
	migrated.industrial_operations.append({"status":"RUNNING"})
	migrated.construction_operations.append({"status":"RUNNING"})
	migrated.automation_rules.append({"rule_id":"INJECTED"})
	migrated.background_economy["mining_sources"] = {"iron_ore":{"per_second":1.0}}
	migrated.facilities["orbital_foundry"] = {"level":99, "status":"ACTIVE"}
	migrated.ensure_location_industry("earth_orbit", "orbital_foundry", 99)
	var simulation := SimulationEngine.new(database)
	simulation.ensure_frontier_state(migrated)
	_check(migrated.industrial_operations.is_empty() and migrated.construction_operations.is_empty() and migrated.automation_rules.is_empty() and migrated.background_economy.get("mining_sources", {}).is_empty() and not migrated.facilities.has("orbital_foundry") and migrated.location_industries("earth_orbit").is_empty(), "runtime normalization rejects stale in-memory aggregate state")

	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = simulation
	game.state = migrated
	var industry_activity_id := ""
	var construction_activity_id := ""
	for activity_value in database.activities.values():
		var activity := activity_value as Dictionary
		if industry_activity_id.is_empty() and str(activity.get("domain", "")) == "industry" and not bool(activity.get("construction_project", false)):
			industry_activity_id = str(activity.get("id", ""))
		elif construction_activity_id.is_empty() and bool(activity.get("construction_project", false)):
			construction_activity_id = str(activity.get("id", ""))
	_check(not game.start_activity("mining", "legacy_ship_mining_activity") and not game.start_activity("industry", industry_activity_id) and not game.start_construction_project(construction_activity_id), "removed aggregate player commands cannot restart retired gameplay")


func _working_factory(with_storage: bool) -> Dictionary:
	var world := factory.create_world("fixture", "earth_orbit", Vector2i(256, 256), 99)
	factory.add_resource_field(world, "iron-field", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid")
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power")
	factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "mine")
	factory.place_entity_immediate(world, "grid_arc_smelter", Vector2i(72, 32), "grid_refine_iron", "smelter")
	factory.connect_entities(world, "POWER", "power", "mine")
	factory.connect_entities(world, "POWER", "power", "smelter")
	factory.connect_entities(world, "CARGO", "mine", "smelter", "iron_ore", 8.0)
	if with_storage:
		factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(110, 32), "", "depot")
		factory.connect_entities(world, "CARGO", "smelter", "depot", "iron_ingot", 4.0)
	return world


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: square-grid mining, production, logistics and construction foundation")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
