extends SceneTree

var failures: Array[String] = []
var database: ContentDatabase


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.get_node("Game").set_process(false)
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "merged catalog validates: %s" % [database.errors])
	var imported: Dictionary = database.dsp_industry
	_check(imported.get("source_item_map", {}).size() == 78 and imported.get("source_building_map", {}).size() == 39, "all source material and building IDs map exactly once")
	for building_id in imported.get("source_building_map", {}).values():
		var building: Dictionary = database.factory_buildings[building_id]
		var product := str(building["deployment_item_id"])
		_check(database.items[product].get("building_definition_id") == building_id, "finished product identity: %s" % building_id)
		var manufacture: Dictionary = database.factory_recipes["manufacture_%s" % building_id]
		_check(manufacture["outputs"].size() == 1 and str(manufacture["outputs"][0]["item"]) == product and int(manufacture["outputs"][0]["quantity"]) == 1, "manufacturing produces exactly one installable building")
		_check(database.factory_buildings["grid_engineering_works"]["recipe_ids"].has(manufacture["id"]) == not bool(building.get("legacy_only", false)), "starting assembler manufactures only active buildings")
	_test_catalog_batches()
	_test_finite_power()
	_test_proliferation_safety()
	_test_geography()
	_test_project_application_guard()
	if failures.is_empty():
		print("FACTORY_DSP_INTEGRATION_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_catalog_batches() -> void:
	var grid := FactoryGridSimulation.new(database.factory_buildings, database.factory_recipes, database.factory_grid_rules)
	for source_recipe in database.dsp_industry.get("factory_recipes", []):
		var recipe: Dictionary = database.factory_recipes[str(source_recipe["id"])]
		var mode := str(recipe.get("runtime_metadata", {}).get("recipe_mode", ""))
		if bool(recipe.get("legacy_only", false)) or mode != "STANDARD" or recipe["id"] in ["dsp_accumulator_charge", "dsp_accumulator_discharge"]:
			continue
		var machine_id := "grid_engineering_works" if str(recipe["id"]).begins_with("manufacture_") else str(recipe.get("source_building_id", ""))
		var definition: Dictionary = database.factory_buildings[machine_id]
		var world := grid.create_world("batch", "", Vector2i(256,160))
		var placed := grid.place_entity_immediate(world, machine_id, Vector2i(8,8), str(recipe["id"]), "machine")
		_check(placed.get("ok", false), "recipe-compatible deployment: %s" % recipe["id"])
		if not placed.get("ok", false):
			continue
		var entity: Dictionary = world["entities"]["machine"]
		for entry in recipe["inputs"]:
			entity["inputs"][entry["item"]] = int(entry["quantity"])
		var events: Array[Dictionary] = []
		grid._run_machines(world, float(recipe["duration_seconds"]) / float(definition.get("speed",1.0)), {"machine":1.0}, events)
		_check(events.size() == 1, "one real completion for %s" % recipe["id"])
		for entry in recipe["inputs"]:
			_check(int(entity["inputs"].get(entry["item"],0)) == 0, "exact batch consumption: %s" % recipe["id"])
		for entry in recipe["outputs"]:
			_check(int(entity["outputs"].get(entry["item"],0)) == int(entry["quantity"]), "exact batch output: %s" % recipe["id"])
		grid._run_machines(world, float(recipe["duration_seconds"]), {"machine":1.0}, events)
		_check(events.size() == 1, "empty inputs cannot duplicate batch output")


func _test_finite_power() -> void:
	var definitions := database.factory_buildings.duplicate(true)
	definitions["test_load"] = {"kind":"MACHINE","footprint":{"width":1,"height":1},"power_demand_kw":1000,"input_capacity":1,"output_capacity":1,"recipe_ids":[]}
	var grid := FactoryGridSimulation.new(definitions, database.factory_recipes, database.factory_grid_rules)
	var world := grid.create_world("power", "", Vector2i(256,160))
	grid.place_entity_immediate(world,"grid_dsp_thermal_power_plant",Vector2i(10,20),"","generator")
	grid.place_entity_immediate(world,"test_load",Vector2i(40,20),"","load")
	var roads: Array = []
	for x in range(10,41):
		roads.append({"x":x,"y":19})
	grid.edit_roads(world,roads)
	grid.refresh_derived_state(world)
	_check(world["entities"]["load"]["power_factor"] == 0.0,"unfueled generator cannot provide nameplate power")
	_check(world["entities"]["generator"]["status"] == "MISSING_FUEL", "unfueled power inspector reports missing fuel, not missing recipe")
	var state := SpaceGameState.create_new(database.domains.keys(),database.regions)
	world["location_id"] = "earth_orbit"
	state.factory_worlds = {"power":world}
	SimulationEngine.new(database).refresh_location_summaries(state)
	_check(float(state.locations["earth_orbit"]["power"]["generation_capacity"]) == 0.0, "location overview also excludes unfueled nameplate generation")
	world["entities"]["generator"]["inputs"]["dsp_coal"] = 1
	grid.advance_world(world,1000.0)
	_check(world["entities"]["generator"]["inputs"].get("dsp_coal",0) == 0 and world["statistics"]["consumed"].get("dsp_coal",0) == 1,"actual road allocation burns one finite coal unit once")
	_check(is_equal_approx(float(world["entities"]["generator"].get("fuel_remaining_mj",0)),1.45),"1000 kW for one second costs 1.25 MJ fuel at 80% efficiency")
	grid.advance_world(world,3000.0)
	_check(float(world["entities"]["load"]["power_factor"]) == 0.0,"finite coal eventually exhausts instead of perpetual generation")
	var before := world.duplicate(true)
	grid.refresh_derived_state(world)
	grid.refresh_derived_state(world)
	_check(world["statistics"] == before["statistics"] and world["entities"]["generator"]["inputs"] == before["entities"]["generator"]["inputs"],"snapshot refresh never burns fuel")
	grid.edit_roads(world,roads,1,true)
	grid.refresh_derived_state(world)
	_check(float(world["entities"]["generator"]["available_generation_kw"]) == 0.0, "disconnected generator cannot retain stale available road power")


func _test_geography() -> void:
	var state := SpaceGameState.create_new(database.domains.keys(),database.regions)
	var simulation := SimulationEngine.new(database)
	simulation.ensure_frontier_state(state)
	var world: Dictionary = state.factory_worlds["earth-surface-grid"]
	var resources := {}
	for field in world["resource_fields"].values():
		resources[str(field["resource_id"])] = true
	for entry in database.dsp_industry.get("resource_catalog",[]):
		_check(resources.has(str(entry["item_id"])),"raw material is obtainable as an actual ore/fluid patch: %s" % entry["item_id"])
	var roundtrip := simulation.factory_grid.normalize_world(world)
	_check(roundtrip["resource_fields"] == world["resource_fields"],"procedural resource descriptors survive normalization without reseeding")
	var gas_world := simulation.surveyed_factory_blueprint("gas_giant_region")
	var collector_resources := {}
	for field in gas_world.get("resource_fields",{}).values():
		if str(field.get("resource_category", "")) == "gas":
			collector_resources[str(field["resource_id"])] = true
	for item_id in database.factory_buildings["grid_dsp_orbital_collector"]["allowed_resource_ids"]:
		_check(collector_resources.has(item_id), "orbital collector has an obtainable gas patch: %s" % item_id)
	for building in simulation.factory_grid.workspace_snapshot(gas_world)["palette"]["buildings"]:
		if building["id"] == "grid_dsp_orbital_collector":
			_check(building.get("allowed_resource_ids",[]) == database.factory_buildings[building["id"]]["allowed_resource_ids"], "resource inspector receives the exact extractor whitelist, not just its broad category")


func _test_proliferation_safety() -> void:
	var grid := FactoryGridSimulation.new(database.factory_buildings,database.factory_recipes,database.factory_grid_rules)
	var recipe: Dictionary = database.factory_recipes["dsp_accumulator_charge"]
	var entity := {"recipe_id":"dsp_accumulator_charge", "inputs":{"dsp_accumulator":4,"dsp_proliferator_mk3":1}, "proliferator":{"tier":3,"mode":"EXTRA","item_id":"dsp_proliferator_mk3","spray_points_per_item":60,"extra_product_bonus":0.25}}
	var plan := grid.DspProduction.planned_outputs(entity, recipe, 4)
	_check(plan["total_outputs"].get("dsp_charged_accumulator") == 4 and plan["extra_outputs"].is_empty(), "charging may not proliferate free batteries or stored energy")
	entity["recipe_id"] = "dsp_iron_ingot"
	entity["inputs"]["iron_ore"] = 4
	var ordinary_recipe: Dictionary = database.factory_recipes["dsp_iron_ingot"]
	_check(is_equal_approx(grid.DspProduction.proliferation_power_multiplier(entity,ordinary_recipe),2.5), "Mk.III spray uses the source 2.5x energy demand")
	entity["proliferator"]["mode"] = "SPEED"
	entity["progress"] = 0.8
	grid._disable_spray_service(entity)
	_check(entity["progress"] == 0.0 and entity["proliferator"]["mode"] == "NORMAL", "disabling spray cannot retain accelerated unpaid partial work")
	var world := grid.create_world("spray-dispatch", "", Vector2i(256,160))
	grid.place_entity_immediate(world,"grid_dsp_spray_coater",Vector2i(10,20),"","coater")
	grid.place_entity_immediate(world,"grid_dsp_arc_smelter",Vector2i(60,20),"dsp_iron_ingot","machine")
	var roads: Array = []
	for x in range(10,61):
		roads.append({"x":x,"y":19})
	grid.edit_roads(world,roads)
	world["entities"]["coater"]["power_factor"] = 1.0
	world["entities"]["machine"]["inputs"]["dsp_proliferator_mk3"] = 1
	grid._refresh_spray_services(world,{},false)
	_check(world["spray_services"].is_empty(), "post-dispatch validation cannot activate an unpaid spray service")
	grid._refresh_spray_services(world,{})
	_check(world["spray_services"].has("machine") and world["entities"]["machine"].get("proliferator",{}).get("tier") == 3, "next pre-dispatch phase enables the reachable spray tier before charging demand")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_project_application_guard() -> void:
	var game: Node = root.get_node("Game")
	game.state = SpaceGameState.create_new(database.domains.keys(),database.regions)
	game.simulation = SimulationEngine.new(database)
	game.simulation.ensure_frontier_state(game.state)
	for technology_id in database.technologies:
		game.state.technologies[technology_id] = true
	var world: Dictionary = game.state.factory_worlds["earth-surface-grid"]
	world["starter_package_delivered"] = true
	var grid: FactoryGridSimulation = game.simulation.factory_grid
	grid.place_entity_immediate(world,"grid_dsp_micro_black_hole_connector",Vector2i(0,0),"","sink")
	var before: Dictionary = game.state.to_dictionary().duplicate(true)
	var intent := {"protocol_version":1,"world_id":"earth-surface-grid","command_id":"destroy-unconfirmed","base_topology_revision":int(world["topology_revision"]),"kind":"SET_RECIPE","payload":{"entity_id":"sink","recipe_id":"dsp_black_hole_destroy_iron_ore"}}
	var rejected: Dictionary = game.execute_factory_command(intent)
	_check(not rejected.get("accepted",false) and rejected.get("reason_code") == "DESTRUCTION_CONFIRMATION_REQUIRED" and game.state.to_dictionary() == before,"unconfirmed destructive recipe is rejected atomically at application boundary")
	intent["command_id"] = "destroy-confirmed"
	intent["payload"]["confirm_destroy"] = true
	var accepted: Dictionary = game.execute_factory_command(intent)
	_check(accepted.get("accepted",false),"explicit confirmation authorizes only the selected sink recipe")
	world = game.state.factory_worlds["earth-surface-grid"]
	world["entities"]["sink"]["inputs"]["iron_ore"] = 1
	var events: Array[Dictionary] = []
	grid._run_machines(world,1.0,{"sink":1.0},events)
	_check(world["entities"]["sink"]["inputs"]["iron_ore"] == 0 and world["statistics"]["consumed"].get("iron_ore",0) == 1 and world["dsp_effects"].get("destroyed",{}).get("iron_ore",0) == 1,"authorized sink consumes and records exactly one unit, without output")
	game.state.research["matrix_work_credit_ms"] = 7000.0
	var project: Dictionary = database.research_projects.values()[0]
	game.simulation.initialize_research_program(game.state,project)
	_check(game.state.research.get("matrix_work_credit_ms",0) == 7000.0,"selecting a research program preserves previously manufactured matrix work")
