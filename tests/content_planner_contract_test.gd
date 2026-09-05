extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content 1.30 loads and validates: %s" % str(database.errors))
	if database.errors.is_empty():
		_test_content_contract(database)
		_test_planner_contract(database)
	_finish()


func _test_content_contract(database: ContentDatabase) -> void:
	_check(str(database.pack_metadata.get("version", "")) == "1.32.0", "content pack metadata is aligned to 1.32.0")
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
	var establish_steps: Array = database.goals.get("establish_industry", {}).get("steps", [])
	var establish_activity_ids: Array = establish_steps.map(func(step_value):
		var requirements: Array = (step_value as Dictionary).get("requirements", [])
		return str((requirements[0] as Dictionary).get("id", "")) if not requirements.is_empty() else ""
	)
	_check(not establish_activity_ids.has("separate_iron_ore") and not establish_activity_ids.has("separate_copper_ore") and establish_activity_ids.has("refine_iron") and establish_activity_ids.has("refine_copper"), "Establish Industry goal uses physical Factory extraction and recipe milestones instead of retired aggregate ore-separation actions")
	var founding_data_core_recipe: Dictionary = database.factory_recipes.get("grid_fabricate_data_core", {})
	_check(founding_data_core_recipe.get("requirements", []).is_empty() and founding_data_core_recipe.get("reveal_requirements", []).is_empty(), "the first Electronics Works has a founding recipe before Industrial Coordination, avoiding a research/facility unlock cycle")
	for resource_id_value in database.factory_grid_rules.get("resource_activity_ids", {}).keys():
		var resource_id := str(resource_id_value)
		var activity_id := str(database.factory_grid_rules.get("resource_activity_ids", {}).get(resource_id_value, ""))
		var activity: Dictionary = database.activities.get(activity_id, {})
		_check(not activity.is_empty() and _entry_quantity(activity.get("rewards", []), resource_id) > 0, "Factory extraction milestone %s maps to a real resource-producing activity" % resource_id)
	var physical_module_buildings := {
		"precision_mechanics_cell":"grid_precision_mechanics_cell",
		"cryogenic_process_unit":"grid_cryogenic_process_unit",
		"radiation_electronics_cell":"grid_radiation_electronics_cell",
		"advanced_alloy_cell":"grid_advanced_alloy_cell",
		"photonic_integration_line":"grid_photonic_integration_line"
	}
	for module_id_value in physical_module_buildings.keys():
		var module_id := str(module_id_value)
		var building_id := str(physical_module_buildings.get(module_id_value, ""))
		var building: Dictionary = database.factory_buildings.get(building_id, {})
		_check(not building.is_empty() and (building.get("completion_effects", []) as Array).any(func(effect): return str((effect as Dictionary).get("type", "")) == "install_manufacturing_module" and str((effect as Dictionary).get("id", "")) == module_id), "Factory progression has a physical construction provider for manufacturing module %s" % module_id)
	var research_expansion: Dictionary = database.factory_buildings.get("grid_research_complex_ii", {})
	_check(
		not research_expansion.is_empty()
		and (research_expansion.get("completion_effects", []) as Array).any(func(effect): return str((effect as Dictionary).get("type", "")) == "set_facility_minimum_level" and str((effect as Dictionary).get("facility", "")) == "research_complex" and int((effect as Dictionary).get("level", 0)) == 2),
		"Megastructure Research has a physical Factory provider for research capacity level 2"
	)
	var research_expansion_requirements: Array = research_expansion.get("requirements", [])
	_check(
		research_expansion_requirements.any(func(requirement): return str((requirement as Dictionary).get("type", "")) == "technology" and str((requirement as Dictionary).get("id", "")) == "heavy_industry")
		and research_expansion_requirements.any(func(requirement): return str((requirement as Dictionary).get("type", "")) == "facility_level" and str((requirement as Dictionary).get("id", "")) == "research_complex" and int((requirement as Dictionary).get("level", 0)) == 1),
		"Research Complex II is revealed by Heavy Industry and requires the owned base complex"
	)
	var expected_research_expansion_bom := {"steel_composite":5, "quantum_component":4, "data_core":4}
	for item_id_value in expected_research_expansion_bom.keys():
		var item_id := str(item_id_value)
		_check(_entry_quantity(research_expansion.get("construction_cost", []), item_id) == int(expected_research_expansion_bom[item_id]), "Research Complex II has the canonical %s construction cost" % item_id)
		var producing_recipes: Array = database.factory_recipes.values().filter(func(recipe_value): return _entry_quantity((recipe_value as Dictionary).get("outputs", []), item_id) > 0)
		var has_pre_mega_machine_provider := producing_recipes.any(func(recipe_value):
			var recipe := recipe_value as Dictionary
			var recipe_id := str(recipe.get("id", ""))
			var forbidden_gate := (recipe.get("requirements", []) as Array).any(func(requirement_value): return str((requirement_value as Dictionary).get("id", "")) in ["megastructure_engineering", "research_megastructures"])
			return not forbidden_gate and database.factory_buildings.values().any(func(building_value): return (building_value as Dictionary).get("recipe_ids", []).has(recipe_id))
		)
		_check(has_pre_mega_machine_provider, "Research Complex II input %s has a physical pre-Megastructure Factory recipe and machine provider" % item_id)
	_assert_goal_requirements_have_factory_providers(database)
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
	var megastructure_requirements: Array = megastructure_research.get("requirements", [])
	for required_gate in [
		{"type":"technology", "id":"exotic_containment_tech"},
		{"type":"own_facility", "id":"frontier_matterworks"},
		{"type":"activity_complete", "id":"separate_dark_matter"}
	]:
		_check(megastructure_requirements.any(func(requirement): return str((requirement as Dictionary).get("type", "")) == str(required_gate.get("type", "")) and str((requirement as Dictionary).get("id", "")) == str(required_gate.get("id", ""))), "Megastructure Research hard-gates the physical %s milestone %s" % [required_gate.get("type", ""), required_gate.get("id", "")])
	var thermal_stage: Dictionary = (megastructure_research.get("stages", []) as Array).filter(func(value): return str((value as Dictionary).get("id", "")) == "thermal_routing")[0]
	_check(_entry_quantity(thermal_stage.get("costs", []), "dark_matter") == 2, "Dark Matter is consumed by the real Megastructure thermal-routing Research stage")
	var fluid_tank: Dictionary = database.factory_buildings.get("grid_fluid_tank", {})
	_check(str(fluid_tank.get("kind", "")) == "STORAGE" and str(fluid_tank.get("storage_class", "")) == "FLUID" and int(fluid_tank.get("inventory_capacity", 0)) >= 1000, "Jovian Factory progression has a canonical physical FLUID custody provider")
	_check((fluid_tank.get("requirements", []) as Array).any(func(requirement): return str((requirement as Dictionary).get("type", "")) == "technology" and str((requirement as Dictionary).get("id", "")) == "advanced_propulsion"), "the canonical FLUID tank becomes buildable on the pre-Jovian Advanced Propulsion path")
	var tank_bom_storage := {}
	for cost_value in fluid_tank.get("construction_cost", []):
		var cost := cost_value as Dictionary
		var profile := database.item_storage_profile(str(cost.get("item", "")))
		var storage_class := str(profile.get("storage_class", ""))
		tank_bom_storage[storage_class] = float(tank_bom_storage.get(storage_class, 0.0)) + float(cost.get("quantity", 0)) * float(profile.get("storage_units", 0.0))
	var surveyed_capacities: Dictionary = database.survey_rules.get("deployment_package", {}).get("site_effects", {}).get("storage_capacities", {})
	_check(tank_bom_storage.keys().all(func(storage_class): return float(tank_bom_storage.get(storage_class, 0.0)) <= float(surveyed_capacities.get(storage_class, 0))), "the canonical FLUID tank BOM fits the finite SURVEYED-site staging contract")
	for fluid_item_id in ["methane", "water_ice", "helium_3"]:
		_check(str(database.item_storage_profile(fluid_item_id).get("storage_class", "")) == "FLUID", "%s resolves to the FLUID storage contract" % fluid_item_id)
	var survey_deployment: Dictionary = database.survey_rules.get("deployment_package", {})
	_check(str(survey_deployment.get("target_state", "")) == LocationState.SURVEYED and _entry_quantity(survey_deployment.get("costs", []), "industrial_machine_tools") > 0 and _entry_quantity(survey_deployment.get("costs", []), "structural_frame") > 0, "remote Survey staging is a committed pre-heavy-industry Capital Good deployment package")
	var asteroid_route: Dictionary = database.expedition_routes.get("asteroid_route", {})
	var debris_nodes: Array = (asteroid_route.get("nodes", []) as Array).filter(func(node_value): return str((node_value as Dictionary).get("id", "")) == "debris_corridor")
	var debris_node: Dictionary = debris_nodes[0] if not debris_nodes.is_empty() else {}
	var surface_mine: Dictionary = database.factory_buildings.get("grid_surface_mine", {})
	_check(_entry_quantity(debris_node.get("rewards", []), "scrap_metal") == _entry_quantity(surface_mine.get("construction_cost", []), "scrap_metal"), "the mandatory Asteroid debris recovery exactly funds the post-bootstrap Lunar rare-earth mine")
	var outer_route: Dictionary = database.expedition_routes.get("outer_route", {})
	var outer_boss_nodes: Array = (outer_route.get("nodes", []) as Array).filter(func(node_value): return str((node_value as Dictionary).get("enemy", "")) == "outer_dreadnought")
	var outer_boss: Dictionary = outer_boss_nodes[0] if not outer_boss_nodes.is_empty() else {}
	var exotic_bootstrap_reward := _entry_quantity(outer_boss.get("rewards", []), "exotic_crystal")
	var exotic_materials_cost := _entry_quantity(database.research_projects.get("research_exotic_materials", {}).get("costs", []), "exotic_crystal")
	var antimatter_cost := _entry_quantity(database.research_projects.get("research_antimatter", {}).get("costs", []), "exotic_crystal")
	var first_antimatter_cell_cost := _entry_quantity(database.factory_recipes.get("grid_build_antimatter_cell", {}).get("inputs", []), "exotic_crystal")
	_check(exotic_bootstrap_reward == 11 and exotic_bootstrap_reward >= exotic_materials_cost + antimatter_cost + first_antimatter_cell_cost, "Outer Dreadnought reward funds both research programs and the first antimatter cell needed to bootstrap the antimatter-gated exotic extractor")


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
	var economy: Dictionary = planner.current_economy_analysis(state, "earth_orbit")
	var scrap_rows: Array = economy.get("products", []).filter(func(value): return str((value as Dictionary).get("product_id", "")) == "scrap_metal")
	var scrap_row: Dictionary = scrap_rows[0] if not scrap_rows.is_empty() else {}
	_check(int(scrap_row.get("factory_on_hand", 0)) == 44 and int(scrap_row.get("location_on_hand", -1)) == 0 and int(scrap_row.get("on_hand", 0)) == 44, "economy analysis reports physical factory buffers without duplicating them into Location Inventory")
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

	var resource_before: Dictionary = state.to_dictionary()
	var production_plan: Dictionary = planner.plan_targets(state, {"iron_ingot":1800.0}, "earth_orbit")
	var factory_requirement: Dictionary = production_plan.get("factory_requirements", [])[0] if not production_plan.get("factory_requirements", []).is_empty() else {}
	_check(str(production_plan.get("method_selections", {}).get("iron_ingot", "")) == "grid_refine_iron" and str(factory_requirement.get("building_definition_id", "")) == "grid_arc_smelter" and int(factory_requirement.get("recommended", 0)) == 1, "throughput planning selects the physical grid recipe and recommends a concrete machine entity")
	var resource_plan: Dictionary = planner.plan_targets(state, {"iron_ore":500.0}, "earth_orbit")
	var geography: Dictionary = resource_plan.get("industrial_geography", {}).get("products", {}).get("iron_ore", {})
	_check(float(geography.get("shortfall", 0.0)) > 0.0 and geography.get("potential_solutions", []).has("PLACE_EXTRACTOR") and str(geography.get("resource_fields", [])[0].get("resource_field_id", "")) == "starter-iron-field", "planner reads tile resource fields and recommends a physical extractor when installed capacity is absent")
	_check(resource_plan.get("logistics", []).is_empty(), "a deposit in the destination factory world does not create a phantom inter-location freight route")
	var bottleneck: Dictionary = planner.trace_bottleneck(state, "iron_ore", "earth_orbit", 500.0)
	var chain_kinds: Array = bottleneck.get("shortest_chain", []).map(func(value): return str((value as Dictionary).get("kind", "")))
	_check(chain_kinds.has("RESOURCE_FIELD") and chain_kinds.has("WORLD") and chain_kinds.has("DESTINATION") and str(bottleneck.get("primary_bottleneck", "")) == "EXTRACTION_CAPACITY_SHORTAGE", "resource bottleneck traces the authoritative RESOURCE_FIELD -> WORLD -> DESTINATION chain")
	_check(state.to_dictionary() == resource_before, "grid recipe, deposit and logistics planning remain read-only")


func _assert_goal_requirements_have_factory_providers(database: ContentDatabase) -> void:
	var activity_providers := {}
	for recipe_value in database.factory_recipes.values():
		var recipe := recipe_value as Dictionary
		var activity_id := str(recipe.get("activity_id", ""))
		if not activity_id.is_empty():
			activity_providers[activity_id] = true
	for building_value in database.factory_buildings.values():
		var building := building_value as Dictionary
		var activity_id := str(building.get("activity_id", ""))
		if not activity_id.is_empty():
			activity_providers[activity_id] = true
	for activity_id_value in database.factory_grid_rules.get("resource_activity_ids", {}).values():
		activity_providers[str(activity_id_value)] = true
	var module_providers := {}
	for building_value in database.factory_buildings.values():
		for effect_value in (building_value as Dictionary).get("completion_effects", []):
			var effect := effect_value as Dictionary
			if str(effect.get("type", "")) == "install_manufacturing_module":
				module_providers[str(effect.get("id", ""))] = true
	for goal_value in database.goals.values():
		var goal := goal_value as Dictionary
		_validate_goal_provider_requirements(str(goal.get("id", "")), goal.get("requirements", []), activity_providers, module_providers)
		for step_value in goal.get("steps", []):
			var step := step_value as Dictionary
			_validate_goal_provider_requirements("%s/%s" % [goal.get("id", ""), step.get("id", "")], step.get("requirements", []), activity_providers, module_providers)


func _validate_goal_provider_requirements(label: String, requirements: Array, activity_providers: Dictionary, module_providers: Dictionary) -> void:
	for requirement_value in requirements:
		var requirement := requirement_value as Dictionary
		var requirement_id := str(requirement.get("id", ""))
		match str(requirement.get("type", "")):
			"activity_complete":
				_check(activity_providers.has(requirement_id), "%s activity milestone has a physical Factory provider: %s" % [label, requirement_id])
			"manufacturing_module_installed":
				_check(module_providers.has(requirement_id), "%s manufacturing-module milestone has a physical Factory provider: %s" % [label, requirement_id])


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
