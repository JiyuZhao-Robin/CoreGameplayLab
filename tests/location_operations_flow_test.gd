extends SceneTree

var failures: Array[String] = []
var game: Node
var main: Control


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.reset_game()
	game.set_process(false)
	root.size = Vector2i(1920, 1080)
	root.get_node("I18n").set_locale("zh_CN")
	main = (load("res://src/ui/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await _settle()
	var lunar := main.find_child("Location_lunar_space", true, false) as Button
	_check(lunar != null and not lunar.disabled, "charted next-region target is inspectable before discovery")
	if lunar != null:
		lunar.pressed.emit()
	await _settle()
	var dashboard := main.find_child("LocationOperationsWorkspace", true, false) as Control
	_check(dashboard != null and dashboard.is_visible_in_tree(), "map route opens the real single-page dashboard")
	_check(main.find_child("LocationTab_resources", true, false) == null, "resource and industry no longer require nested tabs")
	var initial: Dictionary = game.location_operations_snapshot("lunar_space")
	_check(initial.get("resources", []).is_empty() and initial.get("environment", {}).is_empty() and initial.get("environment_effects", {}).is_empty(), "unknown target reveals no exact resource or environmental values")
	var world_count: int = game.state.factory_worlds.size()
	var ship_id := str(game.state.ships[0].get("instance_id", ""))
	var assign := main.find_child("LocationAssignSurveyShip", true, false) as Button
	_check(assign != null and assign.is_visible_in_tree() and not assign.disabled, "fresh starter survey vessel has an actionable formation assignment")
	if assign != null and not assign.disabled:
		assign.pressed.emit()
	await _settle()
	_check(game.state.ship_formation_id(ship_id) == SpaceGameState.DEFAULT_FORMATION_ID, "dashboard assignment uses the existing authoritative formation command")
	var start := main.find_child("LocationStartSurvey", true, false) as Button
	_check(start != null and not start.disabled, "starter vessel can detect the Moon through the visible survey button")
	var fuel_before: int = game.state.item_quantity("chemical_propellant", "earth_orbit")
	if start != null and not start.disabled:
		start.pressed.emit()
	await _settle()
	_check(str(game.state.survey_mission.get("status", "")) == "RUNNING" and game.state.item_quantity("chemical_propellant", "earth_orbit") == fuel_before - 1, "survey start reserves the vessel and pays exact detection fuel")
	var rejected_before := JSON.stringify(game.state.survey_mission)
	_check(not game.start_survey_mission("lunar_space", "DETECTED", [ship_id]) and JSON.stringify(game.state.survey_mission) == rejected_before, "a concurrent mission is rejected without replacing committed progress")
	game._simulation_accumulator_ms = 0.0
	game._process(0.5)
	main.set("_last_refresh_ms", 0)
	main.call("_process", 0.0)
	await _settle()
	var live: Dictionary = game.location_operations_snapshot("lunar_space")
	var origin_survey: Dictionary = game.location_operations_snapshot("earth_orbit")["survey"]
	_check(bool(origin_survey["active"]) and str(origin_survey["target_location_id"]) == "lunar_space", "survey origin exposes the active mission and its actual destination")
	_check(float(live.get("survey", {}).get("progress", 0.0)) > 0.0 and main.find_child("LocationOperationsWorkspace", true, false) == dashboard, "normal runtime notification refreshes survey progress without replacing the dashboard")
	var detection_report: Dictionary = game.advance_game_time(float(game.state.survey_mission.get("duration_ms", 0.0)))
	var detected: Dictionary = game.location_operations_snapshot("lunar_space")
	_check(str(detected.get("survey_state", "")) == "DETECTED" and not detected.get("resources", []).is_empty(), "detection reveals coarse resource signals before Factory initialization")
	var first_signal: Dictionary = detected.get("resources", [{}])[0]
	_check(not first_signal.has("grade") and not first_signal.has("potential_per_hour") and detected.get("environment_effects", {}).is_empty(), "detected signals do not leak exact grade, yield or environment multipliers")
	_check(game.state.factory_worlds.size() == world_count and not bool(game.state.regions.get("lunar_space", false)), "survey knowledge creates neither infrastructure nor a strategic-route unlock")
	_check(detection_report.get("events", []).filter(func(e): return str(e.get("type", "")) == "SurveyMissionCompleted").size() == 1 and game.state.ship_is_docked(ship_id), "completion emits one event and returns the survey vessel")
	# Complete the next tier with a material fixture. First prove the UI-bound
	# command does not grant the staging package when those materials are missing.
	_check(not game.survey_mission_availability("lunar_space", "SURVEYED", [ship_id]).get("allowed", true), "industrial survey requires its physical deployment package")
	var costs: Dictionary = game.simulation.survey_mission_costs("SURVEYED")
	for item_id in costs:
		game.state.add_item(str(item_id), int(costs[item_id]) + 10, "earth_orbit")
	_check(game.start_survey_mission("lunar_space", "SURVEYED", [ship_id]), "funded survey starts from the existing application command")
	game.advance_game_time(float(game.state.survey_mission.get("duration_ms", 0.0)))
	var surveyed: Dictionary = game.simulation.location_intelligence(game.state, "lunar_space")
	_check(str(surveyed.get("survey_state", "")) == "SURVEYED" and not surveyed.get("resources", []).is_empty() and not (surveyed["resources"][0] as Dictionary).has("footprint"), "survey reveals useful grade/potential while exact footprints remain a deep-survey reward")
	_check(game.initialize_surveyed_factory_world("lunar_space"), "surveyed region can initialize its real physical Factory")
	var world_ids: Array[String] = game.factory_world_ids_for_location("lunar_space")
	var world: Dictionary = game.state.factory_worlds.get(world_ids[0], {})
	_check(world.get("entities", {}).is_empty(), "Factory initialization does not grant free productive buildings")
	var fields: Dictionary = world.get("resource_fields", {})
	var resources_match := true
	for profile in surveyed.get("resources", []):
		var field: Dictionary = fields.get(str(profile.get("resource_field_id", "")), {})
		resources_match = resources_match and str(field.get("resource_id", "")) == str(profile.get("resource_type", "")) and is_equal_approx(float(field.get("grade", 0.0)), float(profile.get("grade", 0.0)))
	_check(resources_match, "survey preview and initialized fields share a single deterministic blueprint")
	# Direct content fixture equips deep-survey capability; gameplay acquisition
	# continues through existing ship assembly/research rather than free unlocks.
	game.state.ship_by_id(ship_id)["modules"].append("deep_survey_system")
	for item_id in game.simulation.survey_mission_costs("DEEP_SURVEYED"):
		game.state.add_item(str(item_id), 20, "earth_orbit")
	_check(game.start_survey_mission("lunar_space", "DEEP_SURVEYED", [ship_id]), "equipped survey vessel starts the final intelligence tier")
	game.advance_game_time(float(game.state.survey_mission.get("duration_ms", 0.0)))
	var deep: Dictionary = game.simulation.location_intelligence(game.state, "lunar_space")
	_check(str(deep.get("survey_state", "")) == "DEEP_SURVEYED" and (deep.get("resources", [{}])[0] as Dictionary).has("footprint"), "deep survey reveals exact resource footprints")
	await _test_navigation_and_geometry(world_ids[0])
	await _test_environment_and_task_projection(world_ids[0])
	main.queue_free()
	await process_frame
	var tokens = load("res://src/ui/ui_theme_tokens.gd")
	root.set_meta(tokens.UI_SCALE_SESSION_META, 2.0)
	main = (load("res://src/ui/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.call("_open_location", "earth_orbit")
	await _settle()
	var large_dashboard := main.find_child("LocationOperationsWorkspace", true, false) as Control
	var large_footer := main.find_child("LocationEnvironment", true, false) as Control
	var viewport_bounds := Rect2(Vector2.ZERO, Vector2(1920, 1080))
	var page := (main.get("_page_controls") as Dictionary)["location"] as Control
	_check(viewport_bounds.encloses(main.get_global_rect()), "200%% Location does not expand the whole game beyond its fixed logical screen: %s" % main.get_global_rect())
	var command_dock := main.find_child("CommandDockSurface", true, false) as Control
	_check(command_dock != null and viewport_bounds.encloses(command_dock.get_global_rect()), "200%% keeps the bottom command dock on screen: %s" % (command_dock.get_global_rect() if command_dock != null else Rect2()))
	_check(viewport_bounds.encloses(large_dashboard.get_global_rect()) and page.get_global_rect().encloses(large_dashboard.get_global_rect()) and page.get_global_rect().encloses(large_footer.get_global_rect()), "200%% accessibility retains dashboard and environmental actions inside the real game shell: %s / %s" % [large_dashboard.get_global_rect(), page.get_global_rect()])
	main.queue_free()
	await process_frame
	root.remove_meta(tokens.UI_SCALE_SESSION_META)
	for failure in failures:
		push_error(failure)
	print("LOCATION_OPERATIONS_FLOW_PASS" if failures.is_empty() else "LOCATION_OPERATIONS_FLOW_FAIL")
	quit(0 if failures.is_empty() else 1)


func _test_navigation_and_geometry(world_id: String) -> void:
	main.call("_open_location", "lunar_space")
	await _settle()
	var snapshot: Dictionary = game.location_operations_snapshot("lunar_space")
	_check(not snapshot.get("environment_effects", {}).is_empty(), "surveyed dashboard explains authoritative environment effects")
	main.call("_on_location_operations_action", {"kind":"OPEN_FACTORY", "world_id":world_id, "section":"PRODUCTION"})
	await _settle()
	var factory := main.find_child("FactoryWorkspace", true, false)
	_check(str(main.get("_active_page_key")) == "industry" and str(main.get("_selected_factory_world_id")) == world_id and str(factory.get("_active_subworkspace")) == "PRODUCTION", "dashboard opens the matching Factory and requested production section")
	for route in [["OPEN_LOGISTICS", "logistics"], ["OPEN_INVENTORY", "inventory"], ["OPEN_FLEET", "fleet"]]:
		main.call("_open_location", "lunar_space")
		await _settle()
		main.call("_on_location_operations_action", {"kind":route[0]})
		await _settle()
		_check(str(main.get("_active_page_key")) == route[1] and str(main.get("_selected_location_id")) == "lunar_space", "cross-page %s preserves Location context" % route[0])
	main.call("_open_location", "lunar_space")
	await _settle()
	var panel := main.find_child("LocationOperationsWorkspace", true, false) as Control
	var baseline := panel.get_global_rect()
	for output_size in [Vector2i(1920, 1080), Vector2i(3840, 2160), Vector2i(1366, 768)]:
		root.size = output_size
		await _settle()
		_check(panel.get_global_rect().is_equal_approx(baseline), "physical resize %s preserves authored dashboard geometry" % str(output_size))
		_check(Rect2(Vector2.ZERO, Vector2(1920, 1080)).encloses(panel.get_global_rect()), "dashboard remains inside the fixed logical screen")
	root.get_node("I18n").set_locale("en")
	await _settle()
	_check(main.find_child("LocationOperationsWorkspace", true, false) != null and str(main.get("_selected_location_id")) == "lunar_space", "locale switch preserves active Location and dashboard")


func _test_environment_and_task_projection(world_id: String) -> void:
	# Isolated fixture after the paid player flow: compare projection to the
	# same authoritative Factory, including non-neutral Location conditions.
	var world: Dictionary = game.state.factory_worlds[world_id]
	var grid: FactoryGridSimulation = game.simulation.factory_grid
	grid.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "projection-solar")
	grid.place_entity_immediate(world, "grid_engineering_works", Vector2i(12, 0), "", "projection-machine")
	game.simulation.refresh_factory_runtime_views(game.state)
	var snapshot: Dictionary = game.location_operations_snapshot("lunar_space")
	var factory: Dictionary = game.factory_workspace_snapshot(world_id)
	var location_power: Dictionary = game.state.location_state("lunar_space").get("power", {})
	_check(snapshot["power"] == {"generation_kw":factory["power"]["generation_kw"], "demand_kw":factory["power"]["demand_kw"]} and is_equal_approx(float(location_power["current_demand"]), float(factory["power"]["demand_kw"])), "Location dashboard, Location summary and Factory share effective environment-adjusted power")
	var constraints: Dictionary = game.simulation.location_industry_constraint_profile(game.state, "lunar_space")
	_check(is_equal_approx(float(constraints.get("construction_capacity", -1.0)), grid.construction_capacity_per_second(world)), "engineering constraints share the actual difficulty-adjusted construction capacity")
	var queued: Dictionary = grid.queue_construction(world, "grid_solar_array", Vector2i(28, 0))
	var order: Dictionary = world["construction_orders"][queued["order_id"]]
	order["delivered_items"] = order["required_items"].duplicate(true)
	main.call("_open_location", "lunar_space")
	await _settle()
	var before: Dictionary = game.location_operations_snapshot("lunar_space")
	var before_task: Dictionary = before["tasks"].filter(func(row): return row.get("id") == queued["order_id"])[0]
	game._simulation_accumulator_ms = 0.0
	game._process(1.0)
	await _settle()
	var after: Dictionary = game.location_operations_snapshot("lunar_space")
	var after_task: Dictionary = after["tasks"].filter(func(row): return row.get("id") == queued["order_id"])[0]
	var bar := main.find_child("LocationTaskProgress_%s" % str(queued["order_id"]).validate_node_name(), true, false) as ProgressBar
	_check(float(after_task["progress"]) > float(before_task["progress"]), "construction work advances: %s -> %s" % [before_task["progress"], after_task["progress"]])
	_check(float(after_task["remaining_ms"]) < float(before_task["remaining_ms"]), "construction estimate decreases: %s -> %s" % [before_task["remaining_ms"], after_task["remaining_ms"]])
	_check(bar != null and absf(bar.value - float(after_task["progress"]) * 100.0) <= bar.step, "construction task bar matches real work within the widget's display step")
	main.call("_on_location_operations_action", after_task["action"])
	await _settle()
	_check(str(main.find_child("FactoryWorkspace", true, false).get("_active_subworkspace")) == "CONSTRUCTION", "construction task opens the matching construction board and selects its order")
	game.state.shipyard_queue.append({"project_id":"projection-shipyard", "plan_id":"", "location_id":"lunar_space", "quantity_total":2, "quantity_completed":1, "completed_segments":50, "cycle_progress":0.5, "status":"RUNNING"})
	var shipyard_snapshot: Dictionary = game.location_operations_snapshot("lunar_space")
	var shipyard_tasks: Array = shipyard_snapshot["tasks"].filter(func(row): return row.get("id") == "projection-shipyard")
	_check(shipyard_tasks.size() == 1 and is_equal_approx(float(shipyard_tasks[0]["progress"]), 0.7525), "shipyard projection uses completed ships and real segment progress, not nonexistent millisecond fields")
	game.state.shipyard_queue.clear()


func _settle() -> void:
	for step in 5:
		await process_frame
	main.set("_last_refresh_ms", 0)
	main.call("_process", 0.0)
	for step in 3:
		await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
	print(("PASS: " if condition else "FAIL: ") + message)
