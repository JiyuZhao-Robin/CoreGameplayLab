extends Node

const MAIN_LOCATION := SpaceGameState.MAIN_BASE_LOCATION_ID

var failures: Array[String] = []
var snapshots: Array[Dictionary] = []
var blocker_history: Array[Dictionary] = []
var peak_inventory: Dictionary = {}
var production_stack: Array[String] = []


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
	_route("belt_flagship_route", [pathfinder_id, cruiser_id])
	_snapshot("prototype_complete")
	if _failed(): return

	_route("jovian_route", [starter_id, pathfinder_id, cruiser_id])
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

	_refit_add(titan_id, "exotic_containment")
	_produce_raw("mixed_raw_gas", Game.state.item_quantity("mixed_raw_gas") + 32, "extract_deep_mixed_gas", titan_id)
	_build("build_frontier_matterworks")
	_run_activity_once("separate_dark_matter")
	_research("research_megastructures")
	_run_activity_once("assemble_project_core")
	_build("construct_stellar_energy")
	_build("construct_matter_extractor")
	_build("construct_autonomous_industry")
	_build("construct_deep_space_array")
	_snapshot("build_megastructures")
	if _failed(): return

	_research("research_ultimate_platforms")
	_build("upgrade_starport_v")
	_develop_ship("develop_ultimate_explorer")
	_develop_ship("develop_ultimate_combat")
	_research("interstellar_initiative")
	var explorer_id := _ship_id("ultimate_explorer")
	_route("interstellar_launch_route", [explorer_id])
	_snapshot("launch_interstellar")
	if _failed(): return

	var incomplete_goals: Array[String] = []
	for goal_value in Game.content.goals.values():
		var goal := goal_value as Dictionary
		if not _requirements_complete(goal.get("requirements", [])):
			incomplete_goals.append(str(goal.get("id", "")))
	_check(Game.state.game_complete and incomplete_goals.is_empty(), "a default new save reaches the first interstellar launch without injected resources or unlocks: %s" % str(incomplete_goals))
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
		_fail("no available permanent extraction site and fitted ship for %s / %s" % [item_id, preferred_activity_id])
		return
	var ship_id := str(selection.get("ship_id", ""))
	var site_id := str(selection.get("site_id", ""))
	var activity: Dictionary = selection.get("activity", {})
	var mining_location: Dictionary = Game.content.mining_locations.get(str(activity.get("location", "")), {})
	var output_location := str(mining_location.get("region", MAIN_LOCATION))
	var required_output := target_quantity - Game.state.item_quantity(item_id, MAIN_LOCATION)
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
	if not runtime.is_empty() and str(runtime.get("status", "")) == "RUNNING":
		Game.stop_mining_operation(int(runtime.get("slot", -1)))
	if output_location != MAIN_LOCATION:
		_transfer_to_main(output_location, item_id, target_quantity)
	_check(Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity, "permanent extraction supplies %s target %d; have=%d activity=%s site=%s runtime=%s ship=%s" % [item_id, target_quantity, Game.state.item_quantity(item_id, MAIN_LOCATION), activity.get("id", ""), site_id, str(runtime), str(Game.state.ship_by_id(ship_id))])


func _transfer_to_main(source_location: String, item_id: String, target_quantity: int) -> void:
	if _failed() or Game.state.item_quantity(item_id, MAIN_LOCATION) >= target_quantity:
		return
	# Pause the previous demand pair while replenishing route consumables; otherwise
	# a newly arrived unit of fuel can be spent by the old raw-material demand in
	# the same simulation window before the caller can launch the intended batch.
	Game.clear_location_logistics_policy(source_location, item_id)
	Game.clear_location_logistics_policy(MAIN_LOCATION, item_id)
	var route_fuel := int({"lunar_space":1, "asteroid_belt":3, "gas_giant_region":5, "outer_system":8, "deep_system":12}.get(source_location, 0))
	var route_maintenance := int({"lunar_space":1, "asteroid_belt":2, "gas_giant_region":3, "outer_system":4, "deep_system":5}.get(source_location, 0))
	var route_capacity := int({"lunar_space":24, "asteroid_belt":18, "gas_giant_region":16, "outer_system":12, "deep_system":8}.get(source_location, 1))
	var strategic_fuel_reserve := 20 if int(Game.state.completed_activities.get("manufacture_chemical_propellant", 0)) > 0 else 0
	if route_fuel <= 0:
		_fail("no golden-path freight fuel profile for %s" % source_location)
		return
	var freight_deficit := maxi(0, target_quantity - Game.state.item_quantity(item_id, MAIN_LOCATION))
	var freight_shipments := maxi(1, ceili(float(freight_deficit) / float(route_capacity)))
	var required_route_fuel := route_fuel * freight_shipments
	var required_route_maintenance := route_maintenance * freight_shipments
	if Game.state.item_quantity("chemical_propellant", source_location) < required_route_fuel:
		var remote_fuel_target := maxi(required_route_fuel, route_fuel * 6)
		var fuel_cargo := remote_fuel_target - Game.state.item_quantity("chemical_propellant", source_location)
		var fuel_shipments := ceili(float(fuel_cargo) / float(route_capacity))
		if "chemical_propellant" not in production_stack:
			_ensure_costs({"chemical_propellant":fuel_cargo + route_fuel * fuel_shipments + strategic_fuel_reserve, "repair_material":route_maintenance * fuel_shipments + 20})
		elif Game.state.item_quantity("chemical_propellant", MAIN_LOCATION) < fuel_cargo + route_fuel:
			_fail("bootstrap propellant is exhausted while establishing the renewable Lunar gas loop")
		if _failed(): return
		_command(Game.set_location_logistics_policy(MAIN_LOCATION, "chemical_propellant", "SUPPLY", strategic_fuel_reserve, 0, 100, 1), "publish main propellant supply")
		_command(Game.set_location_logistics_policy(source_location, "chemical_propellant", "DEMAND", 0, remote_fuel_target, 100, 1, MAIN_LOCATION), "request remote route fuel at %s" % source_location)
		_advance(1000000.0)
		if Game.state.item_quantity("chemical_propellant", source_location) < required_route_fuel:
			_fail("route fuel did not arrive at %s; have %d need %d main_fuel=%d main_repair=%d source_repair=%d main_policy=%s source_policy=%s shipments=%s" % [source_location, Game.state.item_quantity("chemical_propellant", source_location), required_route_fuel, Game.state.item_quantity("chemical_propellant", MAIN_LOCATION), Game.state.item_quantity("repair_material", MAIN_LOCATION), Game.state.item_quantity("repair_material", source_location), str(Game.state.location_state(MAIN_LOCATION).get("logistics", {}).get("policies", {})), str(Game.state.location_state(source_location).get("logistics", {}).get("policies", {})), str(Game.state.logistics_network.get("shipments", []))])
			return
	if Game.state.item_quantity("repair_material", source_location) < required_route_maintenance:
		var remote_maintenance_target := maxi(required_route_maintenance, route_maintenance * 6)
		var maintenance_cargo := remote_maintenance_target - Game.state.item_quantity("repair_material", source_location)
		var maintenance_shipments := ceili(float(maintenance_cargo) / float(route_capacity))
		_ensure_costs({"repair_material":maintenance_cargo + route_maintenance * maintenance_shipments + 20, "chemical_propellant":route_fuel * maintenance_shipments + strategic_fuel_reserve})
		if _failed(): return
		_command(Game.set_location_logistics_policy(MAIN_LOCATION, "repair_material", "SUPPLY", 20, 0, 100, 1), "publish main freight maintenance supply")
		_command(Game.set_location_logistics_policy(source_location, "repair_material", "DEMAND", 0, remote_maintenance_target, 100, 1, MAIN_LOCATION), "request remote freight maintenance at %s" % source_location)
		_advance(1000000.0)
		if Game.state.item_quantity("repair_material", source_location) < route_maintenance:
			_fail("freight maintenance did not arrive at %s; have %d need %d" % [source_location, Game.state.item_quantity("repair_material", source_location), route_maintenance])
			return
	_command(Game.set_location_logistics_policy(source_location, item_id, "SUPPLY", 0, 0, 100, 1), "publish %s supply at %s" % [item_id, source_location])
	_command(Game.set_location_logistics_policy(MAIN_LOCATION, item_id, "DEMAND", 0, target_quantity, 100, 1, source_location), "request %s at main" % item_id)
	_advance(1000000.0)
	Game.clear_location_logistics_policy(source_location, item_id)
	Game.clear_location_logistics_policy(MAIN_LOCATION, item_id)
	Game.clear_location_logistics_policy(source_location, "chemical_propellant")
	Game.clear_location_logistics_policy(MAIN_LOCATION, "chemical_propellant")
	Game.clear_location_logistics_policy(source_location, "repair_material")
	Game.clear_location_logistics_policy(MAIN_LOCATION, "repair_material")
	if Game.state.item_quantity(item_id, MAIN_LOCATION) < target_quantity:
		_fail("freight did not deliver %s from %s; main=%d target=%d source=%d source_fuel=%d main_fuel=%d source_policy=%s main_policy=%s shipments=%s" % [item_id, source_location, Game.state.item_quantity(item_id, MAIN_LOCATION), target_quantity, Game.state.item_quantity(item_id, source_location), Game.state.item_quantity("chemical_propellant", source_location), Game.state.item_quantity("chemical_propellant", MAIN_LOCATION), str(Game.state.location_state(source_location).get("logistics", {}).get("policies", {})), str(Game.state.location_state(MAIN_LOCATION).get("logistics", {}).get("policies", {})), str(Game.state.logistics_network.get("shipments", []))])


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
	var project: Dictionary = Game.content.research_projects.get(project_id, {})
	var committed_costs := {}
	for cost_value in project.get("costs", []):
		var cost := cost_value as Dictionary
		committed_costs[str(cost.get("item", ""))] = int(committed_costs.get(str(cost.get("item", "")), 0)) + int(cost.get("quantity", 0))
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
	_advance(maxf(1000.0, float(project.get("duration_ms", 1000.0)) * 2.0))
	_check(bool(Game.state.completed_projects.get(project_id, false)), "research completes with progressively consumed real materials: %s" % project_id)


func _develop_ship(project_id: String) -> void:
	_research(project_id)
	if _failed(): return
	var project: Dictionary = Game.content.research_projects.get(project_id, {})
	var plan_id := str(project.get("grants_ship_plan", ""))
	var plan: Dictionary = Game.content.ship_construction_projects.get(plan_id, {})
	var ship_model := str(plan.get("ship_id", ""))
	if Game.simulation.shipyard_queue_index(Game.state, plan_id) > 0:
		_command(Game.move_shipyard_project(plan_id, 0), "prioritize required Shipyard plan %s" % plan_id)
	for _attempt in 5:
		if Game.state.owns_ship_model(ship_model):
			break
		_advance(maxf(10000.0, float(plan.get("cycle_time_ms", 1000.0)) * 25.0))
	_check(Game.state.owns_ship_model(ship_model), "Shipyard builds the researched physical ship: %s" % ship_model)


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
	var bom: Dictionary = Game.simulation.refit_bom_delta(Game.state.ship_module_definition_ids(ship), desired)
	_ensure_costs(bom)
	if not _command(Game.begin_ship_refit(ship_id, desired), "refit %s with %s" % [ship_id, module_id]):
		return
	_advance(250000.0)
	_check(module_id in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)), "real Starport refit installs capability module %s" % module_id)


func _route(route_id: String, ship_ids: Array) -> void:
	if _failed() or int(Game.state.completed_activities.get("route:%s" % route_id, 0)) > 0:
		return
	_ensure_item("kinetic_munitions", 120)
	_ensure_item("repair_supplies", 20)
	var route: Dictionary = Game.content.expedition_routes.get(route_id, {})
	_command(Game.set_fleet_supply_plan("chemical_propellant", int(route.get("fuel_cost", 0))), "set exact route propellant plan for %s" % route_id)
	for ship_id_value in ship_ids:
		if not _command(Game.set_ship_fleet_assignment(str(ship_id_value), "expedition"), "assign Expedition ship %s" % ship_id_value):
			return
	if not _command(Game.start_expedition_route(route_id, ship_ids), "launch route %s" % route_id):
		return
	_advance(1000000.0)
	if int(Game.state.completed_activities.get("route:%s" % route_id, 0)) <= 0:
		var report: Dictionary = Game.state.expedition_reports[-1] if not Game.state.expedition_reports.is_empty() else {}
		_fail("route %s failed: %s / %s" % [route_id, report.get("result", "NO_REPORT"), report.get("reason", Game.last_notice)])


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


func _cost_dictionary(entries: Array) -> Dictionary:
	var result := {}
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := str(entry.get("item", ""))
		result[item_id] = int(result.get(item_id, 0)) + int(entry.get("quantity", 0))
	return result


func _industry_slot(facility_id: String) -> int:
	for index in Game.state.industrial_operations.size():
		if str(Game.state.industrial_operations[index].get("facility_id", "")) == facility_id:
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
