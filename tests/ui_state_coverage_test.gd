extends Node

const MainScene := preload("res://src/ui/main.tscn")
const GameplayScenarioBuilderScript := preload("res://tests/gameplay_scenario_builder.gd")
const REGISTRY_PATH := "res://data/ui_state_registry.json"
const RESULT_PATH := "res://artifacts/test-results/ui-state-coverage.json"
const MAIN_LOCATION := SpaceGameState.MAIN_BASE_LOCATION_ID

var failures: Array[String] = []
var coverage_by_id := {}
var definitions: Array = []
var main: Control


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Engine.time_scale = 0.0
	I18n.set_locale("en")
	_check(_load_registry(), "UI state registry loads")
	if definitions.is_empty():
		_finish()
		return

	await _cover_production_states()
	await _cover_remote_production_constraints()
	await _cover_production_building_and_disabled()
	await _cover_construction_states()
	await _cover_construction_waiting_capacity()
	await _cover_research_states()
	await _cover_research_locked_and_paused()
	await _cover_golden_research_waiting_states()
	await _cover_survey_states()
	await _cover_megastructure_locked()
	await _cover_megastructure_preparation_states()
	await _cover_golden_scenario_survey_states()
	await _cover_golden_scenario_logistics_states()
	await _verify_diagnostics_upstream_logistics_navigation()
	await _cover_logistics_paused()
	await _cover_logistics_no_transport()
	await _cover_golden_scenario_megastructure_states()
	await _verify_alert_count_single_source()
	_set_explicit_unverified_reasons()
	_write_result()

	var verified := _verified_count()
	var verified_systems := _verified_systems()
	_check(verified == definitions.size(), "every registered core Gameplay State has real-domain UI evidence (%d/%d)" % [verified, definitions.size()])
	_check(["production", "construction", "research", "survey", "megastructure"].all(func(system_id: String) -> bool: return verified_systems.has(system_id)), "runtime evidence spans production, construction, research, survey and megastructure")
	_finish()


func _load_registry() -> bool:
	if not FileAccess.file_exists(REGISTRY_PATH):
		return false
	var file := FileAccess.open(REGISTRY_PATH, FileAccess.READ)
	if file == null:
		return false
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary or (parsed as Dictionary).get("definitions", null) is not Array:
		return false
	definitions = (parsed as Dictionary).get("definitions", [])
	for definition_value in definitions:
		var definition := definition_value as Dictionary
		var state_id := String(definition.get("stateId", ""))
		coverage_by_id[state_id] = {
			"stateId":state_id,
			"systemId":String(definition.get("systemId", "")),
			"status":"UNVERIFIED",
			"domainStateFormed":false,
			"uiStateVisible":false,
			"explanationVisible":false,
			"navigationControlVisible":false,
			"formationTrace":[],
			"uiEvidence":{},
			"reason":"Not exercised by this bounded runtime suite."
		}
	return not definitions.is_empty()


func _cover_production_states() -> void:
	# RUNNING: a funded recipe is started through the application command and the
	# simulation is advanced before any UI is opened.
	Game.reset_game()
	Game.state.add_item("mixed_raw_ore", 20, MAIN_LOCATION)
	var started := Game.start_industry_operation(0, "separate_iron_ore")
	Game.advance_game_time(1.0)
	await _observe_production("PRODUCTION.RUNNING", "RUNNING", started, "separate_iron_ore", "", ["disable", "off", "关闭"], [
		"Game.reset_game()", "SpaceGameState.add_item(mixed_raw_ore, 20)",
		"Game.start_industry_operation(0, separate_iron_ore)", "Game.advance_game_time(1)"
	])

	# BLOCKED_INPUT: the input is first present so the command is legal, then it is
	# consumed through the public inventory API before the next simulation step.
	Game.reset_game()
	Game.state.add_item("mixed_raw_ore", 2, MAIN_LOCATION)
	started = Game.start_industry_operation(0, "separate_iron_ore")
	_drain_item("mixed_raw_ore")
	Game.advance_game_time(10.0)
	await _observe_production("PRODUCTION.BLOCKED_INPUT", "BLOCKED_INPUT", started, "separate_iron_ore", "INPUT_SHORTAGE", ["why?", "原因"], [
		"Game.reset_game()", "SpaceGameState.add_item(mixed_raw_ore, 2)",
		"Game.start_industry_operation(0, separate_iron_ore)",
		"SpaceGameState.remove_item(mixed_raw_ore, current_quantity)", "Game.advance_game_time(10)"
	], true)

	# BLOCKED_OUTPUT: start an output-positive FLUID recipe, then fill the FLUID
	# class using add_item. Storage rejection is produced by the simulation.
	Game.reset_game()
	Game.state.add_item("iron_ingot", 1, MAIN_LOCATION)
	started = Game.start_industry_operation(0, "manufacture_kinetic_munitions")
	var fluid_fill := Game.simulation.location_storage_free_quantity_for_item(Game.state, MAIN_LOCATION, "chemical_propellant")
	Game.state.add_item("chemical_propellant", fluid_fill, MAIN_LOCATION)
	Game.advance_game_time(10.0)
	await _observe_production("PRODUCTION.BLOCKED_OUTPUT", "BLOCKED_OUTPUT", started, "manufacture_kinetic_munitions", "STORAGE_FULL", ["why?", "原因"], [
		"Game.reset_game()", "SpaceGameState.add_item(iron_ingot, 1)",
		"Game.start_industry_operation(0, manufacture_kinetic_munitions)",
		"SimulationEngine.location_storage_free_quantity_for_item(...)",
		"SpaceGameState.add_item(chemical_propellant, free_quantity)", "Game.advance_game_time(10)"
	], true)

	# PAUSED is formed by the normal stop command, not by editing the runtime.
	Game.reset_game()
	Game.state.add_item("mixed_raw_ore", 20, MAIN_LOCATION)
	started = Game.start_industry_operation(0, "separate_iron_ore")
	Game.advance_game_time(1.0)
	var paused := Game.stop_industry_operation(0)
	Game.advance_game_time(1.0)
	await _observe_production("PRODUCTION.PAUSED", "PAUSED", started and paused, "separate_iron_ore", "MANUALLY_PAUSED", ["pinned", "resume", "固定工艺运行"], [
		"Game.reset_game()", "SpaceGameState.add_item(mixed_raw_ore, 20)",
		"Game.start_industry_operation(0, separate_iron_ore)", "Game.advance_game_time(1)",
		"Game.stop_industry_operation(0)", "Game.advance_game_time(1)"
	])


func _observe_production(state_id: String, expected_state: String, command_ok: bool, activity_id: String, blocker_reason: String, action_needles: Array[String], trace: Array[String], use_diagnostics: bool = false) -> void:
	var runtime := Game.state.industrial_operations[0] as Dictionary
	var formed := command_ok and String(runtime.get("operating_state", "")) == expected_state
	await _spawn_main()
	await _press_named("Navigation_location")
	await _press_named("LocationTab_industry")
	var location_text := _visible_text(main)
	var state_visible := _contains_any(location_text, [_status_text(expected_state), expected_state.replace("_", " ")])
	var explanation_visible := location_text.contains(I18n.content(Game.content.activities.get(activity_id, {"id":activity_id, "name":activity_id})))
	var navigation := _find_enabled_button_by_text(action_needles)
	var evidence := {"screen":"location.industry", "statusText":_status_text(expected_state), "activityId":activity_id}
	if not blocker_reason.is_empty():
		var blocker := runtime.get("blocker", {}) as Dictionary
		explanation_visible = explanation_visible and String(blocker.get("primary_reason", "")) == blocker_reason and _visible_text(main).contains(_blocker_text(blocker))
		evidence["blockerReason"] = String(blocker.get("primary_reason", ""))
	if use_diagnostics:
		await _press_named("Navigation_diagnostics")
		navigation = main.find_child("BlockerWhy_%s" % blocker_reason, true, false) as Button
		navigation = navigation if _button_usable(navigation) else null
		evidence["navigationScreen"] = "diagnostics"
	_record_observation(state_id, formed, state_visible, explanation_visible, navigation != null, trace, evidence, "Production state or its UI evidence was not observed from the legal scenario.")
	await _free_main()


func _cover_remote_production_constraints() -> void:
	var location_id := "asteroid_belt"
	var facility_id := "makeshift_workshop"
	var activity_id := "separate_iron_ore"
	var activated := _activate_golden_scenario("prepare_stellar_energy")
	var expanded := activated and _raise_remote_industry_to_automated(location_id, facility_id)
	var runtime := Game.state.industrial_operation_for(location_id, facility_id) if expanded else {}
	var slot := int(runtime.get("slot", -1))
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	if slot >= 0:
		_clear_location_inventory_for_probe(location_id)
		_fund_entries_at(activity.get("costs", []), location_id, 20)
	var started := slot >= 0 and Game.start_industry_operation(slot, activity_id)
	Game.advance_game_time(10.0)
	await _observe_remote_production_constraint("PRODUCTION.POWER_LIMITED", "POWER_LIMITED", started, slot, location_id, activity_id, "POWER_SHORTAGE", [
		"activate prepare_stellar_energy Golden checkpoint", "queue and complete each legal Facility Expansion and Scale Stage project at asteroid_belt",
		"fund normal recipe inputs at the owned remote inventory", "Game.start_industry_operation(remote workshop slot, separate_iron_ore)",
		"Game.advance_game_time lets location_industry_constraint_profile compare real Level-20 demand with the 15-unit site power grid"
	])

	if slot >= 0 and String((Game.state.industrial_operations[slot] as Dictionary).get("status", "")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(slot)
	var power_upgraded := expanded and _complete_location_capacity_upgrade(location_id, "POWER_UPGRADE", 100)
	if slot >= 0:
		_clear_location_inventory_for_probe(location_id)
		_fund_entries_at(activity.get("costs", []), location_id, 20)
	started = power_upgraded and slot >= 0 and Game.set_production_line_control(slot, "PINNED")
	Game.advance_game_time(10.0)
	await _observe_remote_production_constraint("PRODUCTION.COOLING_LIMITED", "COOLING_LIMITED", started, slot, location_id, activity_id, "COOLING_SHORTAGE", [
		"continue from the legally expanded asteroid workshop", "queue and complete a material-backed POWER_UPGRADE to 100 without changing cooling",
		"resume the same production line through Game.set_production_line_control(PINNED)", "Game.advance_game_time exposes demand above the unchanged 7.5-unit cooling grid"
	])

	if slot >= 0 and String((Game.state.industrial_operations[slot] as Dictionary).get("status", "")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(slot)
	var cooling_upgraded := power_upgraded and _complete_location_capacity_upgrade(location_id, "COOLING_UPGRADE", 100)
	if slot >= 0:
		_clear_location_inventory_for_probe(location_id)
		_fund_entries_at(activity.get("costs", []), location_id, 20)
	started = cooling_upgraded and slot >= 0 and Game.set_production_line_control(slot, "PINNED")
	Game.advance_game_time(10.0)
	await _observe_remote_production_constraint("PRODUCTION.LOGISTICS_LIMITED", "LOGISTICS_LIMITED", started, slot, location_id, activity_id, "HANDLING_CONGESTED", [
		"continue from the legally power-constrained and cooling-constrained topology", "queue and complete a material-backed COOLING_UPGRADE to 100",
		"resume the Level-20 line through Game.set_production_line_control(PINNED)",
		"Game.advance_game_time compares real recipe input/output movement with the unchanged 20-unit local handling capacity"
	])


func _raise_remote_industry_to_automated(location_id: String, facility_id: String) -> bool:
	for target_level in [4, 5, 9, 10, 19, 20]:
		var current := int(Game.state.location_industry(location_id, facility_id).get("level", 0))
		if current >= target_level:
			continue
		var queued := Game.queue_scale_stage_upgrade(location_id, facility_id, 90) if target_level in [5, 10, 20] else Game.queue_facility_expansion(location_id, facility_id, target_level, 90)
		if not queued:
			print("REMOTE_CONSTRAINT_SETUP: queue failed target=%d notice=%s" % [target_level, Game.last_notice])
			return false
		if not _fund_and_complete_latest_construction(location_id):
			print("REMOTE_CONSTRAINT_SETUP: completion failed target=%d" % target_level)
			return false
	return int(Game.state.location_industry(location_id, facility_id).get("level", 0)) == 20


func _complete_location_capacity_upgrade(location_id: String, project_type: String, target_value: int) -> bool:
	if not Game.queue_location_capacity_upgrade(location_id, project_type, target_value, 95):
		return false
	return _fund_and_complete_latest_construction(location_id)


func _fund_and_complete_latest_construction(location_id: String) -> bool:
	var runtime: Dictionary = {}
	for index in range(Game.state.construction_operations.size() - 1, -1, -1):
		var candidate := Game.state.construction_operations[index] as Dictionary
		if String(candidate.get("location_id", "")) == location_id and String(candidate.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			runtime = candidate
			break
	if runtime.is_empty():
		return false
	var project_id := String(runtime.get("project_id", ""))
	for item_id_value in (runtime.get("material_plan", {}) as Dictionary).keys():
		var item_id := String(item_id_value)
		var required := int((runtime.get("material_plan", {}) as Dictionary).get(item_id, 0))
		var available := Game.state.item_quantity(item_id, location_id)
		if available < required:
			Game.state.add_item(item_id, required - available, location_id)
	Game.advance_game_time(maxf(500000.0, float(runtime.get("total_work", 1.0)) * 2000.0))
	var completed := Game.state.construction_history.any(func(row_value) -> bool:
		var row := row_value as Dictionary
		return String(row.get("project_id", "")) == project_id and String(row.get("status", "")) == "COMPLETE"
	)
	if not completed:
		print("REMOTE_CONSTRAINT_SETUP: project=%s status=%s blocker=%s plan=%s delivered=%s" % [runtime.get("project_id", ""), runtime.get("status", ""), runtime.get("blocker", {}), runtime.get("material_plan", {}), runtime.get("delivered_materials", {})])
	return completed


func _fund_entries_at(entries: Array, location_id: String, multiplier: int = 1) -> void:
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := String(entry.get("item", ""))
		if not item_id.is_empty():
			Game.state.add_item(item_id, int(entry.get("quantity", 0)) * maxi(1, multiplier), location_id)


func _clear_location_inventory_for_probe(location_id: String) -> void:
	for item_id_value in Game.state.location_inventory(location_id).keys():
		var item_id := String(item_id_value)
		var quantity := Game.state.item_quantity(item_id, location_id)
		if quantity > 0:
			Game.state.remove_item(item_id, quantity, location_id)


func _observe_remote_production_constraint(state_id: String, expected_state: String, command_ok: bool, slot: int, location_id: String, activity_id: String, blocker_reason: String, trace: Array[String]) -> void:
	var runtime: Dictionary = Game.state.industrial_operations[slot] if slot >= 0 and slot < Game.state.industrial_operations.size() else {}
	var blocker: Dictionary = Game.simulation.blocker_diagnostic(Game.state, "industry", runtime) if not runtime.is_empty() else {}
	var formed := command_ok and String(runtime.get("operating_state", "")) == expected_state and String(blocker.get("primary_reason", "")) == blocker_reason
	await _open_location_section(location_id, "industry")
	var corpus := _visible_text(main)
	var state_visible := _contains_any(corpus, [_status_text(expected_state), expected_state])
	var explanation_visible := corpus.contains(I18n.content(Game.content.activities.get(activity_id, {}))) and corpus.contains(_blocker_text(blocker))
	await _press_named("Navigation_diagnostics")
	var why := main.find_child("BlockerWhy_%s" % blocker_reason, true, false) as Button
	_record_observation(state_id, formed, state_visible, explanation_visible, _button_usable(why), trace, {
		"screens":["location.industry", "diagnostics"], "locationId":location_id, "slot":slot,
		"activityId":activity_id, "operatingState":String(runtime.get("operating_state", "")),
		"blockerReason":String(blocker.get("primary_reason", "")), "constraintProfile":Game.simulation.location_industry_constraint_profile(Game.state, location_id),
		"navigationControl":String(why.name) if why != null else ""
	}, "The material-backed remote Factory topology did not form or visibly explain the expected production constraint with root-cause navigation.")
	await _free_main()


func _cover_production_building_and_disabled() -> void:
	var building_location := "asteroid_belt"
	var building_scenario := _activate_golden_scenario("prepare_stellar_energy")
	var queued := building_scenario and Game.queue_facility_expansion(building_location, "makeshift_workshop", 2, 80)
	if not queued:
		print("PRODUCTION_BUILDING_SETUP: scenario=%s notice=%s queue=%d/%d current=%s" % [building_scenario, Game.last_notice, Game.simulation.construction_queue_size(Game.state), Game.simulation.construction_queue_capacity(Game.state), Game.state.location_industry(building_location, "makeshift_workshop")])
	var project: Dictionary = {}
	for runtime_value in Game.state.construction_operations:
		var candidate := runtime_value as Dictionary
		if String(candidate.get("project_type", "")) == "FACILITY_EXPANSION" and String(candidate.get("target_id", "")) == "makeshift_workshop":
			project = candidate
			break
	if queued and project.is_empty():
		print("PRODUCTION_BUILDING_SETUP: active=%s" % Game.state.construction_operations)
	var project_id := String(project.get("project_id", ""))
	var building_formed := queued and not project_id.is_empty() and String(project.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"] and String(project.get("target_id", "")) == "makeshift_workshop"
	await _open_location_section(building_location, "industry")
	var corpus := _visible_text(main)
	var open_project := main.find_child("OpenProductionConstruction_%s" % project_id, true, false) as Button
	_record_observation("PRODUCTION.BUILDING", building_formed, _contains_any(corpus, [_status_text("BUILDING"), "BUILDING"]), corpus.contains(project_id) and corpus.contains(I18n.content(Game.content.facilities.get("makeshift_workshop", {}))) and _contains_any(corpus, ["Material", "材料"]), _button_usable(open_project), [
		"activate prepare_stellar_energy Golden checkpoint", "Game.queue_facility_expansion(asteroid_belt, makeshift_workshop, 2)",
		"retain the authoritative active commitment at its initial material stage", "open live Location Industry"
	], {"screen":"location.industry", "projectId":project_id, "projectType":String(project.get("project_type", "")), "targetId":String(project.get("target_id", "")), "runtimeStatus":String(project.get("status", "")), "navigationControl":String(open_project.name) if open_project != null else ""}, "A real Factory expansion commitment did not appear as BUILDING with progress, material context and Construction navigation.")
	await _free_main()

	var activated := _activate_golden_scenario("prototype_complete")
	var line: Dictionary = Game.state.industrial_operation_for(MAIN_LOCATION, "orbital_foundry") if activated else {}
	var slot := int(line.get("slot", -1))
	var removed := activated and Game.uninstall_manufacturing_module("orbital_foundry", "advanced_alloy_cell", "process", MAIN_LOCATION)
	var gameplay_state := Game.simulation.production_gameplay_state(Game.state, line) if removed else ""
	var blocker: Dictionary = Game.simulation.blocker_diagnostic(Game.state, "industry", line) if removed else {}
	var disabled_formed := removed and gameplay_state == "DISABLED" and String(blocker.get("primary_reason", "")) == "PRODUCTION_DEVICE_UNAVAILABLE"
	await _open_location_section(MAIN_LOCATION, "industry")
	corpus = _visible_text(main)
	var open_capability := main.find_child("OpenProductionCapability_%d" % slot, true, false) as Button
	var run_button := main.find_child("RunProductionLine_%d" % slot, true, false) as Button
	_record_observation("PRODUCTION.DISABLED", disabled_formed, _contains_any(corpus, [_status_text("DISABLED"), "DISABLED"]), corpus.contains(I18n.content(Game.content.activities.get(String(line.get("activity_id", "")), {}))) and corpus.contains(_blocker_text(blocker)) and run_button != null and run_button.disabled and not run_button.tooltip_text.is_empty(), _button_usable(open_capability), _scenario_trace("prototype_complete", [
		"use the legally installed Advanced Alloys process and its paused selected method",
		"Game.uninstall_manufacturing_module returns the physical module to module storage",
		"SimulationEngine.production_gameplay_state revalidates the selected method against installed devices",
		"open live Location Industry"
	]), {"screen":"location.industry", "slot":slot, "activityId":String(line.get("activity_id", "")), "gameplayState":gameplay_state, "blockerReason":String(blocker.get("primary_reason", "")), "runControlDisabled":run_button.disabled if run_button != null else false, "navigationControl":String(open_capability.name) if open_capability != null else ""}, "A legally removed process device did not expose DISABLED, the capability blocker, a disabled Run reason and Facility Configuration navigation.")
	await _free_main()


func _cover_construction_states() -> void:
	Game.reset_game()
	var queued := _queue_power_upgrade(false)
	Game.advance_game_time(100000.0)
	await _observe_construction("CONSTRUCTION.WAITING_MATERIAL", "BLOCKED", queued, "MATERIAL_SHORTAGE", ["cancel", "取消项目"], [
		"Game.reset_game()", "Game.queue_location_capacity_upgrade(earth_orbit, POWER_UPGRADE, current + 50)",
		"Game.advance_game_time(100000)"
	])

	Game.reset_game()
	queued = _queue_power_upgrade(true)
	Game.advance_game_time(1.0)
	await _observe_construction("CONSTRUCTION.BUILDING", "RUNNING", queued, "", ["pause project", "暂停项目"], [
		"Game.reset_game()", "SpaceGameState.add_item(each POWER_UPGRADE material)",
		"Game.queue_location_capacity_upgrade(earth_orbit, POWER_UPGRADE, current + 50)",
		"Game.advance_game_time(1)"
	])

	Game.reset_game()
	queued = _queue_power_upgrade(true)
	Game.advance_game_time(1.0)
	var project_id := String((Game.state.construction_operations[0] as Dictionary).get("project_id", ""))
	var paused := Game.set_construction_project_paused(project_id, true)
	Game.advance_game_time(1.0)
	await _observe_construction("CONSTRUCTION.PAUSED", "PAUSED", queued and paused, "MANUALLY_PAUSED", ["resume project", "继续项目"], [
		"Game.reset_game()", "SpaceGameState.add_item(each POWER_UPGRADE material)",
		"Game.queue_location_capacity_upgrade(...)", "Game.advance_game_time(1)",
		"Game.set_construction_project_paused(project_id, true)", "Game.advance_game_time(1)"
	])

	# Completion and cancellation are legally reached as audit probes. They stay
	# UNVERIFIED unless MainScene actually renders their persistent history row.
	Game.reset_game()
	queued = _queue_power_upgrade(true)
	Game.advance_game_time(100000.0)
	await _observe_construction_history("CONSTRUCTION.COMPLETED", "COMPLETE", queued, [
		"Game.reset_game()", "SpaceGameState.add_item(each POWER_UPGRADE material)",
		"Game.queue_location_capacity_upgrade(...)", "Game.advance_game_time(100000)"
	])

	Game.reset_game()
	queued = _queue_power_upgrade(true)
	Game.advance_game_time(1.0)
	var cancelled := Game.stop_construction_project(0)
	Game.advance_game_time(1.0)
	await _observe_construction_history("CONSTRUCTION.CANCELLED", "CANCELLED", queued and cancelled, [
		"Game.reset_game()", "SpaceGameState.add_item(each POWER_UPGRADE material)",
		"Game.queue_location_capacity_upgrade(...)", "Game.advance_game_time(1)",
		"Game.stop_construction_project(0)", "Game.advance_game_time(1)"
	])


func _queue_power_upgrade(funded: bool) -> bool:
	var rules := Game.content.industry_rules.get("capacity_upgrade_projects", {}).get("POWER_UPGRADE", {}) as Dictionary
	if funded:
		_fund_entries(rules.get("costs", []))
	var current := int(Game.state.location_state(MAIN_LOCATION).get("industry", {}).get("power_capacity", 0))
	return Game.queue_location_capacity_upgrade(MAIN_LOCATION, "POWER_UPGRADE", current + int(rules.get("increment", 50)), 50)


func _cover_construction_waiting_capacity() -> void:
	Game.reset_game()
	var power_ok := _queue_power_upgrade(true)
	var cooling_rules := Game.content.industry_rules.get("capacity_upgrade_projects", {}).get("COOLING_UPGRADE", {}) as Dictionary
	_fund_entries(cooling_rules.get("costs", []))
	var current_cooling := int(Game.state.location_state(MAIN_LOCATION).get("industry", {}).get("cooling_capacity", 0))
	var cooling_ok := Game.queue_location_capacity_upgrade(MAIN_LOCATION, "COOLING_UPGRADE", current_cooling + int(cooling_rules.get("increment", 50)), 40)
	var queued: Dictionary = {}
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("status", "")) == "QUEUED":
			queued = runtime
			break
	var formed := power_ok and cooling_ok and not queued.is_empty() and Game.simulation.construction_gameplay_state(queued) == "WAITING_CAPACITY"
	await _spawn_main()
	await _press_named("Navigation_construction")
	var corpus := _visible_text(main)
	var action := main.find_child("ConstructionPriority_%s_100" % String(queued.get("project_id", "")), true, false) as Button
	_record_observation("CONSTRUCTION.WAITING_CAPACITY", formed, _contains_any(corpus, [_status_text("WAITING_CAPACITY"), "WAITING_CAPACITY"]), not queued.is_empty() and corpus.contains(String(queued.get("project_id", ""))) and _contains_any(corpus, ["capacity", "容量"]), _button_usable(action), [
		"Game.reset_game()", "fund POWER_UPGRADE and COOLING_UPGRADE through SpaceGameState.add_item",
		"Game.queue_location_capacity_upgrade twice", "SimulationEngine.normalize_construction_queue assigns the lower-priority project QUEUED"
	], {"screen":"construction", "runtimeStatus":String(queued.get("status", "")), "gameplayState":Game.simulation.construction_gameplay_state(queued), "projectId":String(queued.get("project_id", ""))}, "A legal second project did not expose WAITING_CAPACITY, queue explanation and a priority action together.")
	await _free_main()


func _observe_construction(state_id: String, expected_runtime_status: String, command_ok: bool, blocker_reason: String, action_needles: Array[String], trace: Array[String]) -> void:
	var runtime := Game.state.construction_operations[0] as Dictionary
	var formed := command_ok and String(runtime.get("status", "")) == expected_runtime_status
	var gameplay_state := Game.simulation.construction_gameplay_state(runtime)
	await _spawn_main()
	await _press_named("Navigation_construction")
	var corpus := _visible_text(main)
	var state_visible := _contains_any(corpus, [_status_text(gameplay_state), gameplay_state])
	var explanation_visible := corpus.contains(String(runtime.get("project_id", ""))) and (corpus.contains("Material") or corpus.contains("材料"))
	var evidence := {"screen":"construction", "runtimeStatus":expected_runtime_status, "gameplayState":gameplay_state}
	if not blocker_reason.is_empty():
		var blocker := runtime.get("blocker", {}) as Dictionary
		var actual_reason := String(blocker.get("primary_reason", ""))
		var reason_matches := actual_reason in ["INPUT_SHORTAGE", "INPUT_IN_TRANSIT", "MISSING_CAPITAL_GOOD"] if blocker_reason == "MATERIAL_SHORTAGE" else actual_reason == blocker_reason
		explanation_visible = explanation_visible and reason_matches and corpus.contains(_blocker_text(blocker))
		evidence["blockerReason"] = String(blocker.get("primary_reason", ""))
	var navigation := _find_enabled_button_by_text(action_needles)
	if navigation == null:
		# Priority, pause/resume and cancellation controls are all real Domain
		# commands inside the active Construction page. Use the first enabled page
		# action as evidence without depending on localized button wording.
		navigation = _first_enabled_button_in_page("construction")
	if navigation != null:
		evidence["actionControlText"] = navigation.text
	_record_observation(state_id, formed, state_visible, explanation_visible, navigation != null, trace, evidence, "Construction runtime or its visible status/explanation/action was not observed.")
	await _free_main()


func _observe_construction_history(state_id: String, history_status: String, command_ok: bool, trace: Array[String]) -> void:
	var row := _last_construction_history(history_status)
	var formed := command_ok and not row.is_empty()
	await _spawn_main()
	await _press_named("Navigation_construction")
	var corpus := _visible_text(main)
	var status_visible := _contains_any(corpus, [_status_text(history_status), history_status])
	var project_visible := not row.is_empty() and corpus.contains(String(row.get("project_id", "")))
	var useful_action := _find_enabled_button_by_text(["history", "ledger", "历史", "台账"])
	_record_observation(state_id, formed, status_visible and project_visible, project_visible, useful_action != null, trace, {
		"screen":"construction", "historyStatus":history_status,
		"historyProjectId":String(row.get("project_id", "")), "domainReached":formed
	}, "Domain history was reached legally, but MainScene did not expose a visible history row with an inspection control.")
	await _free_main()


func _cover_research_states() -> void:
	var setup_ok := _prepare_research_complex()
	Game.advance_game_time(1.0)
	var project := Game.content.research_projects.get("research_industrial_coordination", {}) as Dictionary
	var available := setup_ok and Game.simulation.research_project_available(Game.state, project)
	await _spawn_main()
	await _press_named("Navigation_research")
	var corpus := _visible_text(main)
	var start_button := main.find_child("StartResearch_research_industrial_coordination", true, false) as Button
	_record_observation("RESEARCH.AVAILABLE", available, _button_usable(start_button), corpus.contains(I18n.content(project)), _button_usable(start_button), [
		"Game.reset_game()", "legal production completes assemble_frame", "three Game.start_construction_project commands complete founding facilities",
		"Game.advance_game_time after each command", "SimulationEngine.research_project_available(...)"
	], {"screen":"research", "projectId":"research_industrial_coordination", "controlName":String(start_button.name) if start_button != null else ""}, "Available research project was not both authoritative and visibly startable.")
	await _free_main()

	for cost_value in project.get("costs", []):
		_drain_item(String((cost_value as Dictionary).get("item", "")))
	var started := Game.start_research_project("research_industrial_coordination")
	Game.advance_game_time(5000.0)
	await _observe_research_runtime("RESEARCH.WAITING_MATERIAL", "BLOCKED", started, "INPUT_SHORTAGE", [
		"Game.start_research_project(research_industrial_coordination)", "Game.advance_game_time(5000) with no project materials"
	])

	_fund_entries(project.get("costs", []))
	Game.advance_game_time(10.0)
	await _observe_research_runtime("RESEARCH.ACTIVE", "RUNNING", true, "", [
		"SpaceGameState.add_item(each research material)", "Game.advance_game_time(10)"
	])

	Game.advance_game_time(100000.0)
	var completed := bool(Game.state.completed_projects.get("research_industrial_coordination", false))
	await _spawn_main()
	await _press_named("Navigation_research")
	corpus = _visible_text(main)
	var another_start := _first_enabled_named_prefix("StartResearch_")
	_record_observation("RESEARCH.COMPLETED", completed, corpus.contains(I18n.content(project)) and _contains_any(corpus, [_status_text("COMPLETED"), "completed", "已完成"]), corpus.contains(I18n.content(project)), another_start != null or _button_usable(main.find_child("Navigation_industry", true, false) as Button), [
		"Game.advance_game_time(100000)"
	], {"screen":"research", "projectId":"research_industrial_coordination", "completedProjectsValue":completed}, "Completed project was not visible in the Research completion ledger.")
	await _free_main()


func _prepare_research_complex() -> bool:
	Game.reset_game()
	var frame_activity := Game.content.activities.get("assemble_frame", {}) as Dictionary
	_fund_entries(frame_activity.get("costs", []))
	if not Game.start_industry_operation(0, "assemble_frame"):
		return false
	Game.advance_game_time(20000.0)
	if int(Game.state.completed_activities.get("assemble_frame", 0)) <= 0:
		return false
	if String((Game.state.industrial_operations[0] as Dictionary).get("status", "")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(0)
	for activity_id in ["build_orbital_foundry", "build_electronics_facility", "build_research_complex"]:
		var activity := Game.content.activities.get(activity_id, {}) as Dictionary
		_fund_entries(activity.get("costs", []))
		if not Game.start_construction_project(activity_id):
			return false
		Game.advance_game_time(100000.0)
	var expected := ["orbital_foundry", "electronics_facility", "research_complex"]
	return expected.all(func(facility_id: String) -> bool: return Game.simulation.facility_available(Game.state, facility_id))


func _observe_research_runtime(state_id: String, expected_status: String, command_ok: bool, blocker_reason: String, trace: Array[String]) -> void:
	var runtime := Game.state.research as Dictionary
	var formed := command_ok and String(runtime.get("status", "")) == expected_status
	await _spawn_main()
	await _press_named("Navigation_research")
	var corpus := _visible_text(main)
	var state_visible := _contains_any(corpus, [expected_status, _status_text(expected_status)])
	var explanation_visible := corpus.contains(I18n.content(Game.content.research_projects.get("research_industrial_coordination", {})))
	var navigation: Button
	var evidence := {"screen":"research", "runtimeStatus":expected_status}
	if not blocker_reason.is_empty():
		var blocker := runtime.get("blocker", {}) as Dictionary
		explanation_visible = explanation_visible and String(blocker.get("primary_reason", "")) == blocker_reason and corpus.contains(_blocker_text(blocker))
		await _press_named("Navigation_diagnostics")
		navigation = main.find_child("BlockerWhy_%s" % blocker_reason, true, false) as Button
		evidence["blockerReason"] = String(blocker.get("primary_reason", ""))
	else:
		navigation = _find_enabled_button_by_text(["stop research", "停止研究"])
	_record_observation(state_id, formed, state_visible, explanation_visible, _button_usable(navigation), trace, evidence, "Research runtime or its visible explanation/action was not observed.")
	await _free_main()


func _cover_research_locked_and_paused() -> void:
	Game.reset_game()
	Game.advance_game_time(1.0)
	var locked_project: Dictionary = {}
	for project_value in Game.content.research_projects.values():
		var candidate := project_value as Dictionary
		if not Game.simulation.definition_revealed(Game.state, candidate):
			locked_project = candidate
			break
	await _spawn_main()
	await _press_named("Navigation_research")
	var locked_id := String(locked_project.get("id", ""))
	var corpus := _visible_text(main)
	var guidance := main.find_child("ResearchUnlockGuidance_%s" % locked_id, true, false) as Button
	_record_observation("RESEARCH.LOCKED", not locked_project.is_empty(), _contains_any(corpus, [_status_text("LOCKED"), "LOCKED"]), not locked_project.is_empty() and corpus.contains(I18n.content(locked_project)) and _contains_any(corpus, ["prerequisite", "requirement", "前置", "需求"]), _button_usable(guidance), [
		"Game.reset_game()", "SimulationEngine.definition_revealed returns false for a future program", "open live Research page"
	], {"screen":"research", "projectId":locked_id, "navigationControl":String(guidance.name) if guidance != null else ""}, "An authoritative unrevealed program did not expose LOCKED, prerequisites and progression-objective navigation.")
	await _free_main()

	Game.reset_game()
	var setup_ok := _prepare_research_complex()
	var started := setup_ok and Game.start_research_project("research_industrial_coordination")
	var paused := started and Game.stop_research()
	Game.advance_game_time(1.0)
	var formed := paused and Game.simulation.research_gameplay_state(Game.state) == "PAUSED"
	await _spawn_main()
	await _press_named("Navigation_research")
	corpus = _visible_text(main)
	var resume := main.find_child("ResumeResearch_research_industrial_coordination", true, false) as Button
	_record_observation("RESEARCH.PAUSED", formed, _contains_any(corpus, [_status_text("PAUSED"), "PAUSED"]), corpus.contains(I18n.content(Game.content.research_projects.get("research_industrial_coordination", {}))) and _contains_any(corpus, ["paused", "暂停"]), _button_usable(resume), [
		"legally construct founding Research facilities", "Game.start_research_project(research_industrial_coordination)", "Game.stop_research()"
	], {"screen":"research", "projectId":"research_industrial_coordination", "gameplayState":Game.simulation.research_gameplay_state(Game.state), "navigationControl":"ResumeResearch_research_industrial_coordination"}, "A legally paused program did not expose PAUSED, its committed project and an enabled Resume action.")
	await _free_main()


func _cover_golden_research_waiting_states() -> void:
	await _observe_golden_research_waiting("RESEARCH.WAITING_FACILITY", "WAITING_FACILITY", "research_waiting_facility")
	await _observe_golden_research_waiting("RESEARCH.WAITING_PROTOTYPE", "WAITING_PROTOTYPE", "research_waiting_prototype")
	await _observe_golden_research_waiting("RESEARCH.WAITING_FIELD_TEST", "WAITING_FIELD_TEST", "research_waiting_field_test")


func _observe_golden_research_waiting(state_id: String, expected_gameplay_state: String, scenario_id: String) -> void:
	var activated := _activate_golden_scenario(scenario_id)
	var runtime: Dictionary = Game.state.research if activated else {}
	var project_id := String(runtime.get("project_id", ""))
	var project: Dictionary = Game.content.research_projects.get(project_id, {})
	var blocker: Dictionary = runtime.get("blocker", {}) if runtime.get("blocker", null) is Dictionary else {}
	var reason := String(blocker.get("primary_reason", ""))
	var gameplay_state := Game.simulation.research_gameplay_state(Game.state) if activated else ""
	var formed := activated and String(runtime.get("status", "")) == "BLOCKED" and gameplay_state == expected_gameplay_state and not reason.is_empty()
	await _spawn_main()
	await _press_named("Navigation_research")
	var corpus := _visible_text(main)
	var state_visible := _contains_any(corpus, [_status_text(expected_gameplay_state), expected_gameplay_state])
	var explanation_visible := not project.is_empty() and corpus.contains(I18n.content(project)) and corpus.contains(_blocker_text(blocker))
	await _press_named("Navigation_diagnostics")
	var why := main.find_child("BlockerWhy_%s" % reason, true, false) as Button
	_record_observation(state_id, formed, state_visible, explanation_visible, _button_usable(why), _scenario_trace(scenario_id, [
		"activate invariant-valid checkpoint emitted by the no-cheat Golden Path",
		"read SimulationEngine.research_gameplay_state and the authoritative blocker",
		"open live Research and Diagnostics pages"
	]), {
		"screens":["research", "diagnostics"], "projectId":project_id,
		"runtimeStatus":String(runtime.get("status", "")), "gameplayState":gameplay_state,
		"blockerReason":reason, "navigationControl":String(why.name) if why != null else ""
	}, "The legal staged-research checkpoint did not expose its normalized waiting state, blocker explanation and root-cause navigation together.")
	await _free_main()


func _cover_survey_states() -> void:
	Game.reset_game()
	Game.advance_game_time(1.0)
	await _spawn_main()
	await _press_named("Navigation_system_map")
	var unknown_node := main.find_child("Location_lunar_space", true, false) as Button
	var map_state_visible := unknown_node != null and unknown_node.disabled \
		and not unknown_node.tooltip_text.is_empty() \
		and _contains_any(unknown_node.text, [_status_text("UNKNOWN"), "UNKNOWN"])
	var corpus := _visible_text(main)
	var ship_navigation := main.find_child("Navigation_ships", true, false) as Button
	_record_observation("SURVEY.UNKNOWN", String(Game.state.location_state("lunar_space").get("survey_state", "")) == LocationState.UNKNOWN, map_state_visible and _contains_any(corpus, [_status_text("UNKNOWN"), "UNKNOWN"]), _contains_any(corpus, ["survey vessel", "survey module", "勘测舰", "勘测模块", "尚无可用于工业投资的情报"]), _button_usable(ship_navigation), [
		"Game.reset_game()", "Game.advance_game_time(1)", "press Navigation_system_map", "press Location_lunar_space"
	], {"screen":"location.overview", "locationId":"lunar_space", "mapControl":"Location_lunar_space"}, "Fresh unknown Location was not visibly explained with a route to ship requirements.")
	await _free_main()

	# The canonical founding base is legally created as SURVEYED by New Game.
	Game.reset_game()
	Game.advance_game_time(1.0)
	await _spawn_main()
	await _press_named("Navigation_system_map")
	var surveyed_node := main.find_child("Location_earth_orbit", true, false) as Button
	var surveyed_map_visible := _button_usable(surveyed_node) and _contains_any(surveyed_node.text, [_status_text("SURVEYED"), "SURVEYED"])
	if _button_usable(surveyed_node):
		surveyed_node.pressed.emit()
		await _settle_ui()
	corpus = _visible_text(main)
	var resources_tab := main.find_child("LocationTab_resources", true, false) as Button
	_record_observation("SURVEY.SURVEYED", String(Game.state.location_state(MAIN_LOCATION).get("survey_state", "")) == LocationState.SURVEYED, surveyed_map_visible and _contains_any(corpus, [_status_text("SURVEYED"), "SURVEYED"]), _contains_any(corpus, ["environment", "gravity", "环境条件", "重力"]), _button_usable(resources_tab), [
		"Game.reset_game() creates canonical founding Location", "Game.advance_game_time(1)",
		"press Navigation_system_map", "press Location_earth_orbit"
	], {"screen":"location.overview", "locationId":MAIN_LOCATION, "mapControl":"Location_earth_orbit"}, "Canonical surveyed founding Location was not visibly disclosed with a resource navigation control.")
	await _free_main()


func _cover_megastructure_locked() -> void:
	Game.reset_game()
	Game.advance_game_time(1.0)
	var formed := not bool(Game.state.completed_projects.get("research_megastructures", false)) and Game.state.megastructure_projects.is_empty()
	await _spawn_main()
	var nav := main.find_child("Navigation_megastructure", true, false) as Button
	var nav_explains_lock := _button_usable(nav) and (_contains_any(nav.text, ["locked", "锁定"]) or not nav.tooltip_text.is_empty())
	await _press_named("Navigation_megastructure")
	var corpus := _visible_text(main)
	var research_nav := main.find_child("Navigation_research", true, false) as Button
	_record_observation("MEGASTRUCTURE.LOCKED", formed, nav_explains_lock and _contains_any(corpus, [_status_text("LOCKED"), "LOCKED", "locked", "锁定"]), _contains_any(corpus, ["research", "engineering program", "研究", "计划"]), _button_usable(research_nav), [
		"Game.reset_game()", "Game.advance_game_time(1)", "press Navigation_megastructure"
	], {"screen":"megastructure", "navigationTooltip":nav.tooltip_text if nav != null else ""}, "Fresh-save megastructure lock was not visible with a useful Research navigation control.")
	await _free_main()


func _cover_megastructure_preparation_states() -> void:
	var activated := _activate_golden_scenario("open_deep")
	var research_required := activated and Game.simulation.megastructure_gameplay_state(Game.state, "stellar_energy") == "RESEARCH_REQUIRED"
	await _spawn_main()
	await _press_named("Navigation_megastructure")
	var corpus := _visible_text(main)
	var research_nav := main.find_child("Navigation_research", true, false) as Button
	_record_observation("MEGASTRUCTURE.RESEARCH_REQUIRED", research_required, _contains_any(corpus, [_status_text("RESEARCH_REQUIRED"), "RESEARCH_REQUIRED"]), _contains_any(corpus, ["research", "engineering program", "科研", "工程计划"]), _button_usable(research_nav), _scenario_trace("open_deep", [
		"read SimulationEngine.megastructure_gameplay_state after normal Golden progression reveals the endgame program"
	]), {"screen":"megastructure", "gameplayState":Game.simulation.megastructure_gameplay_state(Game.state, "stellar_energy") if activated else "", "navigationControl":"Navigation_research"}, "The revealed but incomplete endgame program did not expose RESEARCH_REQUIRED with a Research route.")
	await _free_main()

	activated = _activate_golden_scenario("megastructure_site_preparation")
	var site_preparation := activated and Game.simulation.megastructure_gameplay_state(Game.state, "stellar_energy") == "SITE_PREPARATION" and Game.state.megastructure_projects.is_empty()
	await _spawn_main()
	await _press_named("Navigation_megastructure")
	corpus = _visible_text(main)
	var select_site := _first_enabled_named_prefix("SelectMegastructureSite_")
	_record_observation("MEGASTRUCTURE.SITE_PREPARATION", site_preparation, _contains_any(corpus, [_status_text("SITE_PREPARATION"), "SITE_PREPARATION"]), _contains_any(corpus, ["deep-survey", "candidate", "深度勘测", "候选"]), _button_usable(select_site), _scenario_trace("megastructure_site_preparation", [
		"Golden path completes research_megastructures and deep survey before committing a site", "open live Megastructure candidate list"
	]), {"screen":"megastructure", "gameplayState":Game.simulation.megastructure_gameplay_state(Game.state, "stellar_energy") if activated else "", "navigationControl":String(select_site.name) if select_site != null else ""}, "The legal pre-commit checkpoint did not expose SITE_PREPARATION, candidate explanation and an enabled site-selection action.")
	await _free_main()


func _cover_golden_scenario_survey_states() -> void:
	# The snapshot is a legal Golden Path checkpoint, not a claim that this test
	# replayed the whole preceding journey. Starting from that checkpoint, DETECTED
	# is still produced by the public survey command and Simulation advancement.
	var activated := _activate_golden_scenario("open_deep")
	var target_id := "inner_solar_orbit"
	var next_state := LocationState.DETECTED
	var costs: Dictionary = Game.simulation.survey_mission_costs(next_state) if activated else {}
	for item_id_value in costs.keys():
		Game.state.add_item(String(item_id_value), int(costs[item_id_value]), MAIN_LOCATION)
	var availability: Dictionary = Game.survey_mission_availability(target_id, next_state) if activated else {}
	var selected_ships: Array = availability.get("selected_ship_ids", [])
	var started := activated and bool(availability.get("allowed", false)) and Game.start_survey_mission(target_id, next_state, selected_ships)
	if started:
		var duration_ms := float(Game.state.survey_mission.get("duration_ms", 0.0))
		Game.advance_game_time(duration_ms + 1.0)
	var detected_location: Dictionary = Game.state.location_state(target_id) if activated else {}
	var detected_formed := started and String(detected_location.get("survey_state", "")) == next_state
	await _spawn_main()
	await _press_named("Navigation_system_map")
	var detected_node := main.find_child("Location_%s" % target_id, true, false) as Button
	var detected_map_visible := _button_usable(detected_node) and _contains_any(detected_node.text, [_status_text(next_state), next_state])
	if _button_usable(detected_node):
		detected_node.pressed.emit()
		await _settle_ui()
	var detected_corpus := _visible_text(main)
	var detected_intelligence: Dictionary = Game.simulation.location_intelligence(Game.state, target_id) if activated else {}
	var detected_environment: Dictionary = detected_intelligence.get("environment", {})
	var detected_explanation := _contains_any(detected_corpus, [
		_status_text(String(detected_environment.get("radiation", "UNKNOWN"))),
		_status_text(String(detected_environment.get("transport_distance_band", "UNKNOWN")))
	])
	var continue_survey := _first_enabled_named_prefix("StartSurvey_%s_%s_" % [target_id, LocationState.SURVEYED])
	var survey_navigation := continue_survey
	if not _button_usable(survey_navigation):
		survey_navigation = main.find_child("Navigation_ships", true, false) as Button
	_record_observation("SURVEY.DETECTED", detected_formed, detected_map_visible and _contains_any(detected_corpus, [_status_text(next_state), next_state]), detected_explanation, _button_usable(survey_navigation), _scenario_trace("open_deep", [
		"SpaceGameState.add_item(each DETECTED survey cost at earth_orbit)",
		"Game.survey_mission_availability(inner_solar_orbit, DETECTED)",
		"Game.start_survey_mission(inner_solar_orbit, DETECTED, selected_ship_ids)",
		"Game.advance_game_time(mission duration)"
	]), {
		"screen":"location.overview", "locationId":target_id,
		"domainSurveyState":String(detected_location.get("survey_state", "")),
		"selectedShipIds":selected_ships,
		"navigationControl":String(survey_navigation.name) if survey_navigation != null else ""
	}, "The Golden checkpoint allowed a legal detection mission, but the live Location UI did not expose the detected state, preliminary explanation and a usable next-survey control together.")
	await _free_main()

	# open_deep already contains the legally Surveyed Asteroid Belt and the
	# legally researched/built deep-survey vessel. The final level is still formed
	# here through the public mission command so exact asteroid resource data can
	# be asserted without pretending that resource-less Lagrange space has ore.
	activated = _activate_golden_scenario("open_deep")
	target_id = "asteroid_belt"
	var deep_costs: Dictionary = Game.simulation.survey_mission_costs(LocationState.DEEP_SURVEYED) if activated else {}
	for item_id_value in deep_costs.keys():
		Game.state.add_item(String(item_id_value), int(deep_costs[item_id_value]), MAIN_LOCATION)
	var deep_availability: Dictionary = Game.survey_mission_availability(target_id, LocationState.DEEP_SURVEYED) if activated else {}
	var deep_ships: Array = deep_availability.get("selected_ship_ids", [])
	var deep_started := activated and bool(deep_availability.get("allowed", false)) and Game.start_survey_mission(target_id, LocationState.DEEP_SURVEYED, deep_ships)
	if deep_started:
		Game.advance_game_time(float(Game.state.survey_mission.get("duration_ms", 0.0)) + 1.0)
	var deep_location: Dictionary = Game.state.location_state(target_id) if activated else {}
	var deep_formed := deep_started and String(deep_location.get("survey_state", "")) == LocationState.DEEP_SURVEYED
	await _spawn_main()
	await _press_named("Navigation_system_map")
	var deep_node := main.find_child("Location_%s" % target_id, true, false) as Button
	var deep_map_visible := _button_usable(deep_node) and _contains_any(deep_node.text, [_status_text(LocationState.DEEP_SURVEYED), LocationState.DEEP_SURVEYED])
	if _button_usable(deep_node):
		deep_node.pressed.emit()
		await _settle_ui()
	var deep_overview := _visible_text(main)
	var resources_tab := main.find_child("LocationTab_resources", true, false) as Button
	var resources_navigation := _button_usable(resources_tab)
	if resources_navigation:
		resources_tab.pressed.emit()
		await _settle_ui()
	var resources_corpus := _visible_text(main)
	var intelligence: Dictionary = Game.simulation.location_intelligence(Game.state, target_id) if activated else {}
	var resource_profiles: Array = intelligence.get("resources", [])
	var exact_resource_visible := false
	for profile_value in resource_profiles:
		var profile := profile_value as Dictionary
		var item_id := String(profile.get("resource_type", ""))
		if not item_id.is_empty() and resources_corpus.contains(I18n.content(Game.content.items.get(item_id, {"id":item_id, "name":item_id}))):
			exact_resource_visible = true
			break
	_record_observation("SURVEY.DEEP_SURVEYED", deep_formed, deep_map_visible and _contains_any(deep_overview, [_status_text(LocationState.DEEP_SURVEYED), LocationState.DEEP_SURVEYED]), exact_resource_visible and not resource_profiles.is_empty(), resources_navigation, _scenario_trace("open_deep", [
		"SpaceGameState.add_item(each DEEP_SURVEYED mission cost at earth_orbit)",
		"Game.survey_mission_availability(asteroid_belt, DEEP_SURVEYED)",
		"Game.start_survey_mission(asteroid_belt, DEEP_SURVEYED, selected_ship_ids)",
		"Game.advance_game_time(mission duration_ms)",
		"open live System Map node, Location Overview and Resources tab"
	]), {
		"screens":["system", "location.overview", "location.resources"],
		"locationId":target_id, "domainSurveyState":String(deep_location.get("survey_state", "")),
		"selectedShipIds":deep_ships, "resourceProfileCount":resource_profiles.size(), "navigationControl":"LocationTab_resources"
	}, "The legal deep-survey checkpoint loaded, but exact resource disclosure or its useful Resources navigation was absent from the live Location UI.")
	await _free_main()


func _cover_golden_scenario_logistics_states() -> void:
	var activated := _activate_golden_scenario("megastructure_phase_2")
	await _observe_logistics_service("LOGISTICS.UNDERUTILIZED", "UNDERUTILIZED", activated, "megastructure_phase_2", [
		"read SimulationEngine.logistics.service_snapshot(earth_lagrange_freight) after checkpoint activation"
	])

	var dispatch := _form_golden_logistics_dispatch(0.5)
	await _observe_logistics_service("LOGISTICS.ACTIVE", "ACTIVE", bool(dispatch.get("setupOk", false)), "megastructure_phase_2", dispatch.get("trace", []), dispatch)

	dispatch = _form_golden_logistics_dispatch(1.0)
	await _observe_logistics_service("LOGISTICS.SATURATED", "SATURATED", bool(dispatch.get("setupOk", false)), "megastructure_phase_2", dispatch.get("trace", []), dispatch)

	# The Domain blocker is deliberately observed even though MainScene currently
	# renders NO_SUPPLY_SOURCE instead of the registry's BLOCKED_SOURCE badge.
	activated = _activate_golden_scenario("megastructure_phase_2")
	var destination := "earth_sun_lagrange"
	var item_id := "iron_ingot"
	_drain_item_at(item_id, destination)
	var demand_ok := activated and Game.set_location_logistics_policy(destination, item_id, LogisticsEngine.MODE_DEMAND, 0, 10, 100, 1, MAIN_LOCATION, "earth_lagrange_freight")
	Game.advance_game_time(5000.0)
	var demand_policy: Dictionary = Game.state.location_state(destination).get("logistics", {}).get("policies", {}).get(item_id, {}) if activated else {}
	var policy_blocker: Dictionary = demand_policy.get("blocker", {})
	var blocker_code := String(policy_blocker.get("code", ""))
	var blocked_source_formed := demand_ok and blocker_code in ["NO_SUPPLY_SOURCE", "LOGISTICS_OPERATING_COST"]
	await _open_location_section(destination, "logistics")
	var blocker_corpus := _visible_text(main)
	var why_button := _find_enabled_button_by_text(["why?", "open resolution", "原因", "解决"])
	_record_observation("LOGISTICS.BLOCKED_SOURCE", blocked_source_formed, _contains_any(blocker_corpus, [_status_text("BLOCKED_SOURCE"), "BLOCKED_SOURCE"]), not blocker_code.is_empty() and _contains_any(blocker_corpus, [blocker_code, _status_text(blocker_code)]), _button_usable(why_button), _scenario_trace("megastructure_phase_2", [
		"Game.set_location_logistics_policy(earth_sun_lagrange, iron_ingot, DEMAND, source_lock=earth_orbit, route_lock=earth_lagrange_freight)",
		"Game.advance_game_time(5000 ms) lets LogisticsEngine._dispatch create the policy blocker"
	]), {
		"screen":"location.logistics", "domainBlockerCode":blocker_code,
		"normalizedRegistryState":"BLOCKED_SOURCE", "navigationControlText":why_button.text if why_button != null else ""
	}, "Domain formed a source-side logistics blocker, but MainScene did not show the normalized BLOCKED_SOURCE state, its explanation and resolution control together.")
	await _free_main()

	await _cover_blocked_destination_from_golden_scenario()


func _cover_logistics_paused() -> void:
	var scenario_id := "megastructure_phase_2"
	var activated := _activate_golden_scenario(scenario_id)
	var route_id := "earth_lagrange_freight"
	var paused := activated and Game.set_logistics_service_paused(route_id, true)
	var snapshot: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id) if paused else {}
	var formed := paused and String(snapshot.get("status", "")) == "PAUSED" and is_zero_approx(float(snapshot.get("capacity_per_dispatch", 0.0)))
	await _open_location_section("earth_sun_lagrange", "logistics")
	var corpus := _visible_text(main)
	var resume := main.find_child("ResumeLogisticsRoute_%s" % route_id, true, false) as Button
	_record_observation("LOGISTICS.PAUSED", formed, _contains_any(corpus, [_status_text("PAUSED"), "PAUSED"]), corpus.contains(I18n.content(Game.content.logistics_routes.get(route_id, {}))) and _contains_any(corpus, ["capacity", "运力"]), _button_usable(resume), _scenario_trace(scenario_id, [
		"Game.set_logistics_service_paused(earth_lagrange_freight, true)", "read LogisticsEngine.service_snapshot"
	]), {"screen":"location.logistics", "routeId":route_id, "serviceStatus":String(snapshot.get("status", "")), "capacityPerDispatch":float(snapshot.get("capacity_per_dispatch", 0.0)), "navigationControl":String(resume.name) if resume != null else ""}, "A legally paused route service did not expose PAUSED, zero dispatch capacity and an enabled Resume control.")
	await _free_main()


func _verify_diagnostics_upstream_logistics_navigation() -> void:
	var route_id := "earth_lagrange_freight"
	var destination := "earth_sun_lagrange"
	var item_id := "steel_composite"
	var competing_item_id := "iron_ingot"
	var activated := _activate_golden_scenario("megastructure_phase_2")
	if activated:
		_drain_item_at(competing_item_id, destination)
		_drain_item_at(item_id, destination)
		_drain_item_at(item_id, MAIN_LOCATION)
	var before: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id) if activated else {}
	var capacity := maxi(1, int(floor(float(before.get("capacity_per_dispatch", 0.0)))))
	if activated:
		Game.state.add_item(competing_item_id, capacity + 10, MAIN_LOCATION)
		Game.state.add_item("chemical_propellant", 10, MAIN_LOCATION)
	var iron_supply_ok := activated and Game.set_location_logistics_policy(MAIN_LOCATION, competing_item_id, LogisticsEngine.MODE_SUPPLY, 0, 0, 100, 1, "", route_id)
	var blocked_supply_ok := iron_supply_ok and Game.set_location_logistics_policy(MAIN_LOCATION, item_id, LogisticsEngine.MODE_SUPPLY, 0, 0, 10, 1, "", route_id)
	var iron_demand_ok := blocked_supply_ok and Game.set_location_logistics_policy(destination, competing_item_id, LogisticsEngine.MODE_DEMAND, 0, capacity, 100, 1, MAIN_LOCATION, route_id)
	var blocked_demand_ok := iron_demand_ok and Game.set_location_logistics_policy(destination, item_id, LogisticsEngine.MODE_DEMAND, 0, 10, 1, 1, MAIN_LOCATION, route_id)
	if blocked_demand_ok:
		# The higher-priority Iron demand consumes the real route budget. The lower-
		# priority Steel Composite demand is then blocked by the LogisticsEngine in
		# the same dispatch. No service utilization or policy blocker is assigned by
		# the test.
		Game.advance_game_time(5000.0)
	var after: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id) if blocked_demand_ok else {}
	var saturated := String(after.get("status", "")) == "SATURATED"

	var matched_blocker: Dictionary = {}
	for blocker_value in Game.active_blockers():
		var blocker := blocker_value as Dictionary
		var missing: Dictionary = blocker.get("missing_requirement", {})
		var upstream: Dictionary = blocker.get("upstream_cause", {})
		if String(blocker.get("location_id", "")) == destination \
				and String(missing.get("item_id", "")) == item_id \
				and String(upstream.get("code", "")) == "ROUTE_CONGESTED" \
				and String(upstream.get("route_id", "")) == route_id:
			matched_blocker = blocker
			break
	var formed := blocked_demand_ok and saturated and not matched_blocker.is_empty()
	_check(formed, "legal competing Logistics policies form an authoritative upstream route blocker (setup=%s, status=%s, active=%d)" % [str(blocked_demand_ok), String(after.get("status", "")), Game.active_blockers().size()])

	await _spawn_main()
	var diagnostics_opened := await _press_named("Navigation_diagnostics")
	var reason := String(matched_blocker.get("code", ""))
	var upstream_button := main.find_child("BlockerUpstream_%s_%s" % [reason, route_id], true, false) as Button if diagnostics_opened and not reason.is_empty() else null
	_check(_button_usable(upstream_button), "Diagnostics exposes an enabled BlockerUpstream_* root-cause action for the saturated route")
	if _button_usable(upstream_button):
		upstream_button.pressed.emit()
		await _settle_ui()

	var item_selection: Dictionary = main.get("_logistics_item_selection") if is_instance_valid(main) else {}
	var route_card := main.find_child("LogisticsRouteCard_%s" % route_id, true, false) if is_instance_valid(main) else null
	_check(is_instance_valid(main) and String(main.get("_active_page_key")) == "logistics", "upstream root-cause action opens Logistics")
	_check(is_instance_valid(main) and String(main.get("_selected_location_id")) == destination, "upstream root-cause action preserves the affected destination Location")
	_check(String(item_selection.get(destination, "")) == item_id, "upstream root-cause action preserves the missing product context")
	_check(is_instance_valid(main) and String(main.get("_logistics_route_focus_id")) == route_id, "upstream root-cause action preserves the saturated route context")
	_check(route_card != null and (route_card as CanvasItem).is_visible_in_tree(), "the focused upstream route has a player-visible Logistics Route Card")
	await _free_main()


func _cover_logistics_no_transport() -> void:
	var scenario_id := "megastructure_phase_2"
	var source := MAIN_LOCATION
	var destination := "earth_sun_lagrange"
	var item_id := "iron_ingot"
	var impossible_route_lock := "outer_deep_freight"
	var activated := _activate_golden_scenario(scenario_id)
	if activated:
		_drain_item_at(item_id, destination)
		Game.state.add_item(item_id, 20, source)
	var supply_ok: bool = activated and Game.set_location_logistics_policy(source, item_id, LogisticsEngine.MODE_SUPPLY, 0, 0, 80, 1)
	var demand_ok: bool = supply_ok and Game.set_location_logistics_policy(destination, item_id, LogisticsEngine.MODE_DEMAND, 0, 10, 90, 1, source, impossible_route_lock)
	if demand_ok:
		Game.advance_game_time(5000.0)
	var policy: Dictionary = Game.state.location_state(destination).get("logistics", {}).get("policies", {}).get(item_id, {}) if demand_ok else {}
	var blocker: Dictionary = policy.get("blocker", {})
	var formed: bool = demand_ok and Game.simulation.logistics.policy_gameplay_status(policy) == "NO_TRANSPORT" and String(blocker.get("code", "")) == "ROUTE_LOCK_UNAVAILABLE"
	await _open_location_section(destination, "logistics")
	var corpus := _visible_text(main)
	var why := _find_enabled_button_by_text(["why?", "open resolution", "原因", "解决"])
	if not _button_usable(why):
		why = main.find_child("Navigation_ships", true, false) as Button
	_record_observation("LOGISTICS.NO_TRANSPORT", formed, _contains_any(corpus, [_status_text("NO_TRANSPORT"), "NO_TRANSPORT"]), corpus.contains(_status_text("ROUTE_LOCK_UNAVAILABLE")) and corpus.contains(I18n.content(Game.content.items.get(item_id, {}))), _button_usable(why), _scenario_trace(scenario_id, [
		"Game.set_location_logistics_policy(earth_orbit, iron_ingot, SUPPLY)",
		"Game.set_location_logistics_policy(earth_sun_lagrange, iron_ingot, DEMAND, source_lock=earth_orbit, route_lock=outer_deep_freight)",
		"the route lock is a real discovered route but cannot belong to the requested source/destination path",
		"Game.advance_game_time lets LogisticsEngine._dispatch emit ROUTE_LOCK_UNAVAILABLE"
	]), {
		"screen":"location.logistics", "itemId":item_id, "source":source, "destination":destination,
		"routeLock":impossible_route_lock, "blockerCode":String(blocker.get("code", "")),
		"normalizedState":Game.simulation.logistics.policy_gameplay_status(policy), "navigationControl":String(why.name) if why != null else ""
	}, "A valid but incompatible player route lock did not expose NO_TRANSPORT, the locked route cause and a useful transport-resolution entry.")
	await _free_main()


func _form_golden_logistics_dispatch(target_fraction: float) -> Dictionary:
	var scenario_id := "megastructure_phase_2"
	var activated := _activate_golden_scenario(scenario_id)
	var route_id := "earth_lagrange_freight"
	var destination := "earth_sun_lagrange"
	var item_id := "iron_ingot"
	if not activated:
		return {"formed":false, "trace":_scenario_trace(scenario_id)}
	_drain_item_at(item_id, destination)
	var before: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id)
	var capacity := maxi(1, int(floor(float(before.get("capacity_per_dispatch", 0.0)))))
	var desired := maxi(1, int(ceil(float(capacity) * target_fraction)))
	var free_quantity := int(floor(Game.simulation.location_storage_free_quantity_for_item(Game.state, destination, item_id)))
	desired = mini(desired, free_quantity)
	Game.state.add_item(item_id, desired + 10, MAIN_LOCATION)
	Game.state.add_item("chemical_propellant", 10, MAIN_LOCATION)
	var supply_ok := Game.set_location_logistics_policy(MAIN_LOCATION, item_id, LogisticsEngine.MODE_SUPPLY, 0, 0, 100, 1, "", route_id)
	var demand_ok := Game.set_location_logistics_policy(destination, item_id, LogisticsEngine.MODE_DEMAND, 0, desired, 100, 1, MAIN_LOCATION, route_id)
	Game.advance_game_time(5000.0)
	var after: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id)
	var expected_status := "SATURATED" if target_fraction >= 0.999 else "ACTIVE"
	return {
		"setupOk":supply_ok and demand_ok,
		"formed":supply_ok and demand_ok and String(after.get("status", "")) == expected_status,
		"routeId":route_id, "itemId":item_id, "requestedUnits":desired,
		"serviceSnapshot":after.duplicate(true),
		"trace":_scenario_trace(scenario_id, [
			"SpaceGameState.remove_item clears destination iron_ingot through the public inventory API",
			"SpaceGameState.add_item supplies iron_ingot and chemical_propellant at earth_orbit",
			"Game.set_location_logistics_policy creates legal SUPPLY and DEMAND policies locked to earth_lagrange_freight",
			"Game.advance_game_time(5000 ms) lets LogisticsEngine dispatch and measure real utilization"
		])
	}


func _observe_logistics_service(state_id: String, expected_status: String, setup_ok: bool, scenario_id: String, trace_value: Variant, extra_evidence: Dictionary = {}) -> void:
	var route_id := "earth_lagrange_freight"
	var snapshot: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id) if setup_ok else {}
	var formed := setup_ok and String(snapshot.get("status", "")) == expected_status
	await _open_location_section("earth_sun_lagrange", "logistics")
	var corpus := _visible_text(main)
	var route: Dictionary = Game.content.logistics_routes.get(route_id, {})
	var capacity_text := "%.1f" % float(snapshot.get("capacity_per_dispatch", 0.0))
	var state_visible := _contains_any(corpus, [_status_text(expected_status), expected_status])
	var explanation := corpus.contains(I18n.content(route)) and corpus.contains(capacity_text)
	var navigation := main.find_child("LogisticsPolicyAdvancedToggle", true, false) as Button
	var evidence := extra_evidence.duplicate(true)
	evidence.merge({
		"screen":"location.logistics", "routeId":route_id,
		"serviceStatus":String(snapshot.get("status", "")),
		"utilization":float(snapshot.get("utilization", 0.0)),
		"capacityPerDispatch":float(snapshot.get("capacity_per_dispatch", 0.0)),
		"navigationControl":"LogisticsPolicyAdvancedToggle"
	}, true)
	var trace: Array[String] = []
	if trace_value is Array:
		for step_value in trace_value:
			trace.append(String(step_value))
	if trace.is_empty():
		trace = _scenario_trace(scenario_id)
	_record_observation(state_id, formed, state_visible, explanation, _button_usable(navigation), trace, evidence, "The legal Golden logistics state or its visible route status, measured capacity/utilization and policy navigation was not observed together.")
	await _free_main()


func _cover_blocked_destination_from_golden_scenario() -> void:
	var scenario_id := "megastructure_phase_2"
	var activated := _activate_golden_scenario(scenario_id)
	var route_id := "earth_lagrange_freight"
	var destination := "earth_sun_lagrange"
	var item_id := "iron_ingot"
	_drain_item_at(item_id, destination)
	Game.state.add_item(item_id, 20, MAIN_LOCATION)
	Game.state.add_item("chemical_propellant", 10, MAIN_LOCATION)
	var supply_ok := activated and Game.set_location_logistics_policy(MAIN_LOCATION, item_id, LogisticsEngine.MODE_SUPPLY, 0, 0, 100, 1, "", route_id)
	var demand_ok := activated and Game.set_location_logistics_policy(destination, item_id, LogisticsEngine.MODE_DEMAND, 0, 10, 100, 1, MAIN_LOCATION, route_id)
	Game.advance_game_time(5000.0)
	var shipment: Dictionary = {}
	for shipment_value in Game.state.logistics_network.get("shipments", []):
		var candidate := shipment_value as Dictionary
		if String(candidate.get("destination", "")) == destination and int(candidate.get("cargo", {}).get(item_id, 0)) > 0:
			shipment = candidate
			break
	if not shipment.is_empty():
		var fill_quantity := int(floor(Game.simulation.location_storage_free_quantity_for_item(Game.state, destination, item_id)))
		Game.state.add_item(item_id, fill_quantity, destination)
		Game.advance_game_time(float(shipment.get("remaining_ms", 0.0)) + 1.0)
	var blocked_shipment: Dictionary = {}
	for shipment_value in Game.state.logistics_network.get("shipments", []):
		var candidate := shipment_value as Dictionary
		if String(candidate.get("destination", "")) == destination and String(candidate.get("status", "")) == "BLOCKED_OUTPUT":
			blocked_shipment = candidate
			break
	var formed := supply_ok and demand_ok and not blocked_shipment.is_empty() and String(blocked_shipment.get("blocker", {}).get("primary_reason", "")) == "STORAGE_FULL"
	await _open_location_section(destination, "logistics")
	var corpus := _visible_text(main)
	var industry_tab := main.find_child("LocationTab_industry", true, false) as Button
	_record_observation("LOGISTICS.BLOCKED_DESTINATION", formed, _contains_any(corpus, [_status_text("BLOCKED_DESTINATION"), "BLOCKED_DESTINATION"]), not blocked_shipment.is_empty() and corpus.contains(String(blocked_shipment.get("id", ""))) and _contains_any(corpus, ["STORAGE_FULL", _status_text("STORAGE_FULL")]), _button_usable(industry_tab), _scenario_trace(scenario_id, [
		"Game.set_location_logistics_policy creates legal locked SUPPLY and DEMAND policies",
		"Game.advance_game_time(5000 ms) creates an owned in-transit shipment",
		"SpaceGameState.add_item fills destination storage through the public inventory API",
		"Game.advance_game_time(to arrival in ms) lets LogisticsEngine.settle_ready preserve shipment ownership as BLOCKED_OUTPUT/STORAGE_FULL"
	]), {
		"screen":"location.logistics", "shipmentId":String(blocked_shipment.get("id", "")),
		"domainShipmentStatus":String(blocked_shipment.get("status", "")),
		"domainBlockerReason":String(blocked_shipment.get("blocker", {}).get("primary_reason", "")),
		"normalizedRegistryState":"BLOCKED_DESTINATION"
	}, "Domain preserved a destination-blocked shipment, but MainScene did not expose the normalized BLOCKED_DESTINATION state, unloading explanation and storage navigation together.")
	await _free_main()


func _cover_golden_scenario_megastructure_states() -> void:
	var scenario_id := "megastructure_phase_2"
	var activated := _activate_golden_scenario(scenario_id)
	var started := activated and Game.start_megastructure_phase("stellar_energy", 90)
	await _observe_megastructure_runtime("MEGASTRUCTURE.BUILDING", "BUILDING", started, scenario_id, [
		"Game.start_megastructure_phase(stellar_energy, 90) creates the real Construction runtime and sets project.status=BUILDING"
	])

	# Re-load the checkpoint, legally start the phase, remove its physical inputs
	# via the public inventory API, then let Simulation author the blocker.
	activated = _activate_golden_scenario(scenario_id)
	var project: Dictionary = Game.state.megastructure_projects.get("stellar_energy", {}) if activated else {}
	var phase_index := int(project.get("phase_index", -1))
	var definition: Dictionary = Game.content.megastructures.get("stellar_energy", {})
	var phases: Array = definition.get("phases", [])
	var phase: Dictionary = phases[phase_index] as Dictionary if phase_index >= 0 and phase_index < phases.size() else {}
	var activity_id := String(phase.get("activity_id", ""))
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	started = activated and Game.start_megastructure_phase("stellar_energy", 90)
	for cost_value in activity.get("costs", []):
		var item_id := String((cost_value as Dictionary).get("item", ""))
		for location_id_value in Game.state.locations.keys():
			_drain_item_at(item_id, String(location_id_value))
	Game.advance_game_time(5000.0)
	var runtime := _construction_runtime_for_activity_in_test(activity_id)
	project = Game.state.megastructure_projects.get("stellar_energy", {})
	var blocker: Dictionary = runtime.get("blocker", {})
	var waiting_formed := started and String(runtime.get("status", "")) == "BLOCKED" and String(blocker.get("primary_reason", "")) in ["INPUT_SHORTAGE", "INPUT_IN_TRANSIT", "MISSING_CAPITAL_GOOD"]
	await _spawn_main()
	await _press_named("Navigation_megastructure")
	var waiting_corpus := _visible_text(main)
	var cancel := main.find_child("CancelMegastructure_stellar_energy", true, false) as Button
	_record_observation("MEGASTRUCTURE.WAITING_MATERIAL", waiting_formed, _contains_any(waiting_corpus, [_status_text("WAITING_MATERIAL"), "WAITING_MATERIAL"]), not blocker.is_empty() and waiting_corpus.contains(_blocker_text(blocker)), _button_usable(cancel), _scenario_trace(scenario_id, [
		"Game.start_megastructure_phase(stellar_energy, 90)",
		"SpaceGameState.remove_item clears current phase inputs at every known location",
		"Game.advance_game_time(5000 ms) lets Construction/Simulation author the material blocker"
	]), {
		"screen":"megastructure", "activityId":activity_id,
		"projectStatus":String(project.get("status", "")),
		"materialFlowStatus":String(project.get("material_flow_status", "")),
		"runtimeStatus":String(runtime.get("status", "")), "blockerReason":String(blocker.get("primary_reason", ""))
	}, "Domain formed a legal Megastructure material block, but MainScene did not show WAITING_MATERIAL, its blocker explanation and phase action together.")
	await _free_main()

	await _observe_megastructure_phase_checkpoint("MEGASTRUCTURE.INTEGRATION", "megastructure_phase_6", "stellar_grid_integration", "INTEGRATION")
	await _observe_megastructure_phase_checkpoint("MEGASTRUCTURE.COMMISSIONING", "megastructure_phase_7", "stellar_commissioning", "COMMISSIONING")
	await _observe_completed_megastructure_checkpoint()


func _observe_megastructure_runtime(state_id: String, expected_project_status: String, command_ok: bool, scenario_id: String, commands: Array[String]) -> void:
	var project: Dictionary = Game.state.megastructure_projects.get("stellar_energy", {})
	var activity_id := String(project.get("activity_id", ""))
	var formed := command_ok and String(project.get("status", "")) == expected_project_status and not activity_id.is_empty()
	await _spawn_main()
	await _press_named("Navigation_megastructure")
	var corpus := _visible_text(main)
	var cancel := main.find_child("CancelMegastructure_stellar_energy", true, false) as Button
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	_record_observation(state_id, formed, _contains_any(corpus, [_status_text(expected_project_status), expected_project_status]), not activity.is_empty() and corpus.contains(I18n.content(activity, "description")), _button_usable(cancel), _scenario_trace(scenario_id, commands), {
		"screen":"megastructure", "projectStatus":String(project.get("status", "")),
		"activityId":activity_id, "navigationControl":"CancelMegastructure_stellar_energy"
	}, "The legal Megastructure Construction runtime was not visible with its phase explanation and cancellation control.")
	await _free_main()


func _observe_megastructure_phase_checkpoint(state_id: String, scenario_id: String, expected_phase_id: String, visible_state: String) -> void:
	var activated := _activate_golden_scenario(scenario_id)
	var definition: Dictionary = Game.content.megastructures.get("stellar_energy", {})
	var phases: Array = definition.get("phases", [])
	var project: Dictionary = Game.state.megastructure_projects.get("stellar_energy", {}) if activated else {}
	var phase_index := int(project.get("phase_index", -1))
	var phase: Dictionary = phases[phase_index] as Dictionary if phase_index >= 0 and phase_index < phases.size() else {}
	var phase_id := String(phase.get("id", ""))
	var formed := activated and phase_id == expected_phase_id
	await _spawn_main()
	await _press_named("Navigation_megastructure")
	var corpus := _visible_text(main)
	var stage_name := I18n.megastructure_stage("stellar_energy", phase_index, String(phase.get("name", expected_phase_id)))
	var start_button := main.find_child("StartMegastructure_stellar_energy", true, false) as Button
	var navigation := start_button
	if visible_state == "COMMISSIONING" and not _button_usable(navigation):
		# Commissioning can be blocked by a real site requirement. The enabled
		# worksite link is the useful inspection/resolution path; a disabled Start
		# button is not counted as navigation evidence.
		navigation = main.find_child("MegastructureOpenWorksite", true, false) as Button
	var activity_id := String(phase.get("activity_id", ""))
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	_record_observation(state_id, formed, _contains_any(corpus, [_status_text(visible_state), visible_state, stage_name]), corpus.contains(stage_name) and (activity.is_empty() or corpus.contains(I18n.content(activity, "description"))), _button_usable(navigation), _scenario_trace(scenario_id, [
		"read current phase definition from authoritative project.phase_index",
		"verify current phase id equals %s" % expected_phase_id,
		"open live Megastructure page"
	]), {
		"screen":"megastructure", "phaseIndex":phase_index, "phaseId":phase_id,
		"stageName":stage_name, "projectStatus":String(project.get("status", "")),
		"startControlUsable":_button_usable(start_button),
		"navigationControl":String(navigation.name) if navigation != null else ""
	}, "The legal Golden Megastructure phase was not visible with its phase/BOM explanation and a usable phase action or worksite inspection control.")
	await _free_main()


func _observe_completed_megastructure_checkpoint() -> void:
	var scenario_id := "megastructure_phase_8"
	var activated := _activate_golden_scenario(scenario_id)
	var project: Dictionary = Game.state.megastructure_projects.get("stellar_energy", {}) if activated else {}
	var formed := activated and bool(Game.state.megastructures.get("stellar_energy", false)) and Game.state.game_complete and String(project.get("status", "")) == "COMPLETE"
	await _spawn_main()
	await _press_named("Navigation_megastructure")
	var corpus := _visible_text(main)
	var system_map := main.find_child("Navigation_system_map", true, false) as Button
	var ledger_visible := corpus.contains(I18n.content(Game.content.megastructures.get("stellar_energy", {}))) and not (project.get("phase_history", []) as Array).is_empty() and _contains_any(corpus, ["freight units", "materials", "材料", "货运"])
	_record_observation("MEGASTRUCTURE.COMPLETED", formed, _contains_any(corpus, [_status_text("COMPLETED"), "COMPLETED"]), ledger_visible, _button_usable(system_map), _scenario_trace(scenario_id, [
		"read megastructures[stellar_energy], game_complete, project.status and phase_history",
		"open live Megastructure completion ledger"
	]), {
		"screen":"megastructure", "projectStatus":String(project.get("status", "")),
		"gameComplete":Game.state.game_complete, "phaseHistoryCount":project.get("phase_history", []).size(),
		"navigationControl":"Navigation_system_map"
	}, "The completed Golden Megastructure state was not visible with its aggregate completion ledger and System navigation.")
	await _free_main()


func _activate_golden_scenario(scenario_id: String) -> bool:
	var builder = GameplayScenarioBuilderScript.new(Game.content)
	var available: Array[String] = builder.available_scenarios()
	if not available.has(scenario_id):
		return false
	return builder.activate(scenario_id)


func _scenario_trace(scenario_id: String, commands: Array[String] = []) -> Array[String]:
	var result: Array[String] = [
		"scenario provenance: artifacts/ui-scenarios/%s.json" % scenario_id,
		"scenario generated_by=golden_path_test",
		"scenario invariant_source=normal_domain_commands_and_simulation",
		"GameplayScenarioBuilder.activate(%s) migrates/normalizes the recorded authoritative checkpoint; this test does not claim to replay the preceding Golden Journey" % scenario_id
	]
	result.append_array(commands)
	return result


func _open_location_section(location_id: String, section: String) -> bool:
	await _spawn_main()
	if not await _press_named("Navigation_system_map"):
		return false
	var location_button := main.find_child("Location_%s" % location_id, true, false) as Button
	if not _button_usable(location_button):
		return false
	location_button.pressed.emit()
	await _settle_ui()
	if section == "overview":
		return true
	return await _press_named("LocationTab_%s" % section)


func _drain_item_at(item_id: String, location_id: String) -> void:
	var quantity := Game.state.item_quantity(item_id, location_id)
	if quantity > 0:
		Game.state.remove_item(item_id, quantity, location_id)


func _construction_runtime_for_activity_in_test(activity_id: String) -> Dictionary:
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("activity_id", "")) == activity_id and String(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			return runtime
	return {}


func _verify_alert_count_single_source() -> void:
	# Form an authoritative PAUSED blocker through the normal production commands,
	# then verify both player-visible alert summaries project the same collection.
	Game.reset_game()
	Game.state.add_item("mixed_raw_ore", 20, MAIN_LOCATION)
	var started := Game.start_industry_operation(0, "separate_iron_ore")
	Game.advance_game_time(1.0)
	var paused := Game.stop_industry_operation(0)
	Game.advance_game_time(1.0)
	await _spawn_main()
	var header := main.find_child("HeaderStatus", true, false) as Label
	var bottom := main.find_child("AlertsTimelineTasks", true, false) as Label
	var expected_count := Game.active_blockers().size()
	var visible_count := "%s %d" % [I18n.core("header.alerts", "Alerts"), expected_count]
	_check(started and paused and expected_count > 0, "alert consistency scenario forms at least one authoritative blocker through normal commands")
	_check(is_instance_valid(header) and header.text.contains(visible_count), "top status bar shows the authoritative active Alert count")
	_check(is_instance_valid(bottom) and bottom.text.contains(visible_count), "bottom timeline shows the same authoritative active Alert count")
	await _free_main()


func _set_explicit_unverified_reasons() -> void:
	var reasons := {
		"PRODUCTION.POWER_LIMITED":"Requires a legally built high-demand industrial topology; the bounded suite does not reduce capacity or edit runtime constraints.",
		"PRODUCTION.COOLING_LIMITED":"Requires a legally built cooling-constrained industrial topology; the bounded suite does not reduce capacity or edit runtime constraints.",
		"PRODUCTION.LOGISTICS_LIMITED":"Requires developed remote industry and constrained local handling formed through survey, construction and freight commands.",
		"PRODUCTION.BUILDING":"Requires a facility-specific construction target and a UI mapping distinct from Construction.BUILDING.",
		"PRODUCTION.DISABLED":"No public command in the bounded fresh-save path disables a production facility while preserving an inspectable line.",
		"CONSTRUCTION.WAITING_CAPACITY":"Requires multiple concurrent legal projects beyond the founding Construction engineering limit.",
		"RESEARCH.LOCKED":"Not claimed: a visible locked card must be paired with its exact authoritative unmet requirement.",
		"RESEARCH.WAITING_FACILITY":"Requires a legal active program whose later stage loses a facility through Domain behavior; facilities are not directly edited.",
		"RESEARCH.WAITING_KNOWLEDGE":"Requires a multi-stage program reached through prerequisite research and Domain progression.",
		"RESEARCH.WAITING_PROTOTYPE":"Requires legal prototype fabrication progression in a major research program.",
		"RESEARCH.WAITING_FIELD_TEST":"Requires legal expedition and field-test progression in a major research program.",
		"RESEARCH.PAUSED":"Not part of the bounded representative set; no runtime value is assigned directly.",
		"LOGISTICS.ACTIVE":"A connected discovered route and legal transport service were not created in this bounded suite.",
		"LOGISTICS.UNDERUTILIZED":"Requires a connected discovered route with measured dispatch utilization.",
		"LOGISTICS.SATURATED":"Requires legal demand, source inventory, service capacity and an actual saturated dispatch.",
		"LOGISTICS.BLOCKED_SOURCE":"Requires a legal demand policy and dispatch cycle with no eligible source or operating cost.",
		"LOGISTICS.BLOCKED_DESTINATION":"Requires an owned in-transit shipment whose legal destination storage becomes full.",
		"LOGISTICS.NO_TRANSPORT":"Requires a discovered path and policy with no compatible legal service asset.",
		"LOGISTICS.PAUSED":"No public pause-service command was used; raw service status was not edited.",
		"SURVEY.DETECTED":"Starter ship lacks long_range_scan; legal sensor refit requires the Lunar progression chain, so no survey_state is assigned directly.",
		"SURVEY.DEEP_SURVEYED":"Requires a legally researched/built deep-survey hull or module; no ship module or survey_state is assigned directly.",
		"MEGASTRUCTURE.RESEARCH_REQUIRED":"Requires legal late-game program reveal after the Deep System progression chain.",
		"MEGASTRUCTURE.SITE_PREPARATION":"Requires legal completion of research_megastructures plus a deep-surveyed candidate site.",
		"MEGASTRUCTURE.WAITING_MATERIAL":"Requires legal site commitment and a physical phase start after late-game progression.",
		"MEGASTRUCTURE.BUILDING":"Requires legal site commitment and a physical phase start after late-game progression.",
		"MEGASTRUCTURE.INTEGRATION":"Requires completion of all preceding physical megastructure phases.",
		"MEGASTRUCTURE.COMMISSIONING":"Requires completion of all preceding physical megastructure phases.",
		"MEGASTRUCTURE.COMPLETED":"Requires all eight legal phases and final commissioning; no completion flag is assigned directly."
	}
	for state_id_value in reasons.keys():
		var state_id := String(state_id_value)
		if coverage_by_id.has(state_id) and String(coverage_by_id[state_id].get("status", "")) == "UNVERIFIED" and String(coverage_by_id[state_id].get("reason", "")).begins_with("Not exercised"):
			coverage_by_id[state_id]["reason"] = String(reasons[state_id])


func _record_observation(state_id: String, formed: bool, state_visible: bool, explanation_visible: bool, navigation_visible: bool, trace: Array[String], evidence: Dictionary, failure_reason: String) -> void:
	if not coverage_by_id.has(state_id):
		_check(false, "registry contains %s" % state_id)
		return
	var verified := formed and state_visible and explanation_visible and navigation_visible
	var row := coverage_by_id[state_id] as Dictionary
	row["status"] = "VERIFIED" if verified else "UNVERIFIED"
	row["domainStateFormed"] = formed
	row["uiStateVisible"] = state_visible
	row["explanationVisible"] = explanation_visible
	row["navigationControlVisible"] = navigation_visible
	row["formationTrace"] = trace
	row["uiEvidence"] = evidence
	row["reason"] = "Verified through legal Domain formation and live MainScene controls." if verified else failure_reason
	coverage_by_id[state_id] = row
	print(("COVERED: " if verified else "UNVERIFIED: ") + state_id + ("" if verified else " — " + failure_reason))


func _spawn_main() -> void:
	await _free_main()
	main = MainScene.instantiate() as Control
	add_child(main)
	await _settle_ui()


func _free_main() -> void:
	if is_instance_valid(main):
		main.queue_free()
		await get_tree().process_frame
	main = null


func _press_named(control_name: String) -> bool:
	var button := main.find_child(control_name, true, false) as Button if is_instance_valid(main) else null
	if not _button_usable(button):
		return false
	button.pressed.emit()
	await _settle_ui()
	return true


func _settle_ui() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.21, true, false, true).timeout
	await get_tree().process_frame


func _button_usable(button: Button) -> bool:
	return button != null and button.is_visible_in_tree() and not button.disabled


func _find_enabled_button_by_text(needles: Array[String]) -> Button:
	if not is_instance_valid(main):
		return null
	for node_value in main.find_children("*", "Button", true, false):
		var button := node_value as Button
		if not _button_usable(button):
			continue
		if _contains_any(button.text, needles):
			return button
	return null


func _first_enabled_named_prefix(prefix: String) -> Button:
	for node_value in main.find_children("%s*" % prefix, "Button", true, false):
		var button := node_value as Button
		if _button_usable(button):
			return button
	return null


func _first_enabled_button_in_page(page_name: String) -> Button:
	if not is_instance_valid(main):
		return null
	var page := main.find_child(page_name, true, false)
	if page == null:
		return null
	for node_value in page.find_children("*", "Button", true, false):
		var button := node_value as Button
		if _button_usable(button):
			return button
	return null


func _visible_text(root: Node) -> String:
	var parts: Array[String] = []
	_collect_visible_text(root, parts)
	return "\n".join(parts)


func _collect_visible_text(node: Node, parts: Array[String]) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Label:
		parts.append((node as Label).text)
	elif node is RichTextLabel:
		parts.append((node as RichTextLabel).get_parsed_text())
	elif node is Button:
		parts.append((node as Button).text)
	for child in node.get_children():
		_collect_visible_text(child, parts)


func _contains_any(haystack: String, needles: Array[String]) -> bool:
	var normalized := haystack.to_lower()
	for needle_value in needles:
		var needle := String(needle_value).strip_edges().to_lower()
		if not needle.is_empty() and normalized.contains(needle):
			return true
	return false


func _status_text(status: String) -> String:
	var key := "status.%s" % status.to_upper()
	var translated := I18n.core(key, key)
	return translated if translated != key else status.replace("_", " ").capitalize()


func _blocker_text(blocker: Dictionary) -> String:
	if not is_instance_valid(main) or blocker.is_empty():
		return ""
	return String(main.call("_blocker_text", blocker))


func _fund_entries(entries: Array) -> void:
	for entry_value in entries:
		var entry := entry_value as Dictionary
		Game.state.add_item(String(entry.get("item", "")), int(entry.get("quantity", 0)), MAIN_LOCATION)


func _drain_item(item_id: String) -> void:
	var quantity := Game.state.item_quantity(item_id, MAIN_LOCATION)
	if quantity > 0:
		Game.state.remove_item(item_id, quantity, MAIN_LOCATION)


func _last_construction_history(status: String) -> Dictionary:
	for index in range(Game.state.construction_history.size() - 1, -1, -1):
		var row := Game.state.construction_history[index] as Dictionary
		if String(row.get("status", "")) == status:
			return row
	return {}


func _verified_count() -> int:
	return coverage_by_id.values().filter(func(row): return String((row as Dictionary).get("status", "")) == "VERIFIED").size()


func _verified_systems() -> Array[String]:
	var result: Array[String] = []
	for row_value in coverage_by_id.values():
		var row := row_value as Dictionary
		if String(row.get("status", "")) == "VERIFIED" and not result.has(String(row.get("systemId", ""))):
			result.append(String(row.get("systemId", "")))
	result.sort()
	return result


func _write_result() -> void:
	var ordered_results: Array = []
	for definition_value in definitions:
		var state_id := String((definition_value as Dictionary).get("stateId", ""))
		ordered_results.append((coverage_by_id.get(state_id, {}) as Dictionary).duplicate(true))
	var verified := _verified_count()
	var denominator := ordered_results.size()
	var result := {
		"schemaVersion":1,
		"sourceRegistry":REGISTRY_PATH,
		"coverageClaim":"FULL_CORE_STATE_RUNTIME_UI_EVIDENCE" if verified == denominator else "PARTIAL_RUNTIME_UI_EVIDENCE",
		"formationPolicy":"Fresh paths use canonical reset, public Game commands, public SpaceGameState inventory APIs and Game.advance_game_time. Late-game paths may start from GameplayScenarioBuilder checkpoints whose invariant_source is normal_domain_commands_and_simulation, then use the same legal APIs. No direct runtime status/blocker or Control text assignment.",
		"scenarioCheckpointPolicy":"Every checkpoint-based result names its artifacts/ui-scenarios provenance and invariant in formationTrace; loading a checkpoint is legal setup evidence, not a claim that this test replayed the preceding Golden Journey.",
		"numerator":verified,
		"denominator":denominator,
		"coverageRatio":float(verified) / float(maxi(1, denominator)),
		"verifiedSystems":_verified_systems(),
		"results":ordered_results
	}
	var absolute_directory := ProjectSettings.globalize_path("res://artifacts/test-results")
	var make_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	_check(make_error == OK or make_error == ERR_ALREADY_EXISTS, "coverage artifact directory is available")
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	_check(file != null, "coverage artifact opens for writing")
	if file != null:
		file.store_string(JSON.stringify(result, "  "))
		file.close()
	print("UI_STATE_COVERAGE=%d/%d" % [verified, denominator])
	print("UI_STATE_COVERAGE_RESULT=" + JSON.stringify({"numerator":verified, "denominator":denominator, "verifiedSystems":_verified_systems()}))


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append("FAIL: " + message)
		push_error("FAIL: " + message)


func _finish() -> void:
	await _free_main()
	Engine.time_scale = 1.0
	I18n.set_locale("zh_CN")
	if failures.is_empty():
		print("UI Gameplay State runtime coverage passed")
		get_tree().quit(0)
	else:
		for failure in failures:
			print(failure)
		get_tree().quit(1)
