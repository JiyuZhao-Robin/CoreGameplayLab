extends SceneTree

## Current sparse Factory contract: circular extraction, drone logistics,
## wireless power, Location-owned stock, and finished-building deployment.
var failures: Array[String] = []
var database: ContentDatabase
var factory: FactoryGridSimulation
var command_serial := 0
const LOCATION := "earth_orbit"
const STARTER := "earth-surface-grid"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game: Variant = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "grid-factory content loads: %s" % [database.errors])
	if not failures.is_empty():
		_finish()
		return
	factory = FactoryGridSimulation.new(database.factory_buildings, database.factory_recipes, database.factory_grid_rules)
	_test_sparse_square_world_and_tile_resources()
	_test_world_profile_contracts()
	_test_resource_field_exclusion_and_coverage()
	_test_placement_and_retired_ports()
	_test_unconfigured_machine_contracts()
	_test_fair_and_consumer_priority_dispatch()
	_test_transport_capacity_does_not_bank()
	_test_resource_potential_caps_high_grade_extraction()
	_test_mining_production_power_and_conservation()
	_test_backpressure_and_recovery()
	_test_finished_building_deployment()
	_test_simulation_engine_integration()
	_test_new_game_factory_bootstrap()
	_test_factory_bound_force_crop()
	_test_application_command_boundary()
	_test_removed_aggregate_runtime_cannot_restart()
	_test_save_round_trip()
	_finish()


func _test_world_profile_contracts() -> void:
	var expected := {
		"earth_orbit":Vector2i(1024, 640), "lunar_space":Vector2i(1536, 960),
		"asteroid_belt":Vector2i(1536, 960), "gas_giant_region":Vector2i(3072, 1920),
		"outer_system":Vector2i(2048, 1280), "deep_system":Vector2i(4096, 2560),
		"earth_sun_lagrange":Vector2i(1536, 960), "inner_solar_orbit":Vector2i(2048, 1280)
	}
	var profiles: Dictionary = database.factory_grid_rules.get("world_profiles", {})
	_check(_dimensions(database.factory_grid_rules.get("max_world_size_tiles", {})) == Vector2(4096,2560), "one authored maximum bounds every Factory canvas")
	_check(profiles.size() == database.regions.size(), "every Location has one finite Factory profile")
	for location in expected:
		var size: Dictionary = profiles.get(location, {}).get("size_tiles", {})
		_check(Vector2i(int(size.get("x", 0)), int(size.get("y", 0))) == expected[location], "%s uses its current authored planetary dimensions" % location)
	var earth := factory.create_world("edge", LOCATION, Vector2i(1024, 640))
	_check(factory.chunk_coordinate(earth, Vector2i(1023, 639)) == Vector2i(15, 9) and factory.chunk_local_coordinate(earth, Vector2i(1023, 639)) == Vector2i(63, 63), "Earth's last tile has the correct sparse chunk address")
	_check(bool(factory.tile_snapshot(earth, Vector2i(1023, 639)).get("valid", false)) and not bool(factory.tile_snapshot(earth, Vector2i(1024, 639)).get("valid", true)), "logical Earth boundary excludes the first tile beyond its last chunk")
	var partial := factory.create_world("partial", LOCATION, Vector2i(190, 125))
	_check(factory.chunk_coordinate(partial, Vector2i(189, 124)) == Vector2i(2, 1) and factory.chunk_local_coordinate(partial, Vector2i(189, 124)) == Vector2i(61, 60) and not bool(factory.tile_snapshot(partial, Vector2i(190, 124)).get("valid", true)), "smaller custom worlds retain partial final chunks and exact bounds")


func _test_resource_field_exclusion_and_coverage() -> void:
	var world := factory.create_world("coverage", LOCATION, Vector2i(256, 256))
	_check(bool(factory.add_resource_field(world, "iron", "iron_ore", Vector2i(32, 32), Vector2i(3, 3), 1.0, 10.0).get("ok", false)), "resource field registers independently of structures")
	var overlap := factory.add_resource_field(world, "copper-overlap", "copper_ore", Vector2i(32, 32), Vector2i(3, 3))
	_check(not bool(overlap.get("ok", true)), "distinct mineral fields cannot occupy the same tiles")
	_check(bool(factory.add_resource_field(world, "copper-far", "copper_ore", Vector2i(160, 160), Vector2i(3, 3)).get("ok", false)), "widely separated mineral fields remain valid")
	if not _place(factory, world, "grid_planetary_core", Vector2i(0, 0), "power") or not _place(factory, world, "grid_surface_mine", Vector2i(32, 32), "mine"):
		return
	var mine: Dictionary = world["entities"]["mine"]
	_check(mine.get("footprint", {}).get("size", {}) == {"x":11, "y":11} and is_equal_approx(float(mine.get("mining_radius_tiles", 0.0)), 18.0), "actual core extractor uses its 11-square footprint and radius-18 mining circle")
	world["tile_deltas"]["34:34"] = {"resource_cleared":true}
	factory.advance_world(world, 1000.0)
	_check(int(mine.get("covered_resource_tiles", 0)) == 8 and is_equal_approx(float(mine.get("coverage_efficiency", 0.0)), 1.0), "circular extraction counts eight remaining mineral tiles without penalizing empty ground")
	_check(is_equal_approx(float(mine.get("actual_rate", 0.0)), 4.0), "adequate mineral potential sustains the extractor's actual four-unit rate")


func _test_placement_and_retired_ports() -> void:
	var world := factory.create_world("placement", LOCATION, Vector2i(256, 256))
	factory.add_resource_field(world, "iron", "iron_ore", Vector2i(32, 32), Vector2i(24, 24))
	var over_resource := factory.place_entity_immediate(world, "grid_arc_smelter", Vector2i(34, 34), "grid_refine_iron", "cover")
	_check(bool(over_resource.get("ok", false)) and str(factory.tile_snapshot(world, Vector2i(35, 35)).get("resource_id", "")) == "iron_ore", "ordinary structures may cover but never erase the independent resource layer")
	var duplicate := factory.place_entity_immediate(world, "grid_arc_smelter", Vector2i(34, 34), "grid_refine_iron")
	_check(not bool(duplicate.get("ok", true)) and str(duplicate.get("reason_code", "")) == "FOOTPRINT_OCCUPIED", "overlapping building footprints are rejected atomically")
	var missing := factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(190, 190))
	_check(not bool(missing.get("ok", true)) and str(missing.get("reason_code", "")) == "RESOURCE_REQUIRED", "extractors require a resource within their circular mining range")
	var before := world.duplicate(true)
	for kind in ["POWER", "CARGO", "RESOURCE"]:
		var result := factory.connect_entities(world, kind, "cover", "cover", "iron_ore")
		_check(not bool(result.get("ok", true)), "retired %s manual ports cannot create a second local network" % kind)
	_check(world == before and world.get("links", {}).is_empty(), "retired port calls leave world topology and assets unchanged")
	var edge := factory.can_place_entity(world, "grid_solar_array", Vector2i(248, 248))
	var outside := factory.can_place_entity(world, "grid_solar_array", Vector2i(249, 248))
	_check(bool(edge.get("ok", false)) and str(outside.get("reason_code", "")) == "OUT_OF_BOUNDS", "whole-footprint bounds accept an exact edge and reject one-tile overflow")


func _test_unconfigured_machine_contracts() -> void:
	var grid := _small_grid()
	var world := grid.create_world("unconfigured", LOCATION, Vector2i(64, 32))
	if not _place(grid, world, "machine", Vector2i(12, 8), "machine") or not _place(grid, world, "tower", Vector2i(2, 8), "tower"):
		return
	var context := _context({"ore":30})
	grid.advance_world(world, 10000.0, context)
	_check(str(world["entities"]["machine"].get("status", "")) == "NO_RECIPE" and is_zero_approx(float(world["entities"]["machine"].get("actual_rate", -1.0))), "unconfigured machines stay NO_RECIPE at zero production")
	_check(world.get("drone_shipments", {}).is_empty() and context["inventory"]["ore"] == 30, "an unconfigured machine creates no ingredient requests or drone withdrawals")
	var projected: Dictionary = grid.workspace_snapshot(world).get("entities", [])[0]
	for row in grid.workspace_snapshot(world).get("entities", []):
		if str(row.get("id", "")) == "machine":
			projected = row
	var item_ports := 0
	for port in projected.get("ports", {}).get("entries", []):
		if str(port.get("channel", "")) == "ITEM":
			item_ports += 1
	_check(projected.get("input_targets", {}).is_empty() and item_ports == 0, "unconfigured snapshot exposes neither ingredient targets nor item ports")
	var invalid := grid.set_entity_recipe(world, "machine", "missing")
	_check(not bool(invalid.get("ok", true)) and str(world["entities"]["machine"].get("recipe_id", "")) == "", "invalid recipe changes preserve the empty configuration")
	_check(bool(grid.set_entity_recipe(world, "machine", "smelt").get("ok", false)), "selecting a compatible recipe activates the configured machine")
	grid.advance_world(world, 2000.0, context)
	_check(int(world["entities"]["machine"]["inputs"].get("ore", 0)) > 0, "recipe selection permits real drone ingredient delivery")


func _test_fair_and_consumer_priority_dispatch() -> void:
	var grid := _small_grid({"drone_count":1})
	var world := grid.create_world("fair", LOCATION, Vector2i(64, 32))
	for entry in [["tower",2,"tower"], ["machine",8,"source"], ["machine",13,"a"], ["machine",18,"b"]]:
		if not _place(grid, world, str(entry[0]), Vector2i(int(entry[1]), 8), str(entry[2]), "smelt" if str(entry[2]) in ["a", "b"] else ""):
			return
	world["entities"]["source"]["outputs"] = {"ore":20}
	var context := _context({})
	grid.advance_world(world, 20000.0, context)
	_check(int(world["entities"]["a"]["inputs"].get("ore", 0)) == 10 and int(world["entities"]["b"]["inputs"].get("ore", 0)) == 10, "two equally starved consumers each receive one batch before either is filled")
	_check(int(context["inventory"].get("ore", 0)) == 0 and world["entities"]["source"]["outputs"].get("ore", 0) == 0, "eligible consumer deficits take priority over shared storage")
	_check(_quantity(world, context, "ore") == 20, "fair dispatch conserves both ten-item batches across all custodians")


func _test_transport_capacity_does_not_bank() -> void:
	var grid := _small_grid({"drone_count":1})
	var world := grid.create_world("finite-drones", LOCATION, Vector2i(64, 32))
	if not _place(grid, world, "tower", Vector2i(2, 8), "tower") or not _place(grid, world, "machine", Vector2i(14, 8), "source"):
		return
	var context := _context({})
	context["free_capacity"]["ore"] = 0
	grid.advance_world(world, 10000.0, context)
	world["entities"]["source"]["outputs"] = {"ore":20}
	grid.advance_world(world, 1.0, context)
	_check(world["drone_shipments"].size() == 1 and world["entities"]["source"]["outputs"]["ore"] == 20, "idle time never banks extra drones or skips the empty pickup flight")
	grid.advance_world(world, 5000.0, context)
	_check(world["drone_shipments"].size() == 1 and world["entities"]["source"]["outputs"]["ore"] == 10 and _quantity(world, context, "ore") == 20, "one blocked loaded drone occupies its only slot and preserves the remaining source batch")
	context["free_capacity"]["ore"] = 10
	grid.advance_world(world, 100.0, context)
	_check(int(context["inventory"].get("ore", 0)) == 10 and int(world["entities"]["source"]["outputs"].get("ore", 0)) == 10, "reopened capacity accepts one retained batch without an instantaneous second trip")


func _test_resource_potential_caps_high_grade_extraction() -> void:
	var grid := _small_grid()
	var world := grid.create_world("potential", LOCATION, Vector2i(64, 32))
	grid.add_resource_field(world, "rich", "ore", Vector2i(8, 8), Vector2i(3, 3), 2.0, 0.01)
	if not _place(grid, world, "power", Vector2i(1, 1), "power") or not _place(grid, world, "mine", Vector2i(8, 8), "mine"):
		return
	grid.advance_world(world, 1000.0)
	_check(is_equal_approx(float(world["entities"]["mine"].get("actual_rate", 0.0)), 0.09), "covered tiles' sustainable potential remains a hard cap after grade and power modifiers")


func _test_mining_production_power_and_conservation() -> void:
	var fixture := _working_factory()
	var grid: FactoryGridSimulation = fixture["grid"]
	var world: Dictionary = fixture["world"]
	var context: Dictionary = fixture["context"]
	var report := grid.advance_world(world, 60000.0, context)
	var expected_power := 100.0 / 130.0
	_check(int(report.get("steps", 0)) == 60, "a minute uses sixty deterministic one-second Factory steps")
	_check(is_equal_approx(float(world["entities"]["mine"].get("power_factor", 0.0)), expected_power) and is_equal_approx(float(world["entities"]["smelter"].get("power_factor", 0.0)), expected_power), "wireless brownout proportionally throttles all consumers without road topology")
	_check(int(context["inventory"].get("ingot", 0)) >= 10, "deposit, extractor, drones, smelter and shared storage form a productive vertical slice")
	var stats: Dictionary = world["statistics"]
	_check(int(stats.get("produced", {}).get("ore", 0)) == int(stats.get("consumed", {}).get("ore", 0)) + _quantity(world, context, "ore"), "ore is conserved across buffers, drone cargo, shared stock and recipe consumption")
	_check(int(stats.get("produced", {}).get("ingot", 0)) == _quantity(world, context, "ingot"), "every manufactured ingot remains in exactly one live custodian")
	_check(world["entities"]["tower"].get("inventory", {}).is_empty(), "the logistics tower does not own a duplicate storage inventory")


func _test_backpressure_and_recovery() -> void:
	var grid := _small_grid()
	var world := grid.create_world("backpressure", LOCATION, Vector2i(64, 32))
	if not _place(grid, world, "power", Vector2i(1, 1), "power") or not _place(grid, world, "machine", Vector2i(14, 8), "smelter", "smelt"):
		return
	world["entities"]["smelter"]["inputs"] = {"ore":100}
	var context := _context({})
	grid.advance_world(world, 120000.0, context)
	_check(world["entities"]["smelter"]["outputs"].get("ingot", 0) == 20 and str(world["entities"]["smelter"].get("status", "")) == "OUTPUT_FULL", "twenty-item output capacity stops further production without removing unprocessed ingredients")
	var produced_before := int(world["statistics"]["produced"].get("ingot", 0))
	var ore_before := _quantity(world, context, "ore")
	if not _place(grid, world, "tower", Vector2i(2, 8), "tower"):
		return
	grid.advance_world(world, 30000.0, context)
	var produced_after := int(world["statistics"]["produced"].get("ingot", 0))
	_check(produced_after > produced_before and int(context["inventory"].get("ingot", 0)) >= 20, "adding drone coverage drains blocked output and automatically resumes production")
	_check(_quantity(world, context, "ingot") == produced_after and ore_before - _quantity(world, context, "ore") == (produced_after - produced_before) * 2, "backpressure recovery preserves recipe input/output conservation")


func _test_finished_building_deployment() -> void:
	var game: Variant = _fresh_game()
	_check(_command(game, "DEPLOY_BUILDING", {"definition_id":"grid_planetary_core","origin":{"x":110,"y":32}}).get("accepted", false), "finished core deploys immediately at the player's chosen site")
	var item := "building_grid_solar_array"
	game.state.location_inventory(LOCATION)[item] = 0
	var ghost := _command(game, "DEPLOY_BUILDING", {"definition_id":"grid_solar_array","origin":{"x":150,"y":32}})
	var world: Dictionary = game.state.factory_worlds[STARTER]
	_check(bool(ghost.get("accepted", false)) and world["construction_orders"].size() == 1, "missing finished stock creates one deployment ghost")
	if world["construction_orders"].size() != 1:
		return
	var order_id := str(world["construction_orders"].keys()[0])
	var order: Dictionary = world["construction_orders"][order_id]
	_check(order.get("required_items", {}) == {item:1} and str(order.get("status", "")) == "WAITING_BUILDING" and order.get("delivered_items", {}).is_empty(), "ghost asks only for one complete building, with no onsite BOM")
	var rejected := _command(game, "FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":order_id})
	_check(str(rejected.get("reason_code", "")) == "CONSTRUCTION_RETIRED", "legacy onsite material funding cannot restart")
	game.advance_game_time(10000.0)
	_check(game.state.factory_worlds[STARTER]["construction_orders"].has(order_id), "time alone cannot complete a missing building")
	game.state.location_inventory(LOCATION)[item] = 1
	game.advance_game_time(100.0)
	world = game.state.factory_worlds[STARTER]
	_check(world["construction_orders"].is_empty() and world["entities"].has(str(order.get("entity_id", ""))) and game.state.item_quantity(item, LOCATION) == 0, "arrival of one finished item deploys the pending structure once")
	_check(int(game.state.factory_world_item_ledger().get("InstalledBuildings", {}).get(item, 0)) == 1 and int(game.state.factory_world_item_ledger().get("Consumed", {}).get(item, 0)) == 0, "deployment transfers finished building custody rather than consuming construction raw materials")
	game.advance_game_time(1000.0)
	_check(int(game.state.factory_world_item_ledger().get("InstalledBuildings", {}).get(item, 0)) == 1, "later ticks cannot duplicate ghost deployment")


func _test_simulation_engine_integration() -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var simulation := SimulationEngine.new(database)
	simulation.ensure_frontier_state(state)
	state.factory_worlds.clear()
	var world := factory.create_world("online", LOCATION, Vector2i(128, 128))
	factory.add_resource_field(world, "iron", "iron_ore", Vector2i(32, 32), Vector2i(24, 24))
	if not _place(factory, world, "grid_planetary_core", Vector2i(0, 0), "core") or not _place(factory, world, "grid_surface_mine", Vector2i(32, 32), "mine"):
		return
	state.factory_worlds["online"] = world
	var report := simulation.advance(state, 5000.0)
	_check(is_equal_approx(float(state.factory_worlds["online"].get("elapsed_ms", 0.0)), 5000.0) and is_equal_approx(float(report.get("simulated_ms", 0.0)), 5000.0), "online/offline SimulationEngine advances Factory through the shared time authority without losing time")
	_check(int(state.factory_worlds["online"].get("statistics", {}).get("produced", {}).get("iron_ore", 0)) > 0, "actual extractor production participates in ordinary simulation advancement")


func _test_new_game_factory_bootstrap() -> void:
	var game: Variant = _fresh_game()
	var world: Dictionary = game.state.factory_worlds[STARTER]
	_check(world["bounds"]["size"] == {"x":1024,"y":640} and world["entities"].is_empty(), "new Earth has current finite bounds and no preplaced buildings")
	_check(world["resource_fields"].has("starter-iron-field") and not world["entities"].has("starter-iron-field"), "startup mineral fields remain tile data")
	_check(game.state.item_quantity("building_grid_planetary_core", LOCATION) == 1 and game.state.item_quantity("building_grid_surface_mine", LOCATION) == 0, "new game grants one selectable core while the deployment package waits for landing")
	var scrap_before: int = game.state.item_quantity("scrap_metal", LOCATION)
	_check(_command(game, "DEPLOY_BUILDING", {"definition_id":"grid_planetary_core","origin":{"x":110,"y":32}}).get("accepted", false), "player-selected core deployment succeeds without roads")
	_check(game.state.item_quantity("building_grid_surface_mine", LOCATION) == 2 and game.state.item_quantity("building_grid_arc_smelter", LOCATION) == 2 and game.state.item_quantity("building_grid_engineering_works", LOCATION) == 1, "first landing grants exactly two miners, two furnaces and one assembler")
	var before: Dictionary = game.state.to_dictionary()
	game.simulation.ensure_frontier_state(game.state)
	game.simulation.ensure_frontier_state(game.state)
	_check(game.state.item_quantity("building_grid_surface_mine", LOCATION) == 2 and game.state.item_quantity("scrap_metal", LOCATION) == scrap_before, "repeated normalization neither repeats the starter package nor transfers Location cargo into a duplicate depot")
	_check(game.state.factory_worlds[STARTER]["entities"].size() == 1 and before["factory_worlds"][STARTER]["entities"].size() == 1, "only the chosen development core exists after landing")


func _test_factory_bound_force_crop() -> void:
	for offset in [Vector2i.ZERO, Vector2i(1000, 2000)]:
		var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
		var simulation := SimulationEngine.new(database)
		var world := factory.create_world("crop", LOCATION, Vector2i(20000000, 20000000))
		world["bounds"]["origin"] = {"x":offset.x,"y":offset.y}
		if not _place(factory, world, "grid_solar_array", offset + Vector2i(1016, 632), "edge") or not _place(factory, world, "grid_solar_array", offset + Vector2i(1500, 700), "far"):
			continue
		factory.add_resource_field(world, "inside", "iron_ore", offset + Vector2i(64, 64), Vector2i(16,16))
		factory.add_resource_field(world, "outside", "iron_ore", offset + Vector2i(1500, 800), Vector2i(16,16))
		var inside_order := factory.queue_construction(world, "grid_solar_array", offset + Vector2i(200, 100))
		var partial_order := factory.queue_construction(world, "grid_solar_array", offset + Vector2i(1020, 600))
		_check(bool(inside_order.get("ok", false)) and bool(partial_order.get("ok", false)), "oversized legacy fixture contains fully fitting and partly overflowing ghosts")
		world["tile_deltas"]["%d:%d" % [offset.x+100,offset.y+100]] = {"terrain_override":"PLAIN"}
		world["tile_deltas"]["%d:%d" % [offset.x+1800,offset.y+800]] = {"terrain_override":"PLAIN"}
		world["tile_deltas"]["malformed"] = {}
		world["revealed_chunks"] = {"0:0":true,"100:100":true,"malformed":true}
		world["command_receipts"]["durable"] = {"accepted":true,"command_kind":"DEPLOY_BUILDING","message_key":"factory.success.deploy_building"}
		world["command_receipt_order"] = ["durable"]
		state.factory_worlds["crop"] = world
		simulation.ensure_frontier_state(state)
		world = state.factory_worlds["crop"]
		_check(world["bounds"]["size"] == {"x":1024,"y":640} and world["entities"].has("edge") and not world["entities"].has("far"), "Location force-crop respects nonzero origins and exact-edge complete footprints")
		_check(world["resource_fields"].keys() == ["inside"] and world["construction_orders"].size() == 1 and world["construction_orders"].has(str(inside_order.get("order_id",""))), "force-crop removes out-of-bounds resource fields and partial ghosts while preserving complete records")
		_check(world["tile_deltas"].size() == 1 and world["revealed_chunks"] == {"0:0":true}, "crop purges malformed and off-map sparse tiles and revelation")
		_check(world["command_receipts"].has("durable") and world["command_receipt_order"] == ["durable"], "crop preserves command idempotency history")
		var once: Dictionary = world.duplicate(true)
		simulation.ensure_frontier_state(state)
		_check(state.factory_worlds["crop"] == once, "spatial crop and runtime reconciliation are idempotent")
		var restored := SpaceGameState.from_dictionary(JSON.parse_string(JSON.stringify(state.to_dictionary())), database.domains.keys(), database.regions)
		simulation.ensure_frontier_state(restored)
		_check(restored.factory_worlds["crop"]["bounds"] == world["bounds"] and not restored.factory_worlds["crop"]["entities"].has("far"), "discarded out-of-bounds records never revive on JSON save/load")
	var unknown_state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var unknown_sim := SimulationEngine.new(database)
	unknown_state.factory_worlds["unknown"] = factory.create_world("unknown", "unknown_location", Vector2i(9000,9000))
	unknown_sim.ensure_frontier_state(unknown_state)
	_check(unknown_state.factory_worlds["unknown"]["bounds"]["size"] == {"x":4096,"y":2560}, "unprofiled legacy worlds obey the global maximum")


func _test_application_command_boundary() -> void:
	var game: Variant = _fresh_game()
	var workspace: Dictionary = game.factory_workspace_snapshot(STARTER)
	_check(_dimensions(workspace.get("canvas_limits", {}).get("max_world_size_tiles", {})) == Vector2(4096,2560), "workspace publishes the current authored canvas maximum")
	_check(not game.initialize_factory_world("too-wide", LOCATION, Vector2i(1025,640)) and not game.initialize_factory_world("too-tall", LOCATION, Vector2i(1024,641)), "application rejects either dimension exceeding the Location profile")
	_check(_command(game, "DEPLOY_BUILDING", {"definition_id":"grid_planetary_core","origin":{"x":110,"y":32}}).get("accepted", false), "application lands the initial core before other construction")
	_check(game.register_factory_resource_field(STARTER, "command-iron", "iron_ore", Vector2i(300,100), Vector2i(24,24)), "generator-facing application command registers independent tile mineral data")
	game.state.location_inventory(LOCATION)["building_grid_surface_mine"] = 0
	_check(game.queue_factory_construction(STARTER, "grid_surface_mine", Vector2i(300,100)), "legacy-named application construction helper now requests finished-item deployment")
	var world: Dictionary = game.state.factory_worlds[STARTER]
	_check(world["construction_orders"].size() == 1 and world["entities"].size() == 1 and world["resource_fields"].has("command-iron"), "application persists a ghost with no mine item while fields remain outside entity registry")
	var tile: Dictionary = game.factory_tile_snapshot(STARTER, Vector2i(302,102))
	_check(str(tile.get("resource_field_id","")) == "command-iron", "UI tile query reads the authoritative resource projection")
	var invalid := _command(game, "DEPLOY_BUILDING", {"definition_id":"grid_solar_array","origin":{"x":1020,"y":639}})
	_check(str(invalid.get("reason_code","")) == "OUT_OF_BOUNDS", "application exposes a stable out-of-bounds deployment reason")
	var retired := _command(game, "BUILD_ROAD", {"tiles":[{"x":200,"y":20}],"tier":1})
	_check(str(retired.get("reason_code","")) == "ROADS_RETIRED" and game.state.factory_worlds[STARTER].get("roads",{}).is_empty(), "retired road commands cannot create hidden infrastructure")
	for location in database.factory_grid_rules.get("world_profiles", {}):
		if str(location) == LOCATION:
			continue
		game.state.location_state(str(location))["survey_state"] = LocationState.SURVEYED
		_check(game.initialize_surveyed_factory_world(str(location)), "surveyed %s initializes its canonical Factory world" % location)
		var profile: Dictionary = database.factory_grid_rules["world_profiles"][location]
		var actual_size := _dimensions(game.state.factory_worlds.get(str(profile["world_id"]),{}).get("bounds",{}).get("size",{}))
		var authored_size := _dimensions(profile["size_tiles"])
		_check(actual_size == authored_size, "remote %s applies the independently verified authored profile (%s == %s)" % [location,actual_size,authored_size])


func _test_save_round_trip() -> void:
	var fixture := _working_factory()
	var grid: FactoryGridSimulation = fixture["grid"]
	var world: Dictionary = fixture["world"]
	var context: Dictionary = fixture["context"]
	grid.advance_world(world, 10500.0, context)
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.location_inventory(LOCATION).clear()
	state.location_inventory(LOCATION).merge(context["inventory"], true)
	state.factory_worlds["flow"] = world
	var before := state.factory_world_item_holdings()
	var payload: Variant = JSON.parse_string(JSON.stringify(state.to_dictionary()))
	_check(payload is Dictionary, "current Factory state contains only JSON-safe persistent values")
	if payload is not Dictionary:
		return
	var restored := SpaceGameState.from_dictionary(payload, database.domains.keys(), database.regions)
	var saved_world: Dictionary = restored.factory_worlds["flow"]
	_check(_sorted_keys(saved_world["entities"]) == _sorted_keys(world["entities"]) and _sorted_keys(saved_world["drone_shipments"]) == _sorted_keys(world["drone_shipments"]), "JSON normalization preserves every entity and drone-flight identity regardless of dictionary insertion order")
	_check(restored.factory_world_item_holdings() == before and restored.location_inventory(LOCATION) == state.location_inventory(LOCATION), "buffer, drone transit and shared stock custody survive without copies")
	_check(saved_world.get("links",{}).is_empty() and saved_world.get("roads",{}).is_empty(), "save/load never restores retired local networks")


func _small_grid(overrides: Dictionary = {}) -> FactoryGridSimulation:
	var footprint := {"width":1,"height":1}
	var rules := {"drone_radius_tiles":64.0,"drone_count":4,"drone_cargo_capacity":10,"drone_speed_tiles_per_second":12.0,"drone_input_batches":10}
	rules.merge(overrides,true)
	var definitions := {
		"power":{"id":"power","kind":"POWER","footprint":footprint,"power_generation_kw":100.0},
		"tower":{"id":"tower","kind":"STORAGE","footprint":footprint,"drone_tower":true,"drone_radius_tiles":64.0,"drone_count":int(rules["drone_count"]),"inventory_capacity":1000},
		"mine":{"id":"mine","kind":"EXTRACTOR","footprint":{"width":3,"height":3},"resource_categories":["solid"],"mining_rate_per_second":4.0,"power_demand_kw":50.0,"output_capacity":20},
		"machine":{"id":"machine","kind":"MACHINE","footprint":footprint,"recipe_ids":["smelt"],"speed":1.0,"input_capacity":200,"output_capacity":20,"power_demand_kw":80.0}
	}
	var recipes := {"smelt":{"id":"smelt","duration_seconds":2.0,"inputs":[{"item":"ore","quantity":2}],"outputs":[{"item":"ingot","quantity":1}]}}
	return FactoryGridSimulation.new(definitions, recipes, rules)


func _working_factory() -> Dictionary:
	var grid := _small_grid()
	var world := grid.create_world("flow", LOCATION, Vector2i(64,32))
	grid.add_resource_field(world, "ore-field", "ore", Vector2i(6,6), Vector2i(8,8), 1.0, 1.0)
	_place(grid, world, "power", Vector2i(1,1), "power")
	_place(grid, world, "tower", Vector2i(3,8), "tower")
	_place(grid, world, "mine", Vector2i(8,8), "mine")
	_place(grid, world, "machine", Vector2i(18,8), "smelter", "smelt")
	return {"grid":grid,"world":world,"context":_context({})}


func _context(inventory: Dictionary) -> Dictionary:
	return {"inventory":inventory,"available":inventory.duplicate(true),"free_capacity":{"ore":10000,"ingot":10000}}


func _dimensions(value: Dictionary) -> Vector2:
	# JSON content stores numeric Variants as floats; runtime bounds use ints.
	# Compare the actual coordinates, without integer truncation or dictionary
	# type equality obscuring a dimension mismatch.
	return Vector2(float(value.get("x",-1)),float(value.get("y",-1)))


func _sorted_keys(value: Dictionary) -> Array:
	var keys: Array = value.keys()
	keys.sort()
	return keys


func _quantity(world: Dictionary, context: Dictionary, item: String) -> int:
	var total := int(context.get("inventory",{}).get(item,0))
	for entity in world.get("entities",{}).values():
		for field in ["inputs","outputs","inventory"]:
			total += int(entity.get(field,{}).get(item,0))
	for job in world.get("drone_shipments",{}).values():
		total += int(job.get("cargo",{}).get(item,0))
	return total


func _place(grid: FactoryGridSimulation, world: Dictionary, definition: String, origin: Vector2i, id: String, recipe: String = "") -> bool:
	var result := grid.place_entity_immediate(world, definition, origin, recipe, id)
	_check(bool(result.get("ok",false)), "fixture places %s: %s" % [id,result])
	return bool(result.get("ok",false))


func _fresh_game() -> Variant:
	var game: Variant = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(),database.regions)
	game.simulation.ensure_frontier_state(game.state)
	return game


func _command(game: Variant, kind: String, payload: Dictionary) -> Dictionary:
	command_serial += 1
	return game.execute_factory_command({"protocol_version":1,"command_id":"foundation-%d" % command_serial,"kind":kind,"world_id":STARTER,"base_topology_revision":int(game.state.factory_worlds[STARTER].get("topology_revision",0)),"payload":payload})


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: current sparse Factory, circular mining, drone custody, power and finished-building deployment")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)


func _test_sparse_square_world_and_tile_resources() -> void:
	var world := factory.create_world("earth-grid", "earth_orbit", Vector2i(512, 384), 730201)
	_check(world.get("entities", {}).is_empty() and world.get("resource_fields", {}).is_empty() and world.get("tile_deltas", {}).is_empty(), "finite world bounds do not allocate a width-by-height tile array")
	_check(factory.chunk_coordinate(world, Vector2i(63, 63)) == Vector2i(0, 0), "tile 63 remains in chunk zero")
	_check(factory.chunk_coordinate(world, Vector2i(64, 64)) == Vector2i(1, 1) and factory.chunk_local_coordinate(world, Vector2i(64, 64)) == Vector2i.ZERO, "tile 64 crosses to the next 64-metre chunk")
	var first := factory.tile_snapshot(world, Vector2i(100, 200))
	var second_world := factory.create_world("earth-grid-copy", "earth_orbit", Vector2i(512, 384), 730201)
	var second := factory.tile_snapshot(second_world, Vector2i(100, 200))
	_check(first.get("terrain_type", "") == second.get("terrain_type", "") and str(first.get("terrain_type", "")) == "PLAIN" and not str(first.get("terrain_color", "")).is_empty(), "seed plus integer metre coordinate deterministically regenerates a colored terrain attribute")
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
	_check(int(migrated.get("schema_version", 0)) == 4 and migrated.get("resource_fields", {}).has("legacy-iron") and not migrated.get("entities", {}).has("legacy-iron"), "World Schema 1 deposit entities migrate into the Schema 4 tile resource layer")

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
