class_name ContentDatabase
extends RefCounted

var version := ""
var pack_metadata := {}
var simulation_profiles := {}
var factory_grid_rules := {}
var industry_rules := {}
var fleet_rules := {}
var freight_rules := {}
var survey_rules := {}
var definitions_by_canonical_id := {}
var domains := {}
var items := {}
var ships := {}
var modules := {}
var process_modules := {}
var universal_industry_plugins := {}
var facilities := {}
var resource_regions := {}
var combat_areas := {}
var logistics_routes := {}
var transport_modes := {}
var industrial_templates := {}
var activities := {}
var regions := {}
var goals := {}
var technologies := {}
var research_projects := {}
var ship_construction_projects := {}
var enemies := {}
var expedition_routes := {}
var megastructures := {}
var planet_visual_profiles := {}
var factory_buildings := {}
var factory_recipes := {}
var construction_engineering_requirements := {}
var activities_by_domain := {}
var progression_edges: Array[Dictionary] = []
var graph_validation_errors: Array[String] = []
var errors: Array[String] = []


func load_from_file(path: String) -> bool:
	clear()
	if not FileAccess.file_exists(path):
		errors.append("Content file not found: %s" % path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("Content root must be a JSON object")
		return false
	version = str(parsed.get("version", "unknown"))
	if version != GameVersion.PRODUCT_VERSION:
		errors.append("Content version %s does not match product version %s" % [version, GameVersion.PRODUCT_VERSION])
	pack_metadata = parsed.get("content_pack", {"id":"base", "version":version, "namespace":"base"}).duplicate(true)
	simulation_profiles = parsed.get("simulation_profiles", {}).duplicate(true)
	factory_grid_rules = parsed.get("factory_grid_rules", {}).duplicate(true)
	industry_rules = parsed.get("industry_rules", {}).duplicate(true)
	fleet_rules = parsed.get("fleet_rules", {}).duplicate(true)
	freight_rules = parsed.get("freight_rules", {}).duplicate(true)
	survey_rules = parsed.get("survey_rules", {}).duplicate(true)
	construction_engineering_requirements = parsed.get("construction_engineering_requirements", {}).duplicate(true)
	_index_definitions(parsed.get("domains", []), domains, "domain")
	_index_definitions(parsed.get("items", []), items, "item")
	_apply_freight_profiles()
	_apply_storage_profiles()
	_index_definitions(parsed.get("ships", []), ships, "ship")
	_index_definitions(parsed.get("modules", []), modules, "module")
	_index_definitions(parsed.get("process_modules", []), process_modules, "process_module")
	_index_definitions(parsed.get("universal_industry_plugins", []), universal_industry_plugins, "universal_industry_plugin")
	_index_definitions(parsed.get("facilities", []), facilities, "facility")
	_index_definitions(parsed.get("resource_regions", []), resource_regions, "resource_region")
	_index_definitions(parsed.get("combat_areas", []), combat_areas, "combat_area")
	_index_definitions(parsed.get("logistics_routes", []), logistics_routes, "logistics_route")
	_index_definitions(parsed.get("transport_modes", []), transport_modes, "transport_mode")
	_index_definitions(parsed.get("industrial_templates", []), industrial_templates, "industrial_template")
	_index_definitions(parsed.get("activities", []), activities, "activity")
	_index_definitions(parsed.get("regions", []), regions, "region")
	_index_definitions(parsed.get("goals", []), goals, "goal")
	_index_definitions(parsed.get("technologies", []), technologies, "technology")
	_index_definitions(parsed.get("research_projects", []), research_projects, "research_project")
	_index_definitions(parsed.get("ship_construction_projects", []), ship_construction_projects, "ship_construction_project")
	_index_definitions(parsed.get("enemies", []), enemies, "enemy")
	_index_definitions(parsed.get("expedition_routes", []), expedition_routes, "expedition_route")
	_index_definitions(parsed.get("megastructures", []), megastructures, "megastructure")
	_index_definitions(parsed.get("planet_visual_profiles", []), planet_visual_profiles, "planet_visual_profile")
	_index_definitions(parsed.get("factory_buildings", []), factory_buildings, "factory_building")
	_index_definitions(parsed.get("factory_recipes", []), factory_recipes, "factory_recipe")
	for domain_id in domains:
		activities_by_domain[domain_id] = []
	for activity in activities.values():
		var domain_id := str(activity.get("domain", ""))
		if activities_by_domain.has(domain_id):
			activities_by_domain[domain_id].append(activity)
	validate()
	_build_progression_graph()
	_validate_unlock_graph()
	return errors.is_empty()


func clear() -> void:
	version = ""
	domains.clear()
	items.clear()
	ships.clear()
	modules.clear()
	process_modules.clear()
	universal_industry_plugins.clear()
	facilities.clear()
	resource_regions.clear()
	combat_areas.clear()
	logistics_routes.clear()
	transport_modes.clear()
	industrial_templates.clear()
	activities.clear()
	regions.clear()
	goals.clear()
	technologies.clear()
	research_projects.clear()
	ship_construction_projects.clear()
	enemies.clear()
	expedition_routes.clear()
	megastructures.clear()
	planet_visual_profiles.clear()
	factory_buildings.clear()
	factory_recipes.clear()
	construction_engineering_requirements.clear()
	activities_by_domain.clear()
	progression_edges.clear()
	graph_validation_errors.clear()
	pack_metadata.clear()
	simulation_profiles.clear()
	factory_grid_rules.clear()
	industry_rules.clear()
	fleet_rules.clear()
	freight_rules.clear()
	survey_rules.clear()
	definitions_by_canonical_id.clear()
	errors.clear()


func validate() -> void:
	var produced_items := {}
	var consumed_items := {}
	var unique_ship_grants := {}
	# Grid deposits are deterministic production sources owned by factory worlds,
	# not activities or ships. The bootstrap contract lists the resource types
	# that world generation may place as fixed deposits.
	for item_id_value in industry_rules.get("bootstrap_contract", {}).get("progression_extractable_item_ids", []):
		produced_items[str(item_id_value)] = true
	for forbidden_collection in [technologies, research_projects, expedition_routes, megastructures, goals]:
		for definition_id_value in (forbidden_collection as Dictionary).keys():
			if "interstellar" in str(definition_id_value).to_lower():
				errors.append("The single-system core cannot expose interstellar content: %s" % definition_id_value)
	_validate_simulation_profiles()
	_validate_factory_grid_content()
	_validate_ship_role_contract()
	if float(industry_rules.get("economy_of_scale_per_level", 0.0)) < 0.0 or float(industry_rules.get("economy_of_scale_cap", 0.0)) < 0.0:
		errors.append("industry_rules must define non-negative Economy of Scale values")
	if float(industry_rules.get("production_speed_multiplier", 0.0)) <= 0.0:
		errors.append("industry_rules production_speed_multiplier must be positive")
	if float(industry_rules.get("expansion_cost_growth", 0.0)) < 0.0:
		errors.append("industry_rules expansion_cost_growth must be non-negative")
	_validate_item_entries(industry_rules.get("expansion_base_costs", []), "industry_rules")
	for transformation_id_value in industry_rules.get("industrial_transformations", {}).keys():
		var transformation_id := str(transformation_id_value)
		var transformation: Dictionary = industry_rules.get("industrial_transformations", {}).get(transformation_id, {})
		if float(transformation.get("work_required", 0.0)) <= 0.0 or float(transformation.get("downtime_multiplier", -1.0)) < 0.0 or float(transformation.get("downtime_multiplier", 2.0)) > 1.0:
			errors.append("Industrial Transformation '%s' has invalid work or downtime" % transformation_id)
		_validate_item_entries(transformation.get("costs", []), "Industrial Transformation '%s'" % transformation_id)
	if not items.has(str(fleet_rules.get("maintenance_item", ""))):
		errors.append("fleet_rules references a missing maintenance item")
	for maintenance_state in ["ACTIVE", "READY_RESERVE", "MOTHBALLED"]:
		if float(fleet_rules.get("maintenance_rates", {}).get(maintenance_state, -1.0)) < 0.0:
			errors.append("fleet_rules must define non-negative maintenance rate for %s" % maintenance_state)
	if float(fleet_rules.get("reactivation_material_per_command", 0.0)) <= 0.0 or float(fleet_rules.get("reactivation_ms_per_command", 0.0)) <= 0.0:
		errors.append("fleet_rules must define positive Mothball reactivation costs")
	if float(fleet_rules.get("scrap_recovery_fraction", 0.0)) <= 0.0 or float(fleet_rules.get("scrap_recovery_fraction", 0.0)) >= 1.0:
		errors.append("fleet_rules scrap recovery must be between zero and one")
	for slot_value in industry_rules.get("module_bom_defaults", {}).keys():
		_validate_item_entries(industry_rules.get("module_bom_defaults", {}).get(slot_value, []), "industry_rules module BOM '%s'" % slot_value)
	for module_value in modules.values():
		var module := module_value as Dictionary
		if not bool(module.get("special_equipment", false)):
			var module_id := str(module.get("id", ""))
			if module_bom(module_id).is_empty():
				errors.append("ordinary module '%s' must resolve to a manufacturing BOM" % module.get("id", "?"))
		var weapon_kind := str(module.get("weapon_kind", module.get("combat_stats", {}).get("weapon_kind", "DIRECT"))).to_upper()
		if weapon_kind not in ["DIRECT", "MISSILE", "STRIKE_CRAFT", "PENETRATION"]:
			errors.append("module '%s' has invalid weapon_kind '%s'" % [module.get("id", "?"), weapon_kind])
		for defense_stat in ["point_defense", "electronic_warfare", "shield_penetration"]:
			var defense_value := float(module.get("combat_stats", {}).get(defense_stat, 0.0))
			if defense_value < 0.0 or defense_value > 1.0:
				errors.append("module '%s' combat stat '%s' must be between zero and one" % [module.get("id", "?"), defense_stat])
	var logistics_tiers := {}
	for technology_value in technologies.values():
		var technology := technology_value as Dictionary
		if not technology.has("logistics_tier"):
			continue
		var logistics_tier := int(technology.get("logistics_tier", 0))
		if logistics_tier <= 0 or logistics_tiers.has(logistics_tier):
			errors.append("logistics technology '%s' has an invalid or duplicate tier" % technology.get("id", "?"))
		logistics_tiers[logistics_tier] = true
		for multiplier_key in ["freight_capacity_multiplier", "transit_time_multiplier", "fuel_cost_multiplier"]:
			if float(technology.get(multiplier_key, -1.0)) < 0.0:
				errors.append("logistics technology '%s' has invalid %s" % [technology.get("id", "?"), multiplier_key])
	for template in industrial_templates.values():
		var template_label := "industrial template '%s'" % template.get("id", "?")
		var template_items := {}
		if template.get("policies", []).is_empty():
			errors.append("%s must define at least one logistics policy" % template_label)
		if int(template.get("auto_expand_target", 0)) < 1:
			errors.append("%s must define a positive auto_expand_target" % template_label)
		for facility_value in template.get("managed_facilities", []):
			if not facilities.has(str(facility_value)) or str(facility_value) not in SpaceGameState.MANUFACTURING_FACILITY_IDS:
				errors.append("%s manages invalid manufacturing facility '%s'" % [template_label, facility_value])
		for policy_value in template.get("policies", []):
			var policy := policy_value as Dictionary
			var item_id := str(policy.get("item", ""))
			if not items.has(item_id):
				errors.append("%s references missing item '%s'" % [template_label, item_id])
			if template_items.has(item_id):
				errors.append("%s defines duplicate item '%s'" % [template_label, item_id])
			template_items[item_id] = true
			if str(policy.get("mode", "")) not in ["SUPPLY", "DEMAND", "STORAGE"]:
				errors.append("%s has invalid logistics mode" % template_label)
			if int(policy.get("reserve", 0)) < 0 or int(policy.get("target", 0)) < 0 or int(policy.get("dispatch_threshold", 1)) <= 0:
				errors.append("%s has invalid stock or dispatch values" % template_label)
	for route in logistics_routes.values():
		var route_label := "logistics route '%s'" % route.get("id", "?")
		var from_id := str(route.get("from", ""))
		var to_id := str(route.get("to", ""))
		if not regions.has(from_id) or not regions.has(to_id) or from_id == to_id:
			errors.append("%s must connect two different known Locations" % route_label)
		if float(route.get("transit_time_ms", 0.0)) <= 0.0:
			errors.append("%s must define positive transit_time_ms" % route_label)
		if int(route.get("freight_capacity", 0)) <= 0:
			errors.append("%s must define positive freight_capacity" % route_label)
		if not transport_modes.has(str(route.get("default_transport_mode", ""))):
			errors.append("%s must reference a valid default Transport Mode" % route_label)
		_validate_item_entries(route.get("dispatch_costs", []), route_label)
	if megastructures.size() != 1:
		errors.append("The single-system core must define exactly one Megastructure")
	for megastructure in megastructures.values():
		var megastructure_label := "megastructure '%s'" % megastructure.get("id", "?")
		var phases: Array = megastructure.get("phases", [])
		if phases.size() < 6 or phases.size() > 8:
			errors.append("%s must define six to eight meaningful phases" % megastructure_label)
		var seen_phase_ids := {}
		for phase_index in phases.size():
			var phase := phases[phase_index] as Dictionary
			var phase_id := str(phase.get("id", ""))
			if phase_id.is_empty() or seen_phase_ids.has(phase_id) or str(phase.get("name", "")).is_empty():
				errors.append("%s has an empty or duplicate phase" % megastructure_label)
			seen_phase_ids[phase_id] = true
			var activity_id := str(phase.get("activity_id", ""))
			if phase_index == 0:
				if str(phase.get("kind", "")) != "SITE_SELECTION" or not activity_id.is_empty():
					errors.append("%s phase zero must be Research and Site Selection" % megastructure_label)
			else:
				if not activities.has(activity_id) or not bool(activities.get(activity_id, {}).get("construction_project", false)):
					errors.append("%s phase '%s' must reference a real Construction Project" % [megastructure_label, phase_id])
			for requirement in phase.get("requirements", []):
				_validate_requirement(requirement, "%s phase '%s'" % [megastructure_label, phase_id])
		for candidate_value in megastructure.get("site_candidates", []):
			var candidate_id := str(candidate_value)
			if not regions.has(candidate_id) or str(regions.get(candidate_id, {}).get("system_id", "")) != SpaceGameState.SYSTEM_ID:
				errors.append("%s references an invalid single-system site candidate" % megastructure_label)
		if not phases.is_empty():
			var final_activity: Dictionary = activities.get(str((phases[-1] as Dictionary).get("activity_id", "")), {})
			var final_effect_types: Array = final_activity.get("effects", []).map(func(effect): return str((effect as Dictionary).get("type", "")))
			if not final_effect_types.has("complete_megastructure") or not final_effect_types.has("complete_game"):
				errors.append("%s final phase must complete the Megastructure and the game" % megastructure_label)
	for region in regions.values():
		var region_label := "Location '%s'" % region.get("id", "?")
		if str(region.get("system_id", "")).is_empty():
			errors.append("%s must declare system_id" % region_label)
		if str(region.get("location_type", "")) not in [LocationState.NATURAL, LocationState.ARTIFICIAL]:
			errors.append("%s has invalid location_type" % region_label)
		var access_region := str(region.get("access_region", ""))
		if not access_region.is_empty() and (not regions.has(access_region) or access_region == str(region.get("id", ""))):
			errors.append("%s references an invalid access_region '%s'" % [region_label, access_region])
	for activity in activities.values():
		var label := "activity '%s'" % activity.get("id", "?")
		if not domains.has(str(activity.get("domain", ""))):
			errors.append("%s has an invalid domain" % label)
		if float(activity.get("duration_ms", 0)) <= 0:
			errors.append("%s must have a positive duration" % label)
		if activity.get("domain", "") == "industry":
			if float(activity.get("work_required", 0)) <= 0:
				errors.append("%s must define positive work_required" % label)
			var facility_id := str(activity.get("facility", ""))
			if not facilities.has(facility_id):
				errors.append("%s references a missing facility" % label)
			elif bool(activity.get("repeat", true)) and int(facilities[facility_id].get("manufacturing_generation", 0)) <= 0:
				errors.append("%s repeat recipe must belong to a manufacturing regime" % label)
			if bool(activity.get("repeat", true)) and activity.get("required_facility_capabilities", []).is_empty():
				errors.append("%s repeat recipe must declare at least one manufacturing capability" % label)
			if float(activity.get("production_energy_multiplier", 1.0)) <= 0.0:
				errors.append("%s must define a positive production energy multiplier" % label)
			for capability_id in activity.get("required_facility_capabilities", []):
				if str(capability_id).is_empty():
					errors.append("%s has an empty facility capability" % label)
			if bool(activity.get("automation_eligible", false)):
				var automation_category := str(activity.get("automation_category", ""))
				if automation_category.is_empty() or automation_category != str(activity.get("production_family", "")):
					errors.append("%s has an invalid automation category" % label)
				var automation_unlock := str(activity.get("automation_unlock", ""))
				if not automation_unlock.is_empty() and not technologies.has(automation_unlock):
					errors.append("%s references a missing automation technology" % label)
			if bool(activity.get("repeat", true)):
				var technology_gated := false
				for requirement in activity.get("requirements", []):
					technology_gated = technology_gated or _requirement_leaves(requirement).any(func(leaf): return str(leaf.get("type", "")) == "technology")
				if technology_gated and not activity.has("reveal_requirements"):
					errors.append("%s must declare reveal_requirements for its Technology-gated production recipe" % label)
		if activity.get("domain", "") == "expedition":
			var enemy_id := str(activity.get("enemy", ""))
			if str(activity.get("encounter_type", "")) in ["COMBAT", "BOSS"] and not enemies.has(enemy_id):
				errors.append("%s references a missing combat enemy" % label)
			for requirement in activity.get("build_requirements", []):
				_validate_requirement(requirement, label)
		_validate_item_entries(activity.get("costs", []), label)
		_validate_item_entries(activity.get("rewards", []), label)
		_validate_item_entries(activity.get("waste", []), "%s waste" % label)
		for cost in activity.get("costs", []):
			consumed_items[str(cost.get("item", ""))] = true
		for reward in activity.get("rewards", []):
			produced_items[str(reward.get("item", ""))] = true
		for waste in activity.get("waste", []):
			produced_items[str(waste.get("item", ""))] = true
		if activity.get("domain", "") == "industry" and bool(activity.get("repeat", true)) and activity.get("costs", []).is_empty() and not activity.get("rewards", []).is_empty():
			errors.append("%s creates a zero-cost infinite production loop" % label)
		for loot in activity.get("loot", []):
			if not items.has(str(loot.get("item", ""))):
				errors.append("%s references missing loot" % label)
			produced_items[str(loot.get("item", ""))] = true
		for requirement in activity.get("requirements", []):
			_validate_requirement(requirement, label)
		for requirement in activity.get("reveal_requirements", []):
			_validate_requirement(requirement, "%s reveal rule" % label)
		for effect in activity.get("effects", []):
			var effect_type := str(effect.get("type", ""))
			_validate_effect(effect, label)
			if effect_type == "add_ship" and not ships.has(str(effect.get("ship", ""))):
				errors.append("%s references missing ship" % label)
			elif effect_type == "add_ship":
				var ship_id := str(effect.get("ship", ""))
				if unique_ship_grants.has(ship_id):
					errors.append("Unique ship '%s' has multiple grant paths" % ship_id)
				unique_ship_grants[ship_id] = activity.get("id", "")
			if effect_type == "unlock_region" and not regions.has(str(effect.get("region", ""))):
				errors.append("%s references missing region" % label)
			if effect_type == "unlock_facility" and not facilities.has(str(effect.get("facility", ""))):
				errors.append("%s references missing facility" % label)
	for activity_id in construction_engineering_requirements:
		if not activities.has(str(activity_id)):
			errors.append("construction engineering map references missing activity '%s'" % activity_id)
		elif int(construction_engineering_requirements[activity_id]) not in [1, 2, 3]:
			errors.append("construction activity '%s' has invalid Engineering Capability requirement" % activity_id)
	for goal in goals.values():
		for requirement in goal.get("requirements", []):
			_validate_requirement(requirement, "goal '%s'" % goal.get("id", "?"))
		var step_ids := {}
		for step in goal.get("steps", []):
			var step_id := str(step.get("id", ""))
			if step_id.is_empty() or step_ids.has(step_id):
				errors.append("goal '%s' has an empty or duplicate tutorial step id" % goal.get("id", "?"))
			step_ids[step_id] = true
			if str(step.get("view", "")) not in ["overview", "mining", "industry", "expedition", "infrastructure", "research", "ships", "warehouse", "regions", "location", "megastructure", "completion"]:
				errors.append("goal '%s' tutorial step '%s' has an invalid view" % [goal.get("id", "?"), step_id])
			if step.get("requirements", []).is_empty():
				errors.append("goal '%s' tutorial step '%s' has no requirements" % [goal.get("id", "?"), step_id])
			for requirement in step.get("requirements", []):
				_validate_requirement(requirement, "goal '%s' step '%s'" % [goal.get("id", "?"), step_id])
	for project in research_projects.values():
		var project_label := "research project '%s'" % project.get("id", "?")
		if str(project.get("project_type", "TECHNOLOGY")) not in ["TECHNOLOGY", "SHIP_DEVELOPMENT"]:
			errors.append("%s has an invalid project type" % project_label)
		if float(project.get("duration_ms", 0)) <= 0:
			errors.append("%s must have positive duration" % project_label)
		for role in project.get("research_roles", []):
			if str(role) not in ["EXPANSION", "CONSOLIDATION"]:
				errors.append("%s has invalid research role '%s'" % [project_label, role])
		_validate_item_entries(project.get("costs", []), project_label)
		for requirement in project.get("requirements", []):
			_validate_requirement(requirement, project_label)
		var technology_id := str(project.get("grants_technology", ""))
		if not technology_id.is_empty() and not technologies.has(technology_id):
			errors.append("%s grants missing technology '%s'" % [project_label, technology_id])
		var plan_id := str(project.get("grants_ship_plan", ""))
		if not plan_id.is_empty() and not ship_construction_projects.has(plan_id):
			errors.append("%s grants missing ship construction plan '%s'" % [project_label, plan_id])
		for effect in project.get("effects", []):
			_validate_effect(effect, project_label)
		for spillover_id_value in project.get("spillover_work_reductions", {}).keys():
			var spillover_id := str(spillover_id_value)
			var reduction := float(project.get("spillover_work_reductions", {}).get(spillover_id, 0.0))
			if not technologies.has(spillover_id) or str(technologies.get(spillover_id, {}).get("result_kind", "")) != "SPILLOVER":
				errors.append("%s references missing Spillover work reduction '%s'" % [project_label, spillover_id])
			if reduction <= 0.0 or reduction > 0.45:
				errors.append("%s has invalid Spillover work reduction for '%s'" % [project_label, spillover_id])
		var effect_tags: Array = project.get("effect_tags", [])
		if effect_tags.any(func(tag): return str(tag) not in ["UNLOCK", "METHOD", "SYSTEM"]):
			errors.append("%s has an invalid R&D effect tag" % project_label)
		var stages: Array = project.get("stages", [])
		if not stages.is_empty() and not project.get("costs", []).is_empty():
			errors.append("%s defines ambiguous top-level costs; staged programs must use stages[].costs as the only runtime cost authority" % project_label)
		if bool(project.get("major_program", false)) and (stages.size() < 3 or stages.size() > 5):
			errors.append("%s must contain 3-5 meaningful stages" % project_label)
		var stage_ids := {}
		for stage_value in stages:
			var stage := stage_value as Dictionary
			var stage_id := str(stage.get("id", ""))
			var stage_label := "%s stage '%s'" % [project_label, stage_id]
			if stage_id.is_empty() or stage_ids.has(stage_id):
				errors.append("%s has an empty or duplicate stage id" % project_label)
			stage_ids[stage_id] = true
			if str(stage.get("kind", "")) not in ["THEORY", "EXPERIMENT", "ENGINEERING", "PROTOTYPE", "FIELD_TEST", "INDUSTRIALIZATION"]:
				errors.append("%s has an invalid stage kind" % stage_label)
			if str(stage.get("kind", "")) != "FIELD_TEST" and float(stage.get("work_required", 0.0)) <= 0.0:
				errors.append("%s must define positive work" % stage_label)
			_validate_item_entries(stage.get("costs", []), stage_label)
			for requirement in stage.get("requirements", []) + stage.get("operating_conditions", []):
				_validate_requirement(requirement, stage_label)
			for effect in stage.get("completion_effects", []):
				_validate_effect(effect, stage_label)
		var route_ids := {}
		for route_value in project.get("routes", []):
			var route := route_value as Dictionary
			var route_id := str(route.get("id", ""))
			if route_id.is_empty() or route_ids.has(route_id) or float(route.get("work_multiplier", 1.0)) <= 0.0:
				errors.append("%s has an invalid or duplicate engineering route" % project_label)
			route_ids[route_id] = true
			for effect in route.get("completion_effects", []):
				_validate_effect(effect, "%s route '%s'" % [project_label, route_id])
		for reward_value in project.get("domain_rewards", []):
			var reward := reward_value as Dictionary
			if str(reward.get("domain", "")) not in SpaceGameState.TECHNOLOGY_DOMAIN_IDS or float(reward.get("xp", 0.0)) <= 0.0:
				errors.append("%s has an invalid Technology Domain reward" % project_label)
	for plan in ship_construction_projects.values():
		var plan_label := "ship construction project '%s'" % plan.get("id", "?")
		var ship_id := str(plan.get("ship_id", ""))
		if not ships.has(ship_id):
			errors.append("%s references missing ship '%s'" % [plan_label, ship_id])
		elif not ship_loadout_valid(ship_id, plan.get("starting_modules", [])):
			errors.append("%s has an invalid starting loadout: %s" % [plan_label, ship_loadout_error(ship_id, plan.get("starting_modules", []))])
		for module_id_value in plan.get("starting_modules", []):
			var module_id := str(module_id_value)
			if bool(modules.get(module_id, {}).get("special_equipment", false)):
				errors.append("%s cannot create UUID special equipment from a starting-module definition" % plan_label)
		if unique_ship_grants.has(ship_id):
			errors.append("Unique ship '%s' has multiple construction plans" % ship_id)
		unique_ship_grants[ship_id] = plan.get("id", "")
		if float(plan.get("cycle_time_ms", 0.0)) <= 0.0 or int(plan.get("engineering_required", 0)) <= 0:
			errors.append("%s must define positive cycle time and Engineering Capability" % plan_label)
		_validate_item_entries(plan.get("fixed_costs", []), plan_label)
		_validate_item_entries(plan.get("costs", []), plan_label)
		for requirement in plan.get("requirements", []):
			_validate_requirement(requirement, plan_label)
	for route in expedition_routes.values():
		var route_label := "expedition route '%s'" % route.get("id", "?")
		if route.get("nodes", []).is_empty():
			errors.append("%s has no nodes" % route_label)
		for requirement in route.get("requirements", []):
			_validate_requirement(requirement, route_label)
		for node in route.get("nodes", []):
			if str(node.get("phase", "")) not in ["TRAVEL", "EXPLORE", "ENCOUNTER", "COMBAT", "EVENT", "HAZARD", "CHECKPOINT", "BOSS", "RETURN"]:
				errors.append("%s has invalid phase '%s'" % [route_label, node.get("phase", "")])
			if float(node.get("duration_ms", 0)) <= 0:
				errors.append("%s node must have positive duration" % route_label)
			var enemy_id := str(node.get("enemy", ""))
			if not enemy_id.is_empty() and not enemies.has(enemy_id):
				errors.append("%s references missing enemy '%s'" % [route_label, enemy_id])
			_validate_item_entries(node.get("rewards", []), route_label)
	for ship in ships.values():
		var ship_skill_ids: Dictionary = {}
		for skill in ship.get("combat_skills", []):
			var skill_id := str(skill.get("id", ""))
			if skill_id.is_empty() or ship_skill_ids.has(skill_id):
				errors.append("ship '%s' has a missing or duplicate combat skill id" % ship.get("id", "?"))
			ship_skill_ids[skill_id] = true
			if skill.has("chance") or float(skill.get("cycle_time_ms", 0.0)) <= 0.0 or float(skill.get("damage_multiplier", 1.0)) < 0.0:
				errors.append("ship '%s' skill '%s' must use a positive independent Skill Cycle" % [ship.get("id", "?"), skill_id])
		var trigger_ids: Dictionary = {}
		for trigger in ship.get("attack_triggers", []):
			var trigger_id := str(trigger.get("id", ""))
			if trigger_id.is_empty() or trigger_ids.has(trigger_id):
				errors.append("ship '%s' has a missing or duplicate attack trigger id" % ship.get("id", "?"))
			trigger_ids[trigger_id] = true
			if int(trigger.get("every_attacks", 0)) <= 0 or float(trigger.get("damage_multiplier", 1.0)) < 0.0:
				errors.append("ship '%s' attack trigger '%s' must define a positive attack count and valid effect" % [ship.get("id", "?"), trigger_id])
	for enemy in enemies.values():
		for stat in ["hull", "shield", "armor", "damage", "attack_interval_ms", "accuracy", "evasion"]:
			if float(enemy.get(stat, -1)) < 0:
				errors.append("enemy '%s' has invalid stat '%s'" % [enemy.get("id", "?"), stat])
		if float(enemy.get("attack_interval_ms", 0.0)) <= 0.0:
			errors.append("enemy '%s' must have a positive attack interval" % enemy.get("id", "?"))
		if enemy.get("phases", []).is_empty():
			var root_skill_ids: Dictionary = {}
			for skill in enemy.get("skills", []):
				var skill_id := str(skill.get("id", ""))
				if skill_id.is_empty() or root_skill_ids.has(skill_id):
					errors.append("enemy '%s' has a missing or duplicate skill id" % enemy.get("id", "?"))
				root_skill_ids[skill_id] = true
				if float(skill.get("cycle_time_ms", 0.0)) <= 0.0 or float(skill.get("damage_multiplier", 1.0)) < 0.0 or float(skill.get("shield_restore", 0.0)) < 0.0:
					errors.append("enemy '%s' skill '%s' has invalid combat values" % [enemy.get("id", "?"), skill_id])
		var phase_ids: Dictionary = {}
		for phase in enemy.get("phases", []):
			var phase_id := str(phase.get("id", ""))
			if phase_id.is_empty() or phase_ids.has(phase_id):
				errors.append("enemy '%s' has a missing or duplicate phase id" % enemy.get("id", "?"))
			phase_ids[phase_id] = true
			for stat in ["hull", "shield", "armor", "damage", "accuracy", "evasion"]:
				if phase.has(stat) and float(phase.get(stat, -1.0)) < 0.0:
					errors.append("enemy '%s' phase '%s' has invalid stat '%s'" % [enemy.get("id", "?"), phase_id, stat])
			if phase.has("attack_interval_ms") and float(phase.get("attack_interval_ms", 0.0)) <= 0.0:
				errors.append("enemy '%s' phase '%s' must have a positive attack interval" % [enemy.get("id", "?"), phase_id])
			var skill_ids: Dictionary = {}
			for skill in phase.get("skills", []):
				var skill_id := str(skill.get("id", ""))
				if skill_id.is_empty() or skill_ids.has(skill_id):
					errors.append("enemy '%s' phase '%s' has a missing or duplicate skill id" % [enemy.get("id", "?"), phase_id])
				skill_ids[skill_id] = true
				if float(skill.get("cycle_time_ms", 0.0)) <= 0.0 or float(skill.get("damage_multiplier", 1.0)) < 0.0 or float(skill.get("shield_restore", 0.0)) < 0.0:
					errors.append("enemy '%s' skill '%s' has invalid combat values" % [enemy.get("id", "?"), skill_id])
				if skill.has("apply_status"):
					var status: Dictionary = skill.get("apply_status", {})
					if str(status.get("id", "")).is_empty() or str(status.get("target", "")) not in ["FLEET", "ENEMY"] or int(status.get("duration_events", 0)) <= 0 or int(status.get("max_stacks", 0)) <= 0:
						errors.append("enemy '%s' skill '%s' has an invalid status effect" % [enemy.get("id", "?"), skill_id])
	for module in modules.values():
		var module_domain := str(module.get("domain", ""))
		if not module_domain.is_empty() and not domains.has(module_domain):
			errors.append("module '%s' has an invalid domain contribution" % module.get("id", "?"))
		if str(module.get("slot", "")) not in ["weapon", "shield", "drive", "utility", "core"]:
			errors.append("module '%s' has an invalid slot type" % module.get("id", "?"))
		if not items.has(str(module.get("id", ""))):
			errors.append("module '%s' requires matching recipe-catalog metadata" % module.get("id", "?"))
		var module_skill_ids: Dictionary = {}
		for skill in module.get("combat_skills", []):
			var skill_id := str(skill.get("id", ""))
			if skill_id.is_empty() or module_skill_ids.has(skill_id):
				errors.append("module '%s' has a missing or duplicate combat skill id" % module.get("id", "?"))
			module_skill_ids[skill_id] = true
			if skill.has("chance") or float(skill.get("cycle_time_ms", 0.0)) <= 0.0 or float(skill.get("damage_multiplier", 1.0)) < 0.0:
				errors.append("module '%s' skill '%s' has invalid combat values" % [module.get("id", "?"), skill_id])
			if skill.has("apply_status"):
				var status: Dictionary = skill.get("apply_status", {})
				if str(status.get("id", "")).is_empty() or str(status.get("target", "")) not in ["FLEET", "ENEMY"] or int(status.get("duration_events", 0)) <= 0 or int(status.get("max_stacks", 0)) <= 0:
					errors.append("module '%s' skill '%s' has an invalid status effect" % [module.get("id", "?"), skill_id])
		var module_trigger_ids: Dictionary = {}
		for trigger in module.get("combat_attack_triggers", []):
			var trigger_id := str(trigger.get("id", ""))
			if trigger_id.is_empty() or module_trigger_ids.has(trigger_id):
				errors.append("module '%s' has a missing or duplicate attack trigger id" % module.get("id", "?"))
			module_trigger_ids[trigger_id] = true
			if int(trigger.get("every_attacks", 0)) <= 0 or float(trigger.get("damage_multiplier", 1.0)) < 0.0:
				errors.append("module '%s' attack trigger '%s' must define a positive attack count and valid effect" % [module.get("id", "?"), trigger_id])
	for facility in facilities.values():
		var capital_project_facility := str(facility.get("category", "")) in ["Construction", "Starport"]
		if capital_project_facility and float(facility.get("productivity_bonus", 0.0)) > 0.0:
			errors.append("capital-project facility '%s' cannot define productivity_bonus" % facility.get("id", "?"))
		if float(facility.get("baseline_power_generation", facility.get("power_generation", 0.0))) < 0.0 or float(facility.get("baseline_power_demand", facility.get("power_demand", 0.0))) < 0.0 or float(facility.get("advanced_power_generation", 0.0)) < 0.0 or float(facility.get("advanced_power_demand", 0.0)) < 0.0:
			errors.append("facility '%s' has invalid civilization power values" % facility.get("id", "?"))
		if float(facility.get("baseline_power_generation_per_level", facility.get("power_generation_per_level", 0.0))) < 0.0 or float(facility.get("baseline_power_demand_per_level", facility.get("power_demand_per_level", 0.0))) < 0.0 or float(facility.get("advanced_power_generation_per_level", 0.0)) < 0.0 or float(facility.get("advanced_power_demand_per_level", 0.0)) < 0.0:
			errors.append("facility '%s' has invalid per-level power values" % facility.get("id", "?"))
		if int(facility.get("module_slots", 0)) < 0:
			errors.append("facility '%s' has invalid module slot count" % facility.get("id", "?"))
		var generation := int(facility.get("manufacturing_generation", 0))
		if generation < 0 or generation > 6:
			errors.append("facility '%s' has invalid manufacturing generation" % facility.get("id", "?"))
		if generation > 0 and (int(facility.get("process_module_slots", 0)) < 0 or int(facility.get("plugin_slots", 0)) < 0):
			errors.append("manufacturing facility '%s' has invalid specialization slots" % facility.get("id", "?"))
		if float(facility.get("construction_capacity", 0.0)) < 0.0:
			errors.append("facility '%s' has invalid construction capacity" % facility.get("id", "?"))
		for upgrade_id in facility.get("upgrade_modules", {}):
			var upgrade: Dictionary = facility["upgrade_modules"][upgrade_id]
			if capital_project_facility and float(upgrade.get("productivity_bonus", 0.0)) > 0.0:
				errors.append("capital-project facility '%s' upgrade module '%s' cannot define productivity_bonus" % [facility.get("id", "?"), upgrade_id])
			if float(upgrade.get("baseline_power_demand", 0.0)) < 0.0 or float(upgrade.get("advanced_power_demand", 0.0)) < 0.0:
				errors.append("facility '%s' upgrade module '%s' has invalid fixed power demand" % [facility.get("id", "?"), upgrade_id])
			if float(upgrade.get("construction_capacity", 0.0)) < 0.0:
				errors.append("facility '%s' upgrade module '%s' has invalid construction capacity" % [facility.get("id", "?"), upgrade_id])
			_validate_item_entries(upgrade.get("costs", []), "facility module '%s:%s'" % [facility.get("id", "?"), upgrade_id])
			for requirement in upgrade.get("requirements", []):
				_validate_requirement(requirement, "facility module '%s:%s'" % [facility.get("id", "?"), upgrade_id])
		var maintenance_item := str(facility.get("advanced_maintenance_item", ""))
		if not maintenance_item.is_empty() and not items.has(maintenance_item):
			errors.append("facility '%s' references missing advanced maintenance item" % facility.get("id", "?"))
		if float(facility.get("advanced_maintenance_per_hour", 0.0)) < 0.0:
			errors.append("facility '%s' has invalid advanced maintenance demand" % facility.get("id", "?"))
		if str(facility.get("advanced_power_priority", "NORMAL")) not in ["CRITICAL", "HIGH", "NORMAL", "LOW"]:
			errors.append("facility '%s' has invalid advanced power priority" % facility.get("id", "?"))
		var automation_category := str(facility.get("automation_category", ""))
		if not automation_category.is_empty() and automation_category not in ["mining", "regional_extraction", "metallurgy", "electronics", "assembly", "chemical", "energy"]:
			errors.append("facility '%s' has an invalid automation category" % facility.get("id", "?"))
	for process_module in process_modules.values():
		_validate_manufacturing_module(process_module, "process module")
		if process_module.get("compatible_facilities", []).is_empty():
			errors.append("process module '%s' has no compatible facility" % process_module.get("id", "?"))
		for facility_id in process_module.get("compatible_facilities", []):
			if not facilities.has(str(facility_id)):
				errors.append("process module '%s' references missing facility '%s'" % [process_module.get("id", "?"), facility_id])
	for plugin in universal_industry_plugins.values():
		_validate_manufacturing_module(plugin, "universal industry plugin")
		for generation in plugin.get("compatible_generations", []):
			if int(generation) < 1 or int(generation) > 6:
				errors.append("universal industry plugin '%s' has invalid compatible generation" % plugin.get("id", "?"))
	for resource_region in resource_regions.values():
		if not regions.has(str(resource_region.get("region", ""))):
			errors.append("resource region '%s' references a missing space region" % resource_region.get("id", "?"))
	for area in combat_areas.values():
		if not regions.has(str(area.get("region", ""))):
			errors.append("combat area '%s' references a missing region" % area.get("id", "?"))
		var activity_id := str(area.get("activity", ""))
		if not activity_id.is_empty() and not activities.has(activity_id):
			errors.append("combat area '%s' references a missing activity" % area.get("id", "?"))
		var route_id := str(area.get("route", ""))
		if not route_id.is_empty() and not expedition_routes.has(route_id):
			errors.append("combat area '%s' references a missing first-clear route" % area.get("id", "?"))
	for ship in ships.values():
		if int(ship.get("module_slots", -1)) < 0:
			errors.append("ship '%s' has invalid module slots" % ship.get("id", "?"))
		if not ship.get("capabilities", {}).is_empty():
			errors.append("ship '%s' grants mission capabilities from its hull; roles must come from its Loadout" % ship.get("id", "?"))
		var slot_total := 0
		for count in ship.get("slot_layout", {}).values():
			slot_total += int(count)
		if slot_total != int(ship.get("module_slots", 0)):
			errors.append("ship '%s' slot layout does not match module_slots" % ship.get("id", "?"))
	for item_id in consumed_items:
		if not produced_items.has(item_id):
			errors.append("Consumed item '%s' has no production source" % item_id)
	_validate_closed_economy()
	# Gameplay Lab ships no visual profiles, but keep the validator active so a
	# future optional presentation pack cannot introduce broken resource paths.
	_validate_planet_visual_profiles()
	_validate_progression_supply_gates()
	_validate_first_phase_progression_contract()
	_validate_second_phase_capital_contract()
	_validate_third_phase_industry_contract()
	_validate_fourth_phase_freight_contract()
	_validate_seventh_phase_inventory_contract()
	_validate_eighth_phase_geography_contract()
	_validate_core_content_contract()


func _validate_ship_role_contract() -> void:
	for retired_domain_id in ["mining", "salvaging"]:
		if domains.has(retired_domain_id):
			errors.append("ship-role contract forbids the retired '%s' activity domain" % retired_domain_id)
	var forbidden_fields := ["mining_power", "extraction_power", "extraction_method_efficiency", "salvage_power"]
	var forbidden_capabilities := [
		"mining", "laser_ablation", "deep_core_mining", "heavy_mining",
		"ice_harvesting", "bulk_extraction", "gas_collection",
		"exotic_containment", "construction_support"
	]
	for module_value in modules.values():
		var module := module_value as Dictionary
		var module_id := str(module.get("id", "?"))
		if str(module.get("domain", "")) in ["mining", "salvaging"]:
			errors.append("ship module '%s' uses a retired work domain" % module_id)
		for field in forbidden_fields:
			if module.has(field):
				errors.append("ship module '%s' exposes forbidden work field '%s'" % [module_id, field])
		for capability_id in forbidden_capabilities:
			if module.get("capabilities", {}).has(capability_id):
				errors.append("ship module '%s' exposes forbidden work capability '%s'" % [module_id, capability_id])
	for ship_value in ships.values():
		var ship := ship_value as Dictionary
		for field in forbidden_fields:
			if ship.has(field):
				errors.append("ship '%s' exposes forbidden work field '%s'" % [ship.get("id", "?"), field])
	for activity_value in activities.values():
		var activity := activity_value as Dictionary
		if str(activity.get("domain", "")) in ["mining", "salvaging"]:
			errors.append("activity '%s' uses a retired ship-work domain" % activity.get("id", "?"))
	for route_value in expedition_routes.values():
		var route := route_value as Dictionary
		for node_value in route.get("nodes", []):
			var node := node_value as Dictionary
			for effect_value in node.get("effects", []):
				var effect := effect_value as Dictionary
				if str(effect.get("type", "")) == "discover_mining_site":
					errors.append("expedition route '%s' still exposes a retired permanent mining site" % route.get("id", "?"))


func _validate_simulation_profiles() -> void:
	var profiles: Dictionary = simulation_profiles.get("profiles", {})
	var default_profile := str(simulation_profiles.get("default_profile", ""))
	if default_profile.is_empty() or not profiles.has(default_profile):
		errors.append("simulation_profiles must reference an existing default_profile")
	for required_profile in ["TEST_PROFILE", "NORMAL_PROFILE"]:
		if not profiles.has(required_profile):
			errors.append("simulation_profiles is missing %s" % required_profile)
	for profile_id_value in profiles.keys():
		var profile_id := str(profile_id_value)
		var profile: Dictionary = profiles.get(profile_id, {})
		if float(profile.get("shipyard", 0.0)) <= 0.0:
			errors.append("simulation profile '%s' must define a positive shipyard multiplier" % profile_id)


func _validate_factory_grid_content() -> void:
	if int(factory_grid_rules.get("tile_size_m", 0)) != 1:
		errors.append("factory_grid_rules must define one square metre tiles")
	if int(factory_grid_rules.get("generator_version", 0)) <= 0:
		errors.append("factory_grid_rules must define a positive generator version")
	if int(factory_grid_rules.get("chunk_size_tiles", 0)) <= 0:
		errors.append("factory_grid_rules must define a positive chunk size")
	if float(factory_grid_rules.get("simulation_step_seconds", 0.0)) <= 0.0:
		errors.append("factory_grid_rules must define a positive simulation step")
	if float(factory_grid_rules.get("base_construction_capacity_per_second", -1.0)) < 0.0:
		errors.append("factory_grid_rules must define non-negative base construction capacity")
	var starter: Dictionary = factory_grid_rules.get("starter_world", {})
	var starter_size: Dictionary = starter.get("size_tiles", {})
	if str(starter.get("world_id", "")).is_empty() or not regions.has(str(starter.get("location_id", ""))) or int(starter_size.get("x", 0)) <= 0 or int(starter_size.get("y", 0)) <= 0:
		errors.append("factory_grid_rules starter_world must define identity, known location and positive bounds")
	for deposit_value in starter.get("deposits", []):
		var deposit := deposit_value as Dictionary
		var deposit_size: Dictionary = deposit.get("size", {})
		if str(deposit.get("deposit_id", "")).is_empty() or not items.has(str(deposit.get("resource_id", ""))) or int(deposit_size.get("x", 0)) <= 0 or int(deposit_size.get("y", 0)) <= 0:
			errors.append("factory starter deposit has invalid identity, resource or size")
	for entity_value in starter.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("entity_id", "")).is_empty() or not factory_buildings.has(str(entity.get("definition_id", ""))):
			errors.append("factory starter entity has invalid identity or building definition")
		for item_id_value in entity.get("inventory", {}).keys():
			if not items.has(str(item_id_value)) or int(entity.get("inventory", {}).get(item_id_value, 0)) < 0:
				errors.append("factory starter entity has invalid inventory item '%s'" % item_id_value)
	var allowed_kinds := ["EXTRACTOR", "MACHINE", "STORAGE", "POWER", "CONSTRUCTION"]
	for definition_value in factory_buildings.values():
		var definition := definition_value as Dictionary
		var definition_id := str(definition.get("id", "?"))
		var kind := str(definition.get("kind", ""))
		if kind not in allowed_kinds:
			errors.append("factory building '%s' has invalid kind '%s'" % [definition_id, kind])
		var footprint: Dictionary = definition.get("footprint", {})
		if int(footprint.get("width", 0)) <= 0 or int(footprint.get("height", 0)) <= 0:
			errors.append("factory building '%s' must define a positive footprint" % definition_id)
		if float(definition.get("construction_work", 0.0)) <= 0.0:
			errors.append("factory building '%s' must define positive construction work" % definition_id)
		_validate_item_entries(definition.get("construction_cost", []), "factory building '%s'" % definition_id)
		for power_field in ["power_generation_kw", "power_demand_kw"]:
			if float(definition.get(power_field, 0.0)) < 0.0:
				errors.append("factory building '%s' has invalid %s" % [definition_id, power_field])
		match kind:
			"EXTRACTOR":
				if definition.get("resource_categories", []).is_empty() or float(definition.get("mining_rate_per_second", 0.0)) <= 0.0 or int(definition.get("output_capacity", 0)) <= 0:
					errors.append("factory extractor '%s' has incomplete extraction rules" % definition_id)
			"MACHINE":
				if definition.get("recipe_ids", []).is_empty() or float(definition.get("speed", 0.0)) <= 0.0 or int(definition.get("input_capacity", 0)) <= 0 or int(definition.get("output_capacity", 0)) <= 0:
					errors.append("factory machine '%s' has incomplete production rules" % definition_id)
				for recipe_id_value in definition.get("recipe_ids", []):
					if not factory_recipes.has(str(recipe_id_value)):
						errors.append("factory machine '%s' references missing recipe '%s'" % [definition_id, recipe_id_value])
			"STORAGE":
				if int(definition.get("inventory_capacity", 0)) <= 0:
					errors.append("factory storage '%s' must define positive capacity" % definition_id)
			"POWER":
				if float(definition.get("power_generation_kw", 0.0)) <= 0.0:
					errors.append("factory power building '%s' must generate power" % definition_id)
			"CONSTRUCTION":
				if float(definition.get("construction_capacity_per_second", 0.0)) <= 0.0:
					errors.append("factory construction building '%s' must provide construction capacity" % definition_id)
	for recipe_value in factory_recipes.values():
		var recipe := recipe_value as Dictionary
		var recipe_id := str(recipe.get("id", "?"))
		if float(recipe.get("duration_seconds", 0.0)) <= 0.0:
			errors.append("factory recipe '%s' must define positive duration" % recipe_id)
		if recipe.get("inputs", []).is_empty() or recipe.get("outputs", []).is_empty():
			errors.append("factory recipe '%s' must define inputs and outputs" % recipe_id)
		_validate_item_entries(recipe.get("inputs", []), "factory recipe '%s' inputs" % recipe_id)
		_validate_item_entries(recipe.get("outputs", []), "factory recipe '%s' outputs" % recipe_id)


func _validate_progression_supply_gates() -> void:
	for project_value in research_projects.values():
		var project := project_value as Dictionary
		var granted_technology := str(project.get("grants_technology", ""))
		if granted_technology.is_empty():
			continue
		for cost_value in project.get("costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			var finite_route_supply := 0
			for route_value in expedition_routes.values():
				for node_value in (route_value as Dictionary).get("nodes", []):
					for reward_value in (node_value as Dictionary).get("rewards", []):
						var reward := reward_value as Dictionary
						if str(reward.get("item", "")) == item_id:
							finite_route_supply += int(reward.get("quantity", 0))
			if finite_route_supply >= int(cost.get("quantity", 0)):
				continue
			var deterministic_producers: Array[Dictionary] = []
			for activity_value in activities.values():
				var activity := activity_value as Dictionary
				if not bool(activity.get("repeat", true)):
					continue
				if activity.get("rewards", []).any(func(entry): return str((entry as Dictionary).get("item", "")) == item_id):
					deterministic_producers.append(activity)
			if deterministic_producers.is_empty():
				continue
			var all_self_gated := true
			for producer in deterministic_producers:
				var self_gated := false
				for requirement_value in producer.get("requirements", []) + producer.get("reveal_requirements", []):
					for leaf in _requirement_leaves(requirement_value as Dictionary):
						if str(leaf.get("type", "")) == "technology" and str(leaf.get("id", "")) == granted_technology:
							self_gated = true
				if not self_gated:
					all_self_gated = false
					break
			if all_self_gated:
				errors.append("Progression deadlock: research project '%s' consumes '%s', but every deterministic producer requires the technology it grants" % [project.get("id", "?"), item_id])


func _validate_first_phase_progression_contract() -> void:
	# The Guide is the executable progression contract for phase one. A main goal
	# without steps can be technically completable while leaving the player with
	# no actionable route to reach it.
	for goal_value in goals.values():
		var goal := goal_value as Dictionary
		var steps: Array = goal.get("steps", [])
		if steps.is_empty():
			errors.append("Phase-one Guide goal '%s' must define at least one actionable step" % goal.get("id", "?"))
			continue
		var step_ids := {}
		for step_value in steps:
			var step := step_value as Dictionary
			var step_id := str(step.get("id", ""))
			if step_id.is_empty() or step_ids.has(step_id):
				errors.append("Phase-one Guide goal '%s' contains a missing or duplicate step id '%s'" % [goal.get("id", "?"), step_id])
			step_ids[step_id] = true

	# Every manufacturing runtime exists from a new game, but only the founding
	# workshop starts active. Every later facility therefore needs an ordinary
	# construction activity that grants ownership; otherwise a valid recipe can
	# still be permanently unreachable.
	var starting_facilities := {"makeshift_workshop":true}
	for facility_id_value in SpaceGameState.MANUFACTURING_FACILITY_IDS:
		var facility_id := str(facility_id_value)
		if starting_facilities.has(facility_id):
			continue
		var unlock_activity_found := false
		for activity_value in activities.values():
			var activity := activity_value as Dictionary
			for effect_value in activity.get("effects", []):
				var effect := effect_value as Dictionary
				if str(effect.get("type", "")) == "unlock_facility" and str(effect.get("facility", "")) == facility_id:
					unlock_activity_found = true
					break
			if unlock_activity_found:
				break
		if not unlock_activity_found:
			errors.append("Phase-one manufacturing facility '%s' has no construction activity that unlocks it" % facility_id)


func _validate_second_phase_capital_contract() -> void:
	var capital_goods: Array = industry_rules.get("capital_goods", [])
	if capital_goods.size() < 8:
		errors.append("Core capital system must define at least eight reusable capital goods")
	for item_id_value in capital_goods:
		var item_id := str(item_id_value)
		if not items.has(item_id) or str(items[item_id].get("category", "")) != "Capital Good":
			errors.append("Phase-two capital good '%s' is missing or has the wrong category" % item_id)
			continue
		var repeatable_producers := 0
		for activity_value in activities.values():
			var activity := activity_value as Dictionary
			if bool(activity.get("repeat", true)) and activity.get("rewards", []).any(func(entry): return str((entry as Dictionary).get("item", "")) == item_id):
				repeatable_producers += 1
		if repeatable_producers <= 0:
			errors.append("Phase-two capital good '%s' has no repeatable producer" % item_id)
		var scenarios := capital_good_usage_scenarios(item_id)
		if scenarios.size() < 2:
			errors.append("Core capital good '%s' must serve at least two ordinary long-term usage scenarios outside the Megastructure" % item_id)
	var basic_machine_tools: Dictionary = activities.get("fabricate_basic_machine_tools", {})
	if basic_machine_tools.is_empty() or str(basic_machine_tools.get("facility", "")) != "makeshift_workshop" or basic_machine_tools.get("requirements", []).any(func(requirement): return str((requirement as Dictionary).get("type", "")) == "facility_level"):
		errors.append("Phase-two must retain a low-technology machine-tool recovery recipe outside facility expansion")
	var steel_machine_tools: Dictionary = activities.get("fabricate_industrial_machine_tools_steel", {})
	if steel_machine_tools.is_empty() or not _entries_contain_item(steel_machine_tools.get("costs", []), "steel_composite") or not _entries_contain_item(steel_machine_tools.get("rewards", []), "industrial_machine_tools"):
		errors.append("Core industry must define a repeatable Steel-to-Industrial-Machine-Tools production method")
	for project_type_value in industry_rules.get("capacity_upgrade_projects", {}).keys():
		var project_type := str(project_type_value)
		var definition: Dictionary = industry_rules["capacity_upgrade_projects"].get(project_type, {})
		if project_type not in ["POWER_UPGRADE", "COOLING_UPGRADE", "STRUCTURE_UPGRADE", "STORAGE_UPGRADE", "BULK_STORAGE_UPGRADE", "COMPONENT_STORAGE_UPGRADE", "FLUID_STORAGE_UPGRADE", "SPECIAL_STORAGE_UPGRADE", "LOGISTICS_HUB_UPGRADE"]:
			errors.append("Unknown phase-two capacity project type '%s'" % project_type)
		if int(definition.get("increment", 0)) <= 0 or float(definition.get("work_required", 0.0)) <= 0.0:
			errors.append("Capacity project '%s' must define positive increment and work" % project_type)
		for cost_value in definition.get("costs", []):
			var cost := cost_value as Dictionary
			if not items.has(str(cost.get("item", ""))) or int(cost.get("quantity", 0)) <= 0:
				errors.append("Capacity project '%s' has an invalid capital cost" % project_type)


func _validate_third_phase_industry_contract() -> void:
	var stage_order: Array = industry_rules.get("scale_stage_order", [])
	if stage_order != ["WORKSHOP", "FACTORY", "INDUSTRIAL_COMPLEX", "AUTOMATED_DISTRICT"]:
		errors.append("Phase-three Industry Scale Stages must define the approved four-stage order")
	var previous_max := 0
	for stage_value in stage_order:
		var stage_id := str(stage_value)
		var stage: Dictionary = industry_rules.get("scale_stages", {}).get(stage_id, {})
		if int(stage.get("min_level", 0)) != previous_max + 1 or int(stage.get("max_level", 0)) < int(stage.get("min_level", 0)) or int(stage.get("max_production_lines", 0)) <= 0:
			errors.append("Industry Scale Stage '%s' has an invalid level boundary or Production Line limit" % stage_id)
		previous_max = int(stage.get("max_level", previous_max))
		if stage_id != "WORKSHOP":
			_validate_item_entries(stage.get("upgrade_costs", []), "Industry Scale Stage '%s'" % stage_id)
	if not industry_rules.get("location_specializations", {}).is_empty():
		errors.append("Core content forbids hard-coded Location specializations; industrial geography must emerge from resources, environment and logistics")
	for group_id in ["steelmaking", "large_structure_fabrication"]:
		var methods: Array = activities.values().filter(func(value): return str((value as Dictionary).get("production_method_group", "")) == group_id)
		if methods.size() < 2:
			errors.append("Phase-three production family '%s' must define at least two methods" % group_id)
			continue
		for method_value in methods:
			var method := method_value as Dictionary
			if str(method.get("product_family_id", "")).is_empty() or str(method.get("minimum_scale_stage", "")) not in stage_order or float(method.get("production_energy_multiplier", 0.0)) <= 0.0 or float(method.get("production_cooling_multiplier", 0.0)) <= 0.0:
				errors.append("Production Method '%s' is missing family, Scale Stage, Power or Cooling constraints" % method.get("id", "?"))


func _apply_freight_profiles() -> void:
	var category_defaults: Dictionary = freight_rules.get("category_defaults", {})
	var item_overrides: Dictionary = freight_rules.get("item_overrides", {})
	for item_id_value in items.keys():
		var item_id := str(item_id_value)
		var item: Dictionary = items[item_id]
		var profile: Dictionary = category_defaults.get(str(item.get("category", "")), {}).duplicate(true)
		profile.merge(item_overrides.get(item_id, {}), true)
		if item.has("freight_class"):
			profile["freight_class"] = item.get("freight_class")
		if item.has("freight_units"):
			profile["freight_units"] = item.get("freight_units")
		if item.has("cargo_mass"):
			profile["cargo_mass"] = item.get("cargo_mass")
		if item.has("cargo_volume"):
			profile["cargo_volume"] = item.get("cargo_volume")
		item["freight_class"] = str(profile.get("freight_class", ""))
		item["freight_units"] = float(profile.get("freight_units", 0.0))
		item["cargo_mass"] = float(profile.get("cargo_mass", 0.0))
		item["cargo_volume"] = float(profile.get("cargo_volume", 0.0))


func item_freight_profile(item_id: String) -> Dictionary:
	var item: Dictionary = items.get(item_id, {})
	return {
		"freight_class":str(item.get("freight_class", "STANDARD")),
		"freight_units":maxf(0.001, float(item.get("freight_units", 1.0))),
		"cargo_mass":maxf(0.001, float(item.get("cargo_mass", item.get("freight_units", 1.0)))),
		"cargo_volume":maxf(0.001, float(item.get("cargo_volume", item.get("freight_units", 1.0))))
	}


func _apply_storage_profiles() -> void:
	var rules: Dictionary = industry_rules.get("storage_classes", {})
	var category_defaults: Dictionary = rules.get("category_defaults", {})
	var item_overrides: Dictionary = rules.get("item_overrides", {})
	for item_id_value in items.keys():
		var item_id := str(item_id_value)
		var item: Dictionary = items[item_id]
		var profile: Dictionary = category_defaults.get(str(item.get("category", "")), {}).duplicate(true)
		profile.merge(item_overrides.get(item_id, {}), true)
		if item.has("storage_class"):
			profile["storage_class"] = item.get("storage_class")
		if item.has("storage_units"):
			profile["storage_units"] = item.get("storage_units")
		item["storage_class"] = str(profile.get("storage_class", "SPECIAL"))
		item["storage_units"] = maxf(0.001, float(profile.get("storage_units", 1.0)))


func item_storage_profile(item_id: String) -> Dictionary:
	var item: Dictionary = items.get(item_id, {})
	return {
		"storage_class":str(item.get("storage_class", "SPECIAL")),
		"storage_units":maxf(0.001, float(item.get("storage_units", 1.0)))
	}


func _validate_seventh_phase_inventory_contract() -> void:
	var storage_rules: Dictionary = industry_rules.get("storage_classes", {})
	var required_classes := ["BULK", "COMPONENT", "FLUID", "SPECIAL"]
	if storage_rules.get("classes", []) != required_classes:
		errors.append("Phase-seven Storage Classes must define BULK, COMPONENT, FLUID and SPECIAL")
	for storage_class in required_classes:
		if int(storage_rules.get("default_capacities", {}).get(storage_class, 0)) <= 0:
			errors.append("Phase-seven Storage Class '%s' must define positive default capacity" % storage_class)
	for item_value in items.values():
		var item := item_value as Dictionary
		if str(item.get("storage_class", "")) not in required_classes or float(item.get("storage_units", 0.0)) <= 0.0:
			errors.append("Item '%s' must resolve to a valid positive Storage profile" % item.get("id", "?"))
	var maintenance: Dictionary = industry_rules.get("operations_maintenance", {})
	if float(maintenance.get("base_preservation_per_level_per_hour", -1.0)) < 0.0 or float(maintenance.get("operating_wear_per_level_per_hour", -1.0)) < 0.0:
		errors.append("Phase-seven O&M rules must define non-negative preservation and wear")
	for profile_value in [maintenance.get("default_items", {})] + maintenance.get("category_profiles", {}).values():
		for item_id_value in (profile_value as Dictionary).keys():
			if not items.has(str(item_id_value)) or float((profile_value as Dictionary).get(item_id_value, 0.0)) < 0.0:
				errors.append("Phase-seven O&M profile references invalid product '%s'" % item_id_value)
	for activity_value in activities.values():
		var activity := activity_value as Dictionary
		if str(activity.get("domain", "")) != "industry" or not bool(activity.get("repeat", true)):
			continue
		var facility: Dictionary = facilities.get(str(activity.get("facility", "")), {})
		for capability_value in activity.get("required_facility_capabilities", []):
			var capability_id := str(capability_value)
			var has_device := float(facility.get("base_capabilities", facility.get("capabilities", {})).get(capability_id, 0.0)) >= 1.0
			for module_value in process_modules.values():
				var process_module := module_value as Dictionary
				if process_module.get("compatible_facilities", []).has(str(activity.get("facility", ""))) and float(process_module.get("grants_capabilities", {}).get(capability_id, 0.0)) >= 1.0:
					has_device = true
			if not has_device:
				errors.append("Production Method '%s' cannot resolve capability '%s' to a real Production Device" % [activity.get("id", "?"), capability_id])


func _validate_eighth_phase_geography_contract() -> void:
	if survey_rules.get("state_order", []) != ["UNKNOWN", "DETECTED", "SURVEYED", "DEEP_SURVEYED"]:
		errors.append("Phase-eight Survey State order is invalid")
	for survey_state in ["DETECTED", "SURVEYED", "DEEP_SURVEYED"]:
		if float(survey_rules.get("mission_work_ms", {}).get(survey_state, 0.0)) <= 0.0 or str(survey_rules.get("required_capabilities", {}).get(survey_state, "")).is_empty():
			errors.append("Survey mission '%s' must define work and a ship capability" % survey_state)
		_validate_item_entries(survey_rules.get("base_costs", {}).get(survey_state, []), "Survey mission '%s'" % survey_state)
	var deployment_package: Dictionary = survey_rules.get("deployment_package", {})
	if str(deployment_package.get("target_state", "")) != "SURVEYED":
		errors.append("Survey deployment package must be committed by the SURVEYED mission")
	_validate_item_entries(deployment_package.get("costs", []), "Survey deployment package")
	var deployment_effects: Dictionary = deployment_package.get("site_effects", {})
	for field in ["structural_capacity", "construction_capacity", "hub_throughput", "local_throughput_capacity"]:
		if float(deployment_effects.get(field, 0.0)) <= 0.0:
			errors.append("Survey deployment package must define positive %s" % field)
	for storage_class in ["BULK", "COMPONENT", "FLUID", "SPECIAL"]:
		if int(deployment_effects.get("storage_capacities", {}).get(storage_class, 0)) <= 0:
			errors.append("Survey deployment package must define positive %s storage" % storage_class)
	_validate_item_entries(survey_rules.get("site_development", {}).get("costs", []), "Site Development")
	if float(survey_rules.get("site_development", {}).get("work_required", 0.0)) <= 0.0:
		errors.append("Site Development must define positive work")
	for region_value in regions.values():
		var region := region_value as Dictionary
		if str(region.get("system_id", SpaceGameState.SYSTEM_ID)) != SpaceGameState.SYSTEM_ID:
			errors.append("Current product scope permits only the single '%s' stellar system" % SpaceGameState.SYSTEM_ID)
		var environment: Dictionary = region.get("environment", {})
		for field in ["gravity", "vacuum", "atmosphere", "solar_flux", "thermal_environment", "radiation", "transport_distance", "construction_difficulty", "maintenance_severity"]:
			if not environment.has(field):
				errors.append("Location '%s' is missing environment field '%s'" % [region.get("id", "?"), field])
		if float(environment.get("gravity", -1.0)) < 0.0 or float(environment.get("solar_flux", -1.0)) < 0.0 or float(environment.get("transport_distance", -1.0)) < 0.0 or float(environment.get("construction_difficulty", 0.0)) <= 0.0:
			errors.append("Location '%s' has invalid environment magnitudes" % region.get("id", "?"))
func _validate_fourth_phase_freight_contract() -> void:
	var required_classes := ["BULK", "STANDARD", "PRECISION", "CRYOGENIC", "HAZARDOUS", "OVERSIZED"]
	if freight_rules.get("classes", []) != required_classes:
		errors.append("Phase-four Freight Classes must define the approved six-class order")
	for item_value in items.values():
		var item := item_value as Dictionary
		if str(item.get("freight_class", "")) not in required_classes or float(item.get("freight_units", 0.0)) <= 0.0 or float(item.get("cargo_mass", 0.0)) <= 0.0 or float(item.get("cargo_volume", 0.0)) <= 0.0:
			errors.append("Item '%s' must resolve to a valid positive Freight, mass and volume profile" % item.get("id", "?"))
	for required_mode_id in ["general_cargo", "bulk_tug", "mass_driver", "cryogenic_carrier", "express_courier"]:
		if not transport_modes.has(required_mode_id):
			errors.append("Phase-four is missing required Transport Mode '%s'" % required_mode_id)
	if transport_modes.size() < 5:
		errors.append("Phase-four second round must define at least five Transport Modes")
	var ship_modes := 0
	var infrastructure_modes := 0
	var available_ship_capabilities := {}
	for ship_value in ships.values():
		for capability_id_value in (ship_value as Dictionary).get("capabilities", {}).keys():
			available_ship_capabilities[str(capability_id_value)] = true
	for module_value in modules.values():
		for capability_id_value in (module_value as Dictionary).get("capabilities", {}).keys():
			available_ship_capabilities[str(capability_id_value)] = true
	for mode_value in transport_modes.values():
		var mode := mode_value as Dictionary
		var supported: Array = mode.get("supported_freight_classes", [])
		if supported.is_empty() or supported.any(func(value): return str(value) not in required_classes):
			errors.append("Transport Mode '%s' has invalid Freight Class compatibility" % mode.get("id", "?"))
		if str(mode.get("directions", "")) not in ["BOTH", "FORWARD", "REVERSE"] or mode.get("route_ids", []).is_empty():
			errors.append("Transport Mode '%s' must define valid routes and directions" % mode.get("id", "?"))
		for route_id_value in mode.get("route_ids", []):
			if str(route_id_value) != "*" and not logistics_routes.has(str(route_id_value)):
				errors.append("Transport Mode '%s' references missing route '%s'" % [mode.get("id", "?"), route_id_value])
		var required_technology := str(mode.get("required_technology", ""))
		var required_facility := str(mode.get("required_facility", ""))
		if not required_technology.is_empty() and not technologies.has(required_technology):
			errors.append("Transport Mode '%s' references missing technology '%s'" % [mode.get("id", "?"), required_technology])
		if not required_facility.is_empty() and not facilities.has(required_facility):
			errors.append("Transport Mode '%s' references missing facility '%s'" % [mode.get("id", "?"), required_facility])
		var minimum_ship_capacity := int(mode.get("minimum_ship_cargo_capacity", 0))
		var maximum_ship_capacity := int(mode.get("maximum_ship_cargo_capacity", 0))
		if minimum_ship_capacity < 0 or maximum_ship_capacity > 0 and maximum_ship_capacity < minimum_ship_capacity:
			errors.append("Transport Mode '%s' has invalid ship cargo-capacity bounds" % mode.get("id", "?"))
		for capability_id_value in mode.get("required_ship_capabilities", []):
			if not available_ship_capabilities.has(str(capability_id_value)):
				errors.append("Transport Mode '%s' requires unavailable ship capability '%s'" % [mode.get("id", "?"), capability_id_value])
		for key in ["capacity_multiplier", "transit_time_multiplier", "handling_time_multiplier", "propellant_multiplier", "energy_per_freight_unit", "maintenance_multiplier"]:
			if float(mode.get(key, -1.0)) < 0.0:
				errors.append("Transport Mode '%s' has invalid %s" % [mode.get("id", "?"), key])
		for condition_value in mode.get("environment_requirements", []):
			var condition := condition_value as Dictionary
			if str(condition.get("field", "")) not in ["gravity", "vacuum", "atmosphere", "solar_flux", "thermal_environment", "radiation", "radiation_level", "transport_distance", "construction_difficulty"] or str(condition.get("operator", "EQ")) not in ["EQ", "LT", "LTE", "GT", "GTE", "IN"]:
				errors.append("Transport Mode '%s' has an invalid environment condition" % mode.get("id", "?"))
		if bool(mode.get("infrastructure_service", false)):
			infrastructure_modes += 1
		else:
			ship_modes += 1
			if str(mode.get("id", "")) != "general_cargo" and bool(mode.get("public_base_capacity", false)):
				errors.append("Specialist Transport Mode '%s' cannot create public or free freight capacity" % mode.get("id", "?"))
			if not bool(mode.get("public_base_capacity", false)) and float(mode.get("ship_capacity_multiplier", 0.0)) <= 0.0:
				errors.append("Physical Transport Mode '%s' must derive positive capacity from assigned ships" % mode.get("id", "?"))
	var general_cargo: Dictionary = transport_modes.get("general_cargo", {})
	if not bool(general_cargo.get("public_base_capacity", false)) or bool(general_cargo.get("infrastructure_service", false)):
		errors.append("General Cargo must retain its limited single-system public corridor bootstrap until enough physical freighters can cover every route")
	if ship_modes < 2 or infrastructure_modes < 1:
		errors.append("Phase-four requires two ship modes and one infrastructure Transport Mode")
	if float(items.get("mixed_raw_ore", {}).get("freight_units", 0.0)) <= float(items.get("iron_ore", {}).get("freight_units", 0.0)) or float(items.get("iron_ore", {}).get("freight_units", 0.0)) <= float(items.get("iron_ingot", {}).get("freight_units", 0.0)):
		errors.append("Phase-four preprocessing must reduce bulk Freight pressure from raw feedstock to ore to alloy")


func _is_construction_definition(activity: Dictionary) -> bool:
	if bool(activity.get("construction_project", false)):
		return true
	if bool(activity.get("repeat", true)):
		return false
	return activity.get("effects", []).any(func(effect): return str((effect as Dictionary).get("type", "")) in ["unlock_facility", "upgrade_facility", "complete_megastructure"])


func capital_good_usage_scenarios(item_id: String) -> Array:
	var scenarios: Array = []
	var megastructure_activity_ids := {}
	for megastructure_value in megastructures.values():
		for phase_value in (megastructure_value as Dictionary).get("phases", []):
			var activity_id := str((phase_value as Dictionary).get("activity_id", ""))
			if not activity_id.is_empty():
				megastructure_activity_ids[activity_id] = true
	for activity_value in activities.values():
		var activity := activity_value as Dictionary
		var activity_id := str(activity.get("id", ""))
		if _is_construction_definition(activity) and not megastructure_activity_ids.has(activity_id) and _entries_contain_item(activity.get("costs", []), item_id):
			scenarios.append({"kind":"CONSTRUCTION", "id":activity_id})
	for stage_id_value in industry_rules.get("scale_stages", {}).keys():
		var stage_id := str(stage_id_value)
		if _entries_contain_item(industry_rules.get("scale_stages", {}).get(stage_id, {}).get("upgrade_costs", []), item_id):
			scenarios.append({"kind":"INDUSTRY_SCALE_UPGRADE", "id":stage_id})
	for project_id_value in industry_rules.get("capacity_upgrade_projects", {}).keys():
		var project_id := str(project_id_value)
		if _entries_contain_item(industry_rules.get("capacity_upgrade_projects", {}).get(project_id, {}).get("costs", []), item_id):
			scenarios.append({"kind":"CAPACITY_UPGRADE", "id":project_id})
	for transformation_id_value in industry_rules.get("industrial_transformations", {}).keys():
		var transformation_id := str(transformation_id_value)
		if _entries_contain_item(industry_rules.get("industrial_transformations", {}).get(transformation_id, {}).get("costs", []), item_id):
			scenarios.append({"kind":"INDUSTRIAL_TRANSFORMATION", "id":transformation_id})
	for plan_value in ship_construction_projects.values():
		var plan := plan_value as Dictionary
		if _entries_contain_item(plan.get("costs", []), item_id) or _entries_contain_item(plan.get("fixed_costs", []), item_id):
			scenarios.append({"kind":"SHIPBUILDING", "id":str(plan.get("id", ""))})
	for project_value in research_projects.values():
		var project := project_value as Dictionary
		if _entries_contain_item(project.get("costs", []), item_id):
			scenarios.append({"kind":"RESEARCH_PROGRAM", "id":str(project.get("id", ""))})
		for stage_value in project.get("stages", []):
			var stage := stage_value as Dictionary
			if _entries_contain_item(stage.get("costs", []), item_id):
				scenarios.append({"kind":"RESEARCH_PHASE", "id":"%s:%s" % [project.get("id", ""), stage.get("id", "")]})
	scenarios.sort_custom(func(a, b): return "%s:%s" % [a.get("kind", ""), a.get("id", "")] < "%s:%s" % [b.get("kind", ""), b.get("id", "")])
	return scenarios


func _entries_contain_item(entries: Array, item_id: String) -> bool:
	return entries.any(func(entry): return str((entry as Dictionary).get("item", "")) == item_id and int((entry as Dictionary).get("quantity", 0)) > 0)


func bootstrap_reachability_snapshot(mode: String = "BOOTSTRAP") -> Dictionary:
	var normalized_mode := mode.to_upper()
	var contract: Dictionary = industry_rules.get("bootstrap_contract", {})
	var reachable_items := {}
	var reachable_facilities := {}
	var facility_capabilities := {}
	var allowed_technologies := {}
	var allowed_regions := {}
	for item_id_value in contract.get("starting_item_ids", []):
		reachable_items[str(item_id_value)] = true
	var extractable_field := "bootstrap_extractable_item_ids" if normalized_mode == "BOOTSTRAP" else "progression_extractable_item_ids"
	for item_id_value in contract.get(extractable_field, []):
		reachable_items[str(item_id_value)] = true
	for facility_id_value in contract.get("starting_facility_ids", []):
		_add_reachable_facility(str(facility_id_value), reachable_facilities, facility_capabilities)
	if normalized_mode == "BOOTSTRAP":
		for technology_id_value in contract.get("bootstrap_technology_ids", []):
			allowed_technologies[str(technology_id_value)] = true
		for region_id_value in contract.get("bootstrap_region_ids", []):
			allowed_regions[str(region_id_value)] = true
	else:
		for technology_id_value in technologies.keys():
			allowed_technologies[str(technology_id_value)] = true
		for region_id_value in regions.keys():
			allowed_regions[str(region_id_value)] = true
	var changed := true
	var passes := 0
	while changed and passes < items.size() + activities.size() + facilities.size() + process_modules.size():
		changed = false
		passes += 1
		for module_value in process_modules.values():
			var module := module_value as Dictionary
			if not _bootstrap_costs_reachable(module.get("costs", []), reachable_items) or not _bootstrap_requirements_reachable(module.get("requirements", []), allowed_technologies, allowed_regions, reachable_facilities):
				continue
			for facility_id_value in module.get("compatible_facilities", []):
				var facility_id := str(facility_id_value)
				if not reachable_facilities.has(facility_id):
					continue
				var capabilities: Dictionary = facility_capabilities.get(facility_id, {})
				for capability_id_value in module.get("grants_capabilities", {}).keys():
					var capability_id := str(capability_id_value)
					if not capabilities.has(capability_id):
						capabilities[capability_id] = true
						changed = true
				facility_capabilities[facility_id] = capabilities
		for activity_value in activities.values():
			var activity := activity_value as Dictionary
			if str(activity.get("domain", "")) != "industry":
				continue
			var facility_id := str(activity.get("facility", ""))
			if not reachable_facilities.has(facility_id) or not _bootstrap_requirements_reachable(activity.get("requirements", []), allowed_technologies, allowed_regions, reachable_facilities) or not _bootstrap_costs_reachable(activity.get("costs", []), reachable_items):
				continue
			var capabilities: Dictionary = facility_capabilities.get(facility_id, {})
			if activity.get("required_facility_capabilities", []).any(func(value): return not capabilities.has(str(value))):
				continue
			if bool(activity.get("repeat", true)):
				for field in ["rewards", "waste"]:
					for entry_value in activity.get(field, []):
						var item_id := str((entry_value as Dictionary).get("item", ""))
						if not item_id.is_empty() and not reachable_items.has(item_id):
							reachable_items[item_id] = true
							changed = true
			else:
				for effect_value in activity.get("effects", []):
					var effect := effect_value as Dictionary
					if str(effect.get("type", "")) == "unlock_facility":
						var unlocked_id := str(effect.get("facility", ""))
						if not reachable_facilities.has(unlocked_id):
							_add_reachable_facility(unlocked_id, reachable_facilities, facility_capabilities)
							changed = true
	var reachable_item_ids: Array = reachable_items.keys()
	var reachable_facility_ids: Array = reachable_facilities.keys()
	reachable_item_ids.sort()
	reachable_facility_ids.sort()
	return {"mode":normalized_mode, "reachable_items":reachable_item_ids, "reachable_facilities":reachable_facility_ids, "passes":passes}


func _add_reachable_facility(facility_id: String, reachable_facilities: Dictionary, facility_capabilities: Dictionary) -> void:
	if not facilities.has(facility_id):
		return
	reachable_facilities[facility_id] = true
	var capabilities := {}
	var facility: Dictionary = facilities[facility_id]
	for capability_id_value in facility.get("base_capabilities", facility.get("capabilities", {})).keys():
		capabilities[str(capability_id_value)] = true
	facility_capabilities[facility_id] = capabilities


func _bootstrap_costs_reachable(costs: Array, reachable_items: Dictionary) -> bool:
	return costs.all(func(entry): return reachable_items.has(str((entry as Dictionary).get("item", ""))))


func _bootstrap_requirements_reachable(requirements: Array, allowed_technologies: Dictionary, allowed_regions: Dictionary, reachable_facilities: Dictionary) -> bool:
	for requirement_value in requirements:
		for leaf_value in _requirement_leaves(requirement_value):
			var leaf := leaf_value as Dictionary
			match str(leaf.get("type", "")):
				"technology":
					if not allowed_technologies.has(str(leaf.get("id", ""))):
						return false
				"region":
					if not allowed_regions.has(str(leaf.get("id", ""))):
						return false
				"own_facility", "facility_level":
					if not reachable_facilities.has(str(leaf.get("id", ""))):
						return false
	return true


func _validate_core_content_contract() -> void:
	if str(pack_metadata.get("version", "")) != "1.32.0":
		errors.append("Core content pack version must be 1.32.0")
	for legacy_activity_id in ["build_automated_metallurgy_network", "upgrade_automated_metallurgy_network", "build_automated_electronics_network", "build_automated_assembly_network"]:
		if activities.has(legacy_activity_id):
			errors.append("Core content still exposes retired background-capacity activity '%s'" % legacy_activity_id)
	for activity_value in activities.values():
		var activity := activity_value as Dictionary
		for effect_value in activity.get("effects", []):
			var effect_type := str((effect_value as Dictionary).get("type", ""))
			if effect_type in ["set_automation_rate", "configure_background_mining", "configure_industry_network", "enable_background_recipe"]:
				errors.append("Core activity '%s' exposes forbidden background production effect '%s'" % [activity.get("id", "?"), effect_type])
	for facility_value in facilities.values():
		var facility := facility_value as Dictionary
		for capability_id_value in facility.get("capabilities", {}).keys():
			if str(capability_id_value).begins_with("background_"):
				errors.append("Core facility '%s' exposes forbidden background production capability" % facility.get("id", "?"))
	var contract: Dictionary = industry_rules.get("bootstrap_contract", {})
	for item_field in ["starting_item_ids", "bootstrap_extractable_item_ids", "progression_extractable_item_ids", "required_bootstrap_items", "required_progression_items"]:
		for item_id_value in contract.get(item_field, []):
			if not items.has(str(item_id_value)):
				errors.append("Bootstrap contract field '%s' references missing item '%s'" % [item_field, item_id_value])
	for facility_id_value in contract.get("starting_facility_ids", []):
		if not facilities.has(str(facility_id_value)):
			errors.append("Bootstrap contract references missing facility '%s'" % facility_id_value)
	for ship_id_value in contract.get("starting_ship_ids", []):
		if not ships.has(str(ship_id_value)) or int(ships.get(str(ship_id_value), {}).get("cargo_capacity", 0)) <= 0:
			errors.append("Bootstrap contract requires a missing or cargo-incapable starting ship '%s'" % ship_id_value)
	var bootstrap_snapshot := bootstrap_reachability_snapshot("BOOTSTRAP")
	var bootstrap_items := {}
	var bootstrap_facilities := {}
	var bootstrap_technologies := {}
	var bootstrap_regions := {}
	for item_id_value in bootstrap_snapshot.get("reachable_items", []):
		bootstrap_items[str(item_id_value)] = true
	for facility_id_value in bootstrap_snapshot.get("reachable_facilities", []):
		bootstrap_facilities[str(facility_id_value)] = true
	for technology_id_value in contract.get("bootstrap_technology_ids", []):
		bootstrap_technologies[str(technology_id_value)] = true
	for region_id_value in contract.get("bootstrap_region_ids", []):
		bootstrap_regions[str(region_id_value)] = true
	for technology_id_value in contract.get("bootstrap_technology_ids", []):
		var technology_id := str(technology_id_value)
		var granting_projects: Array = research_projects.values().filter(func(value): return str((value as Dictionary).get("grants_technology", "")) == technology_id)
		if granting_projects.is_empty():
			errors.append("Bootstrap milestone Technology '%s' has no R&D Program source" % technology_id)
			continue
		var project_reachable := granting_projects.any(func(value):
			var project := value as Dictionary
			return _bootstrap_costs_reachable(project.get("costs", []), bootstrap_items) and _bootstrap_requirements_reachable(project.get("requirements", []), bootstrap_technologies, bootstrap_regions, bootstrap_facilities)
		)
		if not project_reachable:
			errors.append("New-save bootstrap cannot fund or host the R&D Program for Technology '%s'" % technology_id)
	for item_id_value in contract.get("required_bootstrap_items", []):
		if not bootstrap_snapshot.get("reachable_items", []).has(str(item_id_value)):
			errors.append("New-save bootstrap cannot reach required product '%s'" % item_id_value)
	var progression_snapshot := bootstrap_reachability_snapshot("PROGRESSION")
	for item_id_value in contract.get("required_progression_items", []):
		if not progression_snapshot.get("reachable_items", []).has(str(item_id_value)):
			errors.append("Core production graph cannot reach capital good '%s' from new-save sources" % item_id_value)


func _validate_closed_economy() -> void:
	var stable_sources := {}
	var consumers := {}
	for item_id_value in industry_rules.get("bootstrap_contract", {}).get("progression_extractable_item_ids", []):
		stable_sources[str(item_id_value)] = true
	for activity_value in activities.values():
		var activity := activity_value as Dictionary
		if bool(activity.get("repeat", true)):
			for field in ["rewards", "waste"]:
				for entry_value in activity.get(field, []):
					stable_sources[str((entry_value as Dictionary).get("item", ""))] = true
		for cost_value in activity.get("costs", []):
			consumers[str((cost_value as Dictionary).get("item", ""))] = "activity '%s'" % activity.get("id", "?")
	for project_value in research_projects.values():
		var project := project_value as Dictionary
		for cost_value in project.get("costs", []):
			consumers[str((cost_value as Dictionary).get("item", ""))] = "research project '%s'" % project.get("id", "?")
		for stage_value in project.get("stages", []):
			for cost_value in (stage_value as Dictionary).get("costs", []):
				consumers[str((cost_value as Dictionary).get("item", ""))] = "research project '%s' stage '%s'" % [project.get("id", "?"), (stage_value as Dictionary).get("id", "?")]
	for plan_value in ship_construction_projects.values():
		var plan := plan_value as Dictionary
		for field in ["costs", "fixed_costs"]:
			for cost_value in plan.get(field, []):
				consumers[str((cost_value as Dictionary).get("item", ""))] = "ship construction project '%s'" % plan.get("id", "?")
	for cost_value in industry_rules.get("expansion_base_costs", []):
		consumers[str((cost_value as Dictionary).get("item", ""))] = "Industry expansion"
	for transformation_value in industry_rules.get("industrial_transformations", {}).values():
		for cost_value in (transformation_value as Dictionary).get("costs", []):
			consumers[str((cost_value as Dictionary).get("item", ""))] = "Industrial Transformation"
	for bom_value in industry_rules.get("module_bom_defaults", {}).values():
		for cost_value in bom_value as Array:
			consumers[str((cost_value as Dictionary).get("item", ""))] = "ordinary module BOM"
	for module_collection in [process_modules, universal_industry_plugins]:
		for module_value in module_collection.values():
			var module := module_value as Dictionary
			for cost_value in module.get("costs", []):
				consumers[str((cost_value as Dictionary).get("item", ""))] = "manufacturing module '%s'" % module.get("id", "?")
	for facility_value in facilities.values():
		var facility := facility_value as Dictionary
		for module_value in facility.get("upgrade_modules", {}).values():
			var module := module_value as Dictionary
			for cost_value in module.get("costs", []):
				consumers[str((cost_value as Dictionary).get("item", ""))] = "facility module '%s'" % module.get("id", "?")
	for item_id in consumers:
		if item_id.is_empty() or stable_sources.has(item_id):
			continue
		errors.append("Closed economy violation: consumed item '%s' used by %s has no repeatable deterministic source; random loot cannot be its only source" % [item_id, consumers[item_id]])
	for item_value in items.values():
		var item := item_value as Dictionary
		var item_id := str(item.get("id", ""))
		var category := str(item.get("category", ""))
		if not stable_sources.has(item_id) or category in ["Module", "Consumable", "Special Equipment"] or consumers.has(item_id):
			continue
		errors.append("Closed economy violation: produced %s item '%s' has no repeatable use or disposal path" % [category, item_id])


func _validate_planet_visual_profiles() -> void:
	var allowed_statuses := ["EXPERIMENTAL", "PRODUCTION_REFERENCE", "PRODUCTION"]
	for profile in planet_visual_profiles.values():
		var profile_id := str(profile.get("id", "?"))
		var label := "planet visual profile '%s'" % profile_id
		if str(profile.get("status", "")) not in allowed_statuses:
			errors.append("%s has an invalid status" % label)
		for path_key in ["scene_path", "benchmark_scene_path"]:
			var resource_path := str(profile.get(path_key, ""))
			if resource_path.is_empty() or not FileAccess.file_exists(resource_path):
				errors.append("%s references missing %s '%s'" % [label, path_key, resource_path])
		for layer_name in ["surface", "clouds", "atmosphere"]:
			var layer = profile.get(layer_name, {})
			if typeof(layer) != TYPE_DICTIONARY or layer.is_empty():
				errors.append("%s is missing its %s layer" % [label, layer_name])
			continue
			var shader_path := str(layer.get("shader_path", ""))
			if shader_path.is_empty() or not FileAccess.file_exists(shader_path):
				errors.append("%s %s layer references missing shader '%s'" % [label, layer_name, shader_path])
		for texture_path_key in ["albedo_path", "smoothness_path", "mask_path"]:
			var texture_path := str(profile.get("surface", {}).get(texture_path_key, ""))
			if texture_path.is_empty() or not FileAccess.file_exists(texture_path):
				errors.append("%s references missing surface texture '%s'" % [label, texture_path])
		var cloud_texture_path := str(profile.get("clouds", {}).get("texture_path", ""))
		if cloud_texture_path.is_empty() or not FileAccess.file_exists(cloud_texture_path):
			errors.append("%s references missing cloud texture '%s'" % [label, cloud_texture_path])
		if float(profile.get("surface", {}).get("radius", 0.0)) <= 0.0:
			errors.append("%s must define a positive surface radius" % label)
		if int(profile.get("surface", {}).get("radial_segments", 0)) < 64 or int(profile.get("surface", {}).get("rings", 0)) < 32:
			errors.append("%s must retain the reference sphere tessellation floor" % label)
		if float(profile.get("motion", {}).get("sidereal_day_seconds", 0.0)) <= 0.0 or float(profile.get("motion", {}).get("cloud_day_seconds", 0.0)) <= 0.0:
			errors.append("%s must define positive surface and cloud periods" % label)


func get_planet_visual_profile(profile_id: String) -> Dictionary:
	return planet_visual_profiles.get(profile_id, {}).duplicate(true)


func get_domain_activities(domain_id: String) -> Array:
	return activities_by_domain.get(domain_id, [])


func get_item_name(item_id: String) -> String:
	return str(items.get(item_id, {}).get("name", item_id.capitalize()))


func ship_loadout_valid(ship_id: String, module_ids: Array) -> bool:
	return ship_loadout_error(ship_id, module_ids).is_empty()


func ship_loadout_error(ship_id: String, module_ids: Array) -> String:
	var blueprint: Dictionary = ships.get(ship_id, {})
	if blueprint.is_empty():
		return "missing hull definition"
	var slot_usage := {}
	var totals := {"mass":0.0, "power":0.0, "thermal":0.0}
	var allowed_sizes: Array = blueprint.get("allowed_sizes", ["S"])
	for module_value in module_ids:
		var module_id := str(module_value)
		var module: Dictionary = modules.get(module_id, {})
		if module.is_empty():
			return "missing module '%s'" % module_id
		if bool(module.get("retired", false)):
			return "retired module '%s'" % module_id
		var module_size := str(module.get("size", "S"))
		if not allowed_sizes.has(module_size):
			return "module '%s' size %s is not supported" % [module_id, module_size]
		var slot := str(module.get("slot", "utility"))
		slot_usage[slot] = int(slot_usage.get(slot, 0)) + 1
		if int(slot_usage[slot]) > int(blueprint.get("slot_layout", {}).get(slot, 0)):
			return "module '%s' exceeds the %s slot limit" % [module_id, slot]
		totals["mass"] = float(totals["mass"]) + float(module.get("mass", module.get("cpu", 0.0)))
		totals["power"] = float(totals["power"]) + float(module.get("power", module.get("power_grid", 0.0)))
		totals["thermal"] = float(totals["thermal"]) + float(module.get("thermal", module.get("cooling", 0.0)))
	var base_stats: Dictionary = blueprint.get("base_stats", {})
	var capacities := {
		"mass":float(base_stats.get("mass_capacity", base_stats.get("cpu", 0.0))),
		"power":float(base_stats.get("power_capacity", base_stats.get("power_grid", 0.0))),
		"thermal":float(base_stats.get("thermal_capacity", base_stats.get("cooling", 0.0)))
	}
	for module_value in module_ids:
		var bonus: Dictionary = modules.get(str(module_value), {}).get("fitting_capacity_bonus", {})
		capacities["mass"] = float(capacities["mass"]) + float(bonus.get("mass", bonus.get("cpu", 0.0)))
		capacities["power"] = float(capacities["power"]) + float(bonus.get("power", bonus.get("power_grid", 0.0)))
		capacities["thermal"] = float(capacities["thermal"]) + float(bonus.get("thermal", bonus.get("cooling", 0.0)))
	for stat in totals:
		if float(totals[stat]) > float(capacities.get(stat, 0.0)) + 0.001:
			return "%s demand %.1f exceeds capacity %.1f" % [stat, float(totals[stat]), float(capacities.get(stat, 0.0))]
	return ""


func _build_progression_graph() -> void:
	progression_edges.clear()
	for activity in activities.values():
		var activity_node := "activity:%s" % activity.get("id", "")
		if activity.get("domain", "") == "industry":
			progression_edges.append({"from":"facility:%s" % activity.get("facility", ""), "to":activity_node, "type":"REQUIRES_CAPABILITY"})
		for cost in activity.get("costs", []):
			progression_edges.append({"from":"item:%s" % cost.get("item", ""), "to":activity_node, "type":"REQUIRES_CONSUME"})
		for reward in activity.get("rewards", []):
			progression_edges.append({"from":activity_node, "to":"item:%s" % reward.get("item", ""), "type":"PRODUCES"})
		for loot in activity.get("loot", []):
			progression_edges.append({"from":activity_node, "to":"item:%s" % loot.get("item", ""), "type":"DROPS"})
		for requirement in activity.get("requirements", []):
			for leaf in _requirement_leaves(requirement):
				var requirement_type := str(leaf.get("type", "requirement"))
				var source := "%s:%s" % [requirement_type, leaf.get("id", leaf.get("domain", ""))]
				var edge_type := "REQUIRES_CAPABILITY" if requirement_type == "capability" else "REQUIRES_OWN"
				progression_edges.append({"from":source, "to":activity_node, "type":edge_type})
		for requirement in activity.get("reveal_requirements", []):
			for leaf in _requirement_leaves(requirement):
				progression_edges.append({"from":"%s:%s" % [leaf.get("type", "requirement"), leaf.get("id", leaf.get("domain", ""))], "to":activity_node, "type":"REVEALS"})
		for requirement in activity.get("build_requirements", []):
			for leaf in _requirement_leaves(requirement):
				progression_edges.append({"from":"capability:%s" % leaf.get("id", ""), "to":activity_node, "type":"REQUIRES_CAPABILITY"})
		for effect in activity.get("effects", []):
			var effect_type := str(effect.get("type", ""))
			var target_node := "unlock:effect"
			match effect_type:
				"unlock_region": target_node = "region:%s" % effect.get("region", "")
				"unlock_facility", "upgrade_facility": target_node = "facility:%s" % effect.get("facility", "")
				"add_ship": target_node = "ship:%s" % effect.get("ship", "")
				"unlock_ship_plan": target_node = "ship_plan:%s" % effect.get("id", "")
				"complete_megastructure": target_node = "megastructure:%s" % effect.get("id", "")
				"grant_technology": target_node = "technology:%s" % effect.get("id", "")
				"set_resource_maturity": target_node = "maturity:%s" % effect.get("item", "")
				"configure_background_mining": target_node = "background_mining:%s" % effect.get("item", "")
				"configure_industry_network": target_node = "industry_network:%s" % effect.get("family", "")
				"enable_background_recipe": target_node = "background_recipe:%s" % effect.get("activity", "")
				_: target_node = "unlock:%s" % effect.get("id", effect.get("stat", "effect"))
			progression_edges.append({"from":activity_node, "to":target_node, "type":"UPGRADES" if effect_type == "upgrade_facility" else "UNLOCKS"})
	for module in modules.values():
		for capability_id in module.get("capabilities", {}):
			progression_edges.append({"from":"item:%s" % module.get("id", ""), "to":"capability:%s" % capability_id, "type":"PROVIDES_CAPABILITY"})
	for facility in facilities.values():
		for capability_id in facility.get("capabilities", {}):
			progression_edges.append({"from":"facility:%s" % facility.get("id", ""), "to":"capability:%s" % capability_id, "type":"PROVIDES_CAPABILITY"})
		if float(facility.get("baseline_power_generation", facility.get("power_generation", 0.0))) > 0.0 or float(facility.get("advanced_power_generation", 0.0)) > 0.0:
			progression_edges.append({"from":"facility:%s" % facility.get("id", ""), "to":"capacity:civilization_power", "type":"PROVIDES_CAPABILITY"})
	for project in research_projects.values():
		var project_node := "research_project:%s" % project.get("id", "")
		for cost in project.get("costs", []):
			progression_edges.append({"from":"item:%s" % cost.get("item", ""), "to":project_node, "type":"CONSUMES_OVER_TIME"})
		for requirement in project.get("requirements", []):
			for leaf in _requirement_leaves(requirement):
				progression_edges.append({"from":"%s:%s" % [leaf.get("type", "requirement"), leaf.get("id", "")], "to":project_node, "type":"REQUIRES_OWN"})
		if not str(project.get("grants_technology", "")).is_empty():
			progression_edges.append({"from":project_node, "to":"technology:%s" % project.get("grants_technology", ""), "type":"UNLOCKS"})
		if not str(project.get("grants_ship_plan", "")).is_empty():
			progression_edges.append({"from":project_node, "to":"ship_plan:%s" % project.get("grants_ship_plan", ""), "type":"UNLOCKS"})
		for effect in project.get("effects", []):
			var target := "effect:%s" % effect.get("type", "")
			match str(effect.get("type", "")):
				"set_resource_maturity": target = "maturity:%s" % effect.get("item", "")
				"configure_background_mining": target = "background_mining:%s" % effect.get("item", "")
				"configure_industry_network": target = "industry_network:%s" % effect.get("family", "")
				"enable_background_recipe": target = "background_recipe:%s" % effect.get("activity", "")
			progression_edges.append({"from":project_node, "to":target, "type":"UNLOCKS"})
	for plan in ship_construction_projects.values():
		var plan_node := "ship_plan:%s" % plan.get("id", "")
		for cost in plan.get("fixed_costs", []) + plan.get("costs", []):
			progression_edges.append({"from":"item:%s" % cost.get("item", ""), "to":plan_node, "type":"CONSUMES_OVER_TIME"})
		progression_edges.append({"from":plan_node, "to":"ship:%s" % plan.get("ship_id", ""), "type":"GRANTS_UNIQUE_ASSET"})
	for route in expedition_routes.values():
		var route_node := "route:%s" % route.get("id", "")
		for requirement in route.get("requirements", []):
			for leaf in _requirement_leaves(requirement):
				progression_edges.append({"from":"%s:%s" % [leaf.get("type", "requirement"), leaf.get("id", "")], "to":route_node, "type":"REQUIRES_OWN"})
		for effect in route.get("completion_effects", []):
			progression_edges.append({"from":route_node, "to":"unlock:%s" % effect.get("id", effect.get("region", effect.get("megastructure", "effect"))), "type":"UNLOCKS"})


func _index_definitions(source: Array, target: Dictionary, kind: String) -> void:
	for definition in source:
		var id := str(definition.get("id", ""))
		if id.is_empty():
			errors.append("A %s is missing its id" % kind)
		elif target.has(id):
			errors.append("Duplicate %s id: %s" % [kind, id])
		else:
			definition["source_pack"] = str(pack_metadata.get("id", "base"))
			definition["canonical_id"] = "%s:%s.%s" % [pack_metadata.get("namespace", "base"), kind, id]
			target[id] = definition
			definitions_by_canonical_id[definition["canonical_id"]] = definition


func module_bom_activity(module_id: String) -> Dictionary:
	var module: Dictionary = modules.get(module_id, {})
	if module.is_empty() or bool(module.get("special_equipment", false)):
		return {}
	for activity_value in activities.values():
		var activity := activity_value as Dictionary
		if str(activity.get("domain", "")) != "industry":
			continue
		for reward_value in activity.get("rewards", []):
			var reward := reward_value as Dictionary
			if str(reward.get("item", "")) == module_id and int(reward.get("quantity", 0)) > 0:
				return activity
	return {}


func is_module_bom_activity(activity: Dictionary) -> bool:
	return not module_bom_activity_for_definition(activity).is_empty()


func module_bom_activity_for_definition(activity: Dictionary) -> Dictionary:
	if str(activity.get("domain", "")) != "industry":
		return {}
	for reward_value in activity.get("rewards", []):
		var module_id := str((reward_value as Dictionary).get("item", ""))
		if modules.has(module_id) and not bool(modules[module_id].get("special_equipment", false)):
			return activity
	return {}


func module_bom(module_id: String) -> Array:
	var module: Dictionary = modules.get(module_id, {})
	if module.is_empty() or bool(module.get("special_equipment", false)):
		return []
	var recipe := module_bom_activity(module_id)
	if not recipe.is_empty():
		var output_quantity := 1
		for reward_value in recipe.get("rewards", []):
			var reward := reward_value as Dictionary
			if str(reward.get("item", "")) == module_id:
				output_quantity = maxi(1, int(reward.get("quantity", 1)))
				break
		var result: Array = []
		for cost_value in recipe.get("costs", []):
			var cost := cost_value as Dictionary
			result.append({"item":str(cost.get("item", "")), "quantity":maxi(1, int(ceil(float(cost.get("quantity", 0)) / float(output_quantity))))})
		return result
	var multiplier := maxi(1, int(industry_rules.get("module_bom_size_multipliers", {}).get(str(module.get("size", "S")), 1)))
	var defaults: Array = industry_rules.get("module_bom_defaults", {}).get(str(module.get("slot", "")), [])
	var result: Array = []
	for cost_value in defaults:
		var cost := cost_value as Dictionary
		result.append({"item":str(cost.get("item", "")), "quantity":maxi(1, int(cost.get("quantity", 0)) * multiplier)})
	return result


func module_bom_totals(module_ids: Array) -> Dictionary:
	var result := {}
	for module_value in module_ids:
		for cost_value in module_bom(str(module_value)):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			result[item_id] = int(result.get(item_id, 0)) + int(cost.get("quantity", 0))
	return result


func _validate_item_entries(entries: Array, owner: String) -> void:
	for entry in entries:
		if not items.has(str(entry.get("item", ""))):
			errors.append("%s references missing item '%s'" % [owner, entry.get("item", "")])
		if int(entry.get("quantity", 0)) <= 0:
			errors.append("%s has a non-positive item quantity" % owner)


func _validate_effect(effect: Dictionary, owner: String) -> void:
	match str(effect.get("type", "")):
		"grant_spillover":
			if not technologies.has(str(effect.get("id", ""))):
				errors.append("%s grants a missing Spillover Technology" % owner)
		"set_experimental_maturity":
			if not items.has(str(effect.get("item", ""))) or str(effect.get("maturity", "")) not in ["LAB_SAMPLE", "EXPERIMENTAL", "PILOT", "INDUSTRIAL"]:
				errors.append("%s sets an invalid Experimental Technology maturity" % owner)
		"unlock_industrial_transformation":
			if str(effect.get("id", "")).is_empty():
				errors.append("%s unlocks an empty Industrial Transformation" % owner)
		"unlock_ship_plan":
			if not ship_construction_projects.has(str(effect.get("id", ""))):
				errors.append("%s unlocks a missing ship construction plan" % owner)
		"set_resource_maturity":
			if not items.has(str(effect.get("item", ""))):
				errors.append("%s changes maturity for a missing item" % owner)
			if str(effect.get("maturity", "")) not in ["FRONTIER", "MANAGED", "BACKGROUND"]:
				errors.append("%s has an invalid resource maturity" % owner)
		"configure_background_mining":
			if not items.has(str(effect.get("item", ""))):
				errors.append("%s configures background mining for a missing item" % owner)
			if float(effect.get("per_second", 0.0)) <= 0.0:
				errors.append("%s has a non-positive background mining rate" % owner)
			var facility_id := str(effect.get("facility_id", ""))
			if not facility_id.is_empty() and not facilities.has(facility_id):
				errors.append("%s powers background mining with a missing facility" % owner)
		"configure_industry_network":
			if str(effect.get("family", "")).is_empty() or float(effect.get("capacity_per_second", 0.0)) <= 0.0:
				errors.append("%s has an invalid background industry network" % owner)
			var facility_id := str(effect.get("facility_id", ""))
			if not facility_id.is_empty() and not facilities.has(facility_id):
				errors.append("%s powers background industry with a missing facility" % owner)
		"enable_background_recipe":
			var activity_id := str(effect.get("activity", ""))
			var activity: Dictionary = activities.get(activity_id, {})
			if activity.is_empty() or str(activity.get("domain", "")) != "industry" or not bool(activity.get("repeat", true)):
				errors.append("%s enables an invalid background recipe" % owner)
			elif str(activity.get("production_family", "")) != str(effect.get("family", activity.get("production_family", ""))):
				errors.append("%s background recipe family does not match its activity" % owner)
			elif not bool(activity.get("automation_eligible", false)):
				errors.append("%s enables a recipe that has not been conquered for automation" % owner)
		"set_progression_tier":
			if int(effect.get("tier", 0)) <= 0:
				errors.append("%s has an invalid progression tier" % owner)
		"unlock_combat_area":
			if not combat_areas.has(str(effect.get("id", ""))):
				errors.append("%s unlocks a missing combat area" % owner)
		"set_region_state":
			if not regions.has(str(effect.get("region", ""))) or str(effect.get("field", "")) not in ["exploration_state", "strategic_state", "development_state"]:
				errors.append("%s has an invalid regional-state effect" % owner)
		"grant_special_equipment":
			if not modules.has(str(effect.get("id", ""))) or not bool(modules.get(str(effect.get("id", "")), {}).get("special_equipment", false)):
				errors.append("%s grants invalid special equipment" % owner)


func _validate_manufacturing_module(definition: Dictionary, kind: String) -> void:
	var label := "%s '%s'" % [kind, definition.get("id", "?")]
	if int(definition.get("max_instances", 1)) <= 0:
		errors.append("%s must have a positive physical instance limit" % label)
	if float(definition.get("cycle_speed_bonus", 0.0)) <= -0.8:
		errors.append("%s reduces Cycle speed below the supported floor" % label)
	if float(definition.get("productivity_bonus", 0.0)) < 0.0:
		errors.append("%s has invalid Productivity" % label)
	if float(definition.get("baseline_power_demand", 0.0)) < 0.0 or float(definition.get("advanced_power_demand", 0.0)) < 0.0:
		errors.append("%s has invalid power demand" % label)
	_validate_item_entries(definition.get("costs", []), label)
	for requirement in definition.get("requirements", []):
		_validate_requirement(requirement, label)
	for requirement in definition.get("reveal_requirements", []):
		_validate_requirement(requirement, "%s reveal rule" % label)


func _validate_requirement(requirement: Dictionary, owner: String) -> void:
	var operator := str(requirement.get("op", ""))
	if operator in ["AND", "OR"]:
		var children: Array = requirement.get("children", [])
		if children.is_empty():
			errors.append("%s has an empty %s requirement" % [owner, operator])
		for child in children:
			_validate_requirement(child, owner)
		return
	match str(requirement.get("type", "")):
		"item":
			if not items.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing item" % owner)
		"region":
			if not regions.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing region" % owner)
		"domain_level":
			if not domains.has(str(requirement.get("domain", ""))):
				errors.append("%s requires a missing domain" % owner)
		"technology_domain":
			if str(requirement.get("domain", "")) not in SpaceGameState.TECHNOLOGY_DOMAIN_IDS or int(requirement.get("level", 0)) <= 0:
				errors.append("%s has an invalid Technology Domain gate" % owner)
		"research_capacity":
			if float(requirement.get("value", 0.0)) <= 0.0:
				errors.append("%s has an invalid Research Capacity gate" % owner)
		"operating_condition":
			if str(requirement.get("id", "")) not in ["computing_capacity", "power_capacity", "advanced_power_capacity", "cooling_capacity", "logistics_throughput", "precision_manufacturing"] or float(requirement.get("value", 0.0)) <= 0.0:
				errors.append("%s has an invalid Operating Condition gate" % owner)
		"experimental_maturity":
			if not items.has(str(requirement.get("id", ""))) or str(requirement.get("level", "")) not in ["LAB_SAMPLE", "EXPERIMENTAL", "PILOT", "INDUSTRIAL"]:
				errors.append("%s has an invalid Experimental Maturity gate" % owner)
		"spillover":
			if not technologies.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing Spillover Technology" % owner)
		"activity_complete":
			if not activities.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing activity" % owner)
		"route_complete":
			if not expedition_routes.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing Expedition route" % owner)
		"capability":
			if str(requirement.get("id", "")).is_empty():
				errors.append("%s requires an empty capability" % owner)
		"technology":
			if not technologies.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing technology" % owner)
		"project_complete":
			if not research_projects.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing research project" % owner)
		"own_ship":
			if not ships.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing ship" % owner)
		"own_facility", "facility_level":
			if not facilities.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing facility" % owner)
		"manufacturing_module_installed":
			var module_id := str(requirement.get("id", ""))
			if not facilities.has(str(requirement.get("facility", ""))):
				errors.append("%s requires a manufacturing module in a missing facility" % owner)
			if not process_modules.has(module_id) and not universal_industry_plugins.has(module_id):
				errors.append("%s requires a missing manufacturing module" % owner)
		"infrastructure_site", "boss_defeated":
			if str(requirement.get("id", "")).is_empty():
				errors.append("%s has an empty progression requirement" % owner)
		"survey_state":
			if not regions.has(str(requirement.get("id", ""))) or str(requirement.get("state", "")) not in LocationState.SURVEY_STATE_ORDER:
				errors.append("%s has an invalid Survey State requirement" % owner)
		"megastructure":
			if not megastructures.has(str(requirement.get("id", ""))):
				errors.append("%s requires a missing megastructure" % owner)
		"megastructure_phase":
			if not megastructures.has(str(requirement.get("id", ""))) or int(requirement.get("phase", -1)) < 0:
				errors.append("%s requires an invalid megastructure phase" % owner)
		"game_complete":
			pass
		_:
			errors.append("%s has an unknown requirement type" % owner)


func _requirement_leaves(requirement: Dictionary) -> Array:
	if str(requirement.get("op", "")) not in ["AND", "OR"]:
		return [requirement]
	var result: Array = []
	for child in requirement.get("children", []):
		result.append_array(_requirement_leaves(child))
	return result


func dependency_depth(target: String) -> int:
	var reverse := {}
	for edge in progression_edges:
		if str(edge.get("type", "")) in ["PRODUCES", "DROPS"]:
			continue
		var destination := str(edge.get("to", ""))
		if not reverse.has(destination):
			reverse[destination] = []
		reverse[destination].append(str(edge.get("from", "")))
	return _dependency_depth(target, reverse, {}, 0)


func _dependency_depth(node: String, reverse: Dictionary, visiting: Dictionary, depth: int) -> int:
	if depth > 128 or visiting.has(node):
		return depth
	if not reverse.has(node):
		return depth
	var next_visiting := visiting.duplicate()
	next_visiting[node] = true
	var result := depth
	for parent in reverse[node]:
		result = maxi(result, _dependency_depth(str(parent), reverse, next_visiting, depth + 1))
	return result


func _validate_unlock_graph() -> void:
	graph_validation_errors.clear()
	var adjacency := {}
	for edge in progression_edges:
		if str(edge.get("type", "")) in ["PRODUCES", "DROPS", "REQUIRES_CONSUME", "CONSUMES_OVER_TIME", "UPGRADES"]:
			continue
		var source := str(edge.get("from", ""))
		if not adjacency.has(source):
			adjacency[source] = []
		adjacency[source].append(str(edge.get("to", "")))
	var visiting := {}
	var visited := {}
	for node in adjacency:
		_validate_dag_node(str(node), adjacency, visiting, visited)


func _validate_dag_node(node: String, adjacency: Dictionary, visiting: Dictionary, visited: Dictionary) -> void:
	if visited.has(node):
		return
	if visiting.has(node):
		graph_validation_errors.append("Unlock dependency cycle at %s" % node)
		return
	visiting[node] = true
	for target in adjacency.get(node, []):
		_validate_dag_node(str(target), adjacency, visiting, visited)
	visiting.erase(node)
	visited[node] = true
