class_name SimulationEngine
extends RefCounted

const CombatResolverScript = preload("res://src/core/combat_resolver.gd")
const LogisticsEngineScript = preload("res://src/core/logistics_engine.gd")
const EconomyPlannerScript = preload("res://src/core/economy_planner.gd")
const MAX_OPERATIONS := 350000
const MAX_OFFLINE_MS := 24 * 60 * 60 * 1000
const BLOCKER_REASON_CODES := [
	"MISSING_TECH", "MISSING_FACILITY", "MISSING_SCALE_STAGE", "MISSING_CAPITAL_GOOD",
	"KNOWLEDGE_GATE", "RESEARCH_CAPACITY_SHORTAGE", "OPERATING_CONDITION", "FIELD_TEST_REQUIRED",
	"INPUT_SHORTAGE", "INPUT_IN_TRANSIT", "ROUTE_UNAVAILABLE", "TRANSPORT_MODE_UNAVAILABLE",
	"ROUTE_CONGESTED", "HANDLING_CONGESTED", "POWER_SHORTAGE", "COOLING_SHORTAGE",
	"STORAGE_FULL", "MAINTENANCE_SHORTAGE", "CONSTRUCTION_CAPACITY_FULL",
	"PROJECT_SLOT_FULL", "MANUALLY_PAUSED"
]
const CONSTRUCTION_PROJECT_TYPES := [
	"FACILITY_BUILD", "FACILITY_EXPANSION", "SCALE_STAGE_UPGRADE",
	"INDUSTRY_SPECIALIZATION", "INDUSTRIAL_TRANSFORMATION",
	"POWER_UPGRADE", "COOLING_UPGRADE", "STRUCTURE_UPGRADE", "STORAGE_UPGRADE",
	"BULK_STORAGE_UPGRADE", "COMPONENT_STORAGE_UPGRADE", "FLUID_STORAGE_UPGRADE", "SPECIAL_STORAGE_UPGRADE",
	"LOGISTICS_HUB_UPGRADE", "TRANSPORT_INFRASTRUCTURE", "EXTRACTION_NETWORK", "MEGASTRUCTURE"
]

var content: ContentDatabase
var rng := DomainRng.new()
var modifiers := ModifierEngine.new()
var requirements: RequirementEngine
var combat: RefCounted
var logistics: RefCounted
var economy_planner: RefCounted
var emitted_events: Array[Dictionary] = []
var simulation_profile_id := ""


func _init(database: ContentDatabase) -> void:
	content = database
	simulation_profile_id = str(content.simulation_profiles.get("default_profile", "TEST_PROFILE"))
	requirements = RequirementEngine.new(content, capability_value)
	combat = CombatResolverScript.new(content, rng)
	logistics = LogisticsEngineScript.new(content)
	economy_planner = EconomyPlannerScript.new(content, self)


func advance(state: SpaceGameState, elapsed_ms: float) -> Dictionary:
	emitted_events.clear()
	ensure_frontier_state(state)
	logistics.ensure_state(state)
	_refresh_output_storage_blocks(state)
	_validate_runtime(state)
	normalize_shipyard_queue(state)
	_ensure_repeat_combat_state(state)
	_refresh_resource_commitments(state)
	refresh_demand_registry(state)
	var requested := minf(maxf(0.0, elapsed_ms), float(MAX_OFFLINE_MS))
	var remaining := requested
	var boundaries := 0
	var settled_runs := 0
	while remaining > 0.001 and boundaries < MAX_OPERATIONS:
		_validate_research(state)
		normalize_shipyard_queue(state)
		_ensure_repeat_combat_state(state)
		var boundary := _next_boundary_ms(state)
		if boundary == INF:
			# Background infrastructure has no discrete completion boundary, but it
			# must still advance when every active foreground system is idle.
			_progress_runtime(state, remaining)
			state.total_elapsed_ms += remaining
			remaining = 0.0
			break
		var step := minf(remaining, boundary)
		_progress_runtime(state, step)
		state.total_elapsed_ms += step
		remaining -= step
		# Settle any whole cycles reached inside a shorter requested window as well.
		# Relevant boundaries still cap batching, but online ticks no longer wait until
		# the next level-up before granting ordinary cycle rewards.
		var settled := _settle_ready_boundaries(state)
		var completed := int(settled.get("boundaries", 0))
		if completed > 0:
			_refresh_resource_commitments(state)
			refresh_demand_registry(state)
			boundaries += completed
			settled_runs += int(settled.get("runs", completed))
		elif step + 0.001 >= boundary:
			break
	refresh_location_summaries(state)
	refresh_demand_registry(state)
	_refresh_blocker_diagnostics(state)
	return {
		"simulated_ms":requested - remaining,
		"unprocessed_ms":remaining,
		"operations":boundaries,
		"settled_runs":settled_runs,
		"events":emitted_events.duplicate(true),
		"expedition_reports":state.expedition_reports.duplicate(true),
		"operation_limit_reached":boundaries >= MAX_OPERATIONS
	}


func ensure_ship_loadout_semantics(state: SpaceGameState) -> void:
	var referenced_special := {}
	var ordinary_equipment_ids: Array[String] = []
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		var normalized_modules: Array = []
		for module_value in ship.get("modules", []):
			var stored_value := str(module_value)
			var definition_id := state.equipment_definition_id(stored_value)
			if definition_id.is_empty() and content.modules.has(stored_value):
				definition_id = stored_value
			if definition_id.is_empty() or not content.modules.has(definition_id):
				continue
			var definition: Dictionary = content.modules[definition_id]
			if bool(definition.get("special_equipment", false)):
				var equipment_id := stored_value
				if not state.equipment_instances.has(equipment_id):
					equipment_id = state.create_equipment_instance(definition_id, "ASSET_MIGRATION")
				if referenced_special.has(equipment_id):
					push_warning("Duplicate special-equipment occupancy removed during migration: %s" % equipment_id)
					continue
				state.equipment_instances[equipment_id]["status"] = "INSTALLED"
				state.equipment_instances[equipment_id]["installed_ship_id"] = str(ship.get("instance_id", ""))
				referenced_special[equipment_id] = str(ship.get("instance_id", ""))
				normalized_modules.append(equipment_id)
			else:
				normalized_modules.append(definition_id)
				if state.equipment_instances.has(stored_value):
					ordinary_equipment_ids.append(stored_value)
		ship["modules"] = normalized_modules
	for equipment_value in state.equipment_instances.keys().duplicate():
		var equipment_id := str(equipment_value)
		var equipment: Dictionary = state.equipment_instances.get(equipment_id, {})
		var definition_id := str(equipment.get("definition_id", ""))
		if not content.modules.has(definition_id) or not bool(content.modules[definition_id].get("special_equipment", false)):
			ordinary_equipment_ids.append(equipment_id)
			continue
		if referenced_special.has(equipment_id):
			equipment["status"] = "INSTALLED"
			equipment["installed_ship_id"] = str(referenced_special[equipment_id])
		elif str(equipment.get("status", "")) == "INSTALLED":
			equipment["status"] = "STORAGE"
			equipment["installed_ship_id"] = ""
	for equipment_id in ordinary_equipment_ids:
		state.equipment_instances.erase(equipment_id)
	# Ordinary modules are not inventory. Convert legacy or rejected phase-five
	# stack quantities back into their raw BOM at the same Location or Shipment.
	for location_value in state.locations.keys():
		_replace_ordinary_module_assets_with_bom(state.location_inventory(str(location_value)))
	for shipment_value in state.logistics_network.get("shipments", []):
		_replace_ordinary_module_assets_with_bom((shipment_value as Dictionary).get("cargo", {}))
	for runtime_value in state.shipyard_queue:
		var runtime := runtime_value as Dictionary
		var escrow: Dictionary = runtime.get("module_escrow", {}).duplicate(true)
		_replace_ordinary_module_assets_with_bom(escrow)
		var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		for item_id_value in escrow.keys():
			state.add_item(str(item_id_value), int(escrow[item_id_value]), location_id)
		runtime.erase("module_escrow")
		runtime.erase("module_escrow_initialized")
		runtime.erase("module_asset_semantics_version")
	state.asset_semantics_version = 4


func _replace_ordinary_module_assets_with_bom(values: Dictionary) -> void:
	for module_value in content.modules.keys():
		var module_id := str(module_value)
		if bool(content.modules[module_id].get("special_equipment", false)):
			continue
		var quantity := maxi(0, int(values.get(module_id, 0)))
		if quantity <= 0:
			continue
		values.erase(module_id)
		for cost_value in content.module_bom(module_id):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			values[item_id] = int(values.get(item_id, 0)) + int(cost.get("quantity", 0)) * quantity


func ensure_frontier_state(state: SpaceGameState) -> void:
	ensure_ship_loadout_semantics(state)
	normalize_refit_projects(state)
	state.ensure_main_location_industries()
	for region_id in content.regions:
		var region_definition: Dictionary = content.regions.get(region_id, {})
		state.ensure_location(
			str(region_id),
			str(region_definition.get("location_type", LocationState.ARTIFICIAL if str(region_id) == SpaceGameState.MAIN_BASE_LOCATION_ID else LocationState.NATURAL)),
			bool(state.regions.get(region_id, false)),
			str(region_definition.get("system_id", SpaceGameState.SYSTEM_ID))
		)
		if not state.region_states.has(region_id):
			var known := bool(state.regions.get(region_id, false))
			state.region_states[region_id] = {
				"discovered":known,
				"survey_state":"SURVEYED" if known else "UNKNOWN",
				"exploration_state":"SURVEYED" if known else "UNKNOWN",
				"strategic_state":"SECURED" if region_id == "earth_orbit" else ("OPEN" if known else "UNKNOWN"),
				"development_state":"MATURE" if region_id == "earth_orbit" else ("FRONTIER" if known else "UNKNOWN")
			}
		var location: Dictionary = state.location_state(str(region_id))
		var region_runtime: Dictionary = state.region_states.get(region_id, {})
		var survey_state := str(region_runtime.get("survey_state", region_runtime.get("exploration_state", "UNKNOWN")))
		if survey_state == "UNSURVEYED" or survey_state not in LocationState.SURVEY_STATE_ORDER:
			survey_state = LocationState.UNKNOWN
		if bool(region_runtime.get("discovered", false)) and survey_state == LocationState.UNKNOWN:
			survey_state = LocationState.DETECTED
		region_runtime["survey_state"] = survey_state
		region_runtime["exploration_state"] = survey_state
		location["discovery_state"] = LocationState.DISCOVERED if survey_state != LocationState.UNKNOWN else LocationState.UNDISCOVERED
		location["survey_state"] = survey_state
		location["environment"] = region_definition.get("environment", {}).duplicate(true)
	for site_id in content.mining_sites:
		var definition: Dictionary = content.mining_sites[site_id]
		var resource_region: Dictionary = content.resource_regions.get(str(definition.get("resource_region", "")), {})
		var region_id := str(resource_region.get("region", ""))
		if not state.mining_site_states.has(site_id):
			var initially_discovered := bool(definition.get("initially_discovered", false))
			var auto_discovered := region_id != "lunar_space" and bool(state.regions.get(region_id, false))
			state.mining_site_states[site_id] = {
				"site_id":site_id,
				"region":region_id,
				"discovered":initially_discovered or auto_discovered,
				"unlocked":not bool(definition.get("deferred", false)),
				"mastery_cycles":0,
				"mastery_level":0,
				"integrated_network_id":"",
				"state":"AVAILABLE" if initially_discovered or auto_discovered else "UNDISCOVERED",
				"survey_state":LocationState.SURVEYED if initially_discovered else LocationState.UNKNOWN,
				"developed":initially_discovered,
				"extraction_method_id":"fixed_excavation" if initially_discovered else ""
			}
		var runtime: Dictionary = state.mining_site_states[site_id]
		var region_survey_state := str(state.region_states.get(region_id, {}).get("survey_state", LocationState.UNKNOWN))
		if survey_state_rank(region_survey_state) > survey_state_rank(str(runtime.get("survey_state", LocationState.UNKNOWN))):
			runtime["survey_state"] = region_survey_state
		# Non-Lunar routes unlock their region as a whole. These runtime records are
		# created on a new save before that happens, so they must also transition
		# when the route later grants the region instead of remaining undiscovered.
		if not bool(runtime.get("discovered", false)) and region_id != "lunar_space" and bool(state.regions.get(region_id, false)):
			runtime["discovered"] = true
			runtime["state"] = "DEFERRED" if bool(definition.get("deferred", false)) else "AVAILABLE"
		if bool(runtime.get("discovered", false)) and bool(definition.get("deferred", false)):
			var eligible := true
			for requirement in definition.get("requirements", []):
				if not requirement_met(state, requirement):
					eligible = false
					break
			runtime["unlocked"] = eligible
			if str(runtime.get("integrated_network_id", "")).is_empty():
				runtime["state"] = "AVAILABLE" if eligible else "DEFERRED"
		runtime["developed"] = bool(runtime.get("developed", not str(runtime.get("integrated_network_id", "")).is_empty()))
		runtime["extraction_method_id"] = str(runtime.get("extraction_method_id", "fixed_excavation" if bool(runtime.get("developed", false)) else ""))
	for area_id in content.combat_areas:
		if not state.combat_area_states.has(area_id):
			state.combat_area_states[area_id] = {"unlocked":bool(content.combat_areas[area_id].get("initially_available", false)), "first_clear_complete":false, "completions":0}
	for network_id in content.extraction_networks:
		if state.extraction_network_states.has(network_id):
			continue
		state.extraction_network_states[network_id] = {"unlocked":false, "integrated_site_ids":[], "cycle_progress":0.0, "status":"LOCKED", "production_totals":{}}
	for operation in state.industrial_operations:
		var industry_location_id := str(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		if state.has_location(industry_location_id):
			state.ensure_location_industry(industry_location_id, str(operation.get("facility_id", "")), 1)
	refresh_location_summaries(state)


func survey_state_rank(survey_state: String) -> int:
	return LocationState.SURVEY_STATE_ORDER.find(survey_state)


func location_environment(state: SpaceGameState, location_id: String) -> Dictionary:
	if not state.has_location(location_id):
		return {}
	var runtime_environment: Dictionary = state.location_state(location_id).get("environment", {})
	return runtime_environment if not runtime_environment.is_empty() else content.regions.get(location_id, {}).get("environment", {})


func location_intelligence(state: SpaceGameState, location_id: String) -> Dictionary:
	ensure_frontier_state(state)
	var definition: Dictionary = content.regions.get(location_id, {})
	if definition.is_empty():
		return {}
	var survey_state := str(state.location_state(location_id).get("survey_state", LocationState.UNKNOWN))
	var result := {"location_id":location_id, "name":definition.get("name", location_id), "survey_state":survey_state, "system_id":definition.get("system_id", SpaceGameState.SYSTEM_ID)}
	if survey_state == LocationState.UNKNOWN:
		return result
	var environment := location_environment(state, location_id)
	var profiles: Array = []
	for mining_location_value in content.mining_locations.values():
		var mining_location := mining_location_value as Dictionary
		if str(mining_location.get("region", "")) != location_id:
			continue
		var profile: Dictionary = mining_location.get("resource_profile", {}).duplicate(true)
		profile["mining_location_id"] = mining_location.get("id", "")
		profile["resource_type"] = mining_location.get("raw_material", profile.get("resource_type", ""))
		if survey_state == LocationState.DETECTED:
			profiles.append({
				"mining_location_id":profile.get("mining_location_id", ""),
				"resource_category":content.items.get(str(profile.get("resource_type", "")), {}).get("category", "Resource"),
				"potential_band":_potential_band(float(mining_location.get("extraction_potential", 0.0)))
			})
			continue
		profile["grade_range"] = profile.get("grade_range", [maxf(0.0, float(mining_location.get("density", 1.0)) - 0.2), float(mining_location.get("density", 1.0)) + 0.2]).duplicate()
		profile["extraction_potential"] = float(mining_location.get("extraction_potential", 0.0))
		profile["survey_confidence"] = 1.0 if survey_state == LocationState.DEEP_SURVEYED else 0.75
		profile["hazards"] = mining_location.get("hazards", []).duplicate()
		if survey_state == LocationState.DEEP_SURVEYED:
			profile["grade"] = float(mining_location.get("density", 1.0))
			profile["advanced_potential"] = _maximum_resource_profile_potential(state, mining_location)
		profiles.append(profile)
	result["resources"] = profiles
	if survey_state == LocationState.DETECTED:
		result["environment"] = {
			"radiation":environment.get("radiation", "UNKNOWN"),
			"transport_distance_band":_distance_band(float(environment.get("transport_distance", 0.0))),
			"construction_difficulty_band":_difficulty_band(float(environment.get("construction_difficulty", 1.0)))
		}
	else:
		result["environment"] = environment.duplicate(true)
	return result


func _potential_band(value: float) -> String:
	if value >= 80.0: return "VERY_HIGH"
	if value >= 45.0: return "HIGH"
	if value >= 25.0: return "MODERATE"
	return "LOW"


func _distance_band(value: float) -> String:
	if value >= 9.0: return "REMOTE"
	if value >= 4.0: return "LONG"
	if value >= 1.0: return "MEDIUM"
	return "SHORT"


func _difficulty_band(value: float) -> String:
	if value >= 1.75: return "SEVERE"
	if value >= 1.3: return "HIGH"
	return "LOW"


func environment_condition_met(environment: Dictionary, condition: Dictionary) -> bool:
	var field := str(condition.get("field", ""))
	if field.is_empty() or not environment.has(field):
		return false
	var actual: Variant = environment.get(field)
	var expected: Variant = condition.get("value")
	match str(condition.get("operator", "EQ")):
		"EQ": return actual == expected
		"LT": return float(actual) < float(expected)
		"LTE": return float(actual) <= float(expected)
		"GT": return float(actual) > float(expected)
		"GTE": return float(actual) >= float(expected)
		"IN": return expected is Array and expected.has(actual)
	return false


func environment_requirements_met(state: SpaceGameState, location_id: String, requirements: Array) -> bool:
	var environment := location_environment(state, location_id)
	return requirements.all(func(condition): return environment_condition_met(environment, condition as Dictionary))


func production_method_environment_eligibility(state: SpaceGameState, location_id: String, method: Dictionary) -> Dictionary:
	var unmet: Array = []
	for condition_value in method.get("environment_requirements", []):
		var condition := condition_value as Dictionary
		if not environment_condition_met(location_environment(state, location_id), condition):
			unmet.append(condition.duplicate(true))
	return {"eligible":unmet.is_empty(), "unmet":unmet, "location_id":location_id, "method_id":method.get("id", "")}


func extraction_method_available(state: SpaceGameState, site_id: String, method_id: String) -> bool:
	var site: Dictionary = content.mining_sites.get(site_id, {})
	var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
	var method: Dictionary = content.extraction_methods.get(method_id, {})
	var profile: Dictionary = mining_location.get("resource_profile", {})
	if site.is_empty() or method.is_empty() or not profile.get("allowed_methods", []).has(method_id):
		return false
	var site_runtime: Dictionary = state.mining_site_states.get(site_id, {})
	if survey_state_rank(str(site_runtime.get("survey_state", LocationState.UNKNOWN))) < survey_state_rank(str(method.get("survey_required", LocationState.SURVEYED))):
		return false
	if not environment_requirements_met(state, str(mining_location.get("region", "")), method.get("environment_requirements", [])):
		return false
	for requirement_value in method.get("requirements", []):
		if not requirement_met(state, requirement_value as Dictionary):
			return false
	return true


func extraction_site_sustainable_potential(state: SpaceGameState, site_id: String, method_id: String = "") -> float:
	var site: Dictionary = content.mining_sites.get(site_id, {})
	var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
	if mining_location.is_empty():
		return 0.0
	var selected_method := method_id
	if selected_method.is_empty():
		selected_method = str(state.mining_site_states.get(site_id, {}).get("extraction_method_id", "mobile_surface_extraction"))
	var multiplier := float(content.extraction_methods.get(selected_method, {}).get("potential_multiplier", 1.0))
	return maxf(0.0, float(mining_location.get("extraction_potential", 0.0)) * multiplier)


func _maximum_resource_profile_potential(state: SpaceGameState, mining_location: Dictionary) -> float:
	var result := float(mining_location.get("extraction_potential", 0.0))
	for method_id_value in mining_location.get("resource_profile", {}).get("allowed_methods", []):
		var method: Dictionary = content.extraction_methods.get(str(method_id_value), {})
		var requirements_met := true
		for requirement_value in method.get("requirements", []):
			if not requirement_met(state, requirement_value as Dictionary):
				requirements_met = false
		if requirements_met:
			result = maxf(result, float(mining_location.get("extraction_potential", 0.0)) * float(method.get("potential_multiplier", 1.0)))
	return result


func start_survey_mission(state: SpaceGameState, target_location_id: String, target_state: String, ship_ids: Array, origin_location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	ensure_frontier_state(state)
	if target_state not in LocationState.SURVEY_STATE_ORDER or target_state == LocationState.UNKNOWN or not state.has_location(target_location_id) or not state.has_location(origin_location_id):
		return false
	if str(state.location_state(target_location_id).get("system_id", "")) != SpaceGameState.SYSTEM_ID or str(state.location_state(origin_location_id).get("system_id", "")) != SpaceGameState.SYSTEM_ID:
		return false
	if str(state.survey_mission.get("status", "IDLE")) == "RUNNING" or survey_state_rank(target_state) != survey_state_rank(str(state.location_state(target_location_id).get("survey_state", LocationState.UNKNOWN))) + 1:
		return false
	var capability := str(content.survey_rules.get("required_capabilities", {}).get(target_state, ""))
	if ship_ids.is_empty() or capability_value_for_ships(state, capability, ship_ids) < 1.0:
		return false
	for ship_id_value in ship_ids:
		var ship_id := str(ship_id_value)
		if not state.ship_is_docked(ship_id) or str(state.ship_by_id(ship_id).get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != origin_location_id:
			return false
	var costs := _cost_entries_to_dictionary(content.survey_rules.get("base_costs", {}).get(target_state, []))
	for item_id_value in costs.keys():
		if state.available_item_quantity(str(item_id_value), origin_location_id) < int(costs[item_id_value]):
			return false
	for item_id_value in costs.keys():
		state.remove_item(str(item_id_value), int(costs[item_id_value]), origin_location_id)
	var distance := absf(float(location_environment(state, target_location_id).get("transport_distance", 0.0)) - float(location_environment(state, origin_location_id).get("transport_distance", 0.0)))
	var capability_value := maxf(1.0, capability_value_for_ships(state, capability, ship_ids))
	var duration := float(content.survey_rules.get("mission_work_ms", {}).get(target_state, 10000.0)) * (1.0 + distance * 0.08) / capability_value
	var mission_id := "SURVEY-%06d" % int(state.next_survey_mission_serial)
	state.next_survey_mission_serial += 1
	state.survey_mission = {"status":"RUNNING", "mission_id":mission_id, "origin":origin_location_id, "target":target_location_id, "target_state":target_state, "survey_capability":capability, "duration_ms":duration, "progress_ms":0.0, "costs":costs, "assigned_ship_ids":ship_ids.duplicate()}
	for ship_id_value in ship_ids:
		var ship := state.ship_by_id(str(ship_id_value))
		ship["status"] = "EXPEDITION"
		ship["assignment"] = {"type":"SURVEY_MISSION", "mission_id":mission_id, "target":target_location_id}
	return true


func _settle_survey_mission(state: SpaceGameState) -> bool:
	var mission: Dictionary = state.survey_mission
	if str(mission.get("status", "")) != "RUNNING" or float(mission.get("progress_ms", 0.0)) + 0.001 < float(mission.get("duration_ms", 1.0)):
		return false
	var target := str(mission.get("target", ""))
	var target_state := str(mission.get("target_state", LocationState.UNKNOWN))
	state.regions[target] = true
	var region_runtime: Dictionary = state.region_states.get(target, {})
	region_runtime["discovered"] = true
	region_runtime["survey_state"] = target_state
	region_runtime["exploration_state"] = target_state
	state.region_states[target] = region_runtime
	state.location_state(target)["discovery_state"] = LocationState.DISCOVERED
	state.location_state(target)["survey_state"] = target_state
	for site_id_value in content.mining_sites.keys():
		var site_id := str(site_id_value)
		var site: Dictionary = content.mining_sites.get(site_id, {})
		var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
		if str(mining_location.get("region", "")) != target:
			continue
		var site_runtime: Dictionary = state.mining_site_states.get(site_id, {})
		site_runtime["survey_state"] = target_state
		if survey_state_rank(target_state) >= survey_state_rank(LocationState.SURVEYED):
			site_runtime["discovered"] = true
			if str(site_runtime.get("state", "")) == "UNDISCOVERED":
				site_runtime["state"] = "AVAILABLE"
		state.mining_site_states[site_id] = site_runtime
	for ship_id_value in mission.get("assigned_ship_ids", []):
		var ship_id := str(ship_id_value)
		var ship := state.ship_by_id(ship_id)
		if ship.is_empty():
			continue
		ship["status"] = "DOCKED"
		var fleet_domain := state.ship_fleet_domain(ship_id)
		ship["assignment"] = {} if fleet_domain.is_empty() else {"domain":fleet_domain, "fleet":"default"}
	state.survey_mission["status"] = "COMPLETE"
	state.survey_mission["progress_ms"] = state.survey_mission.get("duration_ms", 0.0)
	emitted_events.append({"type":"SurveyMissionCompleted", "mission_id":mission.get("mission_id", ""), "target":target, "survey_state":target_state})
	return true


func refresh_location_summaries(state: SpaceGameState) -> void:
	var construction_projects: Array = state.construction_operations.filter(func(runtime): return str(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"] and not str(runtime.get("project_id", "")).is_empty())
	construction_projects.sort_custom(func(a, b):
		if int(a.get("priority", 50)) != int(b.get("priority", 50)):
			return int(a.get("priority", 50)) > int(b.get("priority", 50))
		if int(a.get("enqueued_at_ms", 0)) != int(b.get("enqueued_at_ms", 0)):
			return int(a.get("enqueued_at_ms", 0)) < int(b.get("enqueued_at_ms", 0))
		return str(a.get("project_id", "")) < str(b.get("project_id", ""))
	)
	var incoming_budget := {}
	for runtime_value in construction_projects:
		_refresh_construction_project_material_state(state, runtime_value as Dictionary, incoming_budget, true)
	for location_value in state.locations.keys():
		var location_id := str(location_value)
		var location: Dictionary = state.location_state(location_id)
		var active_industry := state.industrial_operations.filter(func(operation): return str(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == location_id and str(operation.get("status", "IDLE")) in ["RUNNING", "BLOCKED"]).size()
		var active_construction := state.construction_operations.filter(func(operation): return str(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == location_id and str(operation.get("status", "IDLE")) in ["RUNNING", "BLOCKED", "QUEUED"]).size()
		var active_shipyard := state.shipyard_queue.filter(func(runtime): return str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == location_id and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED"]).size()
		var ships_here: Array = []
		for ship in state.ships:
			if str(ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == location_id and str(ship.get("condition", "OPERATIONAL")) != "DESTROYED":
				ships_here.append(str(ship.get("instance_id", "")))
		location["fleet_presence"] = ships_here
		location["projects_summary"] = {"active_count":active_construction + active_shipyard, "construction_count":active_construction, "shipyard_count":active_shipyard}
		location["logistics_summary"] = logistics.location_summary(state, location_id)
		var local_logistics := local_logistics_profile(state, location_id)
		var active_facilities := state.location_industries(location_id).size()
		var constraint_profile := location_industry_constraint_profile(state, location_id)
		if location_id == SpaceGameState.MAIN_BASE_LOCATION_ID:
			location["power"] = civilization_power_state(state)
			location["industry_summary"] = {"status":"CONNECTED", "active_operations":active_industry, "active_facilities":active_facilities, "local_logistics":local_logistics, "constraints":constraint_profile}
		else:
			location["power"] = {"status":constraint_profile.get("power_status", "NOT_AVAILABLE"), "generation_capacity":constraint_profile.get("power_capacity", 0.0), "current_demand":constraint_profile.get("power_demand", 0.0), "available_capacity":float(constraint_profile.get("power_capacity", 0.0)) - float(constraint_profile.get("power_demand", 0.0))}
			location["industry_summary"] = {"status":"CONNECTED" if active_facilities > 0 else "NOT_AVAILABLE", "active_operations":active_industry, "active_facilities":active_facilities, "local_logistics":local_logistics, "constraints":constraint_profile}
	_refresh_megastructure_material_flow(state)


func _refresh_megastructure_material_flow(state: SpaceGameState) -> void:
	for project_value in state.megastructure_projects.values():
		var project := project_value as Dictionary
		if str(project.get("status", "")) not in ["BUILDING", "BLOCKED"]:
			continue
		var activity: Dictionary = content.activities.get(str(project.get("activity_id", "")), {})
		var location_id := str(project.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var has_incoming := false
		for cost_value in activity.get("costs", []):
			var cost := cost_value as Dictionary
			if logistics.incoming_quantity(state, location_id, str(cost.get("item", ""))) > 0:
				has_incoming = true
				break
		project["material_flow_status"] = "IN_TRANSIT" if has_incoming else ("AWAITING_SHIPMENT" if str(project.get("status", "")) == "BLOCKED" else "RECEIVING")


func known_system_ids(state: SpaceGameState) -> Array[String]:
	var result: Array[String] = []
	for location_value in state.locations.values():
		var location := location_value as Dictionary
		if str(location.get("discovery_state", LocationState.UNDISCOVERED)) != LocationState.DISCOVERED:
			continue
		var system_id := str(location.get("system_id", SpaceGameState.SYSTEM_ID))
		if not result.has(system_id):
			result.append(system_id)
	result.sort()
	return result


func system_production_overview(state: SpaceGameState, system_id: String) -> Dictionary:
	var location_ids := _system_location_ids(state, system_id)
	var rows := {}
	var operation_rows: Array[Dictionary] = []
	var running_operations := 0
	var blocked_operations := 0
	for location_id in location_ids:
		for item_value in state.location_inventory(location_id).keys():
			var item_id := str(item_value)
			if not rows.has(item_id):
				rows[item_id] = {"production_per_hour":0.0, "demand_per_hour":0.0, "stock":0, "incoming":0}
			rows[item_id]["stock"] = int(rows[item_id].get("stock", 0)) + state.item_quantity(item_id, location_id)
	for entry in _all_runtime_entries(state):
		var domain_id := str(entry.get("domain", ""))
		if domain_id not in ["mining", "industry"]:
			continue
		var runtime: Dictionary = entry.get("runtime", {})
		var activity: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
		if activity.is_empty():
			continue
		var location_id := _runtime_inventory_location_id(state, domain_id, runtime)
		if not location_ids.has(location_id):
			continue
		var status := str(runtime.get("status", "IDLE"))
		if status not in ["RUNNING", "BLOCKED"]:
			continue
		if status == "RUNNING":
			running_operations += 1
		else:
			blocked_operations += 1
		var cycles_per_hour := 0.0
		if status == "RUNNING":
			var snapshot_runtime := runtime.duplicate(true)
			var duration := effective_duration_ms(state, domain_id, activity, snapshot_runtime)
			if duration != INF and duration > 0.0:
				cycles_per_hour = 3600000.0 / duration
				var output_multiplier := 1.0 + activity_productivity_bonus(state, domain_id, activity, snapshot_runtime)
				for reward_value in activity.get("rewards", []):
					var reward := reward_value as Dictionary
					_add_flow(rows, str(reward.get("item", "")), float(reward.get("quantity", 0)) * cycles_per_hour * output_multiplier, 0.0)
				for cost_value in activity.get("costs", []):
					var cost := cost_value as Dictionary
					_add_flow(rows, str(cost.get("item", "")), 0.0, float(cost.get("quantity", 0)) * cycles_per_hour)
		operation_rows.append({
			"domain":domain_id,
			"activity_id":activity.get("id", ""),
			"location_id":location_id,
			"status":status,
			"cycles_per_hour":cycles_per_hour
		})
	# Mature extraction networks are location-owned production even though they no
	# longer occupy foreground operation records.
	for network_value in state.extraction_network_states.keys():
		var network_id := str(network_value)
		var runtime: Dictionary = state.extraction_network_states.get(network_id, {})
		var network: Dictionary = content.extraction_networks.get(network_id, {})
		if str(runtime.get("status", "")) != "RUNNING" or network.is_empty():
			continue
		var cycles_per_hour := 3600000.0 / extraction_network_cycle_duration_ms(network)
		for site_value in runtime.get("integrated_site_ids", []):
			var site: Dictionary = content.mining_sites.get(str(site_value), {})
			var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
			var location_id := str(mining_location.get("region", ""))
			if not location_ids.has(location_id):
				continue
			var item_id := str(mining_location.get("raw_material", ""))
			var quantity := int(network.get("quantity_per_site", 1)) * maxi(1, int(runtime.get("level", 1)))
			_add_flow(rows, item_id, float(quantity) * cycles_per_hour, 0.0)
	# Legacy background capacity pools are migration-only. System flow summaries
	# include only production that the runtime can actually execute.
	refresh_demand_registry(state)
	for demand_value in state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("demand_kind", "")) != "CONTINUOUS" or not location_ids.has(str(demand.get("location_id", ""))):
			continue
		_add_flow(rows, str(demand.get("product_id", "")), 0.0, float(demand.get("rate_per_hour", 0.0)))
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if not location_ids.has(str(shipment.get("destination", ""))):
			continue
		for item_value in shipment.get("cargo", {}).keys():
			var item_id := str(item_value)
			if not rows.has(item_id):
				rows[item_id] = {"production_per_hour":0.0, "demand_per_hour":0.0, "stock":0, "incoming":0}
			rows[item_id]["incoming"] = int(rows[item_id].get("incoming", 0)) + int(shipment.get("cargo", {}).get(item_id, 0))
	var flow_rows: Array[Dictionary] = []
	for item_value in rows.keys():
		var item_id := str(item_value)
		var row: Dictionary = rows[item_id]
		row["item_id"] = item_id
		row["stock"] = int(row.get("stock", 0))
		row["incoming"] = int(row.get("incoming", 0))
		row["net_per_hour"] = float(row.get("production_per_hour", 0.0)) - float(row.get("demand_per_hour", 0.0))
		flow_rows.append(row)
	flow_rows.sort_custom(func(a, b): return str(a.get("item_id", "")) < str(b.get("item_id", "")))
	operation_rows.sort_custom(func(a, b): return (str(a.get("location_id", "")) + ":" + str(a.get("activity_id", ""))) < (str(b.get("location_id", "")) + ":" + str(b.get("activity_id", ""))))
	return {
		"system_id":system_id,
		"location_ids":location_ids,
		"location_count":location_ids.size(),
		"stock_units":location_ids.reduce(func(total, location_id): return int(total) + state.total_inventory_units(str(location_id)), 0),
		"running_operations":running_operations,
		"blocked_operations":blocked_operations,
		"operations":operation_rows,
		"flows":flow_rows
	}


func system_logistics_overview(state: SpaceGameState, system_id: String) -> Dictionary:
	var location_ids := _system_location_ids(state, system_id)
	var policy_counts := {LogisticsEngineScript.MODE_SUPPLY:0, LogisticsEngineScript.MODE_DEMAND:0, LogisticsEngineScript.MODE_STORAGE:0}
	for location_id in location_ids:
		for policy_value in state.location_state(location_id).get("logistics", {}).get("policies", {}).values():
			var policy := policy_value as Dictionary
			var mode := str(policy.get("mode", LogisticsEngineScript.MODE_STORAGE))
			policy_counts[mode] = int(policy_counts.get(mode, 0)) + 1
	var route_rows: Array[Dictionary] = []
	var internal_routes := 0
	var external_routes := 0
	var freight_capacity := 0
	for route_value in content.logistics_routes.values():
		var route := route_value as Dictionary
		var origin := str(route.get("from", ""))
		var destination := str(route.get("to", ""))
		if not state.has_location(origin) or not state.has_location(destination):
			continue
		if str(state.location_state(origin).get("discovery_state", LocationState.UNDISCOVERED)) != LocationState.DISCOVERED or str(state.location_state(destination).get("discovery_state", LocationState.UNDISCOVERED)) != LocationState.DISCOVERED:
			continue
		var origin_here := location_ids.has(origin)
		var destination_here := location_ids.has(destination)
		if not origin_here and not destination_here:
			continue
		var internal := origin_here and destination_here
		internal_routes += 1 if internal else 0
		external_routes += 0 if internal else 1
		var effective_capacity: int = logistics.effective_route_capacity(state, str(route.get("id", "")))
		var effective_transit: float = logistics.effective_route_transit_time_ms(state, str(route.get("id", "")))
		freight_capacity += effective_capacity
		route_rows.append({"route_id":route.get("id", ""), "origin":origin, "destination":destination, "internal":internal, "freight_capacity":effective_capacity, "transit_time_ms":effective_transit})
	var shipment_counts := {"internal":0, "inbound":0, "outbound":0}
	var shipment_units := {"internal":0, "inbound":0, "outbound":0}
	var item_in_transit := {}
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		var origin_here := location_ids.has(str(shipment.get("origin", "")))
		var destination_here := location_ids.has(str(shipment.get("destination", "")))
		if not origin_here and not destination_here:
			continue
		var direction := "internal" if origin_here and destination_here else ("inbound" if destination_here else "outbound")
		shipment_counts[direction] = int(shipment_counts.get(direction, 0)) + 1
		for item_value in shipment.get("cargo", {}).keys():
			var item_id := str(item_value)
			var quantity := int(shipment.get("cargo", {}).get(item_id, 0))
			shipment_units[direction] = int(shipment_units.get(direction, 0)) + quantity
			item_in_transit[item_id] = int(item_in_transit.get(item_id, 0)) + quantity
	return {
		"system_id":system_id,
		"location_ids":location_ids,
		"internal_routes":internal_routes,
		"external_routes":external_routes,
		"route_count":internal_routes + external_routes,
		"freight_capacity":freight_capacity,
		"policy_counts":policy_counts,
		"policy_count":int(policy_counts.get(LogisticsEngineScript.MODE_SUPPLY, 0)) + int(policy_counts.get(LogisticsEngineScript.MODE_DEMAND, 0)) + int(policy_counts.get(LogisticsEngineScript.MODE_STORAGE, 0)),
		"shipment_counts":shipment_counts,
		"shipment_units":shipment_units,
		"item_in_transit":item_in_transit,
		"technology_profile":logistics.technology_profile(state),
		"routes":route_rows
	}


func apply_industrial_template(state: SpaceGameState, location_id: String, template_id: String) -> bool:
	if not state.has_location(location_id) or str(state.location_state(location_id).get("discovery_state", LocationState.UNDISCOVERED)) != LocationState.DISCOVERED:
		return false
	var definition: Dictionary = content.industrial_templates.get(template_id, {})
	if definition.is_empty():
		return false
	var location: Dictionary = state.location_state(location_id)
	var automation: Dictionary = location.get("automation", {})
	for item_value in automation.get("managed_policy_items", []):
		logistics.clear_policy(state, location_id, str(item_value))
	var managed_items: Array[String] = []
	for policy_value in definition.get("policies", []):
		var source := policy_value as Dictionary
		var item_id := str(source.get("item", ""))
		if not logistics.configure_policy(state, location_id, item_id, source):
			return false
		managed_items.append(item_id)
	automation["industrial_template_id"] = template_id
	automation["managed_policy_items"] = managed_items
	automation["status"] = "AUTOMATED"
	# Phase-seven templates are retained only as legacy logistics-policy presets.
	# They never authorize construction or create production capacity.
	automation["auto_expand_enabled"] = false
	automation["target_industry_level"] = maxi(1, int(definition.get("auto_expand_target", 5)))
	automation["expansion_progress_ms"] = 0.0
	automation["last_blocked_reason"] = ""
	location["automation"] = automation
	return true


func clear_industrial_template(state: SpaceGameState, location_id: String) -> bool:
	if not state.has_location(location_id):
		return false
	var location: Dictionary = state.location_state(location_id)
	var automation: Dictionary = location.get("automation", {})
	for item_value in automation.get("managed_policy_items", []):
		logistics.clear_policy(state, location_id, str(item_value))
	automation["industrial_template_id"] = ""
	automation["managed_policy_items"] = []
	automation["status"] = "MANUAL"
	automation["auto_expand_enabled"] = false
	automation["expansion_progress_ms"] = 0.0
	automation["last_blocked_reason"] = ""
	location["automation"] = automation
	return true


func configure_location_industrial_automation(state: SpaceGameState, location_id: String, enabled: bool, target_level: int) -> bool:
	return false


func _system_location_ids(state: SpaceGameState, system_id: String) -> Array[String]:
	var result: Array[String] = []
	for location_value in state.locations.values():
		var location := location_value as Dictionary
		if str(location.get("system_id", SpaceGameState.SYSTEM_ID)) == system_id and str(location.get("discovery_state", LocationState.UNDISCOVERED)) == LocationState.DISCOVERED:
			result.append(str(location.get("id", "")))
	result.sort()
	return result


func effective_duration_ms(state: SpaceGameState, domain_id: String, activity: Dictionary, runtime: Dictionary = {}) -> float:
	# Civilization capabilities, facilities and physical equipment define work
	# rates. Activity repetition never creates RPG-style skill speed.
	var level_rate := 1.0
	if domain_id == "mining":
		var power := mining_power(state, runtime.get("assigned_ship_ids", []))
		var location: Dictionary = content.mining_locations.get(str(runtime.get("location_id", activity.get("location", ""))), {})
		var grade := maxf(0.01, float(location.get("density", 1.0)))
		var potential := maxf(0.01, float(location.get("extraction_potential", power)))
		var installed_extraction := minf(power, potential)
		var method_efficiency := mining_method_efficiency(state, runtime.get("assigned_ship_ids", []))
		var hazard_profile := mining_hazard_profile(state, runtime)
		var uptime := maxf(0.05, float(hazard_profile.get("uptime", 1.0)))
		runtime["allocated_mining_power"] = power
		runtime["site_extraction_potential"] = potential
		runtime["site_grade"] = grade
		runtime["method_efficiency"] = method_efficiency
		runtime["effective_mining_power"] = installed_extraction * method_efficiency
		if power <= 0.0:
			return INF
		return maxf(10.0, float(activity.get("extraction_cost", 10.0)) / (installed_extraction * grade * method_efficiency * level_rate * uptime * simulation_speed_multiplier("mining")) * 1000.0)
	if domain_id == "industry":
		var facility_id := str(runtime.get("facility_id", activity.get("facility", "")))
		var inventory_location_id := _runtime_inventory_location_id(state, domain_id, runtime)
		var throughput := production_line_throughput(state, runtime)
		if throughput <= 0.0 or facility_id != str(activity.get("facility", "")):
			runtime["theoretical_rate"] = 0.0
			runtime["actual_rate"] = 0.0
			return INF
		var local_utilization := float(local_logistics_profile(state, inventory_location_id).get("utilization", 1.0))
		var constraint_utilization := float(location_industry_constraint_profile(state, inventory_location_id).get("throughput_multiplier", 1.0))
		if local_utilization <= 0.0 or constraint_utilization <= 0.0:
			return INF
		var mastery_speed := float(industry_mastery_profile(state, inventory_location_id, facility_id, str(activity.get("id", ""))).get("speed_multiplier", 1.0))
		var work_required := maxf(0.001, float(activity.get("work_required", 1.0)))
		var base_rate := throughput * facility_cycle_speed_multiplier(state, facility_id) * mastery_speed * simulation_speed_multiplier("manufacturing") / work_required
		runtime["theoretical_rate"] = base_rate
		runtime["actual_rate"] = base_rate * local_utilization * constraint_utilization
		return maxf(10.0, float(activity.get("work_required", 1.0)) / (throughput * facility_cycle_speed_multiplier(state, facility_id) * local_utilization * constraint_utilization * mastery_speed * simulation_speed_multiplier("manufacturing")) * 1000.0)
	if domain_id == "construction":
		var allocated := construction_project_allocated_capacity(state, runtime)
		if allocated <= 0.0:
			return INF
		# Every finite capital project is exactly 100 visible Construction Cycles.
		return maxf(2.5, float(activity.get("work_required", 1.0)) / (allocated * facility_cycle_speed_multiplier(state, "orbital_construction_yard") * simulation_speed_multiplier("construction")) * 10.0)
	var ship_ids: Array = runtime.get("assigned_ship_ids", [])
	var loadout_rate := 1.0 + loadout_efficiency(state, domain_id, ship_ids) / 100.0
	return maxf(100.0, float(activity.get("duration_ms", 1000.0)) / (level_rate * loadout_rate))


func mining_power(state: SpaceGameState, ship_ids: Array) -> float:
	var result := 0.0
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if ship.is_empty() or ship.get("condition", "") != "OPERATIONAL":
			continue
		var ship_power := 0.0
		var has_mining_equipment := false
		for module_id in state.ship_module_definition_ids(ship):
			var module: Dictionary = content.modules.get(str(module_id), {})
			if float(module.get("capabilities", {}).get("mining", 0.0)) > 0.0:
				has_mining_equipment = true
				ship_power += float(module.get("mining_power", 0))
		if has_mining_equipment:
			result += ship_power * clampf(float(ship.get("maintenance_coverage", 1.0)), 0.0, 1.0)
	return result


func production_speed_multiplier() -> float:
	return simulation_speed_multiplier("manufacturing")


func set_simulation_profile(profile_id: String) -> bool:
	if not content.simulation_profiles.get("profiles", {}).has(profile_id):
		return false
	simulation_profile_id = profile_id
	return true


func simulation_speed_multiplier(system_id: String) -> float:
	var profiles: Dictionary = content.simulation_profiles.get("profiles", {})
	var profile: Dictionary = profiles.get(simulation_profile_id, {})
	return maxf(0.01, float(profile.get(system_id, 1.0)))


func extraction_network_cycle_duration_ms(network: Dictionary) -> float:
	return maxf(0.1, float(network.get("cycle_time_ms", 1.0)) / simulation_speed_multiplier("mining"))


func mining_method_efficiency(state: SpaceGameState, ship_ids: Array) -> float:
	var result := 1.0
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if ship.is_empty():
			continue
		for module_id in state.ship_module_definition_ids(ship):
			var module: Dictionary = content.modules.get(str(module_id), {})
			if float(module.get("mining_power", 0.0)) > 0.0:
				result = maxf(result, float(module.get("extraction_method_efficiency", 1.0)))
	return result


func active_extraction_operation_count(state: SpaceGameState) -> int:
	var count := 0
	for operation in state.mining_operations:
		if operation.get("status", "IDLE") == "RUNNING" and not str(operation.get("activity_id", "")).is_empty():
			count += 1
	return count


func active_extraction_ship_ids(state: SpaceGameState) -> Array:
	var result: Array = []
	for operation in state.mining_operations:
		if str(operation.get("status", "IDLE")) != "RUNNING":
			continue
		for ship_id in operation.get("assigned_ship_ids", []):
			if not result.has(ship_id):
				result.append(ship_id)
	return result


func extraction_command_usage(state: SpaceGameState, ship_ids: Array = []) -> int:
	var selected := ship_ids if not ship_ids.is_empty() else active_extraction_ship_ids(state)
	return fleet_command_usage(state, selected)


func extraction_command_capacity(state: SpaceGameState) -> int:
	return state.extraction_command_capacity()


func extraction_technology_level(state: SpaceGameState) -> int:
	var result := 0
	for technology_id in state.technologies:
		if bool(state.technologies.get(technology_id, false)):
			result = maxi(result, int(content.technologies.get(str(technology_id), {}).get("extraction_industry_level", 0)))
	return result


func mining_site_network_eligibility(state: SpaceGameState, site_id: String, network_id: String) -> Dictionary:
	var site: Dictionary = content.mining_sites.get(site_id, {})
	var site_runtime: Dictionary = state.mining_site_states.get(site_id, {})
	var network: Dictionary = content.extraction_networks.get(network_id, {})
	var network_runtime: Dictionary = state.extraction_network_states.get(network_id, {})
	var location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
	var mastery_required := int(network.get("required_mastery_level", 1))
	var technology_required := maxi(int(network.get("required_extraction_technology_level", 1)), int(location.get("material_grade", 1)))
	return {
		"eligible":not site.is_empty()
			and not network.is_empty()
			and bool(network_runtime.get("unlocked", false))
			and network.get("site_ids", []).has(site_id)
			and int(site_runtime.get("mastery_level", 0)) >= mastery_required
			and extraction_technology_level(state) >= technology_required
			and str(site_runtime.get("integrated_network_id", "")).is_empty(),
		"mastery_required":mastery_required,
		"mastery_current":int(site_runtime.get("mastery_level", 0)),
		"technology_required":technology_required,
		"technology_current":extraction_technology_level(state),
		"material_grade":int(location.get("material_grade", 1)),
		"network_unlocked":bool(network_runtime.get("unlocked", false))
	}


func integrate_mining_site(state: SpaceGameState, site_id: String, network_id: String) -> bool:
	ensure_frontier_state(state)
	if not bool(mining_site_network_eligibility(state, site_id, network_id).get("eligible", false)):
		return false
	for operation in state.mining_operations:
		if str(operation.get("status", "IDLE")) == "RUNNING" and str(operation.get("site_id", "")) == site_id:
			_stop_runtime(state, operation, "INTEGRATED", true)
	var network_runtime: Dictionary = state.extraction_network_states[network_id]
	var integrated_ids: Array = network_runtime.get("integrated_site_ids", [])
	if not integrated_ids.has(site_id):
		integrated_ids.append(site_id)
	network_runtime["integrated_site_ids"] = integrated_ids
	network_runtime["cycle_progress"] = 0.0
	network_runtime["status"] = "RUNNING"
	var site_runtime: Dictionary = state.mining_site_states[site_id]
	site_runtime["integrated_network_id"] = network_id
	site_runtime["state"] = "INTEGRATED"
	emitted_events.append({"type":"MiningSiteIntegrated", "site_id":site_id, "network_id":network_id})
	return true


func mining_hazard_profile(state: SpaceGameState, runtime: Dictionary) -> Dictionary:
	var location: Dictionary = content.mining_locations.get(str(runtime.get("location_id", "")), {})
	var ship_ids: Array = runtime.get("assigned_ship_ids", [])
	var uptime := 1.0
	var unresolved: Array[String] = []
	var protected: Array[String] = []
	for hazard_id in location.get("hazards", []):
		var hazard: Dictionary = content.mining_hazards.get(str(hazard_id), {})
		var capability_ids: Array = [str(hazard.get("required_capability", ""))]
		capability_ids.append_array(hazard.get("alternative_capabilities", []))
		var is_protected := false
		for capability_id in capability_ids:
			if capability_value_for_ships(state, str(capability_id), ship_ids) >= 1.0:
				is_protected = true
				break
		if is_protected:
			uptime *= float(hazard.get("protected_uptime", 1.0))
			protected.append(str(hazard_id))
		else:
			uptime *= float(hazard.get("unprotected_uptime", 0.5))
			unresolved.append(str(hazard_id))
	var status := "SAFE"
	if not unresolved.is_empty():
		status = "UNPROTECTED: %s" % ", ".join(unresolved)
	elif not protected.is_empty():
		status = "PROTECTED: %s" % ", ".join(protected)
	return {
		"uptime":clampf(uptime, 0.05, 1.0),
		"unresolved":unresolved,
		"protected":protected,
		"status":status
	}


func industrial_capacity(state: SpaceGameState) -> float:
	var result := 0.0
	for facility_id in SpaceGameState.MANUFACTURING_FACILITY_IDS:
		result += facility_manufacturing_throughput(state, str(facility_id))
	return result


func allocated_industrial_capacity(state: SpaceGameState, excluding_slot: int = -1) -> float:
	var result := 0.0
	for operation in state.industrial_operations:
		if int(operation.get("slot", -1)) == excluding_slot or operation.get("status", "") != "RUNNING":
			continue
		result += production_line_throughput(state, operation)
	return result


func production_line_capacity_share(state: SpaceGameState, runtime: Dictionary) -> float:
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var facility_id := str(runtime.get("facility_id", ""))
	if facility_id.is_empty():
		return 0.0
	if str(runtime.get("control_mode", "PINNED")) == "OFF":
		return 0.0
	var candidates: Array = []
	var candidate_present := false
	for line_value in state.industrial_operations:
		var line := line_value as Dictionary
		if str(line.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != location_id or str(line.get("facility_id", "")) != facility_id:
			continue
		if str(line.get("status", "IDLE")) != "RUNNING" or str(line.get("control_mode", "PINNED")) == "OFF":
			continue
		candidates.append(line)
		if str(line.get("line_id", "")) == str(runtime.get("line_id", "")):
			candidate_present = true
	if not candidate_present:
		candidates.append(runtime)
	return 1.0 / maxf(1.0, float(candidates.size()))


func production_line_throughput(state: SpaceGameState, runtime: Dictionary) -> float:
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	return facility_manufacturing_throughput(state, str(runtime.get("facility_id", "")), location_id) * production_line_capacity_share(state, runtime)


func nominal_production_method_cycles_per_hour(state: SpaceGameState, location_id: String, activity: Dictionary) -> float:
	var facility_id := str(activity.get("facility", ""))
	var definition: Dictionary = content.facilities.get(facility_id, {})
	if definition.is_empty() or int(definition.get("manufacturing_generation", 0)) <= 0:
		return 0.0
	var work_required := maxf(0.001, float(activity.get("work_required", 1.0)))
	var base_throughput := maxf(0.0, float(definition.get("industrial_capacity", 0.0))) * maxf(0.0, float(content.industry_rules.get("level_capacity", 1.0)))
	var facility_multiplier := facility_cycle_speed_multiplier(state, facility_id) if facility_available(state, facility_id) else 1.0
	return base_throughput * facility_multiplier * simulation_speed_multiplier("manufacturing") / work_required * 3600.0


func production_dependency_graph() -> Dictionary:
	return economy_planner.production_dependency_graph()


func upstream_production_dependencies(product_id: String) -> Dictionary:
	return economy_planner.upstream_dependencies(product_id)


func current_economy_analysis(state: SpaceGameState, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> Dictionary:
	return economy_planner.current_economy_analysis(state, location_id)


func target_throughput_plan(state: SpaceGameState, targets: Dictionary, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> Dictionary:
	return economy_planner.plan_targets(state, targets, location_id)


func shortest_bottleneck_chain(state: SpaceGameState, product_id: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID, target_rate: float = 0.0) -> Dictionary:
	return economy_planner.trace_bottleneck(state, product_id, location_id, target_rate)


func facility_manufacturing_throughput(state: SpaceGameState, facility_id: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> float:
	if not facility_available(state, facility_id):
		return 0.0
	var definition: Dictionary = content.facilities.get(facility_id, {})
	if int(definition.get("manufacturing_generation", 0)) <= 0:
		return 0.0
	var local_industry := state.location_industry(location_id, facility_id)
	if local_industry.is_empty():
		return 0.0
	var level := maxf(1.0, float(local_industry.get("level", 1)))
	var per_level := maxf(0.0, float(content.industry_rules.get("level_capacity", 1.0)))
	var scale_bonus := minf(float(content.industry_rules.get("economy_of_scale_cap", 0.30)), maxf(0.0, level - 1.0) * float(content.industry_rules.get("economy_of_scale_per_level", 0.02)))
	var facility_multiplier := facility_output_multiplier(state, facility_id) if location_id == SpaceGameState.MAIN_BASE_LOCATION_ID else 1.0
	var transition_multiplier := location_specialization_transition_multiplier(state, location_id)
	var maintenance_multiplier := 0.5 + 0.5 * facility_operations_maintenance_coverage(state, location_id, facility_id)
	return maxf(0.0, float(definition.get("industrial_capacity", 0.0)) * per_level * level * (1.0 + scale_bonus) * facility_multiplier * industrial_transformation_multiplier(state, facility_id) * transition_multiplier * maintenance_multiplier)


func location_specialization_facility_multiplier(state: SpaceGameState, location_id: String, facility_id: String) -> float:
	# Kept as a compatibility entry point for schema <=32 saves. Phase seven no
	# longer permits a location profession to change Factory output.
	return 1.0


func location_specialization_transition_multiplier(state: SpaceGameState, location_id: String) -> float:
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("project_type", "")) == "INDUSTRIAL_TRANSFORMATION" and str(runtime.get("location_id", "")) == location_id and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED"]:
			var transformation_id := str(runtime.get("target_id", ""))
			return clampf(float(content.industry_rules.get("industrial_transformations", {}).get(transformation_id, {}).get("downtime_multiplier", content.industry_rules.get("specialization_transition_throughput", 0.5))), 0.0, 1.0)
	return 1.0


func industrial_transformation_multiplier(state: SpaceGameState, facility_id: String) -> float:
	var result := 1.0
	for transformation_id_value in state.adopted_industrial_transformations.keys():
		var transformation_id := str(transformation_id_value)
		if not bool(state.adopted_industrial_transformations.get(transformation_id, false)):
			continue
		result *= maxf(0.01, float(content.industry_rules.get("industrial_transformations", {}).get(transformation_id, {}).get("facility_multipliers", {}).get(facility_id, 1.0)))
	return result


func industry_expansion_costs(state: SpaceGameState, location_id: String, facility_id: String, levels: int = 1) -> Dictionary:
	if not state.has_location(location_id) or levels <= 0 or not content.facilities.has(facility_id):
		return {}
	var current_level := int(state.location_industry(location_id, facility_id).get("level", 0))
	var growth := maxf(0.0, float(content.industry_rules.get("expansion_cost_growth", 0.15)))
	var generation := maxi(1, int(content.facilities.get(facility_id, {}).get("manufacturing_generation", 1)))
	var result := {}
	for offset in levels:
		var target_level := current_level + offset + 1
		var factor := pow(1.0 + growth, maxf(0.0, float(target_level - 1))) * float(generation)
		for cost_value in content.industry_rules.get("expansion_base_costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			result[item_id] = int(result.get(item_id, 0)) + maxi(1, ceili(float(cost.get("quantity", 0)) * factor))
		# Level 2–4 expansions introduce recoverable basic machine tools. Later
		# levels progressively add structural and precision capital instead of
		# making the capital-goods plant depend on its own upgrade.
		if target_level >= 2:
			result["industrial_machine_tools"] = int(result.get("industrial_machine_tools", 0)) + maxi(1, ceili(factor * 0.5))
		if target_level >= 3:
			result["heavy_structural_section"] = int(result.get("heavy_structural_section", 0)) + maxi(1, ceili(factor * 0.35))
		if target_level >= 4:
			result["precision_actuator"] = int(result.get("precision_actuator", 0)) + maxi(1, ceili(factor * 0.25))
	return result


func industry_scale_stage(state: SpaceGameState, location_id: String, facility_id: String) -> String:
	var local_industry := state.location_industry(location_id, facility_id)
	if local_industry.is_empty():
		return "WORKSHOP"
	return str(local_industry.get("scale_stage", SpaceGameState.scale_stage_for_level(int(local_industry.get("level", 1)))))


func industry_scale_stage_definition(stage_id: String) -> Dictionary:
	return content.industry_rules.get("scale_stages", {}).get(stage_id, {})


func industry_scale_stage_rank(stage_id: String) -> int:
	var order: Array = content.industry_rules.get("scale_stage_order", ["WORKSHOP", "FACTORY", "INDUSTRIAL_COMPLEX", "AUTOMATED_DISTRICT"])
	return order.find(stage_id)


func max_production_lines(state: SpaceGameState, location_id: String, facility_id: String) -> int:
	return maxi(1, int(industry_scale_stage_definition(industry_scale_stage(state, location_id, facility_id)).get("max_production_lines", 1)))


func production_family_id(activity: Dictionary) -> String:
	var family_id := str(activity.get("product_family_id", activity.get("production_family", "")))
	if not family_id.is_empty():
		return family_id
	if not activity.get("rewards", []).is_empty():
		return str((activity.get("rewards", [])[0] as Dictionary).get("item", ""))
	return str(activity.get("id", ""))


func production_method_available_at_scale(state: SpaceGameState, location_id: String, facility_id: String, activity: Dictionary) -> bool:
	var required_stage := str(activity.get("minimum_scale_stage", "WORKSHOP"))
	return industry_scale_stage_rank(industry_scale_stage(state, location_id, facility_id)) >= industry_scale_stage_rank(required_stage)


func expand_location_industry(state: SpaceGameState, location_id: String, facility_id: String, levels: int = 1) -> bool:
	var current_level := int(state.location_industry(location_id, facility_id).get("level", 0))
	return queue_facility_expansion(state, location_id, facility_id, current_level + levels)


func facility_expansion_project_queued(state: SpaceGameState, location_id: String, facility_id: String) -> bool:
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("project_type", "")) == "FACILITY_EXPANSION" and str(runtime.get("location_id", "")) == location_id and str(runtime.get("target_id", "")) == facility_id and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			return true
	return false


func location_industry_constraint_profile(state: SpaceGameState, location_id: String) -> Dictionary:
	if not state.has_location(location_id):
		return {"throughput_multiplier":0.0, "status":"NOT_AVAILABLE"}
	var location := state.location_state(location_id)
	var industry_state: Dictionary = location.get("industry", {})
	var power_capacity := maxf(0.0, float(industry_state.get("power_capacity", 0.0)))
	var cooling_capacity := maxf(0.0, float(industry_state.get("cooling_capacity", 0.0)))
	var structural_capacity := maxf(0.0, float(industry_state.get("structural_capacity", 0.0)))
	var structural_used := 0.0
	for local_industry_value in state.location_industries(location_id).values():
		var local_industry := local_industry_value as Dictionary
		structural_used += float(local_industry.get("level", 1)) * float(content.industry_rules.get("structural_capacity_per_level", 1.0))
	var power_demand := 0.0
	var cooling_demand := 0.0
	for operation_value in state.industrial_operations:
		var operation := operation_value as Dictionary
		if str(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != location_id or str(operation.get("status", "")) != "RUNNING":
			continue
		var facility_id := str(operation.get("facility_id", ""))
		var definition: Dictionary = content.facilities.get(facility_id, {})
		var level := maxi(1, int(state.location_industry(location_id, facility_id).get("level", 1)))
		var expertise := industry_mastery_profile(state, location_id, facility_id, str(operation.get("activity_id", "")))
		var activity: Dictionary = content.activities.get(str(operation.get("activity_id", "")), {})
		var energy_multiplier := float(expertise.get("energy_multiplier", 1.0)) * maxf(0.01, float(activity.get("production_energy_multiplier", 1.0)))
		var capacity_share := production_line_capacity_share(state, operation)
		var per_level_power := maxf(0.0, float(definition.get("baseline_power_demand", 1.0)) + float(definition.get("advanced_power_demand", 0.0)))
		power_demand += per_level_power * float(level) * energy_multiplier * capacity_share
		if str(location.get("type", LocationState.NATURAL)) == LocationState.ARTIFICIAL:
			cooling_demand += float(level) * float(content.industry_rules.get("cooling_demand_per_level", 2.0)) * maxf(0.01, float(activity.get("production_cooling_multiplier", 1.0))) * capacity_share
	var power_coverage := 1.0 if power_demand <= 0.000001 else clampf(power_capacity / power_demand, 0.0, 1.0)
	var artificial := str(location.get("type", LocationState.NATURAL)) == LocationState.ARTIFICIAL
	var cooling_coverage := 1.0 if not artificial or cooling_demand <= 0.000001 else clampf(cooling_capacity / cooling_demand, 0.0, 1.0)
	var multiplier := power_coverage * cooling_coverage
	return {
		"power_capacity":power_capacity,
		"power_demand":power_demand,
		"power_coverage":power_coverage,
		"power_status":"HEALTHY" if power_coverage >= 0.999999 else "POWER_LIMITED",
		"cooling_required":artificial,
		"cooling_capacity":cooling_capacity,
		"cooling_demand":cooling_demand,
		"cooling_coverage":cooling_coverage,
		"structural_capacity":structural_capacity,
		"structural_used":structural_used,
		"throughput_multiplier":multiplier,
		"status":"CONSTRAINED" if multiplier < 0.999999 else "HEALTHY"
	}


func industry_mastery_profile(state: SpaceGameState, location_id: String, facility_id: String, activity_id: String) -> Dictionary:
	var local_industry := state.location_industry(location_id, facility_id)
	var mastery: Dictionary = local_industry.get("product_mastery", {}).get(activity_id, {})
	var mastery_level := maxi(0, int(mastery.get("level", 0)))
	var expertise_level := maxi(0, int(local_industry.get("expertise_level", 0)))
	var speed_bonus := float(mastery_level) * float(content.industry_rules.get("speed_bonus_per_mastery_level", 0.005)) + float(expertise_level) * float(content.industry_rules.get("speed_bonus_per_expertise_level", 0.005))
	var material_efficiency := minf(0.25, float(mastery_level) * float(content.industry_rules.get("material_efficiency_per_mastery_level", 0.0025)))
	var energy_efficiency := minf(0.25, float(expertise_level) * float(content.industry_rules.get("energy_efficiency_per_expertise_level", 0.005)))
	var waste_multiplier := 1.0 - minf(0.50, float(mastery_level) * 0.01)
	return {"mastery_level":mastery_level, "expertise_level":expertise_level, "speed_multiplier":1.0 + speed_bonus, "material_efficiency":material_efficiency, "energy_multiplier":1.0 - energy_efficiency, "waste_multiplier":waste_multiplier}


func local_logistics_profile(state: SpaceGameState, location_id: String) -> Dictionary:
	if not state.has_location(location_id):
		return {"capacity":0.0, "required":0.0, "utilization":0.0, "status":"NOT_AVAILABLE"}
	var capacity := maxf(0.0, float(state.location_state(location_id).get("logistics", {}).get("local_throughput_capacity", LogisticsEngineScript.DEFAULT_LOCAL_THROUGHPUT)))
	var required := 0.0
	for operation_value in state.industrial_operations:
		var operation := operation_value as Dictionary
		if str(operation.get("status", "")) != "RUNNING" or _runtime_inventory_location_id(state, "industry", operation) != location_id:
			continue
		var activity: Dictionary = content.activities.get(str(operation.get("activity_id", "")), {})
		var facility_id := str(operation.get("facility_id", activity.get("facility", "")))
		if activity.is_empty() or facility_id != str(activity.get("facility", "")):
			continue
		var work_required := maxf(0.001, float(activity.get("work_required", 1.0)))
		var cycles_per_second := production_line_throughput(state, operation) * facility_cycle_speed_multiplier(state, facility_id) * simulation_speed_multiplier("manufacturing") / work_required
		var movement_per_cycle := 0.0
		for cost in activity.get("costs", []):
			movement_per_cycle += maxf(0.0, float(cost.get("quantity", 0)))
		var output_multiplier := 1.0 + facility_productivity_bonus(state, facility_id)
		for reward in activity.get("rewards", []):
			movement_per_cycle += maxf(0.0, float(reward.get("quantity", 0))) * output_multiplier
		for waste in activity.get("waste", []):
			movement_per_cycle += maxf(0.0, float(waste.get("quantity", 0)))
		required += cycles_per_second * movement_per_cycle
	var utilization := 1.0 if required <= 0.000001 else clampf(capacity / required, 0.0, 1.0)
	return {
		"capacity":capacity,
		"required":required,
		"utilization":utilization,
		"status":"AVAILABLE" if required <= 0.000001 else ("CONSTRAINED" if utilization < 0.999999 else "HEALTHY")
	}


func is_construction_activity(activity: Dictionary) -> bool:
	if bool(activity.get("construction_project", false)):
		return true
	if bool(activity.get("repeat", true)):
		return false
	for effect in activity.get("effects", []):
		if str(effect.get("type", "")) in ["unlock_facility", "upgrade_facility", "complete_megastructure"]:
			return true
	return false


func construction_activity_for_runtime(runtime: Dictionary) -> Dictionary:
	var activity: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
	if not activity.is_empty():
		return activity
	var definition: Dictionary = runtime.get("project_definition", {})
	return definition if is_construction_activity(definition) else {}


func construction_project_type_for_activity(activity: Dictionary) -> String:
	if not megastructure_for_activity(activity).is_empty():
		return "MEGASTRUCTURE"
	for effect_value in activity.get("effects", []):
		if str((effect_value as Dictionary).get("type", "")) in ["unlock_extraction_network", "upgrade_extraction_network"]:
			return "EXTRACTION_NETWORK"
	for effect_value in activity.get("effects", []):
		var effect := effect_value as Dictionary
		match str(effect.get("type", "")):
			"unlock_extraction_network": return "EXTRACTION_NETWORK"
			"upgrade_facility":
				var facility_id := str(effect.get("facility", ""))
				if facility_id in ["basic_power_grid", "fission_reactor", "energy_array"]:
					return "POWER_UPGRADE"
				if facility_id in ["orbital_construction_yard", "orbital_starport"]:
					return "SCALE_STAGE_UPGRADE"
				return "FACILITY_EXPANSION"
			"unlock_facility": return "FACILITY_BUILD"
	return "FACILITY_BUILD"


func initialize_construction_project(state: SpaceGameState, runtime: Dictionary, activity: Dictionary, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID, priority: int = 50) -> void:
	var project_id := "CONSTRUCTION-%06d" % state.next_construction_project_serial
	state.next_construction_project_serial += 1
	var project_type := construction_project_type_for_activity(activity)
	var target_id := str(activity.get("id", ""))
	var start_level := 0
	var target_level := 0
	for effect_value in activity.get("effects", []):
		var effect := effect_value as Dictionary
		if str(effect.get("type", "")) in ["unlock_facility", "upgrade_facility"]:
			target_id = str(effect.get("facility", target_id))
			start_level = int(state.facilities.get(target_id, {}).get("level", 0))
			target_level = start_level + int(effect.get("levels", 1))
			break
	runtime.merge({
		"project_id":project_id,
		"project_type":project_type,
		"target_id":target_id,
		"priority":clampi(priority, 0, 100),
		"enqueued_at_ms":int(state.total_elapsed_ms),
		"location_id":location_id,
		"start_level":start_level,
		"target_level":target_level,
		"total_work":maxf(1.0, float(activity.get("work_required", 100.0))),
		"completed_work":0.0,
		"material_plan":_cost_entries_to_dictionary(activity.get("costs", [])),
		"delivered_materials":{},
		"in_transit_materials":{},
		"consumed":{},
		"project_definition":{},
		"cancellation_result":{},
		"blocker":{}
	}, true)


func queue_facility_expansion(state: SpaceGameState, location_id: String, facility_id: String, target_level: int, priority: int = 50) -> bool:
	if not state.has_location(location_id) or not content.facilities.has(facility_id) or not facility_available(state, facility_id):
		return false
	var current_level := int(state.location_industry(location_id, facility_id).get("level", 0))
	if target_level <= current_level or target_level > 100 or construction_queue_size(state) >= construction_queue_capacity(state):
		return false
	var current_stage := industry_scale_stage(state, location_id, facility_id)
	var stage_max_level := int(industry_scale_stage_definition(current_stage).get("max_level", 4))
	if target_level > stage_max_level:
		return false
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("project_type", "")) == "FACILITY_EXPANSION" and str(runtime.get("location_id", "")) == location_id and str(runtime.get("target_id", "")) == facility_id and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			return false
	var levels := target_level - current_level
	var costs := industry_expansion_costs(state, location_id, facility_id, levels)
	var generation := maxi(1, int(content.facilities.get(facility_id, {}).get("manufacturing_generation", 1)))
	var definition := {
		"id":"facility_expansion:%s:%s:%d" % [location_id, facility_id, target_level],
		"domain":"industry", "name":"Expand %s to Industry Level %d" % [facility_id, target_level],
		"construction_project":true, "repeat":false,
		"work_required":maxf(20.0, float(levels * generation * 20)),
		"costs":_dictionary_to_item_entries(costs), "effects":[], "requirements":[]
	}
	return _queue_dynamic_construction_project(state, definition, "FACILITY_EXPANSION", location_id, facility_id, current_level, target_level, priority)


func queue_scale_stage_upgrade(state: SpaceGameState, location_id: String, facility_id: String, priority: int = 50) -> bool:
	if not state.has_location(location_id) or not content.facilities.has(facility_id) or not facility_available(state, facility_id) or construction_queue_size(state) >= construction_queue_capacity(state):
		return false
	var current_stage := industry_scale_stage(state, location_id, facility_id)
	var current_definition := industry_scale_stage_definition(current_stage)
	var next_stage := str(current_definition.get("next_stage", ""))
	if next_stage.is_empty() or int(state.location_industry(location_id, facility_id).get("level", 0)) < int(current_definition.get("max_level", 4)):
		return false
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("project_type", "")) in ["FACILITY_EXPANSION", "SCALE_STAGE_UPGRADE"] and str(runtime.get("location_id", "")) == location_id and str(runtime.get("target_id", "")) == facility_id and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			return false
	var next_definition := industry_scale_stage_definition(next_stage)
	var target_level := int(next_definition.get("min_level", int(current_definition.get("max_level", 4)) + 1))
	var stage_costs := industry_expansion_costs(state, location_id, facility_id, target_level - int(state.location_industry(location_id, facility_id).get("level", 1)))
	for cost_value in next_definition.get("upgrade_costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		stage_costs[item_id] = int(stage_costs.get(item_id, 0)) + int(cost.get("quantity", 0))
	var definition := {
		"id":"scale_stage:%s:%s:%s" % [location_id, facility_id, next_stage.to_lower()],
		"domain":"industry", "name":"Upgrade %s to %s" % [facility_id, next_stage.capitalize()],
		"construction_project":true, "repeat":false,
		"work_required":maxf(20.0, float(next_definition.get("upgrade_work", 50.0))),
		"costs":_dictionary_to_item_entries(stage_costs), "effects":[], "requirements":[]
	}
	var queued := _queue_dynamic_construction_project(state, definition, "SCALE_STAGE_UPGRADE", location_id, facility_id, int(state.location_industry(location_id, facility_id).get("level", 1)), target_level, priority)
	if queued:
		var runtime := state.construction_operations.filter(func(value): return str((value as Dictionary).get("project_type", "")) == "SCALE_STAGE_UPGRADE" and str((value as Dictionary).get("location_id", "")) == location_id and str((value as Dictionary).get("target_id", "")) == facility_id)[0] as Dictionary
		runtime["project_definition"]["target_scale_stage"] = next_stage
	return queued


func queue_location_specialization(state: SpaceGameState, location_id: String, specialization_id: String, priority: int = 50) -> bool:
	# Location professions are retired. Industrial geography emerges from real
	# resources, Factory investment, methods, energy, maintenance and logistics.
	return false


func queue_industrial_transformation(state: SpaceGameState, transformation_id: String, priority: int = 50) -> bool:
	var transformations: Dictionary = content.industry_rules.get("industrial_transformations", {})
	var transformation: Dictionary = transformations.get(transformation_id, {})
	if transformation.is_empty() or not bool(state.unlocked_industrial_transformations.get(transformation_id, false)) or bool(state.adopted_industrial_transformations.get(transformation_id, false)) or construction_queue_size(state) >= construction_queue_capacity(state):
		return false
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("project_type", "")) == "INDUSTRIAL_TRANSFORMATION" and str(runtime.get("target_id", "")) == transformation_id and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			return false
	var definition := {
		"id":"industrial_transformation:%s" % transformation_id,
		"domain":"industry", "name":transformation.get("name", transformation_id.capitalize()),
		"description":transformation.get("description", ""), "construction_project":true, "repeat":false,
		"work_required":maxf(20.0, float(transformation.get("work_required", 80.0))),
		"costs":transformation.get("costs", []).duplicate(true), "effects":[], "requirements":[]
	}
	return _queue_dynamic_construction_project(state, definition, "INDUSTRIAL_TRANSFORMATION", SpaceGameState.MAIN_BASE_LOCATION_ID, transformation_id, 0, 1, priority)


func queue_location_capacity_upgrade(state: SpaceGameState, location_id: String, project_type: String, target_value: int, priority: int = 50) -> bool:
	var field_map := {
		"POWER_UPGRADE":["industry", "power_capacity"],
		"COOLING_UPGRADE":["industry", "cooling_capacity"],
		"STRUCTURE_UPGRADE":["industry", "structural_capacity"],
		"STORAGE_UPGRADE":["logistics", "storage_capacities", "BULK"],
		"BULK_STORAGE_UPGRADE":["logistics", "storage_capacities", "BULK"],
		"COMPONENT_STORAGE_UPGRADE":["logistics", "storage_capacities", "COMPONENT"],
		"FLUID_STORAGE_UPGRADE":["logistics", "storage_capacities", "FLUID"],
		"SPECIAL_STORAGE_UPGRADE":["logistics", "storage_capacities", "SPECIAL"],
		"LOGISTICS_HUB_UPGRADE":["logistics", "hub_throughput"]
	}
	if not state.has_location(location_id) or not field_map.has(project_type) or construction_queue_size(state) >= construction_queue_capacity(state):
		return false
	var path: Array = field_map[project_type]
	var current_value := int(state.location_state(location_id).get(str(path[0]), {}).get(str(path[1]), {}).get(str(path[2]), 0)) if path.size() >= 3 else int(state.location_state(location_id).get(str(path[0]), {}).get(str(path[1]), 0))
	if target_value <= current_value:
		return false
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("project_type", "")) == project_type and str(runtime.get("location_id", "")) == location_id and str(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			return false
	var rules: Dictionary = content.industry_rules.get("capacity_upgrade_projects", {}).get(project_type, {})
	if rules.is_empty():
		return false
	var increment := maxi(1, int(rules.get("increment", 1)))
	var steps := maxi(1, ceili(float(target_value - current_value) / float(increment)))
	var costs := {}
	for cost_value in rules.get("costs", []):
		var cost := cost_value as Dictionary
		costs[str(cost.get("item", ""))] = int(cost.get("quantity", 0)) * steps
	var definition := {
		"id":"capacity_upgrade:%s:%s:%d" % [location_id, project_type.to_lower(), target_value],
		"domain":"industry", "name":"%s at %s" % [project_type.capitalize(), location_id],
		"construction_project":true, "repeat":false,
		"work_required":maxf(20.0, float(rules.get("work_required", 20)) * steps),
		"costs":_dictionary_to_item_entries(costs), "effects":[], "requirements":[]
	}
	return _queue_dynamic_construction_project(state, definition, project_type, location_id, str(path[2]) if path.size() >= 3 else str(path[1]), current_value, target_value, priority)


func _queue_dynamic_construction_project(state: SpaceGameState, definition: Dictionary, project_type: String, location_id: String, target_id: String, start_level: int, target_level: int, priority: int) -> bool:
	if project_type not in CONSTRUCTION_PROJECT_TYPES:
		return false
	var slot := construction_queue_size(state)
	if slot < 0 or slot >= state.construction_operations.size():
		return false
	var runtime: Dictionary = state.construction_operations[slot]
	runtime.clear()
	runtime.merge(SpaceGameState._empty_construction_project(slot), true)
	runtime.merge({"activity_id":definition.get("id", ""), "status":"RUNNING"}, true)
	initialize_construction_project(state, runtime, definition, location_id, priority)
	# initialize_construction_project also serves content-backed projects and resets
	# dynamic-only fields. Attach the generated definition afterwards so save/load,
	# validation and completion can resolve this project without a content activity.
	runtime["project_definition"] = definition.duplicate(true)
	runtime["project_type"] = project_type
	runtime["target_id"] = target_id
	runtime["start_level"] = start_level
	runtime["target_level"] = target_level
	normalize_construction_queue(state)
	return true


func construction_queue_capacity(state: SpaceGameState) -> int:
	return SpaceGameState.MAX_CONSTRUCTION_OPERATIONS if facility_available(state, "orbital_construction_yard") else 0


func construction_engineering_level(state: SpaceGameState) -> int:
	if not facility_available(state, "orbital_construction_yard"):
		return 0
	return maxi(1, int(state.facilities["orbital_construction_yard"].get("level", 1)))


func construction_engineering_required(activity: Dictionary) -> int:
	return maxi(1, int(activity.get("construction_engineering_required", content.construction_engineering_requirements.get(str(activity.get("id", "")), 1))))


func construction_capacity(state: SpaceGameState) -> float:
	var facility_id := "orbital_construction_yard"
	if not facility_available(state, facility_id):
		return 0.0
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var capacity := maxf(0.0, float(definition.get("construction_capacity", 0.0)))
	var modules: Dictionary = definition.get("upgrade_modules", {})
	for module_value in state.facilities[facility_id].get("installed_modules", []):
		capacity += maxf(0.0, float(modules.get(str(module_value), {}).get("construction_capacity", 0.0)))
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		if str(ship.get("status", "")) != "DOCKED" or str(ship.get("condition", "")) != "OPERATIONAL" or str(ship.get("maintenance_state", "ACTIVE")) == "MOTHBALLED":
			continue
		capacity += maxf(0.0, ship_loadout_capability_value(state, ship, "construction_support")) * 8.0
	return capacity * facility_output_multiplier(state, facility_id)


func construction_active_project_limit(state: SpaceGameState) -> int:
	return mini(construction_queue_capacity(state), maxi(1, construction_engineering_level(state)))


func location_construction_capacity(state: SpaceGameState, location_id: String) -> float:
	if not state.has_location(location_id):
		return 0.0
	return maxf(0.0, float(state.location_state(location_id).get("construction", {}).get("capacity", 0.0)))


func megastructure_for_activity(activity: Dictionary) -> Dictionary:
	var activity_id := str(activity.get("id", ""))
	for definition_value in content.megastructures.values():
		var definition := definition_value as Dictionary
		if str(definition.get("construction_activity", "")) == activity_id:
			return definition
	return {}


func begin_megastructure_project(state: SpaceGameState, runtime: Dictionary, activity: Dictionary) -> void:
	var definition := megastructure_for_activity(activity)
	if definition.is_empty():
		return
	var project_id := str(definition.get("id", ""))
	runtime["megastructure_id"] = project_id
	state.megastructure_projects[project_id] = {
		"id":project_id,
		"activity_id":activity.get("id", ""),
		"location_id":runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID),
		"progress_percent":0,
		"stage_index":0,
		"stage_name":_megastructure_stage(definition, 0).get("name", "PLANNED"),
		"delivered_materials":{},
		"status":"BUILDING",
		"material_flow_status":"RECEIVING"
	}


func cancel_megastructure_project(state: SpaceGameState, runtime: Dictionary) -> void:
	var project_id := str(runtime.get("megastructure_id", ""))
	if project_id.is_empty() or not state.megastructure_projects.has(project_id):
		return
	state.megastructure_projects[project_id]["status"] = "CANCELLED"
	state.megastructure_projects[project_id]["material_flow_status"] = "STOPPED"


func cancel_construction_project(state: SpaceGameState, runtime: Dictionary) -> Dictionary:
	cancel_megastructure_project(state, runtime)
	_refresh_construction_project_material_state(state, runtime)
	var result := {
		"consumed_lost":runtime.get("consumed", {}).duplicate(true),
		"delivered_released":runtime.get("reserved_costs", {}).duplicate(true),
		"in_transit_destination":str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	}
	runtime["cancellation_result"] = result.duplicate(true)
	_record_construction_history(state, runtime, "CANCELLED", result)
	var slot := int(runtime.get("slot", 0))
	runtime.clear()
	runtime.merge(SpaceGameState._empty_construction_project(slot), true)
	normalize_construction_queue(state)
	return result


func _sync_megastructure_project(state: SpaceGameState, runtime: Dictionary, activity: Dictionary, status: String = "BUILDING") -> void:
	var definition := megastructure_for_activity(activity)
	if definition.is_empty():
		return
	var project_id := str(definition.get("id", ""))
	if not state.megastructure_projects.has(project_id):
		begin_megastructure_project(state, runtime, activity)
	var project: Dictionary = state.megastructure_projects[project_id]
	var percent := clampi(int(runtime.get("project_cycles_completed", 0)), 0, 100)
	var previous_stage := int(project.get("stage_index", 0))
	var stage_index := 0
	var stages: Array = definition.get("stages", [])
	for index in stages.size():
		if int((stages[index] as Dictionary).get("percent", 0)) <= percent:
			stage_index = index
	var stage := _megastructure_stage(definition, stage_index)
	project["progress_percent"] = percent
	project["stage_index"] = stage_index
	project["stage_name"] = str(stage.get("name", "BUILDING"))
	project["delivered_materials"] = runtime.get("consumed", {}).duplicate(true)
	project["status"] = "COMPLETE" if percent >= 100 else status
	project["material_flow_status"] = "COMPLETE" if percent >= 100 else ("AWAITING_SHIPMENT" if status == "BLOCKED" else "RECEIVING")
	if stage_index > previous_stage:
		emitted_events.append({"type":"MegastructureStageChanged", "megastructure_id":project_id, "stage_index":stage_index, "stage_name":project.get("stage_name", ""), "progress_percent":percent})


func _megastructure_stage(definition: Dictionary, index: int) -> Dictionary:
	var stages: Array = definition.get("stages", [])
	if stages.is_empty():
		return {"percent":0, "name":"PLANNED"}
	return stages[clampi(index, 0, stages.size() - 1)]


func facility_cycle_speed_multiplier(state: SpaceGameState, facility_id: String) -> float:
	if facility_id.is_empty() or not state.facilities.has(facility_id):
		return 1.0
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var result := 1.0 + float(definition.get("cycle_speed_bonus", 0.0))
	for module_value in state.facilities[facility_id].get("installed_modules", []):
		result += float(definition.get("upgrade_modules", {}).get(str(module_value), {}).get("cycle_speed_bonus", 0.0))
	for module in installed_manufacturing_module_definitions(state, facility_id):
		var power_factor := float(civilization_power_state(state).get("facility_advanced_coverage", {}).get(facility_id, 1.0)) if float(module.get("advanced_power_demand", 0.0)) > 0.0 else 1.0
		result += float(module.get("cycle_speed_bonus", 0.0)) * power_factor
	return maxf(0.2, result)


func facility_productivity_bonus(state: SpaceGameState, facility_id: String) -> float:
	if facility_id.is_empty() or not state.facilities.has(facility_id):
		return 0.0
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var result := maxf(0.0, float(definition.get("productivity_bonus", 0.0)))
	for module_value in state.facilities[facility_id].get("installed_modules", []):
		result += maxf(0.0, float(definition.get("upgrade_modules", {}).get(str(module_value), {}).get("productivity_bonus", 0.0)))
	for module in installed_manufacturing_module_definitions(state, facility_id):
		var power_factor := float(civilization_power_state(state).get("facility_advanced_coverage", {}).get(facility_id, 1.0)) if float(module.get("advanced_power_demand", 0.0)) > 0.0 else 1.0
		result += maxf(0.0, float(module.get("productivity_bonus", 0.0))) * power_factor
	return result


func activity_productivity_bonus(state: SpaceGameState, domain_id: String, activity: Dictionary, runtime: Dictionary) -> float:
	if domain_id == "industry":
		return facility_productivity_bonus(state, str(activity.get("facility", "")))
	if domain_id == "mining":
		var result := 0.0
		var ship_ids: Array = runtime.get("assigned_ship_ids", [])
		for ship_id in ship_ids:
			var ship := state.ship_by_id(str(ship_id))
			for module_id in state.ship_module_definition_ids(ship):
				var module: Dictionary = content.modules.get(str(module_id), {})
				if str(module.get("domain", "")) == domain_id:
					result += maxf(0.0, float(module.get("productivity_bonus", 0.0)))
		return result
	return 0.0


func shipyard_engineering_level(state: SpaceGameState) -> int:
	if not facility_available(state, "orbital_starport"):
		return 0
	return maxi(1, int(state.facilities["orbital_starport"].get("level", 1)))


func shipyard_cycle_duration_ms(state: SpaceGameState, plan: Dictionary) -> float:
	var capacity := maxf(0.01, float(content.facilities.get("orbital_starport", {}).get("shipbuilding_capacity", 1.0)))
	var speed := facility_cycle_speed_multiplier(state, "orbital_starport")
	var power := facility_output_multiplier(state, "orbital_starport")
	return maxf(2.5, float(plan.get("cycle_time_ms", 1000.0)) / (capacity * speed * power * simulation_speed_multiplier("shipyard")))


func shipyard_active_power_demand(state: SpaceGameState) -> float:
	var total := 0.0
	for runtime in state.shipyard_queue:
		if runtime.get("status", "") == "RUNNING":
			total += maxf(0.0, float(content.ship_construction_projects.get(str(runtime.get("plan_id", "")), {}).get("active_power_demand", 0.0)))
	return total


func ship_service_capacity(state: SpaceGameState) -> int:
	if not facility_available(state, "orbital_starport"):
		return 0
	var capacity := maxi(1, int(state.facilities.get("orbital_starport", {}).get("level", 1)))
	if facility_available(state, "repair_dock"):
		capacity += maxi(1, int(state.facilities.get("repair_dock", {}).get("level", 1)))
	return capacity


func ship_reactivation_duration_ms(state: SpaceGameState, ship: Dictionary) -> float:
	var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
	var command_cost := maxf(1.0, float(blueprint.get("command_cost", 1.0)))
	return maxf(1000.0, command_cost * float(content.fleet_rules.get("reactivation_ms_per_command", 2000.0)) / facility_cycle_speed_multiplier(state, "orbital_starport"))


func ship_reactivation_costs(ship: Dictionary) -> Dictionary:
	var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
	var command_cost := maxf(1.0, float(blueprint.get("command_cost", 1.0)))
	var material_item := str(content.fleet_rules.get("maintenance_item", "repair_material"))
	var material_quantity := maxi(1, int(ceil(command_cost * float(content.fleet_rules.get("reactivation_material_per_command", 0.25)) + float(ship.get("maintenance_debt", 0.0)))))
	return {material_item:material_quantity}


func ship_scrap_recovery(ship: Dictionary) -> Dictionary:
	var invested := {}
	var blueprint_id := str(ship.get("blueprint_id", ""))
	var construction_plan := {}
	for plan_value in content.ship_construction_projects.values():
		var candidate := plan_value as Dictionary
		if str(candidate.get("ship_id", "")) == blueprint_id:
			construction_plan = candidate
			break
	if construction_plan.is_empty():
		var blueprint: Dictionary = content.ships.get(blueprint_id, {})
		invested["scrap_metal"] = maxi(2, int(ceil(float(blueprint.get("command_cost", 1)))))
		invested["electronics"] = maxi(1, int(ceil(float(blueprint.get("command_cost", 1)) / 8.0)))
		var module_totals := content.module_bom_totals(state_module_definitions_without_special(ship))
		for item_id in module_totals:
			invested[str(item_id)] = int(invested.get(str(item_id), 0)) + int(module_totals[item_id])
	else:
		invested = ship_construction_material_totals(construction_plan)
		for cost_value in construction_plan.get("fixed_costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			invested[item_id] = int(invested.get(item_id, 0)) + int(cost.get("quantity", 0))
	var recovery := {}
	var fraction := clampf(float(content.fleet_rules.get("scrap_recovery_fraction", 0.4)), 0.0, 1.0)
	for item_id in invested:
		var quantity := int(floor(float(invested[item_id]) * fraction))
		if quantity > 0:
			recovery[str(item_id)] = quantity
	return recovery


func state_module_definitions_without_special(ship: Dictionary) -> Array:
	var result: Array = []
	for module_value in ship.get("modules", []):
		var stored_value := str(module_value)
		var definition_id := stored_value
		if content.modules.has(definition_id) and not bool(content.modules[definition_id].get("special_equipment", false)):
			result.append(definition_id)
	return result


func normalize_refit_projects(state: SpaceGameState) -> void:
	for runtime_value in state.refit_projects:
		var runtime := runtime_value as Dictionary
		if int(runtime.get("loadout_semantics_version", 0)) >= 1:
			continue
		var ship := state.ship_by_id(str(runtime.get("ship_id", "")))
		if ship.is_empty():
			runtime["status"] = "FAILED"
			runtime["loadout_semantics_version"] = 1
			continue
		var original_modules: Array = runtime.get("original_modules", ship.get("modules", [])).duplicate()
		var special_by_definition := {}
		var all_special_ids: Array = []
		for stored_value in original_modules:
			var stored_id := str(stored_value)
			var definition_id := state.equipment_definition_id(stored_id)
			if definition_id.is_empty():
				continue
			if not special_by_definition.has(definition_id):
				special_by_definition[definition_id] = []
			special_by_definition[definition_id].append(stored_id)
			all_special_ids.append(stored_id)
		var legacy_special_ids: Array = []
		legacy_special_ids.append_array(runtime.get("reserved_equipment_ids", []))
		legacy_special_ids.append_array(runtime.get("incoming_equipment_ids", []))
		legacy_special_ids.append_array(runtime.get("outgoing_equipment_ids", []))
		for equipment_value in legacy_special_ids:
			var equipment_id := str(equipment_value)
			if not state.equipment_instances.has(equipment_id) or equipment_id in all_special_ids:
				continue
			var definition_id := state.equipment_definition_id(equipment_id)
			if not special_by_definition.has(definition_id):
				special_by_definition[definition_id] = []
			special_by_definition[definition_id].append(equipment_id)
			all_special_ids.append(equipment_id)
		var desired_modules: Array = []
		var reserved_equipment: Array = []
		for definition_value in runtime.get("desired_definitions", []):
			var definition_id := str(definition_value)
			if bool(content.modules.get(definition_id, {}).get("special_equipment", false)):
				var pool: Array = special_by_definition.get(definition_id, [])
				if pool.is_empty():
					runtime["status"] = "FAILED"
					continue
				var equipment_id := str(pool.pop_front())
				special_by_definition[definition_id] = pool
				desired_modules.append(equipment_id)
				reserved_equipment.append(equipment_id)
				state.equipment_instances[equipment_id]["status"] = "RESERVED_REFIT"
				state.equipment_instances[equipment_id]["installed_ship_id"] = ""
				continue
			desired_modules.append(definition_id)
		var outgoing_equipment: Array = []
		for equipment_id_value in all_special_ids:
			var equipment_id := str(equipment_id_value)
			if equipment_id in reserved_equipment:
				continue
			outgoing_equipment.append(equipment_id)
			state.equipment_instances[equipment_id]["status"] = "RESERVED_REFIT"
			state.equipment_instances[equipment_id]["installed_ship_id"] = ""
		ship["modules"] = []
		runtime["original_modules"] = original_modules
		runtime["desired_modules"] = desired_modules
		runtime["reserved_equipment_ids"] = reserved_equipment
		runtime["outgoing_equipment_ids"] = outgoing_equipment
		# Legacy projects keep their already committed value; new projects always
		# consume this full BOM at command time.
		if runtime.get("consumed_bom", null) is not Dictionary or runtime.get("consumed_bom", {}).is_empty():
			runtime["consumed_bom"] = loadout_fabrication_costs(runtime.get("desired_definitions", []))
		var fabrication_time_ms := loadout_fabrication_time_ms(runtime.get("desired_definitions", []))
		var installation_time_ms := loadout_installation_time_ms(runtime.get("desired_definitions", []))
		runtime["phase_mode"] = "COMBINED_FABRICATION_INSTALLATION"
		runtime["fabrication_time_ms"] = float(runtime.get("fabrication_time_ms", fabrication_time_ms))
		runtime["installation_time_ms"] = float(runtime.get("installation_time_ms", installation_time_ms))
		runtime["cycle_time_ms"] = float(runtime.get("cycle_time_ms", (fabrication_time_ms + installation_time_ms) / 100.0))
		runtime["loadout_semantics_version"] = 1
		for obsolete_field in ["incoming_module_escrow", "outgoing_module_escrow", "incoming_equipment_ids", "module_asset_semantics_version"]:
			runtime.erase(obsolete_field)


func normalize_shipyard_queue(state: SpaceGameState) -> void:
	var normalized: Array = []
	for value in state.shipyard_queue:
		var runtime: Dictionary = value
		var plan_id := str(runtime.get("plan_id", ""))
		var plan: Dictionary = content.ship_construction_projects.get(plan_id, {})
		if plan.is_empty():
			continue
		runtime["completed_segments"] = clampi(int(runtime.get("completed_segments", 0)), 0, 100)
		runtime["quantity_total"] = clampi(int(runtime.get("quantity_total", 1)), 1, 100)
		runtime["quantity_completed"] = clampi(int(runtime.get("quantity_completed", 0)), 0, int(runtime.get("quantity_total", 1)))
		runtime["quantity_remaining"] = clampi(int(runtime.get("quantity_remaining", int(runtime.get("quantity_total", 1)) - int(runtime.get("quantity_completed", 0)))), 0, int(runtime.get("quantity_total", 1)))
		if int(runtime.get("quantity_remaining", 0)) <= 0:
			continue
		runtime["paid_cycles"] = maxi(0, int(runtime.get("paid_cycles", 0)))
		runtime["cycle_progress"] = clampf(float(runtime.get("cycle_progress", 0.0)), 0.0, 0.999999)
		# Unique ships are finite capital projects. Legacy Productivity progress
		# must never create free construction segments.
		runtime["productivity_progress"] = 0.0
		runtime["consumed"] = runtime.get("consumed", {}).duplicate(true)
		runtime["reserved_costs"] = {}
		runtime["status"] = str(runtime.get("status", "RUNNING"))
		runtime["blocked_reason"] = str(runtime.get("blocked_reason", ""))
		runtime.erase("module_escrow")
		runtime.erase("module_escrow_initialized")
		runtime.erase("module_asset_semantics_version")
		if shipyard_engineering_level(state) < int(plan.get("engineering_required", 1)):
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "ENGINEERING"
			normalized.append(runtime)
			continue
		normalized.append(runtime)
	state.shipyard_queue = normalized
	for runtime in state.shipyard_queue:
		runtime["reserved_costs"] = {}
	for runtime in state.shipyard_queue:
		var plan: Dictionary = content.ship_construction_projects.get(str(runtime.get("plan_id", "")), {})
		if shipyard_engineering_level(state) < int(plan.get("engineering_required", 1)):
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "ENGINEERING"
			continue
		var required := _shipyard_next_cycle_costs(runtime, plan)
		var missing := ""
		for item_id in required:
			if state.available_item_quantity_for_shipyard(str(item_id), str(runtime.get("project_id", ""))) < int(required[item_id]):
				missing = str(item_id)
				break
		runtime["reserved_costs"] = required
		if not missing.is_empty():
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "RESOURCES:%s" % missing
		else:
			runtime["status"] = "RUNNING"
			runtime["blocked_reason"] = ""


func _shipyard_next_cycle_costs(runtime: Dictionary, plan: Dictionary) -> Dictionary:
	var result := {}
	var next_paid := int(runtime.get("paid_cycles", 0)) + 1
	var consumed: Dictionary = runtime.get("consumed", {})
	if int(runtime.get("paid_cycles", 0)) == 0:
		for cost in plan.get("fixed_costs", []):
			result[str(cost.get("item", ""))] = int(cost.get("quantity", 0))
	var construction_totals := ship_construction_material_totals(plan)
	for item_value in construction_totals:
		var item_id := str(item_value)
		var total := int(construction_totals.get(item_id, 0))
		var target := int(floor(float(total) * float(next_paid) / 100.0 + 0.000001))
		var due := maxi(0, target - int(consumed.get(item_id, 0)))
		if due > 0:
			result[item_id] = int(result.get(item_id, 0)) + due
	return result


func ship_construction_material_totals(plan: Dictionary) -> Dictionary:
	var result := {}
	for cost_value in plan.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		result[item_id] = int(result.get(item_id, 0)) + int(cost.get("quantity", 0))
	# Starting modules describe the first Loadout, not stocked components. Their
	# raw fabrication BOM is part of the fitted hull construction cost.
	var module_totals := content.module_bom_totals(plan.get("starting_modules", []))
	for item_id_value in module_totals.keys():
		var item_id := str(item_id_value)
		result[item_id] = int(result.get(item_id, 0)) + int(module_totals[item_id])
	return result


func shipyard_queue_index(state: SpaceGameState, plan_id: String) -> int:
	for index in state.shipyard_queue.size():
		if str(state.shipyard_queue[index].get("plan_id", "")) == plan_id:
			return index
	return -1


func active_construction_count(state: SpaceGameState) -> int:
	var result := 0
	for runtime in state.construction_operations:
		if runtime.get("status", "IDLE") == "RUNNING" and not str(runtime.get("activity_id", "")).is_empty():
			result += 1
	return result


func construction_queue_size(state: SpaceGameState) -> int:
	var count := 0
	for runtime in state.construction_operations:
		if runtime.get("status", "IDLE") in ["RUNNING", "BLOCKED", "QUEUED"] and not str(runtime.get("activity_id", "")).is_empty():
			count += 1
	return count


func construction_allocated_capacity(state: SpaceGameState) -> float:
	return construction_capacity(state) if active_construction_count(state) > 0 else 0.0


func construction_project_allocated_capacity(state: SpaceGameState, runtime: Dictionary) -> float:
	if str(runtime.get("status", "")) != "RUNNING":
		return 0.0
	var active_count := active_construction_count(state)
	if active_count <= 0:
		return 0.0
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var local_active_count := 0
	for project_value in state.construction_operations:
		var project := project_value as Dictionary
		if str(project.get("status", "")) == "RUNNING" and str(project.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == location_id:
			local_active_count += 1
	var civilization_share := construction_capacity(state) / float(active_count)
	var location_share := location_construction_capacity(state, location_id) / float(maxi(1, local_active_count))
	return minf(civilization_share, location_share)


func rebalance_construction_progress(state: SpaceGameState, previous_active_count: int, previous_capacity: float) -> void:
	# Construction stores normalized Cycle progress, so changing capacity or module
	# configuration never rescales or discards the partially completed Cycle.
	pass


func normalize_construction_queue(state: SpaceGameState) -> void:
	var queued: Array = []
	for runtime in state.construction_operations:
		if runtime.get("status", "IDLE") in ["RUNNING", "BLOCKED", "QUEUED"] and not str(runtime.get("activity_id", "")).is_empty():
			queued.append(runtime.duplicate(true))
	queued.sort_custom(func(a, b):
		if int(a.get("priority", 50)) != int(b.get("priority", 50)):
			return int(a.get("priority", 50)) > int(b.get("priority", 50))
		if int(a.get("enqueued_at_ms", 0)) != int(b.get("enqueued_at_ms", 0)):
			return int(a.get("enqueued_at_ms", 0)) < int(b.get("enqueued_at_ms", 0))
		return str(a.get("project_id", "")) < str(b.get("project_id", ""))
	)
	for index in state.construction_operations.size():
		var runtime: Dictionary = state.construction_operations[index]
		runtime.clear()
		runtime.merge(SpaceGameState._empty_construction_project(index), true)
	var active_limit := construction_active_project_limit(state)
	for index in mini(queued.size(), state.construction_operations.size()):
		var restored: Dictionary = queued[index]
		restored["slot"] = index
		restored["domain"] = "construction"
		restored["productivity_progress"] = 0.0
		restored["status"] = ("BLOCKED" if str(restored.get("status", "")) == "BLOCKED" else "RUNNING") if index < active_limit else "QUEUED"
		state.construction_operations[index] = restored
	for location_value in state.locations.values():
		var location := location_value as Dictionary
		location.get("construction", {})["active_project_ids"] = []
	for runtime in state.construction_operations:
		if str(runtime.get("status", "")) not in ["RUNNING", "BLOCKED"]:
			continue
		var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		if state.has_location(location_id):
			state.location_state(location_id).get("construction", {}).get("active_project_ids", []).append(str(runtime.get("project_id", "")))


func loadout_efficiency(state: SpaceGameState, domain_id: String, ship_ids: Array = []) -> float:
	var result := 0.0
	var filter_ids := ship_ids
	for ship in state.ships:
		if not filter_ids.is_empty() and not filter_ids.has(str(ship.get("instance_id", ""))):
			continue
		if ship.get("condition", "OPERATIONAL") != "OPERATIONAL":
			continue
		for module_id in state.ship_module_definition_ids(ship):
			var module: Dictionary = content.modules.get(str(module_id), {})
			if module.get("domain", "") == domain_id:
				result += float(module.get("efficiency_bonus", 0))
	return result


func capability_value(state: SpaceGameState, capability_id: String) -> float:
	match capability_id:
		"research_capacity":
			return research_capacity(state)
		"computing_capacity":
			return research_capacity(state) * 50.0
		"power_capacity":
			var power := civilization_power_state(state)
			return float(power.get("baseline_generation", 0.0)) + float(power.get("advanced_generation", 0.0))
		"advanced_power_capacity":
			return float(civilization_power_state(state).get("advanced_generation", 0.0))
		"cooling_capacity":
			return float(location_industry_constraint_profile(state, SpaceGameState.MAIN_BASE_LOCATION_ID).get("cooling_capacity", 0.0))
		"logistics_throughput":
			return float(local_logistics_profile(state, SpaceGameState.MAIN_BASE_LOCATION_ID).get("capacity", 0.0))
		"precision_manufacturing":
			return facility_process_capability_value(state, "orbital_foundry", "precision_mechanics") + facility_process_capability_value(state, "assembly_yard", "microfabrication")
	var ids: Array = []
	for ship in state.ships:
		if ship.get("condition", "OPERATIONAL") == "OPERATIONAL":
			ids.append(str(ship.get("instance_id", "")))
	return capability_value_for_ships(state, capability_id, ids)


func capability_value_for_ships(state: SpaceGameState, capability_id: String, ship_ids: Array) -> float:
	var result := 0.0
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if ship.is_empty() or ship.get("condition", "") != "OPERATIONAL":
			continue
		result += ship_loadout_capability_value(state, ship, capability_id)
	return result


func ship_loadout_capability_value(state: SpaceGameState, ship: Dictionary, capability_id: String) -> float:
	var result := 0.0
	for module_id in state.ship_module_definition_ids(ship):
		result += float(content.modules.get(str(module_id), {}).get("capabilities", {}).get(capability_id, 0.0))
	return result


func fleet_command_usage(state: SpaceGameState, ship_ids: Array) -> int:
	var total := 0
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
		total += maxi(0, int(blueprint.get("command_cost", 10)))
	return total


func fleet_command_capacity(state: SpaceGameState, fleet_id: String = "expedition") -> int:
	var base := int(state.fleet_logistics_runtime(fleet_id).get("command_capacity", 100))
	if facility_available(state, "command_array"):
		base += 50 * int(state.facilities["command_array"].get("level", 1))
	return base


func fleet_cargo_capacity(state: SpaceGameState, ship_ids: Array) -> int:
	var total := 0
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
		total += maxi(0, int(blueprint.get("cargo_capacity", 0)))
		for module_id in state.ship_module_definition_ids(ship):
			total += maxi(0, int(content.modules.get(str(module_id), {}).get("cargo_capacity", 0)))
	return total


func fleet_cargo_used(state: SpaceGameState, fleet_id: String = "expedition") -> int:
	var runtime := state.fleet_logistics_runtime(fleet_id)
	var total := 0
	for quantity in runtime.get("supplies", {}).values():
		total += maxi(0, int(quantity))
	for quantity in runtime.get("recovered", {}).values():
		total += maxi(0, int(quantity))
	return total


func fleet_endurance_ms(state: SpaceGameState, ship_ids: Array, fleet_id: String = "expedition") -> float:
	var endurance := INF
	var ammunition_per_second := 0.0
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
		var interval := float(blueprint.get("base_stats", {}).get("attack_interval_ms", 3000.0))
		for module_id in state.ship_module_definition_ids(ship):
			var module: Dictionary = content.modules.get(str(module_id), {})
			if str(module.get("ammunition_item", "")) == "kinetic_munitions":
				interval = float(module.get("combat_stats", {}).get("attack_interval_ms", interval))
				ammunition_per_second += float(module.get("ammunition_per_attack", 1)) * 1000.0 / maxf(1.0, interval)
	if ammunition_per_second > 0.0:
		endurance = minf(endurance, float(state.fleet_supply_quantity("kinetic_munitions", fleet_id)) / ammunition_per_second * 1000.0)
	var fuel := state.fleet_supply_quantity("chemical_propellant", fleet_id)
	if fuel > 0:
		endurance = minf(endurance, float(fuel) * 30.0 * 60.0 * 1000.0)
	return 0.0 if endurance == INF else endurance


func requirement_met(state: SpaceGameState, requirement: Dictionary) -> bool:
	return requirements.evaluate(state, requirement)


func activity_available(state: SpaceGameState, activity: Dictionary) -> bool:
	# Module recipes are internal Loadout-fabrication BOM definitions. They never
	# create an inventory item or occupy a normal Production Line.
	if content.is_module_bom_activity(activity):
		return false
	if not bool(activity.get("repeat", true)) and int(state.completed_activities.get(str(activity.get("id", "")), 0)) > 0:
		return false
	if is_construction_activity(activity) and construction_engineering_level(state) < construction_engineering_required(activity):
		return false
	for requirement in activity.get("requirements", []):
		if not requirement_met(state, requirement):
			return false
	if str(activity.get("domain", "")) == "industry" and bool(activity.get("repeat", true)):
		if not industry_recipe_capabilities_met(state, activity):
			return false
	return true


func module_design_available(state: SpaceGameState, module_id: String) -> bool:
	var module: Dictionary = content.modules.get(module_id, {})
	if module.is_empty():
		return false
	if bool(module.get("special_equipment", false)):
		return true
	var recipe := content.module_bom_activity(module_id)
	if recipe.is_empty():
		return true
	if not definition_revealed(state, recipe):
		return false
	for requirement_value in recipe.get("requirements", []):
		if not requirement_met(state, requirement_value as Dictionary):
			return false
	var facility_id := str(recipe.get("facility", ""))
	return facility_available(state, facility_id) and industry_recipe_capabilities_met(state, recipe)


func loadout_semantics_validation_errors(state: SpaceGameState) -> Array[String]:
	var errors: Array[String] = []
	for location_value in state.locations.values():
		var inventory: Dictionary = (location_value as Dictionary).get("inventory", {})
		for module_value in content.modules.keys():
			var module_id := str(module_value)
			if not bool(content.modules[module_id].get("special_equipment", false)) and int(inventory.get(module_id, 0)) != 0:
				errors.append("ordinary Loadout definition %s leaked into Location inventory" % module_id)
	for shipment_value in state.logistics_network.get("shipments", []):
		var cargo: Dictionary = (shipment_value as Dictionary).get("cargo", {})
		for module_value in content.modules.keys():
			var module_id := str(module_value)
			if not bool(content.modules[module_id].get("special_equipment", false)) and int(cargo.get(module_id, 0)) != 0:
				errors.append("ordinary Loadout definition %s leaked into Shipment cargo" % module_id)
	for runtime_value in state.shipyard_queue + state.refit_projects:
		var runtime := runtime_value as Dictionary
		for obsolete_field in ["module_escrow", "incoming_module_escrow", "outgoing_module_escrow"]:
			if not runtime.get(obsolete_field, {}).is_empty():
				errors.append("ordinary Loadout definitions leaked into project field %s" % obsolete_field)
	var special_owners := {}
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		for stored_value in ship.get("modules", []):
			var equipment_id := str(stored_value)
			if not state.equipment_instances.has(equipment_id):
				continue
			if special_owners.has(equipment_id):
				errors.append("special equipment %s is installed on both %s and %s" % [equipment_id, special_owners[equipment_id], ship.get("instance_id", "")])
			else:
				special_owners[equipment_id] = str(ship.get("instance_id", ""))
	for equipment_id_value in state.equipment_instances.keys():
		var equipment_id := str(equipment_id_value)
		var equipment: Dictionary = state.equipment_instances[equipment_id]
		if str(equipment.get("status", "")) == "INSTALLED" and not special_owners.has(equipment_id):
			errors.append("special equipment %s claims an installed owner but occupies no ship" % equipment_id)
	return errors


func loadout_fabrication_costs(desired_module_ids: Array) -> Dictionary:
	return content.module_bom_totals(desired_module_ids)


func loadout_fabrication_time_ms(desired_module_ids: Array) -> float:
	var total := 0.0
	for module_value in desired_module_ids:
		var module_id := str(module_value)
		var definition: Dictionary = content.modules.get(module_id, {})
		if definition.is_empty() or bool(definition.get("special_equipment", false)):
			continue
		var recipe := content.module_bom_activity(module_id)
		total += float(recipe.get("duration_ms", 8000.0)) if not recipe.is_empty() else 8000.0
	return maxf(1000.0, total)


func loadout_installation_time_ms(desired_module_ids: Array) -> float:
	var size_weight := {"S":1.0, "M":1.6, "L":2.5, "XL":4.0}
	var total := 20000.0
	for module_value in desired_module_ids:
		var definition: Dictionary = content.modules.get(str(module_value), {})
		if definition.is_empty():
			continue
		total += 5000.0 * float(size_weight.get(str(definition.get("size", "S")), 1.0))
	return total


# Compatibility name for older callers. The corrected contract intentionally
# ignores the current configuration and charges the complete desired Loadout.
func refit_bom_delta(_current_module_ids: Array, desired_module_ids: Array) -> Dictionary:
	return loadout_fabrication_costs(desired_module_ids)


func _is_combat_activity(activity: Dictionary) -> bool:
	return str(activity.get("domain", "")) == "expedition" and str(activity.get("encounter_type", "")) in ["COMBAT", "BOSS"]


func _ensure_repeat_combat_state(state: SpaceGameState) -> void:
	var runtime: Dictionary = state.active_expedition
	if runtime.get("status", "") != "RUNNING" or not str(runtime.get("route_id", "")).is_empty():
		return
	var activity: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
	if not _is_combat_activity(activity) or not runtime.get("combat_state", {}).is_empty():
		return
	runtime["combat_state"] = combat.begin(state, runtime.get("assigned_ship_ids", []), str(activity.get("enemy", "")))
	state.combat_log = runtime["combat_state"].get("log", []).duplicate(true)
	emitted_events.append({"type":"CombatStarted", "activity_id":activity.get("id", ""), "enemy_id":activity.get("enemy", "")})


func definition_revealed(state: SpaceGameState, definition: Dictionary) -> bool:
	if definition.has("reveal_requirements"):
		for requirement in definition.get("reveal_requirements", []):
			if not requirement_met(state, requirement):
				return false
		return true
	# Compatibility for older content packs: Technology requirements historically
	# doubled as reveal rules, so they must remain hidden unless explicitly changed.
	return technology_requirements_met(state, definition)


func technology_requirements_met(state: SpaceGameState, definition: Dictionary) -> bool:
	for requirement in definition.get("requirements", []):
		if not _technology_requirement_met(state, requirement):
			return false
	return true


func _technology_requirement_met(state: SpaceGameState, requirement: Dictionary) -> bool:
	var operator := str(requirement.get("op", ""))
	if operator == "AND":
		for child in requirement.get("children", []):
			if not _technology_requirement_met(state, child):
				return false
		return true
	if operator == "OR":
		# If any branch already satisfies the OR, the definition is legitimately
		# revealed. Otherwise an unresolved Technology branch keeps it hidden.
		return requirement_met(state, requirement) or not _requirement_contains_technology(requirement)
	if str(requirement.get("type", "")) == "technology":
		return requirement_met(state, requirement)
	return true


func _requirement_contains_technology(requirement: Dictionary) -> bool:
	if str(requirement.get("type", "")) == "technology":
		return true
	for child in requirement.get("children", []):
		if _requirement_contains_technology(child):
			return true
	return false


func build_requirements_met(state: SpaceGameState, activity: Dictionary, ship_ids: Array) -> bool:
	for requirement in activity.get("build_requirements", []):
		if not _requirement_met_for_ships(state, requirement, ship_ids):
			return false
	return true


func costs_available(state: SpaceGameState, activity: Dictionary) -> bool:
	for cost in activity.get("costs", []):
		if state.available_item_quantity(str(cost.get("item", ""))) < int(cost.get("quantity", 0)):
			return false
	return true


func research_project_available(state: SpaceGameState, project: Dictionary, route_id: String = "") -> bool:
	var project_id := str(project.get("id", ""))
	if bool(state.completed_projects.get(project_id, false)):
		# Engineering routes are not permanent exclusions. A completed major program
		# can be reopened as a supplemental route, but already completed routes cannot.
		if route_id.is_empty() or research_route(project, route_id).is_empty() or bool(state.completed_research_routes.get(project_id, {}).get(route_id, false)):
			return false
	var ship_plan_id := str(project.get("grants_ship_plan", ""))
	if not ship_plan_id.is_empty() and not bool(state.completed_projects.get(project_id, false)):
		var plan: Dictionary = content.ship_construction_projects.get(ship_plan_id, {})
		if bool(state.unlocked_ship_plans.get(ship_plan_id, false)) or state.owns_ship_model(str(plan.get("ship_id", ""))):
			return false
	for requirement in project.get("requirements", []):
		if not requirement_met(state, requirement):
			return false
	return true


func research_route(project: Dictionary, route_id: String) -> Dictionary:
	for route_value in project.get("routes", []):
		var route := route_value as Dictionary
		if str(route.get("id", "")) == route_id:
			return route
	return {}


func default_research_route_id(project: Dictionary) -> String:
	var routes: Array = project.get("routes", [])
	return str((routes[0] as Dictionary).get("id", "")) if not routes.is_empty() else ""


func research_stages(project: Dictionary) -> Array:
	var defined: Array = project.get("stages", [])
	if not defined.is_empty():
		return defined
	return [{
		"id":"research", "name":"Integrated Research", "kind":"THEORY",
		"work_required":maxf(1.0, float(project.get("duration_ms", 1.0))),
		"capacity_required":1.0, "costs":project.get("costs", []).duplicate(true),
		"requirements":[], "operating_conditions":[], "completion_effects":[]
	}]


func research_stage_definition(state: SpaceGameState, project: Dictionary, stage_index: int, route_id: String = "") -> Dictionary:
	var stages := research_stages(project)
	if stage_index < 0 or stage_index >= stages.size():
		return {}
	var stage: Dictionary = (stages[stage_index] as Dictionary).duplicate(true)
	var route := research_route(project, route_id)
	stage["work_required"] = maxf(0.0, float(stage.get("work_required", stage.get("duration_ms", 1.0))) * maxf(0.01, float(route.get("work_multiplier", 1.0))) * research_knowledge_work_multiplier(state, project))
	for override_value in route.get("stage_overrides", []):
		var override := override_value as Dictionary
		if str(override.get("id", "")) == str(stage.get("id", "")):
			stage.merge(override, true)
			break
	return stage


func research_knowledge_work_multiplier(state: SpaceGameState, project: Dictionary) -> float:
	var reduction := 0.0
	for affinity_value in project.get("domain_affinities", []):
		var affinity := affinity_value as Dictionary
		var level := int(state.technology_domains.get(str(affinity.get("domain", "")), {}).get("level", 1))
		reduction += maxf(0.0, float(level - 1)) * float(affinity.get("weight", 1.0)) * 0.08
	# Spillovers are deliberately project-specific engineering reuse, not a
	# civilization-wide research-speed currency.
	for spillover_id_value in project.get("spillover_work_reductions", {}).keys():
		var spillover_id := str(spillover_id_value)
		if bool(state.technology_spillovers.get(spillover_id, false)):
			reduction += maxf(0.0, float(project.get("spillover_work_reductions", {}).get(spillover_id, 0.0)))
	return clampf(1.0 - reduction, 0.55, 1.0)


func research_capacity(state: SpaceGameState) -> float:
	if not facility_available(state, "research_complex"):
		return 0.0
	var level := maxf(1.0, float(state.facilities.get("research_complex", {}).get("level", 1)))
	return level * facility_output_multiplier(state, "research_complex")


func facility_available(state: SpaceGameState, facility_id: String) -> bool:
	return state.facilities.get(facility_id, {}).get("status", "") == "ACTIVE"


func industry_runtime_for_facility(state: SpaceGameState, facility_id: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> Dictionary:
	for runtime in state.industrial_operations:
		if str(runtime.get("facility_id", "")) == facility_id and str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == location_id:
			return runtime
	return {}


func industry_facility_busy(state: SpaceGameState, facility_id: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	return state.production_lines_for(location_id, facility_id).any(func(runtime): return str((runtime as Dictionary).get("status", "IDLE")) in ["RUNNING", "BLOCKED"])


func facility_process_capability_value(state: SpaceGameState, facility_id: String, capability_id: String) -> float:
	if not facility_available(state, facility_id):
		return 0.0
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var result := float(definition.get("base_capabilities", definition.get("capabilities", {})).get(capability_id, 0.0))
	for module_value in state.facilities[facility_id].get("installed_process_modules", []):
		var module: Dictionary = content.process_modules.get(str(module_value), {})
		result += float(module.get("grants_capabilities", {}).get(capability_id, 0.0))
	return result


func industry_recipe_capabilities_met(state: SpaceGameState, activity: Dictionary) -> bool:
	var facility_id := str(activity.get("facility", ""))
	if not facility_available(state, facility_id):
		return false
	for capability_value in activity.get("required_facility_capabilities", []):
		if facility_process_capability_value(state, facility_id, str(capability_value)) < 1.0:
			return false
	return true


func production_device_id(state: SpaceGameState, activity: Dictionary) -> String:
	var facility_id := str(activity.get("facility", ""))
	if not facility_available(state, facility_id):
		return ""
	var required: Array = activity.get("required_facility_capabilities", [])
	if required.is_empty():
		return ""
	var facility: Dictionary = content.facilities.get(facility_id, {})
	var base_capabilities: Dictionary = facility.get("base_capabilities", facility.get("capabilities", {}))
	if required.all(func(capability): return float(base_capabilities.get(str(capability), 0.0)) >= 1.0):
		return "FACILITY_DEVICE:%s" % facility_id
	for module_value in state.facilities.get(facility_id, {}).get("installed_process_modules", []):
		var module_id := str(module_value)
		var process_module: Dictionary = content.process_modules.get(module_id, {})
		if required.all(func(capability): return float(process_module.get("grants_capabilities", {}).get(str(capability), 0.0)) >= 1.0 or float(base_capabilities.get(str(capability), 0.0)) >= 1.0):
			return "PROCESS_DEVICE:%s" % module_id
	return ""


func manufacturing_module_definition(module_kind: String, module_id: String) -> Dictionary:
	return content.process_modules.get(module_id, {}) if module_kind == "process" else content.universal_industry_plugins.get(module_id, {})


func manufacturing_module_revealed(state: SpaceGameState, definition: Dictionary) -> bool:
	return definition_revealed(state, definition)


func manufacturing_module_available(state: SpaceGameState, facility_id: String, module_id: String, module_kind: String) -> bool:
	if not facility_available(state, facility_id):
		return false
	var definition := manufacturing_module_definition(module_kind, module_id)
	var facility: Dictionary = content.facilities.get(facility_id, {})
	if definition.is_empty() or int(facility.get("manufacturing_generation", 0)) <= 0:
		return false
	var runtime: Dictionary = state.facilities[facility_id]
	var field := "installed_process_modules" if module_kind == "process" else "installed_plugins"
	var slot_field := "process_module_slots" if module_kind == "process" else "plugin_slots"
	var installed: Array = runtime.get(field, [])
	if installed.has(module_id) or installed.size() >= int(facility.get(slot_field, 0)):
		return false
	if module_kind == "process" and not definition.get("compatible_facilities", []).has(facility_id):
		return false
	if module_kind == "plugin" and not definition.get("compatible_generations", []).has(int(facility.get("manufacturing_generation", 0))):
		return false
	for requirement in definition.get("requirements", []):
		if not requirement_met(state, requirement):
			return false
	if int(state.manufacturing_module_inventory.get(module_id, 0)) > 0:
		return true
	if int(state.manufacturing_modules_built.get(module_id, 0)) >= int(definition.get("max_instances", 1)):
		return false
	for cost in definition.get("costs", []):
		if state.available_item_quantity(str(cost.get("item", ""))) < int(cost.get("quantity", 0)):
			return false
	return true


func installed_manufacturing_module_definitions(state: SpaceGameState, facility_id: String) -> Array:
	var result: Array = []
	if not state.facilities.has(facility_id):
		return result
	for module_id in state.facilities[facility_id].get("installed_process_modules", []):
		var process_module: Dictionary = content.process_modules.get(str(module_id), {})
		if not process_module.is_empty():
			result.append(process_module)
	for module_id in state.facilities[facility_id].get("installed_plugins", []):
		var plugin: Dictionary = content.universal_industry_plugins.get(str(module_id), {})
		if not plugin.is_empty():
			result.append(plugin)
	return result


func facility_baseline_power_demand(state: SpaceGameState, facility_id: String) -> float:
	var runtime: Dictionary = state.facilities.get(facility_id, {})
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var level := maxf(1.0, float(runtime.get("level", 1)))
	var demand := float(definition.get("baseline_power_demand", definition.get("power_demand", 0.0))) + float(definition.get("baseline_power_demand_per_level", definition.get("power_demand_per_level", 0.0))) * (level - 1.0)
	var upgrade_definitions: Dictionary = definition.get("upgrade_modules", {})
	for module_value in runtime.get("installed_modules", []):
		var module_id := str(module_value)
		demand += float(upgrade_definitions.get(module_id, {}).get("baseline_power_demand", 0.0))
	for module in installed_manufacturing_module_definitions(state, facility_id):
		demand += float(module.get("baseline_power_demand", 0.0))
	return maxf(0.0, demand)


func facility_advanced_power_demand(state: SpaceGameState, facility_id: String) -> float:
	var runtime: Dictionary = state.facilities.get(facility_id, {})
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var level := maxf(1.0, float(runtime.get("level", 1)))
	var demand := float(definition.get("advanced_power_demand", 0.0)) + float(definition.get("advanced_power_demand_per_level", 0.0)) * (level - 1.0)
	var upgrade_definitions: Dictionary = definition.get("upgrade_modules", {})
	for module_value in runtime.get("installed_modules", []):
		demand += float(upgrade_definitions.get(str(module_value), {}).get("advanced_power_demand", 0.0))
	for module in installed_manufacturing_module_definitions(state, facility_id):
		demand += float(module.get("advanced_power_demand", 0.0))
	if facility_id == "orbital_starport":
		demand += shipyard_active_power_demand(state)
	return maxf(0.0, demand)


func facility_baseline_power_generation(state: SpaceGameState, facility_id: String) -> float:
	var runtime: Dictionary = state.facilities.get(facility_id, {})
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var level := maxf(1.0, float(runtime.get("level", 1)))
	return maxf(0.0, float(definition.get("baseline_power_generation", definition.get("power_generation", 0.0))) + float(definition.get("baseline_power_generation_per_level", definition.get("power_generation_per_level", 0.0))) * (level - 1.0))


func facility_advanced_power_generation(state: SpaceGameState, facility_id: String) -> float:
	var runtime: Dictionary = state.facilities.get(facility_id, {})
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var level := maxf(1.0, float(runtime.get("level", 1)))
	var nominal := maxf(0.0, float(definition.get("advanced_power_generation", 0.0)) + float(definition.get("advanced_power_generation_per_level", 0.0)) * (level - 1.0))
	if nominal <= 0.0:
		return 0.0
	var coverage := clampf(float(state.energy_system.get("maintenance_coverage", {}).get(facility_id, 1.0)), 0.0, 1.0)
	var emergency := clampf(float(definition.get("emergency_output", 0.25)), 0.0, 1.0)
	return nominal * (emergency + (1.0 - emergency) * coverage)


func facility_power_demand(state: SpaceGameState, facility_id: String) -> float:
	return facility_baseline_power_demand(state, facility_id) + facility_advanced_power_demand(state, facility_id)


func facility_power_generation(state: SpaceGameState, facility_id: String) -> float:
	return facility_baseline_power_generation(state, facility_id) + facility_advanced_power_generation(state, facility_id)


func facility_module_available(state: SpaceGameState, facility_id: String, module_id: String) -> bool:
	if not facility_available(state, facility_id):
		return false
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var module: Dictionary = definition.get("upgrade_modules", {}).get(module_id, {})
	if module.is_empty():
		return false
	var installed: Array = state.facilities.get(facility_id, {}).get("installed_modules", [])
	if installed.has(module_id) or installed.size() >= int(definition.get("module_slots", 0)):
		return false
	for requirement in module.get("requirements", []):
		if not requirement_met(state, requirement):
			return false
	for cost in module.get("costs", []):
		if state.available_item_quantity(str(cost.get("item", ""))) < int(cost.get("quantity", 0)):
			return false
	return true


func facility_module_power_preview(state: SpaceGameState, facility_id: String, module_id: String) -> Dictionary:
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var module: Dictionary = definition.get("upgrade_modules", {}).get(module_id, {})
	if module.is_empty() or not facility_available(state, facility_id):
		return {}
	var current_power := civilization_power_state(state)
	var construction_before := construction_capacity(state)
	var cycle_speed_before := facility_cycle_speed_multiplier(state, facility_id)
	var projected_state := SpaceGameState.from_dictionary(state.to_dictionary(), content.domains.keys(), content.regions)
	if not projected_state.facilities.get(facility_id, {}).get("installed_modules", []).has(module_id):
		projected_state.install_facility_module(facility_id, module_id)
	var projected_power := civilization_power_state(projected_state)
	return {
		"baseline_demand_before":float(current_power.get("baseline_demand", 0.0)),
		"baseline_demand_after":float(projected_power.get("baseline_demand", 0.0)),
		"baseline_reserve_after":float(projected_power.get("baseline_reserve", 0.0)),
		"advanced_demand_before":float(current_power.get("advanced_demand", 0.0)),
		"advanced_demand_after":float(projected_power.get("advanced_demand", 0.0)),
		"advanced_coverage_after":float(projected_power.get("advanced_coverage", 1.0)),
		"facility_output_before":facility_output_multiplier(state, facility_id),
		"facility_output_after":facility_output_multiplier(projected_state, facility_id),
		"cycle_speed_before":cycle_speed_before,
		"cycle_speed_after":facility_cycle_speed_multiplier(projected_state, facility_id),
		"construction_capacity_before":construction_before,
		"construction_capacity_after":construction_capacity(projected_state),
		"construction_cycle_rate_before":construction_before * cycle_speed_before,
		"construction_cycle_rate_after":construction_capacity(projected_state) * facility_cycle_speed_multiplier(projected_state, facility_id)
	}


func facility_level_power_preview(state: SpaceGameState, facility_id: String, target_level: int) -> Dictionary:
	if not content.facilities.has(facility_id):
		return {}
	var current_power := civilization_power_state(state)
	var projected_state := SpaceGameState.from_dictionary(state.to_dictionary(), content.domains.keys(), content.regions)
	var projected_runtime: Dictionary = projected_state.facilities.get(facility_id, {}).duplicate(true)
	projected_runtime["status"] = "ACTIVE"
	projected_runtime["level"] = maxi(1, target_level)
	projected_state.facilities[facility_id] = projected_runtime
	var projected_power := civilization_power_state(projected_state)
	return {
		"baseline_generation_before":float(current_power.get("baseline_generation", 0.0)),
		"baseline_generation_after":float(projected_power.get("baseline_generation", 0.0)),
		"baseline_demand_before":float(current_power.get("baseline_demand", 0.0)),
		"baseline_demand_after":float(projected_power.get("baseline_demand", 0.0)),
		"baseline_reserve_after":float(projected_power.get("baseline_reserve", 0.0)),
		"advanced_generation_before":float(current_power.get("advanced_generation", 0.0)),
		"advanced_generation_after":float(projected_power.get("advanced_generation", 0.0)),
		"advanced_demand_before":float(current_power.get("advanced_demand", 0.0)),
		"advanced_demand_after":float(projected_power.get("advanced_demand", 0.0)),
		"advanced_coverage_after":float(projected_power.get("advanced_coverage", 1.0))
	}


func civilization_power_state(state: SpaceGameState) -> Dictionary:
	var baseline_generation := 0.0
	var baseline_demand := 0.0
	var advanced_generation := 0.0
	var advanced_demand := 0.0
	var consumers: Array = []
	var advanced_coverage := {}
	for facility_value in state.facilities.keys():
		var facility_id := str(facility_value)
		var runtime: Dictionary = state.facilities.get(facility_id, {})
		if str(runtime.get("status", "")) != "ACTIVE":
			continue
		baseline_generation += facility_baseline_power_generation(state, facility_id)
		advanced_generation += facility_advanced_power_generation(state, facility_id)
		baseline_demand += facility_baseline_power_demand(state, facility_id)
		var facility_demand := facility_advanced_power_demand(state, facility_id)
		advanced_demand += facility_demand
		if facility_demand <= 0.0:
			advanced_coverage[facility_id] = 1.0
			continue
		var definition: Dictionary = content.facilities.get(facility_id, {})
		var policy := str(state.energy_system.get("advanced_priorities", {}).get(facility_id, definition.get("advanced_power_priority", "NORMAL")))
		consumers.append({
			"facility_id":facility_id,
			"demand":facility_demand,
			"priority":_advanced_priority_rank(policy)
		})
	for megastructure_id in state.megastructures:
		if bool(state.megastructures.get(megastructure_id, false)):
			var definition: Dictionary = content.megastructures.get(str(megastructure_id), {})
			baseline_generation += float(definition.get("baseline_power_generation", definition.get("power_generation", 0.0)))
			advanced_generation += float(definition.get("advanced_power_generation", 0.0))
	consumers.sort_custom(func(a, b):
		return int(a.get("priority", 50)) > int(b.get("priority", 50)) if int(a.get("priority", 50)) != int(b.get("priority", 50)) else str(a.get("facility_id", "")) < str(b.get("facility_id", ""))
	)
	var advanced_remaining := advanced_generation
	for consumer in consumers:
		var facility_id := str(consumer.get("facility_id", ""))
		var facility_demand := float(consumer.get("demand", 0.0))
		advanced_coverage[facility_id] = clampf(advanced_remaining / facility_demand, 0.0, 1.0)
		advanced_remaining = maxf(0.0, advanced_remaining - facility_demand)
	var baseline_coverage := 1.0 if baseline_demand <= 0.0 else clampf(baseline_generation / baseline_demand, 0.0, 1.0)
	var advanced_total_coverage := 1.0 if advanced_demand <= 0.0 else clampf(advanced_generation / advanced_demand, 0.0, 1.0)
	return {
		"generation_capacity":baseline_generation + advanced_generation,
		"current_demand":baseline_demand + advanced_demand,
		"available_capacity":baseline_generation + advanced_generation - baseline_demand - advanced_demand,
		"baseline_generation":baseline_generation,
		"baseline_demand":baseline_demand,
		"baseline_reserve":baseline_generation - baseline_demand,
		"baseline_coverage":baseline_coverage,
		"advanced_generation":advanced_generation,
		"advanced_demand":advanced_demand,
		"advanced_reserve":advanced_generation - advanced_demand,
		"advanced_coverage":advanced_total_coverage,
		"facility_advanced_coverage":advanced_coverage,
		"maintenance":_energy_maintenance_snapshot(state),
		"shortage":baseline_coverage < 0.9999 or advanced_total_coverage < 0.9999
	}


func facility_powered(state: SpaceGameState, facility_id: String) -> bool:
	# Compatibility query: power shortage is a soft throughput loss, never a hard OFF.
	return state.facilities.has(facility_id) and str(state.facilities[facility_id].get("status", "")) == "ACTIVE"


func facility_output_multiplier(state: SpaceGameState, facility_id: String) -> float:
	if facility_id.is_empty() or not state.facilities.has(facility_id):
		return 1.0
	var definition: Dictionary = content.facilities.get(facility_id, {})
	var power := civilization_power_state(state)
	var baseline_coverage := float(power.get("baseline_coverage", 1.0))
	var baseline_minimum := clampf(float(definition.get("baseline_minimum_efficiency", 0.5)), 0.05, 1.0)
	var result := baseline_minimum + (1.0 - baseline_minimum) * baseline_coverage
	var advanced_demand := facility_advanced_power_demand(state, facility_id)
	if advanced_demand <= 0.0:
		return result
	var advanced_coverage := float(power.get("facility_advanced_coverage", {}).get(facility_id, 1.0))
	var minimum := clampf(float(definition.get("advanced_minimum_efficiency", 1.0)), 0.05, 1.0)
	result *= minimum + (1.0 - minimum) * advanced_coverage
	var bonus := float(definition.get("advanced_power_bonus", 0.0))
	var upgrade_definitions: Dictionary = definition.get("upgrade_modules", {})
	for module_value in state.facilities[facility_id].get("installed_modules", []):
		bonus += float(upgrade_definitions.get(str(module_value), {}).get("advanced_power_bonus", 0.0))
	for module in installed_manufacturing_module_definitions(state, facility_id):
		bonus += float(module.get("advanced_power_bonus", 0.0))
	return maxf(0.05, result * (1.0 + bonus * advanced_coverage))


func _advanced_priority_rank(priority: String) -> int:
	match priority:
		"CRITICAL": return 400
		"HIGH": return 300
		"LOW": return 100
		_: return 200


func runtime_for_domain(state: SpaceGameState, domain_id: String) -> Dictionary:
	match domain_id:
		"mining":
			for runtime in state.mining_operations:
				if runtime.get("status", "") != "IDLE":
					return runtime
		"industry":
			for runtime in state.industrial_operations:
				if runtime.get("status", "") != "IDLE":
					return runtime
		"construction":
			if not state.construction_operations.is_empty() and state.construction_operations[0].get("status", "") in ["RUNNING", "BLOCKED"]:
				return state.construction_operations[0]
		"expedition":
			return state.active_expedition
	return {}


func progress_for_domain(state: SpaceGameState, domain_id: String) -> float:
	var runtime := runtime_for_domain(state, domain_id)
	if domain_id == "construction":
		return clampf((float(runtime.get("project_cycles_completed", 0)) + float(runtime.get("cycle_progress", 0.0))) / 100.0, 0.0, 1.0)
	if domain_id == "expedition" and str(runtime.get("combat_state", {}).get("status", "")) == "RUNNING":
		var combat_state: Dictionary = runtime.get("combat_state", {})
		var maximum := float(combat_state.get("enemy_max_hull", 0.0)) + float(combat_state.get("enemy_max_shield", 0.0))
		var remaining := float(combat_state.get("enemy_hull", 0.0)) + float(combat_state.get("enemy_shield", 0.0))
		return 0.0 if maximum <= 0.0 else clampf(1.0 - remaining / maximum, 0.0, 1.0)
	var activity_id := str(runtime.get("activity_id", ""))
	if activity_id.is_empty() or not content.activities.has(activity_id):
		return 0.0
	var duration := effective_duration_ms(state, domain_id, content.activities[activity_id], runtime)
	if duration == INF:
		return 0.0
	return clampf(float(runtime.get("progress_ms", 0.0)) / duration, 0.0, 1.0)


func runtime_cycle_progress(state: SpaceGameState, domain_id: String, activity: Dictionary, runtime: Dictionary) -> float:
	if domain_id == "construction":
		return clampf(float(runtime.get("cycle_progress", 0.0)), 0.0, 1.0)
	var duration := effective_duration_ms(state, domain_id, activity, runtime)
	return 0.0 if duration == INF else clampf(float(runtime.get("progress_ms", 0.0)) / maxf(1.0, duration), 0.0, 1.0)


func runtime_productivity_progress(runtime: Dictionary) -> float:
	return clampf(float(runtime.get("productivity_progress", 0.0)), 0.0, 1.0)


func _next_boundary_ms(state: SpaceGameState) -> float:
	var result := INF
	result = minf(result, logistics.next_event_ms(state))
	for network_id in state.extraction_network_states:
		var network_runtime: Dictionary = state.extraction_network_states[network_id]
		if network_runtime.get("status", "") != "RUNNING":
			continue
		var network: Dictionary = content.extraction_networks.get(str(network_id), {})
		if not network.is_empty() and not network_runtime.get("integrated_site_ids", []).is_empty():
			result = minf(result, maxf(0.001, (1.0 - float(network_runtime.get("cycle_progress", 0.0))) * extraction_network_cycle_duration_ms(network)))
	for shipyard_runtime in state.shipyard_queue:
		if shipyard_runtime.get("status", "") == "RUNNING":
			var shipyard_plan: Dictionary = content.ship_construction_projects.get(str(shipyard_runtime.get("plan_id", "")), {})
			if not shipyard_plan.is_empty():
				result = minf(result, maxf(0.001, (1.0 - float(shipyard_runtime.get("cycle_progress", 0.0))) * shipyard_cycle_duration_ms(state, shipyard_plan)))
	for refit_runtime in state.refit_projects:
		if refit_runtime.get("status", "") == "RUNNING":
			result = minf(result, maxf(0.001, (1.0 - float(refit_runtime.get("cycle_progress", 0.0))) * refit_cycle_duration_ms(state, refit_runtime)))
	for service_runtime in state.ship_service_projects:
		if service_runtime.get("status", "") == "RUNNING":
			result = minf(result, maxf(0.001, float(service_runtime.get("duration_ms", 1.0)) - float(service_runtime.get("progress_ms", 0.0))))
	if state.research.get("status", "") == "RUNNING":
		var project: Dictionary = content.research_projects.get(str(state.research.get("project_id", "")), {})
		if not project.is_empty():
			result = minf(result, _research_boundary_ms(state, project))
	if state.active_expedition.get("status", "") == "RUNNING" and not str(state.active_expedition.get("route_id", "")).is_empty():
		var node := _current_expedition_node(state)
		if not node.is_empty():
			var route_combat_state: Dictionary = state.active_expedition.get("combat_state", {})
			if str(node.get("phase", "")) in ["COMBAT", "BOSS"] and str(route_combat_state.get("status", "")) == "RUNNING":
				result = minf(result, combat.next_event_ms(route_combat_state))
			else:
				result = minf(result, maxf(0.001, (float(node.get("duration_ms", 1.0)) - float(state.active_expedition.get("node_progress_ms", 0.0))) / expedition_support_rate(state)))
	for entry in _all_runtime_entries(state):
		var runtime: Dictionary = entry["runtime"]
		if runtime.get("status", "") != "RUNNING":
			continue
		if str(entry["domain"]) == "expedition" and not str(runtime.get("route_id", "")).is_empty():
			continue
		var activity: Dictionary = construction_activity_for_runtime(runtime) if str(entry["domain"]) == "construction" else content.activities.get(str(runtime.get("activity_id", "")), {})
		if activity.is_empty():
			continue
		var domain_id := str(entry["domain"])
		if domain_id == "expedition" and _is_combat_activity(activity):
			var activity_combat_state: Dictionary = runtime.get("combat_state", {})
			if str(activity_combat_state.get("status", "")) == "RUNNING":
				result = minf(result, combat.next_event_ms(activity_combat_state))
			continue
		var duration := effective_duration_ms(state, domain_id, activity, runtime)
		if duration != INF:
			if domain_id == "construction":
				result = minf(result, maxf(0.001, (1.0 - float(runtime.get("cycle_progress", 0.0))) * duration))
				continue
			var runs := _runs_to_relevant_boundary(state, domain_id, activity, runtime)
			result = minf(result, maxf(0.001, duration * float(runs) - float(runtime.get("progress_ms", 0.0))))
	for ship in state.ships:
		if ship.get("status", "") == "REPAIRING":
			result = minf(result, maxf(0.001, float(ship.get("repair_remaining_ms", 0.0)) / repair_support_rate(state)))
	return result


func _progress_fleet_maintenance(state: SpaceGameState, elapsed_ms: float) -> void:
	if elapsed_ms <= 0.0:
		return
	var maintenance := state.fleet_maintenance
	var fractions: Dictionary = maintenance.get("fractional", {})
	var debts: Dictionary = maintenance.get("debt", {})
	var coverage: Dictionary = maintenance.get("coverage", {})
	var item_id := str(content.fleet_rules.get("maintenance_item", "repair_material"))
	var per_command_hour := maxf(0.0, float(content.fleet_rules.get("maintenance_material_per_command_hour", 0.02)))
	var rates: Dictionary = content.fleet_rules.get("maintenance_rates", {})
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		var ship_id := str(ship.get("instance_id", ""))
		var maintenance_state := str(ship.get("maintenance_state", "ACTIVE"))
		if str(ship.get("status", "DOCKED")) not in ["DOCKED", "REACTIVATING"]:
			maintenance_state = "ACTIVE"
		var rate := maxf(0.0, float(rates.get(maintenance_state, 1.0)))
		var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
		var command_cost := maxf(1.0, float(blueprint.get("command_cost", 1.0)))
		var demand := command_cost * per_command_hour * rate * elapsed_ms / 3600000.0
		var owed := float(fractions.get(ship_id, 0.0)) + float(debts.get(ship_id, 0.0)) + demand
		var whole_units := maxi(0, int(floor(owed + 0.000001)))
		var location_id := str(ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var consumed := mini(whole_units, state.available_item_quantity(item_id, location_id))
		if consumed > 0:
			state.remove_item(item_id, consumed, location_id)
		var unpaid := whole_units - consumed
		fractions[ship_id] = maxf(0.0, owed - float(whole_units))
		debts[ship_id] = float(unpaid)
		var supported := 1.0 if whole_units <= 0 else float(consumed) / float(whole_units)
		coverage[ship_id] = supported
		ship["maintenance_coverage"] = supported
		ship["maintenance_debt"] = float(unpaid)
	maintenance["fractional"] = fractions
	maintenance["debt"] = debts
	maintenance["coverage"] = coverage
	state.fleet_maintenance = maintenance


func fleet_maintenance_snapshot(state: SpaceGameState) -> Array:
	var result: Array = []
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
		var maintenance_state := str(ship.get("maintenance_state", "ACTIVE"))
		var rate := float(content.fleet_rules.get("maintenance_rates", {}).get(maintenance_state, 1.0))
		result.append({
			"ship_id":str(ship.get("instance_id", "")),
			"maintenance_state":maintenance_state,
			"demand_per_hour":float(blueprint.get("command_cost", 1.0)) * float(content.fleet_rules.get("maintenance_material_per_command_hour", 0.02)) * rate,
			"coverage":float(ship.get("maintenance_coverage", 1.0)),
			"debt":float(ship.get("maintenance_debt", 0.0))
		})
	return result


func refresh_demand_registry(state: SpaceGameState) -> void:
	var previous: Dictionary = state.demand_registry.get("sources", {})
	var current := {}
	for row_value in _facility_operations_maintenance_demands(state):
		var row := row_value as Dictionary
		_register_demand(current, row)
	for row_value in fleet_maintenance_snapshot(state):
		var row := row_value as Dictionary
		_register_demand(current, {
			"demand_id":"maintenance:fleet:%s" % row.get("ship_id", ""),
			"product_id":str(content.fleet_rules.get("maintenance_item", "repair_material")),
			"demand_kind":"CONTINUOUS", "rate_per_hour":float(row.get("demand_per_hour", 0.0)),
			"source_type":"fleet_operation", "source_id":row.get("ship_id", ""),
			"location_id":str(state.ship_by_id(str(row.get("ship_id", ""))).get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)),
			"priority":80, "consumer_type":"fleet_maintenance"
		})
	for row_value in _energy_maintenance_snapshot(state):
		var row := row_value as Dictionary
		_register_demand(current, {
			"demand_id":"maintenance:energy:%s:%s" % [row.get("facility_id", ""), row.get("item_id", "")],
			"product_id":row.get("item_id", ""), "demand_kind":"CONTINUOUS", "rate_per_hour":float(row.get("demand_per_hour", 0.0)),
			"source_type":"maintenance", "source_id":row.get("facility_id", ""), "location_id":SpaceGameState.MAIN_BASE_LOCATION_ID,
			"priority":85, "consumer_type":"advanced_energy_maintenance"
		})
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("status", "")) not in ["RUNNING", "BLOCKED", "QUEUED"] or str(runtime.get("project_id", "")).is_empty():
			continue
		for item_id_value in runtime.get("material_plan", {}).keys():
			var item_id := str(item_id_value)
			var remaining := maxi(0, int(runtime.get("material_plan", {}).get(item_id, 0)) - int(runtime.get("consumed", {}).get(item_id, 0)))
			if remaining > 0:
				_register_demand(current, _committed_demand("construction", str(runtime.get("project_id", "")), item_id, remaining, str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)), int(runtime.get("priority", 50))))
	var research_project: Dictionary = content.research_projects.get(str(state.research.get("project_id", "")), {})
	if str(state.research.get("status", "")) in ["RUNNING", "BLOCKED", "PAUSED"] and not research_project.is_empty():
		var research_stage := research_stage_definition(state, research_project, int(state.research.get("stage_index", 0)), str(state.research.get("route_id", "")))
		for cost_value in research_stage.get("costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			var remaining := maxi(0, int(cost.get("quantity", 0)) - int(state.research.get("stage_consumed", {}).get(item_id, 0)))
			if remaining > 0:
				_register_demand(current, _committed_demand("research_project", "%s:%s" % [research_project.get("id", ""), research_stage.get("id", "")], item_id, remaining, str(state.research.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)), 90))
	for runtime_value in state.shipyard_queue:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("status", "")) not in ["RUNNING", "BLOCKED"]:
			continue
		var plan: Dictionary = content.ship_construction_projects.get(str(runtime.get("plan_id", "")), {})
		if plan.is_empty():
			continue
		var remaining_ships := maxi(0, int(runtime.get("quantity_remaining", 0)))
		var construction_totals := ship_construction_material_totals(plan)
		var fixed_totals := {}
		for fixed_value in plan.get("fixed_costs", []):
			var fixed := fixed_value as Dictionary
			var item_id := str(fixed.get("item", ""))
			fixed_totals[item_id] = int(fixed_totals.get(item_id, 0)) + int(fixed.get("quantity", 0))
		var item_ids: Array = construction_totals.keys()
		for item_id_value in fixed_totals.keys():
			if not item_ids.has(item_id_value):
				item_ids.append(item_id_value)
		for item_id_value in item_ids:
			var item_id := str(item_id_value)
			var fixed_per_ship := int(fixed_totals.get(item_id, 0))
			var fixed_already_paid := fixed_per_ship if int(runtime.get("paid_cycles", 0)) > 0 else 0
			var consumed_construction := maxi(0, int(runtime.get("consumed", {}).get(item_id, 0)) - fixed_already_paid)
			var fixed_ship_count := remaining_ships if int(runtime.get("paid_cycles", 0)) == 0 else maxi(0, remaining_ships - 1)
			var remaining := maxi(0, int(construction_totals.get(item_id, 0)) * remaining_ships - consumed_construction + fixed_per_ship * fixed_ship_count)
			if remaining > 0:
				_register_demand(current, _committed_demand("shipbuilding", str(runtime.get("project_id", "")), item_id, remaining, str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)), 80))
	var history: Array = state.demand_registry.get("history", [])
	for demand_id_value in previous.keys():
		var demand_id := str(demand_id_value)
		if current.has(demand_id):
			current[demand_id]["start_time_ms"] = int(previous[demand_id].get("start_time_ms", state.total_elapsed_ms))
			continue
		var ended: Dictionary = previous[demand_id].duplicate(true)
		ended["end_time_ms"] = int(state.total_elapsed_ms)
		history.append(ended)
	if history.size() > 250:
		history = history.slice(history.size() - 250)
	state.demand_registry = {"sources":current, "history":history}


func demand_sources_for(state: SpaceGameState, product_id: String, location_id: String = "") -> Array:
	var result: Array = []
	for demand_value in state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("product_id", "")) != product_id or not location_id.is_empty() and str(demand.get("location_id", "")) != location_id:
			continue
		result.append(demand.duplicate(true))
	result.sort_custom(func(a, b): return int(a.get("priority", 50)) > int(b.get("priority", 50)) if int(a.get("priority", 50)) != int(b.get("priority", 50)) else str(a.get("demand_id", "")) < str(b.get("demand_id", "")))
	return result


func _register_demand(target: Dictionary, demand: Dictionary) -> void:
	var demand_id := str(demand.get("demand_id", ""))
	if demand_id.is_empty() or str(demand.get("product_id", "")).is_empty():
		return
	demand["demand_id"] = demand_id
	demand["rate_per_hour"] = maxf(0.0, float(demand.get("rate_per_hour", 0.0)))
	demand["quantity"] = maxf(0.0, float(demand.get("quantity", 0.0)))
	demand["priority"] = clampi(int(demand.get("priority", 50)), 0, 100)
	demand["start_time_ms"] = int(demand.get("start_time_ms", 0))
	target[demand_id] = demand


func _committed_demand(source_type: String, source_id: String, product_id: String, quantity: int, location_id: String, priority: int) -> Dictionary:
	return {
		"demand_id":"%s:%s:%s" % [source_type, source_id, product_id], "product_id":product_id,
		"demand_kind":"COMMITTED", "quantity":maxi(0, quantity), "rate_per_hour":0.0,
		"source_type":source_type, "source_id":source_id, "location_id":location_id, "priority":priority,
		"completion_condition":{"type":"source_complete", "source_type":source_type, "source_id":source_id}
	}


func _facility_operations_maintenance_demands(state: SpaceGameState) -> Array:
	var result: Array = []
	var rules: Dictionary = content.industry_rules.get("operations_maintenance", {})
	var base_rate := maxf(0.0, float(rules.get("base_preservation_per_level_per_hour", 0.0)))
	var wear_rate := maxf(0.0, float(rules.get("operating_wear_per_level_per_hour", 0.0)))
	for facility_id_value in state.facilities.keys():
		var facility_id := str(facility_id_value)
		var definition: Dictionary = content.facilities.get(facility_id, {})
		if definition.is_empty() or str(state.facilities.get(facility_id, {}).get("status", "")) != "ACTIVE":
			continue
		if int(definition.get("manufacturing_generation", 0)) > 0:
			for location_id_value in state.locations.keys():
				var location_id := str(location_id_value)
				var local_industry := state.location_industry(location_id, facility_id)
				if not local_industry.is_empty():
					_append_facility_om_demands(result, rules, facility_id, location_id, maxi(1, int(local_industry.get("level", 1))), _facility_utilization(state, facility_id, location_id), "manufacturing", base_rate, wear_rate)
			continue
		var category := str(definition.get("category", "infrastructure")).to_lower()
		var profile_id := "energy" if category == "energy" else "infrastructure"
		_append_facility_om_demands(result, rules, facility_id, SpaceGameState.MAIN_BASE_LOCATION_ID, maxi(1, int(state.facilities[facility_id].get("level", 1))), _facility_utilization(state, facility_id, SpaceGameState.MAIN_BASE_LOCATION_ID), profile_id, base_rate, wear_rate)
	return result


func _append_facility_om_demands(result: Array, rules: Dictionary, facility_id: String, location_id: String, level: int, utilization: float, profile_id: String, base_rate: float, wear_rate: float) -> void:
	var profile: Dictionary = rules.get("category_profiles", {}).get(profile_id, rules.get("default_items", {}))
	var total_rate := (base_rate + wear_rate * clampf(utilization, 0.0, 1.0)) * float(level)
	for item_id_value in profile.keys():
		var item_id := str(item_id_value)
		var rate := total_rate * maxf(0.0, float(profile.get(item_id, 0.0)))
		if rate <= 0.0:
			continue
		result.append({
			"demand_id":"maintenance:facility:%s:%s:%s" % [location_id, facility_id, item_id],
			"product_id":item_id, "demand_kind":"CONTINUOUS", "rate_per_hour":rate,
			"source_type":"maintenance", "source_id":"%s:%s" % [location_id, facility_id], "location_id":location_id,
			"priority":60, "consumer_type":"facility_om", "facility_id":facility_id, "utilization":utilization
		})


func _facility_utilization(state: SpaceGameState, facility_id: String, location_id: String) -> float:
	if int(content.facilities.get(facility_id, {}).get("manufacturing_generation", 0)) > 0:
		return 1.0 if state.production_lines_for(location_id, facility_id).any(func(line): return str((line as Dictionary).get("status", "")) == "RUNNING") else 0.0
	if facility_id == "orbital_construction_yard":
		return 1.0 if state.construction_operations.any(func(project): return str((project as Dictionary).get("status", "")) == "RUNNING") else 0.0
	if facility_id == "orbital_starport":
		return 1.0 if not state.shipyard_queue.is_empty() or not state.refit_projects.is_empty() or not state.ship_service_projects.is_empty() else 0.0
	if facility_id == "research_complex":
		return 1.0 if str(state.research.get("status", "")) == "RUNNING" else 0.0
	if facility_id == "repair_dock":
		return 1.0 if state.ships.any(func(ship): return str((ship as Dictionary).get("status", "")) == "REPAIRING") else 0.0
	return 1.0 if str(content.facilities.get(facility_id, {}).get("category", "")) == "Energy" else 0.0


func _progress_operations_maintenance(state: SpaceGameState, elapsed_ms: float) -> void:
	if elapsed_ms <= 0.0:
		return
	var maintenance: Dictionary = state.operations_maintenance
	var fractional: Dictionary = maintenance.get("fractional", {})
	var coverage: Dictionary = maintenance.get("coverage", {})
	var totals: Dictionary = maintenance.get("consumption_totals", {})
	for demand_value in state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("consumer_type", "")) != "facility_om":
			continue
		var demand_id := str(demand.get("demand_id", ""))
		var item_id := str(demand.get("product_id", ""))
		var location_id := str(demand.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var accumulated := float(fractional.get(demand_id, 0.0)) + float(demand.get("rate_per_hour", 0.0)) * elapsed_ms / 3600000.0
		var due := maxi(0, int(floor(accumulated + 0.000001)))
		fractional[demand_id] = accumulated - float(due)
		if due <= 0:
			coverage[demand_id] = float(coverage.get(demand_id, 1.0))
			continue
		var consumed := mini(due, state.available_item_quantity(item_id, location_id))
		if consumed > 0:
			state.remove_item(item_id, consumed, location_id)
			totals[item_id] = int(totals.get(item_id, 0)) + consumed
		coverage[demand_id] = float(consumed) / float(due)
	maintenance["fractional"] = fractional
	maintenance["coverage"] = coverage
	maintenance["consumption_totals"] = totals
	state.operations_maintenance = maintenance


func facility_operations_maintenance_coverage(state: SpaceGameState, location_id: String, facility_id: String) -> float:
	var result := 1.0
	var found := false
	for demand_value in state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("consumer_type", "")) != "facility_om" or str(demand.get("location_id", "")) != location_id or str(demand.get("facility_id", "")) != facility_id:
			continue
		found = true
		result = minf(result, float(state.operations_maintenance.get("coverage", {}).get(str(demand.get("demand_id", "")), 1.0)))
	return result if found else 1.0


func _progress_runtime(state: SpaceGameState, elapsed_ms: float) -> void:
	logistics.advance_clock(state, elapsed_ms)
	_progress_energy_maintenance(state, elapsed_ms)
	_progress_fleet_maintenance(state, elapsed_ms)
	_progress_operations_maintenance(state, elapsed_ms)
	# Schema <=32 automation/background networks are intentionally retired. All
	# ordinary output must now run through a Factory + Device + Method runtime.
	_progress_research(state, elapsed_ms)
	for network_id in state.extraction_network_states:
		var network_runtime: Dictionary = state.extraction_network_states[network_id]
		if network_runtime.get("status", "") != "RUNNING":
			continue
		var network: Dictionary = content.extraction_networks.get(str(network_id), {})
		if not network.is_empty() and not network_runtime.get("integrated_site_ids", []).is_empty():
			network_runtime["cycle_progress"] = float(network_runtime.get("cycle_progress", 0.0)) + elapsed_ms / extraction_network_cycle_duration_ms(network)
	for shipyard_runtime in state.shipyard_queue:
		if shipyard_runtime.get("status", "") == "RUNNING":
			var shipyard_plan: Dictionary = content.ship_construction_projects.get(str(shipyard_runtime.get("plan_id", "")), {})
			if not shipyard_plan.is_empty():
				shipyard_runtime["cycle_progress"] = float(shipyard_runtime.get("cycle_progress", 0.0)) + elapsed_ms / shipyard_cycle_duration_ms(state, shipyard_plan)
	for refit_runtime in state.refit_projects:
		if refit_runtime.get("status", "") == "RUNNING":
			refit_runtime["cycle_progress"] = float(refit_runtime.get("cycle_progress", 0.0)) + elapsed_ms / refit_cycle_duration_ms(state, refit_runtime)
	for service_runtime in state.ship_service_projects:
		if service_runtime.get("status", "") == "RUNNING":
			service_runtime["progress_ms"] = minf(float(service_runtime.get("duration_ms", 1.0)), float(service_runtime.get("progress_ms", 0.0)) + elapsed_ms)
	for entry in _all_runtime_entries(state):
		var runtime: Dictionary = entry["runtime"]
		if runtime.get("status", "") != "RUNNING" or (str(entry["domain"]) == "expedition" and not str(runtime.get("route_id", "")).is_empty()):
			continue
		var runtime_activity: Dictionary = construction_activity_for_runtime(runtime) if str(entry["domain"]) == "construction" else content.activities.get(str(runtime.get("activity_id", "")), {})
		if str(entry["domain"]) == "expedition" and _is_combat_activity(runtime_activity) and str(runtime.get("combat_state", {}).get("status", "")) == "RUNNING":
			combat.advance_clock(runtime["combat_state"], elapsed_ms)
		elif str(entry["domain"]) == "construction":
			var construction_duration := effective_duration_ms(state, "construction", runtime_activity, runtime)
			if construction_duration != INF:
				runtime["cycle_progress"] = float(runtime.get("cycle_progress", 0.0)) + elapsed_ms / construction_duration
		else:
			runtime["progress_ms"] = float(runtime.get("progress_ms", 0.0)) + elapsed_ms
	if state.active_expedition.get("status", "") == "RUNNING" and not str(state.active_expedition.get("route_id", "")).is_empty():
		var current_node := _current_expedition_node(state)
		var active_route_combat: Dictionary = state.active_expedition.get("combat_state", {})
		if str(current_node.get("phase", "")) in ["COMBAT", "BOSS"] and str(active_route_combat.get("status", "")) == "RUNNING":
			combat.advance_clock(active_route_combat, elapsed_ms)
		else:
			state.active_expedition["node_progress_ms"] = float(state.active_expedition.get("node_progress_ms", 0.0)) + elapsed_ms * expedition_support_rate(state)
	for ship in state.ships:
		if ship.get("status", "") == "REPAIRING":
			ship["repair_remaining_ms"] = maxf(0.0, float(ship.get("repair_remaining_ms", 0.0)) - elapsed_ms * repair_support_rate(state))


func _settle_shipyard_cycle(state: SpaceGameState, runtime: Dictionary) -> bool:
	if runtime.get("status", "") != "RUNNING" or float(runtime.get("cycle_progress", 0.0)) + 0.000001 < 1.0:
		return false
	var plan: Dictionary = content.ship_construction_projects.get(str(runtime.get("plan_id", "")), {})
	if plan.is_empty():
		return false
	var due := _shipyard_next_cycle_costs(runtime, plan)
	for item_id in due:
		if state.available_item_quantity_for_shipyard(str(item_id), str(runtime.get("project_id", ""))) < int(due[item_id]):
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "RESOURCES:%s" % item_id
			return true
	for item_id in due:
		state.remove_item(str(item_id), int(due[item_id]))
		runtime["consumed"][str(item_id)] = int(runtime.get("consumed", {}).get(str(item_id), 0)) + int(due[item_id])
	runtime["cycle_progress"] = maxf(0.0, float(runtime.get("cycle_progress", 0.0)) - 1.0)
	runtime["paid_cycles"] = int(runtime.get("paid_cycles", 0)) + 1
	runtime["completed_segments"] = mini(100, int(runtime.get("completed_segments", 0)) + 1)
	runtime["productivity_progress"] = 0.0
	emitted_events.append({"type":"ShipbuildingCycleCompleted", "plan_id":plan.get("id", ""), "segments":runtime.get("completed_segments", 0)})
	if int(runtime.get("completed_segments", 0)) < 100:
		return true
	var ship_id := str(plan.get("ship_id", ""))
	if state.add_unique_ship(ship_id, plan.get("starting_modules", [])):
		state.statistics["ships_built"] = int(state.statistics.get("ships_built", 0)) + 1
		state.statistics["ships_developed"] = int(state.statistics.get("ships_developed", 0)) + 1
	var project_id := str(runtime.get("project_id", ""))
	runtime["quantity_completed"] = int(runtime.get("quantity_completed", 0)) + 1
	runtime["quantity_remaining"] = maxi(0, int(runtime.get("quantity_remaining", 1)) - 1)
	emitted_events.append({"type":"ShipConstructionCompleted", "project_id":project_id, "plan_id":plan.get("id", ""), "ship_id":ship_id, "quantity_completed":runtime.get("quantity_completed", 1), "quantity_remaining":runtime.get("quantity_remaining", 0)})
	if int(runtime.get("quantity_remaining", 0)) > 0:
		runtime["completed_segments"] = 0
		runtime["paid_cycles"] = 0
		runtime["consumed"] = {}
		runtime["productivity_progress"] = 0.0
		runtime["status"] = "RUNNING"
		runtime["blocked_reason"] = ""
		normalize_shipyard_queue(state)
		return true
	for index in range(state.shipyard_queue.size() - 1, -1, -1):
		if str(state.shipyard_queue[index].get("project_id", "")) == project_id:
			state.shipyard_queue.remove_at(index)
			break
	normalize_shipyard_queue(state)
	return true


func _settle_ready_boundaries(state: SpaceGameState) -> Dictionary:
	var completed := 0
	var settled_runs := 0
	var logistics_result: Dictionary = logistics.settle_ready(state)
	if int(logistics_result.get("boundaries", 0)) > 0:
		completed += int(logistics_result.get("boundaries", 0))
		settled_runs += int(logistics_result.get("boundaries", 0))
		emitted_events.append_array(logistics_result.get("events", []))
	for network_id in state.extraction_network_states:
		if _settle_extraction_network_cycle(state, str(network_id)):
			completed += 1
			settled_runs += 1
	for shipyard_runtime in state.shipyard_queue.duplicate():
		if _settle_shipyard_cycle(state, shipyard_runtime):
			completed += 1
			settled_runs += 1
	for refit_runtime in state.refit_projects.duplicate():
		if _settle_refit_cycle(state, refit_runtime):
			completed += 1
			settled_runs += 1
	for service_runtime in state.ship_service_projects.duplicate():
		if _settle_ship_service_project(state, service_runtime):
			completed += 1
			settled_runs += 1
	if _settle_research(state):
		completed += 1
		settled_runs += 1
	if _settle_expedition_node(state):
		completed += 1
		settled_runs += 1
	for ship in state.ships:
		if ship.get("status", "") == "REPAIRING" and float(ship.get("repair_remaining_ms", 0.0)) <= 0.001:
			ship["status"] = "DOCKED"
			ship["condition"] = "OPERATIONAL"
			var repaired_ship_id := str(ship.get("instance_id", ""))
			var repaired_fleet_domain := state.ship_fleet_domain(repaired_ship_id)
			ship["assignment"] = {} if repaired_fleet_domain.is_empty() else {"domain":repaired_fleet_domain, "fleet":"default"}
			ship["damage_taken"] = 0.0
			emitted_events.append({"type":"ShipRepaired", "ship_id":ship.get("instance_id", "")})
			completed += 1
			settled_runs += 1
	for entry in _all_runtime_entries(state):
		var runtime: Dictionary = entry["runtime"]
		if runtime.get("status", "") != "RUNNING":
			continue
		if str(entry["domain"]) == "expedition" and not str(runtime.get("route_id", "")).is_empty():
			continue
		var activity: Dictionary = construction_activity_for_runtime(runtime) if str(entry["domain"]) == "construction" else content.activities.get(str(runtime.get("activity_id", "")), {})
		if activity.is_empty():
			continue
		if str(entry["domain"]) == "expedition" and _is_combat_activity(activity):
			var combat_state: Dictionary = runtime.get("combat_state", {})
			if combat.event_ready(combat_state):
				var combat_event: Dictionary = combat.settle_next_event(state, combat_state)
				state.combat_log = combat_state.get("log", []).duplicate(true)
				emitted_events.append({"type":"CombatActionResolved", "activity_id":activity.get("id", ""), "combat_event":combat_event})
				completed += 1
				settled_runs += 1
				if str(combat_state.get("status", "")) != "RUNNING":
					_complete_runtime_cycle(state, "expedition", runtime, activity)
				continue
		var duration := effective_duration_ms(state, str(entry["domain"]), activity, runtime)
		var is_construction_cycle := str(entry["domain"]) == "construction"
		if duration == INF or (float(runtime.get("cycle_progress", 0.0)) + 0.000001 < 1.0 if is_construction_cycle else float(runtime.get("progress_ms", 0.0)) + 0.001 < duration):
			continue
		var domain_id := str(entry["domain"])
		var runs := 1 if is_construction_cycle else int(floor((float(runtime.get("progress_ms", 0.0)) + 0.001) / duration))
		runs = mini(runs, _runs_to_relevant_boundary(state, domain_id, activity, runtime))
		if runs <= 0:
			continue
		if is_construction_cycle:
			runtime["cycle_progress"] = maxf(0.0, float(runtime.get("cycle_progress", 0.0)) - 1.0)
		else:
			runtime["progress_ms"] = maxf(0.0, float(runtime.get("progress_ms", 0.0)) - duration * float(runs))
		if runs > 1 and domain_id != "expedition" and bool(activity.get("repeat", true)) and activity.get("effects", []).is_empty():
			_complete_runtime_batch(state, domain_id, runtime, activity, runs)
		else:
			_complete_runtime_cycle(state, domain_id, runtime, activity)
		completed += 1
		settled_runs += runs
	return {"boundaries":completed, "runs":settled_runs}


func _settle_ship_service_project(state: SpaceGameState, runtime: Dictionary) -> bool:
	if runtime.get("status", "") != "RUNNING" or float(runtime.get("progress_ms", 0.0)) + 0.001 < float(runtime.get("duration_ms", 1.0)):
		return false
	var ship_id := str(runtime.get("ship_id", ""))
	var ship := state.ship_by_id(ship_id)
	if not ship.is_empty() and str(runtime.get("project_kind", "")) == "REACTIVATION":
		ship["maintenance_state"] = "ACTIVE"
		ship["maintenance_coverage"] = 1.0
		ship["maintenance_debt"] = 0.0
		ship["status"] = "DOCKED"
		ship["assignment"] = {}
		state.fleet_maintenance.get("debt", {}).erase(ship_id)
		state.fleet_maintenance.get("coverage", {})[ship_id] = 1.0
		emitted_events.append({"type":"ShipReactivated", "project_id":runtime.get("project_id", ""), "ship_id":ship_id})
	var project_id := str(runtime.get("project_id", ""))
	for index in range(state.ship_service_projects.size() - 1, -1, -1):
		if str(state.ship_service_projects[index].get("project_id", "")) == project_id:
			state.ship_service_projects.remove_at(index)
			break
	return true


func refit_cycle_duration_ms(state: SpaceGameState, runtime: Dictionary) -> float:
	return maxf(2.5, float(runtime.get("cycle_time_ms", 100.0)) / (facility_cycle_speed_multiplier(state, "orbital_starport") * simulation_speed_multiplier("shipyard")))


func _settle_refit_cycle(state: SpaceGameState, runtime: Dictionary) -> bool:
	if runtime.get("status", "") != "RUNNING" or float(runtime.get("cycle_progress", 0.0)) + 0.000001 < 1.0:
		return false
	runtime["cycle_progress"] = maxf(0.0, float(runtime.get("cycle_progress", 0.0)) - 1.0)
	runtime["completed_segments"] = mini(100, int(runtime.get("completed_segments", 0)) + 1)
	emitted_events.append({"type":"ShipRefitCycleCompleted", "project_id":runtime.get("project_id", ""), "ship_id":runtime.get("ship_id", ""), "segments":runtime.get("completed_segments", 0)})
	if int(runtime.get("completed_segments", 0)) < 100:
		return true
	var ship_id := str(runtime.get("ship_id", ""))
	var ship := state.ship_by_id(ship_id)
	if ship.is_empty():
		runtime["status"] = "FAILED"
		return true
	var desired_modules: Array = runtime.get("desired_modules", []).duplicate()
	if desired_modules.is_empty() and not runtime.get("desired_definitions", []).is_empty():
		runtime["status"] = "FAILED"
		return true
	for equipment_value in runtime.get("outgoing_equipment_ids", []):
		var equipment_id := str(equipment_value)
		if state.equipment_instances.has(equipment_id):
			state.equipment_instances[equipment_id]["status"] = "STORAGE"
			state.equipment_instances[equipment_id]["installed_ship_id"] = ""
	ship["modules"] = []
	for module_value in desired_modules:
		var stored_value := str(module_value)
		ship["modules"].append(stored_value)
		if state.equipment_instances.has(stored_value):
			state.equipment_instances[stored_value]["status"] = "INSTALLED"
			state.equipment_instances[stored_value]["installed_ship_id"] = ship_id
	ship["current_loadout_id"] = str(runtime.get("target_loadout_id", ""))
	ship["status"] = "DOCKED"
	ship["assignment"] = {}
	state.statistics["refits_completed"] = int(state.statistics.get("refits_completed", 0)) + 1
	var project_id := str(runtime.get("project_id", ""))
	for index in range(state.refit_projects.size() - 1, -1, -1):
		if str(state.refit_projects[index].get("project_id", "")) == project_id:
			state.refit_projects.remove_at(index)
			break
	emitted_events.append({"type":"ShipRefitCompleted", "project_id":project_id, "ship_id":ship_id})
	return true


func _settle_extraction_network_cycle(state: SpaceGameState, network_id: String) -> bool:
	var runtime: Dictionary = state.extraction_network_states.get(network_id, {})
	if runtime.get("status", "") != "RUNNING" or float(runtime.get("cycle_progress", 0.0)) + 0.000001 < 1.0:
		return false
	var network: Dictionary = content.extraction_networks.get(network_id, {})
	var site_ids: Array = runtime.get("integrated_site_ids", [])
	if network.is_empty() or site_ids.is_empty():
		runtime["status"] = "IDLE"
		return false
	var output_transaction := _extraction_network_output_transaction(state, network_id)
	for location_id_value in output_transaction.keys():
		if not storage_can_apply_transaction(state, str(location_id_value), output_transaction[location_id_value]):
			runtime["status"] = "BLOCKED_OUTPUT"
			runtime["blocked_reason"] = "STORAGE_FULL"
			emitted_events.append({"type":"ExtractionNetworkBlocked", "network_id":network_id, "reason":"STORAGE_FULL", "location_id":location_id_value})
			return true
	runtime["cycle_progress"] = maxf(0.0, float(runtime.get("cycle_progress", 0.0)) - 1.0)
	var totals: Dictionary = runtime.get("production_totals", {})
	var output_totals := {}
	for site_id in site_ids:
		var site: Dictionary = content.mining_sites.get(str(site_id), {})
		var location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
		var item_id := str(location.get("raw_material", ""))
		if item_id.is_empty():
			continue
		var quantity := int(network.get("quantity_per_site", 1)) * maxi(1, int(runtime.get("level", 1)))
		state.add_item(item_id, quantity, str(location.get("region", SpaceGameState.MAIN_BASE_LOCATION_ID)))
		totals[item_id] = int(totals.get(item_id, 0)) + quantity
		output_totals[item_id] = int(output_totals.get(item_id, 0)) + quantity
	runtime["production_totals"] = totals
	emitted_events.append({"type":"ExtractionNetworkCycleCompleted", "network_id":network_id, "outputs":output_totals})
	return true


func _runs_to_relevant_boundary(state: SpaceGameState, domain_id: String, activity: Dictionary, runtime: Dictionary) -> int:
	# Mining settles one Cycle at a time for deterministic mastery accounting;
	# expedition targets also require exact boundaries.
	if domain_id in ["mining", "expedition"] or not bool(activity.get("repeat", true)) or not activity.get("effects", []).is_empty():
		return 1
	# Foreground Industry owns one fully funded cycle at a time. Settling a
	# material-consuming recipe per cycle lets reservations be renewed before
	# background systems can spend the remainder.
	if domain_id == "industry" and not activity.get("costs", []).is_empty():
		return 1
	var runs := 1000000
	var xp_per_run := int(activity.get("xp", 0))
	if xp_per_run > 0:
		var domain: Dictionary = state.domains.get(domain_id, {})
		var next_level_xp := xp_for_level(int(domain.get("level", 1)) + 1)
		var needed := maxi(1, next_level_xp - int(domain.get("xp", 0)))
		runs = mini(runs, ceili(float(needed) / float(xp_per_run)))
	for cost in activity.get("costs", []):
		var quantity := int(cost.get("quantity", 0))
		if quantity > 0:
			runs = mini(runs, maxi(1, _runtime_available_item_quantity(state, domain_id, runtime, str(cost.get("item", ""))) / quantity))
	return maxi(1, runs)


func _complete_runtime_batch(state: SpaceGameState, domain_id: String, runtime: Dictionary, activity: Dictionary, requested_runs: int) -> void:
	var runs := requested_runs
	var inventory_location_id := _runtime_inventory_location_id(state, domain_id, runtime)
	for cost in activity.get("costs", []):
		var quantity := int(cost.get("quantity", 0))
		if quantity > 0:
			runs = mini(runs, _runtime_available_item_quantity(state, domain_id, runtime, str(cost.get("item", ""))) / quantity)
	if runs <= 0:
		runtime["status"] = "BLOCKED"
		runtime["progress_ms"] = 0.0
		emitted_events.append({"type":"OperationBlocked", "domain":domain_id, "activity_id":activity.get("id", ""), "reason":"resources"})
		return
	for cost in activity.get("costs", []):
		state.remove_item(str(cost.get("item", "")), int(cost.get("quantity", 0)) * runs, inventory_location_id)
	for reward in activity.get("rewards", []):
		_add_produced_item(state, str(reward.get("item", "")), int(reward.get("quantity", 0)) * runs, inventory_location_id)
	if domain_id == "industry":
		for _run in runs:
			var waste_totals := industry_cycle_waste(state, runtime, activity, true)
			for waste_item in waste_totals:
				state.add_item(str(waste_item), int(waste_totals.get(waste_item, 0)), inventory_location_id)
	var loot_totals := {}
	for _run in runs:
		for loot in activity.get("loot", []):
			if rng.next_float(state, "%s.loot" % domain_id) <= float(loot.get("chance", 0)):
				var item_id := str(loot.get("item", ""))
				var quantity := rng.next_int(state, "%s.loot.quantity" % domain_id, int(loot.get("min", 1)), int(loot.get("max", 1)))
				loot_totals[item_id] = int(loot_totals.get(item_id, 0)) + quantity
	for item_id in loot_totals:
		state.add_item(str(item_id), int(loot_totals[item_id]), inventory_location_id)
	_complete_productivity_output(state, domain_id, runtime, activity, runs)
	var activity_id := str(activity.get("id", ""))
	state.completed_activities[activity_id] = int(state.completed_activities.get(activity_id, 0)) + runs
	var progression_domain_id := str(activity.get("domain", domain_id)) if domain_id == "construction" else domain_id
	var domain: Dictionary = state.domains[progression_domain_id]
	domain["cycles"] = int(domain.get("cycles", 0)) + runs
	state.statistics["cycles_completed"] = int(state.statistics.get("cycles_completed", 0)) + runs
	if progression_domain_id != "industry":
		domain["xp"] = int(domain.get("xp", 0)) + int(activity.get("xp", 0)) * runs
		_apply_level_ups(progression_domain_id, domain)
	emitted_events.append({"type":"OperationBatchCompleted", "domain":domain_id, "activity_id":activity_id, "runs":runs, "slot":runtime.get("slot", 0)})
	if not _runtime_costs_available(state, domain_id, runtime, activity):
		runtime["status"] = "BLOCKED"
		var block_costs := industry_cycle_costs(state, runtime, activity, false) if domain_id == "industry" else _cost_entries_to_dictionary(activity.get("costs", []))
		runtime["blocked_reason"] = "STORAGE_FULL" if domain_id not in ["construction", "expedition"] and not _activity_storage_available(state, domain_id, runtime, activity, block_costs) else "RESOURCES"
		runtime["progress_ms"] = 0.0


func _apply_combat_damage_to_ships(state: SpaceGameState, combat_result: Dictionary, fallback_ship_ids: Array) -> void:
	var ship_results: Array = combat_result.get("ship_results", [])
	if ship_results.is_empty():
		var damage_share := float(combat_result.get("damage_taken", 0.0)) / maxf(1.0, float(fallback_ship_ids.size()))
		for ship_id in fallback_ship_ids:
			var legacy_ship := state.ship_by_id(str(ship_id))
			if not legacy_ship.is_empty():
				legacy_ship["damage_taken"] = float(legacy_ship.get("damage_taken", 0.0)) + damage_share
				legacy_ship["lifetime_damage"] = float(legacy_ship.get("lifetime_damage", 0.0)) + damage_share
				_record_ship_combat_service(legacy_ship, bool(combat_result.get("victory", false)), 0.0, damage_share)
		return
	for ship_result in ship_results:
		var ship := state.ship_by_id(str(ship_result.get("ship_id", "")))
		if ship.is_empty():
			continue
		var damage := maxf(0.0, float(ship_result.get("damage_taken", 0.0)))
		# Fleet Repair Supplies abstract post-engagement field repairs. They are
		# shared logistics cargo, not per-component maintenance simulation.
		var requested_supplies := mini(int(ceil(damage / 25.0)), state.fleet_supply_quantity("repair_supplies"))
		if requested_supplies > 0 and state.consume_fleet_supply("repair_supplies", requested_supplies):
			damage = maxf(0.0, damage - float(requested_supplies) * 25.0)
		ship["damage_taken"] = float(ship.get("damage_taken", 0.0)) + damage
		ship["lifetime_damage"] = float(ship.get("lifetime_damage", 0.0)) + damage
		_record_ship_combat_service(ship, bool(combat_result.get("victory", false)), float(ship_result.get("damage_dealt", 0.0)), float(ship_result.get("damage_taken", 0.0)))
		if bool(ship_result.get("disabled", false)):
			ship["condition"] = "DISABLED"


func _record_ship_combat_service(ship: Dictionary, victory: bool, damage_dealt: float, damage_taken: float) -> void:
	var record: Dictionary = ship.get("service_record", {})
	record["combat_deployments"] = int(record.get("combat_deployments", 0)) + 1
	record["victories"] = int(record.get("victories", 0)) + (1 if victory else 0)
	record["defeats"] = int(record.get("defeats", 0)) + (0 if victory else 1)
	record["damage_dealt"] = float(record.get("damage_dealt", 0.0)) + maxf(0.0, damage_dealt)
	record["combat_experience"] = float(record.get("combat_experience", 0.0)) + maxf(0.0, damage_dealt) * 0.10 + maxf(0.0, damage_taken) * 0.05 + (10.0 if victory else 2.0)
	ship["service_record"] = record


func _complete_productivity_output(state: SpaceGameState, domain_id: String, runtime: Dictionary, activity: Dictionary, normal_cycles: int = 1) -> int:
	if normal_cycles <= 0 or not bool(activity.get("repeat", true)) or domain_id not in ["mining", "industry"]:
		return 0
	var bonus := activity_productivity_bonus(state, domain_id, activity, runtime)
	if bonus <= 0.0:
		return 0
	var accumulated := float(runtime.get("productivity_progress", 0.0)) + bonus * float(normal_cycles)
	var bonus_cycles := int(floor(accumulated + 0.000001))
	runtime["productivity_progress"] = accumulated - float(bonus_cycles)
	if bonus_cycles <= 0:
		return 0
	var inventory_location_id := _runtime_inventory_location_id(state, domain_id, runtime)
	for reward in activity.get("rewards", []):
		_add_produced_item(state, str(reward.get("item", "")), int(reward.get("quantity", 0)) * bonus_cycles, inventory_location_id)
	emitted_events.append({"type":"ProductivityCycleCompleted", "domain":domain_id, "activity_id":activity.get("id", ""), "cycles":bonus_cycles, "slot":runtime.get("slot", 0)})
	return bonus_cycles


func _add_produced_item(state: SpaceGameState, item_id: String, quantity: int, location_id: String) -> void:
	state.add_item(item_id, quantity, location_id)


func _construction_next_cycle_costs(runtime: Dictionary, activity: Dictionary) -> Dictionary:
	var result := {}
	var next_paid := int(runtime.get("paid_cycles", 0)) + 1
	var consumed: Dictionary = runtime.get("consumed", {})
	for cost in activity.get("costs", []):
		var item_id := str(cost.get("item", ""))
		var total := int(cost.get("quantity", 0))
		var target := int(floor(float(total) * float(next_paid) / 100.0 + 0.000001))
		var due := maxi(0, target - int(consumed.get(item_id, 0)))
		if due > 0:
			result[item_id] = due
	return result


func _complete_construction_cycle(state: SpaceGameState, runtime: Dictionary, activity: Dictionary) -> void:
	var inventory_location_id := _runtime_inventory_location_id(state, "construction", runtime)
	if runtime.get("consumed", null) is not Dictionary:
		runtime["consumed"] = {}
	var due := _construction_next_cycle_costs(runtime, activity)
	for item_id in due:
		if state.available_item_quantity_for_construction(str(item_id), int(runtime.get("slot", 0)), inventory_location_id) < int(due[item_id]):
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "RESOURCES:%s" % item_id
			_sync_megastructure_project(state, runtime, activity, "BLOCKED")
			emitted_events.append({"type":"OperationBlocked", "domain":"construction", "activity_id":activity.get("id", ""), "reason":"resources"})
			return
	for item_id in due:
		state.remove_item(str(item_id), int(due[item_id]), inventory_location_id)
		runtime["consumed"][str(item_id)] = int(runtime.get("consumed", {}).get(str(item_id), 0)) + int(due[item_id])
	runtime["paid_cycles"] = int(runtime.get("paid_cycles", 0)) + 1
	runtime["project_cycles_completed"] = mini(100, int(runtime.get("project_cycles_completed", 0)) + 1)
	runtime["completed_work"] = minf(float(runtime.get("total_work", 100.0)), float(runtime.get("project_cycles_completed", 0)) / 100.0 * float(runtime.get("total_work", 100.0)))
	runtime["productivity_progress"] = 0.0
	_refresh_construction_project_material_state(state, runtime)
	_sync_megastructure_project(state, runtime, activity)
	var progression_domain_id := str(activity.get("domain", "industry"))
	var domain: Dictionary = state.domains[progression_domain_id]
	domain["cycles"] = int(domain.get("cycles", 0)) + 1
	state.statistics["cycles_completed"] = int(state.statistics.get("cycles_completed", 0)) + 1
	emitted_events.append({"type":"ConstructionCycleCompleted", "activity_id":activity.get("id", ""), "segments":runtime.get("project_cycles_completed", 0)})
	if int(runtime.get("project_cycles_completed", 0)) < 100:
		return
	if runtime.get("project_definition", {}).is_empty():
		for effect in activity.get("effects", []):
			_apply_effect(state, effect)
	else:
		_apply_dynamic_construction_completion(state, runtime)
	var activity_id := str(activity.get("id", ""))
	if content.activities.has(activity_id):
		state.completed_activities[activity_id] = int(state.completed_activities.get(activity_id, 0)) + 1
	if progression_domain_id != "industry":
		domain["xp"] = int(domain.get("xp", 0)) + int(activity.get("xp", 0))
		_apply_level_ups(progression_domain_id, domain)
	var completed_project_id := str(runtime.get("project_id", ""))
	var completed_project_type := str(runtime.get("project_type", ""))
	_record_construction_history(state, runtime, "COMPLETE")
	_stop_runtime(state, runtime, "COMPLETE", true)
	normalize_construction_queue(state)
	emitted_events.append({"type":"ConstructionProjectCompleted", "activity_id":activity_id, "project_id":completed_project_id, "project_type":completed_project_type})


func _apply_dynamic_construction_completion(state: SpaceGameState, runtime: Dictionary) -> void:
	var project_type := str(runtime.get("project_type", ""))
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var target_id := str(runtime.get("target_id", ""))
	var target_value := int(runtime.get("target_level", 0))
	if project_type == "FACILITY_EXPANSION":
		var local_industry := state.ensure_location_industry(location_id, target_id, maxi(1, target_value))
		local_industry["level"] = maxi(int(local_industry.get("level", 1)), target_value)
		state.ensure_industrial_operation(location_id, target_id)
		return
	if project_type == "SCALE_STAGE_UPGRADE":
		var local_industry := state.ensure_location_industry(location_id, target_id, maxi(1, target_value))
		local_industry["level"] = maxi(int(local_industry.get("level", 1)), target_value)
		local_industry["scale_stage"] = str(runtime.get("project_definition", {}).get("target_scale_stage", SpaceGameState.scale_stage_for_level(target_value)))
		state.ensure_industrial_operation(location_id, target_id)
		return
	if project_type == "INDUSTRY_SPECIALIZATION":
		if state.has_location(location_id):
			var industry_state: Dictionary = state.location_state(location_id).get("industry", {})
			industry_state["specialization_id"] = target_id
			state.location_state(location_id)["industry"] = industry_state
		return
	if project_type == "INDUSTRIAL_TRANSFORMATION":
		state.adopted_industrial_transformations[target_id] = true
		return
	if project_type in ["STORAGE_UPGRADE", "BULK_STORAGE_UPGRADE", "COMPONENT_STORAGE_UPGRADE", "FLUID_STORAGE_UPGRADE", "SPECIAL_STORAGE_UPGRADE"]:
		if state.has_location(location_id):
			var logistics_state: Dictionary = state.location_state(location_id).get("logistics", {})
			var capacities: Dictionary = logistics_state.get("storage_capacities", {}).duplicate(true)
			capacities[target_id] = maxi(int(capacities.get(target_id, 0)), target_value)
			logistics_state["storage_capacities"] = capacities
			logistics_state["storage_capacity"] = LocationState._total_storage_capacity(capacities)
			state.location_state(location_id)["logistics"] = logistics_state
		return
	var section := "industry" if project_type in ["POWER_UPGRADE", "COOLING_UPGRADE", "STRUCTURE_UPGRADE"] else "logistics"
	if state.has_location(location_id) and not target_id.is_empty():
		var values: Dictionary = state.location_state(location_id).get(section, {})
		values[target_id] = maxi(int(values.get(target_id, 0)), target_value)
		state.location_state(location_id)[section] = values


func _refresh_construction_project_material_state(state: SpaceGameState, runtime: Dictionary, incoming_budget: Dictionary = {}, share_incoming: bool = false) -> void:
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var delivered: Dictionary = runtime.get("consumed", {}).duplicate(true)
	for item_id_value in runtime.get("reserved_costs", {}).keys():
		var item_id := str(item_id_value)
		delivered[item_id] = int(delivered.get(item_id, 0)) + int(runtime.get("reserved_costs", {}).get(item_id, 0))
	var in_transit: Dictionary = {}
	for item_id_value in runtime.get("material_plan", {}).keys():
		var item_id := str(item_id_value)
		var incoming_key := "%s:%s" % [location_id, item_id]
		if not incoming_budget.has(incoming_key):
			incoming_budget[incoming_key] = _incoming_item_quantity(state, location_id, item_id)
		var remaining_need := maxi(0, int(runtime.get("material_plan", {}).get(item_id, 0)) - int(delivered.get(item_id, 0)))
		var allocated_incoming := mini(remaining_need, int(incoming_budget.get(incoming_key, 0)))
		if allocated_incoming > 0:
			in_transit[item_id] = allocated_incoming
			if share_incoming:
				incoming_budget[incoming_key] = int(incoming_budget[incoming_key]) - allocated_incoming
	runtime["delivered_materials"] = delivered
	runtime["in_transit_materials"] = in_transit


func _record_construction_history(state: SpaceGameState, runtime: Dictionary, final_status: String, cancellation_result: Dictionary = {}) -> void:
	state.construction_history.append({
		"project_id":runtime.get("project_id", ""),
		"project_type":runtime.get("project_type", ""),
		"activity_id":runtime.get("activity_id", ""),
		"target_id":runtime.get("target_id", ""),
		"location_id":runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID),
		"start_level":runtime.get("start_level", 0),
		"target_level":runtime.get("target_level", 0),
		"material_plan":runtime.get("material_plan", {}).duplicate(true),
		"consumed":runtime.get("consumed", {}).duplicate(true),
		"status":final_status,
		"cancellation_result":cancellation_result.duplicate(true),
		"finished_at_ms":int(state.total_elapsed_ms)
	})
	if state.construction_history.size() > 100:
		state.construction_history.pop_front()


func _complete_runtime_cycle(state: SpaceGameState, domain_id: String, runtime: Dictionary, activity: Dictionary) -> void:
	if domain_id == "construction":
		_complete_construction_cycle(state, runtime, activity)
		return
	if domain_id == "expedition" and not build_requirements_met(state, activity, runtime.get("assigned_ship_ids", [])):
		_fail_expedition(state, runtime, activity, "BUILD_INSUFFICIENT")
		return
	var combat_result: Dictionary = {}
	if domain_id == "expedition" and str(activity.get("encounter_type", "")) in ["COMBAT", "BOSS"]:
		var persisted_combat_state: Dictionary = runtime.get("combat_state", {})
		combat_result = combat.result(persisted_combat_state) if not persisted_combat_state.is_empty() and str(persisted_combat_state.get("status", "")) != "RUNNING" else combat.resolve(state, runtime.get("assigned_ship_ids", []), str(activity.get("enemy", "")))
		state.combat_log = combat_result.get("log", []).duplicate(true)
		if not bool(combat_result.get("victory", false)):
			_apply_combat_damage_to_ships(state, combat_result, runtime.get("assigned_ship_ids", []))
			_fail_expedition(state, runtime, activity, str(combat_result.get("reason", "FLEET_DISABLED")), combat_result)
			return
		_apply_combat_damage_to_ships(state, combat_result, runtime.get("assigned_ship_ids", []))
		var enemy_id := str(activity.get("enemy", ""))
		state.completed_activities["enemy:%s" % enemy_id] = int(state.completed_activities.get("enemy:%s" % enemy_id, 0)) + 1
		if str(activity.get("encounter_type", "")) == "BOSS":
			state.completed_activities["boss:%s" % enemy_id] = 1
			state.statistics["bosses_defeated"] = int(state.statistics.get("bosses_defeated", 0)) + 1
		emitted_events.append({"type":"EnemyDefeated", "enemy_id":enemy_id, "boss":str(activity.get("encounter_type", "")) == "BOSS", "combat":combat_result})
	if not _runtime_costs_available(state, domain_id, runtime, activity):
		runtime["status"] = "BLOCKED"
		var block_costs := industry_cycle_costs(state, runtime, activity, false) if domain_id == "industry" else _cost_entries_to_dictionary(activity.get("costs", []))
		runtime["blocked_reason"] = "STORAGE_FULL" if domain_id not in ["construction", "expedition"] and not _activity_storage_available(state, domain_id, runtime, activity, block_costs) else "RESOURCES"
		runtime["progress_ms"] = 0.0
		emitted_events.append({"type":"OperationBlocked", "domain":domain_id, "activity_id":activity.get("id", ""), "reason":"resources"})
		return
	var inventory_location_id := _runtime_inventory_location_id(state, domain_id, runtime)
	var cycle_costs := industry_cycle_costs(state, runtime, activity, true) if domain_id == "industry" else _cost_entries_to_dictionary(activity.get("costs", []))
	for item_id in cycle_costs:
		state.remove_item(str(item_id), int(cycle_costs[item_id]), inventory_location_id)
	var reward_totals := {}
	for reward in activity.get("rewards", []):
		var fixed_item_id := str(reward.get("item", ""))
		var fixed_quantity := int(reward.get("quantity", 0))
		if domain_id == "expedition":
			_store_expedition_cargo(state, runtime.get("assigned_ship_ids", []), fixed_item_id, fixed_quantity)
		else:
			_add_produced_item(state, fixed_item_id, fixed_quantity, inventory_location_id)
		reward_totals[fixed_item_id] = int(reward_totals.get(fixed_item_id, 0)) + fixed_quantity
	if domain_id == "industry":
		var waste_totals := industry_cycle_waste(state, runtime, activity, true)
		for waste_item in waste_totals:
			state.add_item(str(waste_item), int(waste_totals[waste_item]), inventory_location_id)
			reward_totals[str(waste_item)] = int(reward_totals.get(str(waste_item), 0)) + int(waste_totals[waste_item])
	# Extraction output is wholly deterministic. Random loot remains available to
	# combat, never to permanent mining sites.
	for loot in ([] if domain_id == "mining" else activity.get("loot", [])):
		if rng.next_float(state, "%s.loot" % domain_id) <= float(loot.get("chance", 0)):
			var loot_quantity := rng.next_int(state, "%s.loot.quantity" % domain_id, int(loot.get("min", 1)), int(loot.get("max", 1)))
			var loot_item_id := str(loot.get("item", ""))
			if domain_id == "expedition":
				_store_expedition_cargo(state, runtime.get("assigned_ship_ids", []), loot_item_id, loot_quantity)
			else:
				state.add_item(loot_item_id, loot_quantity, inventory_location_id)
			reward_totals[loot_item_id] = int(reward_totals.get(loot_item_id, 0)) + loot_quantity
	_complete_productivity_output(state, domain_id, runtime, activity)
	for effect in activity.get("effects", []):
		_apply_effect(state, effect)
	var activity_id := str(activity.get("id", ""))
	state.completed_activities[activity_id] = int(state.completed_activities.get(activity_id, 0)) + 1
	var progression_domain_id := str(activity.get("domain", domain_id)) if domain_id == "construction" else domain_id
	var domain: Dictionary = state.domains[progression_domain_id]
	domain["cycles"] = int(domain.get("cycles", 0)) + 1
	state.statistics["cycles_completed"] = int(state.statistics.get("cycles_completed", 0)) + 1
	if domain_id == "expedition" and activity.get("encounter_type", "") in ["COMBAT", "BOSS"]:
		state.statistics["enemies_defeated"] = int(state.statistics.get("enemies_defeated", 0)) + 1
	# Repeated work records history but never creates RPG-style skill levels.
	domain["xp"] = 0
	domain["level"] = 1
	if domain_id == "industry":
		_record_industry_mastery(state, runtime, activity)
	emitted_events.append({"type":"OperationCycleCompleted", "domain":domain_id, "activity_id":activity_id, "slot":runtime.get("slot", 0)})
	if domain_id == "mining":
		var site_id := str(runtime.get("site_id", activity.get("site", "")))
		var site_runtime: Dictionary = state.mining_site_states.get(site_id, {})
		var site: Dictionary = content.mining_sites.get(site_id, {})
		if not site_runtime.is_empty() and not site.is_empty():
			site_runtime["mastery_cycles"] = int(site_runtime.get("mastery_cycles", 0)) + 1
			var previous_mastery := int(site_runtime.get("mastery_level", 0))
			var cycles_per_level := maxi(1, int(site.get("mastery_cycles_per_level", 1)))
			var max_mastery := maxi(1, int(site.get("max_mastery_level", 1)))
			site_runtime["mastery_level"] = mini(max_mastery, int(site_runtime.get("mastery_cycles", 0)) / cycles_per_level)
			for ship_id in runtime.get("assigned_ship_ids", []):
				var extraction_ship := state.ship_by_id(str(ship_id))
				if not extraction_ship.is_empty():
					extraction_ship["lifetime_output"] = int(extraction_ship.get("lifetime_output", 0)) + 1
					extraction_ship["service_record"]["extraction_cycles"] = int(extraction_ship.get("service_record", {}).get("extraction_cycles", 0)) + 1
			if int(site_runtime.get("mastery_level", 0)) > previous_mastery:
				emitted_events.append({"type":"MiningSiteMasteryIncreased", "site_id":site_id, "level":site_runtime.get("mastery_level", 0)})
	if domain_id == "expedition":
		_record_expedition_report(state, activity, "SUCCESS", "", runtime.get("assigned_ship_ids", []), reward_totals, combat_result)
		runtime["combat_state"] = {}
	if not bool(activity.get("repeat", true)):
		_stop_runtime(state, runtime, "COMPLETE", true)
		if domain_id == "construction":
			normalize_construction_queue(state)
	elif not _runtime_costs_available(state, domain_id, runtime, activity):
		runtime["status"] = "BLOCKED"
		var block_costs := industry_cycle_costs(state, runtime, activity, false) if domain_id == "industry" else _cost_entries_to_dictionary(activity.get("costs", []))
		runtime["blocked_reason"] = "STORAGE_FULL" if domain_id not in ["construction", "expedition"] and not _activity_storage_available(state, domain_id, runtime, activity, block_costs) else "RESOURCES"
		runtime["progress_ms"] = 0.0


func _runtime_available_item_quantity(state: SpaceGameState, domain_id: String, runtime: Dictionary, item_id: String) -> int:
	var location_id := _runtime_inventory_location_id(state, domain_id, runtime)
	if domain_id == "industry":
		return state.available_item_quantity_for_industry(item_id, int(runtime.get("slot", -1)), location_id)
	if domain_id == "construction":
		return state.available_item_quantity_for_construction(item_id, int(runtime.get("slot", -1)), location_id)
	return state.available_item_quantity(item_id, location_id)


func _runtime_inventory_location_id(state: SpaceGameState, domain_id: String, runtime: Dictionary) -> String:
	var explicit_id := str(runtime.get("inventory_location_id", ""))
	if state.has_location(explicit_id):
		return explicit_id
	var runtime_location_id := str(runtime.get("location_id", ""))
	if domain_id == "mining":
		var mining_location: Dictionary = content.mining_locations.get(runtime_location_id, {})
		var region_id := str(mining_location.get("region", ""))
		if state.has_location(region_id):
			return region_id
	if state.has_location(runtime_location_id):
		return runtime_location_id
	return SpaceGameState.MAIN_BASE_LOCATION_ID


func _store_expedition_cargo(state: SpaceGameState, ship_ids: Array, item_id: String, quantity: int) -> int:
	var free_capacity := maxi(0, fleet_cargo_capacity(state, ship_ids) - fleet_cargo_used(state))
	var accepted := mini(maxi(0, quantity), free_capacity)
	if accepted > 0:
		state.add_recovered_cargo(item_id, accepted)
	if accepted < quantity:
		emitted_events.append({"type":"FleetCargoFull", "item_id":item_id, "accepted":accepted, "unrecovered":quantity - accepted})
	return accepted


func _runtime_costs_available(state: SpaceGameState, domain_id: String, runtime: Dictionary, activity: Dictionary) -> bool:
	var costs := industry_cycle_costs(state, runtime, activity, false) if domain_id == "industry" else _cost_entries_to_dictionary(activity.get("costs", []))
	for item_id in costs:
		if _runtime_available_item_quantity(state, domain_id, runtime, str(item_id)) < int(costs[item_id]):
			return false
	if domain_id == "expedition" or domain_id == "construction":
		return true
	return _activity_storage_available(state, domain_id, runtime, activity, costs)


func storage_class_for_item(item_id: String) -> String:
	return str(content.item_storage_profile(item_id).get("storage_class", "SPECIAL"))


func storage_units_for_item(item_id: String) -> float:
	return maxf(0.001, float(content.item_storage_profile(item_id).get("storage_units", 1.0)))


func location_storage_capacities(state: SpaceGameState, location_id: String) -> Dictionary:
	var configured: Dictionary = state.location_state(location_id).get("logistics", {}).get("storage_capacities", {}).duplicate(true)
	var defaults: Dictionary = content.industry_rules.get("storage_classes", {}).get("default_capacities", LocationState.DEFAULT_STORAGE_CAPACITIES)
	for storage_class_value in content.industry_rules.get("storage_classes", {}).get("classes", ["BULK", "COMPONENT", "FLUID", "SPECIAL"]):
		var storage_class := str(storage_class_value)
		configured[storage_class] = maxi(0, int(configured.get(storage_class, defaults.get(storage_class, 0))))
	return configured


func location_storage_used(state: SpaceGameState, location_id: String) -> Dictionary:
	var result := {"BULK":0.0, "COMPONENT":0.0, "FLUID":0.0, "SPECIAL":0.0}
	for item_id_value in state.location_inventory(location_id).keys():
		var item_id := str(item_id_value)
		var storage_class := storage_class_for_item(item_id)
		result[storage_class] = float(result.get(storage_class, 0.0)) + float(state.item_quantity(item_id, location_id)) * storage_units_for_item(item_id)
	return result


func location_storage_snapshot(state: SpaceGameState, location_id: String) -> Dictionary:
	var capacities := location_storage_capacities(state, location_id)
	var used := location_storage_used(state, location_id)
	var rows := {}
	var total_capacity := 0.0
	var total_used := 0.0
	for storage_class_value in capacities.keys():
		var storage_class := str(storage_class_value)
		var capacity := float(capacities.get(storage_class, 0.0))
		var class_used := float(used.get(storage_class, 0.0))
		rows[storage_class] = {"storage_class":storage_class, "used":class_used, "capacity":capacity, "free":maxf(0.0, capacity - class_used), "utilization":class_used / capacity if capacity > 0.0 else (1.0 if class_used > 0.0 else 0.0)}
		total_capacity += capacity
		total_used += class_used
	return {"location_id":location_id, "classes":rows, "used":total_used, "capacity":total_capacity, "free":maxf(0.0, total_capacity - total_used), "utilization":total_used / total_capacity if total_capacity > 0.0 else 0.0}


func storage_can_apply_transaction(state: SpaceGameState, location_id: String, outputs: Dictionary, inputs: Dictionary = {}) -> bool:
	var capacities := location_storage_capacities(state, location_id)
	var used := location_storage_used(state, location_id)
	var deltas := {}
	for item_id_value in outputs.keys():
		var item_id := str(item_id_value)
		var storage_class := storage_class_for_item(item_id)
		deltas[storage_class] = float(deltas.get(storage_class, 0.0)) + float(outputs.get(item_id, 0)) * storage_units_for_item(item_id)
	for item_id_value in inputs.keys():
		var item_id := str(item_id_value)
		var storage_class := storage_class_for_item(item_id)
		deltas[storage_class] = float(deltas.get(storage_class, 0.0)) - float(inputs.get(item_id, 0)) * storage_units_for_item(item_id)
	for storage_class_value in deltas.keys():
		var storage_class := str(storage_class_value)
		if float(used.get(storage_class, 0.0)) + float(deltas.get(storage_class, 0.0)) > float(capacities.get(storage_class, 0.0)) + 0.000001:
			return false
	return true


func _activity_output_totals(state: SpaceGameState, domain_id: String, runtime: Dictionary, activity: Dictionary) -> Dictionary:
	var outputs := {}
	var output_cycles := 1
	if domain_id == "industry":
		var productivity := activity_productivity_bonus(state, domain_id, activity, runtime)
		if float(runtime.get("productivity_progress", 0.0)) + productivity + 0.000001 >= 1.0:
			output_cycles += 1
	for reward_value in activity.get("rewards", []):
		var reward := reward_value as Dictionary
		var item_id := str(reward.get("item", ""))
		outputs[item_id] = int(outputs.get(item_id, 0)) + maxi(0, int(reward.get("quantity", 0))) * output_cycles
	if domain_id == "industry":
		var waste_totals := industry_cycle_waste(state, runtime, activity, false)
		for waste_item in waste_totals:
			outputs[str(waste_item)] = int(outputs.get(str(waste_item), 0)) + int(waste_totals.get(waste_item, 0))
	return outputs


func _activity_storage_available(state: SpaceGameState, domain_id: String, runtime: Dictionary, activity: Dictionary, cycle_costs: Dictionary) -> bool:
	var location_id := _runtime_inventory_location_id(state, domain_id, runtime)
	return storage_can_apply_transaction(state, location_id, _activity_output_totals(state, domain_id, runtime, activity), cycle_costs)


func _industry_storage_available(state: SpaceGameState, runtime: Dictionary, activity: Dictionary, cycle_costs: Dictionary) -> bool:
	return _activity_storage_available(state, "industry", runtime, activity, cycle_costs)


func _cost_entries_to_dictionary(entries: Array) -> Dictionary:
	var result := {}
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := str(entry.get("item", ""))
		result[item_id] = int(result.get(item_id, 0)) + maxi(0, int(entry.get("quantity", 0)))
	return result


func industry_cycle_costs(state: SpaceGameState, runtime: Dictionary, activity: Dictionary, commit_fractional: bool = false) -> Dictionary:
	var location_id := _runtime_inventory_location_id(state, "industry", runtime)
	var facility_id := str(runtime.get("facility_id", activity.get("facility", "")))
	var efficiency := float(industry_mastery_profile(state, location_id, facility_id, str(activity.get("id", ""))).get("material_efficiency", 0.0))
	var fractional: Dictionary = runtime.get("material_savings_fractional", {}).duplicate(true)
	var result := {}
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var base_quantity := maxi(0, int(cost.get("quantity", 0)))
		var accumulated := float(fractional.get(item_id, 0.0)) + float(base_quantity) * efficiency
		var saved := mini(base_quantity, int(floor(accumulated + 0.000001)))
		result[item_id] = maxi(0, base_quantity - saved)
		fractional[item_id] = accumulated - float(saved)
	if commit_fractional:
		runtime["material_savings_fractional"] = fractional
		var fractional_materials: Dictionary = runtime.get("fractional_materials", {})
		fractional_materials["input_savings"] = fractional.duplicate(true)
		runtime["fractional_materials"] = fractional_materials
	return result


func industry_cycle_waste(state: SpaceGameState, runtime: Dictionary, activity: Dictionary, commit_fractional: bool = false) -> Dictionary:
	var location_id := _runtime_inventory_location_id(state, "industry", runtime)
	var facility_id := str(runtime.get("facility_id", activity.get("facility", "")))
	var multiplier := float(industry_mastery_profile(state, location_id, facility_id, str(activity.get("id", ""))).get("waste_multiplier", 1.0))
	var fractional: Dictionary = runtime.get("waste_fractional", {}).duplicate(true)
	var result := {}
	for waste_value in activity.get("waste", []):
		var waste := waste_value as Dictionary
		var item_id := str(waste.get("item", ""))
		var accumulated := float(fractional.get(item_id, 0.0)) + float(maxi(0, int(waste.get("quantity", 0)))) * multiplier
		var produced := int(floor(accumulated + 0.000001))
		result[item_id] = produced
		fractional[item_id] = accumulated - float(produced)
	if commit_fractional:
		runtime["waste_fractional"] = fractional
		var fractional_materials: Dictionary = runtime.get("fractional_materials", {})
		fractional_materials["waste"] = fractional.duplicate(true)
		runtime["fractional_materials"] = fractional_materials
	return result


func _record_industry_mastery(state: SpaceGameState, runtime: Dictionary, activity: Dictionary) -> void:
	var location_id := _runtime_inventory_location_id(state, "industry", runtime)
	var facility_id := str(runtime.get("facility_id", activity.get("facility", "")))
	var local_industry := state.ensure_location_industry(location_id, facility_id, 1)
	if local_industry.is_empty():
		return
	local_industry["production_method_id"] = str(activity.get("id", ""))
	local_industry["expertise_cycles"] = int(local_industry.get("expertise_cycles", 0)) + 1
	local_industry["expertise_level"] = mini(int(content.industry_rules.get("max_expertise_level", 20)), int(local_industry.get("expertise_cycles", 0)) / maxi(1, int(content.industry_rules.get("expertise_cycles_per_level", 100))))
	var mastery_by_product: Dictionary = local_industry.get("product_mastery", {})
	var activity_id := str(activity.get("id", ""))
	var mastery: Dictionary = mastery_by_product.get(activity_id, {"cycles":0, "level":0})
	mastery["cycles"] = int(mastery.get("cycles", 0)) + 1
	mastery["level"] = mini(int(content.industry_rules.get("max_mastery_level", 20)), int(mastery.get("cycles", 0)) / maxi(1, int(content.industry_rules.get("mastery_cycles_per_level", 20))))
	mastery_by_product[activity_id] = mastery
	local_industry["product_mastery"] = mastery_by_product


func _fail_expedition(state: SpaceGameState, runtime: Dictionary, activity: Dictionary, reason: String, combat_result: Dictionary = {}) -> void:
	var ship_ids: Array = runtime.get("assigned_ship_ids", []).duplicate()
	if reason in ["AMMUNITION_DEPLETED", "RETREAT_POLICY"]:
		for ship_id in ship_ids:
			var returning_ship := state.ship_by_id(str(ship_id))
			if not returning_ship.is_empty():
				if float(returning_ship.get("damage_taken", 0.0)) > 0.0 or str(returning_ship.get("condition", "")) == "DISABLED":
					returning_ship["status"] = "REPAIRING"
					returning_ship["repair_remaining_ms"] = clampf(float(returning_ship.get("damage_taken", 0.0)) * 250.0, 1000.0, 120000.0)
					returning_ship["assignment"] = {"type":"STARPORT_REPAIR", "source_activity":activity.get("id", "")}
				else:
					returning_ship["status"] = "DOCKED"
					returning_ship["assignment"] = {"domain":"expedition", "fleet":"default"}
		_record_expedition_report(state, activity, "RETURNED", reason, ship_ids, {}, combat_result)
		state.unload_fleet_cargo("expedition", false)
		runtime["activity_id"] = ""
		runtime["status"] = "IDLE"
		runtime["phase"] = "RETURNED_TO_STARPORT"
		runtime["assigned_ship_ids"] = []
		runtime["combat_state"] = {}
		emitted_events.append({"type":"ExpeditionReturnedForLogistics", "activity_id":activity.get("id", ""), "reason":reason, "ship_ids":ship_ids})
		return
	var repair_ms := float(activity.get("failure_repair_ms", 30000.0))
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if ship.is_empty():
			continue
		ship["condition"] = "DISABLED"
		ship["status"] = "REPAIRING"
		ship["repair_remaining_ms"] = repair_ms
		ship["assignment"] = {"type":"STARPORT_REPAIR", "source_activity":activity.get("id", "")}
	state.statistics["expeditions_failed"] = int(state.statistics.get("expeditions_failed", 0)) + 1
	_record_expedition_report(state, activity, "FAILED", reason, ship_ids, {}, combat_result)
	runtime["activity_id"] = ""
	runtime["progress_ms"] = 0.0
	runtime["cycle_progress"] = 0.0
	runtime["productivity_progress"] = 0.0
	runtime["project_cycles_completed"] = 0
	runtime["paid_cycles"] = 0
	runtime["consumed"] = {}
	runtime["material_savings_fractional"] = {}
	runtime["waste_fractional"] = {}
	runtime["fractional_materials"] = {}
	runtime["status"] = "FAILED"
	runtime["phase"] = "RETURNED_TO_STARPORT"
	runtime["assigned_ship_ids"] = []
	runtime["combat_state"] = {}
	emitted_events.append({"type":"ExpeditionFailed", "activity_id":activity.get("id", ""), "reason":reason, "repair_ms":repair_ms, "ship_ids":ship_ids})


func _record_expedition_report(state: SpaceGameState, activity: Dictionary, result: String, reason: String, ship_ids: Array, rewards: Dictionary = {}, combat_result: Dictionary = {}) -> void:
	state.expedition_reports.append({
		"activity_id":activity.get("id", ""),
		"encounter_type":activity.get("encounter_type", "DISCOVERY"),
		"enemy_id":activity.get("enemy", ""),
		"result":result,
		"reason":reason,
		"rewards":rewards.duplicate(true),
		"combat":combat_result.duplicate(true),
		"ship_ids":ship_ids.duplicate(),
		"completed_at_ms":int(state.total_elapsed_ms)
	})
	if state.expedition_reports.size() > 20:
		state.expedition_reports.pop_front()


func _apply_level_ups(domain_id: String, domain: Dictionary) -> void:
	var previous := int(domain.get("level", 1))
	var level := previous
	while int(domain.get("xp", 0)) >= xp_for_level(level + 1):
		level += 1
	domain["level"] = level
	if level > previous:
		emitted_events.append({"type":"DomainLeveledUp", "domain":domain_id, "level":level})


func xp_for_level(level: int) -> int:
	if level <= 1:
		return 0
	return 250 * (level - 1) * (level - 1)


func _apply_effect(state: SpaceGameState, effect: Dictionary) -> void:
	match str(effect.get("type", "")):
		"grant_spillover":
			var technology_id := str(effect.get("id", ""))
			state.technology_spillovers[technology_id] = true
			state.technologies[technology_id] = true
			emitted_events.append({"type":"SpilloverTechnologyGranted", "technology_id":technology_id})
		"set_experimental_maturity":
			var maturity_rank := {"THEORY":0, "LAB_SAMPLE":1, "EXPERIMENTAL":2, "PILOT":3, "INDUSTRIAL":4}
			var item_id := str(effect.get("item", ""))
			var maturity := str(effect.get("maturity", "EXPERIMENTAL"))
			if int(maturity_rank.get(maturity, 0)) >= int(maturity_rank.get(str(state.experimental_maturity.get(item_id, "THEORY")), 0)):
				state.experimental_maturity[item_id] = maturity
		"unlock_industrial_transformation":
			state.unlocked_industrial_transformations[str(effect.get("id", ""))] = true
		"unlock_region":
			var region_id := str(effect.get("region", ""))
			state.regions[region_id] = true
			var region_runtime: Dictionary = state.region_states.get(region_id, {})
			region_runtime["discovered"] = true
			region_runtime["state"] = str(effect.get("state", region_runtime.get("state", "SURVEYED")))
			state.region_states[region_id] = region_runtime
		"set_region_state":
			var region_id := str(effect.get("region", ""))
			var region_runtime: Dictionary = state.region_states.get(region_id, {})
			region_runtime["discovered"] = true
			var field := str(effect.get("field", "state"))
			var value := str(effect.get("value", effect.get("state", "SURVEYED")))
			region_runtime[field] = value
			region_runtime["state"] = value
			state.region_states[region_id] = region_runtime
		"discover_mining_site":
			var site_id := str(effect.get("id", ""))
			var site_runtime: Dictionary = state.mining_site_states.get(site_id, {})
			var site: Dictionary = content.mining_sites.get(site_id, {})
			site_runtime["discovered"] = true
			site_runtime["state"] = "DEFERRED" if bool(site.get("deferred", false)) else "AVAILABLE"
			state.mining_site_states[site_id] = site_runtime
		"unlock_combat_area":
			var area_id := str(effect.get("id", ""))
			var area_runtime: Dictionary = state.combat_area_states.get(area_id, {})
			area_runtime["unlocked"] = true
			state.combat_area_states[area_id] = area_runtime
		"unlock_extraction_network":
			var network_id := str(effect.get("id", ""))
			var network_runtime: Dictionary = state.extraction_network_states.get(network_id, {})
			network_runtime["unlocked"] = true
			network_runtime["status"] = "IDLE"
			network_runtime["level"] = maxi(1, int(network_runtime.get("level", 1)))
			state.extraction_network_states[network_id] = network_runtime
		"upgrade_extraction_network":
			var network_id := str(effect.get("id", ""))
			var network_runtime: Dictionary = state.extraction_network_states.get(network_id, {})
			network_runtime["level"] = maxi(1, int(network_runtime.get("level", 1))) + int(effect.get("levels", 1))
			state.extraction_network_states[network_id] = network_runtime
		"upgrade_extraction_command":
			state.extraction_command["capacity"] = maxi(state.extraction_command_capacity(), int(effect.get("capacity", state.extraction_command_capacity())))
		"grant_special_equipment":
			var equipment_id := state.create_equipment_instance(str(effect.get("id", "")), "MISSION_REWARD")
			emitted_events.append({"type":"SpecialEquipmentRecovered", "equipment_id":equipment_id, "definition_id":effect.get("id", "")})
		"unlock_facility":
			var facility_id := str(effect.get("facility", ""))
			var runtime := {"level":1, "status":"ACTIVE"}
			if int(content.facilities.get(facility_id, {}).get("manufacturing_generation", 0)) > 0:
				runtime["installed_process_modules"] = []
				runtime["installed_plugins"] = []
			state.facilities[facility_id] = runtime
		"upgrade_facility":
			var facility_id := str(effect.get("facility", ""))
			if state.facilities.has(facility_id):
				state.facilities[facility_id]["level"] = int(state.facilities[facility_id].get("level", 1)) + int(effect.get("levels", 1))
		"unlock_site":
			state.infrastructure_sites[str(effect.get("id", ""))] = true
		"grant_technology":
			state.technologies[str(effect.get("id", ""))] = true
		"add_ship":
			state.add_unique_ship(str(effect.get("ship", "")), effect.get("modules", []))
		"unlock_ship_plan":
			var plan_id := str(effect.get("id", ""))
			var newly_unlocked := state.unlock_ship_plan(plan_id)
			if bool(effect.get("auto_enqueue", true)):
				state.enqueue_ship_plan(plan_id)
			normalize_shipyard_queue(state)
			if newly_unlocked:
				emitted_events.append({"type":"ShipPlanUnlocked", "plan_id":plan_id})
		"complete_megastructure":
			state.megastructures[str(effect.get("id", ""))] = true
		"major_discovery":
			state.major_discoveries[str(effect.get("id", ""))] = true
		"complete_game":
			state.game_complete = true
			state.completed_at_ms = int(state.total_elapsed_ms)
			emitted_events.append({"type":"GameCompleted", "completed_at_ms":state.completed_at_ms})
		"set_automation_rate":
			state.automation["rates"][str(effect.get("item", ""))] = float(effect.get("per_second", 0.0))
		"set_progression_tier":
			state.progression_tier = maxi(state.progression_tier, int(effect.get("tier", 1)))
		"set_resource_maturity":
			state.set_resource_maturity(str(effect.get("item", "")), str(effect.get("maturity", "FRONTIER")))
		"configure_background_mining":
			var mining_item := str(effect.get("item", ""))
			state.background_economy["mining_sources"][mining_item] = {
				"source_id":str(effect.get("source_id", "infrastructure")),
				"facility_id":str(effect.get("facility_id", "")),
				"per_second":maxf(0.0, float(effect.get("per_second", 0.0))),
				"enabled":bool(effect.get("enabled", true))
			}
			if effect.has("target"):
				state.set_background_target(mining_item, int(effect.get("target", 0)))
			if effect.has("priority"):
				state.set_background_priority(mining_item, int(effect.get("priority", 50)))
		"configure_industry_network":
			var family := str(effect.get("family", ""))
			var existing: Dictionary = state.background_economy["industry_networks"].get(family, {})
			existing["level"] = maxi(int(existing.get("level", 0)), int(effect.get("level", 1)))
			existing["capacity_per_second"] = maxf(float(existing.get("capacity_per_second", 0.0)), float(effect.get("capacity_per_second", 0.0)))
			existing["enabled"] = bool(effect.get("enabled", true))
			if effect.has("facility_id"):
				existing["facility_id"] = str(effect.get("facility_id", ""))
			existing["recipes"] = existing.get("recipes", {}).duplicate(true)
			state.background_economy["industry_networks"][family] = existing
		"enable_background_recipe":
			var recipe_id := str(effect.get("activity", ""))
			var recipe: Dictionary = content.activities.get(recipe_id, {})
			var recipe_family := str(effect.get("family", recipe.get("production_family", "")))
			var network: Dictionary = state.background_economy["industry_networks"].get(recipe_family, {
				"level":1, "capacity_per_second":0.0, "enabled":true, "recipes":{}
			})
			var recipes: Dictionary = network.get("recipes", {}).duplicate(true)
			recipes[recipe_id] = {"enabled":bool(effect.get("enabled", true))}
			network["recipes"] = recipes
			state.background_economy["industry_networks"][recipe_family] = network
			var reward_item := _primary_reward_item(recipe)
			if not reward_item.is_empty():
				state.set_background_target(reward_item, int(effect.get("target", state.background_economy["targets"].get(reward_item, 0))))
				state.set_background_priority(reward_item, int(effect.get("priority", state.background_economy["priorities"].get(reward_item, 50))))


func _progress_location_industrial_automation(state: SpaceGameState, elapsed_ms: float) -> void:
	# Retained as a no-op migration entry point. Automatic expansion is outside
	# the first phase-seven automation scope.
	return


func _progress_automation(state: SpaceGameState, elapsed_ms: float) -> void:
	var fractions: Dictionary = state.automation.get("fractional", {})
	for item_id in state.automation.get("rates", {}):
		var total := float(fractions.get(item_id, 0.0)) + float(state.automation.rates[item_id]) * simulation_speed_multiplier("automation") * elapsed_ms / 1000.0
		var produced := int(floor(total))
		if produced > 0:
			state.add_item(str(item_id), produced)
			total -= float(produced)
		fractions[item_id] = total
	state.automation["fractional"] = fractions


func _progress_energy_maintenance(state: SpaceGameState, elapsed_ms: float) -> void:
	if elapsed_ms <= 0.0:
		return
	var fractional: Dictionary = state.energy_system.get("maintenance_fractional", {})
	var coverage: Dictionary = state.energy_system.get("maintenance_coverage", {})
	for facility_value in state.facilities.keys():
		var facility_id := str(facility_value)
		if str(state.facilities[facility_id].get("status", "")) != "ACTIVE":
			continue
		var definition: Dictionary = content.facilities.get(facility_id, {})
		var item_id := str(definition.get("advanced_maintenance_item", ""))
		var per_hour := maxf(0.0, float(definition.get("advanced_maintenance_per_hour", 0.0)))
		if item_id.is_empty() or per_hour <= 0.0:
			continue
		var required := float(fractional.get(facility_id, 0.0)) + per_hour * elapsed_ms / 3600000.0
		var due := int(floor(required))
		fractional[facility_id] = required - float(due)
		if due <= 0:
			coverage[facility_id] = float(coverage.get(facility_id, 1.0))
			continue
		var consumed := mini(due, state.available_item_quantity(item_id))
		if consumed > 0:
			state.remove_item(item_id, consumed)
		# Missing maintenance reduces high-performance output but never disables
		# emergency generation or creates repayment debt that could deadlock recovery.
		coverage[facility_id] = clampf(float(consumed) / float(due), 0.0, 1.0)
	state.energy_system["maintenance_fractional"] = fractional
	state.energy_system["maintenance_coverage"] = coverage


func _energy_maintenance_snapshot(state: SpaceGameState) -> Array:
	var rows: Array = []
	for facility_value in state.facilities.keys():
		var facility_id := str(facility_value)
		if str(state.facilities[facility_id].get("status", "")) != "ACTIVE":
			continue
		var definition: Dictionary = content.facilities.get(facility_id, {})
		var item_id := str(definition.get("advanced_maintenance_item", ""))
		var demand := maxf(0.0, float(definition.get("advanced_maintenance_per_hour", 0.0)))
		if item_id.is_empty() or demand <= 0.0:
			continue
		var coverage := clampf(float(state.energy_system.get("maintenance_coverage", {}).get(facility_id, 1.0)), 0.0, 1.0)
		var status := "HEALTHY" if coverage >= 0.999 else ("STRAINED" if coverage >= 0.75 else ("DEGRADED" if coverage >= 0.25 else "CRITICAL"))
		var available := state.available_item_quantity(item_id)
		var automated := _background_automation_enabled_for_item(state, item_id)
		var runway_hours := float(available) / demand
		rows.append({
			"facility_id":facility_id,
			"item_id":item_id,
			"demand_per_hour":demand,
			"coverage":coverage,
			"status":status,
			"stock":state.item_quantity(item_id),
			"available":available,
			"reserve":int(state.location_reserves().get(item_id, 0)),
			"target":int(state.background_economy.get("targets", {}).get(item_id, 0)),
			"runway_hours":runway_hours,
			"automated":automated,
			"attention":coverage < 0.999 or (runway_hours < 6.0 and not automated)
		})
	return rows


func _background_automation_enabled_for_item(state: SpaceGameState, item_id: String) -> bool:
	for family_value in state.background_economy.get("industry_networks", {}).keys():
		var family := str(family_value)
		var network: Dictionary = state.background_economy["industry_networks"].get(family, {})
		if not bool(network.get("enabled", true)):
			continue
		for recipe_value in network.get("recipes", {}).keys():
			var recipe_id := str(recipe_value)
			if not bool(network.get("recipes", {}).get(recipe_id, {}).get("enabled", true)):
				continue
			var recipe: Dictionary = content.activities.get(recipe_id, {})
			if _primary_reward_item(recipe) != item_id or not _background_recipe_eligible(state, family, recipe):
				continue
			var inputs_ready := true
			for cost in recipe.get("costs", []):
				if state.available_item_quantity(str(cost.get("item", ""))) < int(cost.get("quantity", 0)):
					inputs_ready = false
					break
			if inputs_ready:
				return true
	return false


func _progress_background_economy(state: SpaceGameState, elapsed_ms: float) -> void:
	if elapsed_ms <= 0.0:
		return
	var background: Dictionary = state.background_economy
	var fractions: Dictionary = background.get("fractional", {})
	var produced_totals: Dictionary = background.get("production_totals", {})
	var consumed_totals: Dictionary = background.get("consumption_totals", {})
	var mining_potential := {}

	# Mature mining infrastructure is a stable source and does not occupy an
	# Active Frontier Mining slot or a ship. Potential output is made available
	# to background consumers for the whole batch, then unused excess above the
	# stock target is discarded. This preserves continuous offline flow without
	# replaying seconds or banking idle capacity.
	for item_id in background.get("mining_sources", {}):
		var source: Dictionary = background["mining_sources"][item_id]
		if not bool(source.get("enabled", true)):
			continue
		var source_facility_id := str(source.get("facility_id", ""))
		var source_multiplier := facility_output_multiplier(state, source_facility_id)
		var fraction_key := "mining:%s" % item_id
		var total := float(fractions.get(fraction_key, 0.0)) + float(source.get("per_second", 0.0)) * source_multiplier * simulation_speed_multiplier("mining") * elapsed_ms / 1000.0
		var potential := int(floor(total))
		if potential > 0:
			state.location_inventory()[item_id] = state.item_quantity(str(item_id)) + potential
			mining_potential[item_id] = potential
			total -= float(potential)
		fractions[fraction_key] = total

	# Background industry owns separate capacity. Priority only chooses which
	# under-target mature recipe receives that capacity first.
	var family_ids: Array = background.get("industry_networks", {}).keys()
	family_ids.sort()
	for family_value in family_ids:
		var family := str(family_value)
		var network: Dictionary = background["industry_networks"][family]
		if not bool(network.get("enabled", true)):
			continue
		var network_facility_id := str(network.get("facility_id", ""))
		var capacity := maxf(0.0, float(network.get("capacity_per_second", 0.0))) * facility_output_multiplier(state, network_facility_id) * simulation_speed_multiplier("automation")
		if capacity <= 0.0:
			continue
		var work_key := "industry:%s" % family
		var available_work := float(fractions.get(work_key, 0.0)) + capacity * elapsed_ms / 1000.0
		var recipe_ids: Array = network.get("recipes", {}).keys()
		recipe_ids.sort_custom(func(a, b):
			var a_item := _primary_reward_item(content.activities.get(str(a), {}))
			var b_item := _primary_reward_item(content.activities.get(str(b), {}))
			var a_priority := int(background.get("priorities", {}).get(a_item, 50))
			var b_priority := int(background.get("priorities", {}).get(b_item, 50))
			return a_priority > b_priority if a_priority != b_priority else str(a) < str(b)
		)
		var smallest_work := INF
		for recipe_value in recipe_ids:
			var recipe_id := str(recipe_value)
			var recipe_config: Dictionary = network.get("recipes", {}).get(recipe_id, {})
			if not bool(recipe_config.get("enabled", true)):
				continue
			var recipe: Dictionary = content.activities.get(recipe_id, {})
			if recipe.is_empty() or str(recipe.get("domain", "")) != "industry":
				continue
			if not _background_recipe_eligible(state, family, recipe):
				continue
			var work_required := maxf(0.001, float(recipe.get("work_required", 1.0)))
			smallest_work = minf(smallest_work, work_required)
			var reward_item := _primary_reward_item(recipe)
			var reward_quantity := _primary_reward_quantity(recipe)
			if reward_item.is_empty() or reward_quantity <= 0:
				continue
			var target := int(background.get("targets", {}).get(reward_item, 0))
			if target <= 0:
				continue
			var deficit := maxi(0, target - state.item_quantity(reward_item))
			var runs := mini(int(floor(available_work / work_required)), int(ceil(float(deficit) / float(reward_quantity))))
			for cost in recipe.get("costs", []):
				var cost_quantity := int(cost.get("quantity", 0))
				if cost_quantity > 0:
					runs = mini(runs, state.available_item_quantity(str(cost.get("item", ""))) / cost_quantity)
			if runs <= 0:
				continue
			for cost in recipe.get("costs", []):
				var cost_item := str(cost.get("item", ""))
				var consumed := int(cost.get("quantity", 0)) * runs
				state.remove_item(cost_item, consumed)
				consumed_totals[cost_item] = int(consumed_totals.get(cost_item, 0)) + consumed
			var produced := mini(deficit, reward_quantity * runs)
			state.add_item(reward_item, produced)
			produced_totals[reward_item] = int(produced_totals.get(reward_item, 0)) + produced
			available_work -= work_required * float(runs)
			if available_work < 0.001:
				break
		# Idle capacity is not banked. Only sub-cycle fractional work survives.
		fractions[work_key] = available_work if smallest_work == INF else fmod(maxf(0.0, available_work), smallest_work)
	for item_id in mining_potential:
		var potential := int(mining_potential[item_id])
		var target := int(background.get("targets", {}).get(item_id, 0))
		var discarded := 0
		if target > 0:
			discarded = mini(potential, maxi(0, state.item_quantity(str(item_id)) - target))
			if discarded > 0:
				state.location_inventory()[item_id] = state.item_quantity(str(item_id)) - discarded
		var actual := potential - discarded
		if actual > 0:
			state.statistics["items_produced"] = int(state.statistics.get("items_produced", 0)) + actual
			produced_totals[item_id] = int(produced_totals.get(item_id, 0)) + actual
	background["fractional"] = fractions
	background["production_totals"] = produced_totals
	background["consumption_totals"] = consumed_totals
	state.background_economy = background


func background_economy_snapshot(state: SpaceGameState) -> Array:
	var rows := {}
	var background: Dictionary = state.background_economy
	for item_id in background.get("mining_sources", {}):
		var source: Dictionary = background["mining_sources"][item_id]
		var source_facility_id := str(source.get("facility_id", ""))
		if bool(source.get("enabled", true)):
			_add_flow(rows, str(item_id), float(source.get("per_second", 0.0)) * facility_output_multiplier(state, source_facility_id) * simulation_speed_multiplier("mining") * 3600.0, 0.0)
	for item_id in state.automation.get("rates", {}):
		_add_flow(rows, str(item_id), float(state.automation.rates[item_id]) * simulation_speed_multiplier("automation") * 3600.0, 0.0)
	for maintenance in _energy_maintenance_snapshot(state):
		_add_flow(rows, str(maintenance.get("item_id", "")), 0.0, float(maintenance.get("demand_per_hour", 0.0)))
	for family in background.get("industry_networks", {}):
		var network: Dictionary = background["industry_networks"][family]
		if not bool(network.get("enabled", true)):
			continue
		var network_facility_id := str(network.get("facility_id", ""))
		var selected := _selected_background_recipe(state, str(family), network)
		if selected.is_empty():
			continue
		var work_required := maxf(0.001, float(selected.get("work_required", 1.0)))
		var runs_per_hour := float(network.get("capacity_per_second", 0.0)) * facility_output_multiplier(state, network_facility_id) * simulation_speed_multiplier("automation") * 3600.0 / work_required
		for reward in selected.get("rewards", []):
			_add_flow(rows, str(reward.get("item", "")), float(reward.get("quantity", 0)) * runs_per_hour, 0.0)
		for cost in selected.get("costs", []):
			_add_flow(rows, str(cost.get("item", "")), 0.0, float(cost.get("quantity", 0)) * runs_per_hour)
	for item_id in background.get("targets", {}):
		if not rows.has(item_id):
			rows[item_id] = {"production_per_hour":0.0, "demand_per_hour":0.0}
	var result: Array = []
	for item_id in rows:
		var row: Dictionary = rows[item_id]
		row["item_id"] = str(item_id)
		row["net_per_hour"] = float(row.get("production_per_hour", 0.0)) - float(row.get("demand_per_hour", 0.0))
		row["stock"] = state.item_quantity(str(item_id))
		row["target"] = int(background.get("targets", {}).get(item_id, 0))
		row["priority"] = int(background.get("priorities", {}).get(item_id, 50))
		row["maturity"] = state.resource_maturity_state(str(item_id))
		row["attention"] = int(row["target"]) > 0 and int(row["stock"]) < int(row["target"]) and float(row["net_per_hour"]) <= 0.0
		result.append(row)
	result.sort_custom(func(a, b): return str(a.get("item_id", "")) < str(b.get("item_id", "")))
	return result


func _selected_background_recipe(state: SpaceGameState, family: String, network: Dictionary) -> Dictionary:
	var candidates: Array = []
	for recipe_id in network.get("recipes", {}):
		if not bool(network.get("recipes", {}).get(recipe_id, {}).get("enabled", true)):
			continue
		var recipe: Dictionary = content.activities.get(str(recipe_id), {})
		if not _background_recipe_eligible(state, family, recipe):
			continue
		var item_id := _primary_reward_item(recipe)
		var target := int(state.background_economy.get("targets", {}).get(item_id, 0))
		if target > state.item_quantity(item_id):
			candidates.append(recipe)
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a, b):
		var a_item := _primary_reward_item(a)
		var b_item := _primary_reward_item(b)
		var a_priority := int(state.background_economy.get("priorities", {}).get(a_item, 50))
		var b_priority := int(state.background_economy.get("priorities", {}).get(b_item, 50))
		return a_priority > b_priority if a_priority != b_priority else str(a.get("id", "")) < str(b.get("id", ""))
	)
	return candidates[0]


func _background_recipe_eligible(state: SpaceGameState, family: String, recipe: Dictionary) -> bool:
	if recipe.is_empty() or not bool(recipe.get("automation_eligible", false)):
		return false
	if str(recipe.get("automation_category", recipe.get("production_family", ""))) != family:
		return false
	var unlock := str(recipe.get("automation_unlock", ""))
	if not unlock.is_empty() and not bool(state.technologies.get(unlock, false)):
		return false
	var reward_item := _primary_reward_item(recipe)
	return not reward_item.is_empty() and state.resource_maturity_state(reward_item) in ["MANAGED", "BACKGROUND"]


func _add_flow(rows: Dictionary, item_id: String, production: float, demand: float) -> void:
	if item_id.is_empty():
		return
	var row: Dictionary = rows.get(item_id, {"production_per_hour":0.0, "demand_per_hour":0.0})
	row["production_per_hour"] = float(row.get("production_per_hour", 0.0)) + production
	row["demand_per_hour"] = float(row.get("demand_per_hour", 0.0)) + demand
	rows[item_id] = row


func _primary_reward_item(activity: Dictionary) -> String:
	var rewards: Array = activity.get("rewards", [])
	return str(rewards[0].get("item", "")) if not rewards.is_empty() else ""


func _primary_reward_quantity(activity: Dictionary) -> int:
	var rewards: Array = activity.get("rewards", [])
	return int(rewards[0].get("quantity", 0)) if not rewards.is_empty() else 0


func initialize_research_program(state: SpaceGameState, project: Dictionary, route_id: String = "", supplemental_route: bool = false) -> void:
	var selected_route := route_id if not route_id.is_empty() else default_research_route_id(project)
	state.research = SpaceGameState.empty_research_program()
	state.research.merge({
		"status":"RUNNING", "project_id":project.get("id", ""), "route_id":selected_route,
		"supplemental_route":supplemental_route, "location_id":SpaceGameState.MAIN_BASE_LOCATION_ID
	}, true)
	_sync_research_stage_runtime(state, project)
	_ensure_research_reservations(state)


func _sync_research_stage_runtime(state: SpaceGameState, project: Dictionary) -> void:
	var runtime: Dictionary = state.research
	var stage := research_stage_definition(state, project, int(runtime.get("stage_index", 0)), str(runtime.get("route_id", "")))
	if stage.is_empty():
		return
	runtime["stage_id"] = str(stage.get("id", ""))
	runtime["stage_kind"] = str(stage.get("kind", "THEORY"))
	runtime["duration_ms"] = maxf(1.0, float(stage.get("work_required", 1.0)))
	runtime["progress_ms"] = _research_completed_work(state, project, int(runtime.get("stage_index", 0))) + float(runtime.get("stage_progress_ms", 0.0))


func _normalize_research_runtime(state: SpaceGameState, project: Dictionary) -> void:
	var runtime: Dictionary = state.research
	runtime.merge(SpaceGameState.empty_research_program(), false)
	if runtime.has("legacy_project_progress_ms"):
		var legacy_fraction := clampf(float(runtime.get("legacy_project_progress_ms", 0.0)) / maxf(1.0, float(project.get("duration_ms", 1.0))), 0.0, 1.0)
		var total_work := 0.0
		for index in research_stages(project).size():
			total_work += maxf(0.0, float(research_stage_definition(state, project, index, str(runtime.get("route_id", ""))).get("work_required", 0.0)))
		var target_work := total_work * legacy_fraction
		var selected_index := 0
		for index in research_stages(project).size():
			var stage := research_stage_definition(state, project, index, str(runtime.get("route_id", "")))
			var stage_work := maxf(0.0, float(stage.get("work_required", 0.0)))
			if target_work > stage_work + 0.001 and index + 1 < research_stages(project).size():
				_apply_research_stage_effects(state, project, stage)
				target_work -= stage_work
				selected_index = index + 1
			else:
				selected_index = index
				break
		runtime["stage_index"] = selected_index
		runtime["stage_progress_ms"] = target_work
		runtime["stage_consumed"] = {}
		runtime.erase("legacy_project_progress_ms")
	_sync_research_stage_runtime(state, project)


func _research_completed_work(state: SpaceGameState, project: Dictionary, stage_index: int) -> float:
	var total := 0.0
	for index in mini(stage_index, research_stages(project).size()):
		total += maxf(0.0, float(research_stage_definition(state, project, index, str(state.research.get("route_id", ""))).get("work_required", 0.0)))
	return total


func _research_gate_reason(state: SpaceGameState, stage: Dictionary) -> String:
	if research_capacity(state) + 0.000001 < float(stage.get("capacity_required", 1.0)):
		return "RESEARCH_CAPACITY"
	for requirement_value in stage.get("requirements", []):
		var requirement := requirement_value as Dictionary
		if requirement_met(state, requirement):
			continue
		if str(stage.get("kind", "")) == "FIELD_TEST":
			return "FIELD_TEST:%s:%s" % [requirement.get("type", "requirement"), requirement.get("id", requirement.get("domain", ""))]
		if str(requirement.get("type", "")) in ["technology_domain", "research_capacity"]:
			return "KNOWLEDGE:%s" % requirement.get("domain", "research_capacity")
		return "GATE:%s:%s" % [requirement.get("type", "requirement"), requirement.get("id", requirement.get("domain", ""))]
	for requirement_value in stage.get("operating_conditions", []):
		var requirement := requirement_value as Dictionary
		if not requirement_met(state, requirement):
			return "OPERATING:%s" % requirement.get("id", requirement.get("type", "condition"))
	return ""


func _research_boundary_ms(state: SpaceGameState, project: Dictionary) -> float:
	_normalize_research_runtime(state, project)
	var runtime: Dictionary = state.research
	var stage := research_stage_definition(state, project, int(runtime.get("stage_index", 0)), str(runtime.get("route_id", "")))
	if stage.is_empty():
		return 0.001
	var gate_reason := _research_gate_reason(state, stage)
	if not gate_reason.is_empty():
		runtime["status"] = "BLOCKED"
		runtime["blocked_reason"] = gate_reason
		return INF
	if str(stage.get("kind", "")) == "FIELD_TEST":
		return 0.001
	var work_required := maxf(1.0, float(stage.get("work_required", 1.0)))
	var progress := float(runtime.get("stage_progress_ms", 0.0))
	var rate := research_rate(state)
	if rate <= 0.0:
		runtime["status"] = "BLOCKED"
		runtime["blocked_reason"] = "RESEARCH_CAPACITY"
		return INF
	var result := maxf(0.001, (work_required - progress) / rate)
	var consumed: Dictionary = runtime.get("stage_consumed", {})
	for cost_value in stage.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var total := int(cost.get("quantity", 0))
		if total <= 0:
			continue
		var paid := int(consumed.get(item_id, 0))
		var affordable_total := paid + state.available_item_quantity_for_research(item_id)
		var maximum_progress := work_required * minf(1.0, float(affordable_total) / float(total))
		if maximum_progress <= progress + 0.001 and paid < total:
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "RESERVE:%s" % item_id
			return INF
		result = minf(result, maxf(0.001, (maximum_progress - progress) / rate))
	return result


func research_rate(state: SpaceGameState) -> float:
	return research_capacity(state)


func repair_support_rate(state: SpaceGameState) -> float:
	var rate := maxf(1.0, facility_output_multiplier(state, "repair_dock")) if facility_available(state, "repair_dock") else 1.0
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		if str(ship.get("status", "")) != "DOCKED" or str(ship.get("condition", "")) != "OPERATIONAL" or str(ship.get("maintenance_state", "ACTIVE")) == "MOTHBALLED":
			continue
		rate += maxf(0.0, ship_loadout_capability_value(state, ship, "repair_support")) * 0.5
	return rate


func expedition_support_rate(state: SpaceGameState) -> float:
	var rate := maxf(1.0, facility_output_multiplier(state, "command_array")) if facility_available(state, "command_array") else 1.0
	for ship_id_value in state.active_expedition.get("assigned_ship_ids", []):
		var ship := state.ship_by_id(str(ship_id_value))
		rate += maxf(0.0, ship_loadout_capability_value(state, ship, "survey_support")) * 0.25
	return rate


func _progress_research(state: SpaceGameState, elapsed_ms: float) -> void:
	var runtime: Dictionary = state.research
	if runtime.get("status", "") != "RUNNING":
		return
	var project: Dictionary = content.research_projects.get(str(runtime.get("project_id", "")), {})
	if project.is_empty():
		runtime["status"] = "BLOCKED"
		runtime["blocked_reason"] = "MISSING_PROJECT"
		return
	_normalize_research_runtime(state, project)
	var stage := research_stage_definition(state, project, int(runtime.get("stage_index", 0)), str(runtime.get("route_id", "")))
	var gate_reason := _research_gate_reason(state, stage)
	if not gate_reason.is_empty():
		runtime["status"] = "BLOCKED"
		runtime["blocked_reason"] = gate_reason
		return
	var work_required := maxf(1.0, float(stage.get("work_required", 1.0)))
	if str(stage.get("kind", "")) == "FIELD_TEST":
		runtime["stage_progress_ms"] = work_required
		runtime["progress_ms"] = _research_completed_work(state, project, int(runtime.get("stage_index", 0))) + work_required
		return
	var old_progress := float(runtime.get("stage_progress_ms", 0.0))
	var new_progress := minf(work_required, old_progress + elapsed_ms * research_rate(state))
	var stage_consumed: Dictionary = runtime.get("stage_consumed", {})
	var total_consumed: Dictionary = runtime.get("consumed", {})
	for cost_value in stage.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var total := int(cost.get("quantity", 0))
		var desired := mini(total, int(floor(float(total) * new_progress / work_required + 0.0001)))
		var paid := int(stage_consumed.get(item_id, 0))
		var delta := maxi(0, desired - paid)
		if delta > state.available_item_quantity_for_research(item_id):
			new_progress = old_progress
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "RESERVE:%s" % item_id
			_ensure_research_reservations(state)
			return
		if delta > 0:
			state.remove_item(item_id, delta)
			stage_consumed[item_id] = paid + delta
			total_consumed[item_id] = int(total_consumed.get(item_id, 0)) + delta
	runtime["stage_consumed"] = stage_consumed
	runtime["consumed"] = total_consumed
	runtime["stage_progress_ms"] = new_progress
	runtime["progress_ms"] = _research_completed_work(state, project, int(runtime.get("stage_index", 0))) + new_progress
	_ensure_research_reservations(state)


func _validate_research(state: SpaceGameState) -> void:
	var runtime: Dictionary = state.research
	if runtime.get("status", "") != "BLOCKED" or str(runtime.get("project_id", "")).is_empty():
		return
	var project: Dictionary = content.research_projects.get(str(runtime.get("project_id", "")), {})
	if project.is_empty():
		return
	_normalize_research_runtime(state, project)
	var stage := research_stage_definition(state, project, int(runtime.get("stage_index", 0)), str(runtime.get("route_id", "")))
	if not _research_gate_reason(state, stage).is_empty():
		return
	for cost_value in stage.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var consumed := int(runtime.get("stage_consumed", {}).get(item_id, 0))
		if consumed < int(cost.get("quantity", 0)) and state.available_item_quantity_for_research(item_id) <= 0:
			return
	runtime["status"] = "RUNNING"
	runtime["blocked_reason"] = ""


func _settle_research(state: SpaceGameState) -> bool:
	var runtime: Dictionary = state.research
	if runtime.get("status", "") != "RUNNING":
		return false
	var project: Dictionary = content.research_projects.get(str(runtime.get("project_id", "")), {})
	if project.is_empty():
		return false
	_normalize_research_runtime(state, project)
	var stage_index := int(runtime.get("stage_index", 0))
	var stage := research_stage_definition(state, project, stage_index, str(runtime.get("route_id", "")))
	if stage.is_empty():
		return _complete_research_program(state, project)
	var work_required := maxf(1.0, float(stage.get("work_required", 1.0)))
	if float(runtime.get("stage_progress_ms", 0.0)) + 0.001 < work_required:
		for cost_value in stage.get("costs", []):
			var cost := cost_value as Dictionary
			var boundary_item := str(cost.get("item", ""))
			if int(runtime.get("stage_consumed", {}).get(boundary_item, 0)) < int(cost.get("quantity", 0)) and state.available_item_quantity_for_research(boundary_item) <= 0:
				runtime["status"] = "BLOCKED"
				runtime["blocked_reason"] = "RESERVE:%s" % boundary_item
				emitted_events.append({"type":"ResearchBlocked", "project_id":project.get("id", ""), "item_id":boundary_item})
				return true
		return false
	# Pay any rounding remainder at the exact completion boundary.
	for cost_value in stage.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var total := int(cost.get("quantity", 0))
		var paid := int(runtime.get("stage_consumed", {}).get(item_id, 0))
		if total > paid:
			if state.available_item_quantity_for_research(item_id) < total - paid:
				runtime["status"] = "BLOCKED"
				runtime["blocked_reason"] = "RESERVE:%s" % item_id
				return true
			state.remove_item(item_id, total - paid)
			runtime["stage_consumed"][item_id] = total
			runtime["consumed"][item_id] = int(runtime.get("consumed", {}).get(item_id, 0)) + total - paid
	_apply_research_stage_effects(state, project, stage)
	runtime["stage_index"] = stage_index + 1
	runtime["stage_progress_ms"] = 0.0
	runtime["stage_consumed"] = {}
	runtime["blocked_reason"] = ""
	if int(runtime.get("stage_index", 0)) < research_stages(project).size():
		_sync_research_stage_runtime(state, project)
		_ensure_research_reservations(state)
		emitted_events.append({"type":"ResearchStageCompleted", "project_id":project.get("id", ""), "stage_id":stage.get("id", ""), "stage_kind":stage.get("kind", "")})
		return true
	return _complete_research_program(state, project)


func _apply_research_stage_effects(state: SpaceGameState, project: Dictionary, stage: Dictionary) -> void:
	var token := "%s:%s" % [project.get("id", ""), stage.get("id", "")]
	var applied: Array = state.research.get("applied_stage_effects", [])
	if applied.has(token):
		return
	for effect_value in stage.get("completion_effects", []):
		_apply_effect(state, effect_value as Dictionary)
	applied.append(token)
	state.research["applied_stage_effects"] = applied


func _grant_technology_domain_xp(state: SpaceGameState, domain_id: String, amount: float) -> void:
	if domain_id not in SpaceGameState.TECHNOLOGY_DOMAIN_IDS or amount <= 0.0:
		return
	var runtime: Dictionary = state.technology_domains.get(domain_id, {"level":1, "xp":0.0})
	runtime["xp"] = float(runtime.get("xp", 0.0)) + amount
	while float(runtime.get("xp", 0.0)) + 0.000001 >= float(int(runtime.get("level", 1)) * 100):
		runtime["xp"] = float(runtime.get("xp", 0.0)) - float(int(runtime.get("level", 1)) * 100)
		runtime["level"] = int(runtime.get("level", 1)) + 1
		emitted_events.append({"type":"TechnologyDomainLeveledUp", "domain":domain_id, "level":runtime.get("level", 1)})
	state.technology_domains[domain_id] = runtime


func _complete_research_program(state: SpaceGameState, project: Dictionary) -> bool:
	var runtime: Dictionary = state.research
	var project_id := str(project.get("id", ""))
	var route_id := str(runtime.get("route_id", ""))
	var supplemental := bool(runtime.get("supplemental_route", false))
	if not route_id.is_empty():
		var route_history: Dictionary = state.completed_research_routes.get(project_id, {})
		route_history[route_id] = true
		state.completed_research_routes[project_id] = route_history
		for effect_value in research_route(project, route_id).get("completion_effects", []):
			_apply_effect(state, effect_value as Dictionary)
	if not supplemental:
		state.completed_projects[project_id] = true
	var technology_id := str(project.get("grants_technology", ""))
	if not supplemental and not technology_id.is_empty():
		state.technologies[technology_id] = true
	var ship_plan_id := str(project.get("grants_ship_plan", ""))
	if not supplemental and not ship_plan_id.is_empty():
		state.unlock_ship_plan(ship_plan_id)
		state.enqueue_ship_plan(ship_plan_id)
		normalize_shipyard_queue(state)
	if not supplemental:
		for effect in project.get("effects", []):
			_apply_effect(state, effect)
	for reward_value in project.get("domain_rewards", []):
		var reward := reward_value as Dictionary
		_grant_technology_domain_xp(state, str(reward.get("domain", "")), float(reward.get("xp", 0.0)) * (0.5 if supplemental else 1.0))
	state.statistics["research_completed"] = int(state.statistics.get("research_completed", 0)) + 1
	state.research_program_history.append({"project_id":project_id, "route_id":route_id, "supplemental_route":supplemental, "completed_at_ms":int(state.total_elapsed_ms)})
	if state.research_program_history.size() > 50:
		state.research_program_history.pop_front()
	state.research = SpaceGameState.empty_research_program()
	state.research["status"] = "COMPLETE"
	emitted_events.append({"type":"ResearchCompleted", "project_id":project_id, "technology_id":technology_id, "ship_plan_id":ship_plan_id, "route_id":route_id, "supplemental_route":supplemental})
	return true


func costs_available_for_industry_slot(state: SpaceGameState, activity: Dictionary, slot: int) -> bool:
	if slot < 0 or slot >= state.industrial_operations.size():
		return false
	var runtime: Dictionary = state.industrial_operations[slot]
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var cycle_costs := industry_cycle_costs(state, runtime, activity, false)
	for item_id in cycle_costs:
		if state.available_item_quantity_for_industry(str(item_id), slot, location_id) < int(cycle_costs.get(item_id, 0)):
			return false
	return _industry_storage_available(state, runtime, activity, cycle_costs)


func costs_available_for_construction_queue_position(state: SpaceGameState, activity: Dictionary, queue_position: int) -> bool:
	for cost in activity.get("costs", []):
		if state.available_item_quantity_for_construction(str(cost.get("item", "")), queue_position) < int(cost.get("quantity", 0)):
			return false
	return true


func _refresh_resource_commitments(state: SpaceGameState) -> void:
	_ensure_research_reservations(state)
	_ensure_construction_reservations(state)
	normalize_shipyard_queue(state)
	_ensure_industry_reservations(state)
	_validate_construction_commitments(state)
	_validate_industry_commitments(state)


func _refresh_blocker_diagnostics(state: SpaceGameState) -> void:
	for runtime_value in state.mining_operations:
		var runtime := runtime_value as Dictionary
		runtime["blocker"] = blocker_diagnostic(state, "mining", runtime)
	for runtime_value in state.industrial_operations:
		var runtime := runtime_value as Dictionary
		runtime["blocker"] = blocker_diagnostic(state, "industry", runtime)
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		runtime["blocker"] = blocker_diagnostic(state, "construction", runtime)
	for runtime_value in state.shipyard_queue:
		var runtime := runtime_value as Dictionary
		runtime["blocker"] = blocker_diagnostic(state, "shipyard", runtime)
	state.research["blocker"] = blocker_diagnostic(state, "research", state.research)
	for location_id_value in state.locations.keys():
		var location_id := str(location_id_value)
		var location: Dictionary = state.locations[location_id]
		var automation: Dictionary = location.get("automation", {})
		var legacy_reason := str(automation.get("last_blocked_reason", ""))
		automation["blocker"] = _legacy_blocker("automation", location_id, legacy_reason) if not legacy_reason.is_empty() else {}
	for project_id_value in state.megastructure_projects.keys():
		var project_id := str(project_id_value)
		var project: Dictionary = state.megastructure_projects[project_id]
		var matching_runtime: Dictionary = {}
		for runtime_value in state.construction_operations:
			var runtime := runtime_value as Dictionary
			if str(runtime.get("megastructure_id", "")) == project_id:
				matching_runtime = runtime
				break
		project["blocker"] = matching_runtime.get("blocker", {}).duplicate(true) if not matching_runtime.is_empty() else {}


func blocker_diagnostic(state: SpaceGameState, domain_id: String, runtime: Dictionary) -> Dictionary:
	var status := str(runtime.get("status", "IDLE"))
	if status == "PAUSED":
		return _make_blocker("MANUALLY_PAUSED", domain_id, str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)))
	if status != "BLOCKED":
		return {}
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var activity: Dictionary = construction_activity_for_runtime(runtime) if domain_id == "construction" else content.activities.get(str(runtime.get("activity_id", "")), {})
	if domain_id == "research":
		var project: Dictionary = content.research_projects.get(str(runtime.get("project_id", "")), {})
		if project.is_empty():
			return _make_blocker("MISSING_TECH", domain_id, location_id, {"project_id":runtime.get("project_id", "")})
		_normalize_research_runtime(state, project)
		var stage := research_stage_definition(state, project, int(runtime.get("stage_index", 0)), str(runtime.get("route_id", "")))
		var requirement_blocker := _first_requirement_blocker(state, project.get("requirements", []), domain_id, location_id)
		if not requirement_blocker.is_empty():
			return requirement_blocker
		for requirement_value in stage.get("requirements", []):
			var requirement := requirement_value as Dictionary
			if requirement_met(state, requirement):
				continue
			if str(stage.get("kind", "")) == "FIELD_TEST":
				return _make_blocker("FIELD_TEST_REQUIRED", domain_id, location_id, {"project_id":project.get("id", ""), "stage_id":stage.get("id", ""), "requirement":requirement.duplicate(true)})
			if str(requirement.get("type", "")) in ["technology_domain", "research_capacity"]:
				return _make_blocker("KNOWLEDGE_GATE", domain_id, location_id, {"project_id":project.get("id", ""), "stage_id":stage.get("id", ""), "requirement":requirement.duplicate(true)})
			var stage_requirement_blocker := _first_requirement_blocker(state, [requirement], domain_id, location_id)
			if not stage_requirement_blocker.is_empty():
				stage_requirement_blocker["stage_id"] = stage.get("id", "")
				return stage_requirement_blocker
			return _make_blocker("OPERATING_CONDITION", domain_id, location_id, {"project_id":project.get("id", ""), "stage_id":stage.get("id", ""), "requirement":requirement.duplicate(true)})
		if research_capacity(state) + 0.000001 < float(stage.get("capacity_required", 1.0)):
			return _make_blocker("RESEARCH_CAPACITY_SHORTAGE", domain_id, location_id, {"project_id":project.get("id", ""), "stage_id":stage.get("id", ""), "required":float(stage.get("capacity_required", 1.0)), "available":research_capacity(state)})
		for requirement_value in stage.get("operating_conditions", []):
			var requirement := requirement_value as Dictionary
			if not requirement_met(state, requirement):
				return _make_blocker("OPERATING_CONDITION", domain_id, location_id, {"project_id":project.get("id", ""), "stage_id":stage.get("id", ""), "requirement":requirement.duplicate(true), "condition_id":requirement.get("id", ""), "required":requirement.get("value", 1.0), "available":capability_value(state, str(requirement.get("id", "")))})
		var remaining_costs: Array = []
		for cost_value in stage.get("costs", []):
			var cost := cost_value as Dictionary
			var remaining := maxi(0, int(cost.get("quantity", 0)) - int(runtime.get("stage_consumed", {}).get(str(cost.get("item", "")), 0)))
			if remaining > 0:
				remaining_costs.append({"item":str(cost.get("item", "")), "quantity":remaining})
		return _first_missing_input_blocker(state, domain_id, runtime, remaining_costs, location_id, {"project_id":project.get("id", ""), "stage_id":stage.get("id", "")})
	if domain_id == "shipyard":
		var plan: Dictionary = content.ship_construction_projects.get(str(runtime.get("plan_id", "")), {})
		if str(runtime.get("blocked_reason", "")) == "ENGINEERING":
			return _make_blocker("MISSING_SCALE_STAGE", domain_id, location_id, {"project_id":runtime.get("project_id", ""), "required":int(plan.get("engineering_required", 1)), "available":shipyard_engineering_level(state)})
		return _first_missing_input_blocker(state, domain_id, runtime, _dictionary_to_item_entries(_shipyard_next_cycle_costs(runtime, plan)), location_id, {"project_id":runtime.get("project_id", ""), "plan_id":plan.get("id", "")})
	if domain_id == "construction":
		if str(runtime.get("blocked_reason", "")) == "CONSTRUCTION_CAPACITY":
			return _make_blocker("CONSTRUCTION_CAPACITY_FULL", domain_id, location_id, {"project_id":runtime.get("project_id", ""), "required":1, "available":location_construction_capacity(state, location_id)})
		if str(runtime.get("blocked_reason", "")) == "STRUCTURE_CAPACITY":
			var constraints := location_industry_constraint_profile(state, location_id)
			return _make_blocker("CONSTRUCTION_CAPACITY_FULL", domain_id, location_id, {"project_id":runtime.get("project_id", ""), "required":int(runtime.get("target_level", 0)), "available":constraints.get("structural_capacity", 0.0), "capacity_kind":"STRUCTURE"})
	if not activity.is_empty():
		var requirement_blocker := _first_requirement_blocker(state, activity.get("requirements", []), domain_id, location_id)
		if not requirement_blocker.is_empty():
			return requirement_blocker
		var facility_id := str(activity.get("facility", ""))
		if not facility_id.is_empty() and not facility_available(state, facility_id):
			return _make_blocker("MISSING_FACILITY", domain_id, location_id, {"facility_id":facility_id, "activity_id":activity.get("id", "")})
		if domain_id == "industry":
			if not production_method_available_at_scale(state, location_id, facility_id, activity):
				return _make_blocker("MISSING_SCALE_STAGE", domain_id, location_id, {"activity_id":activity.get("id", ""), "required_stage":activity.get("minimum_scale_stage", "WORKSHOP"), "available_stage":industry_scale_stage(state, location_id, facility_id)})
			var constraints := location_industry_constraint_profile(state, location_id)
			if float(constraints.get("power_demand", 0.0)) > float(constraints.get("power_capacity", 0.0)) + 0.000001:
				return _make_blocker("POWER_SHORTAGE", domain_id, location_id, {"required":constraints.get("power_demand", 0.0), "available":constraints.get("power_capacity", 0.0), "activity_id":activity.get("id", "")})
			if float(constraints.get("cooling_demand", 0.0)) > float(constraints.get("cooling_capacity", 0.0)) + 0.000001:
				return _make_blocker("COOLING_SHORTAGE", domain_id, location_id, {"required":constraints.get("cooling_demand", 0.0), "available":constraints.get("cooling_capacity", 0.0), "activity_id":activity.get("id", "")})
			var cycle_costs := industry_cycle_costs(state, runtime, activity, false)
			var input_blocker := _first_missing_input_blocker(state, domain_id, runtime, _dictionary_to_item_entries(cycle_costs), location_id, {"activity_id":activity.get("id", "")})
			if not input_blocker.is_empty():
				return input_blocker
			if not _industry_storage_available(state, runtime, activity, cycle_costs):
				return _make_blocker("STORAGE_FULL", domain_id, location_id, {"activity_id":activity.get("id", "")})
		if domain_id == "construction":
			var due := _construction_next_cycle_costs(runtime, activity)
			var input_blocker := _first_missing_input_blocker(state, domain_id, runtime, _dictionary_to_item_entries(due), location_id, {"activity_id":activity.get("id", "")})
			if not input_blocker.is_empty():
				return input_blocker
	return _legacy_blocker(domain_id, location_id, str(runtime.get("blocked_reason", "")))


func _first_requirement_blocker(state: SpaceGameState, requirement_values: Array, domain_id: String, location_id: String) -> Dictionary:
	for requirement_value in requirement_values:
		var requirement := requirement_value as Dictionary
		if requirement_met(state, requirement):
			continue
		match str(requirement.get("type", "")):
			"technology", "project_complete":
				return _make_blocker("MISSING_TECH", domain_id, location_id, {"technology_id":requirement.get("id", "")})
			"own_facility", "facility_level", "manufacturing_module_installed":
				return _make_blocker("MISSING_FACILITY", domain_id, location_id, {"facility_id":requirement.get("facility", requirement.get("id", "")), "requirement":requirement.duplicate(true)})
	return {}


func _first_missing_input_blocker(state: SpaceGameState, domain_id: String, runtime: Dictionary, cost_values: Array, location_id: String, extra: Dictionary = {}) -> Dictionary:
	for cost_value in cost_values:
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var required := int(cost.get("quantity", 0))
		var available := _runtime_available_item_quantity(state, "construction" if domain_id == "construction" else ("industry" if domain_id == "industry" else domain_id), runtime, item_id) if domain_id in ["industry", "construction"] else state.available_item_quantity(item_id, location_id)
		if domain_id == "research":
			available = state.available_item_quantity_for_research(item_id, location_id)
		elif domain_id == "shipyard":
			available = state.available_item_quantity_for_shipyard(item_id, str(runtime.get("project_id", "")), location_id)
		if available >= required:
			continue
		var incoming := _incoming_item_quantity(state, location_id, item_id)
		var fields := extra.duplicate(true)
		fields.merge({"item_id":item_id, "required":required, "available":available, "incoming":incoming}, true)
		var reason := "INPUT_IN_TRANSIT" if incoming > 0 else "INPUT_SHORTAGE"
		if incoming <= 0 and str(content.items.get(item_id, {}).get("category", "")) == "Capital Good":
			reason = "MISSING_CAPITAL_GOOD"
		return _make_blocker(reason, domain_id, location_id, fields)
	return {}


func _incoming_item_quantity(state: SpaceGameState, location_id: String, item_id: String) -> int:
	var total := 0
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if str(shipment.get("destination", "")) == location_id:
			total += int(shipment.get("cargo", {}).get(item_id, 0))
	return total


func _dictionary_to_item_entries(values: Dictionary) -> Array:
	var result: Array = []
	for item_id_value in values.keys():
		result.append({"item":str(item_id_value), "quantity":int(values[item_id_value])})
	return result


func _make_blocker(primary_reason: String, domain_id: String, location_id: String, fields: Dictionary = {}) -> Dictionary:
	assert(primary_reason in BLOCKER_REASON_CODES, "Unknown blocker reason code: %s" % primary_reason)
	var result := {"status":"BLOCKED", "primary_reason":primary_reason, "domain":domain_id, "location_id":location_id}
	result.merge(fields, true)
	return result


func _legacy_blocker(domain_id: String, location_id: String, legacy_reason: String) -> Dictionary:
	var reason := "INPUT_SHORTAGE"
	if legacy_reason in ["INSUFFICIENT_POWER"]:
		reason = "POWER_SHORTAGE"
	elif legacy_reason in ["ENGINEERING"]:
		reason = "MISSING_SCALE_STAGE"
	elif legacy_reason in ["FACILITY_LOCKED"]:
		reason = "MISSING_FACILITY"
	elif legacy_reason in ["RESOURCES_OR_CAPACITY"]:
		reason = "CONSTRUCTION_CAPACITY_FULL"
	elif legacy_reason in ["CONSTRUCTION_CAPACITY", "STRUCTURE_CAPACITY"]:
		reason = "CONSTRUCTION_CAPACITY_FULL"
	var fields := {"legacy_reason":legacy_reason}
	if legacy_reason.begins_with("RESOURCES:") or legacy_reason.begins_with("RESERVE:"):
		fields["item_id"] = legacy_reason.get_slice(":", 1)
	return _make_blocker(reason, domain_id, location_id, fields)


func _ensure_research_reservations(state: SpaceGameState) -> void:
	var runtime: Dictionary = state.research
	if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED", "PAUSED"]:
		runtime["reserved_costs"] = {}
		return
	var project: Dictionary = content.research_projects.get(str(runtime.get("project_id", "")), {})
	if project.is_empty():
		runtime["reserved_costs"] = {}
		return
	_normalize_research_runtime(state, project)
	var stage := research_stage_definition(state, project, int(runtime.get("stage_index", 0)), str(runtime.get("route_id", "")))
	var consumed: Dictionary = runtime.get("stage_consumed", {})
	var reserved_costs := {}
	for cost_value in stage.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		reserved_costs[item_id] = maxi(0, int(cost.get("quantity", 0)) - int(consumed.get(item_id, 0)))
	runtime["reserved_costs"] = reserved_costs


func _ensure_industry_reservations(state: SpaceGameState) -> void:
	var allocatable := {}
	for runtime in state.industrial_operations:
		runtime["reserved_costs"] = {}
		runtime["input_commitments"] = {}
	var prioritized_lines: Array = state.industrial_operations.duplicate()
	prioritized_lines.sort_custom(func(a, b):
		if int((a as Dictionary).get("priority", 50)) != int((b as Dictionary).get("priority", 50)):
			return int((a as Dictionary).get("priority", 50)) > int((b as Dictionary).get("priority", 50))
		return int((a as Dictionary).get("slot", 0)) < int((b as Dictionary).get("slot", 0))
	)
	for runtime_value in prioritized_lines:
		var runtime := runtime_value as Dictionary
		var slot := int(runtime.get("slot", -1))
		if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED"]:
			continue
		var activity: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
		if activity.is_empty():
			continue
		var costs := industry_cycle_costs(state, runtime, activity, false)
		var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var can_fund := true
		for item_value in costs.keys():
			var item_id := str(item_value)
			var allocation_key := "%s:%s" % [location_id, item_id]
			if not allocatable.has(allocation_key):
				allocatable[allocation_key] = maxi(0, state.item_quantity(item_id, location_id) - int(state.location_reserves(location_id).get(item_id, 0)) - state.research_committed_quantity(item_id, location_id) - state.construction_committed_quantity(item_id, -1, location_id) - state.shipyard_committed_quantity(item_id, "", location_id))
			if int(allocatable[allocation_key]) < int(costs.get(item_id, 0)):
				can_fund = false
				break
		if not can_fund:
			continue
		var reserved_costs := {}
		for item_value in costs.keys():
			var item_id := str(item_value)
			var quantity := int(costs.get(item_id, 0))
			var allocation_key := "%s:%s" % [location_id, item_id]
			reserved_costs[item_id] = quantity
			allocatable[allocation_key] = int(allocatable.get(allocation_key, 0)) - quantity
		runtime["reserved_costs"] = reserved_costs
		runtime["input_commitments"] = reserved_costs.duplicate(true)


func _ensure_construction_reservations(state: SpaceGameState) -> void:
	for runtime in state.construction_operations:
		runtime["reserved_costs"] = {}
	var allocatable := {}
	for runtime_value in state.construction_operations:
		var runtime := runtime_value as Dictionary
		if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED"]:
			continue
		var activity := construction_activity_for_runtime(runtime)
		if activity.is_empty():
			continue
		var due := _construction_next_cycle_costs(runtime, activity)
		var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var fully_funded := true
		for item_id_value in due.keys():
			var item_id := str(item_id_value)
			var allocation_key := "%s:%s" % [location_id, item_id]
			if not allocatable.has(allocation_key):
				allocatable[allocation_key] = maxi(0, state.item_quantity(item_id, location_id) - int(state.location_reserves(location_id).get(item_id, 0)) - state.research_committed_quantity(item_id, location_id) - state.industrial_committed_quantity(item_id, -1, location_id) - state.shipyard_committed_quantity(item_id, "", location_id))
			if int(allocatable[allocation_key]) < int(due[item_id]):
				fully_funded = false
				break
		if not fully_funded:
			continue
		runtime["reserved_costs"] = due
		for item_id_value in due.keys():
			var item_id := str(item_id_value)
			var allocation_key := "%s:%s" % [location_id, item_id]
			allocatable[allocation_key] = int(allocatable[allocation_key]) - int(due[item_id])


func _validate_industry_commitments(state: SpaceGameState) -> void:
	for runtime in state.industrial_operations:
		if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED"]:
			continue
		var activity: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
		if activity.is_empty() or not activity_available(state, activity):
			continue
		if not production_method_available_at_scale(state, str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)), str(runtime.get("facility_id", "")), activity):
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "ENGINEERING"
			runtime["progress_ms"] = 0.0
			continue
		var fully_funded := true
		var cycle_costs := industry_cycle_costs(state, runtime, activity, false)
		for item_value in cycle_costs.keys():
			var item_id := str(item_value)
			if int(runtime.get("reserved_costs", {}).get(item_id, 0)) < int(cycle_costs.get(item_id, 0)):
				fully_funded = false
				break
		var storage_ready := _industry_storage_available(state, runtime, activity, cycle_costs)
		fully_funded = fully_funded and storage_ready
		if fully_funded:
			runtime["status"] = "RUNNING"
			runtime["blocked_reason"] = ""
		elif runtime.get("status", "") == "RUNNING":
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "STORAGE_FULL" if not storage_ready else "RESOURCES"
			runtime["progress_ms"] = 0.0
			emitted_events.append({"type":"OperationBlocked", "domain":"industry", "activity_id":activity.get("id", ""), "reason":"resources"})


func _validate_construction_commitments(state: SpaceGameState) -> void:
	for index in state.construction_operations.size():
		var runtime: Dictionary = state.construction_operations[index]
		if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED", "QUEUED"]:
			continue
		var activity: Dictionary = construction_activity_for_runtime(runtime)
		if activity.is_empty() or not is_construction_activity(activity) or not activity_available(state, activity):
			continue
		var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		if location_construction_capacity(state, location_id) <= 0.0:
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "CONSTRUCTION_CAPACITY"
			continue
		if not _construction_project_structural_capacity_met(state, runtime):
			runtime["status"] = "BLOCKED"
			runtime["blocked_reason"] = "STRUCTURE_CAPACITY"
			continue
		var fully_funded := true
		for item_id in runtime.get("reserved_costs", {}):
			if state.available_item_quantity_for_construction(str(item_id), index) < int(runtime["reserved_costs"][item_id]):
				fully_funded = false
				break
		if index >= construction_active_project_limit(state):
			runtime["status"] = "QUEUED"
		elif fully_funded and not runtime.get("reserved_costs", {}).is_empty() or fully_funded and _construction_next_cycle_costs(runtime, activity).is_empty():
			runtime["status"] = "RUNNING"
			runtime["blocked_reason"] = ""
		elif runtime.get("status", "") in ["RUNNING", "BLOCKED"]:
			runtime["status"] = "BLOCKED"
			emitted_events.append({"type":"OperationBlocked", "domain":"construction", "activity_id":activity.get("id", ""), "reason":"resources"})


func _construction_project_structural_capacity_met(state: SpaceGameState, runtime: Dictionary) -> bool:
	if str(runtime.get("project_type", "")) not in ["FACILITY_EXPANSION", "SCALE_STAGE_UPGRADE"]:
		return true
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	if not state.has_location(location_id) or str(state.location_state(location_id).get("type", LocationState.NATURAL)) != LocationState.ARTIFICIAL:
		return true
	var constraints := location_industry_constraint_profile(state, location_id)
	var current_level := int(state.location_industry(location_id, str(runtime.get("target_id", ""))).get("level", 0))
	var added_levels := maxi(0, int(runtime.get("target_level", current_level)) - current_level)
	var required := float(constraints.get("structural_used", 0.0)) + float(added_levels) * float(content.industry_rules.get("structural_capacity_per_level", 1.0))
	return required <= float(constraints.get("structural_capacity", 0.0)) + 0.000001


func _current_expedition_node(state: SpaceGameState) -> Dictionary:
	var runtime: Dictionary = state.active_expedition
	var route: Dictionary = content.expedition_routes.get(str(runtime.get("route_id", "")), {})
	var index := int(runtime.get("node_index", 0))
	var nodes: Array = route.get("nodes", [])
	return nodes[index] if index >= 0 and index < nodes.size() else {}


func _settle_expedition_node(state: SpaceGameState) -> bool:
	var runtime: Dictionary = state.active_expedition
	if runtime.get("status", "") != "RUNNING" or str(runtime.get("route_id", "")).is_empty():
		return false
	var route: Dictionary = content.expedition_routes.get(str(runtime.get("route_id", "")), {})
	var node := _current_expedition_node(state)
	if node.is_empty():
		return false
	var phase := str(node.get("phase", ""))
	var is_combat_node := phase in ["COMBAT", "BOSS"]
	var active_combat_state: Dictionary = runtime.get("combat_state", {})
	if (not is_combat_node or active_combat_state.is_empty()) and float(runtime.get("node_progress_ms", 0.0)) + 0.001 < float(node.get("duration_ms", 1.0)):
		return false
	var ship_ids: Array = runtime.get("assigned_ship_ids", []).duplicate()
	for requirement in node.get("build_requirements", []):
		if not _requirement_met_for_ships(state, requirement, ship_ids):
			_fail_expedition_route(state, route, "BUILD_INSUFFICIENT:%s" % node.get("id", node.get("phase", "NODE")))
			return true
	if is_combat_node:
		if active_combat_state.is_empty():
			active_combat_state = combat.begin(state, ship_ids, str(node.get("enemy", "")))
			runtime["combat_state"] = active_combat_state
			state.combat_log = active_combat_state.get("log", []).duplicate(true)
			emitted_events.append({"type":"CombatStarted", "route_id":route.get("id", ""), "enemy_id":node.get("enemy", ""), "boss":phase == "BOSS"})
			return true
		if str(active_combat_state.get("status", "")) == "RUNNING":
			if not combat.event_ready(active_combat_state):
				return false
			var combat_event: Dictionary = combat.settle_next_event(state, active_combat_state)
			state.combat_log = active_combat_state.get("log", []).duplicate(true)
			emitted_events.append({"type":"CombatActionResolved", "route_id":route.get("id", ""), "enemy_id":node.get("enemy", ""), "combat_event":combat_event})
			if str(active_combat_state.get("status", "")) == "RUNNING":
				return true
		var combat_result: Dictionary = combat.result(active_combat_state)
		if not bool(combat_result.get("victory", false)):
			_apply_combat_damage_to_ships(state, combat_result, ship_ids)
			_fail_expedition_route(state, route, str(combat_result.get("reason", "FLEET_DISABLED")), combat_result)
			return true
		_apply_combat_damage_to_ships(state, combat_result, ship_ids)
		var enemy_id := str(node.get("enemy", ""))
		state.completed_activities["enemy:%s" % enemy_id] = int(state.completed_activities.get("enemy:%s" % enemy_id, 0)) + 1
		state.statistics["enemies_defeated"] = int(state.statistics.get("enemies_defeated", 0)) + 1
		if phase == "BOSS":
			state.completed_activities["boss:%s" % enemy_id] = 1
			state.statistics["bosses_defeated"] = int(state.statistics.get("bosses_defeated", 0)) + 1
		emitted_events.append({"type":"EnemyDefeated", "enemy_id":enemy_id, "boss":phase == "BOSS", "combat":combat_result})
		runtime["combat_state"] = {}
	for reward in node.get("rewards", []):
		_store_expedition_cargo(state, ship_ids, str(reward.get("item", "")), int(reward.get("quantity", 0)))
	for effect in node.get("effects", []):
		_apply_effect(state, effect)
	if phase == "CHECKPOINT":
		runtime["safe_node_index"] = int(runtime.get("node_index", 0))
	runtime["node_index"] = int(runtime.get("node_index", 0)) + 1
	runtime["node_progress_ms"] = 0.0
	var nodes: Array = route.get("nodes", [])
	if int(runtime.get("node_index", 0)) >= nodes.size():
		for effect in route.get("completion_effects", []):
			_apply_effect(state, effect)
		var route_id := str(route.get("id", ""))
		state.completed_activities["route:%s" % route_id] = int(state.completed_activities.get("route:%s" % route_id, 0)) + 1
		for area_id in content.combat_areas:
			if str(content.combat_areas[area_id].get("route", "")) == route_id:
				var area_runtime: Dictionary = state.combat_area_states.get(area_id, {})
				area_runtime["unlocked"] = true
				area_runtime["first_clear_complete"] = true
				area_runtime["completions"] = int(area_runtime.get("completions", 0)) + 1
				state.combat_area_states[area_id] = area_runtime
		_record_route_report(state, route, "SUCCESS", "", ship_ids)
		_stop_runtime(state, runtime, "COMPLETE", true)
		state.unload_fleet_cargo("expedition", false)
		for ship_id in ship_ids:
			var returning_ship := state.ship_by_id(str(ship_id))
			if not returning_ship.is_empty() and float(returning_ship.get("damage_taken", 0.0)) > 0.0:
				returning_ship["status"] = "REPAIRING"
				returning_ship["repair_remaining_ms"] = clampf(float(returning_ship.get("damage_taken", 0.0)) * 250.0, 1000.0, 120000.0)
				returning_ship["assignment"] = {"type":"STARPORT_REPAIR", "source_route":route_id}
		runtime["route_id"] = ""
		runtime["phase"] = "COMPLETE"
		emitted_events.append({"type":"ExpeditionRouteCompleted", "route_id":route_id})
	else:
		runtime["phase"] = str(nodes[int(runtime.node_index)].get("phase", "EXPLORE"))
		emitted_events.append({"type":"ExpeditionNodeCompleted", "route_id":route.get("id", ""), "node_index":int(runtime.node_index) - 1, "phase":phase})
	return true


func _fail_expedition_route(state: SpaceGameState, route: Dictionary, reason: String, combat_result: Dictionary = {}) -> void:
	var runtime: Dictionary = state.active_expedition
	var ship_ids: Array = runtime.get("assigned_ship_ids", []).duplicate()
	if reason in ["AMMUNITION_DEPLETED", "RETREAT_POLICY"]:
		for ship_id in ship_ids:
			var returning_ship := state.ship_by_id(str(ship_id))
			if not returning_ship.is_empty():
				if float(returning_ship.get("damage_taken", 0.0)) > 0.0 or str(returning_ship.get("condition", "")) == "DISABLED":
					returning_ship["status"] = "REPAIRING"
					returning_ship["repair_remaining_ms"] = clampf(float(returning_ship.get("damage_taken", 0.0)) * 250.0, 1000.0, 120000.0)
					returning_ship["assignment"] = {"type":"STARPORT_REPAIR", "source_route":route.get("id", "")}
				else:
					returning_ship["status"] = "DOCKED"
					returning_ship["assignment"] = {"domain":"expedition", "fleet":"default"}
		_record_route_report(state, route, "RETURNED", reason, ship_ids, combat_result)
		state.unload_fleet_cargo("expedition", false)
		runtime["status"] = "IDLE"
		runtime["phase"] = "RETURNED_TO_STARPORT"
		runtime["route_id"] = ""
		runtime["assigned_ship_ids"] = []
		runtime["node_progress_ms"] = 0.0
		runtime["combat_state"] = {}
		emitted_events.append({"type":"ExpeditionReturnedForLogistics", "route_id":route.get("id", ""), "reason":reason, "ship_ids":ship_ids})
		return
	var repair_ms := float(route.get("failure_repair_ms", 120000.0))
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if ship.is_empty():
			continue
		ship["condition"] = "DISABLED"
		ship["status"] = "REPAIRING"
		ship["repair_remaining_ms"] = repair_ms
		ship["assignment"] = {"type":"STARPORT_REPAIR", "source_route":route.get("id", "")}
	state.statistics["expeditions_failed"] = int(state.statistics.get("expeditions_failed", 0)) + 1
	_record_route_report(state, route, "FAILED", reason, ship_ids, combat_result)
	runtime["status"] = "FAILED"
	runtime["phase"] = "FAILED"
	runtime["route_id"] = ""
	runtime["assigned_ship_ids"] = []
	runtime["node_progress_ms"] = 0.0
	runtime["combat_state"] = {}
	emitted_events.append({"type":"ExpeditionFailed", "route_id":route.get("id", ""), "reason":reason, "repair_ms":repair_ms, "ship_ids":ship_ids})


func _record_route_report(state: SpaceGameState, route: Dictionary, result: String, reason: String, ship_ids: Array, combat_result: Dictionary = {}) -> void:
	state.expedition_reports.append({"route_id":route.get("id", ""), "activity_id":"", "encounter_type":"ROUTE", "result":result, "reason":reason, "combat":combat_result.duplicate(true), "ship_ids":ship_ids.duplicate(), "completed_at_ms":int(state.total_elapsed_ms)})
	if state.expedition_reports.size() > 20:
		state.expedition_reports.pop_front()


func _refresh_output_storage_blocks(state: SpaceGameState) -> void:
	for runtime_value in state.mining_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("status", "")) != "BLOCKED" or str(runtime.get("blocked_reason", "")) != "STORAGE_FULL":
			continue
		var activity: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
		if not activity.is_empty() and _activity_storage_available(state, "mining", runtime, activity, _cost_entries_to_dictionary(activity.get("costs", []))):
			runtime["status"] = "RUNNING"
			runtime["blocked_reason"] = ""
	for network_id_value in state.extraction_network_states.keys():
		var network_id := str(network_id_value)
		var runtime: Dictionary = state.extraction_network_states.get(network_id, {})
		if str(runtime.get("status", "")) != "BLOCKED_OUTPUT":
			continue
		var transaction := _extraction_network_output_transaction(state, network_id)
		var can_resume := true
		for location_id_value in transaction.keys():
			if not storage_can_apply_transaction(state, str(location_id_value), transaction[location_id_value]):
				can_resume = false
				break
		if can_resume:
			runtime["status"] = "RUNNING"
			runtime["blocked_reason"] = ""


func _extraction_network_output_transaction(state: SpaceGameState, network_id: String) -> Dictionary:
	var result := {}
	var runtime: Dictionary = state.extraction_network_states.get(network_id, {})
	var network: Dictionary = content.extraction_networks.get(network_id, {})
	for site_id_value in runtime.get("integrated_site_ids", []):
		var site: Dictionary = content.mining_sites.get(str(site_id_value), {})
		var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
		var location_id := str(mining_location.get("region", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var item_id := str(mining_location.get("raw_material", ""))
		if item_id.is_empty():
			continue
		var outputs: Dictionary = result.get(location_id, {})
		outputs[item_id] = int(outputs.get(item_id, 0)) + int(network.get("quantity_per_site", 1)) * maxi(1, int(runtime.get("level", 1)))
		result[location_id] = outputs
	return result


func _validate_runtime(state: SpaceGameState) -> void:
	_migrate_legacy_construction_progress(state)
	normalize_construction_queue(state)
	for entry in _all_runtime_entries(state):
		var runtime: Dictionary = entry["runtime"]
		if runtime.get("status", "") != "RUNNING":
			continue
		var activity: Dictionary = construction_activity_for_runtime(runtime) if str(entry["domain"]) == "construction" else content.activities.get(str(runtime.get("activity_id", "")), {})
		if str(entry["domain"]) == "expedition" and not str(runtime.get("route_id", "")).is_empty():
			continue
		var runtime_domain := str(entry["domain"])
		var domain_matches := str(activity.get("domain", "")) == runtime_domain or (runtime_domain == "construction" and is_construction_activity(activity))
		if activity.is_empty() or not domain_matches:
			_stop_runtime(state, runtime, "BLOCKED", true)
			continue
		if runtime_domain == "industry":
			runtime["method_id"] = str(activity.get("id", ""))
			runtime["product_family_id"] = production_family_id(activity)
			runtime["production_device_id"] = production_device_id(state, activity)
			if str(runtime.get("production_device_id", "")).is_empty() or not industry_recipe_capabilities_met(state, activity):
				runtime["status"] = "BLOCKED"
				runtime["blocked_reason"] = "MISSING_DEVICE"
				runtime["progress_ms"] = 0.0
				continue
			if not production_method_available_at_scale(state, str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)), str(runtime.get("facility_id", "")), activity):
				runtime["status"] = "BLOCKED"
				runtime["blocked_reason"] = "ENGINEERING"
				runtime["progress_ms"] = 0.0
				continue
		if not activity_available(state, activity):
			_stop_runtime(state, runtime, "BLOCKED", true)
			emitted_events.append({"type":"OperationBlocked", "domain":entry["domain"], "activity_id":activity.get("id", ""), "reason":"requirements"})
		elif str(entry["domain"]) == "mining" and (
			mining_power(state, runtime.get("assigned_ship_ids", [])) <= 0.0
			or str(activity.get("location", "")) != str(runtime.get("location_id", activity.get("location", "")))
			or not state.mining_site_available(str(runtime.get("site_id", activity.get("site", ""))))
			or extraction_command_usage(state) > extraction_command_capacity(state)
		):
			_stop_runtime(state, runtime, "BLOCKED", true)
			emitted_events.append({"type":"OperationBlocked", "domain":"mining", "activity_id":activity.get("id", ""), "reason":"mining_power"})


func _migrate_legacy_construction_progress(state: SpaceGameState) -> void:
	for runtime in state.construction_operations:
		if str(runtime.get("activity_id", "")).is_empty():
			continue
		var current_activity := construction_activity_for_runtime(runtime)
		if str(runtime.get("project_id", "")).is_empty():
			initialize_construction_project(state, runtime, current_activity, str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)), int(runtime.get("priority", 50)))
		elif str(runtime.get("project_type", "")).is_empty() and not current_activity.is_empty():
			runtime["project_type"] = construction_project_type_for_activity(current_activity)
		if runtime.get("material_plan", {}).is_empty() and not current_activity.is_empty():
			runtime["material_plan"] = _cost_entries_to_dictionary(current_activity.get("costs", []))
		runtime["total_work"] = maxf(1.0, float(runtime.get("total_work", 100.0)))
		runtime["completed_work"] = clampf(float(runtime.get("project_cycles_completed", 0)) / 100.0 * float(runtime.get("total_work", 100.0)), 0.0, float(runtime.get("total_work", 100.0)))
		if not runtime.has("legacy_total_progress_ms"):
			continue
		var activity: Dictionary = current_activity
		if activity.is_empty():
			runtime.erase("legacy_total_progress_ms")
			continue
		var old_total_duration := maxf(1.0, float(activity.get("work_required", 1.0)) / maxf(0.01, construction_capacity(state)) * 1000.0)
		var total_segments := clampf(float(runtime.get("legacy_total_progress_ms", 0.0)) / old_total_duration * 100.0, 0.0, 99.999999)
		runtime["project_cycles_completed"] = int(floor(total_segments))
		runtime["paid_cycles"] = int(floor(total_segments))
		runtime["cycle_progress"] = total_segments - floor(total_segments)
		runtime["progress_ms"] = 0.0
		runtime.erase("legacy_total_progress_ms")


func _all_runtime_entries(state: SpaceGameState) -> Array:
	var entries: Array = []
	for runtime in state.mining_operations:
		entries.append({"domain":"mining", "runtime":runtime})
	for runtime in state.industrial_operations:
		entries.append({"domain":"industry", "runtime":runtime})
	for runtime in state.construction_operations:
		if str(runtime.get("status", "")) in ["RUNNING", "BLOCKED"] and not str(runtime.get("activity_id", "")).is_empty():
			entries.append({"domain":"construction", "runtime":runtime})
	entries.append({"domain":"expedition", "runtime":state.active_expedition})
	return entries


func _stop_runtime(state: SpaceGameState, runtime: Dictionary, status: String, release_ships: bool) -> void:
	if release_ships:
		for ship_id in runtime.get("assigned_ship_ids", []):
			var ship := state.ship_by_id(str(ship_id))
			if ship.is_empty() or ship.get("status", "") == "REPAIRING":
				continue
			if float(ship.get("damage_taken", 0.0)) > 0.0 or ship.get("condition", "") == "DISABLED":
				ship["status"] = "REPAIRING"
				ship["repair_remaining_ms"] = clampf(float(ship.get("damage_taken", 0.0)) * 250.0, 1000.0, 120000.0)
				ship["assignment"] = {"type":"STARPORT_REPAIR", "source":"STOPPED_OPERATION"}
			else:
				ship["status"] = "DOCKED"
				var fleet_domain := state.ship_fleet_domain(str(ship_id))
				ship["assignment"] = {} if fleet_domain.is_empty() else {"domain":fleet_domain, "fleet":"default"}
	runtime["activity_id"] = ""
	runtime["progress_ms"] = 0.0
	runtime["cycle_progress"] = 0.0
	runtime["productivity_progress"] = 0.0
	runtime["project_cycles_completed"] = 0
	runtime["paid_cycles"] = 0
	runtime["consumed"] = {}
	runtime["material_savings_fractional"] = {}
	runtime["waste_fractional"] = {}
	runtime["fractional_materials"] = {}
	runtime["status"] = status
	runtime["assigned_ship_ids"] = []
	runtime["reserved_costs"] = {}
	runtime["input_commitments"] = {}
	runtime["theoretical_rate"] = 0.0
	runtime["actual_rate"] = 0.0
	if runtime.get("domain", "") == "expedition":
		runtime["phase"] = status
		runtime["combat_state"] = {}


func _requirement_met_for_ships(state: SpaceGameState, requirement: Dictionary, ship_ids: Array) -> bool:
	var operator := str(requirement.get("op", ""))
	if operator == "AND":
		for child in requirement.get("children", []):
			if not _requirement_met_for_ships(state, child, ship_ids):
				return false
		return true
	if operator == "OR":
		for child in requirement.get("children", []):
			if _requirement_met_for_ships(state, child, ship_ids):
				return true
		return false
	if requirement.get("type", "") == "capability":
		return capability_value_for_ships(state, str(requirement.get("id", "")), ship_ids) >= float(requirement.get("value", 1))
	return requirement_met(state, requirement)
