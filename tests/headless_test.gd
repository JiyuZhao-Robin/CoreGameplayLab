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
	# Visual-profile coverage belongs to the presentation project, not Gameplay Lab.
	_test_frontier_content(database)
	_test_physical_ship_assets(database)
	_test_permanent_extraction(database)
	_test_mature_extraction_network(database)
	_test_location_logistics(database)
	_test_system_overviews(database)
	_test_industrial_templates(database)
	_test_exploration_and_first_clear(database)
	_test_combat_cycles_and_logistics(database)
	_test_combat_depth_zones(database)
	_test_parallel_shipbuilding(database)
	_test_parallel_physical_refits(database)
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
		database.combat_areas, database.extraction_networks, database.industrial_templates,
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
	_check(localization.goal_step("refine_first_copper", "Refine First Copper") == "精炼第一批铜锭", "goal steps use the same Chinese content layer")
	_check(localization.megastructure_stage("stellar_energy", 50, "Power Routing Spine") == "能源路由主干", "Megastructure milestones are localized instead of mixing languages")
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
	deferred_state.mining_site_states["lunar_deep_helium_anomaly"]["discovered"] = true
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
	simulation.advance(state, 60000.0)
	_check(state.item_quantity("mixed_raw_ore") == before + 2, "the automatic network produces the site's mixed raw material at a stable fixed rate")
	_check(state.item_quantity("iron_ore") == 0, "the automatic network never bypasses industrial refinement into specific minerals")

	var grade_state := _new_state(database, simulation)
	grade_state.mining_site_states["lunar_kreep_rare_earths"].merge({"discovered":true, "unlocked":true, "state":"AVAILABLE", "mastery_level":2}, true)
	grade_state.extraction_network_states["lunar_extraction_network"].merge({"unlocked":true, "status":"IDLE"}, true)
	grade_state.technologies["industrial_coordination"] = true
	_check(not bool(simulation.mining_site_network_eligibility(grade_state, "lunar_kreep_rare_earths", "lunar_extraction_network").get("eligible", false)), "material grade blocks integration when extraction-industry technology is too low")
	grade_state.technologies["heavy_extraction"] = true
	_check(bool(simulation.mining_site_network_eligibility(grade_state, "lunar_kreep_rare_earths", "lunar_extraction_network").get("eligible", false)), "higher extraction-industry technology satisfies the site's material-grade condition")


func _test_location_logistics(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.regions["lunar_space"] = true
	state.region_states["lunar_space"]["discovered"] = true
	state.region_states["lunar_space"]["exploration_state"] = "SURVEYED"
	simulation.ensure_frontier_state(state)
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
	simulation.logistics.configure_policy(energy_state, "earth_orbit", "iron_ore", {"mode":"SUPPLY", "reserve":0})
	simulation.logistics.configure_policy(energy_state, "lunar_space", "iron_ore", {"mode":"DEMAND", "target":10})
	energy_state.location_state("earth_orbit")["industry"]["power_capacity"] = 0.0
	simulation.ensure_frontier_state(energy_state)
	energy_state.location_state("earth_orbit")["power"]["available_capacity"] = 0.0
	_check(simulation.logistics._dispatch(energy_state).is_empty(), "energy-based Logistics technology cannot dispatch from an unpowered Hub")
	energy_state.location_state("earth_orbit")["industry"]["power_capacity"] = 100.0
	simulation.ensure_frontier_state(energy_state)
	energy_state.location_state("earth_orbit")["power"]["available_capacity"] = 100.0
	_check(not simulation.logistics._dispatch(energy_state).is_empty(), "available Location power supplies the Logistics energy budget and restores dispatch")


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
	_check(simulation.apply_industrial_template(state, "earth_orbit", "heavy_industry_world"), "a production Template enables policy-managed Location expansion")
	var foundry_before := int(state.location_industry("earth_orbit", "orbital_foundry").get("level", 1))
	var accelerated_expansion_interval := float(database.industry_rules.get("automation_expansion_interval_ms", 60000.0)) / simulation.production_speed_multiplier()
	simulation.advance(state, accelerated_expansion_interval + 1.0)
	_check(int(state.location_industry("earth_orbit", "orbital_foundry").get("level", 1)) == foundry_before + 1 and str(state.location_state("earth_orbit").get("automation", {}).get("last_blocked_reason", "")) == "", "late-game Template automation expands its managed industry using real local materials and the normal cost curve")


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
	state.add_item("structural_frame", 4)
	_start_test_refit(state, first_id, desired)
	_check(state.refit_projects.size() == 1, "design-first refit can begin after one confirmation")
	_start_test_refit(state, second_id, desired)
	_check(state.refit_projects.size() == 2, "multiple refits can run simultaneously without refit slots")
	_check(state.ship_module_definition_ids(state.ship_by_id(first_id)).has("mining_laser"), "configuration remains unchanged while refit is in progress")
	simulation.advance(state, 20000.0)
	_check(state.refit_projects.is_empty(), "both refits finish in parallel")
	_check(state.ship_module_definition_ids(state.ship_by_id(first_id)).has("cargo_expansion") and not state.ship_module_definition_ids(state.ship_by_id(first_id)).has("mining_laser"), "confirmed refit atomically applies the proposed design configuration")
	_check(state.stored_equipment_ids("mining_laser").is_empty() and state.item_quantity("structural_frame") == 0, "ordinary refits consume the positive BOM delta and create no removed-module inventory")


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
	var configured_speed := float(database.industry_rules.get("production_speed_multiplier", 1.0))
	database.industry_rules["production_speed_multiplier"] = 1.0
	var baseline_duration := simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], runtime)
	database.industry_rules["production_speed_multiplier"] = configured_speed
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
	database.industry_rules["production_speed_multiplier"] = 1.0
	var baseline_build_duration := simulation.effective_duration_ms(capital_state, "construction", database.activities["build_orbital_foundry"], build_runtime)
	var baseline_shipyard_duration := simulation.shipyard_cycle_duration_ms(capital_state, ship_plan)
	var baseline_refit_duration := simulation.refit_cycle_duration_ms(capital_state, {"cycle_time_ms":100.0})
	database.industry_rules["production_speed_multiplier"] = configured_speed
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
	_check(simulation.expand_location_industry(state, "natural_test", "makeshift_workshop", 1), "a Natural Location can establish aggregate Industry Level 1")
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
	_check(simulation.location_industry_constraint_profile(state, "natural_test").get("cooling_required", true) == false and simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], natural_operation) != INF, "Natural Locations do not require Cooling")

	state.ensure_location("artificial_test", LocationState.ARTIFICIAL, true, "sol")
	state.location_state("artificial_test")["industry"]["structural_capacity"] = 0.0
	state.add_item("iron_ingot", 100, "artificial_test")
	state.add_item("electronics", 100, "artificial_test")
	_check(not simulation.expand_location_industry(state, "artificial_test", "makeshift_workshop", 1), "Artificial Location expansion is hard-limited by Structural Capacity")
	state.location_state("artificial_test")["industry"]["structural_capacity"] = 10.0
	_check(simulation.expand_location_industry(state, "artificial_test", "makeshift_workshop", 1), "adding station structure permits Industry expansion")
	var station_operation := state.industrial_operation_for("artificial_test", "makeshift_workshop")
	station_operation.merge({"activity_id":"refine_iron", "status":"RUNNING"}, true)
	state.add_item("iron_ore", 100, "artificial_test")
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
	storage_state.location_state("earth_orbit")["logistics"]["storage_capacity"] = storage_state.total_inventory_units("earth_orbit")
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
	state.add_item("project_core", 10)
	state.add_item("antimatter_cell", 20)
	state.add_item("iron_ingot", 100)
	state.add_item("electronics", 100)
	var activity: Dictionary = database.activities["construct_stellar_energy"]
	var runtime: Dictionary = state.construction_operations[0]
	runtime.merge({"activity_id":activity.get("id", ""), "status":"RUNNING", "cycle_progress":0.0, "project_cycles_completed":0, "paid_cycles":0, "consumed":{}, "reserved_costs":{}}, true)
	simulation.begin_megastructure_project(state, runtime, activity)
	var duration := simulation.effective_duration_ms(state, "construction", activity, runtime)
	simulation.advance(state, duration * 25.0 + 1.0)
	var project: Dictionary = state.megastructure_projects.get("stellar_energy", {})
	_check(int(project.get("progress_percent", 0)) == 25 and int(project.get("stage_index", -1)) == 2, "Megastructure construction crosses real 10 and 25 percent stages")
	_check(not project.get("delivered_materials", {}).is_empty() and str(project.get("material_flow_status", "")) == "RECEIVING", "Megastructure stage state records delivered Material Flow")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(int(restored.megastructure_projects.get("stellar_energy", {}).get("progress_percent", 0)) == 25, "Megastructure stage and delivered materials survive save/load")
	simulation.advance(state, duration * 75.0 + 1.0)
	_check(bool(state.megastructures.get("stellar_energy", false)) and str(state.megastructure_projects.get("stellar_energy", {}).get("status", "")) == "COMPLETE", "the 100 percent stage applies the Megastructure's gameplay effect")

	var freight_state := _new_state(database, simulation)
	freight_state.regions["lunar_space"] = true
	freight_state.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	simulation.ensure_frontier_state(freight_state)
	freight_state.add_item("iron_ingot", 50, "lunar_space")
	freight_state.add_item("chemical_propellant", 5, "lunar_space")
	freight_state.add_item("repair_material", 5, "lunar_space")
	_check(simulation.logistics.configure_policy(freight_state, "lunar_space", "iron_ingot", {"mode":"SUPPLY", "reserve":0}), "a remote Megastructure material source can be exposed through Supply")
	var freight_runtime: Dictionary = freight_state.construction_operations[0]
	freight_runtime.merge({"activity_id":activity.get("id", ""), "status":"BLOCKED", "location_id":"earth_orbit", "project_cycles_completed":0, "paid_cycles":0, "consumed":{}}, true)
	simulation.begin_megastructure_project(freight_state, freight_runtime, activity)
	freight_state.megastructure_projects["stellar_energy"]["status"] = "BLOCKED"
	simulation.advance(freight_state, 5000.0)
	_check(freight_state.logistics_network.get("shipments", []).any(func(value): return int((value as Dictionary).get("cargo", {}).get("iron_ingot", 0)) > 0 and str((value as Dictionary).get("destination", "")) == "earth_orbit"), "a live Megastructure creates project Demand and moves remote material through a real Shipment")
	_check(str(freight_state.megastructure_projects["stellar_energy"].get("material_flow_status", "")) == "IN_TRANSIT", "Megastructure Material Flow distinguishes in-transit cargo from local construction progress")


func _test_save_contract(database: ContentDatabase) -> void:
	var state := _new_state(database)
	state.mining_operations.append(SpaceGameState.create_operation_record(state.mining_operations.size(), "mining"))
	var data := state.to_dictionary()
	_check(int(data.get("save_version", 0)) == SpaceGameState.SAVE_VERSION and SpaceGameState.SAVE_VERSION == 27, "the complete core-rules release uses one clean current save schema")
	_check(data.has("mining_site_states") and data.has("extraction_command") and data.has("equipment_instances") and data.has("asset_semantics_version") and data.has("fleet_logistics") and data.has("fleet_maintenance") and data.has("ship_service_projects") and data.has("naval_archive") and data.has("logistics_network") and data.has("megastructure_projects"), "sites, ordinary/special asset semantics, lifecycle, fleet cargo, Shipment and Megastructure state are persisted")
	_check(data.has("extraction_assets") and not data.has("prospect_states") and not data.has("operation_limits") and not data.has("salvaging_operation") and not data.has("salvage_target_states"), "the save contract contains no retired salvage runtime")
	var restored := SpaceGameState.from_dictionary(data, database.domains.keys(), database.regions)
	_check(restored.equipment_instances.size() == state.equipment_instances.size() and restored.ships.size() == state.ships.size(), "current-schema save round-trip preserves physical assets")
	_check(restored.mining_operations.size() == state.mining_operations.size(), "one runtime per active permanent site persists without an arbitrary six-slot cap")
	var repository := LocalSaveRepository.new()
	_check(repository._checksum({"b":2, "a":1}) == repository._checksum({"a":1, "b":2}), "save checksum is independent of Dictionary insertion order")


func _new_state(database: ContentDatabase, simulation: SimulationEngine = null) -> SpaceGameState:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var active_simulation := simulation if simulation != null else SimulationEngine.new(database)
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


func _start_test_refit(state: SpaceGameState, ship_id: String, desired: Array) -> void:
	var project_id := "REFIT-TEST-%d" % (state.refit_projects.size() + 1)
	state.refit_projects.append({
		"project_id":project_id, "ship_id":ship_id, "desired_definitions":desired.duplicate(),
		"reserved_equipment_ids":[], "ordinary_module_additions":["cargo_expansion"], "consumed_bom":{"structural_frame":2},
		"completed_segments":0, "cycle_progress":0.0, "cycle_time_ms":100.0,
		"status":"RUNNING", "started_at_ms":int(state.total_elapsed_ms)
	})
	state.remove_item("structural_frame", 2)
	var ship := state.ship_by_id(ship_id)
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
