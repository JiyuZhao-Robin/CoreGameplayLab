extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content 1.29 loads and validates: %s" % str(database.errors))
	if database.errors.is_empty():
		_test_content_contract(database)
		_test_planner_contract(database)
	_finish()


func _test_content_contract(database: ContentDatabase) -> void:
	_check(str(database.pack_metadata.get("version", "")) == "1.29.0", "content pack metadata is aligned to 1.29.0")
	var capital_goods: Array = database.industry_rules.get("capital_goods", [])
	_check(capital_goods.size() == 8, "the core contains exactly eight reusable Capital Goods")
	for item_id_value in capital_goods:
		var item_id := str(item_id_value)
		var scenarios := database.capital_good_usage_scenarios(item_id)
		_check(scenarios.size() >= 2, "%s has at least two ordinary long-term uses: %s" % [item_id, str(scenarios)])
		_check(scenarios.all(func(value): return str((value as Dictionary).get("kind", "")) != "MEGASTRUCTURE"), "%s usage evidence excludes Megastructure-only sinks" % item_id)
	var recovery: Dictionary = database.activities.get("fabricate_basic_machine_tools", {})
	var steel_method: Dictionary = database.activities.get("fabricate_industrial_machine_tools_steel", {})
	_check(str(recovery.get("facility", "")) == "makeshift_workshop" and _entry_quantity(recovery.get("rewards", []), "industrial_machine_tools") == 1, "the low-efficiency machine-tool recovery route remains available")
	_check(_entry_quantity(steel_method.get("costs", []), "steel_composite") > 0 and _entry_quantity(steel_method.get("rewards", []), "industrial_machine_tools") == 1, "Steel feeds a real repeatable Industrial Machine Tools method")
	var bootstrap: Dictionary = database.bootstrap_reachability_snapshot("BOOTSTRAP")
	for item_id_value in database.industry_rules.get("bootstrap_contract", {}).get("required_bootstrap_items", []):
		_check(bootstrap.get("reachable_items", []).has(str(item_id_value)), "new-save bootstrap reaches %s" % item_id_value)
	var progression: Dictionary = database.bootstrap_reachability_snapshot("PROGRESSION")
	for item_id_value in capital_goods:
		_check(progression.get("reachable_items", []).has(str(item_id_value)), "new-save production graph reaches Capital Good %s" % item_id_value)
	_check(database.industry_rules.get("location_specializations", {}).is_empty(), "hard-coded Location specializations are retired")
	for legacy_id in ["build_automated_metallurgy_network", "upgrade_automated_metallurgy_network", "build_automated_electronics_network", "build_automated_assembly_network"]:
		_check(not database.activities.has(legacy_id), "retired background production activity %s is not executable" % legacy_id)
	_check(not database.facilities.has("autonomous_industry"), "the retired autonomous-industry Megastructure facility is absent from live content")
	for mode_value in database.transport_modes.values():
		var mode := mode_value as Dictionary
		if str(mode.get("id", "")) != "general_cargo" and not bool(mode.get("infrastructure_service", false)):
			_check(not bool(mode.get("public_base_capacity", false)) and float(mode.get("ship_capacity_multiplier", 0.0)) > 0.0, "specialist service %s derives capacity from physical ships" % mode.get("id", "?"))
	_check(bool(database.transport_modes.get("general_cargo", {}).get("public_base_capacity", false)), "limited public General Cargo preserves multi-hop new-save bootstrap")
	for project_value in database.research_projects.values():
		var project := project_value as Dictionary
		if not project.get("stages", []).is_empty():
			_check(project.get("costs", []).is_empty(), "staged Research Program %s has one cost authority: stages[].costs" % project.get("id", "?"))
	var megastructure_research: Dictionary = database.research_projects.get("research_megastructures", {})
	var thermal_stage: Dictionary = (megastructure_research.get("stages", []) as Array).filter(func(value): return str((value as Dictionary).get("id", "")) == "thermal_routing")[0]
	_check(_entry_quantity(thermal_stage.get("costs", []), "dark_matter") == 2, "Dark Matter is consumed by the real Megastructure thermal-routing Research stage")
	var survey_deployment: Dictionary = database.survey_rules.get("deployment_package", {})
	_check(str(survey_deployment.get("target_state", "")) == LocationState.SURVEYED and _entry_quantity(survey_deployment.get("costs", []), "industrial_machine_tools") > 0 and _entry_quantity(survey_deployment.get("costs", []), "structural_frame") > 0, "remote Survey staging is a committed pre-heavy-industry Capital Good deployment package")


func _test_planner_contract(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("TEST_PROFILE")
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	simulation.logistics.ensure_state(state)
	var planner := simulation.economy_planner
	var before: Dictionary = state.to_dictionary()
	simulation.system_production_overview(state, SpaceGameState.SYSTEM_ID)
	_check(state.to_dictionary() == before, "System production overview is a read-only query")
	var ship_plan: Dictionary = database.ship_construction_projects["construct_bulk_freighter"]
	var expected_ship_bom: Dictionary = simulation.ship_construction_material_totals(ship_plan)
	for fixed_value in ship_plan.get("fixed_costs", []):
		var fixed_cost := fixed_value as Dictionary
		var item_id := str(fixed_cost.get("item", ""))
		expected_ship_bom[item_id] = int(expected_ship_bom.get(item_id, 0)) + int(fixed_cost.get("quantity", 0))
	var ship_target: Dictionary = planner.plan_ship_per_month(state, "construct_bulk_freighter", 2.0)
	_check(ship_target.get("per_ship_bom", {}) == expected_ship_bom and is_equal_approx(float(ship_target.get("throughput_targets", {}).get("steel_composite", 0.0)), float(expected_ship_bom.get("steel_composite", 0)) * 2.0 / 720.0), "Ship/month planning reuses the Simulation fitted-hull BOM and shipyard cycle rule")
	var research_target: Dictionary = planner.plan_research_phase(state, "research_advanced_propulsion", "prototype")
	_check(float(research_target.get("bom", {}).get("propulsion_test_article", 0.0)) == 1.0 and str(research_target.get("target_type", "")) == "RESEARCH_PHASE", "R&D phase planning exposes its real Experimental Article BOM")
	var mega_target: Dictionary = planner.plan_megastructure_phase(state, "stellar_energy", "stellar_primary_frame", "earth_sun_lagrange")
	_check(float(mega_target.get("bom", {}).get("steel_composite", 0.0)) > 0.0 and not mega_target.get("site_requirements", {}).is_empty() and str(mega_target.get("activity_id", "")) == "construct_stellar_primary_frame", "Megastructure phase planning exposes its real Construction BOM and site contract")
	var thermal_phase: Dictionary = database.megastructures.get("stellar_energy", {}).get("phases", [])[4]
	var base_site_requirements: Dictionary = simulation.megastructure_effective_site_requirements(state, thermal_phase)
	state.technology_spillovers["stellar_thermal_routing"] = true
	var routed_site_requirements: Dictionary = simulation.megastructure_effective_site_requirements(state, thermal_phase)
	var routed_target: Dictionary = planner.plan_megastructure_phase(state, "stellar_energy", str(thermal_phase.get("id", "")), "earth_sun_lagrange")
	_check(float(routed_site_requirements.get("power_capacity", 0.0)) < float(base_site_requirements.get("power_capacity", 0.0)) and float(routed_site_requirements.get("cooling_capacity", 0.0)) < float(base_site_requirements.get("cooling_capacity", 0.0)), "Stellar Thermal Routing has a real Power and Cooling implementation")
	_check(routed_target.get("site_requirements", {}) == routed_site_requirements, "Megastructure Planner and runtime share effective site requirements")
	state.technology_spillovers.erase("stellar_thermal_routing")
	_check(state.to_dictionary() == before, "all target planners are read-only and do not mutate live state")

	for location_id_value in state.locations.keys():
		var location_id := str(location_id_value)
		state.location_state(location_id)["discovery_state"] = LocationState.DISCOVERED
	state.mining_site_states["lunar_deep_ice_lens"]["survey_state"] = LocationState.SURVEYED
	state.location_state("lunar_space")["survey_state"] = LocationState.SURVEYED
	var resource_before: Dictionary = state.to_dictionary()
	var resource_plan: Dictionary = planner.plan_targets(state, {"mixed_raw_gas":500.0}, "earth_orbit")
	var geography: Dictionary = resource_plan.get("industrial_geography", {}).get("products", {}).get("mixed_raw_gas", {})
	_check(float(geography.get("shortfall", 0.0)) > 0.0 and geography.get("potential_solutions", []).has("DEEP_SURVEY_EXISTING_SITES"), "planner reports surveyed Sustainable Extraction Potential shortfall and a valid remedy")
	var logistics_rows: Array = resource_plan.get("logistics", [])
	var logistics_row: Dictionary = logistics_rows[0] if not logistics_rows.is_empty() else {}
	_check(logistics_row.get("route_ids", []).has("earth_lunar_freight") and float(logistics_row.get("cargo_mass_per_hour", 0.0)) > 0.0 and float(logistics_row.get("cargo_volume_per_hour", 0.0)) > 0.0, "raw-resource planning includes the real route plus mass and volume throughput")
	var bottleneck: Dictionary = planner.trace_bottleneck(state, "mixed_raw_gas", "earth_orbit", 500.0)
	var chain_kinds: Array = bottleneck.get("shortest_chain", []).map(func(value): return str((value as Dictionary).get("kind", "")))
	_check(chain_kinds.has("SITE") and chain_kinds.has("ROUTE") and chain_kinds.has("DESTINATION") and str(bottleneck.get("primary_bottleneck", "")) in ["RESOURCE_POTENTIAL_SHORTAGE", "LOGISTICS_CAPACITY_SHORTAGE"], "resource bottleneck traces a deterministic SITE -> ROUTE/HUB -> DESTINATION chain")
	_check(state.to_dictionary() == resource_before, "resource geography and logistics planning remain read-only")


func _entry_quantity(entries: Array, item_id: String) -> int:
	var result := 0
	for entry_value in entries:
		var entry := entry_value as Dictionary
		if str(entry.get("item", "")) == item_id:
			result += int(entry.get("quantity", 0))
	return result


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("Content and planner contract test passed")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
