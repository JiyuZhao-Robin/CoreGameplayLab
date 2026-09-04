extends Node

const MainScene := preload("res://src/ui/main.tscn")
const GameplayScenarioBuilderScript := preload("res://tests/gameplay_scenario_builder.gd")
const REGISTRY_PATH := "res://data/player_action_registry.json"
const EVIDENCE_PATH := "res://artifacts/test-results/ui-action-coverage.json"
const UI_PERSISTENCE_EVIDENCE_PATH := "res://artifacts/test-results/ui-persistence-audit.json"
# START_EXTRACTION / STOP_EXTRACTION were retired with the schema-36 factory-
# grid cutover. Extraction is now covered through canonical production-line
# commands below; the removed ship-mining aggregate is intentionally not
# restored as a compatibility test fixture.
const EXPECTED_FOUR_CASE_ACTIONS := [
	"SAVE_GAME",
	"START_CONSTRUCTION",
	"PAUSE_CONSTRUCTION",
	"RESUME_CONSTRUCTION",
	"CHANGE_PROJECT_PRIORITY",
	"CANCEL_CONSTRUCTION",
	"START_RESEARCH",
	"SELECT_RESEARCH_ROUTE",
	"START_SURVEY_MISSION",
	"BUILD_SHIP",
	"REFIT_SHIP_FROM_BLUEPRINT",
	"CANCEL_SHIP_REFIT",
	"ASSIGN_SHIP",
	"START_EXPEDITION",
	"RECALL_EXPEDITION",
	"SELECT_MEGASTRUCTURE_SITE",
	"START_MEGASTRUCTURE_PHASE",
	"CANCEL_MEGASTRUCTURE_PHASE",
	"SET_ROUTE_PAUSED",
	"STOP_RESEARCH",
	"CHANGE_TRANSPORT_MODE",
	"ASSIGN_LOGISTICS_SHIP",
	"CHANGE_ROUTE_PRIORITY",
	"SET_LOGISTICS_POLICY",
	"CLEAR_LOGISTICS_POLICY",
	"SET_FLEET_SUPPLY_PLAN",
	"RESUPPLY_FLEET",
	"START_PRODUCTION",
	"STOP_PRODUCTION",
	"CHANGE_PRODUCTION_METHOD",
	"ADD_PRODUCTION_LINE",
	"CHANGE_PRODUCTION_PRIORITY",
	"SET_PRODUCTION_CONTROL_PINNED",
	"SET_PRODUCTION_CONTROL_OFF",
	"EXPAND_FACTORY",
	"UPGRADE_SCALE_STAGE",
	"ADOPT_INDUSTRIAL_TRANSFORMATION",
	"UPGRADE_LOCATION_CAPACITY",
	"INSTALL_FACILITY_MODULE",
	"INSTALL_MANUFACTURING_MODULE",
	"UNINSTALL_MANUFACTURING_MODULE",
	"REORDER_SHIP_BUILD",
	"CANCEL_SHIP_BUILD",
	"SET_ADVANCED_POWER_PRIORITY",
	"SET_FLEET_DOCTRINE",
	"SET_RETREAT_POLICY",
	"SET_COMBAT_ZONE",
	"START_COMBAT_ACTION"
]

var failures: Array[String] = []
var coverage := {}
var main: Control


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Engine.time_scale = 0.0
	_initialize_coverage()
	await _verify_production_start_stop_actions()
	await _verify_location_production_actions()
	await _verify_add_production_line_action()
	await _verify_factory_expansion_action()
	await _verify_scale_stage_and_transformation_actions()
	await _verify_construction_actions()
	await _verify_research_action()
	await _verify_research_route_action()
	await _verify_survey_action()
	await _verify_location_capacity_action()
	await _verify_facility_module_action()
	await _verify_advanced_power_priority_action()
	await _verify_build_ship_action()
	await _verify_shipyard_queue_actions()
	await _verify_ship_design_refit_and_cancel_actions()
	await _verify_ship_assignment_and_expedition_actions()
	await _verify_fleet_configuration_actions()
	await _verify_fleet_supply_actions()
	await _verify_combat_action()
	await _verify_manufacturing_module_actions()
	await _verify_megastructure_site_selection_action()
	await _verify_megastructure_phase_action()
	await _verify_route_pause_action()
	await _verify_logistics_service_actions()
	await _verify_logistics_policy_actions()
	await _verify_save_unavailable_failure()
	_record_known_surface_gaps()
	await _free_main()
	Engine.time_scale = 1.0

	for action_id in EXPECTED_FOUR_CASE_ACTIONS:
		_check(_four_case_verified(action_id), "%s has Success + Failure + Consequence + Persistence evidence" % action_id)
	_write_evidence()
	_finish()


func _verify_production_start_stop_actions() -> void:
	var scenario_id := "establish_industry"
	_check(_activate_scenario(scenario_id), "%s reactivates for Production start/stop" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_industry"), "Industry is reachable for Production start/stop")
	var production_tab := main.find_child("IndustrySection_production", true, false) as Button
	_check(production_tab != null and production_tab.is_visible_in_tree(), "Production section is visible after opening Industry")
	if production_tab != null and not production_tab.disabled:
		production_tab.pressed.emit()
		await _settle_ui()
	# The industrial network is now the default read-only overview. Preserve the
	# existing command coverage by entering its explicit list/detailed control
	# surface before looking up the stable StartIndustry_/StopIndustry_ buttons.
	var detailed_view := main.find_child("IndustryProductionListView", true, false) as Button
	_check(_button_usable(detailed_view), "Production start/stop keeps the list/detailed command surface reachable")
	if _button_usable(detailed_view):
		detailed_view.pressed.emit()
		await _settle_ui()
	var start_button := _first_enabled_named_prefix("StartIndustry_")
	var activity_id := String(start_button.name).trim_prefix("StartIndustry_") if start_button != null else ""
	var start_result := await _double_submit_with_structured_rejection(start_button, func() -> bool:
		var runtime := _active_industry_for_activity(activity_id)
		return not runtime.is_empty() and String(runtime.get("status", "")) == "RUNNING" \
			and not String(runtime.get("production_device_id", "")).is_empty() \
			and not (runtime.get("input_commitments", {}) as Dictionary).is_empty()
	)
	_record_double_submit_action("START_PRODUCTION", scenario_id, String(start_result.get("controlName", "")), start_result,
		"The selected configured Production Line enters RUNNING with a real device and Domain-owned input commitments.")
	var runtime := _active_industry_for_activity(activity_id)
	var slot := int(runtime.get("slot", -1))
	_record_quadrant("START_PRODUCTION", "persistence", _persisted_production_line(slot, activity_id, "RUNNING", "PINNED", -1), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "slot":slot, "activityId":activity_id, "expectedStatus":"RUNNING"
	})
	await _settle_ui()

	var stop_button := main.find_child("StopIndustry_%s" % activity_id, true, false) as Button
	var stop_result := await _double_submit_with_structured_rejection(stop_button, func() -> bool:
		var stopped := _industry_by_slot(slot)
		return String(stopped.get("status", "")) == "PAUSED" \
			and String(stopped.get("control_mode", "")) == "OFF" \
			and (stopped.get("input_commitments", {}) as Dictionary).is_empty() \
			and is_zero_approx(float(stopped.get("actual_rate", -1.0)))
	)
	_record_double_submit_action("STOP_PRODUCTION", scenario_id, String(stop_result.get("controlName", "")), stop_result,
		"The Domain pauses the Production Line, clears its current commitments and exposes zero actual throughput.")
	_record_quadrant("STOP_PRODUCTION", "persistence", _persisted_production_line(slot, activity_id, "PAUSED", "OFF", -1), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "slot":slot, "activityId":activity_id, "expectedStatus":"PAUSED", "controlMode":"OFF"
	})


func _verify_location_production_actions() -> void:
	var scenario_id := "automate_earth"
	_check(_activate_scenario(scenario_id), "%s activates for Location Production controls" % scenario_id)
	# Scenario setup funds two ordinary cycles but does not configure the line or
	# assign a runtime status. The target Method selection remains a UI action.
	_fund_activity_setup("fabricate_data_core", SpaceGameState.MAIN_BASE_LOCATION_ID, 2)
	await _spawn_main()
	_check(await _open_location_industry(), "Earth Location Industry is reachable")

	# This legal checkpoint contains the pre-existing unconfigured Electronics
	# line. The Coordinator fix exposes it by raw runtime IDLE and gives the real
	# button a stable identity.
	var method_control := "SelectProductionMethod_2_fabricate_data_core"
	var method_button := main.find_child(method_control, true, false) as Button
	var activities_before := _production_line_field_snapshot("activity_id")
	var method_result := await _double_submit_with_structured_rejection(method_button, func() -> bool:
		return not _changed_production_line_field(activities_before, "activity_id", "").is_empty()
	)
	var method_slot := _changed_production_line_field(activities_before, "activity_id", "")
	var method_runtime := _industry_by_slot(int(method_slot)) if method_slot.is_valid_int() else {}
	var method_id := String(method_runtime.get("activity_id", ""))
	_record_double_submit_action("CHANGE_PRODUCTION_METHOD", scenario_id, String(method_result.get("controlName", "")), method_result,
		"A pre-existing stable-ID Production Line adopts a revealed compatible Method, its physical device, and real cycle commitments.")
	var method_consequence := bool(method_result.get("consequence", false)) \
		and not method_id.is_empty() and not String(method_runtime.get("production_device_id", "")).is_empty() \
		and not (method_runtime.get("input_commitments", {}) as Dictionary).is_empty()
	_record_quadrant("CHANGE_PRODUCTION_METHOD", "consequence", method_consequence, {
		"slot":int(method_slot) if method_slot.is_valid_int() else -1, "lineId":method_runtime.get("line_id", ""),
		"methodId":method_id, "productionDeviceId":method_runtime.get("production_device_id", ""),
		"inputCommitments":method_runtime.get("input_commitments", {})
	})
	_record_quadrant("CHANGE_PRODUCTION_METHOD", "persistence", method_slot.is_valid_int() \
		and _persisted_production_line(int(method_slot), method_id, "RUNNING", "PINNED", -1), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "slot":int(method_slot) if method_slot.is_valid_int() else -1, "methodId":method_id,
		"setup":"Golden checkpoint plus inventory funding through SpaceGameState.add_item; no runtime status or line configuration was assigned."
	})

	# Re-open the untouched legal checkpoint so control-mode and priority tests
	# measure their own visible controls independently of Method selection.
	_check(_activate_scenario(scenario_id), "%s reactivates for line control and priority" % scenario_id)
	await _spawn_main()
	await _open_location_industry()
	var run_button := main.find_child("RunProductionLine_0", true, false) as Button
	var pin_notice_before := Game.last_notice
	if _button_usable(run_button):
		run_button.pressed.emit()
	var pin_notice := Game.last_notice
	var pinned := String(_industry_by_slot(0).get("control_mode", "")) == "PINNED" \
		and String(_industry_by_slot(0).get("status", "")) == "RUNNING"
	_record_quadrant("SET_PRODUCTION_CONTROL_PINNED", "success", pinned and pin_notice != pin_notice_before, {
		"scenario":scenario_id, "controlName":"RunProductionLine_0", "successNotice":pin_notice
	})
	_record_quadrant("SET_PRODUCTION_CONTROL_PINNED", "consequence", pinned, {
		"slot":0, "lineId":_industry_by_slot(0).get("line_id", ""), "controlMode":_industry_by_slot(0).get("control_mode", ""), "status":_industry_by_slot(0).get("status", "")
	})
	_record_quadrant("SET_PRODUCTION_CONTROL_PINNED", "persistence", _persisted_production_line(0, String(_industry_by_slot(0).get("activity_id", "")), "RUNNING", "PINNED", -1), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "slot":0, "controlMode":"PINNED"
	})
	await _settle_ui()
	var selected_run := main.find_child("RunProductionLine_0", true, false) as Button
	_record_quadrant("SET_PRODUCTION_CONTROL_PINNED", "failure", selected_run != null and selected_run.is_visible_in_tree() and selected_run.disabled, {
		"scenario":scenario_id, "controlName":"RunProductionLine_0", "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The selected PINNED control is visibly disabled and cannot issue a redundant line-control command."
	})

	var priorities_before := _production_line_field_snapshot("priority")
	var high_text := I18n.core("industry.line.high_priority")
	var high_button := _first_visible_button_by_text(high_text, false)
	var priority_notice_before := Game.last_notice
	if _button_usable(high_button):
		high_button.pressed.emit()
	var priority_notice := Game.last_notice
	var priority_slot := _changed_production_line_field(priorities_before, "priority", "100")
	var priority_changed := priority_slot.is_valid_int() and int(_industry_by_slot(int(priority_slot)).get("priority", -1)) == 100
	_record_quadrant("CHANGE_PRODUCTION_PRIORITY", "success", priority_changed and priority_notice != priority_notice_before, {
		"scenario":scenario_id, "controlText":high_text, "successNotice":priority_notice
	})
	_record_quadrant("CHANGE_PRODUCTION_PRIORITY", "consequence", priority_changed, {
		"slot":int(priority_slot) if priority_slot.is_valid_int() else -1, "authoritativePriority":100
	})
	_record_quadrant("CHANGE_PRODUCTION_PRIORITY", "persistence", priority_slot.is_valid_int() \
		and _persisted_production_line(int(priority_slot), String(_industry_by_slot(int(priority_slot)).get("activity_id", "")), "", "", 100), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "slot":int(priority_slot) if priority_slot.is_valid_int() else -1, "priority":100
	})
	await _settle_ui()
	var selected_high := _first_visible_button_by_text(high_text, true)
	_record_quadrant("CHANGE_PRODUCTION_PRIORITY", "failure", selected_high != null and selected_high.disabled, {
		"scenario":scenario_id, "controlText":high_text, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The selected High Priority choice is visibly disabled and cannot submit a redundant priority change."
	})

	var modes_before := _production_line_field_snapshot("control_mode")
	var off_text := I18n.core("industry.line.turn_off")
	var off_button := _first_visible_button_by_text(off_text, false)
	var off_notice_before := Game.last_notice
	if _button_usable(off_button):
		off_button.pressed.emit()
	var off_notice := Game.last_notice
	var off_slot := _changed_production_line_field(modes_before, "control_mode", "OFF")
	var off_runtime := _industry_by_slot(int(off_slot)) if off_slot.is_valid_int() else {}
	var turned_off := off_slot.is_valid_int() and String(off_runtime.get("status", "")) == "PAUSED" \
		and is_zero_approx(float(off_runtime.get("actual_rate", -1.0)))
	_record_quadrant("SET_PRODUCTION_CONTROL_OFF", "success", turned_off and off_notice != off_notice_before, {
		"scenario":scenario_id, "controlText":off_text, "successNotice":off_notice
	})
	_record_quadrant("SET_PRODUCTION_CONTROL_OFF", "consequence", turned_off, {
		"slot":int(off_slot) if off_slot.is_valid_int() else -1, "controlMode":off_runtime.get("control_mode", ""), "status":off_runtime.get("status", ""), "actualRate":off_runtime.get("actual_rate", -1.0)
	})
	_record_quadrant("SET_PRODUCTION_CONTROL_OFF", "persistence", off_slot.is_valid_int() \
		and _persisted_production_line(int(off_slot), String(off_runtime.get("activity_id", "")), "PAUSED", "OFF", -1), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "slot":int(off_slot) if off_slot.is_valid_int() else -1, "controlMode":"OFF"
	})
	await _settle_ui()
	var selected_off := _first_visible_button_by_text(off_text, true)
	_record_quadrant("SET_PRODUCTION_CONTROL_OFF", "failure", selected_off != null and selected_off.disabled, {
		"scenario":scenario_id, "controlText":off_text, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The selected OFF control remains visible but disabled after the authoritative line is paused."
	})


func _verify_add_production_line_action() -> void:
	var scenario_id := "prototype_complete"
	_check(_activate_scenario(scenario_id), "%s activates for legal Production-Line scale setup" % scenario_id)
	var setup_ok := _raise_factory_to_industrial_complex_setup(SpaceGameState.MAIN_BASE_LOCATION_ID, "makeshift_workshop")
	_check(setup_ok, "normal Construction setup forms an INDUSTRIAL_COMPLEX without assigning scale or status")
	_fund_activity_setup("fabricate_repair_material", SpaceGameState.MAIN_BASE_LOCATION_ID, 4)
	Game.simulation.refresh_location_summaries(Game.state)
	await _spawn_main()
	_check(await _open_location_industry(), "Industrial Complex Production-Line controls are reachable")
	var control_name := "AddProductionLine_makeshift_workshop_fabricate_repair_material"
	var add_button := main.find_child(control_name, true, false) as Button
	var before_line_ids := _production_line_ids(SpaceGameState.MAIN_BASE_LOCATION_ID, "makeshift_workshop")
	var notice_before := Game.last_notice
	if _button_usable(add_button):
		add_button.pressed.emit()
	var notice_after := Game.last_notice
	var after_first_ids := _production_line_ids(SpaceGameState.MAIN_BASE_LOCATION_ID, "makeshift_workshop")
	var first_line_id := _new_string_value(before_line_ids, after_first_ids)
	var first_line := Game.state.production_line_by_id(first_line_id)
	var first_success := not first_line_id.is_empty() and after_first_ids.size() == before_line_ids.size() + 1 \
		and notice_after != notice_before
	_record_quadrant("ADD_PRODUCTION_LINE", "success", first_success, {
		"scenario":scenario_id, "controlName":control_name, "successNotice":notice_after,
		"setup":"Golden checkpoint advanced by normal FACILITY_EXPANSION/SCALE_STAGE_UPGRADE projects to INDUSTRIAL_COMPLEX; no scale/status fields assigned."
	})
	_record_quadrant("ADD_PRODUCTION_LINE", "consequence", first_success \
		and String(first_line.get("activity_id", "")) == "fabricate_repair_material" \
		and not String(first_line.get("line_id", "")).is_empty() \
		and not (first_line.get("input_commitments", {}) as Dictionary).is_empty(), {
		"lineId":first_line_id, "slot":first_line.get("slot", -1), "activityId":first_line.get("activity_id", ""),
		"inputCommitments":first_line.get("input_commitments", {}), "lineCountDelta":after_first_ids.size() - before_line_ids.size()
	})
	_record_quadrant("ADD_PRODUCTION_LINE", "persistence", _persisted_production_line_by_id(first_line_id, "fabricate_repair_material"), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "lineId":first_line_id, "methodId":"fabricate_repair_material"
	})
	await _settle_ui()

	# INDUSTRIAL_COMPLEX permits three lines. Use one more visible valid Add,
	# then prove the now-full Factory exposes disabled named controls and a clear
	# scale-stage explanation rather than hiding the action.
	var second_add := main.find_child(control_name, true, false) as Button
	if _button_usable(second_add):
		second_add.pressed.emit()
	await _settle_ui()
	var full_control := main.find_child(control_name, true, false) as Button
	var full_failure := full_control != null and full_control.is_visible_in_tree() and full_control.disabled \
		and not full_control.tooltip_text.is_empty() \
		and _contains_any(full_control.tooltip_text + "\n" + _visible_text(main), ["capacity", "scale", "full", "产线", "规模", "已满"])
	_record_quadrant("ADD_PRODUCTION_LINE", "failure", full_failure, {
		"scenario":scenario_id, "controlName":control_name, "mode":"VISIBLE_DISABLED_CONTROL",
		"tooltip":full_control.tooltip_text if full_control != null else "",
		"formation":"Two valid visible Add controls filled the two INDUSTRIAL_COMPLEX expansion slots; the full-capacity control remains visible and disabled."
	})


func _verify_factory_expansion_action() -> void:
	var scenario_id := "prototype_complete"
	_check(_activate_scenario(scenario_id), "%s activates for Factory expansion" % scenario_id)
	await _spawn_main()
	_check(await _open_location_industry(), "Location Industry is reachable for Factory expansion")
	var button := main.find_child("ExpandIndustry_makeshift_workshop_1", true, false) as Button
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		return not _newest_facility_expansion("makeshift_workshop").is_empty()
	)
	var project := _newest_facility_expansion("makeshift_workshop")
	var project_id := String(project.get("project_id", ""))
	_record_double_submit_action("EXPAND_FACTORY", scenario_id, String(result.get("controlName", "")), result,
		"A material-backed FACILITY_EXPANSION project enters the shared Construction queue; Factory level itself is not changed early by the UI.")
	var expansion_consequence := bool(result.get("consequence", false)) \
		and String(project.get("project_type", "")) == "FACILITY_EXPANSION" \
		and int(project.get("start_level", -1)) == 1 and int(project.get("target_level", -1)) == 2 \
		and not (project.get("material_plan", {}) as Dictionary).is_empty() \
		and int(Game.state.location_industry(SpaceGameState.MAIN_BASE_LOCATION_ID, "makeshift_workshop").get("level", 0)) == 1
	_record_quadrant("EXPAND_FACTORY", "consequence", expansion_consequence, {
		"projectId":project_id, "projectType":project.get("project_type", ""), "startLevel":project.get("start_level", -1),
		"targetLevel":project.get("target_level", -1), "materialPlan":project.get("material_plan", {}),
		"factoryLevelBeforeCompletion":Game.state.location_industry(SpaceGameState.MAIN_BASE_LOCATION_ID, "makeshift_workshop").get("level", 0)
	})
	_record_quadrant("EXPAND_FACTORY", "persistence", _persisted_facility_expansion(project_id, "makeshift_workshop", 2), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id, "facilityId":"makeshift_workshop", "targetLevel":2
	})


func _verify_scale_stage_and_transformation_actions() -> void:
	var scale_scenario := "prototype_complete"
	var location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
	var facility_id := "makeshift_workshop"
	_check(_activate_scenario(scale_scenario), "%s activates for Scale Stage setup" % scale_scenario)
	_check(_raise_factory_to_current_stage_cap_setup(location_id, facility_id),
		"normal Facility Expansion setup reaches the current Scale Stage cap without running the target command")
	await _spawn_main()
	_check(await _open_location_industry(), "Location Industry is reachable for Scale Stage transition")
	var scale_button := _first_enabled_named_prefix("UpgradeScaleStage_%s_%s_" % [location_id, facility_id])
	var scale_result := await _double_submit_with_structured_rejection(scale_button, func() -> bool:
		return not _newest_construction_type("SCALE_STAGE_UPGRADE").is_empty()
	)
	var scale_project := _newest_construction_type("SCALE_STAGE_UPGRADE")
	var scale_project_id := String(scale_project.get("project_id", ""))
	_record_double_submit_action("UPGRADE_SCALE_STAGE", scale_scenario, String(scale_result.get("controlName", "")), scale_result,
		"The Stage-cap control queues one material-backed SCALE_STAGE_UPGRADE in shared Construction; the current Factory scale remains authoritative until completion.")
	_record_quadrant("UPGRADE_SCALE_STAGE", "consequence", bool(scale_result.get("consequence", false)) \
		and String(scale_project.get("target_id", "")) == facility_id \
		and not String(scale_project.get("project_definition", {}).get("target_scale_stage", "")).is_empty() \
		and not (scale_project.get("material_plan", {}) as Dictionary).is_empty(), {
		"projectId":scale_project_id, "facilityId":facility_id,
		"targetScaleStage":scale_project.get("project_definition", {}).get("target_scale_stage", ""),
		"materialPlan":scale_project.get("material_plan", {})
	})
	_record_quadrant("UPGRADE_SCALE_STAGE", "persistence", _persisted_dynamic_construction(scale_project_id, "SCALE_STAGE_UPGRADE", facility_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":scale_project_id, "facilityId":facility_id
	})

	var transformation_scenario := "open_deep"
	_check(_activate_scenario(transformation_scenario), "%s activates with mastered Industrial Transformations" % transformation_scenario)
	await _spawn_main()
	_check(await _open_location_industry(), "Location Industry is reachable for Industrial Transformation")
	var transformation_button := _first_enabled_named_prefix("AdoptIndustrialTransformation_")
	var transformation_id := String(transformation_button.name).trim_prefix("AdoptIndustrialTransformation_") if transformation_button != null else ""
	var transformation_result := await _double_submit_with_structured_rejection(transformation_button, func() -> bool:
		var runtime := _newest_construction_type("INDUSTRIAL_TRANSFORMATION")
		return String(runtime.get("target_id", "")) == transformation_id
	)
	var transformation_project := _newest_construction_type("INDUSTRIAL_TRANSFORMATION")
	var transformation_project_id := String(transformation_project.get("project_id", ""))
	_record_double_submit_action("ADOPT_INDUSTRIAL_TRANSFORMATION", transformation_scenario, String(transformation_result.get("controlName", "")), transformation_result,
		"The mastered system policy enters shared Construction as one material-backed Industrial Transformation instead of directly multiplying Factory output.")
	_record_quadrant("ADOPT_INDUSTRIAL_TRANSFORMATION", "consequence", bool(transformation_result.get("consequence", false)) \
		and not (transformation_project.get("material_plan", {}) as Dictionary).is_empty() \
		and not bool(Game.state.adopted_industrial_transformations.get(transformation_id, false)), {
		"projectId":transformation_project_id, "transformationId":transformation_id,
		"materialPlan":transformation_project.get("material_plan", {}), "adoptedBeforeCompletion":false
	})
	_record_quadrant("ADOPT_INDUSTRIAL_TRANSFORMATION", "persistence", _persisted_dynamic_construction(transformation_project_id, "INDUSTRIAL_TRANSFORMATION", transformation_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":transformation_project_id, "transformationId":transformation_id
	})


func _verify_construction_actions() -> void:
	var scenario_id := ""
	var start_button: Button
	for candidate_id in ["automate_earth", "reach_lunar", "reach_asteroid", "prototype_complete", "open_jovian", "open_outer", "open_deep", "prepare_stellar_energy"]:
		if not _activate_scenario(candidate_id):
			continue
		await _spawn_main()
		if not await _press_named("Navigation_industry"):
			continue
		if not await _press_named("IndustrySection_construction"):
			continue
		start_button = _first_enabled_named_prefix("StartConstruction_")
		if _button_usable(start_button):
			scenario_id = candidate_id
			break
	_check(not scenario_id.is_empty(), "a legal Golden checkpoint exposes an enabled construction action")
	if not _button_usable(start_button):
		return
	var start_control := String(start_button.name)
	var active_before := _active_construction_count()
	start_button.pressed.emit()
	var project := _newest_active_construction()
	var project_id := String(project.get("project_id", ""))
	var start_success := not project_id.is_empty() and _active_construction_count() == active_before + 1
	_record_quadrant("START_CONSTRUCTION", "success", start_success, {
		"scenario":scenario_id, "controlName":start_control,
		"evidence":"Visible MainScene control submitted one material-backed project into the unified queue."
	})
	_record_quadrant("START_CONSTRUCTION", "consequence", start_success and not String(project.get("activity_id", "")).is_empty() and not (project.get("material_plan", {}) as Dictionary).is_empty(), {
		"projectId":project_id, "activityId":project.get("activity_id", ""),
		"materialPlan":project.get("material_plan", {}), "queueDelta":_active_construction_count() - active_before
	})
	_record_quadrant("START_CONSTRUCTION", "persistence", _persisted_construction_matches(project_id, String(project.get("activity_id", "")), ""), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY",
		"claim":"SpaceGameState.to_dictionary -> from_dictionary retains the UI-created project; this is not a UI Save/Load claim."
	})
	await _settle_ui()

	var pause_button := main.find_child("PauseConstruction_%s" % project_id, true, false) as Button
	var pause_result := await _double_submit_with_structured_rejection(pause_button, func() -> bool:
		return String(_construction_by_id(project_id).get("status", "")) == "PAUSED"
	)
	_record_double_submit_action("PAUSE_CONSTRUCTION", scenario_id, String(pause_result.get("controlName", "")), pause_result,
		"The live project status becomes PAUSED while ownership and committed materials remain authoritative.")
	_record_quadrant("PAUSE_CONSTRUCTION", "persistence", _persisted_construction_matches(project_id, "", "PAUSED"), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id, "expectedStatus":"PAUSED"
	})
	await _settle_ui()

	var resume_button := main.find_child("ResumeConstruction_%s" % project_id, true, false) as Button
	var resume_result := await _double_submit_with_structured_rejection(resume_button, func() -> bool:
		return String(_construction_by_id(project_id).get("status", "")) in ["QUEUED", "RUNNING", "BLOCKED"]
	)
	_record_double_submit_action("RESUME_CONSTRUCTION", scenario_id, String(resume_result.get("controlName", "")), resume_result,
		"The paused project re-enters normal shared-capacity queue normalization without recreation.")
	_record_quadrant("RESUME_CONSTRUCTION", "persistence", _persisted_construction_matches(project_id, "", "ACTIVE"), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id,
		"expectedStatus":"QUEUED/RUNNING/BLOCKED"
	})
	await _settle_ui()

	var live_project := _construction_by_id(project_id)
	var old_priority := int(live_project.get("priority", 50))
	var new_priority := 100 if old_priority != 100 else 10
	var priority_name := "ConstructionPriority_%s_%d" % [project_id, new_priority]
	var priority_button := main.find_child(priority_name, true, false) as Button
	_check(_button_usable(priority_button), "a different construction priority is an enabled visible control")
	if _button_usable(priority_button):
		priority_button.pressed.emit()
	var priority_changed := int(_construction_by_id(project_id).get("priority", -1)) == new_priority
	_record_quadrant("CHANGE_PROJECT_PRIORITY", "success", priority_changed, {
		"scenario":scenario_id, "controlName":priority_name, "from":old_priority, "to":new_priority
	})
	_record_quadrant("CHANGE_PROJECT_PRIORITY", "consequence", priority_changed, {
		"projectId":project_id, "authoritativePriority":_construction_by_id(project_id).get("priority", -1)
	})
	_record_quadrant("CHANGE_PROJECT_PRIORITY", "persistence", _persisted_construction_priority(project_id, new_priority), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id, "priority":new_priority
	})
	await _settle_ui()
	var selected_priority := main.find_child(priority_name, true, false) as Button
	var selected_priority_disabled := selected_priority != null and selected_priority.is_visible_in_tree() and selected_priority.disabled
	_record_quadrant("CHANGE_PROJECT_PRIORITY", "failure", selected_priority_disabled, {
		"scenario":scenario_id, "controlName":priority_name, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The currently selected priority is visibly disabled and cannot submit a redundant command."
	})

	var cancel_button := main.find_child("CancelConstruction_%s" % project_id, true, false) as Button
	var history_before := Game.state.construction_history.size()
	var cancel_result := await _double_submit_with_structured_rejection(cancel_button, func() -> bool:
		return _construction_by_id(project_id).is_empty() and Game.state.construction_history.size() == history_before + 1
	)
	_record_double_submit_action("CANCEL_CONSTRUCTION", scenario_id, String(cancel_result.get("controlName", "")), cancel_result,
		"Domain cancellation removes the queue entry once and appends one authoritative cancellation ledger record.")
	_record_quadrant("CANCEL_CONSTRUCTION", "persistence", _persisted_cancel_history(project_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id,
		"claim":"Cancellation ledger survives state serialization; refund/loss fields are not recomputed by UI."
	})
	await _settle_ui()

	# Form a legal full queue exclusively through repeated visible Start controls.
	# The resulting disabled Start control is the player-facing failure surface.
	var fill_clicks := 0
	while fill_clicks < 12:
		var enabled_start := _first_enabled_named_prefix("StartConstruction_")
		if not _button_usable(enabled_start):
			break
		enabled_start.pressed.emit()
		fill_clicks += 1
		await _settle_ui()
	var disabled_start := _first_disabled_visible_named_prefix("StartConstruction_")
	var failure_corpus := _visible_text(main)
	var start_failure := disabled_start != null and _contains_any(failure_corpus, [
		"construction", "project", "queue", "unavailable", "建设", "项目", "队列", "不可用"
	])
	_record_quadrant("START_CONSTRUCTION", "failure", start_failure, {
		"scenario":scenario_id, "controlName":String(disabled_start.name) if disabled_start != null else "",
		"mode":"VISIBLE_DISABLED_CONTROL", "visibleExplanation":start_failure,
		"formation":"The queue was filled only by visible StartConstruction controls at paused player speed.",
		"fillClicks":fill_clicks, "queueSize":_active_construction_count()
	})


func _verify_research_action() -> void:
	var scenario_id := "establish_industry"
	_check(_activate_scenario(scenario_id), "%s reactivates for START_RESEARCH" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_research"), "Research is reachable through visible navigation")
	var button := main.find_child("StartResearch_research_industrial_coordination", true, false) as Button
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_industrial_coordination"
	)
	_record_double_submit_action("START_RESEARCH", scenario_id, String(result.get("controlName", "")), result,
		"The staged industrial-coordination program becomes the authoritative active R&D runtime.")
	_record_quadrant("START_RESEARCH", "persistence", _persisted_research_matches("research_industrial_coordination", ""), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":"research_industrial_coordination"
	})
	await _settle_ui()
	var pause_button := main.find_child("PauseResearch_research_industrial_coordination", true, false) as Button
	var pause_result := await _double_submit_with_structured_rejection(pause_button, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_industrial_coordination" \
			and String(Game.state.research.get("status", "")) == "PAUSED"
	)
	_record_double_submit_action("STOP_RESEARCH", scenario_id, String(pause_result.get("controlName", "")), pause_result,
		"The committed R&D Program remains owned with its project identity and consumed inputs, but enters PAUSED.")
	_record_quadrant("STOP_RESEARCH", "persistence", _persisted_research_status("research_industrial_coordination", "PAUSED"), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":"research_industrial_coordination", "expectedStatus":"PAUSED"
	})


func _verify_research_route_action() -> void:
	var scenario_id := "reach_lunar"
	_check(_activate_scenario(scenario_id), "%s activates for route selection" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_research"), "Research route surface is reachable through visible navigation")
	var button := _first_enabled_named_prefix("StartResearch_research_advanced_propulsion_")
	var route_id := String(button.name).trim_prefix("StartResearch_research_advanced_propulsion_") if button != null else ""
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_advanced_propulsion" \
			and String(Game.state.research.get("route_id", "")) == route_id
	)
	_record_double_submit_action("SELECT_RESEARCH_ROUTE", scenario_id, String(result.get("controlName", "")), result,
		"The selected engineering route is stored on the authoritative staged R&D runtime.")
	_record_quadrant("SELECT_RESEARCH_ROUTE", "persistence", _persisted_research_matches("research_advanced_propulsion", route_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":"research_advanced_propulsion", "routeId":route_id
	})


func _verify_survey_action() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for Deep Survey" % scenario_id)
	await _spawn_main()
	var survey_button: Button
	var target_id := ""
	for candidate_id in ["deep_system", "outer_system", "gas_giant_region", "asteroid_belt", "lunar_space"]:
		if not await _press_named("Navigation_system_map"):
			continue
		var location_button := main.find_child("Location_%s" % candidate_id, true, false) as Button
		if not _button_usable(location_button):
			continue
		location_button.pressed.emit()
		await _settle_ui()
		survey_button = _first_enabled_named_prefix("StartSurvey_%s_" % candidate_id)
		if _button_usable(survey_button):
			target_id = candidate_id
			break
	var requested_state := ""
	if survey_button != null:
		var name_parts := String(survey_button.name).split("_")
		requested_state = "DEEP_SURVEYED" if String(survey_button.name).contains("_DEEP_SURVEYED_") else String(name_parts[name_parts.size() - 2])
	var result := await _double_submit_with_structured_rejection(survey_button, func() -> bool:
		return String(Game.state.survey_mission.get("status", "")) == "RUNNING" \
			and String(Game.state.survey_mission.get("target", "")) == target_id \
			and String(Game.state.survey_mission.get("target_state", "")) == requested_state
	)
	_record_double_submit_action("START_SURVEY_MISSION", scenario_id, String(result.get("controlName", "")), result,
		"A physical capable vessel is exclusively assigned to the next legal Survey State mission.")
	_record_quadrant("START_SURVEY_MISSION", "persistence", _persisted_survey_matches(target_id, requested_state), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "target":target_id, "targetState":requested_state
	})


func _verify_site_development_action() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for a Surveyed undeveloped site" % scenario_id)
	await _spawn_main()
	var develop_button: Button
	var location_id := ""
	for candidate_id in ["deep_system", "outer_system", "gas_giant_region", "lunar_space", "asteroid_belt"]:
		if not await _press_named("Navigation_system_map"):
			continue
		var location_button := main.find_child("Location_%s" % candidate_id, true, false) as Button
		if not _button_usable(location_button):
			continue
		location_button.pressed.emit()
		await _settle_ui()
		if not await _press_named("LocationTab_resources"):
			continue
		develop_button = _first_enabled_named_prefix("DevelopSite_")
		if _button_usable(develop_button):
			location_id = candidate_id
			break
	var control_name := String(develop_button.name) if develop_button != null else ""
	var result := await _double_submit_with_structured_rejection(develop_button, func() -> bool:
		return not _newest_construction_type("SITE_DEVELOPMENT").is_empty()
	)
	var project := _newest_construction_type("SITE_DEVELOPMENT")
	var project_id := String(project.get("project_id", ""))
	_record_double_submit_action("DEVELOP_SITE", scenario_id, String(result.get("controlName", "")), result,
		"The selected permanent Extraction Method creates one SITE_DEVELOPMENT project in shared Construction with a real BOM.")
	_record_quadrant("DEVELOP_SITE", "consequence", bool(result.get("consequence", false)) \
		and not String(project.get("target_id", "")).is_empty() \
		and not String(project.get("project_definition", {}).get("extraction_method_id", "")).is_empty() \
		and not (project.get("material_plan", {}) as Dictionary).is_empty(), {
		"locationId":location_id, "controlName":control_name, "projectId":project_id,
		"siteId":project.get("target_id", ""), "extractionMethodId":project.get("project_definition", {}).get("extraction_method_id", ""),
		"materialPlan":project.get("material_plan", {})
	})
	_record_quadrant("DEVELOP_SITE", "persistence", _persisted_dynamic_construction(project_id, "SITE_DEVELOPMENT", String(project.get("target_id", ""))), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id, "projectType":"SITE_DEVELOPMENT"
	})


func _verify_location_capacity_action() -> void:
	var scenario_id := "prototype_complete"
	_check(_activate_scenario(scenario_id), "%s activates for Location capacity projects" % scenario_id)
	await _spawn_main()
	_check(await _open_location_industry(), "Location Industry capacity projects are reachable")
	var current_power := int(Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("industry", {}).get("power_capacity", 0))
	var increment := int(Game.content.industry_rules.get("capacity_upgrade_projects", {}).get("POWER_UPGRADE", {}).get("increment", 1))
	var capacity_text := I18n.core("industry.capacity.target") % [I18n.core("industry.capacity.power"), current_power + increment]
	var button := _first_visible_button_by_text(capacity_text, false)
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		return not _newest_capacity_construction().is_empty()
	)
	var project := _newest_capacity_construction()
	var project_id := String(project.get("project_id", ""))
	var project_type := String(project.get("project_type", ""))
	_record_double_submit_action("UPGRADE_LOCATION_CAPACITY", scenario_id, String(result.get("controlName", "")), result,
		"A visible capacity choice creates one material-backed shared Construction project; capacity remains unchanged until completion.")
	_record_quadrant("UPGRADE_LOCATION_CAPACITY", "consequence", bool(result.get("consequence", false)) \
		and project_type in _capacity_project_types() \
		and int(project.get("target_level", -1)) > int(project.get("start_level", -1)) \
		and not (project.get("material_plan", {}) as Dictionary).is_empty(), {
		"projectId":project_id, "projectType":project_type, "startValue":project.get("start_level", -1),
		"targetValue":project.get("target_level", -1), "materialPlan":project.get("material_plan", {})
	})
	_record_quadrant("UPGRADE_LOCATION_CAPACITY", "persistence", _persisted_dynamic_construction(project_id, project_type, String(project.get("target_id", ""))), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id, "projectType":project_type
	})


func _verify_facility_module_action() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for Infrastructure Facility modules" % scenario_id)
	_fund_available_facility_module_setup()
	await _spawn_main()
	_check(await _press_named("Navigation_industry"), "Industry is reachable for Infrastructure Facility modules")
	_check(await _press_named("IndustrySection_facilities"), "Facilities section is reachable for Infrastructure Facility modules")
	var button := _first_enabled_named_prefix("InstallFacilityModule_")
	var target := _facility_module_target(String(button.name) if button != null else "")
	var facility_id := String(target.get("facilityId", ""))
	var module_id := String(target.get("moduleId", ""))
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		var runtime := _newest_construction_type("FACILITY_MODULE_INSTALL")
		return String(runtime.get("target_id", "")) == facility_id \
			and String(runtime.get("project_definition", {}).get("module_id", "")) == module_id
	)
	var project := _newest_construction_type("FACILITY_MODULE_INSTALL")
	var project_id := String(project.get("project_id", ""))
	_record_double_submit_action("INSTALL_FACILITY_MODULE", scenario_id, String(result.get("controlName", "")), result,
		"The named infrastructure-module control queues one physical, material-backed shared Construction project and does not install the module before completion.")
	_record_quadrant("INSTALL_FACILITY_MODULE", "consequence", bool(result.get("consequence", false)) \
		and not (project.get("material_plan", {}) as Dictionary).is_empty() \
		and not (Game.state.facilities.get(facility_id, {}) as Dictionary).get("installed_modules", []).has(module_id), {
		"projectId":project_id, "facilityId":facility_id, "moduleId":module_id,
		"materialPlan":project.get("material_plan", {}), "installedBeforeCompletion":false
	})
	_record_quadrant("INSTALL_FACILITY_MODULE", "persistence", _persisted_dynamic_construction(project_id, "FACILITY_MODULE_INSTALL", facility_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id, "facilityId":facility_id, "moduleId":module_id
	})


func _verify_advanced_power_priority_action() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for Advanced Power policy" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_industry"), "Industry is reachable for Advanced Power policy")
	_check(await _press_named("IndustrySection_facilities"), "Facilities are reachable for Advanced Power policy")
	var button := _first_enabled_named_prefix("AdvancedPowerPriority_")
	var target := _advanced_power_target(String(button.name) if button != null else "")
	var facility_id := String(target.get("facilityId", ""))
	var priority := String(target.get("priority", ""))
	var previous := String(Game.state.energy_system.get("advanced_priorities", {}).get(facility_id, ""))
	if _button_usable(button):
		button.pressed.emit()
	var changed := not facility_id.is_empty() and priority != previous \
		and String(Game.state.energy_system.get("advanced_priorities", {}).get(facility_id, "")) == priority
	_record_quadrant("SET_ADVANCED_POWER_PRIORITY", "success", changed, {
		"scenario":scenario_id, "controlName":String(button.name) if button != null else "", "previous":previous, "selected":priority
	})
	_record_quadrant("SET_ADVANCED_POWER_PRIORITY", "consequence", changed, {
		"facilityId":facility_id, "authoritativePriority":Game.state.energy_system.get("advanced_priorities", {}).get(facility_id, "")
	})
	_record_quadrant("SET_ADVANCED_POWER_PRIORITY", "persistence", _persisted_advanced_power_priority(facility_id, priority), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "facilityId":facility_id, "priority":priority
	})
	await _settle_ui()
	var selected_button := main.find_child("AdvancedPowerPriority_%s_%s" % [facility_id, priority], true, false) as Button
	_record_quadrant("SET_ADVANCED_POWER_PRIORITY", "failure", selected_button != null and selected_button.is_visible_in_tree() and selected_button.disabled, {
		"scenario":scenario_id, "controlName":String(selected_button.name) if selected_button != null else "", "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The authoritative selected Power Priority remains visible but disabled."
	})


func _verify_build_ship_action() -> void:
	var success_scenario := "prepare_stellar_energy"
	_check(_activate_scenario(success_scenario), "%s activates for BUILD_SHIP success" % success_scenario)
	var prepared_designs := _create_saved_ship_designs(1)
	_check(prepared_designs.size() == 1, "a valid player ship design is prepared through the public design command")
	var design_id := prepared_designs[0] if not prepared_designs.is_empty() else ""
	var plan_id := String(Game.state.ship_designs.get(design_id, {}).get("plan_id", ""))
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for BUILD_SHIP")
	_check(await _press_named("FleetSection_shipyard"), "Shipyard is reachable through its visible tab")
	var build_button := main.find_child("BuildShipDesign_%s_1" % design_id, true, false) as Button
	_check(_button_usable(build_button), "a saved valid ship design has an enabled Build control")
	var control_name := String(build_button.name) if build_button != null else ""
	var queue_before := Game.state.shipyard_queue.size()
	if _button_usable(build_button):
		build_button.pressed.emit()
	var order := _newest_shipyard_order(plan_id)
	var project_id := String(order.get("project_id", ""))
	var built := not project_id.is_empty() and Game.state.shipyard_queue.size() == queue_before + 1
	_record_quadrant("BUILD_SHIP", "success", built, {
		"scenario":success_scenario, "controlName":control_name,
		"evidence":"A saved player-authored design's visible one-ship batch control is accepted."
	})
	_record_quadrant("BUILD_SHIP", "consequence", built and int(order.get("quantity_total", 0)) == 1 and String(order.get("plan_id", "")) == plan_id, {
		"projectId":project_id, "planId":plan_id, "quantity":order.get("quantity_total", 0),
		"queueDelta":Game.state.shipyard_queue.size() - queue_before
	})
	_record_quadrant("BUILD_SHIP", "persistence", _persisted_shipyard_order(project_id, plan_id, 1), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":project_id, "planId":plan_id,
		"claim":"The UI-created physical Shipyard order survives Domain round-trip; this is not UI Save/Load."
	})

	var failure_scenario := "establish_industry"
	_check(_activate_scenario(failure_scenario), "%s activates for locked BUILD_SHIP failure" % failure_scenario)
	await _spawn_main()
	await _press_named("Navigation_ships")
	await _press_named("FleetSection_shipyard")
	var locked_build := main.find_child("ShipPaletteHull_construct_ultimate_combat", true, false) as Button
	var locked_corpus := _visible_text(main)
	var locked_failure := locked_build == null \
		and _contains_any(locked_corpus, ["no saved design", "blank assembly canvas", "尚无已保存设计", "空白装配画布"])
	_record_quadrant("BUILD_SHIP", "failure", locked_failure, {
		"scenario":failure_scenario, "controlName":"ShipPaletteHull_construct_ultimate_combat",
		"mode":"UNAVAILABLE_CONTENT_OMITTED",
		"evidence":"The Ship palette contains only unlocked, constructible hull models; unavailable hulls and build controls are absent until their real unlock and a valid saved design exist."
	})


func _verify_shipyard_queue_actions() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for Shipyard queue controls" % scenario_id)
	var design_ids := _create_saved_ship_designs(2)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for Shipyard queue controls")
	_check(await _press_named("FleetSection_shipyard"), "Shipyard queue is reachable")
	var setup_plans: Array[String] = []
	for design_id in design_ids:
		var button := main.find_child("BuildShipDesign_%s_1" % design_id, true, false) as Button
		if not _button_usable(button):
			continue
		button.pressed.emit()
		setup_plans.append(String(Game.state.ship_designs.get(design_id, {}).get("plan_id", "")))
		await _settle_ui()
	_check(setup_plans.size() == 2 and Game.state.shipyard_queue.size() >= 2,
		"two distinct saved-design Build controls form a legal reorderable Shipyard queue")
	var reorder_order := Game.state.shipyard_queue[1] as Dictionary if Game.state.shipyard_queue.size() >= 2 else {}
	var reorder_project_id := String(reorder_order.get("project_id", ""))
	var reorder_plan_id := String(reorder_order.get("plan_id", ""))
	var move_control := "ReorderShipBuildUp_%s" % reorder_project_id
	var move_button := main.find_child(move_control, true, false) as Button
	var notice_before := Game.last_notice
	if _button_usable(move_button):
		move_button.pressed.emit()
	var reordered := not reorder_plan_id.is_empty() and String((Game.state.shipyard_queue[0] as Dictionary).get("plan_id", "")) == reorder_plan_id
	_record_quadrant("REORDER_SHIP_BUILD", "success", reordered and Game.last_notice != notice_before, {
		"scenario":scenario_id, "controlName":move_control, "planId":reorder_plan_id, "successNotice":Game.last_notice
	})
	_record_quadrant("REORDER_SHIP_BUILD", "consequence", reordered, {
		"projectId":reorder_project_id, "planId":reorder_plan_id, "authoritativeQueueIndex":0,
		"queuePlanIds":_shipyard_plan_ids(Game.state)
	})
	_record_quadrant("REORDER_SHIP_BUILD", "persistence", _persisted_shipyard_order_index(reorder_project_id, 0), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":reorder_project_id, "expectedIndex":0
	})
	await _settle_ui()
	var selected_up := main.find_child(move_control, true, false) as Button
	_record_quadrant("REORDER_SHIP_BUILD", "failure", selected_up != null and selected_up.is_visible_in_tree() and selected_up.disabled, {
		"scenario":scenario_id, "controlName":move_control, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The now-first order retains a named Move Up control that is visibly disabled at the queue boundary."
	})

	var cancel_order := Game.state.shipyard_queue[Game.state.shipyard_queue.size() - 1] as Dictionary if not Game.state.shipyard_queue.is_empty() else {}
	var cancel_project_id := String(cancel_order.get("project_id", ""))
	var cancel_plan_id := String(cancel_order.get("plan_id", ""))
	var queue_before := Game.state.shipyard_queue.size()
	var cancel_control := "CancelShipBuild_%s" % cancel_project_id
	var cancel_button := main.find_child(cancel_control, true, false) as Button
	var cancel_result := await _double_submit_with_structured_rejection(cancel_button, func() -> bool:
		return not _shipyard_has_project(Game.state, cancel_project_id) and Game.state.shipyard_queue.size() == queue_before - 1
	)
	_record_double_submit_action("CANCEL_SHIP_BUILD", scenario_id, String(cancel_result.get("controlName", "")), cancel_result,
		"The named order control removes exactly one persistent Shipyard project and the Domain retains its committed-material loss rule; a stale duplicate is rejected.")
	_record_quadrant("CANCEL_SHIP_BUILD", "persistence", _persisted_shipyard_project_absent(cancel_project_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "projectId":cancel_project_id, "planId":cancel_plan_id,
		"consumedLost":cancel_order.get("consumed", {})
	})


func _verify_ship_design_refit_and_cancel_actions() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for saved-design Ship refit" % scenario_id)
	var design_ids := _create_saved_ship_designs(1)
	var design_id := design_ids[0] if not design_ids.is_empty() else ""
	var candidates := Game.ship_design_refit_candidates(design_id) if not design_id.is_empty() else []
	var ship_id := String(candidates[0]) if not candidates.is_empty() else ""
	var design := Game.state.ship_designs.get(design_id, {}) as Dictionary
	var desired_modules: Array = design.get("modules", []).duplicate()
	var original_modules := Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)) if not ship_id.is_empty() else []
	var funded_bom := _fund_ship_refit_setup(ship_id, desired_modules)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for saved-design refit")
	_check(await _press_named("FleetSection_shipyard"), "Shipyard exposes the canonical saved-design refit entry point")
	var refit_control := "RefitShipDesign_%s_%s" % [design_id, ship_id]
	var refit_button := main.find_child(refit_control, true, false) as Button
	var refit_result := await _double_submit_with_structured_rejection(refit_button, func() -> bool:
		return _active_refit_matches(ship_id, desired_modules)
	)
	var refit := _active_refit_for_ship(ship_id)
	var refit_id := String(refit.get("project_id", ""))
	_record_double_submit_action("REFIT_SHIP_FROM_BLUEPRINT", scenario_id, String(refit_result.get("controlName", "")), refit_result,
		"The visible saved-design action creates one canonical full-loadout refit and exclusively assigns the real physical ship to it.")
	_record_quadrant("REFIT_SHIP_FROM_BLUEPRINT", "consequence", bool(refit_result.get("consequence", false)) \
		and (refit.get("consumed_bom", {}) as Dictionary) == funded_bom, {
		"shipId":ship_id, "designId":design_id, "projectId":refit_id,
		"desiredDefinitions":desired_modules, "consumedBom":refit.get("consumed_bom", {})
	})
	_record_quadrant("REFIT_SHIP_FROM_BLUEPRINT", "persistence", _persisted_refit_matches(refit_id, ship_id, desired_modules), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "designId":design_id, "projectId":refit_id
	})

	_check(await _press_named("FleetSection_archive"), "Maintenance Archive exposes the active refit cancellation")
	var cancel_control := "CancelShipRefit_%s" % refit_id
	var cancel_button := main.find_child(cancel_control, true, false) as Button
	var stock_after_refit := _inventory_snapshot(funded_bom.keys(), String(Game.state.ship_by_id(ship_id).get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)))
	var cancel_result := await _double_submit_with_structured_rejection(cancel_button, func() -> bool:
		return _refit_cancelled_to_original(ship_id, refit_id, original_modules)
	)
	_record_double_submit_action("CANCEL_SHIP_REFIT", scenario_id, String(cancel_result.get("controlName", "")), cancel_result,
		"Cancellation removes exactly the active refit, restores the physical ship and keeps committed fabrication materials consumed.")
	_record_quadrant("CANCEL_SHIP_REFIT", "consequence", bool(cancel_result.get("consequence", false)) \
		and _inventory_snapshot_matches(stock_after_refit, String(Game.state.ship_by_id(ship_id).get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))), {
		"shipId":ship_id, "cancelledProjectId":refit_id,
		"restoredDefinitions":Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)), "committedBomStillLost":funded_bom
	})
	_record_quadrant("CANCEL_SHIP_REFIT", "persistence", _persisted_refit_cancelled(ship_id, refit_id, original_modules), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "cancelledProjectId":refit_id
	})


func _verify_ship_module_install_and_cancel_actions() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for a normal Ship-module installation refit" % scenario_id)
	# The renderer now consumes the same full-loadout availability query as the
	# command. Fund the invariant-valid scenario before creating the UI so the
	# visible Remove control is authoritatively enabled.
	var reinstall_target := _removable_reinstall_target()
	var ship_id := String(reinstall_target.get("shipId", ""))
	var module_id := String(reinstall_target.get("moduleId", ""))
	var setup_desired := Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	var setup_remove_index := setup_desired.find(module_id)
	if setup_remove_index >= 0:
		setup_desired.remove_at(setup_remove_index)
	_fund_ship_refit_setup(ship_id, setup_desired)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for module installation")
	var roster_tab := main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	# The legal checkpoint's commissioned hulls are all full. Form an empty slot
	# through the public Remove control and normal refit completion; no ship,
	# module, project or status field is assigned by the test.
	var setup_remove_control := "RemoveModule_%s_%s" % [ship_id, module_id]
	var setup_remove_button := main.find_child(setup_remove_control, true, false) as Button
	if _button_usable(setup_remove_button):
		setup_remove_button.pressed.emit()
	var setup_refit := _active_refit_for_ship(ship_id)
	var setup_completed := _complete_active_refit_setup(ship_id)
	_check(setup_completed and _same_string_multiset(Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)), setup_desired),
		"visible Remove + normal Simulation completion forms a legal empty Ship slot")
	var original_modules := Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	var desired_modules: Array = original_modules.duplicate()
	desired_modules.append(module_id)
	var funded_bom := _fund_ship_refit_setup(ship_id, desired_modules)
	# Install visibility is itself obtained from the authoritative availability
	# query, including full-BOM availability. Rebuild only after funding setup.
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable after the empty-slot setup")
	roster_tab = main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var install_control := "InstallModule_%s_%s" % [ship_id, module_id]
	var install_button := main.find_child(install_control, true, false) as Button
	var install_result := await _double_submit_with_structured_rejection(install_button, func() -> bool:
		return _active_refit_matches(ship_id, desired_modules)
	)
	var refit := _active_refit_for_ship(ship_id)
	var refit_id := String(refit.get("project_id", ""))
	_record_double_submit_action("INSTALL_SHIP_MODULE", scenario_id, String(install_result.get("controlName", "")), install_result,
		"The named Install control creates one full-loadout Starport refit, consumes its canonical BOM and exclusively owns the physical ship while fabrication is active.")
	_record_quadrant("INSTALL_SHIP_MODULE", "consequence", bool(install_result.get("consequence", false)) \
		and (refit.get("consumed_bom", {}) as Dictionary) == funded_bom, {
		"shipId":ship_id, "moduleId":module_id, "projectId":refit_id,
		"desiredDefinitions":refit.get("desired_definitions", []), "consumedBom":refit.get("consumed_bom", {})
	})
	_record_quadrant("INSTALL_SHIP_MODULE", "persistence", _persisted_refit_matches(refit_id, ship_id, desired_modules), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "moduleId":module_id, "projectId":refit_id,
		"legalSetup":{"controlName":setup_remove_control, "setupProjectId":setup_refit.get("project_id", ""), "completion":"normal Simulation advancement"}
	})
	var stock_after_install := _inventory_snapshot(funded_bom.keys(), String(Game.state.ship_by_id(ship_id).get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)))
	await _settle_ui()

	var archive_tab := main.find_child("FleetSection_archive", true, false) as Button
	if archive_tab != null and not archive_tab.disabled:
		archive_tab.pressed.emit()
		await _settle_ui()
	var cancel_text := I18n.core("ships.archive.cancel_refit")
	var cancel_button := _first_visible_button_by_text(cancel_text, false)
	var cancel_result := await _double_submit_with_structured_rejection(cancel_button, func() -> bool:
		return _refit_cancelled_to_original(ship_id, refit_id, original_modules)
	)
	_record_double_submit_action("CANCEL_SHIP_REFIT", scenario_id, String(cancel_result.get("controlName", "")), cancel_result,
		"Cancellation removes exactly the active refit, restores the physical ship's original loadout and docked ownership, while committed fabrication materials remain consumed.")
	_record_quadrant("CANCEL_SHIP_REFIT", "consequence", bool(cancel_result.get("consequence", false)) \
		and _inventory_snapshot_matches(stock_after_install, String(Game.state.ship_by_id(ship_id).get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))), {
		"shipId":ship_id, "cancelledProjectId":refit_id, "restoredDefinitions":Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)),
		"committedBomStillLost":funded_bom, "locator":"visible localized Cancel Refit control (shared UI currently has no stable name)"
	})
	_record_quadrant("CANCEL_SHIP_REFIT", "persistence", _persisted_refit_cancelled(ship_id, refit_id, original_modules), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "cancelledProjectId":refit_id
	})


func _verify_ship_module_remove_action() -> void:
	var scenario_id := "open_deep"
	var ship_id := "SHIP-004"
	var module_id := "cargo_expansion"
	_check(_activate_scenario(scenario_id), "%s reactivates for a normal Ship-module removal refit" % scenario_id)
	var desired_modules := Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	var remove_index := desired_modules.find(module_id)
	if remove_index >= 0:
		desired_modules.remove_at(remove_index)
	var funded_bom := _fund_ship_refit_setup(ship_id, desired_modules)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for module removal")
	var roster_tab := main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var control_name := "RemoveModule_%s_%s" % [ship_id, module_id]
	var remove_button := main.find_child(control_name, true, false) as Button
	var result := await _double_submit_with_structured_rejection(remove_button, func() -> bool:
		return _active_refit_matches(ship_id, desired_modules)
	)
	var refit := _active_refit_for_ship(ship_id)
	var refit_id := String(refit.get("project_id", ""))
	_record_double_submit_action("REMOVE_SHIP_MODULE", scenario_id, String(result.get("controlName", "")), result,
		"The named Remove control creates one canonical full-loadout refit with one matching installed definition removed; the in-service ship becomes exclusively REFITTING.")
	_record_quadrant("REMOVE_SHIP_MODULE", "consequence", bool(result.get("consequence", false)) \
		and (refit.get("consumed_bom", {}) as Dictionary) == funded_bom, {
		"shipId":ship_id, "moduleId":module_id, "projectId":refit_id,
		"desiredDefinitions":refit.get("desired_definitions", []), "consumedBom":refit.get("consumed_bom", {})
	})
	_record_quadrant("REMOVE_SHIP_MODULE", "persistence", _persisted_refit_matches(refit_id, ship_id, desired_modules), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "moduleId":module_id, "projectId":refit_id
	})


func _verify_ship_loadout_actions() -> void:
	var scenario_id := "open_deep"
	var apply_ship_id := "SHIP-004"
	_check(_activate_scenario(scenario_id), "%s activates for saved Ship Loadouts" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for saved Loadouts")
	var roster_tab := main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var save_button := main.find_child("SaveShipLoadout_%s" % apply_ship_id, true, false) as Button
	var loadout_ids_before: Array = Game.state.saved_loadouts.keys()
	if _button_usable(save_button):
		save_button.pressed.emit()
	await _settle_ui()
	var loadout_id := _new_variant_string_value(loadout_ids_before, Game.state.saved_loadouts.keys())
	var apply_desired: Array = (Game.state.saved_loadouts.get(loadout_id, {}) as Dictionary).get("modules", []).duplicate()
	var apply_bom := _fund_ship_refit_setup(apply_ship_id, apply_desired)
	await _spawn_main()
	await _press_named("Navigation_ships")
	roster_tab = main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var apply_control := "ApplyShipLoadout_%s_%s" % [apply_ship_id, loadout_id]
	var apply_button := main.find_child(apply_control, true, false) as Button
	var apply_result := await _double_submit_with_structured_rejection(apply_button, func() -> bool:
		return _active_refit_matches(apply_ship_id, apply_desired)
	)
	var apply_refit := _active_refit_for_ship(apply_ship_id)
	var apply_project_id := String(apply_refit.get("project_id", ""))
	_record_double_submit_action("APPLY_SHIP_LOADOUT", scenario_id, String(apply_result.get("controlName", "")), apply_result,
		"The stable saved-Loadout control starts one canonical full-BOM Starport refit; the saved preset is a design reference, not a state shortcut.")
	_record_quadrant("APPLY_SHIP_LOADOUT", "consequence", bool(apply_result.get("consequence", false)) \
		and String(apply_refit.get("target_loadout_id", "")) == loadout_id \
		and (apply_refit.get("consumed_bom", {}) as Dictionary) == apply_bom, {
		"shipId":apply_ship_id, "loadoutId":loadout_id, "projectId":apply_project_id,
		"desiredDefinitions":apply_desired, "consumedBom":apply_refit.get("consumed_bom", {})
	})
	_record_quadrant("APPLY_SHIP_LOADOUT", "persistence", _persisted_refit_matches(apply_project_id, apply_ship_id, apply_desired), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":apply_ship_id, "loadoutId":loadout_id, "projectId":apply_project_id
	})

	_check(_activate_scenario(scenario_id), "%s reactivates for Ship-module replacement" % scenario_id)
	var replacement := _replacement_refit_target()
	var replace_ship_id := String(replacement.get("shipId", ""))
	var old_module_id := String(replacement.get("oldModuleId", ""))
	var new_module_id := String(replacement.get("newModuleId", ""))
	var replace_desired: Array = replacement.get("desiredModules", [])
	var replace_bom := _fund_ship_refit_setup(replace_ship_id, replace_desired)
	await _spawn_main()
	await _press_named("Navigation_ships")
	roster_tab = main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var replace_control := "ReplaceModule_%s_%s_%s" % [replace_ship_id, old_module_id, new_module_id]
	var replace_button := main.find_child(replace_control, true, false) as Button
	var replace_result := await _double_submit_with_structured_rejection(replace_button, func() -> bool:
		return _active_refit_matches(replace_ship_id, replace_desired)
	)
	var replace_refit := _active_refit_for_ship(replace_ship_id)
	var replace_project_id := String(replace_refit.get("project_id", ""))
	_record_double_submit_action("REPLACE_SHIP_MODULE", scenario_id, String(replace_result.get("controlName", "")), replace_result,
		"The named replacement control creates one full-loadout refit whose desired definitions exchange exactly the selected compatible slot occupant.")
	_record_quadrant("REPLACE_SHIP_MODULE", "consequence", bool(replace_result.get("consequence", false)) \
		and (replace_refit.get("consumed_bom", {}) as Dictionary) == replace_bom, {
		"shipId":replace_ship_id, "oldModuleId":old_module_id, "newModuleId":new_module_id,
		"projectId":replace_project_id, "desiredDefinitions":replace_desired, "consumedBom":replace_refit.get("consumed_bom", {})
	})
	_record_quadrant("REPLACE_SHIP_MODULE", "persistence", _persisted_refit_matches(replace_project_id, replace_ship_id, replace_desired), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":replace_ship_id, "projectId":replace_project_id,
		"oldModuleId":old_module_id, "newModuleId":new_module_id
	})


func _verify_ship_assignment_and_expedition_actions() -> void:
	var scenario_id := "automate_earth"
	_check(_activate_scenario(scenario_id), "%s activates for Ship assignment and Lunar Expedition" % scenario_id)
	var ship_id := "SHIP-001"
	var formation_id := SpaceGameState.DEFAULT_FORMATION_ID
	if Game.state.ship_formation_id(ship_id) == formation_id:
		Game.set_ship_formation_assignment(ship_id, "")
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for physical fleet assignment")
	var roster_tab := main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var assign_button := main.find_child("FleetRosterDispatch", true, false) as Button
	var assignment_before := Game.state.ship_formation_id(ship_id)
	var notice_before := Game.last_notice
	if _button_usable(assign_button):
		assign_button.pressed.emit()
		await _settle_ui()
		var dispatch_popup := main.get("_fleet_roster_popup") as PopupMenu
		if is_instance_valid(dispatch_popup):
			for item_index in dispatch_popup.item_count:
				if String(dispatch_popup.get_item_metadata(item_index)) == formation_id and not dispatch_popup.is_item_disabled(item_index):
					dispatch_popup.id_pressed.emit(dispatch_popup.get_item_id(item_index))
					break
		await _settle_ui()
	var assignment_notice := Game.last_notice
	var assigned := assignment_before != formation_id and Game.state.ship_formation_id(ship_id) == formation_id \
		and Game.state.formation_ship_ids(formation_id).has(ship_id)
	_record_quadrant("ASSIGN_SHIP", "success", assigned and assignment_notice != notice_before, {
		"scenario":scenario_id, "controlName":"FleetRosterDispatch", "successNotice":assignment_notice
	})
	_record_quadrant("ASSIGN_SHIP", "consequence", assigned, {
		"shipId":ship_id, "formationId":Game.state.ship_formation_id(ship_id),
		"formationRoster":Game.state.formation_ship_ids(formation_id)
	})
	_record_quadrant("ASSIGN_SHIP", "persistence", _persisted_ship_fleet_assignment(ship_id, formation_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "formationId":formation_id
	})
	await _settle_ui()

	_check(await _press_named("ShipsMissions"), "Expedition Missions is reachable from the visible Ships surface")
	var route_id := "lunar_route"
	var fuel_before := Game.state.fleet_supply_quantity("chemical_propellant", "expedition") \
		+ Game.state.item_quantity("chemical_propellant", SpaceGameState.MAIN_BASE_LOCATION_ID)
	var route_button := main.find_child("StartRoute_%s" % route_id, true, false) as Button
	var route_result := await _double_submit_with_structured_rejection(route_button, func() -> bool:
		return String(Game.state.active_expedition.get("status", "")) == "RUNNING" \
			and String(Game.state.active_expedition.get("route_id", "")) == route_id \
			and (Game.state.active_expedition.get("assigned_ship_ids", []) as Array).has(ship_id) \
			and String(Game.state.ship_by_id(ship_id).get("status", "")) == "EXPEDITION"
	)
	var fuel_after := Game.state.fleet_supply_quantity("chemical_propellant", "expedition") \
		+ Game.state.item_quantity("chemical_propellant", SpaceGameState.MAIN_BASE_LOCATION_ID)
	_record_double_submit_action("START_EXPEDITION", scenario_id, String(route_result.get("controlName", "")), route_result,
		"The persistent route runtime exclusively owns the assigned physical ship and consumes its real chemical-propellant cost.")
	var route_consequence := bool(route_result.get("consequence", false)) and fuel_after < fuel_before
	_record_quadrant("START_EXPEDITION", "consequence", route_consequence, {
		"routeId":route_id, "shipId":ship_id, "fuelBefore":fuel_before, "fuelAfter":fuel_after,
		"runtime":Game.state.active_expedition
	})
	_record_quadrant("START_EXPEDITION", "persistence", _persisted_expedition(route_id, ship_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "routeId":route_id, "shipId":ship_id
	})
	await _settle_ui()

	await _press_named("Navigation_ships")
	roster_tab = main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var active_dispatch := main.find_child("FleetRosterDispatch", true, false) as Button
	var active_formation_before := Game.state.ship_formation_id(ship_id)
	var failure_notice_before := Game.last_notice
	if _button_usable(active_dispatch):
		active_dispatch.pressed.emit()
		await _settle_ui()
		var active_popup := main.get("_fleet_roster_popup") as PopupMenu
		if is_instance_valid(active_popup):
			active_popup.id_pressed.emit(active_popup.get_item_id(0))
		await _settle_ui()
	var assignment_rejected := Game.state.ship_formation_id(ship_id) == active_formation_before \
		and Game.last_notice != failure_notice_before
	_record_quadrant("ASSIGN_SHIP", "failure", assignment_rejected, {
		"scenario":scenario_id, "controlName":"FleetRosterDispatch", "mode":"DOMAIN_REJECTION",
		"evidence":"The visible Dispatch menu routes an active-formation reassignment through the canonical availability guard without mutating the roster."
	})

	_check(await _press_named("ShipsMissions"), "Expedition Missions remains reachable for active-route Recall")
	var recall_control := "RecallExpeditionRoute_%s" % route_id
	var recall_button := main.find_child(recall_control, true, false) as Button
	var safe_node_before := int(Game.state.active_expedition.get("safe_node_index", -1))
	var recall_result := await _double_submit_with_structured_rejection(recall_button, func() -> bool:
		return _expedition_is_recalled(ship_id, safe_node_before)
	)
	_record_double_submit_action("RECALL_EXPEDITION", scenario_id, String(recall_result.get("controlName", "")), recall_result,
		"The active route runtime releases its physical ship, unloads recoverable cargo through normal capacity rules, clears route/node/combat ownership and preserves the last safe waypoint field.")
	_record_quadrant("RECALL_EXPEDITION", "persistence", _persisted_recalled_expedition(ship_id, safe_node_before), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "routeId":route_id, "shipId":ship_id,
		"safeNodeBefore":safe_node_before, "safeNodeAfter":Game.state.active_expedition.get("safe_node_index", -1)
	})


func _verify_construction_support_actions() -> void:
	var scenario_id := "open_deep"
	var ship_id := ""
	var location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
	_check(_activate_scenario(scenario_id), "%s activates for physical Construction Support" % scenario_id)
	for ship_value in Game.state.ships:
		var candidate := ship_value as Dictionary
		if String(candidate.get("blueprint_id", "")) == "mobile_constructor":
			ship_id = String(candidate.get("instance_id", ""))
			break
	_check(not ship_id.is_empty(), "%s contains a stable-identity Mobile Constructor" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for Construction Support")
	var roster_tab := main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var capacity_before := Game.simulation.location_construction_capacity(Game.state, location_id)
	var assign_control := "AssignConstructionSupport_%s" % ship_id
	var assign_button := main.find_child(assign_control, true, false) as Button
	var assign_result := await _double_submit_with_structured_rejection(assign_button, func() -> bool:
		var ship := Game.state.ship_by_id(ship_id)
		var assignment: Dictionary = ship.get("assignment", {})
		return String(ship.get("status", "")) == "CONSTRUCTION_SUPPORT" \
			and String(assignment.get("type", "")) == "CONSTRUCTION_SUPPORT" \
			and String(assignment.get("location_id", "")) == location_id \
			and Game.simulation.location_construction_capacity(Game.state, location_id) > capacity_before
	)
	var capacity_assigned := Game.simulation.location_construction_capacity(Game.state, location_id)
	_record_double_submit_action("ASSIGN_CONSTRUCTION_SUPPORT", scenario_id, String(assign_result.get("controlName", "")), assign_result,
		"The unassigned docked engineering ship becomes the exclusive Construction Support asset at its physical Location and raises authoritative local capacity.")
	_record_quadrant("ASSIGN_CONSTRUCTION_SUPPORT", "persistence", _persisted_construction_support(ship_id, location_id, true), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "locationId":location_id,
		"capacityBefore":capacity_before, "capacityAfter":capacity_assigned
	})
	await _settle_ui()

	var release_control := "ReleaseConstructionSupport_%s" % ship_id
	var release_button := main.find_child(release_control, true, false) as Button
	var release_result := await _double_submit_with_structured_rejection(release_button, func() -> bool:
		var ship := Game.state.ship_by_id(ship_id)
		return String(ship.get("status", "")) == "DOCKED" \
			and (ship.get("assignment", {}) as Dictionary).is_empty() \
			and Game.simulation.location_construction_capacity(Game.state, location_id) < capacity_assigned
	)
	_record_double_submit_action("RELEASE_CONSTRUCTION_SUPPORT", scenario_id, String(release_result.get("controlName", "")), release_result,
		"The engineering ship returns to an unassigned docked state and its mobile contribution leaves authoritative local Construction capacity.")
	_record_quadrant("RELEASE_CONSTRUCTION_SUPPORT", "persistence", _persisted_construction_support(ship_id, location_id, false), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":ship_id, "locationId":location_id,
		"capacityAssigned":capacity_assigned, "capacityReleased":Game.simulation.location_construction_capacity(Game.state, location_id)
	})


func _verify_fleet_configuration_actions() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for Fleet configuration" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for Fleet configuration")
	_check(await _press_named("FleetSection_readiness"), "Fleet Readiness is reachable")
	var formation := Game.state.fleet_logistics_runtime("expedition").get("formation", {}) as Dictionary
	var doctrine_before := String(formation.get("doctrine", "HOLD_FORMATION"))
	var doctrine_target := "AGGRESSIVE_PUSH" if doctrine_before != "AGGRESSIVE_PUSH" else "MISSILE_SATURATION"
	var doctrine_control := "FleetDoctrine_%s" % doctrine_target
	var doctrine_button := main.find_child(doctrine_control, true, false) as Button
	if _button_usable(doctrine_button):
		doctrine_button.pressed.emit()
	var doctrine_changed := String(Game.state.fleet_logistics_runtime("expedition").get("formation", {}).get("doctrine", "")) == doctrine_target
	_record_quadrant("SET_FLEET_DOCTRINE", "success", doctrine_changed, {
		"scenario":scenario_id, "controlName":doctrine_control, "previous":doctrine_before, "selected":doctrine_target
	})
	_record_quadrant("SET_FLEET_DOCTRINE", "consequence", doctrine_changed, {
		"authoritativeDoctrine":Game.state.fleet_logistics_runtime("expedition").get("formation", {}).get("doctrine", "")
	})
	_record_quadrant("SET_FLEET_DOCTRINE", "persistence", _persisted_fleet_formation_field("doctrine", doctrine_target), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "doctrine":doctrine_target
	})
	await _settle_ui()
	var selected_doctrine := main.find_child(doctrine_control, true, false) as Button
	_record_quadrant("SET_FLEET_DOCTRINE", "failure", selected_doctrine != null and selected_doctrine.is_visible_in_tree() and selected_doctrine.disabled, {
		"scenario":scenario_id, "controlName":doctrine_control, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The authoritative selected Doctrine remains visible but disabled."
	})

	var retreat_control := "FleetRetreatPolicy_NEVER"
	var retreat_button := main.find_child(retreat_control, true, false) as Button
	if _button_usable(retreat_button):
		retreat_button.pressed.emit()
	var retreat: Dictionary = Game.state.fleet_logistics_runtime("expedition").get("formation", {}).get("retreat_policy", {})
	var retreat_changed := String(retreat.get("mode", "")) == "NEVER"
	_record_quadrant("SET_RETREAT_POLICY", "success", retreat_changed, {
		"scenario":scenario_id, "controlName":retreat_control
	})
	_record_quadrant("SET_RETREAT_POLICY", "consequence", retreat_changed, {
		"authoritativePolicy":retreat
	})
	_record_quadrant("SET_RETREAT_POLICY", "persistence", _persisted_retreat_policy("NEVER", 0.25), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "mode":"NEVER"
	})
	await _settle_ui()
	var selected_retreat := main.find_child(retreat_control, true, false) as Button
	_record_quadrant("SET_RETREAT_POLICY", "failure", selected_retreat != null and selected_retreat.is_visible_in_tree() and selected_retreat.disabled, {
		"scenario":scenario_id, "controlName":retreat_control, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The authoritative selected Retreat Policy remains visible but disabled."
	})

	var roster_tab := main.find_child("FleetSection_roster", true, false) as Button
	if roster_tab != null and not roster_tab.disabled:
		roster_tab.pressed.emit()
		await _settle_ui()
	var combat_ship_id := "SHIP-002"
	var zone_control := "ShipCombatZone_%s_MID" % combat_ship_id
	var zone_button := main.find_child(zone_control, true, false) as Button
	if _button_usable(zone_button):
		zone_button.pressed.emit()
	var zone_changed := String(Game.state.fleet_logistics_runtime("expedition").get("formation", {}).get("ship_zones", {}).get(combat_ship_id, "")) == "MID"
	_record_quadrant("SET_COMBAT_ZONE", "success", zone_changed, {
		"scenario":scenario_id, "controlName":zone_control, "shipId":combat_ship_id
	})
	_record_quadrant("SET_COMBAT_ZONE", "consequence", zone_changed, {
		"shipId":combat_ship_id, "authoritativeZone":"MID"
	})
	_record_quadrant("SET_COMBAT_ZONE", "persistence", _persisted_combat_zone(combat_ship_id, "MID"), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":combat_ship_id, "zone":"MID"
	})
	await _settle_ui()
	var selected_zone := main.find_child(zone_control, true, false) as Button
	_record_quadrant("SET_COMBAT_ZONE", "failure", selected_zone != null and selected_zone.is_visible_in_tree() and selected_zone.disabled, {
		"scenario":scenario_id, "controlName":zone_control, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The selected per-Ship formation zone remains visible but disabled."
	})


func _verify_fleet_supply_actions() -> void:
	var scenario_id := "open_deep"
	var item_id := "chemical_propellant"
	_check(_activate_scenario(scenario_id), "%s activates for Fleet supply controls" % scenario_id)
	# Legal scenario setup supplies ordinary owned inventory through the same
	# invariant-preserving API used by normal production completion. The target
	# plan and transfer actions below still enter only through visible controls.
	Game.state.add_item(item_id, 12, SpaceGameState.MAIN_BASE_LOCATION_ID)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for Fleet supply actions")
	_check(await _press_named("FleetSection_readiness"), "Fleet Readiness is reachable for Fleet supply actions")

	var supply_before := Game.state.fleet_supply_quantity(item_id, "expedition")
	var target_quantity := supply_before + 7
	var input := main.find_child("FleetSupplyTarget_%s" % item_id, true, false) as SpinBox
	var set_control := "SetFleetSupplyPlan_%s" % item_id
	var set_button := main.find_child(set_control, true, false) as Button
	if input != null:
		input.value = target_quantity
	var set_usable := _button_usable(set_button)
	if set_usable:
		set_button.pressed.emit()
	var plan_after_first: Dictionary = Game.state.fleet_logistics_runtime("expedition").get("supply_plan", {})
	var set_consequence := int(plan_after_first.get(item_id, -1)) == target_quantity
	var first_notice := Game.last_notice
	# Submit the same still-live control before the dirty rebuild. The second
	# intent is a genuine no-op and must be rejected by the Domain contract.
	if is_instance_valid(set_button):
		set_button.pressed.emit()
	var unchanged_notice := Game.last_notice
	await _settle_ui()
	var set_failure := not unchanged_notice.is_empty() and unchanged_notice != first_notice \
		and _visible_text(main).contains(unchanged_notice)
	_record_quadrant("SET_FLEET_SUPPLY_PLAN", "success", set_usable and set_consequence, {
		"scenario":scenario_id, "controlName":set_control, "itemId":item_id,
		"targetQuantity":target_quantity, "entry":"visible named SpinBox and Save Target button"
	})
	_record_quadrant("SET_FLEET_SUPPLY_PLAN", "failure", set_failure, {
		"scenario":scenario_id, "controlName":set_control, "mode":"STRUCTURED_DOMAIN_REJECTION",
		"rejectionNotice":unchanged_notice, "visibleInAlertsTimeline":_visible_text(main).contains(unchanged_notice),
		"formation":"The same canonical target was submitted twice; the Domain rejected the second no-op."
	})
	_record_quadrant("SET_FLEET_SUPPLY_PLAN", "consequence", set_consequence, {
		"fleetId":"expedition", "itemId":item_id, "authoritativeTarget":plan_after_first.get(item_id, -1)
	})
	_record_quadrant("SET_FLEET_SUPPLY_PLAN", "persistence", _persisted_fleet_supply_plan(item_id, target_quantity), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "fleetId":"expedition", "itemId":item_id,
		"targetQuantity":target_quantity
	})

	var base_stock_before := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
	var fleet_stock_before := Game.state.fleet_supply_quantity(item_id, "expedition")
	var resupply_button := main.find_child("AutoResupplyFleet", true, false) as Button
	var resupply_usable := _button_usable(resupply_button)
	if resupply_usable:
		resupply_button.pressed.emit()
	var base_stock_after := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
	var fleet_stock_after := Game.state.fleet_supply_quantity(item_id, "expedition")
	var transferred := fleet_stock_after - fleet_stock_before
	var conserved := base_stock_before + fleet_stock_before == base_stock_after + fleet_stock_after
	var resupply_consequence := transferred > 0 and base_stock_before - base_stock_after == transferred and conserved
	_record_quadrant("RESUPPLY_FLEET", "success", resupply_usable and resupply_consequence, {
		"scenario":scenario_id, "controlName":"AutoResupplyFleet", "itemId":item_id,
		"transferred":transferred, "entry":"visible named Auto-resupply button"
	})
	_record_quadrant("RESUPPLY_FLEET", "consequence", resupply_consequence, {
		"baseBefore":base_stock_before, "baseAfter":base_stock_after,
		"fleetBefore":fleet_stock_before, "fleetAfter":fleet_stock_after,
		"aggregateConserved":conserved
	})
	_record_quadrant("RESUPPLY_FLEET", "persistence", _persisted_fleet_supply_transfer(item_id, base_stock_after, fleet_stock_after), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "itemId":item_id,
		"baseQuantity":base_stock_after, "fleetQuantity":fleet_stock_after
	})

	var failure_scenario := "establish_industry"
	_check(_activate_scenario(failure_scenario), "%s activates for empty Expedition Fleet resupply failure" % failure_scenario)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for empty-fleet resupply failure")
	_check(await _press_named("FleetSection_readiness"), "Fleet Readiness is reachable for empty-fleet resupply failure")
	var disabled_resupply := main.find_child("AutoResupplyFleet", true, false) as Button
	var resupply_failure := disabled_resupply != null and disabled_resupply.is_visible_in_tree() \
		and disabled_resupply.disabled and not disabled_resupply.tooltip_text.is_empty()
	_record_quadrant("RESUPPLY_FLEET", "failure", resupply_failure, {
		"scenario":failure_scenario, "controlName":"AutoResupplyFleet", "mode":"VISIBLE_DISABLED_CONTROL",
		"tooltip":disabled_resupply.tooltip_text if disabled_resupply != null else "",
		"evidence":"The legal checkpoint has no Expedition Fleet roster; resupply stays discoverable but disabled with an explicit reason."
	})


func _verify_combat_action() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for repeatable Expedition combat" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_ships"), "Ships is reachable for repeatable combat")
	_check(await _press_named("ShipsMissions"), "Expedition Missions is reachable for repeatable combat")
	var combat_button := _first_enabled_named_prefix("StartCombat_")
	var activity_id := String(combat_button.name).trim_prefix("StartCombat_") if combat_button != null else ""
	var result := await _double_submit_with_structured_rejection(combat_button, func() -> bool:
		var runtime: Dictionary = Game.state.active_expedition
		return String(runtime.get("status", "")) == "RUNNING" \
			and String(runtime.get("activity_id", "")) == activity_id \
			and not (runtime.get("assigned_ship_ids", []) as Array).is_empty() \
			and (runtime.get("assigned_ship_ids", []) as Array).all(func(ship_id): return String(Game.state.ship_by_id(String(ship_id)).get("status", "")) == "EXPEDITION")
	)
	_record_double_submit_action("START_COMBAT_ACTION", scenario_id, String(result.get("controlName", "")), result,
		"The repeatable encounter runtime exclusively owns the ready Expedition Fleet and enters the activity's real combat phase; a second active front is rejected.")
	_record_quadrant("START_COMBAT_ACTION", "persistence", _persisted_combat_action(activity_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "activityId":activity_id,
		"assignedShipIds":Game.state.active_expedition.get("assigned_ship_ids", [])
	})


func _verify_manufacturing_module_actions() -> void:
	var scenario_id := "open_deep"
	_check(_activate_scenario(scenario_id), "%s activates for idle Factory module refit" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_industry"), "Industry is reachable for manufacturing modules")
	_check(await _press_named("IndustrySection_facilities"), "Facilities section is reachable for manufacturing modules")
	var before_installations := _manufacturing_installation_keys(Game.state)
	var uninstall_button := _first_enabled_named_prefix("UninstallManufacturingModule_")
	var uninstall_result := await _double_submit_with_structured_rejection(uninstall_button, func() -> bool:
		return not _removed_string_value(before_installations, _manufacturing_installation_keys(Game.state)).is_empty()
	)
	var removed_key := _removed_string_value(before_installations, _manufacturing_installation_keys(Game.state))
	var parts := removed_key.split("|")
	var facility_id := String(parts[0]) if parts.size() == 3 else ""
	var module_kind := String(parts[1]) if parts.size() == 3 else ""
	var module_id := String(parts[2]) if parts.size() == 3 else ""
	var module_stock := int(Game.state.manufacturing_module_inventory.get(module_id, 0))
	_record_double_submit_action("UNINSTALL_MANUFACTURING_MODULE", scenario_id, String(uninstall_result.get("controlName", "")), uninstall_result,
		"The installed physical module leaves the idle Factory and returns exactly one unit to manufacturing-module storage.")
	_record_quadrant("UNINSTALL_MANUFACTURING_MODULE", "consequence", bool(uninstall_result.get("consequence", false)) \
		and not facility_id.is_empty() and module_stock > 0, {
		"facilityId":facility_id, "moduleId":module_id, "moduleKind":module_kind, "moduleStorage":module_stock
	})
	_record_quadrant("UNINSTALL_MANUFACTURING_MODULE", "persistence", _persisted_manufacturing_module(facility_id, module_id, module_kind, false, module_stock), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "facilityId":facility_id, "moduleId":module_id, "moduleKind":module_kind, "installed":false
	})
	await _settle_ui()

	var install_name := "InstallManufacturingModule_%s_%s_%s" % [facility_id, module_id, module_kind]
	var install_button := main.find_child(install_name, true, false) as Button
	var install_result := await _double_submit_with_structured_rejection(install_button, func() -> bool:
		return _manufacturing_installation_keys(Game.state).has(removed_key)
	)
	var stock_after_install := int(Game.state.manufacturing_module_inventory.get(module_id, 0))
	_record_double_submit_action("INSTALL_MANUFACTURING_MODULE", scenario_id, String(install_result.get("controlName", "")), install_result,
		"The visible refit control draws the returned physical module from storage and installs it in the compatible idle Factory.")
	_record_quadrant("INSTALL_MANUFACTURING_MODULE", "consequence", bool(install_result.get("consequence", false)) \
		and stock_after_install == maxi(0, module_stock - 1), {
		"facilityId":facility_id, "moduleId":module_id, "moduleKind":module_kind,
		"storageBefore":module_stock, "storageAfter":stock_after_install
	})
	_record_quadrant("INSTALL_MANUFACTURING_MODULE", "persistence", _persisted_manufacturing_module(facility_id, module_id, module_kind, true, stock_after_install), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "facilityId":facility_id, "moduleId":module_id, "moduleKind":module_kind, "installed":true
	})


func _verify_megastructure_site_selection_action() -> void:
	var scenario_id := "megastructure_site_preparation"
	var megastructure_id := "stellar_energy"
	_check(_activate_scenario(scenario_id), "%s activates before Megastructure site commitment" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_megastructure"), "Megastructure candidate surface is reachable")
	var button := _first_enabled_named_prefix("SelectMegastructureSite_")
	var candidate_id := String(button.name).trim_prefix("SelectMegastructureSite_") if button != null else ""
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		return _megastructure_site_selected(megastructure_id, candidate_id)
	)
	_record_double_submit_action("SELECT_MEGASTRUCTURE_SITE", scenario_id, String(result.get("controlName", "")), result,
		"The Deep-Surveyed candidate becomes the stable Megastructure worksite, records Phase-zero completion and advances to the first material phase; a duplicate commitment is rejected.")
	_record_quadrant("SELECT_MEGASTRUCTURE_SITE", "persistence", _persisted_megastructure_site(megastructure_id, candidate_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "megastructureId":megastructure_id, "locationId":candidate_id,
		"phaseIndex":(Game.state.megastructure_projects.get(megastructure_id, {}) as Dictionary).get("phase_index", -1)
	})


func _verify_megastructure_phase_action() -> void:
	var scenario_id := "prepare_stellar_energy"
	_check(_activate_scenario(scenario_id), "%s activates for a ready Megastructure phase" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_megastructure"), "Megastructure is reachable through visible navigation")
	var button := main.find_child("StartMegastructure_stellar_energy", true, false) as Button
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		return _active_megastructure_runtime_count("stellar_energy") == 1 \
			and not String((Game.state.megastructure_projects.get("stellar_energy", {}) as Dictionary).get("active_project_id", "")).is_empty()
	)
	_record_double_submit_action("START_MEGASTRUCTURE_PHASE", scenario_id, String(result.get("controlName", "")), result,
		"Exactly one shared Construction runtime owns the active Stellar Energy phase and its project identity is stored on the Megastructure project.")
	var active_project_id := String((Game.state.megastructure_projects.get("stellar_energy", {}) as Dictionary).get("active_project_id", ""))
	# Failure is valid only if the rapid second submission was rejected and did
	# not create a second runtime for the same physical phase.
	var failure_row := (coverage["START_MEGASTRUCTURE_PHASE"] as Dictionary).get("failure", {}) as Dictionary
	failure_row["verified"] = bool(failure_row.get("verified", false)) and _active_megastructure_runtime_count("stellar_energy") == 1
	failure_row["activeRuntimeCountAfterRapidSecondSubmission"] = _active_megastructure_runtime_count("stellar_energy")
	coverage["START_MEGASTRUCTURE_PHASE"]["failure"] = failure_row
	_record_quadrant("START_MEGASTRUCTURE_PHASE", "persistence", _persisted_megastructure_phase(active_project_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "megastructureId":"stellar_energy", "activeProjectId":active_project_id,
		"claim":"The one active phase and its shared Construction project survive Domain round-trip."
	})
	await _settle_ui()

	var history_before := Game.state.construction_history.size()
	var cancel_button := main.find_child("CancelMegastructure_stellar_energy", true, false) as Button
	var cancel_result := await _double_submit_with_structured_rejection(cancel_button, func() -> bool:
		var mega_project := Game.state.megastructure_projects.get("stellar_energy", {}) as Dictionary
		return _active_megastructure_runtime_count("stellar_energy") == 0 \
			and String(mega_project.get("active_project_id", "")).is_empty() \
			and Game.state.construction_history.size() == history_before + 1
	)
	_record_double_submit_action("CANCEL_MEGASTRUCTURE_PHASE", scenario_id, String(cancel_result.get("controlName", "")), cancel_result,
		"Shared Construction cancels the active phase exactly once, clears Megastructure ownership, and appends one cancellation ledger row.")
	_record_quadrant("CANCEL_MEGASTRUCTURE_PHASE", "persistence", _persisted_cancel_history(active_project_id) \
		and _persisted_megastructure_has_no_active_phase("stellar_energy"), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "megastructureId":"stellar_energy", "cancelledProjectId":active_project_id
	})


func _verify_route_pause_action() -> void:
	var scenario_id := "megastructure_phase_2"
	_check(_activate_scenario(scenario_id), "%s activates for route pause controls" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_location"), "Location is reachable for route pause")
	_check(await _press_named("LocationTab_logistics"), "Location Logistics tab is reachable for route pause")
	var button := main.find_child("PauseLogisticsRoute_earth_lagrange_freight", true, false) as Button
	var result := await _double_submit_with_structured_rejection(button, func() -> bool:
		var snapshot: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, "earth_lagrange_freight")
		return String(snapshot.get("status", "")) == "PAUSED" and is_zero_approx(float(snapshot.get("capacity_per_dispatch", 0.0)))
	)
	_record_double_submit_action("SET_ROUTE_PAUSED", scenario_id, String(result.get("controlName", "")), result,
		"The authoritative route Service is PAUSED and exposes zero dispatch capacity.")
	_record_quadrant("SET_ROUTE_PAUSED", "persistence", _persisted_logistics_pause("earth_lagrange_freight", true), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "routeId":"earth_lagrange_freight", "expectedStatus":"PAUSED"
	})


func _verify_logistics_service_actions() -> void:
	var success_scenario := "open_deep"
	_check(_activate_scenario(success_scenario), "%s activates for advanced Logistics Service actions" % success_scenario)
	await _spawn_main()
	_check(await _open_location_logistics(SpaceGameState.MAIN_BASE_LOCATION_ID), "Earth Logistics services are reachable for transport-mode actions")

	# Assign the only legal freight-capable ship while services still use public
	# General Cargo. This is a direct click on the visible per-ship action.
	var assign_button: Button
	var assigned_ship_id := ""
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		if not Game.state.ship_is_unassigned_docked(ship_id):
			continue
		var assign_text := I18n.core("location.logistics.assign_ship") % String(ship.get("name", ship_id))
		assign_button = _first_visible_button_by_text(assign_text, false)
		if _button_usable(assign_button):
			assigned_ship_id = ship_id
			break
	var assignment_before := String(Game.state.ship_by_id(assigned_ship_id).get("assignment", {}).get("service_id", ""))
	if _button_usable(assign_button):
		assign_button.pressed.emit()
	var assigned_ship := Game.state.ship_by_id(assigned_ship_id)
	var assigned_service_id := String(assigned_ship.get("assignment", {}).get("service_id", ""))
	var assigned_route_id := String(assigned_ship.get("assignment", {}).get("route_id", ""))
	var assignment_success := not assigned_ship_id.is_empty() and assignment_before.is_empty() and not assigned_service_id.is_empty() \
		and (Game.simulation.logistics.service_for_route(Game.state, assigned_route_id).get("assigned_ship_ids", []) as Array).has(assigned_ship_id)
	_record_quadrant("ASSIGN_LOGISTICS_SHIP", "success", assignment_success, {
		"scenario":success_scenario, "controlText":String(assign_button.text) if assign_button != null else "",
		"locator":"Visible Assign Ship button generated from the physical ship identity"
	})
	_record_quadrant("ASSIGN_LOGISTICS_SHIP", "consequence", assignment_success, {
		"shipId":assigned_ship_id, "serviceId":assigned_service_id, "routeId":assigned_route_id,
		"shipStatus":assigned_ship.get("status", ""), "exclusiveAssignment":assigned_ship.get("assignment", {})
	})
	_record_quadrant("ASSIGN_LOGISTICS_SHIP", "persistence", _persisted_logistics_assignment(assigned_ship_id, assigned_service_id, assigned_route_id), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "shipId":assigned_ship_id, "serviceId":assigned_service_id, "routeId":assigned_route_id
	})
	await _settle_ui()

	var bulk_mode := Game.content.transport_modes.get("bulk_tug", {}) as Dictionary
	var bulk_text := I18n.content(bulk_mode)
	var bulk_button := _first_visible_button_by_text(bulk_text, false)
	_check(_button_usable(bulk_button), "a real Bulk Tug transport-mode control is enabled with the legal late-game freight ship")
	var service_modes_before := _service_field_snapshot("transport_mode_id")
	if _button_usable(bulk_button):
		bulk_button.pressed.emit()
	var bulk_route_id := _changed_service_field(service_modes_before, "transport_mode_id", "bulk_tug")
	var bulk_service: Dictionary = Game.simulation.logistics.service_for_route(Game.state, bulk_route_id)
	var bulk_ship_ids: Array = bulk_service.get("assigned_ship_ids", []).duplicate()
	var mode_success := not bulk_route_id.is_empty() and String(bulk_service.get("transport_mode_id", "")) == "bulk_tug" and not bulk_ship_ids.is_empty()
	_record_quadrant("CHANGE_TRANSPORT_MODE", "success", mode_success, {
		"scenario":success_scenario, "controlText":bulk_text, "controlName":String(bulk_button.name) if bulk_button != null else "",
		"locator":"Visible localized Transport Mode button inside a live route card"
	})
	_record_quadrant("CHANGE_TRANSPORT_MODE", "consequence", mode_success, {
		"routeId":bulk_route_id, "transportModeId":bulk_service.get("transport_mode_id", ""), "assignedShipIds":bulk_ship_ids
	})
	_record_quadrant("CHANGE_TRANSPORT_MODE", "persistence", _persisted_logistics_service(bulk_route_id, "bulk_tug", "", bulk_ship_ids), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "routeId":bulk_route_id, "transportModeId":"bulk_tug", "assignedShipIds":bulk_ship_ids
	})
	await _settle_ui()

	# Removing the only physical ship from a non-public Bulk Tug service is a
	# visible disabled failure surface for the ship-assignment action.
	var bulk_ship_id := String(bulk_ship_ids[0]) if not bulk_ship_ids.is_empty() else ""
	var bulk_ship := Game.state.ship_by_id(bulk_ship_id)
	var remove_text := I18n.core("location.logistics.remove_ship") % String(bulk_ship.get("name", bulk_ship_id)) if not bulk_ship.is_empty() else ""
	var last_ship_button := _first_visible_button_by_text(remove_text, true)
	var assignment_failure := last_ship_button != null and last_ship_button.disabled
	_record_quadrant("ASSIGN_LOGISTICS_SHIP", "failure", assignment_failure, {
		"scenario":success_scenario, "controlText":remove_text, "mode":"VISIBLE_DISABLED_CONTROL",
		"evidence":"The only physical ship on a non-public service cannot be removed, preventing a zero-asset route configuration."
	})

	var priority_id := "PRECISION_FIRST"
	var priority_text := I18n.core("logistics.priority.%s" % priority_id)
	var priority_button := _first_visible_button_by_text(priority_text, false)
	var priorities_before := _service_field_snapshot("priority_strategy")
	if _button_usable(priority_button):
		priority_button.pressed.emit()
	var priority_route_id := _changed_service_field(priorities_before, "priority_strategy", priority_id)
	var priority_success := not priority_route_id.is_empty()
	_record_quadrant("CHANGE_ROUTE_PRIORITY", "success", priority_success, {
		"scenario":success_scenario, "controlText":priority_text,
		"locator":"Visible localized priority strategy button inside a live route card"
	})
	_record_quadrant("CHANGE_ROUTE_PRIORITY", "consequence", priority_success, {
		"routeId":priority_route_id, "priorityStrategy":Game.simulation.logistics.service_for_route(Game.state, priority_route_id).get("priority_strategy", "")
	})
	var priority_service: Dictionary = Game.simulation.logistics.service_for_route(Game.state, priority_route_id)
	_record_quadrant("CHANGE_ROUTE_PRIORITY", "persistence", _persisted_logistics_service(priority_route_id, String(priority_service.get("transport_mode_id", "")), priority_id, priority_service.get("assigned_ship_ids", [])), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "routeId":priority_route_id, "priorityStrategy":priority_id
	})
	await _settle_ui()
	var selected_priority_name := "LogisticsPriority_%s_%s" % [priority_route_id, priority_id]
	var selected_priority_button := main.find_child(selected_priority_name, true, false) as Button
	var priority_failure := selected_priority_button != null and selected_priority_button.is_visible_in_tree() \
		and selected_priority_button.disabled and not selected_priority_button.tooltip_text.is_empty()
	_record_quadrant("CHANGE_ROUTE_PRIORITY", "failure", priority_failure, {
		"scenario":success_scenario, "controlName":selected_priority_name, "mode":"VISIBLE_DISABLED_CONTROL",
		"tooltip":selected_priority_button.tooltip_text if selected_priority_button != null else "",
		"evidence":"The authoritative selected strategy remains visible but disabled, preventing a false-success same-priority command."
	})

	# Failure for transport-mode selection comes from a real locked mode in an
	# earlier legal checkpoint with no compatible physical transport asset.
	var failure_scenario := "reach_lunar"
	_check(_activate_scenario(failure_scenario), "%s activates for locked Transport Mode evidence" % failure_scenario)
	await _spawn_main()
	await _open_location_logistics(SpaceGameState.MAIN_BASE_LOCATION_ID)
	var locked_bulk := _first_visible_button_by_text(bulk_text, true)
	var mode_failure := locked_bulk != null and locked_bulk.disabled and not locked_bulk.tooltip_text.is_empty()
	_record_quadrant("CHANGE_TRANSPORT_MODE", "failure", mode_failure, {
		"scenario":failure_scenario, "controlText":bulk_text, "mode":"VISIBLE_DISABLED_CONTROL",
		"tooltip":locked_bulk.tooltip_text if locked_bulk != null else "",
		"evidence":"The same public Transport Mode remains visible but disabled without the required physical freight capability."
	})


func _verify_logistics_policy_actions() -> void:
	var scenario_id := "establish_industry"
	_check(_activate_scenario(scenario_id), "%s activates for Logistics policy controls" % scenario_id)
	await _spawn_main()
	_check(await _press_named("Navigation_location"), "Location is reachable for Logistics policies")
	_check(await _press_named("LocationTab_logistics"), "Location Logistics tab is reachable")
	_check(await _press_named("LogisticsPolicyAdvancedToggle"), "Advanced policy exceptions are visible by explicit player choice")
	var policies_before: Dictionary = Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {})
	var before_ids: Array = policies_before.keys()
	var add_button := main.find_child("AddLogisticsPolicy_%s_DEMAND" % SpaceGameState.MAIN_BASE_LOCATION_ID, true, false) as Button
	var add_control := String(add_button.name) if add_button != null else ""
	if _button_usable(add_button):
		add_button.pressed.emit()
	var policies_after_add: Dictionary = Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {})
	var after_ids: Array = policies_after_add.keys()
	var item_id := ""
	for candidate_value in after_ids:
		if not before_ids.has(candidate_value):
			item_id = String(candidate_value)
			break
	var add_succeeded := not item_id.is_empty() and String((policies_after_add.get(item_id, {}) as Dictionary).get("mode", "")) == LogisticsEngine.MODE_DEMAND
	await _settle_ui()
	var set_name := "SetLogisticsPolicy_%s_%s" % [SpaceGameState.MAIN_BASE_LOCATION_ID, item_id]
	var set_button := main.find_child(set_name, true, false) as Button
	var mode_selector: OptionButton
	if set_button != null and set_button.get_parent() != null and set_button.get_parent().get_parent() != null:
		var option_nodes := set_button.get_parent().get_parent().find_children("*", "OptionButton", true, false)
		if not option_nodes.is_empty():
			mode_selector = option_nodes[0] as OptionButton
	if mode_selector != null:
		mode_selector.select(0)
	var set_notice_before := Game.last_notice
	if _button_usable(set_button):
		set_button.pressed.emit()
	var policies_after_set: Dictionary = Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {})
	var policy := policies_after_set.get(item_id, {}) as Dictionary
	var set_success := add_succeeded and _button_usable(set_button) and String(policy.get("mode", "")) == LogisticsEngine.MODE_SUPPLY
	var set_success_notice := Game.last_notice
	# The stale-but-visible control can be clicked once more before the dirty UI
	# rebuild. The Domain compares normalized policy values and rejects the no-op.
	if is_instance_valid(set_button):
		set_button.pressed.emit()
	var set_rejection_notice := Game.last_notice
	await _settle_ui()
	var set_failure := not set_rejection_notice.is_empty() \
		and set_rejection_notice != set_success_notice \
		and set_rejection_notice != set_notice_before \
		and _visible_text(main).contains(set_rejection_notice)
	_record_quadrant("SET_LOGISTICS_POLICY", "success", set_success, {
		"scenario":scenario_id, "controlName":set_name, "setupControlName":add_control, "itemId":item_id,
		"entry":"real MainScene AddLogisticsPolicy creates the policy; visible OptionButton + SetLogisticsPolicy edits it",
		"successNotice":set_success_notice
	})
	_record_quadrant("SET_LOGISTICS_POLICY", "consequence", set_success, {
		"locationId":SpaceGameState.MAIN_BASE_LOCATION_ID, "itemId":item_id, "policy":policy
	})
	_record_quadrant("SET_LOGISTICS_POLICY", "persistence", _persisted_logistics_policy(item_id, true), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "locationId":SpaceGameState.MAIN_BASE_LOCATION_ID, "itemId":item_id
	})
	_record_quadrant("SET_LOGISTICS_POLICY", "failure", set_failure, {
		"scenario":scenario_id, "controlName":set_name, "mode":"STRUCTURED_DOMAIN_REJECTION",
		"rejectionNotice":set_rejection_notice, "visibleInAlertsTimeline":_visible_text(main).contains(set_rejection_notice),
		"formation":"The same canonical normalized policy was submitted twice; the Domain rejected the second no-op."
	})

	var clear_name := "ClearLogisticsPolicy_%s_%s" % [SpaceGameState.MAIN_BASE_LOCATION_ID, item_id]
	var clear_button := main.find_child(clear_name, true, false) as Button
	var notice_before := Game.last_notice
	if _button_usable(clear_button):
		clear_button.pressed.emit()
	var policies_after_clear: Dictionary = Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {})
	var cleared_once := not policies_after_clear.has(item_id)
	var success_notice := Game.last_notice
	# A rapid repeat through the same still-live control reaches the legitimate
	# nothing-to-clear rejection without constructing an invalid location/item.
	if is_instance_valid(clear_button):
		clear_button.pressed.emit()
	var second_notice := Game.last_notice
	await _settle_ui()
	_record_quadrant("CLEAR_LOGISTICS_POLICY", "success", cleared_once and success_notice != notice_before, {
		"scenario":scenario_id, "controlName":clear_name, "successNotice":success_notice
	})
	var policies_after_repeat: Dictionary = Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {})
	_record_quadrant("CLEAR_LOGISTICS_POLICY", "consequence", cleared_once and not policies_after_repeat.has(item_id), {
		"locationId":SpaceGameState.MAIN_BASE_LOCATION_ID, "itemId":item_id, "policyPresent":policies_after_repeat.has(item_id)
	})
	_record_quadrant("CLEAR_LOGISTICS_POLICY", "persistence", _persisted_logistics_policy(item_id, false), {
		"tier":"DOMAIN_SERIALIZE_DESERIALIZE_ONLY", "locationId":SpaceGameState.MAIN_BASE_LOCATION_ID, "itemId":item_id
	})
	var clear_failure := not second_notice.is_empty() and second_notice != success_notice \
		and _visible_text(main).contains(second_notice)
	_record_quadrant("CLEAR_LOGISTICS_POLICY", "failure", clear_failure, {
		"scenario":scenario_id, "controlName":clear_name, "mode":"STRUCTURED_DOMAIN_REJECTION",
		"rejectionNotice":second_notice, "visibleInAlertsTimeline":_visible_text(main).contains(second_notice),
		"formation":"The same visible Clear control was submitted again before rebuild; the Domain rejected the absent-policy no-op."
	})


func _verify_save_unavailable_failure() -> void:
	var scenario_id := "establish_industry"
	_check(_activate_scenario(scenario_id), "%s activates for persistence-disabled Save failure" % scenario_id)
	await _spawn_main()
	var save_button := main.find_child("SaveButton", true, false) as Button
	var notice_before := Game.last_notice
	if _button_usable(save_button):
		save_button.pressed.emit()
	var rejection_notice := Game.last_notice
	await _settle_ui()
	var failure_visible := not rejection_notice.is_empty() and rejection_notice != notice_before \
		and _visible_text(main).contains(rejection_notice)
	_record_quadrant("SAVE_GAME", "failure", failure_visible, {
		"scenario":scenario_id, "controlName":"SaveButton", "mode":"STRUCTURED_DOMAIN_REJECTION",
		"persistenceEnabled":Game.persistence_enabled, "rejectionNotice":rejection_notice,
		"visibleInAlertsTimeline":_visible_text(main).contains(rejection_notice),
		"boundary":"This suite intentionally runs with persistence disabled and does not touch user://."
	})
	_import_isolated_save_evidence()


func _import_isolated_save_evidence() -> void:
	var parsed: Variant = null
	if FileAccess.file_exists(UI_PERSISTENCE_EVIDENCE_PATH):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(UI_PERSISTENCE_EVIDENCE_PATH))
	var envelope_valid := parsed is Dictionary \
		and int((parsed as Dictionary).get("schemaVersion", 0)) == 1 \
		and String((parsed as Dictionary).get("source", "")) == "tests/ui_persistence_audit_test.gd" \
		and bool((parsed as Dictionary).get("passed", false)) \
		and String((parsed as Dictionary).get("isolation", "")).contains("unique platform-runner temporary root")
	var observations: Array = []
	if parsed is Dictionary:
		observations = (parsed as Dictionary).get("observations", [])
	var visible_save_wrote_disk := envelope_valid and _passed_external_observation(observations,
		"visible SaveButton writes the isolated LocalSaveRepository")
	var ui_consequence_created := envelope_valid and _passed_external_observation(observations,
		"visible Ships control creates the state later loaded by the reader")
	var ui_consequence_restored := envelope_valid and _passed_external_observation(observations,
		"startup auto-load restores the UI-created fleet assignment")
	var identity_restored := envelope_valid and _passed_external_observation(observations,
		"startup auto-load restores stable Save identity and revision")
	_record_quadrant("SAVE_GAME", "success", visible_save_wrote_disk, {
		"sourceArtifact":UI_PERSISTENCE_EVIDENCE_PATH,
		"controlName":"SaveButton", "isolatedWriterVerified":visible_save_wrote_disk,
		"boundary":"Imported only from the separate isolated APPDATA writer/reader run."
	})
	_record_quadrant("SAVE_GAME", "consequence", ui_consequence_created and ui_consequence_restored, {
		"sourceArtifact":UI_PERSISTENCE_EVIDENCE_PATH,
		"uiCreatedConsequence":ui_consequence_created, "startupRestoredConsequence":ui_consequence_restored
	})
	_record_quadrant("SAVE_GAME", "persistence", identity_restored and ui_consequence_restored, {
		"tier":"ISOLATED_LOCAL_SAVE_WRITER_READER", "sourceArtifact":UI_PERSISTENCE_EVIDENCE_PATH,
		"startupIdentityRevisionRestored":identity_restored, "uiConsequenceRestored":ui_consequence_restored
	})


func _passed_external_observation(observations: Array, expected_description: String) -> bool:
	for observation_value in observations:
		if observation_value is Dictionary:
			var observation := observation_value as Dictionary
			if String(observation.get("description", "")) == expected_description and bool(observation.get("passed", false)):
				return true
	return false


func _record_known_surface_gaps() -> void:
	_set_reason("SAVE_GAME", "PARTIAL: persistence-disabled Save is a visible structured failure, but the required passed isolated APPDATA writer/reader artifact is missing or does not explicitly prove SaveButton disk write, startup identity/revision and restored UI-created consequence.")


func _double_submit_with_structured_rejection(button: Button, consequence: Callable) -> Dictionary:
	if not _button_usable(button):
		return {"success":false, "consequence":false, "failure":false, "reason":"visible control missing or disabled"}
	var control_name := String(button.name)
	button.pressed.emit()
	var consequence_verified := bool(consequence.call())
	var success_notice := Game.last_notice
	button.pressed.emit()
	var rejection_notice := Game.last_notice
	await _settle_ui()
	var timeline := _visible_text(main)
	var rejected := not rejection_notice.is_empty() \
		and rejection_notice != success_notice \
		and timeline.contains(rejection_notice)
	return {
		"success":consequence_verified and not success_notice.is_empty(),
		"consequence":consequence_verified,
		"failure":rejected,
		"controlName":control_name,
		"successNotice":success_notice,
		"rejectionNotice":rejection_notice,
		"failureVisibleInTimeline":timeline.contains(rejection_notice) if not rejection_notice.is_empty() else false
	}


func _record_double_submit_action(action_id: String, scenario_id: String, control_name: String, result: Dictionary, consequence_text: String) -> void:
	_record_quadrant(action_id, "success", bool(result.get("success", false)), {
		"scenario":scenario_id, "controlName":control_name,
		"successNotice":result.get("successNotice", ""), "entry":"real MainScene visible Button"
	})
	_record_quadrant(action_id, "failure", bool(result.get("failure", false)), {
		"scenario":scenario_id, "controlName":control_name, "mode":"STRUCTURED_DOMAIN_REJECTION",
		"rejectionNotice":result.get("rejectionNotice", ""),
		"visibleInAlertsTimeline":result.get("failureVisibleInTimeline", false),
		"formation":"The same still-live visible control was submitted again before rebuild; Domain rejected the now-invalid state."
	})
	_record_quadrant(action_id, "consequence", bool(result.get("consequence", false)), {
		"evidence":consequence_text
	})


func _initialize_coverage() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY_PATH))
	_check(parsed is Dictionary, "player action registry parses for runtime evidence")
	if parsed is not Dictionary:
		return
	for action_value in (parsed as Dictionary).get("actions", []):
		var action := action_value as Dictionary
		if not bool(action.get("coreGameplay", false)):
			continue
		var action_id := String(action.get("actionId", ""))
		coverage[action_id] = {
			"actionId":action_id,
			"domainCommand":action.get("domainCommand", ""),
			"saveRelevant":action.get("saveRelevant", false),
			"success":{"verified":false},
			"failure":{"verified":false},
			"consequence":{"verified":false},
			"persistence":{"verified":false},
			"fourCaseVerified":false,
			"reason":"Not exercised by this bounded runtime suite."
		}
	_check(coverage.size() == 48, "runtime evidence denominator matches the current 48-action core registry")


func _record_quadrant(action_id: String, quadrant: String, verified: bool, evidence: Dictionary) -> void:
	if not coverage.has(action_id):
		_check(false, "coverage registry contains %s" % action_id)
		return
	var row := coverage[action_id] as Dictionary
	var value := evidence.duplicate(true)
	value["verified"] = verified
	row[quadrant] = value
	row["fourCaseVerified"] = _quadrants_true(row)
	if bool(row["fourCaseVerified"]):
		row["reason"] = "Verified through real MainScene controls against a legal Golden checkpoint."
	coverage[action_id] = row


func _set_reason(action_id: String, reason: String) -> void:
	if coverage.has(action_id) and not _four_case_verified(action_id):
		coverage[action_id]["reason"] = reason


func _quadrants_true(row: Dictionary) -> bool:
	for quadrant in ["success", "failure", "consequence", "persistence"]:
		if not bool((row.get(quadrant, {}) as Dictionary).get("verified", false)):
			return false
	return true


func _four_case_verified(action_id: String) -> bool:
	return coverage.has(action_id) and _quadrants_true(coverage[action_id] as Dictionary)


func _activate_scenario(scenario_id: String) -> bool:
	var builder = GameplayScenarioBuilderScript.new(Game.content)
	return builder.activate(scenario_id)


func _create_saved_ship_designs(limit: int) -> Array[String]:
	var result: Array[String] = []
	var plan_ids: Array = Game.content.ship_construction_projects.keys()
	plan_ids.sort()
	for plan_id_value in plan_ids:
		var plan_id := String(plan_id_value)
		if not bool(Game.state.unlocked_ship_plans.get(plan_id, false)):
			continue
		var plan := Game.content.ship_construction_projects[plan_id] as Dictionary
		var hull_id := String(plan.get("ship_id", ""))
		var nodes: Array = [{"node_id":"ship_design_hull", "kind":"hull", "definition_id":hull_id, "position":{"x":520.0, "y":220.0}}]
		var connections: Array = []
		var slot_counts := {}
		for module_index in plan.get("starting_modules", []).size():
			var module_id := String(plan.get("starting_modules", [])[module_index])
			var module := Game.content.modules.get(module_id, {}) as Dictionary
			var slot := String(module.get("slot", "utility"))
			var socket_index := int(slot_counts.get(slot, 0))
			slot_counts[slot] = socket_index + 1
			var node_id := "ship_design_module_%04d" % (module_index + 1)
			nodes.append({"node_id":node_id, "kind":"module", "definition_id":module_id, "position":{"x":80.0, "y":80.0 + module_index * 100.0}})
			connections.append({"module_node_id":node_id, "socket_id":"socket_%s_%d" % [slot, socket_index]})
		if Game.save_ship_design("", "Coverage Design %d" % (result.size() + 1), plan_id, nodes, connections):
			result.append(Game.last_saved_ship_design_id)
			if result.size() >= limit:
				break
	return result


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


func _open_location_logistics(location_id: String) -> bool:
	if not await _press_named("Navigation_system_map"):
		return false
	var location_button := main.find_child("Location_%s" % location_id, true, false) as Button
	if not _button_usable(location_button):
		return false
	location_button.pressed.emit()
	await _settle_ui()
	return await _press_named("LocationTab_logistics")


func _open_location_industry() -> bool:
	if not await _press_named("Navigation_location"):
		return false
	return await _press_named("LocationTab_industry")


func _settle_ui() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.24, true, false, true).timeout
	await get_tree().process_frame


func _button_usable(button: Button) -> bool:
	return button != null and button.is_visible_in_tree() and not button.disabled


func _first_enabled_named_prefix(prefix: String) -> Button:
	if not is_instance_valid(main):
		return null
	for node_value in main.find_children("%s*" % prefix, "Button", true, false):
		var button := node_value as Button
		if _button_usable(button):
			return button
	return null


func _first_disabled_visible_named_prefix(prefix: String) -> Button:
	if not is_instance_valid(main):
		return null
	for node_value in main.find_children("%s*" % prefix, "Button", true, false):
		var button := node_value as Button
		if button != null and button.is_visible_in_tree() and button.disabled:
			return button
	return null


func _first_visible_button_by_text(button_text: String, require_disabled: bool) -> Button:
	if not is_instance_valid(main) or button_text.is_empty():
		return null
	for node_value in main.find_children("*", "Button", true, false):
		var button := node_value as Button
		if button == null or not button.is_visible_in_tree() or button.text != button_text:
			continue
		if button.disabled == require_disabled:
			return button
	return null


func _first_visible_button_text_prefix(button_text_prefix: String, require_disabled: bool) -> Button:
	if not is_instance_valid(main) or button_text_prefix.is_empty():
		return null
	for node_value in main.find_children("*", "Button", true, false):
		var button := node_value as Button
		if button == null or not button.is_visible_in_tree() or not button.text.begins_with(button_text_prefix):
			continue
		if button.disabled == require_disabled:
			return button
	return null


func _industry_by_slot(slot: int) -> Dictionary:
	if slot < 0 or slot >= Game.state.industrial_operations.size():
		return {}
	return Game.state.industrial_operations[slot] as Dictionary


func _active_industry_for_activity(activity_id: String) -> Dictionary:
	for runtime_value in Game.state.industrial_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("activity_id", "")) == activity_id and String(runtime.get("status", "")) in ["RUNNING", "BLOCKED"]:
			return runtime
	return {}


func _production_line_field_snapshot(field: String) -> Dictionary:
	var result := {}
	for runtime_value in Game.state.industrial_operations:
		var runtime := runtime_value as Dictionary
		result[str(runtime.get("slot", -1))] = runtime.get(field, "")
	return result


func _production_line_ids(location_id: String, facility_id: String) -> Array[String]:
	var result: Array[String] = []
	for runtime_value in Game.state.production_lines_for(location_id, facility_id):
		var line_id := String((runtime_value as Dictionary).get("line_id", ""))
		if not line_id.is_empty():
			result.append(line_id)
	result.sort()
	return result


func _new_string_value(before: Array[String], after: Array[String]) -> String:
	for value in after:
		if not before.has(value):
			return value
	return ""


func _removed_string_value(before: Array[String], after: Array[String]) -> String:
	for value in before:
		if not after.has(value):
			return value
	return ""


func _manufacturing_installation_keys(state: SpaceGameState) -> Array[String]:
	var result: Array[String] = []
	for facility_id_value in state.facilities.keys():
		var facility_id := String(facility_id_value)
		var facility := state.facilities.get(facility_id, {}) as Dictionary
		for module_id_value in facility.get("installed_process_modules", []):
			result.append("%s|process|%s" % [facility_id, String(module_id_value)])
		for module_id_value in facility.get("installed_plugins", []):
			result.append("%s|plugin|%s" % [facility_id, String(module_id_value)])
	result.sort()
	return result


func _fund_available_facility_module_setup() -> void:
	for facility_id_value in Game.state.facilities.keys():
		var facility_id := String(facility_id_value)
		var facility_definition := Game.content.facilities.get(facility_id, {}) as Dictionary
		var installed: Array = (Game.state.facilities.get(facility_id, {}) as Dictionary).get("installed_modules", [])
		if installed.size() >= int(facility_definition.get("module_slots", 0)):
			continue
		for module_id_value in (facility_definition.get("upgrade_modules", {}) as Dictionary).keys():
			var module_id := String(module_id_value)
			if installed.has(module_id):
				continue
			var module := (facility_definition.get("upgrade_modules", {}) as Dictionary).get(module_id, {}) as Dictionary
			var requirements_met := true
			for requirement_value in module.get("requirements", []):
				if not Game.simulation.requirement_met(Game.state, requirement_value as Dictionary):
					requirements_met = false
					break
			if not requirements_met:
				continue
			for cost_value in module.get("costs", []):
				var cost := cost_value as Dictionary
				var item_id := String(cost.get("item", ""))
				var required := int(cost.get("quantity", 0))
				var available := Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
				if available < required:
					Game.state.add_item(item_id, required - available, SpaceGameState.MAIN_BASE_LOCATION_ID)


func _facility_module_target(control_name: String) -> Dictionary:
	for facility_id_value in Game.state.facilities.keys():
		var facility_id := String(facility_id_value)
		var definition := Game.content.facilities.get(facility_id, {}) as Dictionary
		for module_id_value in (definition.get("upgrade_modules", {}) as Dictionary).keys():
			var module_id := String(module_id_value)
			if control_name == "InstallFacilityModule_%s_%s" % [facility_id, module_id]:
				return {"facilityId":facility_id, "moduleId":module_id}
	return {}


func _advanced_power_target(control_name: String) -> Dictionary:
	for priority in ["CRITICAL", "HIGH", "NORMAL", "LOW"]:
		var suffix := "_%s" % priority
		if control_name.begins_with("AdvancedPowerPriority_") and control_name.ends_with(suffix):
			return {"facilityId":control_name.trim_prefix("AdvancedPowerPriority_").trim_suffix(suffix), "priority":priority}
	return {}


func _ship_module_target(control_name: String, prefix: String) -> Dictionary:
	for ship_value in Game.state.ships:
		var ship_id := String((ship_value as Dictionary).get("instance_id", ""))
		for module_id_value in Game.content.modules.keys():
			var module_id := String(module_id_value)
			if control_name == "%s%s_%s" % [prefix, ship_id, module_id]:
				return {"shipId":ship_id, "moduleId":module_id}
	return {}


func _removable_reinstall_target() -> Dictionary:
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		if not Game.state.ship_is_unassigned_docked(ship_id):
			continue
		var installed: Array = Game.state.ship_module_definition_ids(ship)
		for module_id_value in installed:
			var module_id := String(module_id_value)
			if installed.count(module_id) != 1 or not Game.simulation.module_design_available(Game.state, module_id):
				continue
			var definition := Game.content.modules.get(module_id, {}) as Dictionary
			if bool(definition.get("special_equipment", false)):
				continue
			var desired := installed.duplicate()
			desired.erase(module_id)
			var blueprint_id := String(ship.get("blueprint_id", ""))
			if Game.content.ship_loadout_error(blueprint_id, desired).is_empty():
				return {"shipId":ship_id, "moduleId":module_id}
	return {}


func _replacement_refit_target() -> Dictionary:
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		if not Game.state.ship_is_unassigned_docked(ship_id):
			continue
		var installed: Array = Game.state.ship_module_definition_ids(ship)
		for old_id_value in installed:
			var old_id := String(old_id_value)
			var old_definition := Game.content.modules.get(old_id, {}) as Dictionary
			for new_id_value in Game.content.modules.keys():
				var new_id := String(new_id_value)
				var new_definition := Game.content.modules.get(new_id, {}) as Dictionary
				if new_id == old_id or bool(new_definition.get("special_equipment", false)) \
					or not Game.simulation.module_design_available(Game.state, new_id) \
					or String(new_definition.get("slot", "")) != String(old_definition.get("slot", "")):
					continue
				var desired := installed.duplicate()
				desired[desired.find(old_id)] = new_id
				if Game.content.ship_loadout_error(String(ship.get("blueprint_id", "")), desired).is_empty():
					return {"shipId":ship_id, "oldModuleId":old_id, "newModuleId":new_id, "desiredModules":desired}
	return {}


func _new_variant_string_value(before: Array, after: Array) -> String:
	for value in after:
		if not before.has(value):
			return String(value)
	return ""


func _fund_ship_refit_setup(ship_id: String, desired_modules: Array) -> Dictionary:
	var ship := Game.state.ship_by_id(ship_id)
	if ship.is_empty():
		return {}
	var location_id := String(ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var costs: Dictionary = Game.simulation.loadout_fabrication_costs(desired_modules)
	for item_id_value in costs.keys():
		var item_id := String(item_id_value)
		var required := int(costs[item_id])
		var available := Game.state.available_item_quantity(item_id, location_id)
		if available < required:
			Game.state.add_item(item_id, required - available, location_id)
	return costs.duplicate(true)


func _active_refit_for_ship(ship_id: String) -> Dictionary:
	for project_value in Game.state.refit_projects:
		var project := project_value as Dictionary
		if String(project.get("ship_id", "")) == ship_id and String(project.get("status", "")) == "RUNNING":
			return project
	return {}


func _active_refit_matches(ship_id: String, desired_modules: Array) -> bool:
	var refit := _active_refit_for_ship(ship_id)
	var ship := Game.state.ship_by_id(ship_id)
	return not refit.is_empty() \
		and _same_string_multiset(refit.get("desired_definitions", []), desired_modules) \
		and String(ship.get("status", "")) == "REFITTING" \
		and String(ship.get("assignment", {}).get("type", "")) == "STARPORT_REFIT" \
		and String(ship.get("assignment", {}).get("project_id", "")) == String(refit.get("project_id", ""))


func _complete_active_refit_setup(ship_id: String) -> bool:
	var refit := _active_refit_for_ship(ship_id)
	if refit.is_empty():
		return false
	var project_id := String(refit.get("project_id", ""))
	var duration_ms := float(refit.get("fabrication_time_ms", 0.0)) + float(refit.get("installation_time_ms", 0.0))
	Game.advance_game_time(maxf(1000.0, duration_ms + 1000.0))
	var ship := Game.state.ship_by_id(ship_id)
	return not project_id.is_empty() \
		and not Game.state.refit_projects.any(func(value) -> bool: return String((value as Dictionary).get("project_id", "")) == project_id) \
		and String(ship.get("status", "")) == "DOCKED"


func _same_string_multiset(left: Array, right: Array) -> bool:
	var left_copy: Array[String] = []
	var right_copy: Array[String] = []
	for value in left:
		left_copy.append(String(value))
	for value in right:
		right_copy.append(String(value))
	left_copy.sort()
	right_copy.sort()
	return left_copy == right_copy


func _refit_cancelled_to_original(ship_id: String, project_id: String, original_modules: Array) -> bool:
	var ship := Game.state.ship_by_id(ship_id)
	return _active_refit_for_ship(ship_id).is_empty() \
		and not Game.state.refit_projects.any(func(value) -> bool: return String((value as Dictionary).get("project_id", "")) == project_id) \
		and String(ship.get("status", "")) == "DOCKED" \
		and (ship.get("assignment", {}) as Dictionary).is_empty() \
		and _same_string_multiset(Game.state.ship_module_definition_ids(ship), original_modules)


func _inventory_snapshot(item_ids: Array, location_id: String) -> Dictionary:
	var result := {}
	for item_id_value in item_ids:
		var item_id := String(item_id_value)
		result[item_id] = Game.state.item_quantity(item_id, location_id)
	return result


func _inventory_snapshot_matches(expected: Dictionary, location_id: String) -> bool:
	for item_id_value in expected.keys():
		var item_id := String(item_id_value)
		if Game.state.item_quantity(item_id, location_id) != int(expected[item_id]):
			return false
	return true


func _fund_activity_setup(activity_id: String, location_id: String, cycles: int) -> void:
	var activity := Game.content.activities.get(activity_id, {}) as Dictionary
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := String(cost.get("item", ""))
		var required := int(cost.get("quantity", 0)) * maxi(1, cycles)
		var available := Game.state.item_quantity(item_id, location_id)
		if not item_id.is_empty() and available < required:
			Game.state.add_item(item_id, required - available, location_id)


func _raise_factory_to_industrial_complex_setup(location_id: String, facility_id: String) -> bool:
	for target_level in [4, 5, 9, 10]:
		var current := int(Game.state.location_industry(location_id, facility_id).get("level", 0))
		if current >= target_level:
			continue
		var queued := Game.queue_scale_stage_upgrade(location_id, facility_id, 90) if target_level in [5, 10] \
			else Game.queue_facility_expansion(location_id, facility_id, target_level, 90)
		if not queued or not _fund_and_complete_latest_construction_setup(location_id):
			return false
	return int(Game.state.location_industry(location_id, facility_id).get("level", 0)) == 10 \
		and String(Game.state.location_industry(location_id, facility_id).get("scale_stage", "")) == "INDUSTRIAL_COMPLEX"


func _raise_factory_to_current_stage_cap_setup(location_id: String, facility_id: String) -> bool:
	var stage := Game.simulation.industry_scale_stage(Game.state, location_id, facility_id)
	var stage_max := int(Game.simulation.industry_scale_stage_definition(stage).get("max_level", 4))
	var current := int(Game.state.location_industry(location_id, facility_id).get("level", 0))
	if current < stage_max:
		if not Game.queue_facility_expansion(location_id, facility_id, stage_max, 90) \
			or not _fund_and_complete_latest_construction_setup(location_id):
			return false
	return int(Game.state.location_industry(location_id, facility_id).get("level", 0)) == stage_max \
		and Game.simulation.industry_scale_stage(Game.state, location_id, facility_id) == stage


func _fund_and_complete_latest_construction_setup(location_id: String) -> bool:
	var runtime := {}
	for index in range(Game.state.construction_operations.size() - 1, -1, -1):
		var candidate := Game.state.construction_operations[index] as Dictionary
		if String(candidate.get("location_id", "")) == location_id \
			and String(candidate.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"]:
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
	return Game.state.construction_history.any(func(row_value) -> bool:
		var row := row_value as Dictionary
		return String(row.get("project_id", "")) == project_id and String(row.get("status", "")) == "COMPLETE"
	)


func _changed_production_line_field(before: Dictionary, field: String, expected_value: String) -> String:
	for runtime_value in Game.state.industrial_operations:
		var runtime := runtime_value as Dictionary
		var slot := str(runtime.get("slot", -1))
		var current := str(runtime.get(field, ""))
		var previous := str(before.get(slot, ""))
		if current == previous:
			continue
		if expected_value.is_empty():
			if not current.is_empty():
				return slot
		elif current == expected_value:
			return slot
	return ""


func _newest_facility_expansion(facility_id: String) -> Dictionary:
	var newest := {}
	var newest_serial := -1
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("project_type", "")) != "FACILITY_EXPANSION" \
			or String(runtime.get("target_id", "")) != facility_id \
			or String(runtime.get("status", "")) not in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			continue
		var serial := int(runtime.get("started_at_ms", runtime.get("slot", 0)))
		if newest.is_empty() or serial >= newest_serial:
			newest = runtime
			newest_serial = serial
	return newest


func _newest_construction_type(project_type: String) -> Dictionary:
	for index in range(Game.state.construction_operations.size() - 1, -1, -1):
		var runtime := Game.state.construction_operations[index] as Dictionary
		if String(runtime.get("project_type", "")) == project_type \
			and String(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			return runtime
	return {}


func _capacity_project_types() -> Array[String]:
	return ["POWER_UPGRADE", "COOLING_UPGRADE", "STRUCTURE_UPGRADE", "STORAGE_UPGRADE", "BULK_STORAGE_UPGRADE", "COMPONENT_STORAGE_UPGRADE", "FLUID_STORAGE_UPGRADE", "SPECIAL_STORAGE_UPGRADE", "LOGISTICS_HUB_UPGRADE"]


func _newest_capacity_construction() -> Dictionary:
	for index in range(Game.state.construction_operations.size() - 1, -1, -1):
		var runtime := Game.state.construction_operations[index] as Dictionary
		if String(runtime.get("project_type", "")) in _capacity_project_types() \
			and String(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			return runtime
	return {}


func _construction_by_id(project_id: String) -> Dictionary:
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("project_id", "")) == project_id and String(runtime.get("status", "IDLE")) != "IDLE":
			return runtime
	return {}


func _newest_active_construction() -> Dictionary:
	var result := {}
	var latest := -1
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("activity_id", "")).is_empty() or String(runtime.get("status", "IDLE")) == "IDLE":
			continue
		var started := int(runtime.get("started_at_ms", runtime.get("slot", 0)))
		if result.is_empty() or started >= latest:
			result = runtime
			latest = started
	return result


func _active_construction_count() -> int:
	var count := 0
	for runtime_value in Game.state.construction_operations:
		if String((runtime_value as Dictionary).get("status", "IDLE")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			count += 1
	return count


func _roundtrip_state() -> SpaceGameState:
	return SpaceGameState.from_dictionary(Game.state.to_dictionary(), Game.content.domains.keys(), Game.content.regions)


func _expedition_is_recalled(ship_id: String, safe_node_index: int) -> bool:
	var runtime: Dictionary = Game.state.active_expedition
	var ship := Game.state.ship_by_id(ship_id)
	return String(runtime.get("status", "")) == "IDLE" \
		and String(runtime.get("activity_id", "")).is_empty() \
		and String(runtime.get("route_id", "")).is_empty() \
		and String(runtime.get("phase", "")) == "IDLE" \
		and int(runtime.get("node_index", -1)) == 0 \
		and is_zero_approx(float(runtime.get("node_progress_ms", -1.0))) \
		and int(runtime.get("safe_node_index", -1)) == safe_node_index \
		and (runtime.get("assigned_ship_ids", []) as Array).is_empty() \
		and (runtime.get("combat_state", {}) as Dictionary).is_empty() \
		and String(ship.get("status", "")) == "DOCKED" \
		and Game.state.ship_formation_id(ship_id) == SpaceGameState.DEFAULT_FORMATION_ID


func _persisted_recalled_expedition(ship_id: String, safe_node_index: int) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	var runtime: Dictionary = loaded.active_expedition
	var ship := loaded.ship_by_id(ship_id)
	return String(runtime.get("status", "")) == "IDLE" \
		and String(runtime.get("activity_id", "")).is_empty() \
		and String(runtime.get("route_id", "")).is_empty() \
		and String(runtime.get("phase", "")) == "IDLE" \
		and int(runtime.get("node_index", -1)) == 0 \
		and is_zero_approx(float(runtime.get("node_progress_ms", -1.0))) \
		and int(runtime.get("safe_node_index", -1)) == safe_node_index \
		and (runtime.get("assigned_ship_ids", []) as Array).is_empty() \
		and (runtime.get("combat_state", {}) as Dictionary).is_empty() \
		and String(ship.get("status", "")) == "DOCKED" \
		and loaded.ship_formation_id(ship_id) == SpaceGameState.DEFAULT_FORMATION_ID


func _persisted_construction_support(ship_id: String, location_id: String, expected_assigned: bool) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	var ship := loaded.ship_by_id(ship_id)
	var assignment: Dictionary = ship.get("assignment", {})
	if expected_assigned:
		return String(ship.get("status", "")) == "CONSTRUCTION_SUPPORT" \
			and String(assignment.get("type", "")) == "CONSTRUCTION_SUPPORT" \
			and String(assignment.get("location_id", "")) == location_id \
			and Game.simulation.location_construction_capacity(loaded, location_id) > 0.0
	return String(ship.get("status", "")) == "DOCKED" and assignment.is_empty()


func _megastructure_site_selected(megastructure_id: String, location_id: String) -> bool:
	if location_id.is_empty():
		return false
	var project := Game.state.megastructure_projects.get(megastructure_id, {}) as Dictionary
	return String(project.get("site_location_id", "")) == location_id \
		and int(project.get("phase_index", 0)) == 1 \
		and (project.get("phase_history", []) as Array).size() == 1 \
		and String(project.get("active_project_id", "")).is_empty()


func _persisted_megastructure_site(megastructure_id: String, location_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or location_id.is_empty():
		return false
	var project := loaded.megastructure_projects.get(megastructure_id, {}) as Dictionary
	return String(project.get("site_location_id", "")) == location_id \
		and int(project.get("phase_index", 0)) == 1 \
		and (project.get("phase_history", []) as Array).size() == 1 \
		and String(project.get("active_project_id", "")).is_empty()


func _persisted_production_line(slot: int, activity_id: String, expected_status: String, control_mode: String, priority: int) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or slot < 0 or slot >= loaded.industrial_operations.size():
		return false
	var runtime := loaded.industrial_operations[slot] as Dictionary
	if not activity_id.is_empty() and String(runtime.get("activity_id", "")) != activity_id:
		return false
	if not expected_status.is_empty() and String(runtime.get("status", "")) != expected_status:
		return false
	if not control_mode.is_empty() and String(runtime.get("control_mode", "")) != control_mode:
		return false
	if priority >= 0 and int(runtime.get("priority", -1)) != priority:
		return false
	return not String(runtime.get("line_id", "")).is_empty()


func _persisted_production_line_by_id(line_id: String, activity_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or line_id.is_empty():
		return false
	var runtime := loaded.production_line_by_id(line_id)
	return not runtime.is_empty() and String(runtime.get("activity_id", "")) == activity_id \
		and not (runtime.get("input_commitments", {}) as Dictionary).is_empty()


func _persisted_facility_expansion(project_id: String, facility_id: String, target_level: int) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or project_id.is_empty():
		return false
	for runtime_value in loaded.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("project_id", "")) != project_id:
			continue
		return String(runtime.get("project_type", "")) == "FACILITY_EXPANSION" \
			and String(runtime.get("target_id", "")) == facility_id \
			and int(runtime.get("target_level", -1)) == target_level \
			and not (runtime.get("material_plan", {}) as Dictionary).is_empty()
	return false


func _persisted_dynamic_construction(project_id: String, project_type: String, target_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or project_id.is_empty() or project_type.is_empty():
		return false
	for runtime_value in loaded.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("project_id", "")) != project_id:
			continue
		return String(runtime.get("project_type", "")) == project_type \
			and (target_id.is_empty() or String(runtime.get("target_id", "")) == target_id) \
			and not (runtime.get("material_plan", {}) as Dictionary).is_empty()
	return false


func _persisted_construction_matches(project_id: String, activity_id: String, expected_status: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	for runtime_value in loaded.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("project_id", "")) != project_id:
			continue
		if not activity_id.is_empty() and String(runtime.get("activity_id", "")) != activity_id:
			return false
		var status := String(runtime.get("status", ""))
		return status in ["RUNNING", "BLOCKED", "QUEUED"] if expected_status == "ACTIVE" else (expected_status.is_empty() or status == expected_status)
	return false


func _persisted_construction_priority(project_id: String, priority: int) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	for runtime_value in loaded.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("project_id", "")) == project_id:
			return int(runtime.get("priority", -1)) == priority
	return false


func _persisted_cancel_history(project_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	var matches := 0
	for history_value in loaded.construction_history:
		var history := history_value as Dictionary
		if String(history.get("project_id", "")) == project_id and String(history.get("status", "")) == "CANCELLED":
			matches += 1
	return matches == 1


func _persisted_research_matches(project_id: String, route_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	return String(loaded.research.get("project_id", "")) == project_id \
		and (route_id.is_empty() or String(loaded.research.get("route_id", "")) == route_id)


func _persisted_research_status(project_id: String, expected_status: String) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null and String(loaded.research.get("project_id", "")) == project_id \
		and String(loaded.research.get("status", "")) == expected_status


func _persisted_survey_matches(target_id: String, target_state: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	return String(loaded.survey_mission.get("status", "")) == "RUNNING" \
		and String(loaded.survey_mission.get("target", "")) == target_id \
		and String(loaded.survey_mission.get("target_state", "")) == target_state


func _newest_shipyard_order(plan_id: String) -> Dictionary:
	for index in range(Game.state.shipyard_queue.size() - 1, -1, -1):
		var order := Game.state.shipyard_queue[index] as Dictionary
		if String(order.get("plan_id", "")) == plan_id:
			return order
	return {}


func _shipyard_plan_ids(state_value: SpaceGameState) -> Array[String]:
	var result: Array[String] = []
	for order_value in state_value.shipyard_queue:
		result.append(String((order_value as Dictionary).get("plan_id", "")))
	return result


func _shipyard_has_project(state_value: SpaceGameState, project_id: String) -> bool:
	return state_value.shipyard_queue.any(func(order_value) -> bool:
		return String((order_value as Dictionary).get("project_id", "")) == project_id
	)


func _persisted_shipyard_order(project_id: String, plan_id: String, quantity: int) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	for order_value in loaded.shipyard_queue:
		var order := order_value as Dictionary
		if String(order.get("project_id", "")) == project_id:
			return String(order.get("plan_id", "")) == plan_id and int(order.get("quantity_total", 0)) == quantity
	return false


func _persisted_shipyard_order_index(project_id: String, expected_index: int) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or expected_index < 0 or expected_index >= loaded.shipyard_queue.size():
		return false
	return String((loaded.shipyard_queue[expected_index] as Dictionary).get("project_id", "")) == project_id


func _persisted_shipyard_project_absent(project_id: String) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null and not project_id.is_empty() and not _shipyard_has_project(loaded, project_id)


func _persisted_ship_fleet_assignment(ship_id: String, formation_id: String) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null and loaded.ship_formation_id(ship_id) == formation_id \
		and loaded.formation_ship_ids(formation_id).has(ship_id)


func _persisted_expedition(route_id: String, ship_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	return String(loaded.active_expedition.get("status", "")) == "RUNNING" \
		and String(loaded.active_expedition.get("route_id", "")) == route_id \
		and (loaded.active_expedition.get("assigned_ship_ids", []) as Array).has(ship_id) \
		and String(loaded.ship_by_id(ship_id).get("status", "")) == "EXPEDITION"


func _persisted_refit_matches(project_id: String, ship_id: String, desired_modules: Array) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or project_id.is_empty():
		return false
	for project_value in loaded.refit_projects:
		var project := project_value as Dictionary
		if String(project.get("project_id", "")) != project_id:
			continue
		var ship := loaded.ship_by_id(ship_id)
		return String(project.get("ship_id", "")) == ship_id \
			and String(project.get("status", "")) == "RUNNING" \
			and _same_string_multiset(project.get("desired_definitions", []), desired_modules) \
			and not (project.get("consumed_bom", {}) as Dictionary).is_empty() \
			and String(ship.get("status", "")) == "REFITTING" \
			and String(ship.get("assignment", {}).get("project_id", "")) == project_id
	return false


func _persisted_refit_cancelled(ship_id: String, project_id: String, original_modules: Array) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	for project_value in loaded.refit_projects:
		if String((project_value as Dictionary).get("project_id", "")) == project_id:
			return false
	var ship := loaded.ship_by_id(ship_id)
	return String(ship.get("status", "")) == "DOCKED" \
		and (ship.get("assignment", {}) as Dictionary).is_empty() \
		and _same_string_multiset(loaded.ship_module_definition_ids(ship), original_modules)


func _persisted_advanced_power_priority(facility_id: String, priority: String) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null and not facility_id.is_empty() \
		and String(loaded.energy_system.get("advanced_priorities", {}).get(facility_id, "")) == priority


func _persisted_fleet_formation_field(field: String, expected_value: String) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null and String(loaded.fleet_logistics_runtime("expedition").get("formation", {}).get(field, "")) == expected_value


func _persisted_fleet_supply_plan(item_id: String, target_quantity: int) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null and int(loaded.fleet_logistics_runtime("expedition").get("supply_plan", {}).get(item_id, -1)) == target_quantity


func _persisted_fleet_supply_transfer(item_id: String, base_quantity: int, fleet_quantity: int) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null \
		and loaded.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) == base_quantity \
		and loaded.fleet_supply_quantity(item_id, "expedition") == fleet_quantity


func _persisted_retreat_policy(mode: String, threshold: float) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	var policy: Dictionary = loaded.fleet_logistics_runtime("expedition").get("formation", {}).get("retreat_policy", {})
	return String(policy.get("mode", "")) == mode and is_equal_approx(float(policy.get("threshold", -1.0)), threshold)


func _persisted_combat_zone(ship_id: String, zone: String) -> bool:
	var loaded := _roundtrip_state()
	return loaded != null and String(loaded.fleet_logistics_runtime("expedition").get("formation", {}).get("ship_zones", {}).get(ship_id, "")) == zone


func _persisted_combat_action(activity_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or activity_id.is_empty():
		return false
	var runtime: Dictionary = loaded.active_expedition
	var ship_ids: Array = runtime.get("assigned_ship_ids", [])
	if String(runtime.get("status", "")) != "RUNNING" or String(runtime.get("activity_id", "")) != activity_id or ship_ids.is_empty():
		return false
	for ship_id_value in ship_ids:
		if String(loaded.ship_by_id(String(ship_id_value)).get("status", "")) != "EXPEDITION":
			return false
	return true


func _persisted_manufacturing_module(facility_id: String, module_id: String, module_kind: String, expected_installed: bool, expected_stock: int) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or facility_id.is_empty() or module_id.is_empty() or module_kind not in ["process", "plugin"]:
		return false
	var field := "installed_process_modules" if module_kind == "process" else "installed_plugins"
	var installed: Array = (loaded.facilities.get(facility_id, {}) as Dictionary).get(field, [])
	return installed.has(module_id) == expected_installed \
		and int(loaded.manufacturing_module_inventory.get(module_id, 0)) == expected_stock


func _active_megastructure_runtime_count(megastructure_id: String) -> int:
	var count := 0
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("megastructure_id", "")) == megastructure_id \
			and String(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			count += 1
	return count


func _persisted_megastructure_phase(active_project_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or active_project_id.is_empty():
		return false
	var project := loaded.megastructure_projects.get("stellar_energy", {}) as Dictionary
	if String(project.get("active_project_id", "")) != active_project_id:
		return false
	var matches := 0
	for runtime_value in loaded.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("megastructure_id", "")) == "stellar_energy" \
			and String(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			matches += 1
	return matches == 1


func _persisted_megastructure_has_no_active_phase(megastructure_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	var project := loaded.megastructure_projects.get(megastructure_id, {}) as Dictionary
	if not String(project.get("active_project_id", "")).is_empty():
		return false
	for runtime_value in loaded.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("megastructure_id", "")) == megastructure_id \
			and String(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			return false
	return true


func _persisted_logistics_policy(item_id: String, expected_present: bool) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or item_id.is_empty():
		return false
	var policies: Dictionary = loaded.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {})
	return policies.has(item_id) == expected_present


func _persisted_logistics_pause(route_id: String, expected_paused: bool) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null:
		return false
	var service: Dictionary = loaded.logistics_network.get("services", {}).get(route_id, {})
	return (String(service.get("status", "ACTIVE")) == "PAUSED") == expected_paused


func _service_field_snapshot(field: String) -> Dictionary:
	var result := {}
	for route_id_value in Game.state.logistics_network.get("services", {}).keys():
		var route_id := String(route_id_value)
		result[route_id] = (Game.state.logistics_network.get("services", {}).get(route_id, {}) as Dictionary).get(field, "")
	return result


func _changed_service_field(before: Dictionary, field: String, expected_value: String) -> String:
	for route_id_value in Game.state.logistics_network.get("services", {}).keys():
		var route_id := String(route_id_value)
		var current := String((Game.state.logistics_network.get("services", {}).get(route_id, {}) as Dictionary).get(field, ""))
		if current == expected_value and String(before.get(route_id, "")) != current:
			return route_id
	return ""


func _persisted_logistics_service(route_id: String, mode_id: String, priority_id: String, assigned_ship_ids: Array) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or route_id.is_empty():
		return false
	var service: Dictionary = loaded.logistics_network.get("services", {}).get(route_id, {})
	if service.is_empty() or String(service.get("transport_mode_id", "")) != mode_id:
		return false
	if not priority_id.is_empty() and String(service.get("priority_strategy", "")) != priority_id:
		return false
	var loaded_ship_ids: Array = service.get("assigned_ship_ids", [])
	if loaded_ship_ids.size() != assigned_ship_ids.size():
		return false
	for ship_id_value in assigned_ship_ids:
		if not loaded_ship_ids.has(ship_id_value):
			return false
	return true


func _persisted_logistics_assignment(ship_id: String, service_id: String, route_id: String) -> bool:
	var loaded := _roundtrip_state()
	if loaded == null or ship_id.is_empty() or service_id.is_empty() or route_id.is_empty():
		return false
	var ship := loaded.ship_by_id(ship_id)
	var assignment: Dictionary = ship.get("assignment", {})
	var service: Dictionary = loaded.logistics_network.get("services", {}).get(route_id, {})
	return String(assignment.get("domain", "")) == "logistics" \
		and String(assignment.get("service_id", "")) == service_id \
		and String(assignment.get("route_id", "")) == route_id \
		and (service.get("assigned_ship_ids", []) as Array).has(ship_id)


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
		if normalized.contains(String(needle_value).to_lower()):
			return true
	return false


func _write_evidence() -> void:
	var verified_ids: Array[String] = []
	var rows: Array[Dictionary] = []
	var action_ids: Array = coverage.keys()
	action_ids.sort()
	for action_id_value in action_ids:
		var action_id := String(action_id_value)
		var row := (coverage[action_id] as Dictionary).duplicate(true)
		row["fourCaseVerified"] = _quadrants_true(row)
		if bool(row["fourCaseVerified"]):
			verified_ids.append(action_id)
		rows.append(row)
	var payload := {
		"schemaVersion":1,
		"coverageDefinition":"Four-case runtime UI evidence requires Success, player-visible Failure, authoritative Consequence, and Persistence for the same core action.",
		"coverageDenominator":coverage.size(),
		"fourCaseVerifiedCount":verified_ids.size(),
		"fourCaseCoverage":"%d/%d" % [verified_ids.size(), coverage.size()],
		"fourCaseVerifiedActions":verified_ids,
		"scenarioBoundary":"Golden Scenario checkpoints were generated by normal Domain commands and simulation, then activated only as invariant-valid starting checkpoints. They are not fresh-save Journey evidence.",
		"persistenceBoundary":"Ordinary gameplay-action persistence evidence is DOMAIN_SERIALIZE_DESERIALIZE_ONLY. SAVE_GAME is the sole exception and imports only a passed isolated APPDATA LocalSave writer/reader artifact that explicitly proves visible SaveButton disk write, startup identity/revision, and restored UI-created consequence.",
		"staticMappingCountedAsCoverage":false,
		"directRuntimeStatusAssignmentUsed":false,
		"directGameplayCommandUsedByTest":true,
		"directTargetGameplayCommandUsedByTest":false,
		"domainSetupBoundary":"Legal Golden checkpoints are activated through GameplayScenarioBuilder. Bounded setup uses invariant-preserving inventory funding for Construction/module/refit/fleet-transfer prerequisites, and ADD_PRODUCTION_LINE additionally uses normal facility/scale Construction completion to form INDUSTRIAL_COMPLEX. Every target action is still submitted through a visible MainScene control; this is not Fresh Save Journey evidence.",
		"actions":rows
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EVIDENCE_PATH.get_base_dir()))
	var file := FileAccess.open(EVIDENCE_PATH, FileAccess.WRITE)
	if file == null:
		_check(false, "runtime action evidence file opens for writing")
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.close()
	print("UI_ACTION_FOUR_CASE: %d/%d" % [verified_ids.size(), coverage.size()])


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: UI action four-case evidence verifies %d of 57 core actions through real MainScene controls" % EXPECTED_FOUR_CASE_ACTIONS.size())
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
