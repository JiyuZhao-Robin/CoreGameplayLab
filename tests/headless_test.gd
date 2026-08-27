extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content loads and validates: %s" % str(database.errors))
	if not database.errors.is_empty():
		_finish()
		return
	_test_localization(database)
	_test_economic_closure(database)
	_test_phase_one_progression_contract(database)
	_test_phase_two_construction_projects(database)
	_test_phase_three_production_lines(database)
	_test_structured_blocker_diagnostics(database)
	# Visual-profile coverage belongs to the presentation project, not Gameplay Lab.
	_test_frontier_content(database)
	_test_physical_ship_assets(database)
	_test_permanent_extraction(database)
	_test_mature_extraction_network(database)
	_test_phase_four_freight_services(database)
	_test_location_logistics(database)
	_test_system_overviews(database)
	_test_industrial_templates(database)
	_test_exploration_and_first_clear(database)
	_test_combat_cycles_and_logistics(database)
	_test_combat_depth_zones(database)
	_test_parallel_shipbuilding(database)
	_test_parallel_physical_refits(database)
	_test_phase_five_loadout_fabrication(database)
	_test_phase_five_loadout_migration(database)
	_test_phase_six_rd_programs(database)
	_test_phase_seven_inventory_planning(database)
	_test_phase_eight_industrial_geography(database)
	_test_ship_lifecycle(database)
	_test_industry_and_capital_cycles(database)
	_test_location_industry_rules(database)
	_test_megastructure_stages(database)
	_test_save_contract(database)
	_finish()


func _test_localization(database: ContentDatabase) -> void:
	var localization = load("res://src/application/localization.gd").new()
	localization._load_translations()
	localization.current_locale = "zh_CN"
	_check(localization.t("button.save", "SAVE NOW") == "立即保存", "Chinese UI strings load")
	_check(localization.content(database.expedition_routes["lunar_relay_assault"]) == "首次清剿：月球海盗中继站", "new first-clear content is localized")
	var translated_definitions: Array = []
	for collection in [
		database.domains, database.items, database.ships, database.modules,
		database.process_modules, database.universal_industry_plugins, database.facilities,
		database.mining_locations, database.mining_hazards, database.activities,
		database.regions, database.resource_regions, database.mining_sites,
		database.combat_areas, database.extraction_networks, database.logistics_routes,
		database.transport_modes, database.industrial_templates,
		database.goals, database.technologies, database.research_projects,
		database.ship_construction_projects, database.enemies,
		database.expedition_routes, database.megastructures
	]:
		translated_definitions.append_array(collection.values())
	var missing: Array[String] = []
	var missing_names: Array[String] = []
	var missing_descriptions: Array[String] = []
	for definition in translated_definitions:
		var definition_id := str(definition.get("id", ""))
		var translated: Dictionary = localization._translations.get("content", {}).get(definition_id, {})
		if translated.is_empty():
			missing.append(definition_id)
		if not str(definition.get("name", "")).is_empty() and str(translated.get("name", "")).is_empty():
			missing_names.append(definition_id)
		if not str(definition.get("description", "")).is_empty() and str(translated.get("description", "")).is_empty():
			missing_descriptions.append(definition_id)
	_check(missing.is_empty(), "Chinese content translation coverage: %s" % str(missing))
	_check(missing_names.is_empty(), "Chinese content name coverage: %s" % str(missing_names))
	_check(missing_descriptions.is_empty(), "Chinese content description coverage: %s" % str(missing_descriptions))
	var missing_goal_steps: Array[String] = []
	var translated_goal_steps: Dictionary = localization._translations.get("goal_steps", {})
	for goal_value in database.goals.values():
		for step_value in (goal_value as Dictionary).get("steps", []):
			var step_id := str((step_value as Dictionary).get("id", ""))
			if step_id.is_empty() or str(translated_goal_steps.get(step_id, "")).is_empty():
				missing_goal_steps.append(step_id)
	_check(missing_goal_steps.is_empty(), "every main-flow Guide step has an explicit Chinese instruction: %s" % str(missing_goal_steps))
	_check(localization.goal_step("refine_first_copper", "Refine First Copper") == "精炼第一批铜锭", "goal steps use the same Chinese content layer")
	_check(localization.megastructure_stage("stellar_energy", 4, "Industrial and Energy Backbone") == "工业与能源骨架", "Megastructure phases are localized instead of mixing languages")
	localization.free()


func _test_economic_closure(database: ContentDatabase) -> void:
	var stable_sources := {}
	var consumers := {}
	for activity_value in database.activities.values():
		var activity := activity_value as Dictionary
		if bool(activity.get("repeat", true)):
			for field in ["rewards", "waste"]:
				for entry_value in activity.get(field, []):
					stable_sources[str((entry_value as Dictionary).get("item", ""))] = true
		for cost_value in activity.get("costs", []):
			consumers[str((cost_value as Dictionary).get("item", ""))] = true
	for project_value in database.research_projects.values():
		for cost_value in (project_value as Dictionary).get("costs", []):
			consumers[str((cost_value as Dictionary).get("item", ""))] = true
	for plan_value in database.ship_construction_projects.values():
		for field in ["costs", "fixed_costs"]:
			for cost_value in (plan_value as Dictionary).get(field, []):
				consumers[str((cost_value as Dictionary).get("item", ""))] = true
	for bom_value in database.industry_rules.get("module_bom_defaults", {}).values():
		for cost_value in bom_value as Array:
			consumers[str((cost_value as Dictionary).get("item", ""))] = true
	var missing_sources: Array[String] = []
	for item_id in consumers:
		if not stable_sources.has(item_id):
			missing_sources.append(str(item_id))
	missing_sources.sort()
	_check(missing_sources.is_empty(), "every consumed strategic item has a repeatable deterministic source instead of a random-loot gate: %s" % str(missing_sources))
	var frame: Dictionary = database.activities["assemble_frame"]
	_check(_entry_amount(frame.get("costs", []), "iron_ingot") == 2 and _entry_amount(frame.get("costs", []), "copper_ingot") == 1 and _entry_amount(frame.get("costs", []), "scrap_metal") == 0, "Structural Frames use refined iron and copper rather than salvage")
	var foundry: Dictionary = database.activities["build_orbital_foundry"]
	_check(_entry_amount(foundry.get("costs", []), "structural_frame") == 1 and _entry_amount(foundry.get("costs", []), "iron_ingot") == 4 and _entry_amount(foundry.get("costs", []), "electronics") == 2, "the first Structural Frame is consumed by the Orbital Foundry it unlocks")
	var electronics: Dictionary = database.activities["fabricate_electronics"]
	_check(_entry_amount(electronics.get("costs", []), "iron_ingot") == 1 and _entry_amount(electronics.get("costs", []), "copper_ingot") == 1 and _entry_amount(electronics.get("costs", []), "scrap_metal") == 0, "Electronics use the refined iron/copper loop rather than salvage")
	_check(str(electronics.get("facility", "")) == "makeshift_workshop" and (electronics.get("requirements", []) as Array).is_empty(), "Electronics can be rebuilt at the founding workshop even after the finite starter stock is spent")
	_check(_entry_amount(database.activities["fabricate_quantum_component"].get("costs", []), "data_core") == 0, "Quantum Components no longer consume research loot")
	_check(_entry_amount(database.activities["fabricate_reactor_part"].get("rewards", []), "reactor_part") == 1 and _entry_amount(database.activities["fabricate_data_core"].get("rewards", []), "data_core") == 1, "Reactor Parts and Data Cores have deterministic manufacturing paths")
	_check((database.activities["fabricate_repair_material"].get("requirements", []) as Array).all(func(requirement): return str((requirement as Dictionary).get("type", "")) != "technology") and (database.activities["manufacture_repair_supplies"].get("requirements", []) as Array).all(func(requirement): return str((requirement as Dictionary).get("type", "")) != "technology"), "Early maintenance and combat losses cannot consume the player into a repair-supply soft lock")
	_check(_entry_amount(database.activities["reprocess_industrial_waste"].get("costs", []), "industrial_waste") > 0, "Industrial Waste has a disposal and recovery path before finite storage fills")
	_check(_entry_amount(database.activities["process_silicate_ceramic"].get("costs", []), "silicate_ore") > 0 and _entry_amount(database.activities["prepare_thorium_fuel"].get("costs", []), "thorium_ore") > 0, "Silicate and Thorium feed explicit processing stages rather than dead-end stock")
	_check(_entry_amount(database.activities["refine_steel"].get("costs", []), "cobalt_ore") == 0 and _entry_amount(database.activities["refine_steel"].get("costs", []), "silicate_ore") == 0 and _entry_amount(database.activities["refine_superalloy"].get("costs", []), "cobalt_ore") == 0 and _entry_amount(database.activities["fabricate_fusion_service_component"].get("costs", []), "thorium_ore") == 0, "advanced composites and fusion components never consume raw ore directly")
	for slot_bom_value in database.industry_rules.get("module_bom_defaults", {}).values():
		_check(_entry_amount(slot_bom_value as Array, "scrap_metal") == 0, "ordinary ship-module BOMs do not require salvage")


func _entry_amount(entries: Array, item_id: String) -> int:
	for entry_value in entries:
		var entry := entry_value as Dictionary
		if str(entry.get("item", "")) == item_id:
			return int(entry.get("quantity", 0))
	return 0


func _test_phase_one_progression_contract(database: ContentDatabase) -> void:
	var profiles: Dictionary = database.simulation_profiles.get("profiles", {})
	_check(str(database.simulation_profiles.get("default_profile", "")) == "NORMAL_PROFILE" and profiles.has("TEST_PROFILE") and profiles.has("NORMAL_PROFILE"), "normal play defaults to the NORMAL profile while deterministic tests can explicitly select TEST")
	for system_id in ["mining", "manufacturing", "construction", "shipyard", "automation"]:
		_check(is_equal_approx(float(profiles.get("TEST_PROFILE", {}).get(system_id, 0.0)), 10.0) and is_equal_approx(float(profiles.get("NORMAL_PROFILE", {}).get(system_id, 0.0)), 1.0), "test and normal speed profiles share rules but independently configure %s" % system_id)

	var facility_unlocks := {}
	for activity_value in database.activities.values():
		for effect_value in (activity_value as Dictionary).get("effects", []):
			var effect := effect_value as Dictionary
			if str(effect.get("type", "")) == "unlock_facility":
				facility_unlocks[str(effect.get("facility", ""))] = str((activity_value as Dictionary).get("id", ""))
	for facility_id_value in SpaceGameState.MANUFACTURING_FACILITY_IDS:
		var facility_id := str(facility_id_value)
		if facility_id == "makeshift_workshop":
			continue
		_check(facility_unlocks.has(facility_id), "late manufacturing facility has a real construction unlock: %s" % facility_id)
	_check(facility_unlocks.has("field_engineering_complex") and facility_unlocks.has("frontier_matterworks"), "exotic-crystal and dark-matter repeatable production facilities are buildable")

	var empty_goals: Array[String] = []
	for goal_value in database.goals.values():
		var goal := goal_value as Dictionary
		if goal.get("steps", []).is_empty():
			empty_goals.append(str(goal.get("id", "")))
	_check(database.goals.size() == 11 and empty_goals.is_empty(), "all eleven main goals expose actionable Guide steps: %s" % str(empty_goals))
	var prototype_steps: Array = database.goals.get("prototype_complete", {}).get("steps", [])
	_check(_goal_step_index(prototype_steps, "build_deep_core_drill") >= prototype_steps.size() and _goal_step_index(prototype_steps, "install_precision_mechanics") < _goal_step_index(prototype_steps, "fit_deep_core_drill") and _goal_step_index(prototype_steps, "fit_deep_core_drill") < _goal_step_index(prototype_steps, "extract_belt_feedstock"), "prototype Guide orders the enabling process, full-loadout Starport fabrication/install and extraction without exposing a module-inventory production step")
	_check(_goal_step_index(prototype_steps, "research_heavy_industry") < _goal_step_index(prototype_steps, "research_heavy_extraction") and _goal_step_index(prototype_steps, "research_heavy_extraction") < _goal_step_index(prototype_steps, "separate_cobalt"), "prototype Guide obtains Heavy Extraction before asking for cobalt separation")
	_check(_goal_step_index(prototype_steps, "install_photonic_integration") < _goal_step_index(prototype_steps, "produce_quantum_component"), "prototype Guide installs the Assembly Yard process required for Quantum Components")
	_check(int(database.facilities.get("orbital_foundry", {}).get("process_module_slots", 0)) >= 2, "Orbital Foundry can retain the earlier precision process while the same active Guide goal installs Advanced Alloys")
	var outer_steps: Array = database.goals.get("open_outer", {}).get("steps", [])
	_check(_goal_step_index(outer_steps, "build_gas_collector") >= outer_steps.size() and _goal_step_index(outer_steps, "fit_gas_collector") < _goal_step_index(outer_steps, "extract_jovian_gas"), "outer-system Guide applies the Gas Collector loadout before extraction without creating a physical module inventory step")
	_check(_goal_step_index(outer_steps, "install_fusion_test_rig") < _goal_step_index(outer_steps, "produce_fusion_service_components") and _goal_step_index(outer_steps, "produce_fusion_service_components") < _goal_step_index(outer_steps, "build_energy_array"), "outer-system Guide installs the Fusion process and produces service components before the Energy Array consumes them")
	var megastructure_steps: Array = database.goals.get("prepare_stellar_energy", {}).get("steps", [])
	_check(_goal_step_index(megastructure_steps, "build_exotic_containment") >= megastructure_steps.size() and _goal_step_index(megastructure_steps, "fit_exotic_containment") < _goal_step_index(megastructure_steps, "extract_deep_gas"), "deep-system Guide applies the Exotic Containment loadout before extraction without creating a physical module inventory step")
	var heavy_extraction: Dictionary = database.research_projects.get("research_heavy_extraction", {})
	_check(_entry_amount(heavy_extraction.get("costs", []), "cobalt_ore") == 0 and _entry_amount(heavy_extraction.get("costs", []), "silicate_ore") > 0, "Heavy Extraction research cannot consume the cobalt ore that it uniquely unlocks")
	_check(_entry_amount(database.module_bom("advanced_drive"), "quantum_component") == 0 and _entry_amount(database.module_bom("advanced_drive"), "electronics") > 0, "the pre-Belt Pathfinder drive cannot depend on post-Belt Quantum Component production")
	_check(_entry_amount(database.module_bom("plasma_cannon"), "antimatter_cell") == 0 and _entry_amount(database.module_bom("plasma_cannon"), "quantum_component") > 0, "the pre-Outer Jovian Battleship weapon cannot depend on post-Outer Antimatter production")
	_check(database.activities.get("build_command_array", {}).get("effects", []).any(func(effect): return str((effect as Dictionary).get("type", "")) == "upgrade_extraction_command" and int((effect as Dictionary).get("capacity", 0)) >= 55), "Deep-space Command Array grants enough Extraction Command for the required Titan")


func _test_phase_two_construction_projects(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	_check(SimulationEngine.CONSTRUCTION_PROJECT_TYPES.size() >= 17 and "FACILITY_EXPANSION" in SimulationEngine.CONSTRUCTION_PROJECT_TYPES and "COMPONENT_STORAGE_UPGRADE" in SimulationEngine.CONSTRUCTION_PROJECT_TYPES and "INDUSTRIAL_TRANSFORMATION" in SimulationEngine.CONSTRUCTION_PROJECT_TYPES, "the generic ConstructionProject model retains earlier project types and supports class-specific Storage infrastructure")
	var capital_goods: Array = database.industry_rules.get("capital_goods", [])
	_check(capital_goods.size() == 8, "the core capital system exposes eight reusable Capital Goods")
	for item_id_value in capital_goods:
		var item_id := str(item_id_value)
		var repeat_producers := 0
		var construction_consumers := 0
		for activity_value in database.activities.values():
			var activity := activity_value as Dictionary
			if bool(activity.get("repeat", true)) and _entry_amount(activity.get("rewards", []), item_id) > 0:
				repeat_producers += 1
			if simulation.is_construction_activity(activity) and _entry_amount(activity.get("costs", []), item_id) > 0:
				construction_consumers += 1
		_check(repeat_producers >= 1 and construction_consumers >= 2, "Capital Good %s has a repeatable source and multiple construction sinks" % item_id)
	var machine_tools: Dictionary = database.activities.get("fabricate_basic_machine_tools", {})
	_check(str(machine_tools.get("facility", "")) == "makeshift_workshop" and (machine_tools.get("requirements", []) as Array).all(func(requirement): return str((requirement as Dictionary).get("type", "")) != "facility_level"), "basic machine tools retain a permanent low-technology recovery route")
	var guide_localization = load("res://src/application/localization.gd").new()
	guide_localization._load_translations()
	guide_localization.current_locale = "zh_CN"
	_check(guide_localization.goal_step("upgrade_construction_yard_ii", "").contains("工业机床") and guide_localization.goal_step("build_energy_array", "").contains("重型结构段") and guide_localization.goal_step("stellar_forward_base", "").contains("资本品"), "the Guide explicitly names the Capital Goods required before construction gates")
	guide_localization.free()
	_check(simulation.construction_project_type_for_activity(database.activities["build_lunar_extraction_network"]) == "EXTRACTION_NETWORK" and simulation.construction_project_type_for_activity(database.activities["construct_stellar_forward_base"]) == "MEGASTRUCTURE", "content-backed extraction networks and Megastructure phases map to their generic project types")

	var bootstrap_state := _new_state(database, simulation)
	bootstrap_state.ensure_location("capital_bootstrap", LocationState.NATURAL, true, "sol")
	_check(not simulation.industry_expansion_costs(bootstrap_state, "capital_bootstrap", "makeshift_workshop", 1).has("industrial_machine_tools"), "Industry Level 1 remains buildable without a circular Capital Good dependency")
	bootstrap_state.ensure_location_industry("capital_bootstrap", "makeshift_workshop", 1)
	_check(int(simulation.industry_expansion_costs(bootstrap_state, "capital_bootstrap", "makeshift_workshop", 1).get("industrial_machine_tools", 0)) > 0, "Industry Level 2 begins the recoverable machine-tool demand curve")
	var capital_blocker_state := _new_state(database, simulation)
	capital_blocker_state.add_item("iron_ingot", 100)
	capital_blocker_state.add_item("electronics", 100)
	simulation.queue_facility_expansion(capital_blocker_state, "earth_orbit", "makeshift_workshop", 2, 50)
	var capital_blocker_runtime: Dictionary = capital_blocker_state.construction_operations[0]
	capital_blocker_runtime["paid_cycles"] = 99
	capital_blocker_runtime["project_cycles_completed"] = 99
	capital_blocker_runtime["consumed"] = capital_blocker_runtime.get("material_plan", {}).duplicate(true)
	capital_blocker_runtime["consumed"].erase("industrial_machine_tools")
	simulation.advance(capital_blocker_state, 0.0)
	_check(str(capital_blocker_state.construction_operations[0].get("blocker", {}).get("primary_reason", "")) == "MISSING_CAPITAL_GOOD" and str(capital_blocker_state.construction_operations[0].get("blocker", {}).get("item_id", "")) == "industrial_machine_tools", "a blocked phase-two project identifies its exact missing Capital Good")

	var queue_state := _new_state(database, simulation)
	queue_state.facilities["orbital_construction_yard"]["level"] = 1
	for item_id in ["iron_ingot", "electronics", "industrial_machine_tools", "heavy_structural_section", "precision_actuator"]:
		queue_state.add_item(item_id, 100)
	_check(simulation.queue_facility_expansion(queue_state, "earth_orbit", "makeshift_workshop", 2, 20), "facility expansion enters the generic Construction queue")
	_check(simulation.queue_location_capacity_upgrade(queue_state, "earth_orbit", "LOGISTICS_HUB_UPGRADE", 125, 90), "Location capacity upgrades enter the same Construction queue")
	var priority_project: Dictionary = queue_state.construction_operations[0]
	var queued_project: Dictionary = queue_state.construction_operations[1]
	var required_fields := ["project_id", "project_type", "location_id", "target_id", "start_level", "target_level", "priority", "slot", "total_work", "completed_work", "material_plan", "delivered_materials", "in_transit_materials", "consumed", "status", "blocker"]
	_check(required_fields.all(func(field): return priority_project.has(field)) and is_equal_approx(float(priority_project.get("total_work", 0.0)), 35.0), "generic ConstructionProject persists every required planning, progress, material and blocker field")
	_check(str(priority_project.get("project_type", "")) == "LOGISTICS_HUB_UPGRADE" and str(priority_project.get("status", "")) == "RUNNING" and str(queued_project.get("project_type", "")) == "FACILITY_EXPANSION" and str(queued_project.get("status", "")) == "QUEUED", "priority controls the single active project at Construction Engineering I")
	var queue_round_trip := SpaceGameState.from_dictionary(queue_state.to_dictionary(), database.domains.keys(), database.regions)
	_check(not simulation.construction_activity_for_runtime(queue_round_trip.construction_operations[0]).is_empty() and queue_round_trip.construction_operations[0].get("material_plan", {}) == priority_project.get("material_plan", {}) and queue_round_trip.next_construction_project_serial == 3, "dynamic project definitions, material plans and collision-free IDs survive save/load")
	queue_state.facilities["orbital_construction_yard"]["level"] = 2
	simulation.normalize_construction_queue(queue_state)
	priority_project = queue_state.construction_operations[0]
	queued_project = queue_state.construction_operations[1]
	_check(str(priority_project.get("status", "")) == "RUNNING" and str(queued_project.get("status", "")) == "RUNNING" and is_equal_approx(simulation.construction_project_allocated_capacity(queue_state, priority_project), 0.5) and is_equal_approx(simulation.construction_project_allocated_capacity(queue_state, queued_project), 0.5), "multiple projects compete for finite civilization Construction capacity")
	var priority_activity := simulation.construction_activity_for_runtime(priority_project)
	for _segment in 99:
		simulation._complete_construction_cycle(queue_state, priority_project, priority_activity)
	simulation._refresh_resource_commitments(queue_state)
	queue_state.logistics_network["shipments"] = [{"id":"SHIPMENT-CANCEL-TEST", "origin":"lunar_space", "destination":"earth_orbit", "cargo":{"precision_actuator":1}, "remaining_ms":1000.0}]
	var consumed_before_cancel: Dictionary = priority_project.get("consumed", {}).duplicate(true)
	var inventory_before_cancel := queue_state.total_inventory_units("earth_orbit")
	var cancellation := simulation.cancel_construction_project(queue_state, priority_project)
	_check(not consumed_before_cancel.is_empty() and cancellation.get("consumed_lost", {}) == consumed_before_cancel and not cancellation.get("delivered_released", {}).is_empty() and queue_state.total_inventory_units("earth_orbit") == inventory_before_cancel, "cancelling a partially built project records consumed losses and releases commitments without duplicating inventory")
	_check(str(cancellation.get("in_transit_destination", "")) == "earth_orbit" and str(queue_state.logistics_network.get("shipments", [])[0].get("destination", "")) == "earth_orbit", "cancelling a project leaves in-transit material owned by its original destination")
	_check(str(queue_state.construction_history[-1].get("status", "")) == "CANCELLED" and str(queue_state.construction_operations[0].get("project_type", "")) == "FACILITY_EXPANSION", "cancellation is auditable and immediately promotes the next queued project")

	var megastructure_state := _new_state(database, simulation)
	megastructure_state.facilities["orbital_construction_yard"]["level"] = 3
	megastructure_state.facilities["assembly_yard"] = {"level":1, "status":"ACTIVE", "installed_process_modules":[], "installed_plugins":[]}
	megastructure_state.technologies["megastructure_engineering"] = true
	var megastructure_activity: Dictionary = database.activities["construct_stellar_forward_base"]
	var megastructure_runtime: Dictionary = megastructure_state.construction_operations[0]
	megastructure_runtime.merge({"activity_id":"construct_stellar_forward_base", "status":"RUNNING"}, true)
	simulation.initialize_construction_project(megastructure_state, megastructure_runtime, megastructure_activity, "earth_orbit", 80)
	simulation.begin_megastructure_project(megastructure_state, megastructure_runtime, megastructure_activity)
	_check(simulation.queue_facility_expansion(megastructure_state, "earth_orbit", "makeshift_workshop", 2, 40), "ordinary expansion can queue beside a live Megastructure")
	var competing_megastructure: Dictionary = megastructure_state.construction_operations[0]
	var competing_expansion: Dictionary = megastructure_state.construction_operations[1]
	_check(str(competing_megastructure.get("project_type", "")) == "MEGASTRUCTURE" and str(competing_expansion.get("project_type", "")) == "FACILITY_EXPANSION" and is_equal_approx(simulation.construction_project_allocated_capacity(megastructure_state, competing_megastructure), 0.5) and is_equal_approx(simulation.construction_project_allocated_capacity(megastructure_state, competing_expansion), 0.5), "Megastructures and ordinary expansion draw from the same core Construction capacity")
	var local_capacity_state := _new_state(database, simulation)
	local_capacity_state.ensure_location("remote_construction", LocationState.NATURAL, true, "sol")
	simulation._install_survey_staging_package(local_capacity_state, "remote_construction")
	local_capacity_state.facilities["orbital_construction_yard"]["level"] = 2
	local_capacity_state.facilities["orbital_construction_yard"]["installed_modules"] = ["prefabrication_line"]
	simulation.queue_facility_expansion(local_capacity_state, "remote_construction", "makeshift_workshop", 1, 60)
	simulation.queue_location_capacity_upgrade(local_capacity_state, "remote_construction", "LOGISTICS_HUB_UPGRADE", 125, 50)
	var local_capacity_total := simulation.construction_project_allocated_capacity(local_capacity_state, local_capacity_state.construction_operations[0]) + simulation.construction_project_allocated_capacity(local_capacity_state, local_capacity_state.construction_operations[1])
	_check(is_equal_approx(local_capacity_total, 1.0), "projects at one Location divide rather than multiply that Location's finite Construction capacity")
	var construction_demand_rows: Array = simulation.logistics._demand_rows(local_capacity_state).filter(func(row): return str(row.get("location_id", "")) == "remote_construction" and str(row.get("item_id", "")) == "electronics")
	_check(construction_demand_rows.size() == 2 and int(construction_demand_rows[0].get("target", 0)) == 1 and int(construction_demand_rows[1].get("target", 0)) == 2, "same-item freight demand accumulates across prioritized Construction projects while requesting only the next balanced finite-storage tranche")
	var first_project_demands: Array = simulation.logistics._demand_rows(local_capacity_state).filter(func(row): return str(row.get("project_id", "")) == str(local_capacity_state.construction_operations[0].get("project_id", "")))
	var first_project_items := {}
	for demand_value in first_project_demands:
		var demand := demand_value as Dictionary
		first_project_items[str(demand.get("item_id", ""))] = int(demand.get("target", 0))
	_check(first_project_items.size() == local_capacity_state.construction_operations[0].get("material_plan", {}).size() and first_project_items.values().all(func(quantity): return int(quantity) >= 1), "finite remote staging requests a non-zero balanced tranche for every complementary Construction BOM item")
	local_capacity_state.logistics_network["shipments"] = [{"id":"SHIPMENT-SHARED-INCOMING", "origin":"earth_orbit", "destination":"remote_construction", "cargo":{"electronics":3}, "remaining_ms":1000.0}]
	simulation.refresh_location_summaries(local_capacity_state)
	var allocated_incoming_total := int(local_capacity_state.construction_operations[0].get("in_transit_materials", {}).get("electronics", 0)) + int(local_capacity_state.construction_operations[1].get("in_transit_materials", {}).get("electronics", 0))
	_check(allocated_incoming_total == 3, "one in-transit cargo allocation is never displayed or claimed by two Construction projects")

	var capacity_state := _new_state(database, simulation)
	for item_id in ["industrial_machine_tools", "precision_actuator", "electronics"]:
		capacity_state.add_item(item_id, 10)
	var starting_throughput := int(capacity_state.location_state("earth_orbit").get("logistics", {}).get("hub_throughput", 0))
	_check(simulation.queue_location_capacity_upgrade(capacity_state, "earth_orbit", "LOGISTICS_HUB_UPGRADE", starting_throughput + 25, 50), "a Logistics Hub upgrade can be queued at its fixed construction increment")
	var capacity_runtime: Dictionary = capacity_state.construction_operations[0]
	var capacity_activity := simulation.construction_activity_for_runtime(capacity_runtime)
	for _segment in 50:
		simulation._complete_construction_cycle(capacity_state, capacity_runtime, capacity_activity)
	_check(int(capacity_state.location_state("earth_orbit").get("logistics", {}).get("hub_throughput", 0)) == starting_throughput and not capacity_runtime.get("consumed", {}).is_empty(), "capacity remains unchanged while project materials are consumed progressively")
	for _segment in 50:
		simulation._complete_construction_cycle(capacity_state, capacity_runtime, capacity_activity)
	_check(int(capacity_state.location_state("earth_orbit").get("logistics", {}).get("hub_throughput", 0)) == starting_throughput + 25 and str(capacity_state.construction_history[-1].get("status", "")) == "COMPLETE", "capacity changes only when its ConstructionProject completes")

	var bulk_state := _new_state(database, simulation)
	var segmented_state := _new_state(database, simulation)
	for comparison_state in [bulk_state, segmented_state]:
		comparison_state.add_item("industrial_machine_tools", 10)
		comparison_state.add_item("precision_actuator", 10)
		comparison_state.add_item("electronics", 10)
		simulation.queue_location_capacity_upgrade(comparison_state, "earth_orbit", "LOGISTICS_HUB_UPGRADE", 125, 50)
	simulation.advance(bulk_state, 2100.0)
	for _slice in 21:
		simulation.advance(segmented_state, 100.0)
	var bulk_runtime: Dictionary = bulk_state.construction_operations[0]
	var segmented_runtime: Dictionary = segmented_state.construction_operations[0]
	_check(int(bulk_runtime.get("project_cycles_completed", 0)) == int(segmented_runtime.get("project_cycles_completed", 0)) and is_equal_approx(float(bulk_runtime.get("cycle_progress", 0.0)), float(segmented_runtime.get("cycle_progress", 0.0))) and bulk_runtime.get("consumed", {}) == segmented_runtime.get("consumed", {}) and bulk_state.location_inventory("earth_orbit") == segmented_state.location_inventory("earth_orbit"), "bulk and segmented time advancement produce identical ConstructionProject progress and material ownership")

	var legacy_data := capacity_state.to_dictionary()
	legacy_data["save_version"] = 27
	legacy_data["construction_operations"][0] = {"slot":0, "domain":"construction", "activity_id":"build_orbital_foundry", "status":"BLOCKED", "project_cycles_completed":25, "paid_cycles":25, "consumed":{"iron_ingot":1}, "location_id":"earth_orbit"}
	var migrated := SpaceGameState.from_dictionary(legacy_data, database.domains.keys(), database.regions)
	simulation._migrate_legacy_construction_progress(migrated)
	var migrated_project: Dictionary = migrated.construction_operations[0]
	_check(not str(migrated_project.get("project_id", "")).is_empty() and str(migrated_project.get("project_type", "")) == "FACILITY_BUILD" and is_equal_approx(float(migrated_project.get("completed_work", 0.0)), 7.5) and not migrated_project.get("material_plan", {}).is_empty(), "schema 27 live construction migrates into the generic project model without retroactive capital charges")


func _goal_step_index(steps: Array, step_id: String) -> int:
	for index in steps.size():
		if str((steps[index] as Dictionary).get("id", "")) == step_id:
			return index
	return 1000000


func _test_phase_three_production_lines(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.facilities["orbital_foundry"] = {"level":1, "status":"ACTIVE", "installed_process_modules":["advanced_alloy_cell"], "installed_plugins":[]}
	state.regions["asteroid_belt"] = true
	state.technologies["heavy_industry"] = true
	var foundry := state.ensure_location_industry("earth_orbit", "orbital_foundry", 10)
	foundry["level"] = 10
	foundry["scale_stage"] = "INDUSTRIAL_COMPLEX"
	var low_line := state.ensure_industrial_operation("earth_orbit", "orbital_foundry")
	var high_line := state.create_production_line("earth_orbit", "orbital_foundry")
	low_line.merge({"activity_id":"refine_steel", "method_id":"refine_steel", "product_family_id":"steel_composite", "status":"RUNNING", "capacity_allocation":25.0, "priority":20}, true)
	high_line.merge({"activity_id":"refine_steel", "method_id":"refine_steel", "product_family_id":"steel_composite", "status":"RUNNING", "capacity_allocation":75.0, "priority":90}, true)
	for item_id in ["iron_ingot", "cobalt_ingot", "silicate_ceramic"]:
		state.add_item(item_id, 100)
	var facility_capacity := simulation.facility_manufacturing_throughput(state, "orbital_foundry")
	var low_throughput := simulation.production_line_throughput(state, low_line)
	var high_throughput := simulation.production_line_throughput(state, high_line)
	var low_duration := simulation.effective_duration_ms(state, "industry", database.activities["refine_steel"], low_line)
	var high_duration := simulation.effective_duration_ms(state, "industry", database.activities["refine_steel"], high_line)
	_check(is_equal_approx(low_throughput + high_throughput, facility_capacity) and is_equal_approx(high_throughput, low_throughput) and is_equal_approx(low_duration, high_duration), "active Production Lines automatically divide one real Factory instead of using player-maintained percentages")
	var required_line_fields := ["line_id", "product_family_id", "method_id", "production_device_id", "control_mode", "manual_lock", "priority", "cycle_progress", "input_commitments", "fractional_materials", "theoretical_rate", "actual_rate", "status", "blocked_reason"]
	_check(required_line_fields.all(func(field): return high_line.has(field)) and float(high_line.get("theoretical_rate", 0.0)) > 0.0 and float(high_line.get("actual_rate", 0.0)) > 0.0, "Production Line state exposes its real Device, Method, control, commitment, rate and blocker diagnostics")
	state.locations["earth_orbit"]["inventory"]["iron_ingot"] = 2
	simulation.advance(state, 0.0)
	_check(not high_line.get("input_commitments", {}).is_empty() and low_line.get("input_commitments", {}).is_empty() and str(high_line.get("status", "")) == "RUNNING" and str(low_line.get("status", "")) == "BLOCKED" and is_equal_approx(simulation.production_line_throughput(state, high_line), facility_capacity), "Production Line priority wins scarce input commitments and automatically reallocates blocked capacity")

	var method_state := _new_state(database, simulation)
	method_state.facilities["orbital_foundry"] = {"level":1, "status":"ACTIVE", "installed_process_modules":["advanced_alloy_cell"], "installed_plugins":[]}
	method_state.regions["asteroid_belt"] = true
	method_state.technologies["heavy_industry"] = true
	var method_industry := method_state.ensure_location_industry("earth_orbit", "orbital_foundry", 5)
	method_industry.merge({"level":5, "scale_stage":"FACTORY"}, true)
	var method_line := method_state.ensure_industrial_operation("earth_orbit", "orbital_foundry")
	method_line.merge({"activity_id":"refine_steel", "status":"RUNNING", "capacity_allocation":100.0, "material_savings_fractional":{}, "waste_fractional":{}}, true)
	for item_id in ["iron_ingot", "cobalt_ingot", "silicate_ceramic"]:
		method_state.add_item(item_id, 100)
	var conventional_duration := simulation.effective_duration_ms(method_state, "industry", database.activities["refine_steel"], method_line)
	var conventional_constraints := simulation.location_industry_constraint_profile(method_state, "earth_orbit")
	var waste_before := method_state.item_quantity("industrial_waste")
	simulation._complete_runtime_cycle(method_state, "industry", method_line, database.activities["refine_steel"])
	method_line.merge({"activity_id":"refine_steel_electric", "method_id":"refine_steel_electric", "status":"RUNNING", "material_savings_fractional":{}, "waste_fractional":{}}, true)
	var electric_duration := simulation.effective_duration_ms(method_state, "industry", database.activities["refine_steel_electric"], method_line)
	var electric_constraints := simulation.location_industry_constraint_profile(method_state, "earth_orbit")
	_check(electric_duration < conventional_duration and float(electric_constraints.get("power_demand", 0.0)) > float(conventional_constraints.get("power_demand", 0.0)) and float(electric_constraints.get("cooling_demand", 0.0)) > float(conventional_constraints.get("cooling_demand", 0.0)) and _entry_amount(database.activities["refine_steel_electric"].get("costs", []), "silicate_ceramic") == 0 and method_state.item_quantity("industrial_waste") == waste_before + 1, "Steel Production Methods change throughput, input, Power, Cooling and Waste constraints")

	var scale_state := _new_state(database, simulation)
	var scale_industry := scale_state.ensure_location_industry("earth_orbit", "makeshift_workshop", 4)
	scale_industry.merge({"level":4, "scale_stage":"WORKSHOP"}, true)
	for item_id in ["iron_ingot", "industrial_machine_tools", "heavy_structural_section", "electronics", "precision_actuator", "power_bus_component"]:
		scale_state.add_item(item_id, 100)
	_check(not simulation.queue_facility_expansion(scale_state, "earth_orbit", "makeshift_workshop", 5, 50), "ordinary Facility expansion cannot cross an Industry Scale Stage boundary")
	_check(simulation.queue_scale_stage_upgrade(scale_state, "earth_orbit", "makeshift_workshop", 70) and str(scale_state.construction_operations[0].get("project_type", "")) == "SCALE_STAGE_UPGRADE", "cross-stage growth enters the shared Construction queue as a Scale Stage project")
	var scale_project: Dictionary = scale_state.construction_operations[0]
	var scale_activity := simulation.construction_activity_for_runtime(scale_project)
	for _segment in 100:
		simulation._complete_construction_cycle(scale_state, scale_project, scale_activity)
	_check(int(scale_industry.get("level", 0)) == 5 and str(scale_industry.get("scale_stage", "")) == "FACTORY", "Scale Stage abilities change only when the 100-Cycle construction project completes")

	foundry["level"] = 10
	foundry["scale_stage"] = "INDUSTRIAL_COMPLEX"
	state.facilities["electronics_facility"] = {"level":1, "status":"ACTIVE", "installed_process_modules":[], "installed_plugins":[]}
	var electronics_industry := state.ensure_location_industry("earth_orbit", "electronics_facility", 10)
	electronics_industry.merge({"level":10, "scale_stage":"INDUSTRIAL_COMPLEX"}, true)
	for item_id in ["heavy_structural_section", "industrial_machine_tools", "precision_actuator", "power_bus_component"]:
		state.add_item(item_id, 100)
	var baseline_specialized_capacity := simulation.facility_manufacturing_throughput(state, "orbital_foundry")
	state.location_state("earth_orbit")["industry"]["specialization_id"] = "BULK_METALLURGY"
	_check(not simulation.queue_location_specialization(state, "earth_orbit", "BULK_METALLURGY", 60) and is_equal_approx(simulation.facility_manufacturing_throughput(state, "orbital_foundry"), baseline_specialized_capacity), "legacy Location professions are inert and cannot impose hard-coded production bonuses")

	var round_trip := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(round_trip.production_lines_for("earth_orbit", "orbital_foundry").size() == 2 and round_trip.next_production_line_serial > state.industrial_operations.size(), "Production Lines, stable IDs and Scale Stages survive save/load")
	var legacy_data := state.to_dictionary()
	legacy_data["save_version"] = 28
	legacy_data.erase("next_production_line_serial")
	for line_value in legacy_data.get("industrial_operations", []):
		for field in ["line_id", "product_family_id", "method_id", "capacity_allocation", "priority", "input_commitments", "fractional_materials", "theoretical_rate", "actual_rate"]:
			(line_value as Dictionary).erase(field)
	for local_industry_value in legacy_data.get("locations", {}).get("earth_orbit", {}).get("industry", {}).get("industries", {}).values():
		(local_industry_value as Dictionary).erase("scale_stage")
	var migrated := SpaceGameState.from_dictionary(legacy_data, database.domains.keys(), database.regions)
	_check(not str(migrated.production_lines_for("earth_orbit", "orbital_foundry")[0].get("line_id", "")).is_empty() and str(migrated.location_industry("earth_orbit", "orbital_foundry").get("scale_stage", "")) == "INDUSTRIAL_COMPLEX", "schema 28 facilities migrate to stable Production Line IDs and infer their earned Scale Stage without losing progress")
	var guide_localization = load("res://src/application/localization.gd").new()
	guide_localization._load_translations()
	guide_localization.current_locale = "zh_CN"
	var steel_guidance: String = guide_localization.goal_step("produce_steel", "")
	_check(steel_guidance.contains("电弧法") and steel_guidance.contains("多条产线"), "the Guide tells players where Production Methods and multi-line allocation enter progression")
	guide_localization.free()


func _test_structured_blocker_diagnostics(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	var runtime: Dictionary = state.industrial_operations[0]
	runtime.merge({"activity_id":"refine_iron", "status":"BLOCKED", "progress_ms":0.0}, true)
	simulation.advance(state, 0.0)
	var blocker: Dictionary = runtime.get("blocker", {})
	_check(str(blocker.get("primary_reason", "")) == "INPUT_SHORTAGE" and str(blocker.get("item_id", "")) == "iron_ore" and int(blocker.get("required", 0)) == 2 and int(blocker.get("available", -1)) == 0 and str(blocker.get("location_id", "")) == SpaceGameState.MAIN_BASE_LOCATION_ID, "blocked Industry exposes a structured, item-specific primary diagnosis")
	state.logistics_network["shipments"] = [{"id":"SHIPMENT-BLOCKER-TEST", "origin":"lunar_surface", "destination":SpaceGameState.MAIN_BASE_LOCATION_ID, "cargo":{"iron_ore":2}, "remaining_ms":10000.0}]
	simulation.advance(state, 0.0)
	blocker = runtime.get("blocker", {})
	_check(str(blocker.get("primary_reason", "")) == "INPUT_IN_TRANSIT" and int(blocker.get("incoming", 0)) == 2, "the same core diagnosis distinguishes missing inventory from inventory already in transit")

	state.research.merge({"project_id":"research_heavy_extraction", "status":"BLOCKED", "progress_ms":0.0, "consumed":{}, "blocked_reason":"RESERVE:silicate_ore"}, true)
	simulation.advance(state, 0.0)
	var research_blocker: Dictionary = state.research.get("blocker", {})
	_check(str(research_blocker.get("primary_reason", "")) == "MISSING_TECH" or (str(research_blocker.get("primary_reason", "")) in ["INPUT_SHORTAGE", "INPUT_IN_TRANSIT"] and not str(research_blocker.get("item_id", "")).is_empty()), "blocked Research always identifies either its exact prerequisite or exact material")

	var automation: Dictionary = state.locations[SpaceGameState.MAIN_BASE_LOCATION_ID].get("automation", {})
	automation["last_blocked_reason"] = "FACILITY_LOCKED"
	simulation.advance(state, 0.0)
	var automation_blocker: Dictionary = automation.get("blocker", {})
	_check(str(automation_blocker.get("primary_reason", "")) == "MISSING_FACILITY" and str(automation_blocker.get("location_id", "")) == SpaceGameState.MAIN_BASE_LOCATION_ID, "automation uses the same structured blocker contract and preserves its owning location")
	for diagnostic in [blocker, research_blocker, automation_blocker]:
		_check(str(diagnostic.get("primary_reason", "")) in SimulationEngine.BLOCKER_REASON_CODES and str(diagnostic.get("status", "")) == "BLOCKED", "every emitted blocker uses a canonical phase-one reason code")


func _test_frontier_content(database: ContentDatabase) -> void:
	_check(not database.domains.has("salvaging") and database.activities.values().all(func(activity): return str(activity.get("domain", "")) != "salvaging"), "the retired salvage domain has no content or runtime entry")
	_check(database.resource_regions.has("lunar_mare_region") and database.resource_regions.has("lunar_polar_region") and database.resource_regions.has("lunar_kreep_region"), "the Moon has distinct resource geography")
	_check(database.mining_sites.values().all(func(site): return int(site.get("mastery_cycles_per_level", 0)) > 0 and not site.has("reserve_cycles")), "extraction sites are permanent and use deterministic mastery")
	_check(database.activities_by_domain["mining"].all(func(activity): return str(activity.get("raw_material", "")) in ["mixed_raw_ore", "mixed_raw_gas"] and not activity.has("target_resource") and not activity.has("loot")), "mining has no resource picker or random payout path")
	_check(database.ships.values().all(func(ship): return not ship.has("base_mining_power")), "hulls have no intrinsic mining role; equipment supplies extraction capability")
	_check(database.mining_hazards.values().all(func(hazard): return not hazard.has("failure_chance") and not hazard.has("repair_ms")), "mining hazards modify predictable throughput without random failures")
	_check(database.combat_areas["lunar_pirate_relay"].get("area_type", "") == "FIRST_CLEAR", "the Lunar relay is a first-clear strategic objective")
	_check(database.combat_areas["lunar_transfer_interception"].get("area_type", "") == "REPEATABLE", "secured Lunar space retains repeatable combat")
	_check(database.expedition_routes["lunar_route"].get("nodes", []).all(func(node): return str(node.get("phase", "")) not in ["COMBAT", "BOSS"]), "Lunar survey does not secretly resolve the Boss")
	_check(database.expedition_routes["lunar_relay_assault"].get("nodes", []).any(func(node): return str(node.get("phase", "")) == "BOSS" and str(node.get("enemy", "")) == "lunar_corsair"), "the named Lunar Boss exists in a separate first-clear assault")
	_check(float(database.extraction_networks["lunar_extraction_network"].get("efficiency_ratio", 1.0)) < 1.0 and not database.extraction_networks["lunar_extraction_network"].has("modes"), "automatic mining is stable, below ship efficiency and has no mineral selector")
	var frontier_state := _new_state(database)
	_check(not frontier_state.mining_site_available("belt_cobalt_frontier"), "a future-region extraction site starts undiscovered")
	frontier_state.regions["asteroid_belt"] = true
	SimulationEngine.new(database).ensure_frontier_state(frontier_state)
	_check(str(frontier_state.location_state("asteroid_belt").get("survey_state", "")) == LocationState.DETECTED and not frontier_state.mining_site_available("belt_cobalt_frontier"), "unlocking a non-Lunar region detects its sites without leaking Surveyed extraction data")
	frontier_state.location_state("asteroid_belt")["survey_state"] = LocationState.SURVEYED
	frontier_state.region_states["asteroid_belt"]["survey_state"] = LocationState.SURVEYED
	SimulationEngine.new(database).ensure_frontier_state(frontier_state)
	_check(frontier_state.mining_site_available("belt_cobalt_frontier"), "a normal Survey makes the detected permanent extraction site operational for mobile assets")


func _test_physical_ship_assets(database: ContentDatabase) -> void:
	var state := _new_state(database)
	var starter: Dictionary = state.ships[0]
	_check(starter.get("modules", []).all(func(value): return not str(value).begins_with("EQUIP-")) and state.equipment_instances.is_empty(), "ordinary Loadout modules are definitions rather than single-item inventory entities")
	_check(state.ship_module_definition_ids(starter).has("mining_laser"), "the starter design configuration is mining-first")
	var second_ship := state._create_ship_instance("patchwork_prospector", [], "ISS Second")
	_check(not second_ship.is_empty() and state.ships.size() == 2, "multiple unique ship instances may share one hull design")
	starter["modules"].erase("light_autocannon")
	var special_id := state.create_equipment_instance("corsair_overcharged_laser", "TEST")
	_check(state.install_equipment_instance(special_id, str(starter.get("instance_id", ""))), "recovered special equipment retains a physical instance")
	_check(not state.install_equipment_instance(special_id, str(second_ship.get("instance_id", ""))), "one special equipment instance cannot be installed on two ships")
	_check(state.store_equipment_instance(special_id) and state.stored_equipment_ids("corsair_overcharged_laser").has(special_id), "removed special equipment returns to Starport storage")
	_check(state.install_equipment_instance(special_id, str(second_ship.get("instance_id", ""))), "stored special equipment can be reassigned to another docked asset")
	_check(database.module_bom("mining_laser") == [{"item":"iron_ingot", "quantity":2}, {"item":"copper_ingot", "quantity":2}, {"item":"electronics", "quantity":1}], "ordinary module designs resolve to deterministic closed-economy manufacturing BOMs")
	var fitting_error := database.ship_loadout_error("patchwork_prospector", state.ship_module_definition_ids(starter))
	var hull_stats: Dictionary = database.ships["patchwork_prospector"].get("base_stats", {})
	_check(fitting_error.is_empty() and hull_stats.has("mass_capacity") and hull_stats.has("power_capacity") and hull_stats.has("thermal_capacity"), "ship fitting exposes Mass, Power and Thermal budgets")
	_check(int(database.ships["patchwork_prospector"].get("cargo_capacity", 0)) > 0 and not hull_stats.has("cargo_capacity"), "Cargo is a mission capability, not a fourth engineering budget")


func _test_permanent_extraction(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	var ship_id := str(state.ships[0].get("instance_id", ""))
	_check(simulation.mining_power(state, [ship_id]) > 0.0, "the starter prospector can mine without a prerequisite refit")
	state.mining_operations.append(SpaceGameState.create_operation_record(0, "mining"))
	var earth_activity: Dictionary = database.activities["extract_earth_mixed_ore"]
	_start_frontier_operation(state, state.mining_operations[0], earth_activity, [ship_id], {"site_id":"earth_resource_cluster_prospect", "location_id":"earth_iron_cluster", "raw_material_id":"mixed_raw_ore"})
	var duration := simulation.effective_duration_ms(state, "mining", earth_activity, state.mining_operations[0])
	var configured_speed := simulation.simulation_speed_multiplier("mining")
	_check(simulation.set_simulation_profile("NORMAL_PROFILE"), "normal simulation profile is selectable")
	var baseline_duration := simulation.effective_duration_ms(state, "mining", earth_activity, state.mining_operations[0])
	_check(simulation.set_simulation_profile("TEST_PROFILE"), "test simulation profile is selectable")
	_check(is_equal_approx(configured_speed, 10.0) and is_equal_approx(duration * 10.0, baseline_duration), "active ship mining uses the same configured tenfold speed multiplier as manufacturing")
	var before: int = state.item_quantity("mixed_raw_ore")
	simulation.advance(state, duration * 12.0)
	_check(state.item_quantity("mixed_raw_ore") == before + 24, "permanent extraction produces only its stable mixed raw material at a predictable rate")
	_check(state.mining_operations[0].get("status", "") == "RUNNING", "a permanent extraction site never depletes or releases ships unexpectedly")
	_check(int(state.mining_site_states["earth_resource_cluster_prospect"].get("mastery_level", 0)) == 1, "site mastery grows deterministically from completed Cycles")
	_check(state.item_quantity("iron_ore") == 0 and state.item_quantity("copper_ore") == 0, "specific minerals are produced by Industry rather than selected at the mining site")

	var two_ship_state := _new_state(database, simulation)
	var first_id := str(two_ship_state.ships[0].get("instance_id", ""))
	var second := two_ship_state._create_ship_instance("lunar_pathfinder", ["mining_laser"], "ISS Independent")
	var second_id := str(second.get("instance_id", ""))
	two_ship_state.mining_operations.append(SpaceGameState.create_operation_record(0, "mining"))
	_start_frontier_operation(two_ship_state, two_ship_state.mining_operations[0], earth_activity, [first_id], {"site_id":"earth_resource_cluster_prospect", "location_id":"earth_iron_cluster", "raw_material_id":"mixed_raw_ore"})
	var one_ship_duration := simulation.effective_duration_ms(two_ship_state, "mining", earth_activity, two_ship_state.mining_operations[0])
	two_ship_state.mining_operations[0]["assigned_ship_ids"].append(second_id)
	var two_ship_duration := simulation.effective_duration_ms(two_ship_state, "mining", earth_activity, two_ship_state.mining_operations[0])
	_check(two_ship_duration < one_ship_duration, "multiple equipped ships can bind to the same permanent site and predictably increase throughput")
	var third := two_ship_state._create_ship_instance("lunar_pathfinder", ["mining_laser"], "ISS Potential Cap")
	two_ship_state.mining_operations[0]["assigned_ship_ids"].append(str(third.get("instance_id", "")))
	var capped_duration := simulation.effective_duration_ms(two_ship_state, "mining", earth_activity, two_ship_state.mining_operations[0])
	_check(is_equal_approx(capped_duration, two_ship_duration) and is_equal_approx(float(two_ship_state.mining_operations[0].get("effective_mining_power", 0.0)), 20.0), "Site Extraction Potential caps vertical ship stacking and forces horizontal expansion")
	two_ship_state.mining_operations[0]["assigned_ship_ids"].erase(str(third.get("instance_id", "")))
	_check(simulation.extraction_command_usage(two_ship_state) == 26 and simulation.extraction_command_usage(two_ship_state) <= simulation.extraction_command_capacity(two_ship_state), "bound ships consume their distinct Extraction Command values")
	two_ship_state.extraction_command["capacity"] = 20
	_check(simulation.extraction_command_usage(two_ship_state) > simulation.extraction_command_capacity(two_ship_state), "Extraction Command Capacity prevents unlimited ship stacking")

	var deferred_state := _new_state(database, simulation)
	deferred_state.region_states["lunar_space"].merge({"discovered":true, "survey_state":LocationState.SURVEYED, "exploration_state":LocationState.SURVEYED}, true)
	deferred_state.mining_site_states["lunar_deep_helium_anomaly"].merge({"discovered":true, "survey_state":LocationState.SURVEYED}, true)
	simulation.ensure_frontier_state(deferred_state)
	_check(not deferred_state.mining_site_available("lunar_deep_helium_anomaly"), "a deferred permanent site remains visible but inaccessible without the required technology")
	deferred_state.technologies["heavy_extraction"] = true
	simulation.ensure_frontier_state(deferred_state)
	_check(deferred_state.mining_site_available("lunar_deep_helium_anomaly"), "new technology can reopen an old discovered permanent site")


func _test_mature_extraction_network(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	var ship_id := str(state.ships[0].get("instance_id", ""))
	state.mining_operations.append(SpaceGameState.create_operation_record(0, "mining"))
	_start_frontier_operation(state, state.mining_operations[0], database.activities["extract_earth_mixed_ore"], [ship_id], {"site_id":"earth_resource_cluster_prospect", "location_id":"earth_iron_cluster", "raw_material_id":"mixed_raw_ore"})
	state.mining_site_states["earth_resource_cluster_prospect"]["mastery_level"] = 2
	state.technologies["industrial_coordination"] = true
	state.extraction_network_states["earth_extraction_network"].merge({"unlocked":true, "status":"IDLE"}, true)
	_check(simulation.integrate_mining_site(state, "earth_resource_cluster_prospect", "earth_extraction_network"), "a mastered site with sufficient extraction technology and material grade can join its regional network")
	_check(state.ship_is_docked(ship_id) and state.mining_operations[0].get("status", "") == "INTEGRATED", "integration releases bound ships for other work")
	var before := state.item_quantity("mixed_raw_ore")
	var network: Dictionary = database.extraction_networks["earth_extraction_network"]
	var accelerated_network_duration := simulation.extraction_network_cycle_duration_ms(network)
	var configured_speed := simulation.simulation_speed_multiplier("mining")
	simulation.set_simulation_profile("NORMAL_PROFILE")
	var baseline_network_duration := simulation.extraction_network_cycle_duration_ms(network)
	simulation.set_simulation_profile("TEST_PROFILE")
	_check(is_equal_approx(accelerated_network_duration * 10.0, baseline_network_duration), "automatic extraction networks use the configured tenfold mining speed")
	var network_cycles := 20.0
	simulation.advance(state, accelerated_network_duration * network_cycles + 1.0)
	var sustainable_output := int(floor(simulation.extraction_site_sustainable_potential(state, "earth_resource_cluster_prospect") * simulation.simulation_speed_multiplier("mining") * accelerated_network_duration * network_cycles / 3600000.0))
	_check(sustainable_output > 0 and state.item_quantity("mixed_raw_ore") == before + sustainable_output, "the automatic network obeys the site's sustainable extraction potential")
	_check(state.item_quantity("iron_ore") == 0, "the automatic network never bypasses industrial refinement into specific minerals")
	var background_state := _new_state(database, simulation)
	background_state.background_economy["mining_sources"]["mixed_raw_gas"] = {"source_id":"test_source", "facility_id":"", "per_second":1.0, "enabled":true}
	simulation.advance(background_state, 101.0)
	_check(background_state.item_quantity("mixed_raw_gas") == 0, "retired background capacity cannot create output outside a real extraction asset or Factory runtime")

	var grade_state := _new_state(database, simulation)
	grade_state.mining_site_states["lunar_kreep_rare_earths"].merge({"discovered":true, "unlocked":true, "state":"AVAILABLE", "survey_state":LocationState.DEEP_SURVEYED, "developed":true, "extraction_method_id":"fixed_excavation", "mastery_level":2}, true)
	grade_state.extraction_network_states["lunar_extraction_network"].merge({"unlocked":true, "status":"IDLE"}, true)
	grade_state.location_state("lunar_space")["industry"]["power_capacity"] = 20.0
	grade_state.location_state("lunar_space")["logistics"]["storage_capacities"]["BULK"] = 500
	grade_state.location_state("lunar_space")["logistics"]["local_throughput_capacity"] = 50.0
	grade_state.technologies["industrial_coordination"] = true
	_check(not bool(simulation.mining_site_network_eligibility(grade_state, "lunar_kreep_rare_earths", "lunar_extraction_network").get("eligible", false)), "material grade blocks integration when extraction-industry technology is too low")
	grade_state.technologies["heavy_extraction"] = true
	_check(bool(simulation.mining_site_network_eligibility(grade_state, "lunar_kreep_rare_earths", "lunar_extraction_network").get("eligible", false)), "higher extraction-industry technology satisfies the site's material-grade condition")


func _test_phase_four_freight_services(database: ContentDatabase) -> void:
	var required_classes := ["BULK", "STANDARD", "PRECISION", "CRYOGENIC", "HAZARDOUS", "OVERSIZED"]
	_check(database.freight_rules.get("classes", []) == required_classes and database.items.values().all(func(value): return str((value as Dictionary).get("freight_class", "")) in required_classes and float((value as Dictionary).get("freight_units", 0.0)) > 0.0), "every transportable Item resolves to one of the six positive Freight profiles")
	_check(database.transport_modes.size() >= 5 and ["general_cargo", "bulk_tug", "mass_driver", "cryogenic_carrier", "express_courier"].all(func(mode_id): return database.transport_modes.has(mode_id)), "both phase-four rounds define five meaningfully different Transport Modes")
	_check(float(database.items["mixed_raw_ore"].get("freight_units", 0.0)) > float(database.items["iron_ore"].get("freight_units", 0.0)) and float(database.items["iron_ore"].get("freight_units", 0.0)) > float(database.items["iron_ingot"].get("freight_units", 0.0)), "remote preprocessing progressively reduces Freight pressure")

	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.regions["lunar_space"] = true
	state.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	simulation.ensure_frontier_state(state)
	var iron_path: Dictionary = simulation.logistics._shortest_path(state, "earth_orbit", "lunar_space", "iron_ore")
	var precision_path: Dictionary = simulation.logistics._shortest_path(state, "earth_orbit", "lunar_space", "electronics")
	_check(float(iron_path.get("route_freight_units_per_item", {}).get("earth_lunar_freight", 0.0)) > float(precision_path.get("route_freight_units_per_item", {}).get("earth_lunar_freight", 0.0)), "bulk ore and precision components occupy different effective route capacity")
	var raw_path: Dictionary = simulation.logistics._shortest_path(state, "earth_orbit", "lunar_space", "mixed_raw_ore")
	var ingot_path: Dictionary = simulation.logistics._shortest_path(state, "earth_orbit", "lunar_space", "iron_ingot")
	var route_budget: Dictionary = {"earth_lunar_freight":100.0}
	var hub_budget: Dictionary = {"earth_orbit":1000.0, "lunar_space":1000.0}
	var energy_budget: Dictionary = {"earth_orbit":1000.0, "lunar_space":1000.0}
	_check(simulation.logistics._path_dispatch_capacity(ingot_path, route_budget, hub_budget, energy_budget) > simulation.logistics._path_dispatch_capacity(raw_path, route_budget, hub_budget, energy_budget), "processing remote raw feedstock before shipment materially relieves route congestion")
	_check(float(raw_path.get("score", 0.0)) > 0.0 and raw_path.has("special_cargo_risk") and raw_path.has("handling_freight_units_per_item"), "path selection records the composite time, congestion, handling, operating, transfer and risk score")

	state.technologies["industrial_coordination"] = true
	var tug := state._create_ship_instance("belt_cruiser", ["bulk_freight_array"], "ISS Bulk Service")
	var tug_id := str(tug.get("instance_id", ""))
	_check(simulation.logistics.configure_service(state, "earth_lunar_freight", "bulk_tug", [tug_id], "BULK_FIRST"), "a bulk service accepts a qualifying physical ship asset")
	var tug_service: Dictionary = simulation.logistics.service_for_route(state, "earth_lunar_freight")
	_check(tug_service.get("assigned_ship_ids", []).has(tug_id) and str(state.ship_by_id(tug_id).get("assignment", {}).get("domain", "")) == "logistics" and str(state.ship_by_id(tug_id).get("status", "")) == "LOGISTICS_SERVICE", "Transport Ship assignment references and reserves the actual Ship instance")
	_check(float(simulation.logistics.service_snapshot(state, "earth_lunar_freight").get("capacity_per_minute", 0.0)) > float(simulation.logistics.service_snapshot(state, "earth_lunar_freight").get("capacity_per_dispatch", 0.0)), "a route Logistics Service exposes per-minute capacity, classes, utilization and allocation state")
	_check(simulation.logistics._demand_priority_score(state, {"priority":50, "item_id":"mixed_raw_ore"}) > simulation.logistics._demand_priority_score(state, {"priority":50, "item_id":"electronics"}), "route Priority Strategy changes automatic batch scheduling order")
	_check(simulation.logistics.service_capacity(state, "earth_lunar_freight") > 0.0 and not simulation.logistics._shortest_path(state, "earth_orbit", "lunar_space", "mixed_raw_ore").is_empty() and simulation.logistics._shortest_path(state, "earth_orbit", "lunar_space", "electronics").is_empty(), "Bulk Tug capacity and Freight Class compatibility affect actual path selection")

	state.technologies["mass_driver_logistics"] = true
	_check(simulation.logistics.configure_service(state, "earth_lunar_freight", "mass_driver", []), "Mass Driver provides an infrastructure Logistics Service without ships")
	_check(state.ship_is_unassigned_docked(tug_id) and simulation.logistics.service_for_route(state, "earth_lunar_freight").get("assigned_ship_ids", []).is_empty(), "switching to infrastructure releases the previously assigned physical ship")
	_check(simulation.logistics.service_capacity(state, "earth_lunar_freight") > float(simulation.logistics.effective_route_capacity(state, "earth_lunar_freight")), "Mass Driver changes available Freight capacity instead of only changing display metadata")
	var service_transaction := GameStateTransaction.new(state, database.domains.keys())
	_check(simulation.logistics.configure_service(service_transaction.working_state, "earth_lunar_freight", "bulk_tug", [tug_id], "BULK_FIRST"), "the player-facing transactional command can assign a ship-backed Logistics Service")
	var committed_service_state := service_transaction.commit()
	var subsequent_transaction := GameStateTransaction.new(committed_service_state, database.domains.keys())
	_check(str(subsequent_transaction.working_state.ship_by_id(tug_id).get("status", "")) == "LOGISTICS_SERVICE" and subsequent_transaction.working_state.logistics_network.get("services", {}).get("earth_lunar_freight", {}).get("assigned_ship_ids", []).has(tug_id), "subsequent player commands preserve Logistics Ship ownership instead of silently releasing it")

	var specialized_state := _new_state(database, simulation)
	specialized_state.regions["lunar_space"] = true
	specialized_state.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	specialized_state.technologies.merge({"advanced_propulsion":true, "advanced_orbital_interface":true}, true)
	simulation.ensure_frontier_state(specialized_state)
	var general_precision_path: Dictionary = simulation.logistics._shortest_path(specialized_state, "earth_orbit", "lunar_space", "electronics")
	var general_precision_costs: Dictionary = simulation.logistics._path_costs(specialized_state, general_precision_path)
	var express_ship := specialized_state._create_ship_instance("lunar_pathfinder", ["advanced_drive"], "ISS Express Courier")
	var express_ship_id := str(express_ship.get("instance_id", ""))
	_check(not simulation.logistics.ship_eligible_for_mode(specialized_state, str(specialized_state.ships[0].get("instance_id", "")), "express_courier") and simulation.logistics.ship_eligible_for_mode(specialized_state, express_ship_id, "express_courier"), "Express Courier requires a real ship with Advanced Drive freight capability")
	_check(simulation.logistics.configure_service(specialized_state, "earth_lunar_freight", "express_courier", [express_ship_id], "PRECISION_FIRST"), "an eligible Advanced-Drive ship can enter Express Courier service")
	var one_courier_capacity: float = simulation.logistics.service_capacity(specialized_state, "earth_lunar_freight")
	var second_express_ship := specialized_state._create_ship_instance("belt_cruiser", ["advanced_drive"], "ISS Express Wing")
	var second_express_ship_id := str(second_express_ship.get("instance_id", ""))
	_check(simulation.logistics.configure_service(specialized_state, "earth_lunar_freight", "express_courier", [express_ship_id, second_express_ship_id], "PRECISION_FIRST") and simulation.logistics.service_capacity(specialized_state, "earth_lunar_freight") > one_courier_capacity, "adding a second eligible physical courier increases the live route-service capacity")
	var express_path: Dictionary = simulation.logistics._shortest_path(specialized_state, "earth_orbit", "lunar_space", "electronics")
	var express_costs: Dictionary = simulation.logistics._path_costs(specialized_state, express_path)
	_check(float(express_path.get("transit_time_ms", INF)) < float(general_precision_path.get("transit_time_ms", INF)) and float(express_path.get("handling_freight_units_per_item", INF)) < float(general_precision_path.get("handling_freight_units_per_item", INF)), "Express Courier materially reduces precision-cargo transit and handling time")
	_check(int(express_costs.get("chemical_propellant", 0)) > int(general_precision_costs.get("chemical_propellant", 0)) and int(express_costs.get("repair_material", 0)) > int(general_precision_costs.get("repair_material", 0)), "Express Courier pays its intended propellant and maintenance premium")
	_check(not simulation.logistics.configure_service(specialized_state, "outer_deep_freight", "express_courier", [express_ship_id]), "Express Courier is rejected outside its declared inner-system routes")
	_check(simulation.logistics.configure_service(specialized_state, "earth_lunar_freight", "general_cargo", []), "switching from Express service releases its physical courier")
	_check(specialized_state.ship_is_unassigned_docked(express_ship_id) and specialized_state.ship_is_unassigned_docked(second_express_ship_id), "switching modes releases every courier in a multi-ship service")
	var general_cryo_path: Dictionary = simulation.logistics._shortest_path(specialized_state, "earth_orbit", "lunar_space", "water_ice")
	var cryogenic_ship := specialized_state._create_ship_instance("lunar_pathfinder", ["cryogenic_hold_system"], "ISS Cold Chain")
	var cryogenic_ship_id := str(cryogenic_ship.get("instance_id", ""))
	_check(not simulation.logistics.configure_service(specialized_state, "earth_lunar_freight", "cryogenic_carrier", [express_ship_id]) and simulation.logistics.ship_eligible_for_mode(specialized_state, cryogenic_ship_id, "cryogenic_carrier"), "Cryogenic Carrier rejects ordinary holds and requires a Cryogenic Hold Loadout")
	_check(simulation.logistics.configure_service(specialized_state, "earth_lunar_freight", "cryogenic_carrier", [cryogenic_ship_id], "MAINTENANCE_FIRST"), "an insulated physical ship can enter Cryogenic Carrier service")
	var cryogenic_path: Dictionary = simulation.logistics._shortest_path(specialized_state, "earth_orbit", "lunar_space", "water_ice")
	_check(float(cryogenic_path.get("route_freight_units_per_item", {}).get("earth_lunar_freight", INF)) < float(general_cryo_path.get("route_freight_units_per_item", {}).get("earth_lunar_freight", INF)) and float(cryogenic_path.get("handling_freight_units_per_item", INF)) < float(general_cryo_path.get("handling_freight_units_per_item", INF)), "Cryogenic Carrier materially reduces cold-chain route and handling pressure")
	_check(str(specialized_state.ship_by_id(cryogenic_ship_id).get("status", "")) == "LOGISTICS_SERVICE" and specialized_state.logistics_network.get("services", {}).get("earth_lunar_freight", {}).get("assigned_ship_ids", []).has(cryogenic_ship_id), "specialized second-round transport still reserves the actual assigned Ship entity")

	var conservation := _new_state(database, simulation)
	conservation.regions["lunar_space"] = true
	conservation.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	simulation.ensure_frontier_state(conservation)
	simulation._install_survey_staging_package(conservation, "lunar_space")
	conservation.location_state("lunar_space")["logistics"]["storage_capacities"] = {"BULK":1000, "COMPONENT":1000, "FLUID":1000, "SPECIAL":1000}
	conservation.location_state("lunar_space")["logistics"]["local_throughput_capacity"] = 100.0
	conservation.location_state("lunar_space")["logistics"]["hub_throughput"] = 100.0
	conservation.add_item("electronics", 30, "earth_orbit")
	var before_total := conservation.aggregate_item_quantity("electronics")
	simulation.logistics.configure_policy(conservation, "earth_orbit", "electronics", {"mode":"SUPPLY", "reserve":0})
	simulation.logistics.configure_policy(conservation, "lunar_space", "electronics", {"mode":"DEMAND", "target":20, "route_lock":"earth_lunar_freight"})
	var events: Array[Dictionary] = simulation.logistics._dispatch(conservation)
	_check(not events.is_empty() and conservation.aggregate_item_quantity("electronics") + simulation.logistics.incoming_quantity(conservation, "lunar_space", "electronics") == before_total, "Freight conservation covers source stock plus real in-transit cargo")
	var in_flight: Dictionary = conservation.logistics_network.get("shipments", [])[0]
	simulation.advance(conservation, float(in_flight.get("total_ms", 0.0)) + 1.0)
	_check(conservation.aggregate_item_quantity("electronics") == before_total and conservation.item_quantity("electronics", "lunar_space") == 20, "Freight conservation survives arrival at the target Location")
	simulation.logistics.configure_policy(conservation, "lunar_space", "electronics", {"mode":"DEMAND", "target":25, "route_lock":"lunar_belt_freight"})
	_check(simulation.logistics._dispatch(conservation).is_empty() and str(conservation.location_state("lunar_space").get("logistics", {}).get("policies", {}).get("electronics", {}).get("blocker", {}).get("code", "")) == "ROUTE_LOCK_UNAVAILABLE", "an impossible player route lock produces a structured actionable Logistics blocker")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(restored.logistics_network.get("services", {}) == state.logistics_network.get("services", {}), "route Logistics Services and their strategy survive save/load")
	var schema_twenty_nine := state.to_dictionary()
	schema_twenty_nine["save_version"] = 29
	schema_twenty_nine["logistics_network"].erase("services")
	var migrated := SpaceGameState.from_dictionary(schema_twenty_nine, database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(migrated)
	_check(migrated.logistics_network.get("services", {}).size() == database.logistics_routes.size(), "schema 29 Logistics state migrates to one compatible default service per route")


func _test_location_logistics(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.regions["lunar_space"] = true
	state.region_states["lunar_space"]["discovered"] = true
	state.region_states["lunar_space"]["exploration_state"] = "SURVEYED"
	simulation.ensure_frontier_state(state)
	simulation._install_survey_staging_package(state, "lunar_space")
	state.location_state("lunar_space")["logistics"]["storage_capacities"] = {"BULK":1000, "COMPONENT":1000, "FLUID":1000, "SPECIAL":1000}
	state.location_state("lunar_space")["logistics"]["local_throughput_capacity"] = 100.0
	state.location_state("lunar_space")["logistics"]["hub_throughput"] = 100.0
	state.add_item("iron_ore", 60, "earth_orbit")
	var before_ore := state.aggregate_item_quantity("iron_ore")
	var before_propellant := state.item_quantity("chemical_propellant", "earth_orbit")
	var before_maintenance := state.item_quantity("repair_material", "earth_orbit")
	_check(simulation.logistics.configure_policy(state, "earth_orbit", "iron_ore", {"mode":"SUPPLY", "reserve":10, "dispatch_threshold":5}), "a Location can expose stock as Supply above a Local Reserve")
	_check(simulation.logistics.configure_policy(state, "lunar_space", "iron_ore", {"mode":"DEMAND", "target":20, "priority":90}), "a Location can request a Target Stock with Priority")
	simulation.advance(state, 5000.0)
	_check(state.logistics_network.get("shipments", []).size() == 1, "Supply and Demand create one persistent Shipment")
	var shipment: Dictionary = state.logistics_network.get("shipments", [])[0]
	_check(str(shipment.get("origin", "")) == "earth_orbit" and str(shipment.get("destination", "")) == "lunar_space" and int(shipment.get("cargo", {}).get("iron_ore", 0)) == 20, "Shipment records Origin, Destination and Cargo")
	_check(state.item_quantity("iron_ore", "earth_orbit") == 40 and state.item_quantity("iron_ore", "lunar_space") == 0, "dispatch deducts cargo from Origin without teleporting it")
	_check(state.item_quantity("chemical_propellant", "earth_orbit") == before_propellant - 1, "dispatch pays the freight route's physical fuel cost")
	_check(state.item_quantity("repair_material", "earth_orbit") == before_maintenance - 1, "dispatch pays physical Logistics Fleet maintenance parts")
	_check(float(shipment.get("handling_time_ms", 0.0)) > 0.0 and float(shipment.get("total_ms", 0.0)) > float(database.logistics_routes["earth_lunar_freight"].get("transit_time_ms", 0.0)), "Shipment ETA includes loading and unloading time")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(restored.logistics_network.get("shipments", []).size() == 1, "in-flight Shipment state survives save/load")
	simulation.advance(state, float(shipment.get("total_ms", 0.0)))
	_check(state.item_quantity("iron_ore", "lunar_space") == 20 and state.logistics_network.get("shipments", []).is_empty(), "Shipment arrives only after its ETA and adds cargo to Destination")
	_check(state.aggregate_item_quantity("iron_ore") == before_ore, "Shipment movement conserves aggregate cargo")
	simulation.advance(state, 10000.0)
	_check(state.logistics_network.get("shipments", []).is_empty(), "Target Stock prevents unnecessary follow-up shipments")
	var baseline_profile: Dictionary = simulation.logistics.technology_profile(state)
	state.technologies["mass_driver_logistics"] = true
	var mass_driver_profile: Dictionary = simulation.logistics.technology_profile(state)
	_check(int(mass_driver_profile.get("logistics_tier", 0)) == 1 and float(mass_driver_profile.get("freight_capacity_multiplier", 1.0)) > float(baseline_profile.get("freight_capacity_multiplier", 1.0)), "Mass Driver technology changes Freight throughput and operating structure")
	_check(simulation.logistics.effective_route_capacity(state, "earth_lunar_freight") > int(database.logistics_routes["earth_lunar_freight"].get("freight_capacity", 0)) and simulation.logistics.effective_route_transit_time_ms(state, "earth_lunar_freight") < float(database.logistics_routes["earth_lunar_freight"].get("transit_time_ms", 0.0)), "logistics technology modifies route capacity and transit time in actual dispatch calculations")
	var energy_state := _new_state(database, simulation)
	energy_state.regions["lunar_space"] = true
	energy_state.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	energy_state.technologies["mass_driver_logistics"] = true
	energy_state.add_item("iron_ore", 20, "earth_orbit")
	simulation.ensure_frontier_state(energy_state)
	simulation._install_survey_staging_package(energy_state, "lunar_space")
	energy_state.location_state("lunar_space")["logistics"]["storage_capacities"]["BULK"] = 1000
	energy_state.location_state("lunar_space")["logistics"]["local_throughput_capacity"] = 100.0
	energy_state.location_state("lunar_space")["logistics"]["hub_throughput"] = 100.0
	simulation.logistics.configure_policy(energy_state, "earth_orbit", "iron_ore", {"mode":"SUPPLY", "reserve":0})
	simulation.logistics.configure_policy(energy_state, "lunar_space", "iron_ore", {"mode":"DEMAND", "target":10})
	energy_state.location_state("earth_orbit")["industry"]["power_capacity"] = 0.0
	simulation.ensure_frontier_state(energy_state)
	energy_state.location_state("earth_orbit")["power"]["available_capacity"] = 0.0
	_check(simulation.logistics._dispatch(energy_state).is_empty(), "energy-based Logistics technology cannot dispatch from an unpowered Hub")
	energy_state.location_state("earth_orbit")["industry"]["power_capacity"] = 100.0
	energy_state.location_state("lunar_space")["industry"]["power_capacity"] = 100.0
	simulation.ensure_frontier_state(energy_state)
	energy_state.location_state("earth_orbit")["power"]["available_capacity"] = 100.0
	energy_state.location_state("lunar_space")["power"]["available_capacity"] = 100.0
	_check(not simulation.logistics._dispatch(energy_state).is_empty(), "available power at both physical Logistics hubs restores energy-based dispatch")


func _test_system_overviews(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.regions["lunar_space"] = true
	state.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	simulation.ensure_frontier_state(state)
	state.add_item("iron_ore", 17, "lunar_space")
	state.ensure_location("alpha_hub", LocationState.ARTIFICIAL, true, "alpha")
	state.add_item("iron_ore", 99, "alpha_hub")
	var sol_production := simulation.system_production_overview(state, "sol")
	var sol_iron_rows: Array = sol_production.get("flows", []).filter(func(row): return str(row.get("item_id", "")) == "iron_ore")
	_check(sol_production.get("location_ids", []).has("earth_orbit") and sol_production.get("location_ids", []).has("lunar_space") and not sol_production.get("location_ids", []).has("alpha_hub"), "System Production Overview includes only discovered Locations in the selected system")
	_check(not sol_iron_rows.is_empty() and int(sol_iron_rows[0].get("stock", 0)) == state.item_quantity("iron_ore", "earth_orbit") + 17, "System Production Overview aggregates stock without leaking another system's inventory")
	var alpha_production := simulation.system_production_overview(state, "alpha")
	_check(int(alpha_production.get("stock_units", 0)) == 99 and simulation.known_system_ids(state) == ["alpha", "sol"], "content-defined system_id supports multiple independent system summaries")
	_check(simulation.logistics.configure_policy(state, "earth_orbit", "iron_ore", {"mode":"SUPPLY", "reserve":0}), "overview fixture creates a Supply endpoint")
	_check(simulation.logistics.configure_policy(state, "lunar_space", "iron_ore", {"mode":"DEMAND", "target":5}), "overview fixture creates a Demand endpoint")
	var sol_logistics := simulation.system_logistics_overview(state, "sol")
	_check(int(sol_logistics.get("internal_routes", 0)) >= 1 and int(sol_logistics.get("external_routes", 0)) == 0, "System Logistics Overview distinguishes internal and cross-system routes")
	_check(int(sol_logistics.get("policy_count", 0)) == 2 and int(sol_logistics.get("policy_counts", {}).get("SUPPLY", 0)) == 1 and int(sol_logistics.get("policy_counts", {}).get("DEMAND", 0)) == 1, "System Logistics Overview aggregates endpoint policies by mode")


func _test_industrial_templates(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	_check(database.industrial_templates.size() == 6, "the six XMind late-game Industrial Templates are content-defined")
	_check(simulation.logistics.configure_policy(state, "earth_orbit", "electronics", {"mode":"STORAGE"}), "template fixture creates an unrelated manual policy")
	_check(simulation.apply_industrial_template(state, "earth_orbit", "bulk_mining_world"), "a discovered Location can apply an Industrial Template")
	var automation: Dictionary = state.location_state("earth_orbit").get("automation", {})
	_check(str(automation.get("industrial_template_id", "")) == "bulk_mining_world" and str(automation.get("status", "")) == "AUTOMATED", "template assignment is explicit Location state")
	_check(str(state.location_state("earth_orbit").get("logistics", {}).get("policies", {}).get("mixed_raw_ore", {}).get("mode", "")) == "SUPPLY", "Bulk Mining World exposes bulk feedstock through Supply")
	_check(state.location_state("earth_orbit").get("logistics", {}).get("policies", {}).has("electronics"), "applying a Template preserves unrelated manual logistics policies")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(str(restored.location_state("earth_orbit").get("automation", {}).get("industrial_template_id", "")) == "bulk_mining_world", "Industrial Template ownership survives save/load")
	_check(simulation.clear_industrial_template(state, "earth_orbit"), "a Location can return from Template automation to manual control")
	_check(not state.location_state("earth_orbit").get("logistics", {}).get("policies", {}).has("mixed_raw_ore") and state.location_state("earth_orbit").get("logistics", {}).get("policies", {}).has("electronics"), "clearing a Template removes only template-managed policies")
	state.facilities["orbital_foundry"] = {"level":1, "status":"ACTIVE", "installed_modules":[]}
	state.add_item("iron_ingot", 20)
	state.add_item("electronics", 20)
	state.add_item("industrial_machine_tools", 10)
	_check(simulation.apply_industrial_template(state, "earth_orbit", "heavy_industry_world"), "a legacy production Template remains loadable as a logistics-policy preset")
	var foundry_before := int(state.location_industry("earth_orbit", "orbital_foundry").get("level", 0))
	var accelerated_expansion_interval := float(database.industry_rules.get("automation_expansion_interval_ms", 60000.0)) / simulation.production_speed_multiplier()
	simulation._progress_location_industrial_automation(state, accelerated_expansion_interval + 1.0)
	_check(int(state.location_industry("earth_orbit", "orbital_foundry").get("level", 0)) == foundry_before and not simulation.facility_expansion_project_queued(state, "earth_orbit", "orbital_foundry") and not bool(state.location_state("earth_orbit").get("automation", {}).get("auto_expand_enabled", true)), "legacy Templates never auto-expand or create production capacity")


func _test_exploration_and_first_clear(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.facilities["earth_extraction_network"] = {"level":1, "status":"ACTIVE"}
	state.expedition_fleet = {"ship_ids":["SHIP-001"]}
	state.fleet_logistics_runtime()["supplies"] = {"kinetic_munitions":300, "chemical_propellant":30, "repair_supplies":20}
	_start_route(state, "lunar_route", ["SHIP-001"])
	simulation.advance(state, 120000.0)
	_check(int(state.completed_activities.get("route:lunar_route", 0)) == 1, "finite Lunar exploration completes once")
	_check(state.mining_site_states["lunar_titanium_impact_layer"].get("discovered", false) and state.mining_site_states["lunar_deep_ice_lens"].get("discovered", false), "exploration creates persistent permanent extraction sites")
	_check(not state.completed_activities.has("boss:lunar_corsair") and not state.combat_area_states["lunar_transfer_interception"].get("unlocked", false), "survey completion does not silently defeat the named Boss")

	_replace_ship_module(state, "SHIP-001", "light_autocannon", "corsair_overcharged_laser")
	state.ships[0]["damage_taken"] = 0.0
	state.ships[0]["status"] = "DOCKED"
	state.ships[0]["condition"] = "OPERATIONAL"
	state.ships[0]["assignment"] = {"domain":"expedition", "fleet":"default"}
	_start_route(state, "lunar_relay_assault", ["SHIP-001"])
	simulation.advance(state, 180000.0)
	_check(int(state.completed_activities.get("route:lunar_relay_assault", 0)) == 1 and int(state.completed_activities.get("boss:lunar_corsair", 0)) == 1, "first-clear assault defeats the narrative Boss exactly once")
	_check(state.region_states["lunar_space"].get("strategic_state", "") == "SECURED", "first-clear combat changes regional strategic state")
	_check(state.combat_area_states["lunar_transfer_interception"].get("unlocked", false) and state.combat_area_states["lunar_shadow_ambush"].get("unlocked", false), "strategic control unlocks persistent repeatable combat areas")
	_check(state.equipment_instances.values().any(func(instance): return str(instance.get("definition_id", "")) == "corsair_overcharged_laser" and str(instance.get("origin", "")) == "MISSION_REWARD"), "first-clear rewards include a finite physical special module")


func _test_combat_cycles_and_logistics(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.fleet_logistics_runtime()["supplies"] = {"kinetic_munitions":20, "chemical_propellant":10, "repair_supplies":5}
	var resolver := CombatResolver.new(database, DomainRng.new())
	var combat_state := resolver.begin(state, ["SHIP-001"], "earth_raider")
	var cohort: Dictionary = combat_state.get("cohorts", [])[0]
	_check(float(cohort.get("attack_next_ms", 0.0)) != float(cohort.get("skill_next_ms", 0.0)), "Cohort attacks and skills use two independent Cycle timers")
	resolver.advance_clock(combat_state, float(cohort.get("attack_next_ms", 0.0)))
	var first_event := resolver.settle_next_event(state, combat_state)
	_check(first_event.get("cycle_kind", "") == "ATTACK" and int(combat_state.get("cohorts", [])[0].get("attacks", 0)) == 1, "one completed Cohort Attack Cycle resolves exactly one aggregated volley")
	_check(int(combat_state.get("actors", [])[0].get("skills_used", 0)) == 0, "normal attacks do not consume the separate Skill Cycle")
	_check(state.fleet_supply_quantity("kinetic_munitions") == 19, "ammunition weapons consume shared Fleet Cargo supplies per normal attack")
	var skill_remaining := float(combat_state.get("cohorts", [])[0].get("skill_next_ms", 0.0))
	resolver.advance_clock(combat_state, skill_remaining)
	var skill_event := resolver.settle_next_event(state, combat_state)
	_check(skill_event.get("cycle_kind", "") == "SKILL" and int(combat_state.get("actors", [])[0].get("skills_used", 0)) == 1, "one completed Skill Cycle resolves independently")
	_check(int(combat_state.get("actors", [])[0].get("attacks", 0)) == 1, "Skill Cycle does not increment the normal-attack counter")

	var ship_ids := ["SHIP-001"]
	_check(simulation.fleet_command_usage(state, ship_ids) == int(database.ships["patchwork_prospector"].get("command_cost", 0)), "Fleet Command Capacity is derived separately from ownership")
	_check(simulation.fleet_cargo_capacity(state, ship_ids) >= int(database.ships["patchwork_prospector"].get("cargo_capacity", 0)), "Fleet Cargo is shared from participating ship capacity")
	_check(simulation.fleet_endurance_ms(state, ship_ids) > 0.0, "pre-deployment Fleet Endurance can be estimated from physical supplies")

	var dry_state := _new_state(database, simulation)
	dry_state.fleet_logistics_runtime()["supplies"] = {"kinetic_munitions":0}
	var dry_combat := resolver.begin(dry_state, ["SHIP-001"], "earth_raider")
	resolver.advance_clock(dry_combat, float(dry_combat.get("cohorts", [])[0].get("attack_next_ms", 0.0)))
	var dry_event := resolver.settle_next_event(dry_state, dry_combat)
	_check(dry_event.get("type", "") == "SUPPLY_DEPLETED" and dry_combat.get("status", "") == "WITHDRAWN", "ammunition depletion causes a predictable logistics withdrawal instead of magical firing")


func _test_combat_depth_zones(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	var front_id := str(state.ships[0].get("instance_id", ""))
	var mid_ship := state._create_ship_instance("patchwork_prospector", ["light_autocannon", "civilian_shield", "basic_drive", "civilian_reactor_core"], "ISS Mid")
	var rear_ship := state._create_ship_instance("patchwork_prospector", ["light_autocannon", "civilian_shield", "basic_drive", "civilian_reactor_core"], "ISS Rear")
	var formation: Dictionary = state.fleet_logistics_runtime("expedition").get("formation", {})
	formation["ship_zones"] = {front_id:"FRONT", str(mid_ship.get("instance_id", "")):"MID", str(rear_ship.get("instance_id", "")):"REAR"}
	state.fleet_logistics_runtime("expedition")["formation"] = formation
	var resolver := CombatResolver.new(database, DomainRng.new())
	var combat_state := resolver.begin(state, [front_id, str(mid_ship.get("instance_id", "")), str(rear_ship.get("instance_id", ""))], "earth_raider")
	_check(combat_state.get("actors", []).map(func(actor): return str(actor.get("zone", ""))) == ["FRONT", "MID", "REAR"], "Front / Mid / Rear assignments enter persistent combat state")
	var first_target := resolver._enemy_target_indices(state, combat_state, {})
	_check(first_target.size() == 1 and str(combat_state.get("actors", [])[first_target[0]].get("zone", "")) == "FRONT", "ordinary enemy fire targets the foremost surviving zone")
	combat_state.get("actors", [])[0]["hull"] = 0.0
	var exposed_target := resolver._enemy_target_indices(state, combat_state, {})
	_check(exposed_target.size() == 1 and str(combat_state.get("actors", [])[exposed_target[0]].get("zone", "")) == "MID", "Front collapse exposes Mid before Rear")
	var bypass_target := resolver._enemy_target_indices(state, combat_state, {"id":"bypass_test", "target_mode":"BYPASS_EXPOSURE"})
	_check(bypass_target.size() == 1 and str(combat_state.get("actors", [])[bypass_target[0]].get("zone", "")) == "REAR", "Missile / Strike Craft bypass targeting can reach the deepest living zone")

	var cohort_state := _new_state(database, simulation)
	var cohort_second := cohort_state._create_ship_instance("patchwork_prospector", cohort_state.ship_module_definition_ids(cohort_state.ships[0]), "ISS Cohort Wing")
	var cohort_ids := [str(cohort_state.ships[0].get("instance_id", "")), str(cohort_second.get("instance_id", ""))]
	cohort_state.fleet_logistics_runtime()["supplies"] = {"kinetic_munitions":20}
	var grouped := resolver.begin(cohort_state, cohort_ids, "earth_raider")
	_check(grouped.get("cohorts", []).size() == 1 and grouped.get("cohorts", [])[0].get("member_ship_ids", []).size() == 2, "ships with the same Hull, Loadout and Zone resolve as one combat Cohort")
	_check(grouped.get("cohorts", [])[0].get("weapon_cycles", []).size() == 2, "Hull weapon and fitted weapon retain independent Weapon Cycles inside the Cohort")
	resolver.advance_clock(grouped, float(grouped.get("cohorts", [])[0].get("attack_next_ms", 0.0)))
	var volley := resolver.settle_next_event(cohort_state, grouped)
	_check(int(volley.get("cohort_size", 0)) == 2 and not str(volley.get("weapon_id", "")).is_empty() and cohort_state.fleet_supply_quantity("kinetic_munitions") == 18, "one ready Weapon Cycle fires a Cohort volley while paying ammunition for every living member")
	grouped["enemy_accuracy"] = 10.0
	var packet_event := resolver._resolve_enemy_action(cohort_state, grouped, {"id":"packet_test", "damage_multiplier":1.0}, "BASIC_ATTACK")
	var packets: Array = packet_event.get("damage_packets", [])
	_check(packets.size() == 1 and packets[0].has("shield_damage") and packets[0].get("recoverable", false), "enemy fire resolves into a traceable per-ship Damage Packet across Shield, Armor and Hull")
	grouped.get("actors", [])[0]["point_defense"] = 0.4
	var missile_event := resolver._resolve_enemy_action(cohort_state, grouped, {"id":"missile_test", "weapon_kind":"MISSILE", "damage_multiplier":1.0}, "SKILL")
	_check(float(missile_event.get("damage_packets", [])[0].get("defense_strength", 0.0)) > 0.0, "Point Defense and EW reduce missile / strike-craft hit and damage resolution")
	var penetration_actor: Dictionary = grouped.get("actors", [])[0]
	penetration_actor["shield"] = maxf(10.0, float(penetration_actor.get("shield", 0.0)))
	var penetration_packet := resolver._apply_actor_damage(penetration_actor, 10.0, 0.5)
	_check(float(penetration_packet.get("hull_damage", 0.0)) > 0.0 and float(penetration_packet.get("shield_damage", 0.0)) > 0.0, "Penetration splits one Damage Packet between Shield and Hull")
	var sticky_first := resolver._enemy_target_indices(cohort_state, grouped, {"id":"sticky_test"})[0]
	var sticky_second := resolver._enemy_target_indices(cohort_state, grouped, {"id":"sticky_test"})[0]
	_check(sticky_first == sticky_second, "weighted Damage Packet targeting keeps a short sticky lock within the exposed zone")
	grouped["doctrine"] = "AGGRESSIVE_PUSH"
	_check(is_equal_approx(resolver._doctrine_damage_multiplier(grouped, grouped.get("cohorts", [])[0]), 1.15), "Aggressive Push doctrine applies a real outgoing-damage tradeoff")
	for grouped_actor in grouped.get("actors", []):
		grouped_actor["hull"] = float(grouped_actor.get("max_hull", 1.0)) * 0.2
	resolver._sync_fleet_summary(grouped)
	_check(resolver._retreat_policy_triggered(grouped), "the default retreat policy withdraws when aggregate Hull reaches 25 percent")
	var disabled_packet := resolver._apply_actor_damage(grouped.get("actors", [])[0], 100000.0)
	_check(disabled_packet.get("disabled", false) and disabled_packet.get("recoverable", false), "zero Hull creates a recoverable Disabled ship rather than deleting the capital asset")
	var service_state := _new_state(database, simulation)
	var service_ship: Dictionary = service_state.ships[0]
	simulation._apply_combat_damage_to_ships(service_state, {"victory":true, "ship_results":[{"ship_id":service_ship.get("instance_id", ""), "damage_taken":12.0, "damage_dealt":40.0, "disabled":false}]}, [service_ship.get("instance_id", "")])
	_check(int(service_ship.get("service_record", {}).get("combat_deployments", 0)) == 1 and int(service_ship.get("service_record", {}).get("victories", 0)) == 1 and float(service_ship.get("service_record", {}).get("combat_experience", 0.0)) > 0.0, "Ship Entity records combat count, result, damage and experience")


func _test_parallel_shipbuilding(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.unlock_ship_plan("construct_lunar_pathfinder")
	state.add_item("reactor_part", 10)
	state.add_item("titanium_alloy", 20)
	state.add_item("electronics", 20)
	state.add_item("iron_ingot", 40)
	state.add_item("copper_ingot", 40)
	state.add_item("data_core", 4)
	state.add_item("quantum_component", 2)
	var pathfinder_plan: Dictionary = database.ship_construction_projects["construct_lunar_pathfinder"]
	for item_id_value in simulation.ship_construction_material_totals(pathfinder_plan).keys():
		var item_id := str(item_id_value)
		state.add_item(item_id, int(simulation.ship_construction_material_totals(pathfinder_plan)[item_id]) * 2)
	_check(state.enqueue_ship_plan("construct_lunar_pathfinder") and state.enqueue_ship_plan("construct_lunar_pathfinder"), "the Starport can construct multiple ships of the same hull without ownership or slot caps")
	_check(state.shipyard_queue.size() == 2 and state.shipyard_queue[0].get("project_id", "") != state.shipyard_queue[1].get("project_id", ""), "simultaneous ship projects are independent persistent capital projects")
	simulation.advance(state, 260.0)
	_check(state.shipyard_queue.all(func(runtime): return int(runtime.get("completed_segments", 0)) >= 1), "all eligible ship projects advance in parallel")
	_check(state.shipyard_queue.all(func(runtime): return float(runtime.get("productivity_progress", 0.0)) == 0.0), "unique ship construction has Cycle speed but no Productivity output")
	simulation.advance(state, 30000.0)
	var pathfinder_count := 0
	for ship in state.ships:
		if str(ship.get("blueprint_id", "")) == "lunar_pathfinder":
			pathfinder_count += 1
	_check(pathfinder_count == 2, "parallel projects create two individually persistent ships")

	var batch := _new_state(database, simulation)
	batch.unlock_ship_plan("construct_lunar_pathfinder")
	_check(batch.enqueue_ship_plan("construct_lunar_pathfinder", 20) and batch.shipyard_queue.size() == 1, "Build ×20 is one persistent Shipyard order rather than twenty UI queue entries")
	_check(int(batch.shipyard_queue[0].get("quantity_total", 0)) == 20 and int(batch.shipyard_queue[0].get("quantity_remaining", 0)) == 20, "a batch order persists total and remaining Quantity")
	var batch_plan: Dictionary = database.ship_construction_projects["construct_lunar_pathfinder"]
	for item_value in simulation.ship_construction_material_totals(batch_plan):
		var item_id := str(item_value)
		batch.add_item(item_id, int(simulation.ship_construction_material_totals(batch_plan).get(item_id, 0)) * 2)
	for fixed_cost_value in batch_plan.get("fixed_costs", []):
		var fixed_cost := fixed_cost_value as Dictionary
		batch.add_item(str(fixed_cost.get("item", "")), int(fixed_cost.get("quantity", 0)) * 2)
	simulation.advance(batch, 60000.0)
	var completed_batch_ships := batch.ships.filter(func(ship): return str(ship.get("blueprint_id", "")) == "lunar_pathfinder").size()
	_check(completed_batch_ships == 2 and int(batch.shipyard_queue[0].get("quantity_completed", 0)) == 2 and int(batch.shipyard_queue[0].get("quantity_remaining", 0)) == 18, "each completed batch unit consumes its own BOM and creates one independent Ship Entity")

	var blocked := _new_state(database, simulation)
	blocked.unlock_ship_plan("construct_belt_cruiser")
	blocked.add_item("quantum_component", 5)
	blocked.add_item("steel_composite", 20)
	blocked.add_item("titanium_alloy", 20)
	blocked.add_item("electronics", 20)
	blocked.enqueue_ship_plan("construct_belt_cruiser")
	var before_inventory := blocked.inventory.duplicate(true)
	simulation.advance(blocked, 10000.0)
	_check(blocked.shipyard_queue[0].get("status", "") == "BLOCKED" and blocked.shipyard_queue[0].get("blocked_reason", "") == "ENGINEERING", "insufficient Starport engineering locks a stronger hull without consuming resources")
	_check(blocked.inventory == before_inventory and int(blocked.shipyard_queue[0].get("completed_segments", 0)) == 0, "an engineering-locked ship project preserves all materials and progress")


func _test_parallel_physical_refits(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	var second := state._create_ship_instance("patchwork_prospector", ["light_autocannon", "civilian_shield", "basic_drive", "mining_laser", "civilian_reactor_core"], "ISS Refit Two")
	var first_id := str(state.ships[0].get("instance_id", ""))
	var second_id := str(second.get("instance_id", ""))
	var desired := ["light_autocannon", "civilian_shield", "basic_drive", "cargo_expansion", "civilian_reactor_core"]
	var complete_bom := simulation.loadout_fabrication_costs(desired)
	for item_id_value in complete_bom.keys():
		state.add_item(str(item_id_value), int(complete_bom[item_id_value]) * 2)
	_start_test_refit(state, first_id, desired, database)
	_check(state.refit_projects.size() == 1, "design-first refit can begin after one confirmation")
	_start_test_refit(state, second_id, desired, database)
	_check(state.refit_projects.size() == 2, "multiple refits can run simultaneously without refit slots")
	_check(state.ship_by_id(first_id).get("modules", []).is_empty() and state.refit_projects[0].get("consumed_bom", {}) == complete_bom, "a running refit dismantles the old configuration and commits the complete desired Loadout BOM")
	simulation.advance(state, 20000.0)
	_check(state.refit_projects.is_empty(), "both refits finish in parallel")
	_check(state.ship_module_definition_ids(state.ship_by_id(first_id)).has("cargo_expansion") and not state.ship_module_definition_ids(state.ship_by_id(first_id)).has("mining_laser"), "confirmed refit atomically applies the proposed design configuration")
	_check(state.item_quantity("mining_laser") == 0 and state.item_quantity("cargo_expansion") == 0, "completed refits create no ordinary module inventory from either installed or dismantled definitions")


func _test_phase_five_loadout_fabrication(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	_check(not simulation.activity_available(_new_state(database, simulation), database.activities["build_cargo_expansion"]), "ordinary-plugin recipes are internal Loadout BOMs, not stock-producing Industry operations")
	var state := _new_state(database, simulation)
	var ship_id := str(state.ships[0].get("instance_id", ""))
	var desired := state.ship_module_definition_ids(state.ship_by_id(ship_id))
	desired[desired.find("mining_laser")] = "cargo_expansion"
	var complete_bom := simulation.loadout_fabrication_costs(desired)
	var changed_slot_bom := database.module_bom_totals(["cargo_expansion"])
	_check(complete_bom != changed_slot_bom and not complete_bom.is_empty(), "a refit charges the complete desired Loadout BOM rather than only the changed slot")
	for item_id_value in complete_bom.keys():
		state.add_item(str(item_id_value), int(complete_bom[item_id_value]))
	_start_test_refit(state, ship_id, desired, database)
	var runtime: Dictionary = state.refit_projects[0]
	_check(runtime.get("consumed_bom", {}) == complete_bom and str(runtime.get("phase_mode", "")) == "COMBINED_FABRICATION_INSTALLATION", "Loadout confirmation commits all materials once and records the merged fabrication-plus-installation phase")
	_check(float(runtime.get("fabrication_time_ms", 0.0)) > 0.0 and float(runtime.get("installation_time_ms", 0.0)) > 0.0 and state.ship_by_id(ship_id).get("modules", []).is_empty(), "the merged project retains both time components while the previous configuration is dismantled")
	simulation.advance(state, 20000.0)
	_check(state.refit_projects.is_empty() and state.ship_module_definition_ids(state.ship_by_id(ship_id)) == desired, "the merged refit installs the selected Loadout after its one project duration")
	_check(state.item_quantity("mining_laser") == 0 and state.item_quantity("cargo_expansion") == 0, "neither removed nor newly fabricated ordinary plugins become Location inventory")

	var shipyard := _new_state(database, simulation)
	var pathfinder_plan: Dictionary = database.ship_construction_projects["construct_lunar_pathfinder"]
	var starting_bom := database.module_bom_totals(pathfinder_plan.get("starting_modules", []))
	var construction_totals := simulation.ship_construction_material_totals(pathfinder_plan)
	for item_id_value in starting_bom.keys():
		var item_id := str(item_id_value)
		_check(int(construction_totals.get(item_id, 0)) == _entry_amount(pathfinder_plan.get("costs", []), item_id) + int(starting_bom[item_id]), "Shipyard total includes initial-Loadout fabrication material %s" % item_id)
	for item_id_value in construction_totals.keys():
		shipyard.add_item(str(item_id_value), int(construction_totals[item_id_value]))
	for fixed_value in pathfinder_plan.get("fixed_costs", []):
		shipyard.add_item(str((fixed_value as Dictionary).get("item", "")), int((fixed_value as Dictionary).get("quantity", 0)))
	shipyard.unlock_ship_plan("construct_lunar_pathfinder")
	shipyard.enqueue_ship_plan("construct_lunar_pathfinder")
	simulation.normalize_shipyard_queue(shipyard)
	_check(str(shipyard.shipyard_queue[0].get("status", "")) == "RUNNING" and not shipyard.shipyard_queue[0].has("module_escrow"), "a funded fitted hull starts directly from raw materials without module stock or project escrow")

	var role_hull_ids := ["bulk_freighter", "cryogenic_carrier", "repair_tender", "mobile_constructor", "deep_survey_vessel"]
	var role_module_ids := ["bulk_freight_array", "cryogenic_hold_system", "mobile_repair_system", "construction_support_system", "deep_survey_system"]
	var development_ids := ["develop_bulk_freighter", "develop_cryogenic_carrier", "develop_repair_tender", "develop_mobile_constructor", "develop_deep_survey_vessel"]
	_check(role_hull_ids.all(func(hull_id): return database.ships.has(hull_id) and database.ships[hull_id].get("capabilities", {}).is_empty()) and role_module_ids.all(func(module_id): return database.modules.has(module_id)), "phase five hull models define slots and engineering limits while every logistics/industrial role is a Loadout plugin")
	_check(development_ids.all(func(project_id): return not str(database.research_projects[project_id].get("grants_ship_plan", "")).is_empty() and not database.research_projects[project_id].has("grants_module") and not database.research_projects[project_id].has("grants_capability")), "Ship Development research unlocks only a hull construction plan, never a built-in role capability")
	_check(role_module_ids.all(func(module_id): return not simulation.activity_available(state, database.module_bom_activity(module_id))), "role-plugin fabrication recipes remain internal to complete Loadout application")
	var constructor := state._create_ship_instance("mobile_constructor", [], "ISS Test Constructor")
	var repair := state._create_ship_instance("repair_tender", [], "ISS Test Tender")
	var survey := state._create_ship_instance("deep_survey_vessel", [], "ISS Test Survey")
	var bulk := state._create_ship_instance("bulk_freighter", [], "ISS Test Bulk")
	var cryogenic := state._create_ship_instance("cryogenic_carrier", [], "ISS Test Cryogenic")
	state.active_expedition["assigned_ship_ids"] = [survey.get("instance_id", "")]
	var empty_role_capacity := simulation.construction_capacity(state)
	_check(is_equal_approx(simulation.repair_support_rate(state), 1.0) and is_equal_approx(simulation.expedition_support_rate(state), 1.0) and not simulation.logistics.ship_eligible_for_mode(state, str(bulk.get("instance_id", "")), "bulk_tug") and not simulation.logistics.ship_eligible_for_mode(state, str(cryogenic.get("instance_id", "")), "cryogenic_carrier"), "an unfitted logistics or industrial hull grants no role merely because of its model ID")
	constructor["modules"] = ["construction_support_system"]
	repair["modules"] = ["mobile_repair_system"]
	survey["modules"] = ["deep_survey_system"]
	bulk["modules"] = ["bulk_freight_array"]
	cryogenic["modules"] = ["cryogenic_hold_system"]
	_check(simulation.construction_capacity(state) > empty_role_capacity and simulation.repair_support_rate(state) > 1.0 and simulation.expedition_support_rate(state) > 1.0, "construction, repair and deep-survey effects activate only after their role plugins are fitted")
	_check(simulation.logistics.ship_eligible_for_mode(state, str(bulk.get("instance_id", "")), "bulk_tug") and simulation.logistics.ship_eligible_for_mode(state, str(cryogenic.get("instance_id", "")), "cryogenic_carrier"), "bulk and cryogenic Logistics Services are enabled by the current Loadout rather than the hull model")


func _test_phase_five_loadout_migration(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var legacy := _new_state(database, simulation)
	legacy.add_item("cargo_expansion", 2)
	var starter := legacy.ships[0] as Dictionary
	starter["modules"].erase("light_autocannon")
	var special_id := legacy.create_equipment_instance("corsair_overcharged_laser", "LEGACY_TEST")
	legacy.install_equipment_instance(special_id, str(starter.get("instance_id", "")))
	var legacy_data := legacy.to_dictionary()
	legacy_data["save_version"] = 30
	legacy_data["asset_semantics_version"] = 3
	legacy_data["standard_module_accounting"] = {"introduced":{"cargo_expansion":2}, "lost":{}}
	var migrated := SpaceGameState.from_dictionary(legacy_data, database.domains.keys(), database.regions)
	var expected_refund := database.module_bom_totals(["cargo_expansion", "cargo_expansion"])
	var before_refund := {}
	for item_id_value in expected_refund.keys():
		before_refund[str(item_id_value)] = migrated.item_quantity(str(item_id_value))
	simulation.ensure_frontier_state(migrated)
	var refund_exact := migrated.item_quantity("cargo_expansion") == 0 and migrated.asset_semantics_version == 4
	for item_id_value in expected_refund.keys():
		var item_id := str(item_id_value)
		refund_exact = refund_exact and migrated.item_quantity(item_id) - int(before_refund[item_id]) == int(expected_refund[item_id])
	_check(refund_exact, "legacy ordinary-module stock converts back to its exact raw BOM instead of surviving as an asset")
	_check(migrated.equipment_instances.has(special_id) and migrated.ships[0].get("modules", []).has(special_id), "migration preserves special-equipment UUID and installed ownership")

	var legacy_shipyard := _new_state(database, simulation)
	legacy_shipyard.unlock_ship_plan("construct_lunar_pathfinder")
	legacy_shipyard.enqueue_ship_plan("construct_lunar_pathfinder")
	legacy_shipyard.shipyard_queue[0]["completed_segments"] = 37
	legacy_shipyard.shipyard_queue[0]["module_escrow"] = {"advanced_drive":1, "sensor_array":1}
	legacy_shipyard.shipyard_queue[0]["module_escrow_initialized"] = true
	legacy_shipyard.asset_semantics_version = 3
	simulation.ensure_frontier_state(legacy_shipyard)
	_check(int(legacy_shipyard.shipyard_queue[0].get("completed_segments", 0)) == 37 and not legacy_shipyard.shipyard_queue[0].has("module_escrow"), "a rejected module-asset Shipyard save keeps hull progress and removes project escrow")
	_check(simulation.loadout_semantics_validation_errors(legacy_shipyard).is_empty(), "migrated projects contain no ordinary plugin inventory authority")

	var duplicate_ship := migrated._create_ship_instance("patchwork_prospector", [], "ISS Duplicate Audit")
	duplicate_ship["modules"].append(special_id)
	_check(not simulation.loadout_semantics_validation_errors(migrated).is_empty(), "save validation detects duplicate special-equipment occupancy")
	simulation.ensure_ship_loadout_semantics(migrated)
	_check(not duplicate_ship.get("modules", []).has(special_id) and simulation.loadout_semantics_validation_errors(migrated).is_empty(), "migration removes duplicate special-equipment occupancy while preserving its original owner")


func _test_phase_six_rd_programs(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	_check(SpaceGameState.TECHNOLOGY_DOMAIN_IDS.size() == 8 and state.technology_domains.size() == 8 and SpaceGameState.TECHNOLOGY_DOMAIN_IDS.all(func(domain_id): return int(state.technology_domains.get(domain_id, {}).get("level", 0)) == 1), "phase six starts with eight persistent Technology Capability Domains rather than a node-heavy Tech Tree")
	_check(simulation.research_capacity(state) == 0.0 and not state.to_dictionary().has("research_points"), "Research Capacity is a non-stockpiling flow and no generic Research Point inventory exists")
	var advanced: Dictionary = database.research_projects["research_advanced_propulsion"]
	var heavy: Dictionary = database.research_projects["research_heavy_industry"]
	var fusion: Dictionary = database.research_projects["research_jovian_operations"]
	_check([advanced, heavy, fusion].all(func(project): return bool(project.get("major_program", false)) and project.get("stages", []).size() >= 3 and project.get("stages", []).size() <= 5), "the first three major R&D Programs each expose three to five meaningful engineering stages")
	_check(heavy.get("effect_tags", []).has("UNLOCK") and heavy.get("effect_tags", []).has("METHOD") and heavy.get("effect_tags", []).has("SYSTEM"), "UNLOCK, METHOD and SYSTEM are combinable outcome labels rather than mutually exclusive technology types")
	_check(str(database.activities["fabricate_propulsion_test_article"].get("requirements", [])[0].get("type", "")) == "spillover" and str(database.activities["fabricate_fusion_service_component"].get("requirements", [])[0].get("id", "")) == "experimental_fusion_engineering", "experimental Articles and fusion components become manufacturable during a program instead of appearing only after final completion")

	state.facilities["research_complex"] = {"level":1, "status":"ACTIVE", "installed_modules":[]}
	state.technologies["industrial_coordination"] = true
	state.add_item("electronics", 20)
	state.add_item("titanium_alloy", 20)
	state.add_item("data_core", 10)
	simulation.initialize_research_program(state, advanced, "HIGH_THRUST")
	simulation.advance(state, 20000.0)
	_check(bool(state.technology_spillovers.get("experimental_propulsion_engineering", false)) and str(state.research.get("stage_id", "")) == "prototype" and str(state.research.get("status", "")) == "BLOCKED", "the propulsion experiment grants a relevant Spillover and then blocks on a real manufactured prototype Article")
	state.completed_activities["fabricate_propulsion_test_article"] = 1
	state.add_item("propulsion_test_article", 2)
	simulation.advance(state, 10000.0)
	var field_progress_before := float(state.research.get("stage_progress_ms", 0.0))
	_check(str(state.research.get("stage_id", "")) == "field_test" and str(state.research.get("status", "")) == "BLOCKED", "the major program reaches a dedicated Field Test gate")
	simulation.advance(state, 100000.0)
	_check(float(state.research.get("stage_progress_ms", 0.0)) == field_progress_before and not bool(state.completed_projects.get("research_advanced_propulsion", false)), "a Field Test cannot be replaced by waiting through a countdown")
	var field_blocker := simulation.blocker_diagnostic(state, "research", state.research)
	_check(str(field_blocker.get("primary_reason", "")) == "FIELD_TEST_REQUIRED" and str(field_blocker.get("requirement", {}).get("id", "")) == "propulsion_proving_route", "structured blockers tell the Guide exactly which real proving route must be completed")
	state.completed_activities["route:propulsion_proving_route"] = 1
	simulation.advance(state, 20000.0)
	_check(bool(state.completed_projects.get("research_advanced_propulsion", false)) and bool(state.completed_research_routes.get("research_advanced_propulsion", {}).get("HIGH_THRUST", false)) and bool(state.technology_spillovers.get("high_temperature_thrust_chambers", false)), "field evidence, selected engineering route and route-specific Spillover survive final industrialization")
	_check(simulation.research_project_available(state, advanced, "HIGH_EFFICIENCY") and not simulation.research_project_available(state, advanced, "HIGH_THRUST"), "a completed program permits later supplemental investment in the other engineering route without making routes permanently exclusive")
	_check(int(state.technology_domains.get("propulsion", {}).get("level", 1)) >= 2 and simulation.research_knowledge_work_multiplier(state, advanced) < 1.0, "completed programs accumulate reusable domain capability that changes later project work instead of adding a generic research percentage currency")
	var spillover_reuse_state := _new_state(database, simulation)
	var heavy_baseline := simulation.research_knowledge_work_multiplier(spillover_reuse_state, heavy)
	spillover_reuse_state.technology_spillovers["high_temperature_thrust_chambers"] = true
	var heavy_reused := simulation.research_knowledge_work_multiplier(spillover_reuse_state, heavy)
	spillover_reuse_state.technology_spillovers["precision_coil_manufacturing"] = true
	var fusion_reused := simulation.research_knowledge_work_multiplier(spillover_reuse_state, fusion)
	spillover_reuse_state.technology_spillovers["fusion_thermal_management"] = true
	var capital_reused := simulation.research_knowledge_work_multiplier(spillover_reuse_state, database.research_projects["research_capital_combat"])
	_check(heavy_reused < heavy_baseline and fusion_reused < 1.0 and capital_reused < 1.0, "Spillovers reduce specific related engineering programs instead of existing as unrelated badges or a universal research bonus")

	var transformation_state := _new_state(database, simulation)
	transformation_state.unlocked_industrial_transformations["precision_industry_network"] = true
	for item_id in ["industrial_machine_tools", "precision_actuator", "power_bus_component"]:
		transformation_state.add_item(item_id, 20)
	_check(simulation.queue_industrial_transformation(transformation_state, "precision_industry_network"), "mastered SYSTEM knowledge creates a separate Capital-Good Industrial Transformation Project")
	_check(str(transformation_state.construction_operations[0].get("project_type", "")) == "INDUSTRIAL_TRANSFORMATION" and simulation.location_specialization_transition_multiplier(transformation_state, "earth_orbit") < 1.0, "adopting a SYSTEM consumes Construction capacity and creates explicit temporary downtime")
	simulation.advance(transformation_state, 300000.0)
	_check(bool(transformation_state.adopted_industrial_transformations.get("precision_industry_network", false)), "the industrial organization changes only after its real transformation project completes")

	var legacy := _new_state(database, simulation).to_dictionary()
	legacy["save_version"] = 31
	legacy["research"] = {"status":"PAUSED", "project_id":"research_advanced_propulsion", "progress_ms":12000.0, "consumed":{"titanium_alloy":1}, "reserved_costs":{}, "blocked_reason":"", "blocker":{}, "location_id":"earth_orbit"}
	var migrated := SpaceGameState.from_dictionary(legacy, database.domains.keys(), database.regions)
	_check(int(migrated.research.get("research_model_version", 0)) == 2 and migrated.research.has("legacy_project_progress_ms") and migrated.technology_domains.size() == 8, "schema-31 linear research migrates with paid progress intact into the phase-six stage model")


func _test_ship_lifecycle(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	var ship_id := str(state.ships[0].get("instance_id", ""))
	var snapshot: Dictionary = simulation.fleet_maintenance_snapshot(state)[0]
	_check(is_equal_approx(float(snapshot.get("demand_per_hour", 0.0)), 0.24), "Active maintenance demand scales from hull Command Cost")
	state.ship_by_id(ship_id)["maintenance_state"] = "READY_RESERVE"
	state.add_item("repair_material", 20)
	var ready_before := state.item_quantity("repair_material")
	simulation.advance(state, 24.0 * 60.0 * 60.0 * 1000.0)
	_check(ready_before - state.item_quantity("repair_material") == 1, "Ready Reserve pays the approved 30 percent non-zero maintenance rate")
	var lifecycle_ship := state.ship_by_id(ship_id)
	lifecycle_ship["maintenance_state"] = "MOTHBALLED"
	_check(not state.ship_is_docked(ship_id), "Mothballed ships are excluded from operational docked-ship selection")
	var reactivation_costs := simulation.ship_reactivation_costs(lifecycle_ship)
	var reactivation_before := state.item_quantity("repair_material")
	for item_id in reactivation_costs:
		state.remove_item(str(item_id), int(reactivation_costs[item_id]))
	var duration := simulation.ship_reactivation_duration_ms(state, lifecycle_ship)
	state.ship_service_projects.append({"project_id":"SERVICE-TEST", "project_kind":"REACTIVATION", "ship_id":ship_id, "status":"RUNNING", "progress_ms":0.0, "duration_ms":duration, "consumed_materials":reactivation_costs, "location_id":"earth_orbit"})
	lifecycle_ship["status"] = "REACTIVATING"
	_check(state.item_quantity("repair_material") < reactivation_before and simulation.ship_service_capacity(state) >= 1, "Mothball reactivation requires real materials and Starport service capacity")
	simulation.advance(state, duration + 1.0)
	_check(state.ship_service_projects.is_empty() and str(state.ship_by_id(ship_id).get("maintenance_state", "")) == "ACTIVE", "completed reactivation returns a Mothballed ship to Active docked service")
	var retirement := state._create_ship_instance("patchwork_prospector", ["light_autocannon", "civilian_shield", "basic_drive", "civilian_reactor_core"], "ISS Archive Test")
	var retirement_id := str(retirement.get("instance_id", ""))
	retirement["modules"].erase("light_autocannon")
	var special_id := state.create_equipment_instance("corsair_overcharged_laser", "TEST")
	state.install_equipment_instance(special_id, retirement_id)
	var recovered := simulation.ship_scrap_recovery(retirement)
	state.store_equipment_instance(special_id)
	state.naval_archive.append({"ship_id":retirement_id, "name":retirement.get("name", ""), "blueprint_id":retirement.get("blueprint_id", ""), "commissioned_at_ms":retirement.get("commissioned_at_ms", 0), "scrapped_at_ms":state.total_elapsed_ms, "service_record":retirement.get("service_record", {}).duplicate(true), "recovered_materials":recovered})
	state.ships.erase(retirement)
	_check(not recovered.is_empty() and state.ship_by_id(retirement_id).is_empty() and state.naval_archive.any(func(entry): return str(entry.get("ship_id", "")) == retirement_id), "Scrap recovery removes the live ship while preserving identity and service history in Naval Archive")
	_check(state.stored_equipment_ids("corsair_overcharged_laser").has(special_id), "Scrap returns physical special equipment to storage")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(restored.naval_archive.size() == state.naval_archive.size() and restored.fleet_maintenance.has("fractional"), "maintenance state, service history and Naval Archive survive save/load")


func _test_industry_and_capital_cycles(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.add_item("iron_ore", 100)
	var runtime: Dictionary = state.industrial_operations[0]
	runtime.merge({"activity_id":"refine_iron", "status":"RUNNING", "progress_ms":0.0, "productivity_progress":0.0}, true)
	var duration := simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], runtime)
	var configured_speed := simulation.simulation_speed_multiplier("manufacturing")
	simulation.set_simulation_profile("NORMAL_PROFILE")
	var baseline_duration := simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], runtime)
	simulation.set_simulation_profile("TEST_PROFILE")
	_check(is_equal_approx(configured_speed, 10.0) and is_equal_approx(duration * 10.0, baseline_duration), "all foreground Industry production uses the configured tenfold speed multiplier")
	state.location_state("earth_orbit")["logistics"]["local_throughput_capacity"] = 0.01
	var constrained_duration := simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], runtime)
	var local_profile := simulation.local_logistics_profile(state, "earth_orbit")
	_check(str(local_profile.get("status", "")) == "CONSTRAINED" and float(local_profile.get("utilization", 1.0)) < 1.0 and constrained_duration > duration, "Local Logistics throughput is a real industrial utilization bottleneck")
	state.location_state("earth_orbit")["logistics"]["local_throughput_capacity"] = 100.0
	var before := state.item_quantity("iron_ingot")
	simulation.advance(state, duration + 1.0)
	_check(state.item_quantity("iron_ingot") > before and int(state.domains["industry"].get("cycles", 0)) == 1, "industrial manufacturing follows the shared one-work-unit-per-Cycle foundation")
	_check(int(state.domains["industry"].get("level", 0)) == 1 and int(state.domains["industry"].get("xp", -1)) == 0, "repeated production does not create Melvor-style RPG skill levels")

	var capital_state := _new_state(database, simulation)
	capital_state.facilities["orbital_construction_yard"]["installed_modules"] = ["autonomous_builder_control"]
	capital_state.add_item("iron_ingot", 500)
	capital_state.add_item("electronics", 500)
	var build_runtime: Dictionary = capital_state.construction_operations[0]
	build_runtime.merge({"activity_id":"build_orbital_foundry", "status":"RUNNING", "cycle_progress":0.0, "project_cycles_completed":0, "paid_cycles":0, "productivity_progress":0.75, "reserved_costs":{}}, true)
	var accelerated_build_duration := simulation.effective_duration_ms(capital_state, "construction", database.activities["build_orbital_foundry"], build_runtime)
	var ship_plan: Dictionary = database.ship_construction_projects["construct_lunar_pathfinder"]
	var accelerated_shipyard_duration := simulation.shipyard_cycle_duration_ms(capital_state, ship_plan)
	var accelerated_refit_duration := simulation.refit_cycle_duration_ms(capital_state, {"cycle_time_ms":100.0})
	simulation.set_simulation_profile("NORMAL_PROFILE")
	var baseline_build_duration := simulation.effective_duration_ms(capital_state, "construction", database.activities["build_orbital_foundry"], build_runtime)
	var baseline_shipyard_duration := simulation.shipyard_cycle_duration_ms(capital_state, ship_plan)
	var baseline_refit_duration := simulation.refit_cycle_duration_ms(capital_state, {"cycle_time_ms":100.0})
	simulation.set_simulation_profile("TEST_PROFILE")
	_check(is_equal_approx(accelerated_build_duration * 10.0, baseline_build_duration), "facility and Megastructure construction use the same tenfold production speed multiplier")
	_check(is_equal_approx(accelerated_shipyard_duration * 10.0, baseline_shipyard_duration) and is_equal_approx(accelerated_refit_duration * 10.0, baseline_refit_duration), "Shipyard construction and physical refits use the same tenfold production speed multiplier")
	simulation.advance(capital_state, 100000.0)
	_check(float(build_runtime.get("productivity_progress", -1.0)) == 0.0, "infrastructure construction discards legacy Productivity and only accelerates its 100 Cycles")


func _test_location_industry_rules(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.ensure_location("natural_test", LocationState.NATURAL, true, "sol")
	state.add_item("iron_ingot", 10000, "natural_test")
	state.add_item("electronics", 10000, "natural_test")
	var first_costs := simulation.industry_expansion_costs(state, "natural_test", "makeshift_workshop", 1)
	_check(simulation.expand_location_industry(state, "natural_test", "makeshift_workshop", 1) and int(state.location_industry("natural_test", "makeshift_workshop").get("level", 0)) == 0, "a Natural Location queues aggregate Industry Level 1 without changing it immediately")
	var natural_expansion: Dictionary = state.construction_operations[0]
	var natural_expansion_activity := simulation.construction_activity_for_runtime(natural_expansion)
	for _segment in 100:
		simulation._complete_construction_cycle(state, natural_expansion, natural_expansion_activity)
	var second_costs := simulation.industry_expansion_costs(state, "natural_test", "makeshift_workshop", 1)
	_check(int(second_costs.get("iron_ingot", 0)) > int(first_costs.get("iron_ingot", 0)), "Industry expansion costs grow by the approved fifteen-percent curve")
	var natural_industry := state.location_industry("natural_test", "makeshift_workshop")
	var level_one_throughput := simulation.facility_manufacturing_throughput(state, "makeshift_workshop", "natural_test")
	natural_industry["level"] = 20
	var level_twenty_throughput := simulation.facility_manufacturing_throughput(state, "makeshift_workshop", "natural_test")
	_check(level_twenty_throughput > level_one_throughput * 20.0 and is_equal_approx(level_twenty_throughput / (level_one_throughput * 20.0), 1.3), "Industry Level scales linearly and Economy of Scale is capped at thirty percent")
	var natural_operation := state.industrial_operation_for("natural_test", "makeshift_workshop")
	natural_operation.merge({"activity_id":"refine_iron", "status":"RUNNING"}, true)
	state.add_item("iron_ore", 100, "natural_test")
	state.location_state("natural_test")["industry"]["power_capacity"] = 100.0
	state.location_state("natural_test")["logistics"]["local_throughput_capacity"] = 100.0
	_check(bool(simulation.location_industry_constraint_profile(state, "natural_test").get("cooling_required", false)) and simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], natural_operation) == INF, "natural industrial sites need real heat rejection instead of a free Cooling exemption")
	state.location_state("natural_test")["industry"]["cooling_capacity"] = 100.0
	_check(simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], natural_operation) != INF, "building Cooling restores production at a Natural Location")

	state.ensure_location("artificial_test", LocationState.ARTIFICIAL, true, "sol")
	state.location_state("artificial_test")["industry"]["structural_capacity"] = 0.0
	state.add_item("iron_ingot", 100, "artificial_test")
	state.add_item("electronics", 100, "artificial_test")
	_check(simulation.expand_location_industry(state, "artificial_test", "makeshift_workshop", 1), "Artificial Location expansion may enter the queue while Structural Capacity is unavailable")
	simulation.advance(state, 0.0)
	_check(str(state.construction_operations[0].get("status", "")) == "BLOCKED" and str(state.construction_operations[0].get("blocker", {}).get("primary_reason", "")) == "CONSTRUCTION_CAPACITY_FULL", "Artificial Location expansion is hard-blocked by Structural Capacity before work progresses")
	state.location_state("artificial_test")["industry"]["structural_capacity"] = 10.0
	simulation.advance(state, 0.0)
	var artificial_expansion: Dictionary = state.construction_operations[0]
	var artificial_expansion_activity := simulation.construction_activity_for_runtime(artificial_expansion)
	for _segment in 100:
		simulation._complete_construction_cycle(state, artificial_expansion, artificial_expansion_activity)
	_check(int(state.location_industry("artificial_test", "makeshift_workshop").get("level", 0)) == 1, "adding station structure permits the queued Industry expansion to complete")
	var station_operation := state.industrial_operation_for("artificial_test", "makeshift_workshop")
	station_operation.merge({"activity_id":"refine_iron", "status":"RUNNING"}, true)
	state.add_item("iron_ore", 100, "artificial_test")
	state.location_state("artificial_test")["industry"]["power_capacity"] = 100.0
	state.location_state("artificial_test")["logistics"]["local_throughput_capacity"] = 100.0
	state.location_state("artificial_test")["industry"]["cooling_capacity"] = 0.0
	_check(float(simulation.location_industry_constraint_profile(state, "artificial_test").get("cooling_coverage", 1.0)) == 0.0 and simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], station_operation) == INF, "Artificial-station Cooling shortage is a real throughput constraint")
	state.location_state("artificial_test")["industry"]["cooling_capacity"] = 100.0
	_check(simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], station_operation) != INF, "sufficient station Cooling restores production")

	var expertise := state.location_industry("artificial_test", "makeshift_workshop")
	expertise["expertise_level"] = 20
	expertise["product_mastery"] = {"refine_iron":{"cycles":400, "level":20}}
	station_operation["material_savings_fractional"] = {"iron_ore":0.99}
	var profile := simulation.industry_mastery_profile(state, "artificial_test", "makeshift_workshop", "refine_iron")
	var efficient_costs := simulation.industry_cycle_costs(state, station_operation, database.activities["refine_iron"], false)
	_check(float(profile.get("speed_multiplier", 1.0)) > 1.0 and is_equal_approx(float(profile.get("energy_multiplier", 1.0)), 0.9) and float(profile.get("waste_multiplier", 1.0)) < 1.0 and int(efficient_costs.get("iron_ore", 0)) == 1, "Product Mastery and Industry Expertise improve speed, material use, energy use and Waste without combat bonuses")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(int(restored.location_industry("artificial_test", "makeshift_workshop").get("expertise_level", 0)) == 20 and restored.industrial_operation_for("artificial_test", "makeshift_workshop").get("material_savings_fractional", {}).has("iron_ore"), "Location Industry Level, Mastery and fractional material efficiency survive save/load")

	var storage_state := _new_state(database, simulation)
	storage_state.add_item("iron_ingot", 1)
	var storage_runtime := storage_state.industrial_operation_for("earth_orbit", "makeshift_workshop")
	storage_runtime.merge({"activity_id":"manufacture_kinetic_munitions", "status":"RUNNING"}, true)
	var fluid_used := float(simulation.location_storage_used(storage_state, "earth_orbit").get("FLUID", 0.0))
	storage_state.location_state("earth_orbit")["logistics"]["storage_capacities"]["FLUID"] = int(fluid_used)
	var storage_duration := simulation.effective_duration_ms(storage_state, "industry", database.activities["manufacture_kinetic_munitions"], storage_runtime)
	simulation.advance(storage_state, storage_duration + 1.0)
	_check(str(storage_runtime.get("status", "")) == "BLOCKED" and storage_state.item_quantity("kinetic_munitions") == 120, "Location Storage capacity blocks an industrial Cycle that cannot fit its output")

	var method_state := _new_state(database, simulation)
	method_state.technologies["industrial_coordination"] = true
	method_state.add_item("iron_ore", 20)
	var method_runtime := method_state.industrial_operation_for("earth_orbit", "makeshift_workshop")
	method_runtime.merge({"activity_id":"refine_iron", "status":"RUNNING", "material_savings_fractional":{}, "waste_fractional":{}}, true)
	var conventional_duration := simulation.effective_duration_ms(method_state, "industry", database.activities["refine_iron"], method_runtime)
	var conventional_power := float(simulation.location_industry_constraint_profile(method_state, "earth_orbit").get("power_demand", 0.0))
	var waste_before := method_state.item_quantity("industrial_waste")
	simulation._complete_runtime_cycle(method_state, "industry", method_runtime, database.activities["refine_iron"])
	_check(method_state.item_quantity("industrial_waste") == waste_before + 1, "the conventional Production Method creates its defined Waste output")
	method_runtime.merge({"activity_id":"refine_iron_electric", "status":"RUNNING", "material_savings_fractional":{}, "waste_fractional":{}}, true)
	var electric_duration := simulation.effective_duration_ms(method_state, "industry", database.activities["refine_iron_electric"], method_runtime)
	var electric_power := float(simulation.location_industry_constraint_profile(method_state, "earth_orbit").get("power_demand", 0.0))
	var iron_before_electric := method_state.item_quantity("iron_ore")
	waste_before = method_state.item_quantity("industrial_waste")
	simulation._complete_runtime_cycle(method_state, "industry", method_runtime, database.activities["refine_iron_electric"])
	_check(electric_duration < conventional_duration and electric_power > conventional_power and method_state.item_quantity("iron_ore") == iron_before_electric - 1 and method_state.item_quantity("industrial_waste") == waste_before, "switching the same Industry Level to an advanced Production Method changes Input, Energy, Waste and Throughput")


func _test_megastructure_stages(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.facilities["orbital_construction_yard"]["level"] = 3
	state.facilities["orbital_construction_yard"]["installed_modules"] = ["autonomous_builder_control"]
	state.technologies["megastructure_engineering"] = true
	state.completed_projects["research_megastructures"] = true
	var site_id := "earth_sun_lagrange"
	state.location_state(site_id)["survey_state"] = LocationState.DEEP_SURVEYED
	simulation._install_survey_staging_package(state, site_id)
	var definition: Dictionary = database.megastructures["stellar_energy"]
	var phases: Array = definition.get("phases", [])
	state.megastructure_projects["stellar_energy"] = {
		"id":"stellar_energy", "site_location_id":site_id, "location_id":site_id,
		"phase_index":1, "stage_index":1, "status":"READY", "phase_history":[{"phase_index":0, "phase_id":"stellar_site_selection", "materials_consumed":{}}],
		"total_materials_consumed":{}, "total_capital_goods":{}, "total_cargo_transported":0.0,
		"peak_construction_throughput":0.0, "peak_power_demand":0.0, "supplier_locations":{}, "started_at_ms":0
	}
	# Unit-level phase validation pre-provisions the maximum site envelope. The
	# Golden Path separately proves those capacities are built and supplied.
	state.location_state(site_id)["industry"].merge({"power_capacity":5000.0, "cooling_capacity":5000.0, "structural_capacity":1000.0}, true)
	state.location_state(site_id)["construction"]["capacity"] = 100.0
	state.location_state(site_id)["logistics"].merge({"local_throughput_capacity":1000.0, "hub_throughput":1000.0}, true)
	state.location_state(site_id)["logistics"]["storage_capacities"] = {"BULK":20000, "COMPONENT":20000, "FLUID":5000, "SPECIAL":10000}
	for phase_index in range(1, phases.size()):
		var phase := phases[phase_index] as Dictionary
		var activity: Dictionary = database.activities[str(phase.get("activity_id", ""))]
		var runtime: Dictionary = state.construction_operations[0]
		runtime.clear()
		runtime.merge(SpaceGameState._empty_construction_project(0), true)
		runtime["activity_id"] = activity.get("id", "")
		runtime["status"] = "RUNNING"
		simulation.initialize_construction_project(state, runtime, activity, site_id, 90)
		simulation.begin_megastructure_project(state, runtime, activity)
		for cost_value in activity.get("costs", []):
			var cost := cost_value as Dictionary
			state.add_item(str(cost.get("item", "")), int(cost.get("quantity", 0)), site_id)
		for _segment in 100:
			simulation._complete_construction_cycle(state, runtime, activity)
		_check(int(state.megastructure_projects["stellar_energy"].get("phase_index", 0)) == phase_index + 1, "Megastructure phase %d completes through the normal Construction cycle" % phase_index)
	var project: Dictionary = state.megastructure_projects["stellar_energy"]
	_check(bool(state.megastructures.get("stellar_energy", false)) and state.game_complete and str(project.get("status", "")) == "COMPLETE", "the only Megastructure completes the one-star-system game")
	_check(project.get("phase_history", []).size() == 8 and not project.get("total_materials_consumed", {}).is_empty() and not project.get("total_capital_goods", {}).is_empty() and float(project.get("peak_construction_throughput", 0.0)) > 0.0 and float(project.get("peak_power_demand", 0.0)) >= 3400.0, "all eight physical phases retain materials, Capital Goods and peak construction/power statistics")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(bool(restored.megastructures.get("stellar_energy", false)) and restored.megastructure_projects.get("stellar_energy", {}).get("phase_history", []).size() == 8, "completed Megastructure phases and statistics survive save/load")


func _test_phase_eight_industrial_geography(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	_check(database.regions.values().all(func(region): return str((region as Dictionary).get("system_id", "")) == "sol" and not (region as Dictionary).get("environment", {}).is_empty()), "every developable Location belongs to the one Sol system and carries unified environment data")
	_check(database.mining_locations.values().all(func(location): return (location as Dictionary).has("resource_profile") and not (location as Dictionary).has("remaining_ore") and not (location as Dictionary).has("depletion")), "resource profiles expose sustainable potential without normal deposit depletion")

	var unknown := simulation.location_intelligence(state, "asteroid_belt")
	_check(str(unknown.get("survey_state", "")) == LocationState.UNKNOWN and not unknown.has("resources") and not unknown.has("environment"), "UNKNOWN intelligence reveals only the celestial Location identity")
	var survey_ship := state._create_ship_instance("deep_survey_vessel", ["deep_survey_system"], "ISS Geography Test")
	var survey_ship_id := str(survey_ship.get("instance_id", ""))
	state.add_item("chemical_propellant", 20)
	state.add_item("repair_material", 20)
	state.add_item("electronics", 20)
	_check(simulation.start_survey_mission(state, "asteroid_belt", LocationState.DETECTED, [survey_ship_id]), "Survey uses a real fitted vessel and normal fuel inventory instead of Survey Points")
	var saved_running := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(str(saved_running.survey_mission.get("status", "")) == "RUNNING" and saved_running.survey_mission.get("assigned_ship_ids", []).has(survey_ship_id), "a running Survey Mission and its assigned physical vessel survive save/load")
	simulation.advance(state, float(state.survey_mission.get("duration_ms", 1.0)) + 1.0)
	var detected := simulation.location_intelligence(state, "asteroid_belt")
	_check(str(detected.get("survey_state", "")) == LocationState.DETECTED and detected.get("resources", []).all(func(profile): return (profile as Dictionary).has("potential_band") and not (profile as Dictionary).has("extraction_potential") and not (profile as Dictionary).has("byproducts")), "DETECTED supports go/no-go decisions without leaking exact potential, grade or byproducts")
	_check(simulation.start_survey_mission(state, "asteroid_belt", LocationState.SURVEYED, [survey_ship_id]), "the next Survey level is an explicit mission rather than an automatic reveal")
	simulation.advance(state, float(state.survey_mission.get("duration_ms", 1.0)) + 1.0)
	var surveyed := simulation.location_intelligence(state, "asteroid_belt")
	_check(str(surveyed.get("survey_state", "")) == LocationState.SURVEYED and surveyed.get("resources", []).all(func(profile): return (profile as Dictionary).has("grade_range") and (profile as Dictionary).has("extraction_potential") and (profile as Dictionary).has("allowed_methods")), "SURVEYED intelligence exposes investment-grade resource, method and infrastructure data")

	var site_id := "belt_cobalt_frontier"
	var base_potential := simulation.extraction_site_sustainable_potential(state, site_id, "fixed_excavation")
	state.add_item("industrial_machine_tools", 10, "asteroid_belt")
	state.add_item("heavy_structural_section", 10, "asteroid_belt")
	state.add_item("electronics", 10, "asteroid_belt")
	_check(simulation.queue_site_development(state, site_id, "fixed_excavation", 60), "a Surveyed site enters the normal Construction queue for permanent development")
	_check(str(state.construction_operations[0].get("project_type", "")) == "SITE_DEVELOPMENT" and str(state.construction_operations[0].get("location_id", "")) == "asteroid_belt", "Site Development consumes local inventory and remote construction capacity through the shared project model")
	simulation.advance(state, 120000.0)
	_check(bool(state.mining_site_states[site_id].get("developed", false)) and str(state.mining_site_states[site_id].get("extraction_method_id", "")) == "fixed_excavation", "completed Site Development creates a permanent extraction site with the selected method: %s" % str(state.construction_operations[0]))
	_check(bool(simulation.extraction_site_infrastructure_status(state, site_id).get("operational", false)), "permanent extraction reads real local power, Bulk Storage and logistics support")
	_check(base_potential > float(database.mining_locations["belt_cobalt_seam"].get("extraction_potential", 0.0)), "the selected Extraction Method changes sustainable scale rather than a finite reserve")

	var vacuum_method: Dictionary = database.activities["refine_steel_electric"]
	_check(bool(simulation.production_method_environment_eligibility(state, "earth_orbit", vacuum_method).get("eligible", false)) and not bool(simulation.production_method_environment_eligibility(state, "gas_giant_region", vacuum_method).get("eligible", true)), "Production Methods read extensible Location environment conditions instead of region percentage buffs")
	_check(simulation._maintenance_environment_multiplier("gas_giant_region", "electronics") > simulation._maintenance_environment_multiplier("earth_orbit", "electronics"), "radiation environment increases actual Electronics O&M demand through the shared maintenance system")
	_check(simulation.logistics_lead_time_ms(state, "earth_orbit", "outer_system") > simulation.logistics_lead_time_ms(state, "earth_orbit", "lunar_space"), "outer-system bases create a longer real Logistics lead time within the same star system")
	var plan := simulation.target_throughput_plan(state, {"mixed_raw_ore":500.0}, "earth_orbit")
	var geography: Dictionary = plan.get("industrial_geography", {}).get("products", {}).get("mixed_raw_ore", {})
	_check(bool(plan.get("read_only", false)) and float(geography.get("surveyed_capacity", 0.0)) > 0.0 and float(geography.get("shortfall", 0.0)) > 0.0 and not geography.get("potential_solutions", []).is_empty(), "Planner compares industrial targets with currently Surveyed sustainable extraction capacity and suggests non-mutating solutions")
	state.technologies["heavy_extraction"] = true
	_check(simulation.extraction_site_sustainable_potential(state, site_id, "deep_fracture_extraction") > base_potential, "new extraction technology can increase the value of an already Surveyed old site")
	var schema_thirty_three := state.to_dictionary()
	schema_thirty_three["save_version"] = 33
	schema_thirty_three.erase("survey_mission")
	schema_thirty_three.erase("next_survey_mission_serial")
	var migrated := SpaceGameState.from_dictionary(schema_thirty_three, database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(migrated)
	_check(str(migrated.survey_mission.get("status", "")) == "IDLE" and bool(migrated.mining_site_states[site_id].get("developed", false)) and str(migrated.mining_site_states[site_id].get("extraction_method_id", "")) == "fixed_excavation", "schema 33 migrates to Survey Mission state without invalidating previously usable permanent extraction sites")


func _test_save_contract(database: ContentDatabase) -> void:
	var state := _new_state(database)
	state.mining_operations.append(SpaceGameState.create_operation_record(state.mining_operations.size(), "mining"))
	var data := state.to_dictionary()
	_check(int(data.get("save_version", 0)) == SpaceGameState.SAVE_VERSION and SpaceGameState.SAVE_VERSION == 35, "the single-system core uses the explicit schema-35 migration target")
	_check(data.has("demand_registry") and data.has("operations_maintenance") and data.has("economy_telemetry") and data.has("planning_scenarios") and data.has("automation_rules") and data.has("automation_audit") and data.has("mining_site_states") and data.has("extraction_command") and data.has("survey_mission") and data.has("next_survey_mission_serial") and data.has("equipment_instances") and data.has("asset_semantics_version") and not data.has("standard_module_accounting") and data.has("fleet_logistics") and data.has("fleet_maintenance") and data.has("ship_service_projects") and data.has("naval_archive") and data.has("logistics_network") and data.has("construction_history") and data.has("next_construction_project_serial") and data.has("next_production_line_serial") and data.has("technology_domains") and data.has("completed_research_routes") and data.has("technology_spillovers") and data.has("experimental_maturity") and data.has("unlocked_industrial_transformations") and data.has("adopted_industrial_transformations"), "physical assets, Survey Mission, Demand Registry, O&M, Planner and Automation audit state persist without generic production or research currency")
	_check(data.has("extraction_assets") and not data.has("prospect_states") and not data.has("operation_limits") and not data.has("salvaging_operation") and not data.has("salvage_target_states"), "the save contract contains no retired salvage runtime")
	var restored := SpaceGameState.from_dictionary(data, database.domains.keys(), database.regions)
	_check(restored.equipment_instances.size() == state.equipment_instances.size() and restored.ships.size() == state.ships.size(), "current-schema save round-trip preserves physical assets")
	_check(restored.mining_operations.size() == state.mining_operations.size(), "one runtime per active permanent site persists without an arbitrary six-slot cap")
	var repository := LocalSaveRepository.new()
	_check(repository._checksum({"b":2, "a":1}) == repository._checksum({"a":1, "b":2}), "save checksum is independent of Dictionary insertion order")


func _test_phase_seven_inventory_planning(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	var storage := simulation.location_storage_snapshot(state, "earth_orbit")
	_check(storage.get("classes", {}).keys().size() == 4 and ["BULK", "COMPONENT", "FLUID", "SPECIAL"].all(func(storage_class): return storage.get("classes", {}).has(storage_class)), "Planet Inventory resolves every item into one of four real Storage Classes")
	var initial_fluid_capacity := int(state.location_state("earth_orbit").get("logistics", {}).get("storage_capacities", {}).get("FLUID", 0))
	state.regions["lunar_space"] = true
	state.add_item("iron_ingot", 10)
	var propellant_line := state.industrial_operation_for("earth_orbit", "makeshift_workshop")
	propellant_line.merge({"activity_id":"manufacture_chemical_propellant", "method_id":"manufacture_chemical_propellant", "production_device_id":"FACILITY_DEVICE:makeshift_workshop", "control_mode":"PINNED", "status":"RUNNING"}, true)
	state.add_item("water_ice", 10)
	state.location_state("earth_orbit")["logistics"]["storage_capacities"]["FLUID"] = int(simulation.location_storage_used(state, "earth_orbit").get("FLUID", 0.0))
	simulation.advance(state, simulation.effective_duration_ms(state, "industry", database.activities["manufacture_chemical_propellant"], propellant_line) + 1.0)
	_check(str(propellant_line.get("status", "")) == "BLOCKED" and str(propellant_line.get("blocked_reason", "")) == "STORAGE_FULL", "a full matching Storage Class produces BLOCKED_OUTPUT semantics instead of silently deleting output")
	state.remove_item("chemical_propellant", 10)
	state.location_state("earth_orbit")["logistics"]["storage_capacities"]["FLUID"] = initial_fluid_capacity
	simulation.advance(state, 0.0)
	_check(str(propellant_line.get("status", "")) == "RUNNING", "a storage-blocked Factory automatically resumes after real capacity becomes available")

	state.add_item("industrial_machine_tools", 20)
	state.add_item("heavy_structural_section", 20)
	state.add_item("precision_actuator", 20)
	state.add_item("electronics", 100)
	_check(simulation.queue_facility_expansion(state, "earth_orbit", "makeshift_workshop", 2, 70), "a Construction pulse can be registered for Phase-seven demand tracing")
	state.research.merge({"status":"RUNNING", "project_id":"research_advanced_propulsion", "route_id":"high_thrust", "stage_index":0, "stage_consumed":{}, "location_id":"earth_orbit"}, true)
	state.unlocked_ship_plans["construct_lunar_pathfinder"] = true
	state.enqueue_ship_plan("construct_lunar_pathfinder", 1)
	simulation.refresh_demand_registry(state)
	var source_types := {}
	for demand_value in state.demand_registry.get("sources", {}).values():
		source_types[str((demand_value as Dictionary).get("source_type", ""))] = true
	_check(source_types.has("maintenance") and source_types.has("construction") and source_types.has("research_project") and source_types.has("shipbuilding") and state.demand_registry.get("sources", {}).values().all(func(demand): return (demand as Dictionary).has("product_id") and (demand as Dictionary).has("location_id") and (demand as Dictionary).has("priority")), "Demand Registry unifies O&M, Construction, Research and Shipbuilding with traceable source records")

	var analysis := simulation.current_economy_analysis(state, "earth_orbit")
	var electronics_row := {}
	for row_value in analysis.get("products", []):
		if str((row_value as Dictionary).get("product_id", "")) == "electronics":
			electronics_row = row_value
	_check(not electronics_row.is_empty() and electronics_row.has("production_rate") and electronics_row.has("consumption_rate") and electronics_row.has("net_rate") and electronics_row.has("committed_demand") and electronics_row.has("demand_sources") and electronics_row.has("status"), "Current Economy Analysis explains stock, real rates, commitments, sources and diagnostic state without a player target")

	var graph := simulation.production_dependency_graph()
	var upstream := simulation.upstream_production_dependencies("electronics")
	_check(graph.get("nodes", {}).has("product:electronics") and graph.get("producers", {}).has("electronics") and upstream.get("nodes", {}).keys().any(func(node_id): return str(node_id).begins_with("method:")) and str(graph.get("cycle_policy", "")) == "EXTERNAL_CREDIT", "the data-driven Production Dependency Graph supports complete upstream queries and defers loops as External Credit")
	var before_plan := state.to_dictionary()
	var plan := simulation.target_throughput_plan(state, {"electronics":30.0}, "earth_orbit")
	_check(bool(plan.get("read_only", false)) and not plan.get("product_requirements", {}).is_empty() and not plan.get("factory_requirements", []).is_empty() and plan.get("factory_requirements", []).all(func(requirement): return (requirement as Dictionary).has("facility_id") and (requirement as Dictionary).has("production_device_requirements") and (requirement as Dictionary).has("recommended") and (requirement as Dictionary).has("shortage")) and plan.get("infrastructure_requirements", {}).has("power") and plan.get("infrastructure_requirements", {}).has("storage"), "the read-only Planner expands a target into products, real Factories, Devices, energy, Storage and Capital Goods")
	_check(state.to_dictionary() == before_plan, "Planner analysis cannot mutate inventory, construction, routes or locked Production Methods")
	var bottleneck := simulation.shortest_bottleneck_chain(state, "electronics", "earth_orbit", 30.0)
	_check(not str(bottleneck.get("primary_bottleneck", "")).is_empty() and bottleneck.get("shortest_chain", []).size() >= 2, "an unmet target exposes a Primary Bottleneck and a shortest traceable chain")
	state.automation_rules = SpaceGameState._normalized_automation_rules([{"rule_id":"AUTOMATION-000001", "condition":{"type":"INVENTORY_STATE"}, "action":{"type":"PAUSE_FACTORY"}, "cooldown_ms":1000.0, "hysteresis":1.0, "authorized":true}])
	var automation_restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(automation_restored.automation_rules.size() == 1 and float(automation_restored.automation_rules[0].get("cooldown_ms", 0.0)) == 1000.0 and float(automation_restored.automation_rules[0].get("hysteresis", 0.0)) == 1.0, "limited Automation authorization, cooldown and hysteresis survive save/load for normal Game transactions")


func _new_state(database: ContentDatabase, simulation: SimulationEngine = null) -> SpaceGameState:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var active_simulation := simulation if simulation != null else SimulationEngine.new(database)
	active_simulation.set_simulation_profile("TEST_PROFILE")
	active_simulation.ensure_frontier_state(state)
	return state


func _equipment_id_for_definition(state: SpaceGameState, ship: Dictionary, definition_id: String) -> String:
	for value in ship.get("modules", []):
		var equipment_id := str(value)
		if state.equipment_definition_id(equipment_id) == definition_id:
			return equipment_id
	return ""


func _replace_ship_module(state: SpaceGameState, ship_id: String, old_definition: String, new_definition: String) -> void:
	var ship := state.ship_by_id(ship_id)
	for value in ship.get("modules", []).duplicate():
		var stored_value := str(value)
		var definition_id := state.equipment_definition_id(stored_value)
		if (definition_id if not definition_id.is_empty() else stored_value) != old_definition:
			continue
		if state.equipment_instances.has(stored_value):
			state.store_equipment_instance(stored_value)
		else:
			ship["modules"].erase(stored_value)
		break
	if new_definition == "corsair_overcharged_laser":
		var new_id := state.create_equipment_instance(new_definition, "TEST")
		state.install_equipment_instance(new_id, ship_id)
	else:
		ship["modules"].append(new_definition)


func _start_route(state: SpaceGameState, route_id: String, ship_ids: Array) -> void:
	state.active_expedition.merge({
		"status":"RUNNING", "route_id":route_id, "activity_id":"", "node_index":0,
		"node_progress_ms":0.0, "safe_node_index":0, "assigned_ship_ids":ship_ids.duplicate(),
		"phase":"TRAVEL", "combat_state":{}
	}, true)
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		ship["status"] = "EXPEDITION"
		ship["assignment"] = {"domain":"expedition", "fleet":"default"}


func _start_frontier_operation(state: SpaceGameState, runtime: Dictionary, activity: Dictionary, ship_ids: Array, extra: Dictionary = {}) -> void:
	runtime.merge({
		"activity_id":str(activity.get("id", "")), "status":"RUNNING", "progress_ms":0.0,
		"cycle_progress":0.0, "productivity_progress":0.0, "assigned_ship_ids":ship_ids.duplicate(),
		"operation_cargo":{}
	}, true)
	runtime.merge(extra, true)
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		ship["status"] = "EXTRACTION_OPERATION"
		ship["assignment"] = {"domain":str(activity.get("domain", "")), "slot":int(runtime.get("slot", 0))}


func _stop_test_operation(state: SpaceGameState, runtime: Dictionary) -> void:
	for ship_id in runtime.get("assigned_ship_ids", []):
		var ship := state.ship_by_id(str(ship_id))
		ship["status"] = "DOCKED"
		ship["assignment"] = {}
	runtime.merge({"activity_id":"", "status":"IDLE", "progress_ms":0.0, "assigned_ship_ids":[]}, true)


func _start_test_refit(state: SpaceGameState, ship_id: String, desired: Array, database: ContentDatabase) -> void:
	var project_id := "REFIT-TEST-%d" % (state.refit_projects.size() + 1)
	var ship := state.ship_by_id(ship_id)
	var original_modules: Array = ship.get("modules", []).duplicate()
	var consumed_bom := database.module_bom_totals(desired)
	for item_id_value in consumed_bom.keys():
		state.remove_item(str(item_id_value), int(consumed_bom[item_id_value]))
	state.refit_projects.append({
		"project_id":project_id, "ship_id":ship_id, "desired_definitions":desired.duplicate(),
		"original_modules":original_modules, "desired_modules":desired.duplicate(),
		"reserved_equipment_ids":[], "outgoing_equipment_ids":[], "consumed_bom":consumed_bom,
		"loadout_semantics_version":1, "phase_mode":"COMBINED_FABRICATION_INSTALLATION",
		"fabrication_time_ms":5000.0, "installation_time_ms":5000.0,
		"completed_segments":0, "cycle_progress":0.0, "cycle_time_ms":100.0,
		"status":"RUNNING", "location_id":SpaceGameState.MAIN_BASE_LOCATION_ID, "started_at_ms":int(state.total_elapsed_ms)
	})
	ship["modules"] = []
	ship["status"] = "REFITTING"
	ship["assignment"] = {"type":"STARPORT_REFIT", "project_id":project_id}


func _finish() -> void:
	if failures.is_empty():
		print("All headless tests passed")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
