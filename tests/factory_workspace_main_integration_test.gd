extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := root.get_node("Game")
	var localization := root.get_node("I18n")
	game.persistence_enabled = false
	localization.call("set_locale", "zh_CN")
	game.reset_game()
	var earth_world: Dictionary = game.state.factory_worlds.get("earth-surface-grid", {})
	game.simulation.factory_grid.place_entity_immediate(earth_world, "grid_solar_array", Vector2i(200, 0), "", "integration-power")
	game.simulation.factory_grid.place_entity_immediate(earth_world, "grid_surface_mine", Vector2i(32, 32), "", "integration-mine")
	var lunar: Dictionary = game.state.location_state("lunar_space")
	lunar["survey_state"] = LocationState.SURVEYED
	game.state.region_states["lunar_space"]["survey_state"] = LocationState.SURVEYED
	_check(game.initialize_surveyed_factory_world("lunar_space"), "surveyed second Location creates a second Factory world")
	var lunar_world_ids: Array[String] = game.factory_world_ids_for_location("lunar_space")
	_check(lunar_world_ids.size() == 1, "second Location exposes one canonical Factory world")
	if lunar_world_ids.is_empty():
		_finish(null)
		return

	# Exercise the real pointer route at a normal desktop size first; compact
	# reachability is checked separately below after resizing the same Main tree.
	root.size = Vector2i(1400, 900)
	var main_scene := load("res://src/ui/main.tscn") as PackedScene
	_check(main_scene != null, "MainScene loads after application autoload initialization")
	if main_scene == null:
		_finish(null)
		return
	var main := main_scene.instantiate() as Control
	root.add_child(main)
	await _settle()
	var industry_navigation := main.find_child("Navigation_industry", true, false) as Button
	_check(industry_navigation != null and not industry_navigation.disabled, "Main exposes an enabled player-facing Industry navigation control")
	if industry_navigation != null and not industry_navigation.disabled:
		industry_navigation.pressed.emit()
	await _settle()
	_check(_selected_world(main) == "earth-surface-grid", "Factory selector and workspace initially agree on the Earth world")
	var live_workspace := main.find_child("FactoryWorkspace", true, false)
	var power_mode := main.find_child("PowerConnectionMode", true, false) as Button
	var connection_source := main.find_child("ConnectionSource", true, false) as OptionButton
	var connection_target := main.find_child("ConnectionTarget", true, false) as OptionButton
	var create_connection := main.find_child("CreateConnection", true, false) as Button
	var feedback := main.find_child("FactoryCommandFeedback", true, false) as Label
	var connection_events: Array = []
	game.domain_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "FactoryEntitiesConnected" and str(event.get("source_id", "")) == "integration-power":
			connection_events.append(event.duplicate(true))
	)
	var link_count_before: int = earth_world.get("links", {}).size()
	var topology_before := int(earth_world.get("topology_revision", 0))
	if power_mode != null:
		power_mode.pressed.emit()
	var connection_selected := _select_option_metadata(connection_source, "integration-power") and _select_option_metadata(connection_target, "integration-mine")
	if create_connection != null and connection_selected:
		create_connection.pressed.emit()
	await _settle()
	var earth_after_connection: Dictionary = game.state.factory_worlds.get("earth-surface-grid", {})
	_check(
		connection_selected and earth_after_connection.get("links", {}).size() == link_count_before + 1
		and int(earth_after_connection.get("topology_revision", 0)) == topology_before + 1
		and connection_events.size() == 1 and feedback != null and str(feedback.text).begins_with("[ACCEPTED]"),
		"one real Create Connection press commits one link, one event, one topology revision, and final accepted feedback"
	)
	var palette := main.find_child("BuildingPalette", true, false) as OptionButton
	var canvas := main.find_child("FactoryCanvas", true, false) as Control
	var order_count_before: int = game.state.factory_worlds.get("earth-surface-grid", {}).get("construction_orders", {}).size()
	_check(live_workspace != null and _select_option_metadata(palette, "grid_solar_array"), "real Main Factory palette selects a physical building")
	var pointer_placement_dispatched := false
	if canvas != null:
		pointer_placement_dispatched = await _place_valid_canvas_tile_with_pointer(canvas)
	await _settle()
	_check(pointer_placement_dispatched and game.state.factory_worlds.get("earth-surface-grid", {}).get("construction_orders", {}).size() == order_count_before + 1, "Main navigation, real palette signal, and routed mouse placement execute a versioned Factory intent against Game")
	var world_selector := main.find_child("FactoryWorldSelector", true, false) as OptionButton
	_check(_select_option_metadata(world_selector, lunar_world_ids[0]), "real Factory world selector chooses the surveyed Lunar workspace")
	await _settle()
	_check(_selected_world(main) == lunar_world_ids[0], "Location-to-Factory navigation rebuilds the selector for the newly opened world")
	var workspace := main.find_child("FactoryWorkspace", true, false)
	var snapshot: Dictionary = workspace.get("_snapshot") if workspace != null else {}
	_check(str(snapshot.get("world_id", "")) == lunar_world_ids[0], "Factory workspace snapshot matches the visible world selector")
	main.call("_reset_game")
	await _settle()
	world_selector = main.find_child("FactoryWorldSelector", true, false) as OptionButton
	workspace = main.find_child("FactoryWorkspace", true, false)
	snapshot = workspace.get("_snapshot") if workspace != null else {}
	_check(
		not game.state.factory_worlds.has(lunar_world_ids[0])
		and world_selector != null and world_selector.item_count == 1
		and _selected_world(main) == "earth-surface-grid"
		and str(snapshot.get("world_id", "")) == "earth-surface-grid",
		"resetting while a removed remote Factory is selected rebuilds the selector and falls back to the fresh Earth workspace"
	)
	var next_step_cta := main.find_child("NextStepCTA", true, false) as Button
	var next_step_cta_was_enabled := next_step_cta != null and not next_step_cta.disabled
	if next_step_cta_was_enabled:
		next_step_cta.pressed.emit()
	await _settle()
	var refreshed_next_step_cta := main.find_child("NextStepCTA", true, false) as Button
	_check(
		next_step_cta_was_enabled and refreshed_next_step_cta != null and not refreshed_next_step_cta.disabled and _selected_world(main) == "earth-surface-grid",
		"real Factory bootstrap CTA signal follows guidance location back to the authoritative Earth workspace; selected=%s active=%s disabled=%s guidance=%s" % [
			_selected_world(main), str(main.get("_active_page_key")), str(refreshed_next_step_cta == null or refreshed_next_step_cta.disabled), JSON.stringify(game.guidance_snapshot())
		]
	)

	root.size = Vector2i(800, 600)
	await _settle()
	var industry_scroll := main.find_child("industry", true, false) as ScrollContainer
	_check(industry_scroll != null and industry_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO and industry_scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO, "compact Factory layout keeps both axes reachable through bounded scrolling")
	_check(main.find_child("BuildingPalette", true, false) != null and main.find_child("FactoryCanvas", true, false) != null and main.find_child("FactoryInspector", true, false) != null, "compact Factory layout retains palette, canvas, and inspector controls")

	var construction_navigation := main.find_child("Navigation_construction", true, false) as Button
	if construction_navigation != null:
		construction_navigation.pressed.emit()
	await _settle()
	_check(main.find_child("OpenFactoryConstruction", true, false) != null and main.find_child("OpenMegastructureConstruction", true, false) != null, "Construction navigation routes to the authoritative Factory and Megastructure workspaces")
	_check(main.find_child("StartConstruction_*", true, false) == null and main.find_child("PauseConstruction_*", true, false) == null, "retired aggregate construction controls are no longer reachable")

	game.state.completed_projects["research_megastructures"] = true
	game.state.technologies["megastructure_engineering"] = true
	game.state.megastructure_projects["stellar_energy"] = {
		"id":"stellar_energy", "site_location_id":"earth_orbit", "location_id":"earth_orbit",
		"phase_index":1, "status":"BUILDING", "material_flow_status":"STAGED", "progress_percent":15,
		"delivered_materials":{"scrap_metal":1},
		"phase_runtime":{"phase_index":1, "phase_id":"stellar_forward_base", "activity_id":"construct_stellar_forward_base", "progress_ms":10.0, "duration_ms":100000.0}
	}
	var megastructure_navigation := main.find_child("Navigation_megastructure", true, false) as Button
	if megastructure_navigation != null:
		megastructure_navigation.pressed.emit()
	await _settle()
	_check(main.find_child("MegastructureOpenWorksite", true, false) != null, "active Megastructure UI exposes its selected worksite")
	_check(main.find_child("StartMegastructure_stellar_energy", true, false) == null, "active Megastructure UI reads dedicated phase_runtime and does not offer a duplicate start")
	_check(main.find_child("CancelMegastructure_stellar_energy", true, false) == null, "Megastructure UI exposes no retired aggregate cancel action")

	game.state.megastructure_projects["stellar_energy"]["phase_runtime"] = {}
	game.state.megastructure_projects["stellar_energy"]["status"] = "READY"
	game.state.megastructure_projects["stellar_energy"]["delivered_materials"] = {}
	if megastructure_navigation != null:
		megastructure_navigation.pressed.emit()
	await _settle()
	var waiting_start := main.find_child("StartMegastructure_stellar_energy", true, false) as Button
	_check(game.simulation.megastructure_gameplay_state(game.state, "stellar_energy") == "WAITING_MATERIAL", "READY Megastructure with a missing same-site BOM exposes WAITING_MATERIAL")
	_check(waiting_start != null and waiting_start.disabled, "Megastructure Start is visibly disabled while its same-site BOM is missing")
	game.state.megastructure_projects["stellar_energy"]["site_effects"] = {"construction_capacity":1.0}
	var stellar_definition: Dictionary = game.content.megastructures.get("stellar_energy", {})
	var ready_phase: Dictionary = (stellar_definition.get("phases", []) as Array)[1]
	var ready_activity: Dictionary = game.content.activities.get(str(ready_phase.get("activity_id", "")), {})
	for cost_value in ready_activity.get("costs", []):
		var cost := cost_value as Dictionary
		game.state.add_item(str(cost.get("item", "")), int(cost.get("quantity", 0)), "earth_orbit")
	main.call("_switch_page", "megastructure")
	await _settle()
	var ready_start := main.find_child("StartMegastructure_stellar_energy", true, false) as Button
	var ready_state := str(game.simulation.megastructure_gameplay_state(game.state, "stellar_energy"))
	var ready_blocker: Dictionary = game.simulation.megastructure_phase_start_blocker(game.state, ready_activity, "earth_orbit")
	_check(ready_state == "READY", "material-complete idle Megastructure phase exposes READY instead of BUILDING: %s / %s" % [ready_state, str(ready_blocker)])
	_check(ready_start != null and not ready_start.disabled, "READY Megastructure exposes an enabled Start Phase action: %s" % str(ready_blocker))

	if industry_navigation != null:
		industry_navigation.pressed.emit()
	await _settle()
	world_selector = main.find_child("FactoryWorldSelector", true, false) as OptionButton
	_select_option_metadata(world_selector, "earth-surface-grid")
	await _settle()
	workspace = main.find_child("FactoryWorkspace", true, false)
	snapshot = workspace.get("_snapshot") if workspace != null else {}
	var entities: Array = snapshot.get("entities", [])
	var depots: Array = entities.filter(func(entity_value): return str((entity_value as Dictionary).get("definition_id", "")) == "grid_bulk_depot")
	var inspected_entity: Dictionary = depots[0] if not depots.is_empty() else {}
	if workspace != null and not inspected_entity.is_empty():
		workspace.call("_on_entity_selected", inspected_entity.duplicate(true))
		await _settle()
	var expected_depot := str(localization.call("t", "factory.building.grid_bulk_depot"))
	var expected_status := str(localization.call("status", str(inspected_entity.get("status", "IDLE")))) if not inspected_entity.is_empty() else ""
	_check(not inspected_entity.is_empty() and _has_text(workspace, expected_depot) and _has_text(workspace, expected_status), "Chinese Factory inspector localizes physical entity names and runtime states")
	_finish(main)


func _selected_world(main: Control) -> String:
	var selector := main.find_child("FactoryWorldSelector", true, false) as OptionButton
	var workspace := main.find_child("FactoryWorkspace", true, false)
	if selector == null or selector.selected < 0 or workspace == null:
		return ""
	var selected_id := str(selector.get_item_metadata(selector.selected))
	var snapshot: Dictionary = workspace.get("_snapshot")
	return selected_id if selected_id == str(snapshot.get("world_id", "")) else ""


func _has_text(node: Node, fragment: String) -> bool:
	if node == null or fragment.is_empty():
		return false
	if (node is Label or node is RichTextLabel or node is Button) and fragment in str(node.get("text")):
		return true
	for child in node.get_children():
		if _has_text(child, fragment):
			return true
	return false


func _select_option_metadata(options: OptionButton, value: String) -> bool:
	if options == null:
		return false
	for index in options.item_count:
		if str(options.get_item_metadata(index)) != value:
			continue
		options.select(index)
		options.item_selected.emit(index)
		return true
	return false


func _place_valid_canvas_tile_with_pointer(canvas: Control) -> bool:
	if canvas == null or canvas.size.x < 32.0 or canvas.size.y < 32.0:
		return false
	# Tile (1,1) is a stable empty starter-world coordinate: resource fields begin
	# at x=32/72 and the depot at x=110. Route viewport-space pointer events
	# through the Window so Control hit testing and the full mouse branch run.
	var local_point: Vector2 = canvas.call("_world_to_screen", Vector2(1, 1)) + Vector2(2, 2)
	var viewport_point := canvas.get_global_rect().position + local_point
	var motion := InputEventMouseMotion.new()
	motion.position = viewport_point
	motion.global_position = viewport_point
	root.push_input(motion, false)
	await process_frame
	var preview: Dictionary = canvas.get("_placement_preview")
	if not bool(preview.get("valid", false)):
		return false
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = viewport_point
	press.global_position = viewport_point
	root.push_input(press, false)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = viewport_point
	release.global_position = viewport_point
	root.push_input(release, false)
	return true


func _settle() -> void:
	await process_frame
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish(main: Control) -> void:
	if main != null:
		main.queue_free()
	if failures.is_empty():
		print("PASS: Factory MainScene world selection, compact reachability, and zh-CN inspector integration")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
