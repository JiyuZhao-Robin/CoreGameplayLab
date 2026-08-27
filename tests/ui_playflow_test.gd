extends Node

const MainScene := preload("res://src/ui/main.tscn")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	var main: Control = MainScene.instantiate()
	add_child(main)
	await _redraw()
	var initial_guidance: Dictionary = Game.guidance_snapshot()
	_check(["goal_id", "step_id", "page", "section", "location_id", "focus_entity_id", "reason", "acquisition_path"].all(func(key): return initial_guidance.has(key)) and not str(initial_guidance.get("page", "")).is_empty(), "Guidance exposes an actionable page, section, location, focus entity, reason and acquisition path")

	_check(main.find_child("SystemMap2D", true, false) != null, "formal UI contains the interactive 2D System Map")
	for page_id in ["overview", "system_map", "location", "frontier", "industry", "research", "fleet", "expedition"]:
		_check(main.find_child("Navigation_%s" % page_id, true, false) != null, "navigation exposes %s" % page_id)
	_check(main.find_child("Navigation_megastructure", true, false) != null and Game.content.megastructures.size() == 1 and Game.content.megastructures.get("stellar_energy", {}).get("phases", []).size() == 8, "the UI exposes exactly one eight-phase single-system Megastructure endgame")

	var fleet_nav := main.find_child("Navigation_fleet", true, false) as Button
	_press(fleet_nav)
	await _redraw()
	for section_id in ["roster", "readiness", "shipyard", "archive"]:
		_check(main.find_child("FleetSection_%s" % section_id, true, false) != null, "Fleet exposes %s workspace" % section_id)
	var ship_id := String((Game.state.ships[0] as Dictionary).get("instance_id", ""))
	var assign_mining := main.find_child("AssignMining_%s" % ship_id, true, false) as Button
	_check(assign_mining != null and not assign_mining.disabled, "starter ship can be assigned through Fleet UI")
	_press(assign_mining)
	await _redraw()
	_check(Game.state.ship_fleet_domain(ship_id) == "mining", "Fleet UI changes the real ship assignment")

	var readiness := main.find_child("FleetSection_readiness", true, false) as Button
	_press(readiness)
	await _redraw()
	var retreat_label := _find_label(main, "撤退策略")
	_check(retreat_label != null and retreat_label.size.x >= 100.0 and retreat_label.size.y < 60.0, "Fleet retreat policy keeps a horizontal readable layout")
	_check(_has_text_fragment(main, "前列") and _has_text_fragment(main, "中列") and _has_text_fragment(main, "后列"), "Fleet UI exposes the translated three-line formation")

	var mining_nav := main.find_child("Navigation_frontier", true, false) as Button
	_press(mining_nav)
	await _redraw()
	var start_mining := main.find_child("StartMining_earth_resource_cluster_prospect", true, false) as Button
	if start_mining == null or start_mining.disabled:
		var mining_activity := Game.content.activities.get("extract_earth_mixed_ore", {}) as Dictionary
		print("UI_PLAYFLOW_DIAGNOSTIC mining_button=", start_mining, " disabled=", start_mining.disabled if start_mining != null else "missing", " can_start=", Game.can_start_activity("mining", mining_activity), " assignment=", Game.state.ship_fleet_domain(ship_id), " status=", Game.state.ship_by_id(ship_id).get("status", ""), " notice=", Game.last_notice)
		for diagnostic_button_value in main.find_children("*", "Button", true, false):
			var diagnostic_button := diagnostic_button_value as Button
			if "采矿" in diagnostic_button.text or "Mining" in diagnostic_button.name:
				print("UI_PLAYFLOW_BUTTON name=", diagnostic_button.name, " text=", diagnostic_button.text, " disabled=", diagnostic_button.disabled)
	_check(start_mining != null and not start_mining.disabled, "Mining operation is startable through the UI")
	_press(start_mining)
	await _redraw()
	_check(_has_running_mining(), "Mining UI starts the real extraction runtime")
	Game.simulation.advance(Game.state, 10001.0)
	Game.state_changed.emit()
	await _redraw()
	_check(Game.state.item_quantity("mixed_raw_ore", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 2, "UI-started mining produces real inventory")
	for operation_value in Game.state.mining_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("site_id", "")) == "earth_resource_cluster_prospect":
			operation["status"] = "INTEGRATED"
	Game.state.extraction_network_states["earth_extraction_network"].merge({"unlocked":true, "status":"RUNNING", "integrated_site_ids":["earth_resource_cluster_prospect"]}, true)
	_check(bool(main.call("_has_active_mining")), "Guide recognizes an integrated extraction network as active production")
	_check("启动近地永久采集点" not in String(main.call("_next_flow_step")), "Guide never regresses to the starter mining instruction after the first completed extraction cycle")
	Game.state.extraction_network_states["earth_extraction_network"]["status"] = "IDLE"

	var industry_nav := main.find_child("Navigation_industry", true, false) as Button
	_press(industry_nav)
	await _redraw()
	var start_separation := main.find_child("StartIndustry_separate_iron_ore", true, false) as Button
	_check(start_separation != null and not start_separation.disabled, "first industrial recipe is startable through the UI")
	_press(start_separation)
	await _redraw()
	_check(String(Game.runtime_for_domain("industry").get("activity_id", "")) == "separate_iron_ore", "Industry UI starts the real production runtime")
	var remaining_feedstock := Game.state.item_quantity("mixed_raw_ore", SpaceGameState.MAIN_BASE_LOCATION_ID)
	Game.state.remove_item("mixed_raw_ore", remaining_feedstock, SpaceGameState.MAIN_BASE_LOCATION_ID)
	Game.simulation.advance(Game.state, 1000.0)
	Game.state_changed.emit()
	await _redraw()
	_check(_has_text_fragment(main, "首要阻塞") and _has_text_fragment(main, "混合粗矿不足"), "Industry UI renders the core structured blocker instead of an unrelated free-form error")

	var workshop_runtime: Dictionary = Game.runtime_for_domain("industry")
	if not workshop_runtime.is_empty():
		Game.stop_industry_operation(int(workshop_runtime.get("slot", 0)))
	var existing_iron := Game.state.item_quantity("iron_ingot", SpaceGameState.MAIN_BASE_LOCATION_ID)
	if existing_iron > 0:
		Game.state.remove_item("iron_ingot", existing_iron, SpaceGameState.MAIN_BASE_LOCATION_ID)
	Game.state.completed_activities["assemble_frame"] = 1
	Game.state.add_item("structural_frame", 1, SpaceGameState.MAIN_BASE_LOCATION_ID)
	Game.state_changed.emit()
	await _redraw()
	_check("4 铁锭" in String(main.call("_next_flow_step")) and String(main.call("_next_flow_industry_section")) == "production", "guide states the exact Orbital Foundry shortage and keeps the player in Production")
	Game.state.add_item("iron_ingot", 4, SpaceGameState.MAIN_BASE_LOCATION_ID)
	Game.state_changed.emit()
	await _redraw()
	var next_step_button := main.find_child("NextStepCTA", true, false) as Button
	_press(next_step_button)
	await _redraw()
	_check(String(main.get("_industry_section")) == "construction", "guide CTA switches directly to the Construction workspace once Foundry materials are ready")
	var start_foundry := main.find_child("StartConstruction_build_orbital_foundry", true, false) as Button
	_check(start_foundry != null and not start_foundry.disabled and _has_text_fragment(main, "建设轨道铸造厂"), "Orbital Foundry construction card uses the same name as the guide")
	var premature_electronics := main.find_child("StartConstruction_build_electronics_facility", true, false) as Button
	_check(premature_electronics != null and premature_electronics.disabled, "construction cannot bypass the missing sponsor facility to build High-Energy Systems early")
	_press(start_foundry)
	Game.simulation.advance(Game.state, 35000.0)
	_check("orbital_foundry" in Game.state.facilities, "guide-provided Foundry materials complete the real construction project")

	var expedition_nav := main.find_child("Navigation_expedition", true, false) as Button
	_press(expedition_nav)
	await _redraw()
	_check(main.find_child("StartRoute_lunar_route", true, false) != null, "Expedition route has a formal UI action")
	_check(_has_text_fragment(main, "指挥容量") and _has_text_fragment(main, "货舱"), "Expedition UI exposes translated readiness and fleet capacity")

	# A blocked R&D Field Test must override the broad goal list with one exact,
	# executable Guide instruction and route the CTA to the Expedition workspace.
	Game.state.facilities["research_complex"] = {"status":"ACTIVE", "level":1}
	Game.state.research = SpaceGameState.empty_research_program()
	Game.state.research.merge({
		"project_id":"research_advanced_propulsion",
		"status":"BLOCKED",
		"stage_id":"field_test",
		"blocker":{
			"primary_reason":"FIELD_TEST_REQUIRED",
			"domain":"research",
			"requirement":{"type":"route_complete", "id":"propulsion_proving_route"}
		}
	}, true)
	var research_guide := String(main.call("_next_flow_step"))
	_check("原型推进实测航线" in research_guide and "倒计时不能替代" in research_guide, "Guide names the exact real R&D Field Test instead of suggesting more waiting")
	_check(String(main.call("_next_flow_page")) == "expedition", "Guide routes a blocked R&D Field Test directly to Expedition")
	var prototype_guidance := String(main.call("_research_blocker_guidance", {"primary_reason":"OPERATING_CONDITION", "requirement":{"type":"activity_complete", "id":"fabricate_propulsion_test_article"}}))
	_check("制造原型推进室" in prototype_guidance and "真实工业产线" in prototype_guidance, "Guide names the exact industrial prototype recipe at an R&D Material/Component Gate")
	Game.state.research["blocker"] = {"primary_reason":"OPERATING_CONDITION", "domain":"research", "requirement":{"type":"activity_complete", "id":"fabricate_propulsion_test_article"}}
	_check(String(main.call("_next_flow_page")) == "industry", "Guide routes an R&D prototype manufacturing gate directly to Industry")
	var roadmap := String(main.call("_research_roadmap_text", Game.content.research_projects["research_advanced_propulsion"], -1))
	_check("钛合金" in roadmap and "制造原型推进室" in roadmap and "原型推进实测航线" in roadmap, "R&D roadmap reveals concrete future supply, prototype and Field Test demands before program start")
	_finish()


func _press(button: Button) -> void:
	if button == null:
		return
	button.pressed.emit()


func _redraw() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.21).timeout
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	await get_tree().process_frame


func _has_running_mining() -> bool:
	for operation_value in Game.state.mining_operations:
		if String((operation_value as Dictionary).get("status", "")) == "RUNNING":
			return true
	return false


func _find_label(node: Node, text_value: String) -> Label:
	if node is Label and String(node.text) == text_value:
		return node as Label
	for child in node.get_children():
		var found := _find_label(child, text_value)
		if found != null:
			return found
	return null


func _has_text_fragment(node: Node, fragment: String) -> bool:
	if node is Label and fragment in String(node.text):
		return true
	if node is RichTextLabel and fragment in String(node.text):
		return true
	if node is Button and fragment in String(node.text):
		return true
	for child in node.get_children():
		if _has_text_fragment(child, fragment):
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: UI-driven core playflow and product navigation")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
