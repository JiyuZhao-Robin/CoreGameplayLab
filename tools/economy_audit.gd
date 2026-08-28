extends SceneTree

const OUTPUT_PATH := "res://docs/audit/generated-economy-audit.md"
const CRITICAL_CODES := ["NO_PRODUCER", "UNREACHABLE_PRODUCT", "SELF_BOOTSTRAP_DEADLOCK", "TECH_WITHOUT_IMPLEMENTATION", "DEVICE_WITHOUT_METHOD", "METHOD_WITHOUT_DEVICE", "CONSTRUCTION_DEADLOCK"]

var findings: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var database := ContentDatabase.new()
	if not database.load_from_file("res://data/content.json"):
		push_error("Economy audit could not load content: %s" % str(database.errors))
		quit(1)
		return
	var report := build_report(database)
	if not OS.get_cmdline_user_args().has("--no-write"):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/audit"))
		var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
		if file == null:
			push_error("Economy audit could not write %s" % OUTPUT_PATH)
			quit(1)
			return
		file.store_string(render_markdown(report))
	print("ECONOMY_AUDIT products=%d findings=%d critical=%d" % [report.get("products", []).size(), findings.size(), findings.filter(func(row): return str((row as Dictionary).get("code", "")) in CRITICAL_CODES).size()])
	quit(1 if findings.any(func(row): return str((row as Dictionary).get("code", "")) in CRITICAL_CODES and str((row as Dictionary).get("severity", "")) == "P0") else 0)


func build_report(database: ContentDatabase) -> Dictionary:
	findings.clear()
	var simulation := SimulationEngine.new(database)
	var producers := {}
	var consumers := {}
	var required_technologies := {}
	var required_devices := {}
	var required_facilities := {}
	var construction_inputs := {}
	var maintenance_inputs := {}
	var megastructure_inputs := {}
	var methods_by_facility := {}
	var device_capabilities := {}
	for item_id_value in database.items.keys():
		var item_id := str(item_id_value)
		producers[item_id] = []
		consumers[item_id] = []
	for facility_id_value in database.facilities.keys():
		var facility_id := str(facility_id_value)
		var facility: Dictionary = database.facilities[facility_id]
		device_capabilities[facility_id] = facility.get("base_capabilities", facility.get("capabilities", {})).duplicate(true)
		var maintenance_item := str(facility.get("advanced_maintenance_item", ""))
		if not maintenance_item.is_empty():
			_add_reference(maintenance_inputs, maintenance_item, facility_id)
	for module_value in database.process_modules.values():
		var module := module_value as Dictionary
		for facility_id_value in module.get("compatible_facilities", []):
			var facility_id := str(facility_id_value)
			var capabilities: Dictionary = device_capabilities.get(facility_id, {})
			capabilities.merge(module.get("grants_capabilities", {}), true)
			device_capabilities[facility_id] = capabilities
	for activity_value in database.activities.values():
		var activity := activity_value as Dictionary
		var activity_id := str(activity.get("id", ""))
		var facility_id := str(activity.get("facility", ""))
		if not facility_id.is_empty():
			_add_reference(required_facilities, facility_id, activity_id)
			_add_reference(methods_by_facility, facility_id, activity_id)
		for capability_value in activity.get("required_facility_capabilities", []):
			_add_reference(required_devices, str(capability_value), activity_id)
		for reward_value in activity.get("rewards", []):
			_add_reference(producers, str((reward_value as Dictionary).get("item", "")), activity_id)
		for waste_value in activity.get("waste", []):
			_add_reference(producers, str((waste_value as Dictionary).get("item", "")), "%s:waste" % activity_id)
		for cost_value in activity.get("costs", []):
			var item_id := str((cost_value as Dictionary).get("item", ""))
			_add_reference(consumers, item_id, activity_id)
			if simulation.is_construction_activity(activity):
				_add_reference(construction_inputs, item_id, activity_id)
				if not simulation.megastructure_for_activity(activity).is_empty():
					_add_reference(megastructure_inputs, item_id, activity_id)
		_collect_technology_requirements(activity.get("requirements", []), activity_id, required_technologies)
		_collect_technology_requirements(activity.get("reveal_requirements", []), activity_id, required_technologies)
	for project_value in database.research_projects.values():
		var project := project_value as Dictionary
		var project_id := str(project.get("id", ""))
		_collect_technology_requirements(project.get("requirements", []), project_id, required_technologies)
		for stage_value in project.get("stages", []):
			var stage := stage_value as Dictionary
			for cost_value in stage.get("costs", []):
				_add_reference(consumers, str((cost_value as Dictionary).get("item", "")), "%s/%s" % [project_id, stage.get("id", "")])
			_collect_technology_requirements(stage.get("requirements", []), "%s/%s" % [project_id, stage.get("id", "")], required_technologies)
	for plan_value in database.ship_construction_projects.values():
		var plan := plan_value as Dictionary
		for field in ["costs", "fixed_costs"]:
			for cost_value in plan.get(field, []):
				_add_reference(consumers, str((cost_value as Dictionary).get("item", "")), str(plan.get("id", "")))
	for module_id_value in database.modules.keys():
		var module_id := str(module_id_value)
		_add_reference(consumers, module_id, "LOADOUT_INSTALLATION")
	for route_value in database.expedition_routes.values():
		var route := route_value as Dictionary
		var route_id := str(route.get("id", ""))
		if int(route.get("fuel_cost", 0)) > 0:
			_add_reference(consumers, str(database.fleet_rules.get("fuel_item", "chemical_propellant")), route_id)
		for node_value in route.get("nodes", []):
			var node := node_value as Dictionary
			for reward_value in node.get("rewards", []):
				_add_reference(producers, str((reward_value as Dictionary).get("item", "")), "%s/%s" % [route_id, node.get("id", "")])
			for effect_value in node.get("effects", []):
				var effect := effect_value as Dictionary
				if str(effect.get("type", "")) == "grant_special_equipment":
					_add_reference(producers, str(effect.get("id", "")), "%s/%s" % [route_id, node.get("id", "")])
	for custom_sink in ["chemical_propellant", "repair_supplies", "repair_material", "kinetic_munitions"]:
		_add_reference(consumers, custom_sink, "FLEET_OPERATION")
	var starting_items := SpaceGameState.create_new(database.domains.keys(), database.regions).aggregate_inventory().keys()
	var progression: Dictionary = database.bootstrap_reachability_snapshot("PROGRESSION")
	for item_id_value in database.items.keys():
		var item_id := str(item_id_value)
		if producers.get(item_id, []).is_empty() and not starting_items.has(item_id):
			_add_finding("NO_PRODUCER", "P1", item_id, "No repeatable or mission producer is registered.")
		if consumers.get(item_id, []).is_empty():
			_add_finding("NO_CONSUMER", "P2", item_id, "No gameplay sink is registered.")
		var produced_by_progression_event: bool = (producers.get(item_id, []) as Array).any(func(owner): return str(owner).contains("_route/") or str(owner).contains("_assault/"))
		if not progression.get("reachable_items", []).has(item_id) and not producers.get(item_id, []).is_empty() and not produced_by_progression_event:
			_add_finding("UNREACHABLE_PRODUCT", "P1", item_id, "The declared progression reachability graph cannot reach this produced item.")
	for facility_id_value in database.facilities.keys():
		var facility_id := str(facility_id_value)
		if int((database.facilities[facility_id] as Dictionary).get("manufacturing_generation", 0)) > 0 and methods_by_facility.get(facility_id, []).is_empty():
			_add_finding("DEVICE_WITHOUT_METHOD", "P1", facility_id, "Manufacturing facility has no executable Production Method.")
	for activity_value in database.activities.values():
		var activity := activity_value as Dictionary
		if str(activity.get("domain", "")) != "industry" or simulation.is_construction_activity(activity):
			continue
		var facility_id := str(activity.get("facility", ""))
		for capability_value in activity.get("required_facility_capabilities", []):
			if float(device_capabilities.get(facility_id, {}).get(str(capability_value), 0.0)) < 1.0:
				_add_finding("METHOD_WITHOUT_DEVICE", "P0", str(activity.get("id", "")), "Required capability %s has no compatible device." % capability_value)
	var granted_technologies := {}
	for project_value in database.research_projects.values():
		var project := project_value as Dictionary
		var granted := str(project.get("grants_technology", ""))
		if not granted.is_empty():
			granted_technologies[granted] = str(project.get("id", ""))
	for technology_id_value in granted_technologies.keys():
		var technology_id := str(technology_id_value)
		var technology_definition: Dictionary = database.technologies.get(technology_id, {})
		var has_runtime_contract := technology_definition.has("logistics_tier") or technology_definition.has("megastructure_power_requirement_multiplier") or technology_definition.has("megastructure_cooling_requirement_multiplier")
		if required_technologies.get(technology_id, []).is_empty() and not has_runtime_contract:
			_add_finding("TECH_WITHOUT_IMPLEMENTATION", "P1", technology_id, "Technology is granted but no content requirement consumes it.")
	var chinese := _load_catalog("res://data/localization_zh_CN.json")
	for item_id_value in database.items.keys():
		var item_id := str(item_id_value)
		if not chinese.get("content", {}).has(item_id) and not chinese.get("content_overrides", {}).has(item_id):
			_add_finding("MISSING_LOCALIZATION", "P1", item_id, "zh-CN content entry is missing.")
	return {
		"products":database.items.keys(), "producers":producers, "consumers":consumers,
		"required_technologies":required_technologies, "required_devices":required_devices,
		"required_facilities":required_facilities, "construction_inputs":construction_inputs,
		"maintenance_inputs":maintenance_inputs, "megastructure_inputs":megastructure_inputs,
		"findings":findings.duplicate(true)
	}


func render_markdown(report: Dictionary) -> String:
	var lines: Array[String] = ["# Generated Economy Audit", "", "Generated from `data/content.json`; do not hand-edit findings.", ""]
	for section in [
		["All Products", "products"], ["All Producers", "producers"], ["All Consumers", "consumers"],
		["All Required Technologies", "required_technologies"], ["All Required Devices", "required_devices"],
		["All Required Facilities", "required_facilities"], ["All Construction Inputs", "construction_inputs"],
		["All Maintenance Inputs", "maintenance_inputs"], ["All Megastructure Inputs", "megastructure_inputs"]
	]:
		lines.append("## %s" % section[0])
		lines.append("")
		var value: Variant = report.get(str(section[1]), {})
		if value is Array:
			var values: Array = value.duplicate()
			values.sort()
			for entry in values:
				lines.append("- `%s`" % entry)
		else:
			var keys: Array = (value as Dictionary).keys()
			keys.sort()
			for key_value in keys:
				lines.append("- `%s` → %s" % [key_value, ", ".join((value as Dictionary).get(key_value, []))])
		lines.append("")
	lines.append("## Findings")
	lines.append("")
	if findings.is_empty():
		lines.append("No findings.")
	for finding in findings:
		lines.append("- **%s %s** `%s`: %s" % [finding.get("severity", ""), finding.get("code", ""), finding.get("entity", ""), finding.get("message", "")])
	lines.append("")
	return "\n".join(lines)


func _collect_technology_requirements(entries: Array, owner_id: String, target: Dictionary) -> void:
	for requirement_value in entries:
		var requirement := requirement_value as Dictionary
		if str(requirement.get("type", "")) == "technology":
			_add_reference(target, str(requirement.get("id", "")), owner_id)


func _add_reference(target: Dictionary, key: String, owner: String) -> void:
	if key.is_empty() or owner.is_empty():
		return
	if not target.has(key):
		target[key] = []
	if not target[key].has(owner):
		target[key].append(owner)


func _add_finding(code: String, severity: String, entity: String, message: String) -> void:
	findings.append({"code":code, "severity":severity, "entity":entity, "message":message})


func _load_catalog(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if parsed is Dictionary else {}
