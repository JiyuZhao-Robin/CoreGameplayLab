extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content loads")
	if not failures.is_empty():
		_finish()
		return
	var simulation := SimulationEngine.new(database)
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	var ship_id := str(state.ships[0].get("instance_id", ""))
	state.region_states["earth_orbit"]["survey_state"] = LocationState.DETECTED
	state.location_state("earth_orbit")["survey_state"] = LocationState.DETECTED
	state.add_item("industrial_machine_tools", 1)
	state.add_item("structural_frame", 2)
	state.add_item("repair_material", 1)
	state.add_item("electronics", 4)

	_check(state.formation_ids() == [SpaceGameState.DEFAULT_FORMATION_ID], "new saves start with one generic tactical formation")
	_check(state.formation_ship_ids().is_empty(), "ships are not automatically classified by work type")
	state.set_formation_ship_ids("mining", [ship_id])
	_check(not state.fleet_formations.has("mining") and state.formation_runtime("mining").is_empty(), "generic APIs cannot recreate a retired work-type formation")
	_check(not simulation.start_survey_mission(state, "earth_orbit", LocationState.SURVEYED, [ship_id]), "an individually selected ship cannot bypass formation membership for exploration")

	state.set_formation_ship_ids(SpaceGameState.DEFAULT_FORMATION_ID, [ship_id])
	state.ship_by_id(ship_id)["assignment"] = {"formation_id":SpaceGameState.DEFAULT_FORMATION_ID}
	_check(state.ship_is_deployment_ready(ship_id), "formation survey ship is deployment ready")
	_check(simulation.capability_value_for_ships(state, "long_range_scan", [ship_id]) >= 1.0, "formation survey ship has long-range sensors")
	_check(simulation.survey_target_accessible(state, "earth_orbit"), "formation survey target is accessible")
	_check(state.available_item_quantity("chemical_propellant", "earth_orbit") >= 1, "formation survey fuel is available")
	for item_id_value in simulation.survey_mission_costs(LocationState.SURVEYED).keys():
		var item_id := str(item_id_value)
		_check(state.available_item_quantity(item_id) >= int(simulation.survey_mission_costs(LocationState.SURVEYED).get(item_id, 0)), "formation survey cost is available: %s" % item_id)
	_check(simulation.survey_state_rank(LocationState.SURVEYED) == simulation.survey_state_rank(str(state.location_state("earth_orbit").get("survey_state", ""))) + 1, "formation survey advances exactly one intelligence state")
	_check(state.ship_formation_id(ship_id) == SpaceGameState.DEFAULT_FORMATION_ID, "formation membership remains authoritative before survey launch")
	_check(simulation.start_survey_mission(state, "earth_orbit", LocationState.SURVEYED, [ship_id]), "a sensor-capable tactical formation can launch exploration")
	_check(str(state.survey_mission.get("formation_id", "")) == SpaceGameState.DEFAULT_FORMATION_ID, "survey mission records its operational formation")

	state.fleet_formations["task_force_2"] = {"id":"task_force_2", "name":"Second Battle Group", "ship_ids":[]}
	state.fleet_logistics_runtime("task_force_2")["formation"]["doctrine"] = "LONG_RANGE_ENGAGEMENT"
	_check(state.formation_ids().has("task_force_2") and str(state.fleet_logistics_runtime("task_force_2").get("formation", {}).get("doctrine", "")) == "LONG_RANGE_ENGAGEMENT", "multiple named formations keep independent operational doctrine")

	var persisted := state.to_dictionary()
	_check(persisted.has("fleet_formations") and not persisted.has("extraction_assets") and not persisted.has("expedition_fleet"), "current saves contain no work-type fleet authorities")
	for retired_id in ["mining_laser", "deep_core_drill", "heavy_mining_array", "gas_collector", "exotic_containment", "construction_support_system"]:
		_check(not database.modules.has(retired_id) and not database.items.has(retired_id), "deleted ship work plugin: %s" % retired_id)

	_finish()


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	failures.append(message)
	push_error("FAIL: %s" % message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: generic tactical formations and factory-only ship work boundary")
		quit(0)
	else:
		quit(1)
