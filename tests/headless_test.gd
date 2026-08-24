extends SceneTree

var failures: Array[String] = []


func _init() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content loads and validates: %s" % str(database.errors))
	if not database.errors.is_empty():
		_finish()
		return
	_test_localization(database)
	# Visual-profile coverage belongs to the presentation project, not Gameplay Lab.
	_test_frontier_content(database)
	_test_physical_ship_assets(database)
	_test_permanent_extraction(database)
	_test_mature_extraction_network(database)
	_test_exploration_and_first_clear(database)
	_test_combat_cycles_and_logistics(database)
	_test_parallel_shipbuilding(database)
	_test_parallel_physical_refits(database)
	_test_industry_and_capital_cycles(database)
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
		database.combat_areas, database.extraction_networks,
		database.goals, database.technologies, database.research_projects,
		database.ship_construction_projects, database.enemies,
		database.expedition_routes, database.megastructures
	]:
		translated_definitions.append_array(collection.values())
	var missing: Array[String] = []
	for definition in translated_definitions:
		var definition_id := str(definition.get("id", ""))
		if not localization._translations.get("content", {}).has(definition_id):
			missing.append(definition_id)
	_check(missing.is_empty(), "Chinese content translation coverage: %s" % str(missing))
	localization.free()


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
	_check(starter.get("modules", []).all(func(value): return str(value).begins_with("EQUIP-")), "installed modules are persistent physical equipment instances")
	_check(state.ship_module_definition_ids(starter).has("mining_laser"), "the starter physical configuration is mining-first")
	var first_copy := state.create_equipment_instance("mining_laser", "TEST")
	_check(state.install_equipment_instance(first_copy, str(starter.get("instance_id", ""))), "a stored physical module can be installed")
	var second_ship := state._create_ship_instance("patchwork_prospector", [], "ISS Second")
	_check(not second_ship.is_empty() and state.ships.size() == 2, "multiple unique ship instances may share one hull design")
	_check(not state.install_equipment_instance(first_copy, str(second_ship.get("instance_id", ""))), "one physical module cannot be installed on two ships")
	_check(state.store_equipment_instance(first_copy) and state.stored_equipment_ids("mining_laser").has(first_copy), "removed equipment returns to Starport storage")
	_check(state.install_equipment_instance(first_copy, str(second_ship.get("instance_id", ""))), "stored equipment can be reassigned to another docked asset")
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

	var laser_id := state.create_equipment_instance("corsair_overcharged_laser", "TEST")
	var old_weapon := _equipment_id_for_definition(state, state.ships[0], "light_autocannon")
	state.store_equipment_instance(old_weapon)
	state.install_equipment_instance(laser_id, "SHIP-001")
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
	var actor: Dictionary = combat_state.get("actors", [])[0]
	_check(float(actor.get("attack_next_ms", 0.0)) != float(actor.get("skill_next_ms", 0.0)), "ordinary attacks and skills use two independent Cycle timers")
	resolver.advance_clock(combat_state, float(actor.get("attack_next_ms", 0.0)))
	var first_event := resolver.settle_next_event(state, combat_state)
	_check(first_event.get("cycle_kind", "") == "ATTACK" and int(combat_state.get("actors", [])[0].get("attacks", 0)) == 1, "one completed Attack Cycle resolves exactly one normal attack")
	_check(int(combat_state.get("actors", [])[0].get("skills_used", 0)) == 0, "normal attacks do not consume the separate Skill Cycle")
	_check(state.fleet_supply_quantity("kinetic_munitions") == 19, "ammunition weapons consume shared Fleet Cargo supplies per normal attack")
	var skill_remaining := float(combat_state.get("actors", [])[0].get("skill_next_ms", 0.0))
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
	resolver.advance_clock(dry_combat, float(dry_combat.get("actors", [])[0].get("attack_next_ms", 0.0)))
	var dry_event := resolver.settle_next_event(dry_state, dry_combat)
	_check(dry_event.get("type", "") == "SUPPLY_DEPLETED" and dry_combat.get("status", "") == "WITHDRAWN", "ammunition depletion causes a predictable logistics withdrawal instead of magical firing")


func _test_parallel_shipbuilding(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.unlock_ship_plan("construct_lunar_pathfinder")
	state.add_item("reactor_part", 10)
	state.add_item("titanium_alloy", 20)
	state.add_item("electronics", 20)
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
	var first_old := _equipment_id_for_definition(state, state.ship_by_id(first_id), "mining_laser")
	var desired := ["light_autocannon", "civilian_shield", "basic_drive", "cargo_expansion", "civilian_reactor_core"]
	_start_test_refit(state, first_id, desired)
	_check(state.refit_projects.size() == 1, "design-first refit can begin after one confirmation")
	_start_test_refit(state, second_id, desired)
	_check(state.refit_projects.size() == 2, "multiple refits can run simultaneously without refit slots")
	_check(state.ship_module_definition_ids(state.ship_by_id(first_id)).has("mining_laser"), "physical configuration remains unchanged while refit is in progress")
	simulation.advance(state, 20000.0)
	_check(state.refit_projects.is_empty(), "both refits finish in parallel")
	_check(state.ship_module_definition_ids(state.ship_by_id(first_id)).has("cargo_expansion") and not state.ship_module_definition_ids(state.ship_by_id(first_id)).has("mining_laser"), "confirmed refit atomically applies the proposed physical configuration")
	_check(state.stored_equipment_ids("mining_laser").has(first_old), "removed physical equipment is retained in Starport storage")


func _test_industry_and_capital_cycles(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := _new_state(database, simulation)
	state.add_item("iron_ore", 100)
	var runtime: Dictionary = state.industrial_operations[0]
	runtime.merge({"activity_id":"refine_iron", "status":"RUNNING", "progress_ms":0.0, "productivity_progress":0.0}, true)
	var duration := simulation.effective_duration_ms(state, "industry", database.activities["refine_iron"], runtime)
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
	simulation.advance(capital_state, 100000.0)
	_check(float(build_runtime.get("productivity_progress", -1.0)) == 0.0, "infrastructure construction discards legacy Productivity and only accelerates its 100 Cycles")


func _test_save_contract(database: ContentDatabase) -> void:
	var state := _new_state(database)
	state.mining_operations.append(SpaceGameState.create_operation_record(state.mining_operations.size(), "mining"))
	var data := state.to_dictionary()
	_check(int(data.get("save_version", 0)) == SpaceGameState.SAVE_VERSION and SpaceGameState.SAVE_VERSION == 25, "the Location foundation uses one clean current save schema")
	_check(data.has("mining_site_states") and data.has("extraction_command") and data.has("equipment_instances") and data.has("fleet_logistics"), "permanent sites, Extraction Command, physical equipment and logistics state are persisted")
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
	var old_id := _equipment_id_for_definition(state, ship, old_definition)
	if not old_id.is_empty():
		state.store_equipment_instance(old_id)
	var new_id := state.create_equipment_instance(new_definition, "TEST")
	state.install_equipment_instance(new_id, ship_id)


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
		"reserved_equipment_ids":[], "pending_new_definitions":["cargo_expansion"],
		"completed_segments":0, "cycle_progress":0.0, "cycle_time_ms":100.0,
		"status":"RUNNING", "started_at_ms":int(state.total_elapsed_ms)
	})
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
