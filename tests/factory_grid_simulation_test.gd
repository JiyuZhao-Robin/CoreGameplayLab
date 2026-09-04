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
	_test_resource_field_exclusion_and_coverage()
	_test_placement_and_port_contracts()
	_test_fair_and_priority_routing()
	_test_transport_capacity_does_not_bank()
	_test_resource_potential_caps_high_grade_extraction()
	_test_mining_production_power_and_conservation()
	_test_backpressure_and_recovery()
	_test_production_funds_real_construction()
	_test_simulation_engine_integration()
	_test_new_game_factory_bootstrap()
	_test_application_command_boundary()
	_test_removed_aggregate_runtime_cannot_restart()
	_test_save_round_trip()
	_finish()


func _test_sparse_square_world_and_tile_resources() -> void:
	var world := factory.create_world("earth-grid", "earth_orbit", Vector2i(20_000_000, 20_000_000), 730201)
	_check(world.get("entities", {}).is_empty() and world.get("resource_fields", {}).is_empty() and world.get("tile_deltas", {}).is_empty(), "planet-scale bounds do not allocate a width-by-height tile array")
	_check(factory.chunk_coordinate(world, Vector2i(63, 63)) == Vector2i(0, 0), "tile 63 remains in chunk zero")
	_check(factory.chunk_coordinate(world, Vector2i(64, 64)) == Vector2i(1, 1) and factory.chunk_local_coordinate(world, Vector2i(64, 64)) == Vector2i.ZERO, "tile 64 crosses to the next 64-metre chunk")
	var first := factory.tile_snapshot(world, Vector2i(1000, 2000))
	var second_world := factory.create_world("earth-grid-copy", "earth_orbit", Vector2i(20_000_000, 20_000_000), 730201)
	var second := factory.tile_snapshot(second_world, Vector2i(1000, 2000))
	_check(first.get("terrain_type", "") == second.get("terrain_type", "") and str(first.get("terrain_type", "")) in ["MOUNTAIN", "WATER", "FOREST", "PLAIN", "DESERT"] and not str(first.get("terrain_color", "")).is_empty(), "seed plus integer metre coordinate deterministically regenerates a colored terrain attribute")
	_check(not bool(factory.tile_snapshot(world, Vector2i(-1, 0)).get("valid", true)), "world bounds reject negative out-of-canvas coordinates")
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
	_check(bool(factory.connect_entities(world, "POWER", "power", "mine").get("ok", false)) and bool(factory.connect_entities(world, "POWER", "power", "smelter").get("ok", false)), "power links form an explicit local network")
	_check(bool(factory.connect_entities(world, "CARGO", "mine", "smelter", "iron_ore", 8.0).get("ok", false)), "cargo link accepts a compatible item route")
	var second_input := factory.connect_entities(world, "CARGO", "depot", "smelter", "iron_ore", 8.0)
	_check(not bool(second_input.get("ok", true)) and str(second_input.get("reason_code", "")) == "CARGO_INPUT_OCCUPIED", "ordinary item input ports cannot silently fan in and bypass a merger")


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
	_check(not world.is_empty() and int(world.get("bounds", {}).get("size", {}).get("x", 0)) == 20_000_000, "new saves bootstrap the configured sparse Earth factory world")
	_check(str(world.get("resource_fields", {}).get("starter-iron-field", {}).get("resource_id", "")) == "iron_ore" and not world.get("entities", {}).has("starter-iron-field"), "new factory bootstrap stores the starter iron field outside the entity registry")
	_check(int(depot.get("inventory", {}).get("scrap_metal", 0)) == scrap_before and int(depot.get("inventory", {}).get("electronics", 0)) == electronics_before, "founding industrial cargo moves into the starter entity depot")
	_check(state.item_quantity("scrap_metal", "earth_orbit") == 0 and state.item_quantity("electronics", "earth_orbit") == 0, "starter cargo is moved rather than duplicated in Location Inventory")


func _test_application_command_boundary() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	_check(game.initialize_factory_world("command-grid", "earth_orbit", Vector2i(256, 256), 123), "Game command creates a factory world transactionally")
	_check(game.register_factory_resource_field("command-grid", "command-iron", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid"), "generator-facing Game command registers a tile resource field transactionally")
	_check(game.queue_factory_construction("command-grid", "grid_surface_mine", Vector2i(34, 34)), "player-facing Game command creates a construction order rather than an instant mine")
	var command_world: Dictionary = game.state.factory_worlds.get("command-grid", {})
	_check(command_world.get("construction_orders", {}).size() == 1 and command_world.get("entities", {}).is_empty() and command_world.get("resource_fields", {}).size() == 1, "application boundary persists the order while resource fields remain outside the entity registry")
	var snapshot: Dictionary = game.factory_tile_snapshot("command-grid", Vector2i(35, 35))
	_check(str(snapshot.get("resource_field_id", "")) == "command-iron", "UI query reads a terrain/resource projection without owning tile state")


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
