extends SceneTree

## A short player-facing command path through the rebuilt workspace shell.  It
## deliberately uses visible controls (rather than the first node with a name)
## because inactive TabContainer pages retain similarly named controls in the
## tree between refreshes.

const DEFAULT_FORMATION_ID := SpaceGameState.DEFAULT_FORMATION_ID

var failures: Array[String] = []
var main: Control
var game: Node


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node_or_null("Game")
	_check(game != null, "Game autoload is available to the standalone workspace flow")
	if game == null:
		_finish()
		return
	game.persistence_enabled = false
	game.reset_game()
	# Rendering a command route must not accrue simulation time while the test is
	# waiting for layout frames.
	game.set_process(false)
	root.size = Vector2i(1920, 1080)
	# Load after the autoloads exist. Preloading Main from a standalone SceneTree
	# entry point can compile its autoload references before that registry is live.
	var main_scene := load("res://src/ui/main.tscn") as PackedScene
	_check(main_scene != null, "Main scene loads after standalone autoload initialization")
	if main_scene == null:
		_finish()
		return
	main = main_scene.instantiate() as Control
	root.add_child(main)
	await _settle()

	await _test_primary_navigation()
	await _test_supply_location_and_logistics()
	await _test_fleet_command_and_shipyard()
	await _test_research_selection_and_camera_refresh()

	if is_instance_valid(main):
		main.queue_free()
	await process_frame
	_finish()


func _test_primary_navigation() -> void:
	var primary_routes := [
		["system_map", "Navigation_system_map"],
		["industry", "Navigation_industry"],
		["inventory", "Navigation_inventory"],
		["research", "Navigation_research"],
		["fleet", "Navigation_ships"],
		["megastructure", "Navigation_megastructure"],
		["diagnostics", "Navigation_diagnostics"]
	]
	for route_value in primary_routes:
		var route := route_value as Array
		var expected_page := String(route[0])
		var control_name := String(route[1])
		var button := _visible_named(control_name, "Button") as Button
		_check(button != null and not button.disabled, "primary route is visible and usable: %s" % expected_page)
		if button != null and not button.disabled:
			button.pressed.emit()
			await _settle()
		_check(String(main.get("_active_page_key")) == expected_page, "primary route reaches its workspace: %s" % expected_page)
		_assert_main_bounds("primary route %s" % expected_page)


func _test_supply_location_and_logistics() -> void:
	await _press_visible("Navigation_inventory", "Supply inventory navigation")
	var location_selector := _visible_named("WorkspaceLocationSelector", "OptionButton") as OptionButton
	_check(location_selector != null and location_selector.item_count > 0, "Supply exposes a visible location selector")
	var location_before := String(main.get("_selected_location_id"))
	if location_selector != null and location_selector.item_count > 0:
		# A fresh start can truthfully expose only Earth Orbit. Emitting the visible
		# choice still covers the selector's player signal and keeps this a fresh,
		# no-persistence route rather than fabricating a discovered location.
		location_selector.item_selected.emit(location_selector.selected)
		await _settle()
		_check(String(main.get("_selected_location_id")) == location_before, "Supply location selection resolves to the visible current location")
		location_selector = _visible_named("WorkspaceLocationSelector", "OptionButton") as OptionButton
		_assert_control_inside_main(location_selector, "Supply location selector")
	var inventory_page := _active_page()
	_check(inventory_page != null and inventory_page.is_visible_in_tree(), "Inventory workspace remains visible after location selection")
	await _press_visible("SectionRoute_logistics", "Supply Logistics route")
	_check(String(main.get("_active_page_key")) == "logistics", "Inventory routes directly to Logistics")
	_check(String(main.get("_selected_location_id")) == location_before, "Logistics preserves the active Supply location")
	_assert_main_bounds("Supply logistics route")
	_assert_control_inside_main(_active_page(), "Logistics workspace host")


func _test_fleet_command_and_shipyard() -> void:
	await _press_visible("Navigation_ships", "Fleet navigation")
	var roster_tab := _visible_named("FleetSection_roster", "Button") as Button
	_check(roster_tab != null, "Fleet roster tab is visible")
	if roster_tab != null and not roster_tab.disabled:
		await _press_visible("FleetSection_roster", "Fleet roster tab")
	var ship_row := _visible_named("FleetRosterShip_*", "Button") as Button
	_check(ship_row != null, "Fleet roster exposes a visible ship row")
	if ship_row == null:
		return
	var ship_id := String(ship_row.name).trim_prefix("FleetRosterShip_")
	ship_row.pressed.emit()
	await _settle()
	var dispatch := _visible_named("FleetRosterDispatch", "Button") as Button
	_check(dispatch != null and not dispatch.disabled, "selected roster ship exposes Dispatch")
	if dispatch != null and not dispatch.disabled:
		dispatch.pressed.emit()
		await _settle()
		var popup := _visible_named("FleetRosterDispatchMenu", "PopupMenu") as PopupMenu
		var formation_item := _popup_item_by_metadata(popup, DEFAULT_FORMATION_ID)
		_check(popup != null and formation_item >= 0, "Dispatch popup offers the default formation")
		if popup != null and formation_item >= 0:
			popup.id_pressed.emit(popup.get_item_id(formation_item))
			await _settle()
		_check(String(game.state.ship_formation_id(ship_id)) == DEFAULT_FORMATION_ID, "Dispatch writes the selected ship's authoritative formation")
	_assert_main_bounds("Fleet roster dispatch")

	await _press_visible("FleetSection_readiness", "Fleet readiness tab")
	var doctrine := _visible_named("FleetDoctrine_AGGRESSIVE_PUSH", "Button") as Button
	_check(doctrine != null and not doctrine.disabled, "Readiness exposes Aggressive Push doctrine")
	if doctrine != null and not doctrine.disabled:
		doctrine.pressed.emit()
		await _settle()
	var retreat := _visible_named("FleetRetreatPolicy_HULL_THRESHOLD_40", "Button") as Button
	_check(retreat != null and not retreat.disabled, "Readiness exposes a 40 percent hull retreat policy")
	if retreat != null and not retreat.disabled:
		retreat.pressed.emit()
		await _settle()
	var supply_input := _visible_named("FleetSupplyTarget_kinetic_munitions", "SpinBox") as SpinBox
	var save_supply := _visible_named("SetFleetSupplyPlan_kinetic_munitions", "Button") as Button
	var next_supply_target := -1
	if supply_input != null:
		next_supply_target = int(supply_input.value) + 17
		supply_input.value = next_supply_target
	_check(supply_input != null and save_supply != null and not save_supply.disabled, "Readiness exposes an editable, saveable munitions target")
	if save_supply != null and not save_supply.disabled and next_supply_target >= 0:
		save_supply.pressed.emit()
		await _settle()
	var formation: Dictionary = game.state.fleet_logistics_runtime(DEFAULT_FORMATION_ID).get("formation", {})
	var retreat_policy: Dictionary = formation.get("retreat_policy", {})
	var supply_plan: Dictionary = game.state.fleet_logistics_runtime(DEFAULT_FORMATION_ID).get("supply_plan", {})
	_check(String(formation.get("doctrine", "")) == "AGGRESSIVE_PUSH", "Readiness doctrine button writes authoritative formation doctrine")
	_check(String(retreat_policy.get("mode", "")) == "HULL_THRESHOLD" and is_equal_approx(float(retreat_policy.get("threshold", 0.0)), 0.40), "Readiness retreat button writes authoritative retreat policy")
	_check(next_supply_target >= 0 and int(supply_plan.get("kinetic_munitions", -1)) == next_supply_target, "Readiness supply target writes authoritative fleet logistics")
	_assert_main_bounds("Fleet readiness commands")

	await _press_visible("FleetSection_shipyard", "Shipyard tab")
	var editor := _visible_named("MainShipBlueprintEditor", "Control") as Control
	var assembly_map := _visible_named("ShipAssemblyMap", "GraphEdit") as GraphEdit
	_check(editor != null and assembly_map != null, "Shipyard mounts the visible shared blueprint editor and canvas")
	if editor == null or assembly_map == null:
		return
	assembly_map.call("_drop_data", Vector2(620.0, 260.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	assembly_map.call("_drop_data", Vector2(120.0, 160.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	assembly_map.call("request_module_connection", "ship_design_module_0001", "socket_weapon_0")
	await _settle()
	var draft_before_refresh: Dictionary = assembly_map.call("draft_snapshot")
	_check(draft_before_refresh.get("nodes", []).size() == 2 and draft_before_refresh.get("connections", []).size() == 1, "Shipyard accepts a hull drop, module drop, and player-authored connection")
	main.call("_request_active_page_refresh", true)
	await _settle()
	var refreshed_editor := _visible_named("MainShipBlueprintEditor", "Control") as Control
	var refreshed_map := _visible_named("ShipAssemblyMap", "GraphEdit") as GraphEdit
	var draft_after_refresh: Dictionary = refreshed_map.call("draft_snapshot") if refreshed_map != null else {}
	_check(refreshed_editor == editor and refreshed_map == assembly_map and draft_after_refresh == draft_before_refresh, "Shipyard refresh preserves the live editor, canvas, and unsaved draft")
	if refreshed_editor == null or refreshed_map == null:
		return
	editor = refreshed_editor
	assembly_map = refreshed_map
	_assert_editor_session_contract(editor, "Shipyard editor")
	# Give the persisted session an intentionally non-default player camera. The
	# scene transition and locale refresh below must restore this local canvas
	# state along with the unsaved physical design.
	assembly_map.zoom = 0.76
	assembly_map.scroll_offset = Vector2(180.0, 90.0)
	await _settle()
	var draft_before_leave: Dictionary = assembly_map.call("draft_snapshot")
	var camera_before_leave := _graph_camera(assembly_map)
	await _press_visible("FleetSection_readiness", "leave Shipyard for Fleet readiness")
	_check(String(main.get("_fleet_section")) == "readiness", "Fleet can leave Shipyard through its visible readiness tab")
	await _press_visible("FleetSection_shipyard", "return to Shipyard")
	var returned_editor := _visible_named("MainShipBlueprintEditor", "Control") as Control
	var returned_map := _visible_named("ShipAssemblyMap", "GraphEdit") as GraphEdit
	var draft_after_return: Dictionary = returned_map.call("draft_snapshot") if returned_map != null else {}
	_check(returned_editor != null and returned_map != null and draft_after_return == draft_before_leave, "leaving Shipyard and returning restores the unsaved player draft")
	_check(returned_map != null and _camera_equal(camera_before_leave, _graph_camera(returned_map)), "leaving Shipyard and returning restores the player canvas camera")
	_assert_editor_session_contract(returned_editor, "returned Shipyard editor")
	if returned_editor == null or returned_map == null:
		return

	var localization := root.get_node_or_null("I18n")
	var locale_before := String(localization.current_locale) if localization != null else ""
	var toggle_locale := _visible_named("ToggleLocale", "Button") as Button
	_check(localization != null and toggle_locale != null and not toggle_locale.disabled, "global locale refresh is reachable while Shipyard is open")
	if localization != null and toggle_locale != null and not toggle_locale.disabled:
		toggle_locale.pressed.emit()
		await _settle()
	var locale_after := String(localization.current_locale) if localization != null else ""
	var expected_locale := "en" if locale_before.begins_with("zh") else "zh_CN"
	var localized_editor := _visible_named("MainShipBlueprintEditor", "Control") as Control
	var localized_map := _visible_named("ShipAssemblyMap", "GraphEdit") as GraphEdit
	var draft_after_locale: Dictionary = localized_map.call("draft_snapshot") if localized_map != null else {}
	_check(locale_after == expected_locale, "locale toggle performs a real locale refresh")
	_check(localized_editor != null and localized_map != null and draft_after_locale == draft_before_leave, "locale refresh preserves the unsaved Shipyard draft")
	_check(localized_map != null and _camera_equal(camera_before_leave, _graph_camera(localized_map)), "locale refresh preserves the player canvas camera")
	_assert_editor_session_contract(localized_editor, "locale-refreshed Shipyard editor")
	_assert_main_bounds("Shipyard draft workflow")
	_assert_control_inside_main(localized_editor, "Shipyard workspace content")


func _test_research_selection_and_camera_refresh() -> void:
	await _press_visible("Navigation_research", "Research navigation")
	var selector := _visible_named("ResearchProjectSelector", "OptionButton") as OptionButton
	var graph := _visible_named("ResearchTechnologyGraph", "GraphEdit") as GraphEdit
	_check(selector != null and selector.item_count > 1 and graph != null, "Research exposes a visible selector and technology graph")
	if selector == null or selector.item_count < 2 or graph == null:
		return
	var next_index := 1 if selector.selected == 0 else 0
	selector.select(next_index)
	selector.item_selected.emit(next_index)
	await _settle()
	var selected_graph := _visible_named("ResearchTechnologyGraph", "GraphEdit") as GraphEdit
	var inspector := _visible_named("ResearchWorkspaceInspector", "VBoxContainer") as Control
	_check(selector.selected == next_index and selected_graph != null and inspector != null and inspector.is_visible_in_tree(), "Research selector updates the in-place inspector without leaving the workspace")
	if selected_graph == null:
		return
	var camera_before_refresh := Vector3(selected_graph.scroll_offset.x, selected_graph.scroll_offset.y, selected_graph.zoom)
	main.call("_request_active_page_refresh", true)
	await _settle()
	var refreshed_graph := _visible_named("ResearchTechnologyGraph", "GraphEdit") as GraphEdit
	var refreshed_inspector := _visible_named("ResearchWorkspaceInspector", "VBoxContainer") as Control
	var camera_after_refresh := Vector3(refreshed_graph.scroll_offset.x, refreshed_graph.scroll_offset.y, refreshed_graph.zoom) if refreshed_graph != null else Vector3.ZERO
	_check(refreshed_graph != null and _camera_equal(camera_before_refresh, camera_after_refresh), "Research refresh preserves camera expected=%s actual=%s" % [camera_before_refresh, camera_after_refresh])
	_assert_main_bounds("Research selector and refresh")
	_assert_control_inside_main(refreshed_inspector, "Research inspector workspace content")


func _press_visible(control_name: String, description: String) -> void:
	var button := _visible_named(control_name, "Button") as Button
	_check(button != null and not button.disabled, "%s is visible and enabled" % description)
	if button != null and not button.disabled:
		button.pressed.emit()
		await _settle()


func _visible_named(pattern: String, type_name: String) -> Node:
	if not is_instance_valid(main):
		return null
	for candidate in main.find_children(pattern, type_name, true, false):
		if candidate is Control and (candidate as Control).is_visible_in_tree():
			return candidate
		if candidate is PopupMenu and (candidate as PopupMenu).visible:
			return candidate
	return null


func _active_page() -> Control:
	if not is_instance_valid(main):
		return null
	var pages: Dictionary = main.get("_page_controls")
	return pages.get(String(main.get("_active_page_key"))) as Control


func _popup_item_by_metadata(popup: PopupMenu, expected: String) -> int:
	if popup == null:
		return -1
	for item_index in popup.item_count:
		if String(popup.get_item_metadata(item_index)) == expected and not popup.is_item_disabled(item_index):
			return item_index
	return -1


func _assert_main_bounds(context: String) -> void:
	var active_page := _active_page()
	_assert_control_inside_main(_visible_named("TopStatusBar", "PanelContainer") as Control, "%s top status controls" % context)
	_assert_control_inside_main(_visible_named("WorkspaceNavigationBar", "PanelContainer") as Control, "%s primary navigation" % context)
	_assert_control_inside_main(_visible_named("CentralWorkspace", "VBoxContainer") as Control, "%s central workspace" % context)
	var command_dock := _visible_named("CommandDockSurface", "PanelContainer") as Control
	if command_dock != null:
		_assert_control_inside_main(command_dock, "%s command dock" % context)
	_assert_control_inside_main(active_page, "%s active workspace host" % context)


func _assert_control_inside_main(control: Control, description: String) -> void:
	var main_bounds := main.get_global_rect().grow(1.0) if is_instance_valid(main) else Rect2()
	var fits := control != null and control.is_visible_in_tree() and control.size.x > 0.0 and control.size.y > 0.0 \
		and main_bounds.encloses(control.get_global_rect())
	_check(fits, "%s stays inside the authored 1920 x 1080 logical surface" % description)


func _camera_equal(a: Vector3, b: Vector3) -> bool:
	return is_equal_approx(a.x, b.x) and is_equal_approx(a.y, b.y) and is_equal_approx(a.z, b.z)


func _graph_camera(graph: GraphEdit) -> Vector3:
	if graph == null:
		return Vector3.ZERO
	var center := (graph.scroll_offset + graph.size * 0.5) / graph.zoom
	return Vector3(center.x, center.y, graph.zoom)


func _assert_editor_session_contract(editor: Control, context: String) -> void:
	var supports_session := editor != null and editor.has_method("capture_session_state") and editor.has_method("restore_session_state")
	_check(supports_session, "%s exposes the public session capture and restore contract" % context)
	if supports_session:
		_check(editor.call("capture_session_state") is Dictionary, "%s returns a serializable session capture" % context)


func _settle() -> void:
	for _frame in 8:
		await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("COMMAND_WORKSPACE_FLOW_TEST_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
