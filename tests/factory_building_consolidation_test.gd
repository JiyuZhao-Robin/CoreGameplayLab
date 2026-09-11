extends SceneTree

## Real catalog and save-boundary regression: retiring building variants must
## not retire player-owned kits, cargo, installed machines or paid production.
const Catalog = preload("res://src/core/factory_building_catalog.gd")
const Migration = preload("res://src/core/factory_building_migration.gd")
const WORLD := "consolidation-regression"
const LOCATION := "earth_orbit"
const OLD_BUILDING := "grid_dsp_assembling_machine_mk2"
const BUILDING := "grid_engineering_works"
const OLD_ITEM := "building_grid_dsp_assembling_machine_mk2"
const ITEM := "building_grid_engineering_works"
const OLD_RECIPE := "manufacture_grid_dsp_assembling_machine_mk2"
const FAMILIES := ["grid_surface_mine", "grid_engineering_works", "grid_arc_smelter", "grid_dsp_oil_refinery", "grid_dsp_chemical_plant", "grid_dsp_thermal_power_plant"]

var failures: Array[String] = []
var database: ContentDatabase
var simulation: SimulationEngine


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game: Variant = root.get_node_or_null("Game")
	if game != null:
		game.set_process(false)
		game.persistence_enabled = false
	database = ContentDatabase.new()
	if not database.load_from_file("res://data/content.json"):
		_check(false, "actual consolidated content database loads")
		_finish()
		return
	simulation = SimulationEngine.new(database)
	_test_catalog()
	_test_raw_migration()
	_test_state_roundtrips()
	_test_running_legacy_and_extraction()
	_finish()


func _test_catalog() -> void:
	_check(not Catalog.BUILDING_ALIASES.is_empty(), "retired variants have an explicit save migration map")
	for id in FAMILIES:
		_check(database.factory_buildings.has(id), "approved animated family remains active: %s" % id)
	for old_id in Catalog.BUILDING_ALIASES:
		var canonical := str(Catalog.canonical_building_id(str(old_id)))
		_check(not database.factory_buildings.has(old_id), "retired building is absent from active catalog: %s" % old_id)
		_check(database.factory_buildings.has(canonical), "retired building maps to a deployable active definition: %s" % old_id)
		_check(Catalog.canonical_item_id("building_%s" % old_id) == "building_%s" % canonical, "building and kit aliases agree: %s" % old_id)
		_check(not database.items.has("building_%s" % old_id), "retired kit is absent from active item catalog: %s" % old_id)
	for recipe_id in database.factory_recipes:
		var recipe: Dictionary = database.factory_recipes[recipe_id]
		for output in recipe.get("outputs", []):
			var item := str(output.get("item", ""))
			_check(item == Catalog.canonical_item_id(item), "recipe cannot produce a retired kit: %s -> %s" % [recipe_id, item])
	for definition in database.factory_buildings.values():
		for recipe_id in definition.get("recipe_ids", []):
			_check(not bool(database.factory_recipes.get(str(recipe_id), {}).get("legacy_only", false)), "active recipe picker excludes compatibility-only production: %s" % recipe_id)
	var chemical: Dictionary = database.factory_buildings.get("grid_dsp_chemical_plant", {})
	for recipe_id in ["dsp_deuterium_fractionation", "dsp_deuterium", "dsp_strange_matter", "dsp_antimatter"]:
		_check(database.factory_recipes.has(recipe_id) and chemical.get("recipe_ids", []).has(recipe_id), "retired processing machine product remains reachable in chemical plant: %s" % recipe_id)
	var core: Dictionary = database.factory_buildings.get("grid_planetary_core", {})
	_check(bool(core.get("drone_tower", false)), "the initial elevator hub dispatches drones")
	_check(int(core.get("inventory_capacity", 0)) == 2000, "the same initial hub adds 2000 shared storage capacity")
	_check(int(core.get("power_generation_kw", 0)) == 400, "the same initial hub supplies startup power")
	var legacy: Dictionary = database.factory_recipes.get(OLD_RECIPE, {})
	_check(bool(legacy.get("legacy_only", false)), "old in-progress manufacture recipe remains compatibility-only")
	_check(str(legacy.get("replacement_building_id", "")) == BUILDING, "compatibility recipe identifies its canonical replacement")
	_check(_item_counts(legacy.get("inputs", [])) == {"dsp_steel":8, "dsp_gear":8, "dsp_circuit_board":8, "dsp_magnetic_coil":4}, "already-selected old manufacture preserves its original four-ingredient BOM")
	_check(_item_counts(legacy.get("outputs", [])) == {ITEM:1}, "old manufacture completes as exactly one canonical finished building")


func _test_raw_migration() -> void:
	var source := {
		"inventory":{OLD_ITEM:2, ITEM:3},
		"inventory_reserves":{OLD_ITEM:1, ITEM:2},
		"selection":{"selected_building_id":OLD_BUILDING, "selected_item_id":OLD_ITEM},
		"pinned_items":[OLD_ITEM, "iron_ingot"],
		"nested":[{"item":OLD_ITEM, "quantity":7, "id":OLD_ITEM}],
		"command_receipts":{"deploy":{"definition_id":OLD_BUILDING, "item_id":OLD_ITEM}},
		"retired_archive":{"inventory":{OLD_ITEM:11}},
		"source_metadata":{"item_id":OLD_ITEM}
	}
	var original := source.duplicate(true)
	var migrated: Dictionary = Migration.migrate_save(source)
	_check(source == original, "pure migration never changes its caller's dictionary")
	_check(migrated.get("inventory", {}) == {ITEM:5}, "old and canonical physical stock merge by summation")
	_check(migrated.get("inventory_reserves", {}) == {ITEM:3}, "reservations merge without becoming physical stock")
	_check(migrated.get("selection", {}) == {"selected_building_id":BUILDING, "selected_item_id":ITEM}, "saved catalog selection follows canonical content")
	_check(migrated.get("pinned_items", []) == [ITEM, "iron_ingot"], "saved item pins migrate")
	_check(migrated.get("nested", []) == [{"item":ITEM, "quantity":7, "id":OLD_ITEM}], "nested item references migrate without rewriting instance identities")
	for field in ["command_receipts", "retired_archive", "source_metadata"]:
		_check(migrated.get(field, {}) == original[field], "historical/idempotency evidence is preserved: %s" % field)
	_check(Migration.migrate_save(migrated) == migrated, "raw migration is idempotent")


func _test_state_roundtrips() -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.factory_worlds.clear()
	state.location_inventory(LOCATION).clear()
	state.location_reserves(LOCATION).clear()
	var world := simulation.factory_grid.create_world(WORLD, LOCATION, Vector2i(192, 128), 7311)
	state.factory_worlds[WORLD] = world
	var placed: Dictionary = simulation.factory_grid.place_entity_immediate(world, BUILDING, Vector2i(40, 20), "", "assembler-instance-7")
	_check(bool(placed.get("ok", false)), "real canonical assembler can be deployed to build an old-save fixture")
	if not bool(placed.get("ok", false)):
		return
	var ghost_result: Dictionary = simulation.factory_grid.queue_construction(world, BUILDING, Vector2i(90, 40))
	_check(bool(ghost_result.get("ok", false)), "real pending finished-building ghost can be queued")
	if not bool(ghost_result.get("ok", false)):
		return
	var ghost_id := str(ghost_result.get("order_id", ""))
	var entity: Dictionary = world["entities"]["assembler-instance-7"]
	entity["definition_id"] = OLD_BUILDING
	entity["deployment_item_id"] = OLD_ITEM
	entity["recipe_id"] = OLD_RECIPE
	entity["progress"] = 0.375
	entity["inputs"] = {OLD_ITEM:2, ITEM:3, "dsp_steel":8}
	entity["outputs"] = {OLD_ITEM:4, ITEM:5}
	# An old Mk.II rectangle is intentionally smaller than a new manufacturer.
	# Changing occupied tiles during loading would cause adjacent overlaps.
	entity["footprint"]["size"] = {"x":5, "y":5}
	var footprint: Dictionary = entity["footprint"].duplicate(true)
	var ghost: Dictionary = world["construction_orders"][ghost_id]
	ghost["definition_id"] = OLD_BUILDING
	ghost["deployment_item_id"] = OLD_ITEM
	ghost["required_items"] = {OLD_ITEM:1}
	var ghost_footprint: Dictionary = ghost["footprint"].duplicate(true)
	world["starter_package_delivered"] = true
	world["landing_definition_id"] = "grid_planetary_core"
	world["drone_shipments"] = {"DRONE-SHIP-17":_cargo_job("DRONE-SHIP-17", 6, 1)}
	world["road_shipments"] = {"ROAD-SHIP-23":_cargo_job("ROAD-SHIP-23", 2, 1)}
	world["roads"] = {"3,4":{"x":3, "y":4, "tier":1}}
	state.location_inventory(LOCATION).merge({OLD_ITEM:11, ITEM:13}, true)
	state.location_reserves(LOCATION).merge({OLD_ITEM:2, ITEM:3}, true)
	state.logistics_network["shipments"] = [{"id":"SHIPMENT-29", "destination":LOCATION, "item_id":OLD_ITEM, "cargo":{OLD_ITEM:3, ITEM:2}}]
	var serialized := state.to_dictionary()
	var original := serialized.duplicate(true)
	var input_save := serialized
	for round_index in range(3):
		state = SpaceGameState.from_dictionary(serialized, database.domains.keys(), database.regions)
		world = state.factory_worlds.get(WORLD, {})
		entity = world.get("entities", {}).get("assembler-instance-7", {})
		ghost = world.get("construction_orders", {}).get(ghost_id, {})
		_check(str(entity.get("id", "")) == "assembler-instance-7" and str(entity.get("definition_id", "")) == BUILDING, "installed instance keeps identity and migrates definition on roundtrip %d" % round_index)
		_check(str(entity.get("deployment_item_id", "")) == ITEM, "installed building retains one canonical demolition refund")
		_check(entity.get("footprint", {}) == footprint, "old occupied rectangle does not expand into neighboring buildings")
		_check(is_equal_approx(float(entity.get("progress", -1.0)), 0.375), "paid in-progress production survives loading")
		_check(str(entity.get("recipe_id", "")) == OLD_RECIPE and bool(entity.get("legacy_recipe_continuation", false)), "already-running old recipe retains its BOM through explicit continuation")
		_check(entity.get("inputs", {}) == {ITEM:5, "dsp_steel":8} and entity.get("outputs", {}) == {ITEM:9}, "input and output buffers merge old and new kits without loss")
		_check(str(ghost.get("definition_id", "")) == BUILDING and str(ghost.get("deployment_item_id", "")) == ITEM, "pending ghost points at the retained building and finished kit")
		_check(ghost.get("required_items", {}) == {ITEM:1} and ghost.get("footprint", {}) == ghost_footprint, "ghost keeps position and requires one canonical kit")
		_check(bool(world.get("starter_package_delivered", false)), "loading cannot reset the one-time starter grant")
		_check(state.location_inventory(LOCATION) == {ITEM:24}, "shared Location owns exactly the combined 24 stock items")
		_check(state.location_reserves(LOCATION) == {ITEM:5}, "combined five reserved units remain claims on Location stock")
		var jobs: Dictionary = world.get("drone_shipments", {})
		_check(jobs.size() == 2 and jobs.get("DRONE-SHIP-17", {}).get("cargo", {}) == {ITEM:7} and jobs.get("ROAD-SHIP-23", {}).get("cargo", {}) == {ITEM:3}, "drone and retired-road cargo migrate once with shipment IDs intact")
		for job in jobs.values():
			_check(str(job.get("item_id", "")) == ITEM, "live shipment item discriminator follows its canonical cargo")
		_check(world.get("road_shipments", {}).is_empty(), "road cargo has no duplicate live road custodian")
		var ships: Array = state.logistics_network.get("shipments", [])
		_check(ships.size() == 1 and ships[0].get("cargo", {}) == {ITEM:5} and str(ships[0].get("item_id", "")) == ITEM, "interstellar shipment cargo and item discriminator migrate together")
		var physical := state.item_quantity(ITEM, LOCATION) + int(state.factory_world_item_holdings().get(ITEM, 0))
		for ship in ships:
			physical += int(ship.get("cargo", {}).get(ITEM, 0))
		_check(physical == 54, "all 54 physical kits (including installed building) conserved; reserves and ghost demand are not assets")
		_check(not state.factory_world_item_holdings().has(OLD_ITEM), "physical ledger contains no stranded retired kit")
		serialized = state.to_dictionary()
	_check(input_save == original, "real save loader leaves the caller's original old save untouched")
	world = simulation.factory_grid.normalize_world(world)
	_check(world.get("entities", {}).get("assembler-instance-7", {}).get("footprint", {}) == footprint, "configured simulation normalization also preserves occupied geometry")


func _cargo_job(id: String, old_quantity: int, new_quantity: int) -> Dictionary:
	return {"id":id, "tower_id":"missing-old-tower", "source_id":"assembler-instance-7", "target_id":"missing-old-tower", "item_id":OLD_ITEM, "cargo":{OLD_ITEM:old_quantity, ITEM:new_quantity}, "destination_kind":"WAREHOUSE", "phase":"RETURNING", "status":"IN_TRANSIT", "remaining_ms":2500.0, "travel_ms":5000.0, "from_position":{"x":45.0, "y":22.0}, "to_position":{"x":20.0, "y":20.0}}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: building consolidation catalog, shared hub, old-save cargo/stock/ghost migration and idempotency")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _item_counts(entries: Array) -> Dictionary:
	var counts := {}
	for entry in entries:
		var id := str(entry.get("item", ""))
		counts[id] = int(counts.get(id, 0)) + int(entry.get("quantity", 0))
	return counts


func _test_running_legacy_and_extraction() -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.factory_worlds.clear()
	state.location_inventory(LOCATION).clear()
	var world := simulation.factory_grid.create_world(WORLD, LOCATION, Vector2i(128, 128), 19)
	state.factory_worlds[WORLD] = world
	_check(bool(simulation.factory_grid.place_entity_immediate(world, "grid_planetary_core", Vector2i(10, 10), "", "core").get("ok", false)), "legacy production fixture deploys powered drone hub")
	_check(bool(simulation.factory_grid.place_entity_immediate(world, BUILDING, Vector2i(42, 10), "", "legacy-works").get("ok", false)), "legacy production fixture deploys manufacturer")
	world["entities"]["legacy-works"]["recipe_id"] = OLD_RECIPE
	world["entities"]["legacy-works"]["definition_id"] = OLD_BUILDING
	state = SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	for input in database.factory_recipes[OLD_RECIPE]["inputs"]:
		state.location_inventory(LOCATION)[str(input["item"])] = int(input["quantity"])
	for tick in range(60):
		simulation._progress_runtime(state, 1000.0)
	var total := int(state.factory_world_item_holdings().get(ITEM, 0)) + state.item_quantity(ITEM, LOCATION)
	_check(total == 2, "old selected BOM receives drone inputs and produces exactly one canonical kit beside the installed manufacturer")
	_check(not state.facilities.has("assembly_yard"), "consolidated manufacturer does not unlock advanced assembly before research")
	state.technologies["heavy_industry"] = true
	simulation.ensure_frontier_state(state)
	_check(state.facilities.has("assembly_yard"), "existing manufacturer unlocks assembly capability after heavy-industry research")
	var source := {"entities":{
		"make":{"id":"make", "definition_id":"grid_dsp_matrix_lab", "deployment_item_id":"building_grid_dsp_matrix_lab", "recipe_id":"dsp_energy_matrix", "inputs":{"dsp_hydrogen":2}, "progress":0.4},
		"research":{"id":"research", "definition_id":"grid_dsp_matrix_lab", "recipe_id":"dsp_matrix_research"}}}
	var migrated: Dictionary = Migration.migrate_save(source)
	_check(str(migrated["entities"]["make"]["definition_id"]) == BUILDING and float(migrated["entities"]["make"]["progress"]) == 0.4, "matrix-producing lab migrates to manufacturer with paid work intact")
	_check(str(migrated["entities"]["research"]["definition_id"]) == "grid_dsp_matrix_lab", "matrix research lab retains its independent function")
	world = simulation.factory_grid.create_world("liquid", LOCATION, Vector2i(128, 128), 21)
	state.factory_worlds = {"liquid":world}
	state.technologies.clear()
	_check(bool(simulation.factory_grid.add_resource_field(world, "oil", "dsp_crude_oil", Vector2i(20, 20), Vector2i(50, 50), 1.0, 1.0, "solid").get("ok", false)), "fixture preserves old oil field mislabeled solid")
	simulation._sync_factory_world_environments(state)
	var placement: Dictionary = simulation.factory_grid.can_place_entity(world, "grid_surface_mine", Vector2i(35, 35))
	_check(str(placement.get("reason_code", "")) == "BUILDING_LOCKED", "old solid-tagged oil cannot bypass liquid extraction technology")
	state.technologies["industrial_coordination"] = true
	simulation._sync_factory_world_environments(state)
	placement = simulation.factory_grid.can_place_entity(world, "grid_surface_mine", Vector2i(35, 35))
	_check(bool(placement.get("ok", false)), "same animated miner can extract oil after research")
	var profile: Dictionary = simulation.factory_grid._resource_definition(database.factory_buildings["grid_surface_mine"], {"resource_id":"dsp_crude_oil", "resource_category":"solid"})
	_check(float(profile.get("mining_rate_per_second", 0.0)) == 1.0 and float(profile.get("power_demand_kw", 0.0)) == 840.0, "oil retains its extraction rate and demand after consolidation")
