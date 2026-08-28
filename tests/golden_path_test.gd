extends Node

const MAIN_LOCATION := SpaceGameState.MAIN_BASE_LOCATION_ID

var failures: Array[String] = []
var snapshots: Array[Dictionary] = []
var blocker_history: Array[Dictionary] = []
var peak_inventory: Dictionary = {}
var production_stack: Array[String] = []
var emitted_research_state_scenarios: Dictionary = {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	_run_golden_path()
	_finish()


func _run_golden_path() -> void:
	var starter_id := _ship_id("patchwork_prospector")
	_produce_raw("mixed_raw_ore", 60)
	_build("build_orbital_foundry")
	_build("build_electronics_facility")
	_build("build_research_complex")
	_ensure_item("repair_material", 100)
	_snapshot("establish_industry")
	if _failed(): return

	_research("research_industrial_coordination")
	_build("build_earth_extraction_network")
	_snapshot("automate_earth")
	_route("lunar_route", [starter_id])
	_snapshot("reach_lunar")
	_produce_raw("mixed_raw_gas", 20)
	_ensure_item("chemical_propellant", 1000)
	_route("lunar_relay_assault", [starter_id])
	_snapshot("lunar_demo_complete")
	if _failed(): return

	_research("research_advanced_propulsion")
	_develop_ship("develop_lunar_pathfinder")
	var pathfinder_id := _ship_id("lunar_pathfinder")
	_route("asteroid_route", [pathfinder_id])
	_snapshot("reach_asteroid")
	# Build a visible O&M buffer before the fleet and remote industry expand. This
	# prevents long R&D/material campaigns from silently grounding every extractor.
	_ensure_item("repair_material", 1000)
	if _failed(): return

	_install_process("orbital_foundry", "precision_mechanics_cell")
	_refit_add(pathfinder_id, "deep_core_drill")
	_produce_raw("mixed_raw_ore", Game.state.item_quantity("mixed_raw_ore") + 20, "extract_belt_mixed_ore", pathfinder_id)
	_run_activity_once("separate_silicate_ore")
	_run_activity_once("process_silicate_ceramic")
	_install_process("electronics_facility", "cryogenic_process_unit")
	_ensure_item("superconducting_coil", 3)
	_install_process("electronics_facility", "radiation_electronics_cell")
	_ensure_item("radiation_hardened_electronics", 3)
	_research("research_heavy_industry")
	_research("research_heavy_extraction")
	_run_activity_once("separate_cobalt_ore")
	_run_activity_once("refine_cobalt")
	_install_process("orbital_foundry", "advanced_alloy_cell")
	_run_activity_once("refine_steel")
	_build("upgrade_construction_yard_ii")
	_build("build_assembly_yard")
	_build("build_repair_dock")
	_build("upgrade_starport_ii")
	_install_process("assembly_yard", "photonic_integration_line")
	_run_activity_once("fabricate_quantum_component")
	_develop_ship("develop_belt_cruiser")
	var cruiser_id := _ship_id("belt_cruiser")
	_develop_ship("develop_bulk_freighter")
	var bulk_freighter_id := _ship_id("bulk_freighter")
	_develop_ship("develop_deep_survey_vessel")
	_establish_belt_preprocessing_base(pathfinder_id, bulk_freighter_id)
	_route("belt_flagship_route", [pathfinder_id, cruiser_id])
	_snapshot("prototype_complete")
	if _failed(): return

	_route("jovian_route", [starter_id, pathfinder_id, cruiser_id])
	_uninstall_process("electronics_facility", "cryogenic_process_unit")
	_research("research_jovian_operations")
	_snapshot("open_jovian")
	_refit_add(cruiser_id, "gas_collector")
	_produce_raw("mixed_raw_gas", Game.state.item_quantity("mixed_raw_gas") + 24, "extract_jovian_mixed_gas", cruiser_id)
	_run_activity_once("separate_methane")
	_run_activity_once("refine_superalloy")
	_uninstall_process("electronics_facility", "cryogenic_process_unit")
	_install_process("electronics_facility", "fusion_component_test_rig")
	_ensure_item("fusion_service_component", 2)
	_build("build_energy_array")
	_research("research_capital_combat")
	_build("upgrade_starport_iii")
	_develop_ship("develop_mobile_constructor")
	_develop_ship("develop_jovian_battleship")
	var battleship_id := _ship_id("jovian_battleship")
	_route("outer_route", [battleship_id])
	_snapshot("open_outer")
	if _failed(): return

	_research("research_exotic_materials")
	_build("upgrade_construction_yard_iii")
	_build("build_field_engineering_complex")
	_run_activity_once("separate_exotic_crystal")
	_research("research_antimatter")
	_run_activity_once("build_antimatter_cell")
	_research("research_exotic_containment")
	_build("build_command_array")
	_build("upgrade_starport_iv")
	_develop_ship("develop_outer_titan")
	var titan_id := _ship_id("outer_titan")
	_route("deep_system_route", [titan_id])
	_snapshot("open_deep")
	if _failed(): return

	_refit_swap(titan_id, "targeting_computer", "exotic_containment")
	_refit_add(titan_id, "heavy_mining_array")
	_produce_raw("mixed_raw_gas", Game.state.item_quantity("mixed_raw_gas") + 32, "extract_deep_mixed_gas", titan_id)
	_build("build_frontier_matterworks")
	_run_activity_once("separate_dark_matter")
	_build("upgrade_research_complex")
	_prepare_stellar_program_process_stock()
	_survey_to_state("earth_sun_lagrange", LocationState.DEEP_SURVEYED)
	_research("research_megastructures")
	_emit_scenario("megastructure_site_preparation")
	_check(Game.select_megastructure_site("stellar_energy", "earth_sun_lagrange"), "the deeply surveyed Lagrange worksite is committed without free infrastructure")
	_snapshot("prepare_stellar_energy")
	if _failed(): return

	_complete_stellar_energy_megastructure()
	_snapshot("complete_stellar_energy")
	if _failed(): return

	var incomplete_goals: Array[String] = []
	for goal_value in Game.content.goals.values():
		var goal := goal_value as Dictionary
		if not _requirements_complete(goal.get("requirements", [])):
			incomplete_goals.append(str(goal.get("id", "")))
	var mega_project: Dictionary = Game.state.megastructure_projects.get("stellar_energy", {})
	_check(Game.state.game_complete and incomplete_goals.is_empty(), "a default new save completes the one-star-system industrial endgame without injected resources or unlocks: %s" % str(incomplete_goals))
	_check(Game.content.megastructures.size() == 1 and Game.state.megastructures.get("stellar_energy", false), "the Golden Path completes exactly one Megastructure")
	_check((mega_project.get("phase_history", []) as Array).size() == 8, "all eight physical Megastructure phases are recorded")
	_check(float(mega_project.get("total_cargo_transported", 0.0)) > 0.0 and not (mega_project.get("total_materials_consumed", {}) as Dictionary).is_empty(), "Megastructure statistics preserve freight and material contributions")
	_check(snapshots.size() == Game.content.goals.size(), "the no-cheat path records one development snapshot for every main goal")


func _ensure_item(item_id: String, target_quantity: int) -> void:
	if _failed() or Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity:
		return
	if item_id in ["mixed_raw_ore", "mixed_raw_gas"]:
		_produce_raw(item_id, target_quantity)
		return
	if item_id in production_stack:
		_fail("production cycle while requesting %s: %s" % [item_id, str(production_stack)])
		return
	production_stack.append(item_id)
	var producer := _available_industry_producer(item_id)
	if producer.is_empty():
		production_stack.pop_back()
		_fail("no currently executable deterministic producer for %s (need %d, have %d)" % [item_id, target_quantity, Game.state.item_quantity(item_id, MAIN_LOCATION)])
		return
	var reward_quantity := maxi(1, _entry_amount(producer.get("rewards", []), item_id))
	for _attempt in 8:
		if Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity:
			break
		var cycles := ceili(float(target_quantity - Game.state.item_quantity(item_id, MAIN_LOCATION)) / float(reward_quantity))
		var production_costs := {}
		for cost_value in producer.get("costs", []):
			var cost := cost_value as Dictionary
			production_costs[str(cost.get("item", ""))] = int(production_costs.get(str(cost.get("item", "")), 0)) + int(cost.get("quantity", 0)) * cycles
		_ensure_costs(production_costs)
		if _failed():
			production_stack.pop_back()
			return
		_run_industry(str(producer.get("id", "")), cycles)
	production_stack.pop_back()
	if not _failed() and Game.state.item_quantity(item_id, MAIN_LOCATION) < target_quantity:
		_fail("producer %s did not reach %s target %d" % [producer.get("id", "?"), item_id, target_quantity])


func _available_industry_producer(item_id: String) -> Dictionary:
	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		if str(activity.get("domain", "")) != "industry" or not bool(activity.get("repeat", true)):
			continue
		if _entry_amount(activity.get("rewards", []), item_id) <= 0:
			continue
		if Game.simulation.activity_available(Game.state, activity) and Game.simulation.facility_available(Game.state, str(activity.get("facility", ""))):
			return activity
	return {}


func _run_industry(activity_id: String, cycles: int) -> void:
	if _failed() or cycles <= 0:
		return
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	var slot := _industry_slot(str(activity.get("facility", "")))
	if slot < 0:
		_fail("industry runtime missing for %s" % activity_id)
		return
	var current: Dictionary = Game.state.industrial_operations[slot]
	if str(current.get("status", "IDLE")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(slot)
	if not _command(Game.start_industry_operation(slot, activity_id), "start Industry %s" % activity_id):
		return
	var runtime: Dictionary = Game.state.industrial_operations[slot]
	var duration := Game.simulation.effective_duration_ms(Game.state, "industry", activity, runtime)
	_advance(duration * float(cycles) + 1.0)
	runtime = Game.state.industrial_operations[slot]
	if str(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(slot)


func _run_activity_once(activity_id: String) -> void:
	if _failed() or int(Game.state.completed_activities.get(activity_id, 0)) > 0:
		return
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	_ensure_costs(_cost_dictionary(activity.get("costs", [])))
	_run_industry(activity_id, 1)
	_check(int(Game.state.completed_activities.get(activity_id, 0)) > 0, "activity completes through its real Industry command: %s" % activity_id)


func _produce_raw(item_id: String, target_quantity: int, preferred_activity_id: String = "", preferred_ship_id: String = "") -> void:
	if _failed() or Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity:
		return
	var selection := _mining_selection(item_id, preferred_activity_id, preferred_ship_id)
	if selection.is_empty():
		_fail("no available permanent extraction site and fitted ship for %s / %s; ships=%s" % [item_id, preferred_activity_id, str(Game.state.ships)])
		return
	var ship_id := str(selection.get("ship_id", ""))
	var site_id := str(selection.get("site_id", ""))
	var activity: Dictionary = selection.get("activity", {})
	var mining_location: Dictionary = Game.content.mining_locations.get(str(activity.get("location", "")), {})
	var output_location := str(mining_location.get("region", MAIN_LOCATION))
	var required_output := target_quantity - Game.state.item_quantity(item_id, MAIN_LOCATION)
	if output_location != MAIN_LOCATION:
		required_output = maxi(required_output, 8)
	var output_target := Game.state.item_quantity(item_id, output_location) + required_output
	if output_location != MAIN_LOCATION:
		Game.clear_location_logistics_policy(output_location, item_id)
		Game.clear_location_logistics_policy(MAIN_LOCATION, item_id)
	if not _command(Game.set_ship_fleet_assignment(ship_id, "mining"), "assign mining ship %s" % ship_id):
		return
	if not _command(Game.start_extraction_operation(site_id, [ship_id]), "start extraction %s" % site_id):
		return
	var runtime := _mining_runtime(site_id)
	var reward_quantity := maxi(1, _entry_amount(activity.get("rewards", []), item_id))
	var cycles := ceili(float(output_target - Game.state.item_quantity(item_id, output_location)) / float(reward_quantity))
	var duration := Game.simulation.effective_duration_ms(Game.state, "mining", activity, runtime)
	_advance(duration * float(cycles) + 1.0)
	for _attempt in 5:
		if Game.state.item_quantity(item_id, output_location) >= output_target:
			break
		runtime = _mining_runtime(site_id)
		duration = Game.simulation.effective_duration_ms(Game.state, "mining", activity, runtime)
		_advance(duration + 1.0)
	runtime = _mining_runtime(site_id)
	if not runtime.is_empty() and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED"]:
		Game.stop_mining_operation(int(runtime.get("slot", -1)))
	if output_location != MAIN_LOCATION:
		var batch_target := mini(target_quantity, Game.state.item_quantity(item_id, MAIN_LOCATION) + Game.state.item_quantity(item_id, output_location))
		_transfer_to_main(output_location, item_id, batch_target)
		# A surveyed frontier only has finite staging storage. Large requests are
		# therefore mined and freighted in real batches instead of accumulating in
		# an implicit unlimited remote inventory.
		if not _failed() and Game.state.item_quantity(item_id, MAIN_LOCATION) < target_quantity:
			var delivered_before_retry := Game.state.item_quantity(item_id, MAIN_LOCATION)
			_produce_raw(item_id, target_quantity, preferred_activity_id, preferred_ship_id)
			if not _failed() and Game.state.item_quantity(item_id, MAIN_LOCATION) <= delivered_before_retry:
				_fail("batched frontier extraction made no progress for %s at %s" % [item_id, output_location])
			return
	_check(Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity, "permanent extraction supplies %s target %d; have=%d activity=%s site=%s runtime=%s ship=%s" % [item_id, target_quantity, Game.state.item_quantity(item_id, MAIN_LOCATION), activity.get("id", ""), site_id, str(runtime), str(Game.state.ship_by_id(ship_id))])


func _transfer_to_main(source_location: String, item_id: String, target_quantity: int) -> void:
	if _failed() or Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity:
		return
	var route_fuel := int({"lunar_space":1, "asteroid_belt":3, "gas_giant_region":5, "outer_system":8, "deep_system":12}.get(source_location, 0))
	var route_maintenance := int({"lunar_space":1, "asteroid_belt":2, "gas_giant_region":3, "outer_system":4, "deep_system":5}.get(source_location, 0))
	if route_fuel <= 0:
		_fail("no golden-path freight fuel profile for %s" % source_location)
		return
	Game.clear_location_logistics_policy(source_location, item_id)
	Game.clear_location_logistics_policy(MAIN_LOCATION, item_id)
	for _batch in 64:
		if Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity or Game.state.item_quantity(item_id, source_location) <= 0:
			break
		if not _stage_remote_route_consumables(source_location, route_fuel, route_maintenance):
			return
		var before := Game.state.item_quantity(item_id, MAIN_LOCATION)
		var batch_capacity := _freight_quantity_capacity(source_location, MAIN_LOCATION, item_id)
		var staged_dispatches := mini(4, mini(
			int(Game.state.item_quantity("chemical_propellant", source_location) / float(route_fuel)),
			int(Game.state.item_quantity("repair_material", source_location) / float(route_maintenance))
		))
		var batch_target := mini(target_quantity, before + mini(batch_capacity * maxi(1, staged_dispatches), Game.state.item_quantity(item_id, source_location)))
		_command(Game.set_location_logistics_policy(source_location, item_id, "SUPPLY", 0, 0, 100, 1), "publish %s supply at %s" % [item_id, source_location])
		_command(Game.set_location_logistics_policy(MAIN_LOCATION, item_id, "DEMAND", 0, batch_target, 100, 1, source_location), "request %s freight batch" % item_id)
		_advance(_freight_wait_ms(source_location, MAIN_LOCATION, item_id))
		Game.clear_location_logistics_policy(source_location, item_id)
		Game.clear_location_logistics_policy(MAIN_LOCATION, item_id)
		if Game.state.item_quantity(item_id, MAIN_LOCATION) <= before:
			_fail("freight batch stalled for %s from %s; source=%d fuel=%d repair=%d path=%s" % [item_id, source_location, Game.state.item_quantity(item_id, source_location), Game.state.item_quantity("chemical_propellant", source_location), Game.state.item_quantity("repair_material", source_location), str(Game.simulation.logistics._shortest_path(Game.state, source_location, MAIN_LOCATION, item_id))])
			return
	Game.clear_location_logistics_policy(source_location, "chemical_propellant")
	Game.clear_location_logistics_policy(MAIN_LOCATION, "chemical_propellant")
	Game.clear_location_logistics_policy(source_location, "repair_material")
	Game.clear_location_logistics_policy(MAIN_LOCATION, "repair_material")


func _stage_remote_route_consumables(source_location: String, route_fuel: int, route_maintenance: int) -> bool:
	if Game.state.item_quantity("chemical_propellant", source_location) < route_fuel:
		var fuel_target := maxi(route_fuel, mini(16, route_fuel * 4))
		var fuel_cargo := fuel_target - Game.state.item_quantity("chemical_propellant", source_location)
		_ensure_bootstrap_route_stock(fuel_cargo + route_fuel + 8, route_maintenance + 8)
		if _failed(): return false
		_command(Game.set_location_logistics_policy(MAIN_LOCATION, "chemical_propellant", "SUPPLY", 0, 0, 100, 1), "publish route fuel")
		_command(Game.set_location_logistics_policy(source_location, "chemical_propellant", "DEMAND", 0, fuel_target, 100, 1, MAIN_LOCATION), "stage route fuel")
		_advance(_freight_wait_ms(MAIN_LOCATION, source_location, "chemical_propellant"))
		Game.clear_location_logistics_policy(MAIN_LOCATION, "chemical_propellant")
		Game.clear_location_logistics_policy(source_location, "chemical_propellant")
	if Game.state.item_quantity("repair_material", source_location) < route_maintenance:
		var repair_target := maxi(route_maintenance, mini(16, route_maintenance * 4))
		var repair_cargo := repair_target - Game.state.item_quantity("repair_material", source_location)
		_ensure_bootstrap_route_stock(route_fuel + 8, repair_cargo + route_maintenance + 12)
		if _failed(): return false
		_command(Game.set_location_logistics_policy(MAIN_LOCATION, "repair_material", "SUPPLY", 0, 0, 100, 1), "publish route maintenance")
		_command(Game.set_location_logistics_policy(source_location, "repair_material", "DEMAND", 0, repair_target, 100, 1, MAIN_LOCATION), "stage route maintenance")
		_advance(_freight_wait_ms(MAIN_LOCATION, source_location, "repair_material"))
		Game.clear_location_logistics_policy(MAIN_LOCATION, "repair_material")
		Game.clear_location_logistics_policy(source_location, "repair_material")
	if Game.state.item_quantity("chemical_propellant", source_location) < route_fuel or Game.state.item_quantity("repair_material", source_location) < route_maintenance:
		_fail("route consumables cannot be staged at %s; fuel=%d/%d repair=%d/%d" % [source_location, Game.state.item_quantity("chemical_propellant", source_location), route_fuel, Game.state.item_quantity("repair_material", source_location), route_maintenance])
		return false
	return true


func _ensure_bootstrap_route_stock(fuel_quantity: int, repair_quantity: int) -> void:
	if "chemical_propellant" in production_stack and Game.state.available_item_quantity("chemical_propellant", MAIN_LOCATION) < fuel_quantity:
		var cycles := ceili(float(fuel_quantity + 10 - Game.state.available_item_quantity("chemical_propellant", MAIN_LOCATION)) / 2.0)
		_ensure_costs({"iron_ingot":cycles * 2, "electronics":cycles})
		_run_industry("manufacture_emergency_propellant", cycles)
	if "chemical_propellant" in production_stack:
		_ensure_costs({"repair_material":repair_quantity})
	else:
		_ensure_costs({"chemical_propellant":fuel_quantity, "repair_material":repair_quantity})


func _freight_quantity_capacity(origin: String, destination: String, item_id: String) -> int:
	var path: Dictionary = Game.simulation.logistics._shortest_path(Game.state, origin, destination, item_id)
	if path.is_empty():
		return 1
	var result := 2147483647
	for route_id_value in path.get("route_ids", []):
		var route_id := str(route_id_value)
		var freight_units := maxf(0.001, float(path.get("route_freight_units_per_item", {}).get(route_id, 1.0)))
		result = mini(result, int(floor(Game.simulation.logistics.service_capacity(Game.state, route_id) / freight_units)))
	var hub_units := maxf(0.001, float(path.get("hub_freight_units_per_item", 1.0)))
	for node_id_value in path.get("nodes", []):
		var node_id := str(node_id_value)
		result = mini(result, int(floor(float(Game.state.location_state(node_id).get("logistics", {}).get("hub_throughput", 0.0)) / hub_units)))
	return maxi(1, result if result != 2147483647 else 1)


func _freight_wait_ms(origin: String, destination: String, item_id: String) -> float:
	var path: Dictionary = Game.simulation.logistics._shortest_path(Game.state, origin, destination, item_id)
	return maxf(30000.0, float(path.get("transit_time_ms", 0.0)) + 30000.0)


func _mining_selection(item_id: String, preferred_activity_id: String, preferred_ship_id: String) -> Dictionary:
	for site_id_value in Game.content.mining_sites.keys():
		var site_id := str(site_id_value)
		if not Game.state.mining_site_available(site_id):
			continue
		var activity: Dictionary = Game.content.get_mining_activity_for_site(site_id)
		if activity.is_empty() or _entry_amount(activity.get("rewards", []), item_id) <= 0:
			continue
		if not preferred_activity_id.is_empty() and str(activity.get("id", "")) != preferred_activity_id:
			continue
		for ship_value in Game.state.ships:
			var ship := ship_value as Dictionary
			var ship_id := str(ship.get("instance_id", ""))
			if not preferred_ship_id.is_empty() and ship_id != preferred_ship_id:
				continue
			if Game.state.ship_is_docked(ship_id) and Game.simulation.mining_power(Game.state, [ship_id]) > 0.0 and Game.simulation.build_requirements_met(Game.state, activity, [ship_id]):
				return {"site_id":site_id, "ship_id":ship_id, "activity":activity}
	return {}


func _build(activity_id: String) -> void:
	if _failed() or int(Game.state.completed_activities.get(activity_id, 0)) > 0:
		return
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	_ensure_costs(_cost_dictionary(activity.get("costs", [])))
	if not _command(Game.start_construction_project(activity_id), "queue Construction %s" % activity_id):
		return
	_advance(maxf(1000.0, float(activity.get("duration_ms", 1000.0)) * 2.0))
	_check(int(Game.state.completed_activities.get(activity_id, 0)) > 0, "construction completes through the shared project queue: %s" % activity_id)


func _research(project_id: String) -> void:
	if _failed() or bool(Game.state.completed_projects.get(project_id, false)):
		return
	print("GOLDEN: starting R&D %s" % project_id)
	var project: Dictionary = Game.content.research_projects.get(project_id, {})
	var committed_costs := {}
	var plan_id := str(project.get("grants_ship_plan", ""))
	if not plan_id.is_empty():
		var plan: Dictionary = Game.content.ship_construction_projects.get(plan_id, {})
		var ship_costs: Dictionary = Game.simulation.ship_construction_material_totals(plan)
		for fixed_value in plan.get("fixed_costs", []):
			var fixed := fixed_value as Dictionary
			ship_costs[str(fixed.get("item", ""))] = int(ship_costs.get(str(fixed.get("item", "")), 0)) + int(fixed.get("quantity", 0))
		for item_id_value in ship_costs.keys():
			var item_id := str(item_id_value)
			committed_costs[item_id] = int(committed_costs.get(item_id, 0)) + int(ship_costs[item_id])
	_ensure_costs(committed_costs)
	if not _command(Game.start_research_project(project_id), "start Research %s" % project_id):
		return
	for _attempt in 20:
		if bool(Game.state.completed_projects.get(project_id, false)) or _failed():
			break
		var stage := Game.simulation.research_stage_definition(Game.state, project, int(Game.state.research.get("stage_index", 0)), str(Game.state.research.get("route_id", "")))
		if stage.is_empty():
			_advance(1.0)
			continue
		_capture_research_state_scenario()
		for requirement_value in stage.get("requirements", []):
			var requirement := requirement_value as Dictionary
			if Game.simulation.requirement_met(Game.state, requirement):
				continue
			match str(requirement.get("type", "")):
				"activity_complete":
					_run_activity_once(str(requirement.get("id", "")))
				"route_complete":
					var route_id := str(requirement.get("id", ""))
					var candidates := _docked_route_candidates(route_id)
					if candidates.is_empty():
						_fail("no docked real ship can execute R&D Field Test route %s" % route_id)
					else:
						_route(route_id, candidates)
				"manufacturing_module_installed":
					_install_process(str(requirement.get("facility", "")), str(requirement.get("id", "")))
				"own_facility":
					var facility_id := str(requirement.get("id", ""))
					for activity_value in Game.content.activities.values():
						var activity := activity_value as Dictionary
						if activity.get("effects", []).any(func(effect): return str((effect as Dictionary).get("type", "")) == "unlock_facility" and str((effect as Dictionary).get("facility", "")) == facility_id):
							_build(str(activity.get("id", "")))
							break
				"item":
					_ensure_item(str(requirement.get("id", "")), int(requirement.get("quantity", 1)))
		if _failed(): return
		_ensure_research_stage_costs(_cost_dictionary(stage.get("costs", [])))
		if _failed(): return
		for condition_value in stage.get("operating_conditions", []):
			if not Game.simulation.requirement_met(Game.state, condition_value as Dictionary):
				_fail("R&D Operating Condition is not met for %s / %s: %s" % [project_id, stage.get("id", ""), str(condition_value)])
				return
		var work := maxf(1.0, float(stage.get("work_required", 1.0)))
		_advance(work / maxf(0.01, Game.simulation.research_capacity(Game.state)) * 2.0 + 1.0)
	_check(bool(Game.state.completed_projects.get(project_id, false)), "R&D Program completes through real stage supplies, facilities and Field Tests: %s" % project_id)
	if not _failed(): print("GOLDEN: completed R&D %s" % project_id)


func _capture_research_state_scenario() -> void:
	_advance(1.0)
	var gameplay_state := Game.simulation.research_gameplay_state(Game.state)
	if gameplay_state not in ["WAITING_FACILITY", "WAITING_KNOWLEDGE", "WAITING_PROTOTYPE", "WAITING_FIELD_TEST"] or emitted_research_state_scenarios.has(gameplay_state):
		return
	emitted_research_state_scenarios[gameplay_state] = true
	_emit_scenario("research_%s" % gameplay_state.to_lower())


func _develop_ship(project_id: String) -> void:
	print("GOLDEN: developing ship project %s" % project_id)
	_research(project_id)
	if _failed(): return
	var project: Dictionary = Game.content.research_projects.get(project_id, {})
	var plan_id := str(project.get("grants_ship_plan", ""))
	var plan: Dictionary = Game.content.ship_construction_projects.get(plan_id, {})
	var ship_model := str(plan.get("ship_id", ""))
	var ship_costs: Dictionary = Game.simulation.ship_construction_material_totals(plan)
	for fixed_value in plan.get("fixed_costs", []):
		var fixed := fixed_value as Dictionary
		var item_id := str(fixed.get("item", ""))
		ship_costs[item_id] = int(ship_costs.get(item_id, 0)) + int(fixed.get("quantity", 0))
	_ensure_costs(ship_costs)
	if Game.simulation.shipyard_queue_index(Game.state, plan_id) > 0:
		_command(Game.move_shipyard_project(plan_id, 0), "prioritize required Shipyard plan %s" % plan_id)
	for _attempt in 5:
		if Game.state.owns_ship_model(ship_model):
			break
		_advance(maxf(10000.0, float(plan.get("cycle_time_ms", 1000.0)) * 25.0))
	_check(Game.state.owns_ship_model(ship_model), "Shipyard builds the researched physical ship: %s" % ship_model)
	if not _failed(): print("GOLDEN: commissioned ship %s" % ship_model)


func _install_process(facility_id: String, module_id: String) -> void:
	if _failed() or module_id in Game.state.facilities.get(facility_id, {}).get("installed_process_modules", []):
		return
	var definition: Dictionary = Game.content.process_modules.get(module_id, {})
	_ensure_costs(_cost_dictionary(definition.get("costs", [])))
	_command(Game.install_manufacturing_module(facility_id, module_id, "process"), "install process %s / %s" % [facility_id, module_id])


func _uninstall_process(facility_id: String, module_id: String) -> void:
	if _failed() or module_id not in Game.state.facilities.get(facility_id, {}).get("installed_process_modules", []):
		return
	_command(Game.uninstall_manufacturing_module(facility_id, module_id, "process"), "uninstall process %s / %s" % [facility_id, module_id])


func _refit_add(ship_id: String, module_id: String) -> void:
	if _failed(): return
	var ship := Game.state.ship_by_id(ship_id)
	var desired: Array = Game.state.ship_module_definition_ids(ship)
	if module_id in desired:
		return
	desired.append(module_id)
	_ensure_costs(Game.simulation.loadout_fabrication_costs(desired))
	if not _command(Game.begin_ship_refit(ship_id, desired), "refit %s with %s" % [ship_id, module_id]):
		return
	for _attempt in 20:
		if module_id in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)):
			break
		_advance(100000.0)
	_check(module_id in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)), "real Starport refit installs capability module %s" % module_id)


func _refit_swap(ship_id: String, remove_module_id: String, add_module_id: String) -> void:
	if _failed(): return
	var desired: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	desired.erase(remove_module_id)
	if add_module_id not in desired:
		desired.append(add_module_id)
	_ensure_costs(Game.simulation.loadout_fabrication_costs(desired))
	if not _command(Game.begin_ship_refit(ship_id, desired), "refit %s: %s → %s" % [ship_id, remove_module_id, add_module_id]):
		return
	for _attempt in 20:
		if add_module_id in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)):
			break
		_advance(100000.0)
	_check(add_module_id in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)), "real Starport refit swaps the configured utility module to %s" % add_module_id)


func _docked_route_candidates(route_id: String) -> Array:
	var result: Array = []
	var route: Dictionary = Game.content.expedition_routes.get(route_id, {})
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := str(ship.get("instance_id", ""))
		if not Game.state.ship_is_docked(ship_id):
			continue
		var valid := true
		for node_value in route.get("nodes", []):
			if not Game.simulation.build_requirements_met(Game.state, node_value as Dictionary, [ship_id]):
				valid = false
				break
		if valid:
			result.append(ship_id)
			break
	return result


func _route(route_id: String, ship_ids: Array) -> void:
	if _failed() or int(Game.state.completed_activities.get("route:%s" % route_id, 0)) > 0:
		return
	_ensure_item("kinetic_munitions", 120)
	_ensure_item("repair_supplies", 20)
	var route: Dictionary = Game.content.expedition_routes.get(route_id, {})
	var propellant_target := int(route.get("fuel_cost", 0))
	var current_plan: Dictionary = Game.state.fleet_logistics_runtime("expedition").get("supply_plan", {})
	# Consecutive routes can legitimately require the same exact target. The
	# player command rejects unchanged values, so preserve the already-valid plan
	# instead of treating domain-level idempotence as a Golden Path failure.
	if int(current_plan.get("chemical_propellant", -1)) != propellant_target:
		_command(Game.set_fleet_supply_plan("chemical_propellant", propellant_target), "set exact route propellant plan for %s" % route_id)
	for ship_id_value in ship_ids:
		if not _command(Game.set_ship_fleet_assignment(str(ship_id_value), "expedition"), "assign Expedition ship %s" % ship_id_value):
			return
	if not _command(Game.start_expedition_route(route_id, ship_ids), "launch route %s" % route_id):
		return
	_advance(1000000.0)
	if int(Game.state.completed_activities.get("route:%s" % route_id, 0)) <= 0:
		var report: Dictionary = Game.state.expedition_reports[-1] if not Game.state.expedition_reports.is_empty() else {}
		_fail("route %s failed: %s / %s" % [route_id, report.get("result", "NO_REPORT"), report.get("reason", Game.last_notice)])
		return
	var survey_target := str({"lunar_route":"lunar_space", "asteroid_route":"asteroid_belt", "jovian_route":"gas_giant_region", "outer_route":"outer_system", "deep_system_route":"deep_system"}.get(route_id, ""))
	if not survey_target.is_empty():
		_survey_to_investment_grade(survey_target)


func _survey_to_investment_grade(location_id: String) -> void:
	if _failed(): return
	Game.simulation.ensure_frontier_state(Game.state)
	for target_state in [LocationState.DETECTED, LocationState.SURVEYED]:
		var current_state := str(Game.state.location_state(location_id).get("survey_state", LocationState.UNKNOWN))
		if Game.simulation.survey_state_rank(current_state) >= Game.simulation.survey_state_rank(target_state):
			continue
		var capability := str(Game.content.survey_rules.get("required_capabilities", {}).get(target_state, ""))
		var selected_ship_id := ""
		for ship_value in Game.state.ships:
			var ship := ship_value as Dictionary
			var ship_id := str(ship.get("instance_id", ""))
			if Game.state.ship_is_docked(ship_id) and Game.simulation.capability_value_for_ships(Game.state, capability, [ship_id]) >= 1.0:
				selected_ship_id = ship_id
				break
		if selected_ship_id.is_empty():
			_fail("no fitted Survey Vessel can advance %s to %s" % [location_id, target_state])
			return
		_ensure_costs(Game.simulation.survey_mission_costs(target_state))
		if not _command(Game.start_survey_mission(location_id, target_state, [selected_ship_id]), "survey %s to %s" % [location_id, target_state]):
			return
		_advance(float(Game.state.survey_mission.get("duration_ms", 1.0)) + 1.0)
		_check(str(Game.state.location_state(location_id).get("survey_state", "")) == target_state, "real Survey Mission exposes investment-grade data for %s" % location_id)


func _survey_to_state(location_id: String, target_state: String) -> void:
	if _failed(): return
	Game.simulation.ensure_frontier_state(Game.state)
	var order: Array = Game.content.survey_rules.get("state_order", [LocationState.UNKNOWN, LocationState.DETECTED, LocationState.SURVEYED, LocationState.DEEP_SURVEYED])
	for state_value in order:
		var next_state := str(state_value)
		if Game.simulation.survey_state_rank(next_state) <= Game.simulation.survey_state_rank(str(Game.state.location_state(location_id).get("survey_state", LocationState.UNKNOWN))):
			continue
		if Game.simulation.survey_state_rank(next_state) > Game.simulation.survey_state_rank(target_state):
			break
		var capability := str(Game.content.survey_rules.get("required_capabilities", {}).get(next_state, ""))
		var selected_ship_id := ""
		for ship_value in Game.state.ships:
			var ship := ship_value as Dictionary
			var ship_id := str(ship.get("instance_id", ""))
			if Game.state.ship_is_docked(ship_id) and Game.simulation.capability_value_for_ships(Game.state, capability, [ship_id]) >= 1.0:
				selected_ship_id = ship_id
				break
		if selected_ship_id.is_empty():
			_fail("no physical Survey Vessel has %s for %s" % [capability, next_state])
			return
		_ensure_costs(Game.simulation.survey_mission_costs(next_state))
		if not _command(Game.start_survey_mission(location_id, next_state, [selected_ship_id]), "survey %s to %s" % [location_id, next_state]):
			return
		_advance(float(Game.state.survey_mission.get("duration_ms", 1.0)) + 1.0)
	_check(str(Game.state.location_state(location_id).get("survey_state", "")) == target_state, "Survey Mission reaches %s at %s through ship, fuel and maintenance" % [target_state, location_id])


func _establish_belt_preprocessing_base(mining_ship_id: String, bulk_freighter_id: String) -> void:
	if _failed(): return
	print("GOLDEN: developing permanent Belt extraction site")
	var location_id := "asteroid_belt"
	var site_id := "belt_cobalt_frontier"
	var development_costs: Dictionary = _cost_dictionary(Game.content.survey_rules.get("site_development", {}).get("costs", []))
	_ensure_costs(development_costs)
	if not _command(Game.queue_site_development(site_id, "fixed_excavation", 90), "queue Belt Site Development"):
		return
	_complete_remote_construction(location_id, "SITE_DEVELOPMENT", site_id)
	if _failed(): return

	print("GOLDEN: constructing Belt preprocessing Factory")
	var expansion_costs: Dictionary = Game.simulation.industry_expansion_costs(Game.state, location_id, "makeshift_workshop", 1)
	_ensure_costs(expansion_costs)
	if not _command(Game.queue_facility_expansion(location_id, "makeshift_workshop", 1, 90), "queue Belt preprocessing Factory"):
		return
	_complete_remote_construction(location_id, "FACILITY_EXPANSION", "makeshift_workshop")
	if _failed(): return
	_check(Game.configure_logistics_service("lunar_belt_freight", "bulk_tug", [bulk_freighter_id], "BULK_FIRST"), "the completed mixed-cargo buildout hands the Belt trunk to a physical bulk freighter")
	if _failed(): return

	var remote_before := Game.state.item_quantity("mixed_raw_ore", location_id)
	if not _command(Game.set_ship_fleet_assignment(mining_ship_id, "mining"), "assign Belt preprocessing feedstock ship"):
		return
	if not _command(Game.start_extraction_operation(site_id, [mining_ship_id]), "start fixed-site Belt feedstock extraction"):
		return
	var mining_runtime := _mining_runtime(site_id)
	var mining_activity: Dictionary = Game.content.get_mining_activity_for_site(site_id)
	_advance(Game.simulation.effective_duration_ms(Game.state, "mining", mining_activity, mining_runtime) * 8.0 + 1.0)
	mining_runtime = _mining_runtime(site_id)
	if not mining_runtime.is_empty() and str(mining_runtime.get("status", "")) in ["RUNNING", "BLOCKED"]:
		Game.stop_mining_operation(int(mining_runtime.get("slot", -1)))
	_check(Game.state.item_quantity("mixed_raw_ore", location_id) > remote_before, "the developed Belt site extracts into Belt inventory")
	if _failed(): return

	var iron_before := Game.state.item_quantity("iron_ore", location_id)
	_run_industry_at("separate_iron_ore", 4, location_id)
	_check(Game.state.item_quantity("iron_ore", location_id) > iron_before, "the real Belt Factory preprocesses ore locally")
	var main_iron_target := Game.state.item_quantity("iron_ore", MAIN_LOCATION) + 4
	_transfer_to_main(location_id, "iron_ore", main_iron_target)
	_check(Game.state.item_quantity("iron_ore", MAIN_LOCATION) >= main_iron_target, "preprocessed Belt ore uses the physical freight network instead of raw direct haul")
	# Restore mixed-cargo service for later precision and cryogenic freight. The
	# physical Bulk Tug remains owned and can be reassigned when bulk pressure is
	# again the dominant bottleneck.
	_check(Game.configure_logistics_service("lunar_belt_freight", "general_cargo", [], "DEMAND_PRIORITY"), "the Belt trunk can be deliberately returned to mixed-cargo service")


func _run_industry_at(activity_id: String, cycles: int, location_id: String) -> void:
	if _failed() or cycles <= 0: return
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	var slot := _industry_slot_at(str(activity.get("facility", "")), location_id)
	if slot < 0:
		_fail("location Industry runtime missing for %s at %s" % [activity_id, location_id])
		return
	var runtime: Dictionary = Game.state.industrial_operations[slot]
	if str(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(slot)
	if not _command(Game.start_industry_operation(slot, activity_id), "start %s at %s" % [activity_id, location_id]):
		return
	runtime = Game.state.industrial_operations[slot]
	_advance(Game.simulation.effective_duration_ms(Game.state, "industry", activity, runtime) * float(cycles) + 1.0)
	runtime = Game.state.industrial_operations[slot]
	if str(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(slot)


func _complete_remote_construction(location_id: String, project_type: String, target_id: String) -> void:
	if _failed(): return
	var material_plan := _active_construction_material_plan(location_id, project_type, target_id)
	if material_plan.is_empty():
		_fail("remote Construction project was not registered: %s / %s" % [project_type, target_id])
		return
	var supply_stock := {}
	for item_id_value in material_plan.keys():
		var item_id := str(item_id_value)
		supply_stock[item_id] = int(material_plan[item_id]) + maxi(4, ceili(float(material_plan[item_id]) * 0.1))
	_ensure_item("chemical_propellant", Game.state.item_quantity("chemical_propellant", MAIN_LOCATION) + 160)
	_ensure_item("repair_material", Game.state.item_quantity("repair_material", MAIN_LOCATION) + 80)
	# Route operating stock is prepared first because its own recipes can consume
	# the same metals/components as the project BOM.
	_ensure_costs(supply_stock)
	for item_id_value in material_plan.keys():
		var item_id := str(item_id_value)
		_command(Game.set_location_logistics_policy(MAIN_LOCATION, item_id, "SUPPLY", 0, 0, 100, 1), "publish remote project supply %s" % item_id)
	_command(Game.set_location_logistics_policy(MAIN_LOCATION, "repair_material", "SUPPLY", 20, 0, 100, 1), "publish remote maintenance supply")
	for _attempt in 180:
		if _active_construction_material_plan(location_id, project_type, target_id).is_empty():
			break
		if _attempt > 0 and _attempt % 30 == 0:
			var progress_runtime := _active_construction_runtime(location_id, project_type, target_id)
			print("GOLDEN: %s %s progress %.1f/%.1f blocker=%s" % [project_type, target_id, float(progress_runtime.get("completed_work", 0.0)), float(progress_runtime.get("total_work", 0.0)), str(progress_runtime.get("blocker", {}).get("primary_reason", ""))])
		_advance(60000.0)
	for item_id_value in material_plan.keys():
		Game.clear_location_logistics_policy(MAIN_LOCATION, str(item_id_value))
	Game.clear_location_logistics_policy(MAIN_LOCATION, "repair_material")
	if not _active_construction_material_plan(location_id, project_type, target_id).is_empty():
		var runtime := _active_construction_runtime(location_id, project_type, target_id)
		_fail("remote Construction did not complete: %s / %s blocker=%s inventory=%s shipments=%s" % [project_type, target_id, str(runtime.get("blocker", {})), str(Game.state.location_inventory(location_id)), str(Game.state.logistics_network.get("shipments", []))])


func _complete_stellar_energy_megastructure() -> void:
	if _failed(): return
	var site_id := "earth_sun_lagrange"
	var definition: Dictionary = Game.content.megastructures.get("stellar_energy", {})
	var phases: Array = definition.get("phases", [])
	# Preserve the legal pre-construction state as Phase 1. Later snapshots are
	# emitted only after the preceding phase transaction has completed.
	_emit_scenario("megastructure_phase_1")
	while int(Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_index", 0)) < phases.size():
		var phase_index := int(Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_index", 0))
		if phase_index == 4:
			_upgrade_remote_capacity(site_id, "POWER_UPGRADE", 300)
			_upgrade_remote_capacity(site_id, "COOLING_UPGRADE", 300)
			if _failed(): return
		if phase_index == 7:
			_stage_location_maintenance(site_id)
			if _failed(): return
		var phase: Dictionary = phases[phase_index]
		var activity_id := str(phase.get("activity_id", ""))
		print("GOLDEN: preparing Megastructure phase %d / %s" % [phase_index, activity_id])
		var activity: Dictionary = Game.content.activities.get(activity_id, {})
		var costs := _cost_dictionary(activity.get("costs", []))
		_ensure_costs(costs)
		_ensure_item("chemical_propellant", Game.state.item_quantity("chemical_propellant", MAIN_LOCATION) + 600)
		_ensure_item("repair_material", Game.state.item_quantity("repair_material", MAIN_LOCATION) + 300)
		if not _command(Game.start_megastructure_phase("stellar_energy", 100), "start Megastructure phase %d / %s" % [phase_index, activity_id]):
			return
		_complete_remote_construction(site_id, "MEGASTRUCTURE", activity_id)
		if _failed(): return
		_check(int(Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_index", 0)) == phase_index + 1, "Megastructure phase advances exactly once: %s" % activity_id)
		_emit_scenario("megastructure_phase_%d" % (phase_index + 1))
	_check(Game.state.game_complete and bool(Game.state.megastructures.get("stellar_energy", false)), "Commissioning completes the single-system game")


func _prepare_stellar_program_process_stock() -> void:
	# The Electronics Facility has finite process slots. Build the long-lived
	# superconducting stock first, then return the line to fusion engineering for
	# program operation and commissioning supplies.
	_uninstall_process("electronics_facility", "fusion_component_test_rig")
	_install_process("electronics_facility", "cryogenic_process_unit")
	_ensure_item("superconducting_coil", 150)
	_uninstall_process("electronics_facility", "cryogenic_process_unit")
	_install_process("electronics_facility", "fusion_component_test_rig")
	_ensure_item("fusion_service_component", 40)


func _stage_location_maintenance(location_id: String) -> void:
	Game.simulation.refresh_demand_registry(Game.state)
	var requirements := {}
	for source_value in Game.state.demand_registry.get("sources", {}).values():
		var source := source_value as Dictionary
		if str(source.get("consumer_type", "")) != "facility_om" or str(source.get("location_id", "")) != location_id:
			continue
		var item_id := str(source.get("product_id", ""))
		requirements[item_id] = int(requirements.get(item_id, 0)) + maxi(10, ceili(float(source.get("rate_per_hour", 0.0)) * 48.0))
	for item_id_value in requirements.keys():
		var item_id := str(item_id_value)
		var quantity := int(requirements[item_id])
		_ensure_bootstrap_route_stock(20, 20)
		_ensure_item(item_id, Game.state.item_quantity(item_id, MAIN_LOCATION) + quantity)
		if _failed(): return
		var target := Game.state.item_quantity(item_id, location_id) + quantity
		_command(Game.set_location_logistics_policy(MAIN_LOCATION, item_id, "SUPPLY", 0, 0, 100, 1), "publish worksite O&M %s" % item_id)
		_command(Game.set_location_logistics_policy(location_id, item_id, "DEMAND", 0, target, 100, 1, MAIN_LOCATION), "stage worksite O&M %s" % item_id)
		_advance(_freight_wait_ms(MAIN_LOCATION, location_id, item_id))
		Game.clear_location_logistics_policy(MAIN_LOCATION, item_id)
		Game.clear_location_logistics_policy(location_id, item_id)
		_check(Game.state.item_quantity(item_id, location_id) > 0, "normal freight supplies worksite O&M item %s" % item_id)
		if _failed(): return
	# Low-rate electronics demand may need several hours before it crosses a whole
	# inventory unit. Continue real settlements until every worksite O&M stream has
	# replaced stale zero-coverage history.
	for _settlement in 6:
		_advance(36000000.0)
		if Game.simulation._location_maintenance_coverage(Game.state, location_id) >= 0.75:
			break
	print("GOLDEN: worksite maintenance coverage %.2f" % Game.simulation._location_maintenance_coverage(Game.state, location_id))


func _upgrade_remote_capacity(location_id: String, project_type: String, target_value: int) -> void:
	if _failed(): return
	if not _command(Game.queue_location_capacity_upgrade(location_id, project_type, target_value, 100), "queue %s at Megastructure site" % project_type):
		return
	_complete_remote_construction(location_id, project_type, str({"POWER_UPGRADE":"power_capacity", "COOLING_UPGRADE":"cooling_capacity"}.get(project_type, "")))


func _active_construction_material_plan(location_id: String, project_type: String, target_id: String) -> Dictionary:
	var runtime := _active_construction_runtime(location_id, project_type, target_id)
	return (runtime.get("material_plan", {}) as Dictionary).duplicate(true) if not runtime.is_empty() else {}


func _active_construction_runtime(location_id: String, project_type: String, target_id: String) -> Dictionary:
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("location_id", "")) != location_id or str(runtime.get("project_type", "")) != project_type:
			continue
		if not target_id.is_empty() and str(runtime.get("target_id", "")) != target_id and str(runtime.get("activity_id", "")) != target_id:
			continue
		if str(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			return runtime
	return {}


func _advance(elapsed_ms: float) -> void:
	if _failed(): return
	Game.simulation.advance(Game.state, elapsed_ms)
	for item_id_value in Game.state.location_inventory(MAIN_LOCATION).keys():
		var item_id := str(item_id_value)
		peak_inventory[item_id] = maxi(int(peak_inventory.get(item_id, 0)), Game.state.item_quantity(item_id, MAIN_LOCATION))
	_capture_blockers()


func _capture_blockers() -> void:
	var entries: Array = []
	entries.append_array(Game.state.mining_operations)
	entries.append_array(Game.state.industrial_operations)
	entries.append_array(Game.state.construction_operations)
	entries.append_array(Game.state.shipyard_queue)
	entries.append(Game.state.research)
	for runtime_value in entries:
		var runtime := runtime_value as Dictionary
		var blocker: Dictionary = runtime.get("blocker", {})
		if blocker.is_empty():
			continue
		var signature := "%s:%s:%s" % [blocker.get("domain", ""), blocker.get("primary_reason", ""), blocker.get("item_id", blocker.get("facility_id", ""))]
		if blocker_history.any(func(existing): return str((existing as Dictionary).get("signature", "")) == signature):
			continue
		var record := blocker.duplicate(true)
		record["signature"] = signature
		record["at_ms"] = int(Game.state.total_elapsed_ms)
		blocker_history.append(record)


func _snapshot(goal_id: String) -> void:
	if _failed(): return
	var goal: Dictionary = Game.content.goals.get(goal_id, {})
	if goal.is_empty() or not _requirements_complete(goal.get("requirements", [])):
		_fail("goal snapshot %s is not complete; Guide next step is unresolved" % goal_id)
		return
	snapshots.append({
		"goal_id":goal_id,
		"completed_at_ms":int(Game.state.total_elapsed_ms),
		"inventory":Game.state.location_inventory(MAIN_LOCATION).duplicate(true),
		"blocker_count":blocker_history.size(),
		"ships":Game.state.ships.size()
	})
	print("GOLDEN: completed goal %s at %.1f simulated minutes" % [goal_id, Game.state.total_elapsed_ms / 60000.0])
	_emit_scenario(goal_id)


func _emit_scenario(scenario_id: String) -> void:
	if not OS.get_cmdline_user_args().has("--emit-scenarios"):
		return
	var directory := ProjectSettings.globalize_path("res://artifacts/ui-scenarios")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := "%s/%s.json" % [directory, scenario_id]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("cannot write generated Scenario state: %s" % path)
		return
	file.store_string(JSON.stringify({
		"scenario_id":scenario_id,
		"generated_by":"golden_path_test",
		"invariant_source":"normal_domain_commands_and_simulation",
		"state":Game.state.to_dictionary()
	}, "  "))
	file.close()
	print("SCENARIO_SAVED: res://artifacts/ui-scenarios/%s.json" % scenario_id)


func _requirements_complete(values: Array) -> bool:
	for requirement_value in values:
		if not Game.simulation.requirement_met(Game.state, requirement_value as Dictionary):
			return false
	return true


func _ensure_costs(costs: Dictionary) -> void:
	if _failed(): return
	for _attempt in 32:
		var complete := true
		for item_id_value in costs.keys():
			var item_id := str(item_id_value)
			var required := int(costs[item_id_value])
			var available := Game.state.available_item_quantity(item_id, MAIN_LOCATION)
			if available >= required:
				continue
			complete = false
			_ensure_item(item_id, Game.state.item_quantity(item_id, MAIN_LOCATION) + required - available)
			if _failed(): return
		if complete:
			return
	_fail("could not assemble simultaneous committed costs: %s" % str(costs))


func _ensure_research_stage_costs(costs: Dictionary) -> void:
	if _failed(): return
	for _attempt in 32:
		var complete := true
		for item_id_value in costs.keys():
			var item_id := str(item_id_value)
			var required := int(costs[item_id_value])
			# The active stage's own reservation is usable by that stage. Only other
			# queues and player reserves reduce the stock available to this R&D gate.
			var usable := (
				Game.state.item_quantity(item_id, MAIN_LOCATION)
				- int(Game.state.location_reserves(MAIN_LOCATION).get(item_id, 0))
				- Game.state.industrial_committed_quantity(item_id, -1, MAIN_LOCATION)
				- Game.state.construction_committed_quantity(item_id, -1, MAIN_LOCATION)
				- Game.state.shipyard_committed_quantity(item_id, "", MAIN_LOCATION)
			)
			if usable >= required:
				continue
			complete = false
			_ensure_item(item_id, Game.state.item_quantity(item_id, MAIN_LOCATION) + required - usable)
			if _failed(): return
		if complete:
			return
	_fail("could not supply active R&D stage costs: %s" % str(costs))


func _cost_dictionary(entries: Array) -> Dictionary:
	var result := {}
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := str(entry.get("item", ""))
		result[item_id] = int(result.get(item_id, 0)) + int(entry.get("quantity", 0))
	return result


func _industry_slot(facility_id: String) -> int:
	for index in Game.state.industrial_operations.size():
		if str(Game.state.industrial_operations[index].get("facility_id", "")) == facility_id and str(Game.state.industrial_operations[index].get("location_id", MAIN_LOCATION)) == MAIN_LOCATION:
			return index
	return -1


func _industry_slot_at(facility_id: String, location_id: String) -> int:
	for index in Game.state.industrial_operations.size():
		if str(Game.state.industrial_operations[index].get("facility_id", "")) == facility_id and str(Game.state.industrial_operations[index].get("location_id", MAIN_LOCATION)) == location_id:
			return index
	return -1


func _mining_runtime(site_id: String) -> Dictionary:
	for runtime_value in Game.state.mining_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("site_id", "")) == site_id:
			return runtime
	return {}


func _ship_id(model_id: String) -> String:
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		if str(ship.get("blueprint_id", "")) == model_id:
			return str(ship.get("instance_id", ""))
	_fail("required physical ship is missing: %s" % model_id)
	return ""


func _entry_amount(entries: Array, item_id: String) -> int:
	for entry_value in entries:
		var entry := entry_value as Dictionary
		if str(entry.get("item", "")) == item_id:
			return int(entry.get("quantity", 0))
	return 0


func _command(success: bool, label: String) -> bool:
	if success:
		return true
	_fail("%s rejected: %s" % [label, Game.last_notice])
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if failures.is_empty():
		failures.append(message)


func _failed() -> bool:
	return not failures.is_empty()


func _finish() -> void:
	if failures.is_empty():
		print("PASS: no-cheat golden path completed %d goals in %.1f simulated minutes; %d blocker classes observed" % [snapshots.size(), Game.state.total_elapsed_ms / 60000.0, blocker_history.size()])
		get_tree().quit(0)
		return
	push_error("GOLDEN PATH FAIL: %s" % failures[0])
	push_error("Last structured blockers: %s" % str(blocker_history.slice(maxi(0, blocker_history.size() - 5))))
	get_tree().quit(1)
