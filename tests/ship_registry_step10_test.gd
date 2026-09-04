extends Node

const MainScene = preload("res://src/ui/main.tscn")
const SelectionState = preload("res://src/ui/view_models/ship_registry_selection.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("zh_CN")
	_test_selection_model()
	await _test_multi_selection_ui_and_actions()
	await _test_contextual_toolbar_scale_contract()
	get_tree().root.remove_meta(UiTokens.UI_SCALE_SESSION_META)
	Game.reset_game()
	if failures.is_empty():
		print("SHIP_REGISTRY_STEP10_TEST_PASS")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _test_selection_model() -> void:
	var state = SelectionState.new()
	var visible: Array[String] = ["A", "B", "C"]
	var canonical: Array[String] = ["A", "B", "C", "D"]
	state.reconcile(visible, canonical, true)
	_check(state.primary_ship_id == "A" and state.bulk_selected_ship_ids.is_empty(), "fresh selection chooses a primary ship but never restores transient bulk state")
	state.set_bulk_selected("A", true)
	state.set_bulk_selected("B", true)
	state.set_primary("C")
	_check(state.primary_ship_id == "C" and state.bulk_selected_ship_ids.keys().size() == 2, "primary and bulk selection are independent canonical-ID concepts")
	_check(state.header_state(visible) == SelectionState.HEADER_INDETERMINATE, "partial filtered selection reports indeterminate")
	state.select_all_visible(visible)
	_check(state.header_state(visible) == SelectionState.HEADER_CHECKED, "select filtered includes the complete derived result")
	state.deselect_all_visible(visible)
	_check(state.header_state(visible) == SelectionState.HEADER_UNCHECKED, "deselect filtered clears exactly the current result IDs")
	state.set_bulk_selected("D", true)
	state.reconcile(["C", "B", "A"], canonical, false)
	_check(state.is_bulk_selected("D") and state.primary_ship_id == "C", "sorting preserves primary and bulk IDs even when row order changes")
	state.reconcile(["A", "B"], canonical, true)
	_check(not state.is_bulk_selected("D") and state.primary_ship_id == "A", "filter changes prune hidden bulk IDs and choose a deterministic visible primary")
	state.set_bulk_selected("REMOVED", true)
	state.reconcile(["A", "B"], canonical, false)
	_check(not state.is_bulk_selected("REMOVED"), "removed canonical IDs are pruned even when only sorting changes")


func _test_multi_selection_ui_and_actions() -> void:
	Game.reset_game()
	var modules := ["light_autocannon", "civilian_shield", "basic_drive", "sensor_array", "civilian_reactor_core"]
	var alpha := Game.state._create_ship_instance("lunar_pathfinder", modules, "ISS Alpha")
	var beta := Game.state._create_ship_instance("belt_cruiser", modules, "ISS Beta")
	var reserve := Game.state._create_ship_instance("lunar_pathfinder", modules, "ISS Reserve")
	reserve["maintenance_state"] = "READY_RESERVE"
	var gamma := Game.state._create_ship_instance("lunar_pathfinder", modules, "ISS Gamma")
	var alpha_id := String(alpha.get("instance_id", ""))
	var beta_id := String(beta.get("instance_id", ""))
	var reserve_id := String(reserve.get("instance_id", ""))
	var gamma_id := String(gamma.get("instance_id", ""))
	Game.state.set_formation_ship_ids(SpaceGameState.DEFAULT_FORMATION_ID, [reserve_id])
	get_tree().root.set_meta(UiTokens.UI_SCALE_SESSION_META, 1.5)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1672, 941)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.gui_embed_subwindows = true
	add_child(viewport)
	var main := MainScene.instantiate() as Control
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1672, 941)
	main.set("_fleet_section", "roster")
	viewport.add_child(main)
	await _redraw()
	var fleet_nav := main.find_child("Navigation_ships", true, false) as Button
	if is_instance_valid(fleet_nav): fleet_nav.pressed.emit()
	await _redraw()

	var initial_primary := String(main.call("_fleet_roster_selected_ship_id"))
	var selection = main.get("_fleet_roster_selection_state")
	_check(not initial_primary.is_empty() and selection.bulk_selected_ship_ids.is_empty(), "production UI starts with a primary Inspector ship and empty transient bulk membership")
	var keyboard_checkbox := main.find_child("FleetRosterSelectionControl_%s" % initial_primary, true, false) as CheckBox
	keyboard_checkbox.grab_focus()
	_push_space(viewport)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.is_bulk_selected(initial_primary), "Space toggles the focused real row CheckBox without simulation input")
	main.call("_clear_fleet_roster_bulk_selection")
	await _redraw()
	_toggle_row_checkbox(main, initial_primary, true)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.is_bulk_selected(initial_primary) and String(selection.primary_ship_id) == initial_primary and main.find_child("FleetRosterBulkActions", true, false) is Button, "individual real CheckBox toggles bulk membership and opens the same-height contextual toolbar")
	var header := main.find_child("FleetRosterBrowserHeader", true, false) as Control
	var header_height := header.size.y
	var alpha_row := main.find_child("FleetRosterShip_%s" % alpha_id, true, false) as Button
	alpha_row.pressed.emit()
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(String(selection.primary_ship_id) == alpha_id and selection.is_bulk_selected(initial_primary), "ordinary row navigation changes the primary ship without clearing bulk membership")
	_toggle_row_checkbox(main, alpha_id, true)
	await _redraw()
	var header_checkbox = main.find_child("FleetRosterSelectFiltered", true, false)
	_check(header_checkbox != null and bool(header_checkbox.display_indeterminate) and not header_checkbox.button_pressed, "individual partial selection immediately renders the Header indeterminate state")
	_check((main.find_child("FleetRosterBrowserHeader", true, false) as Control).size.y == header_height, "contextual toolbar causes no vertical layout shift")

	main.set("_fleet_roster_sort_mode", "NAME_DESCENDING")
	main.call("_refresh_fleet_roster_results", false)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(String(selection.primary_ship_id) == alpha_id and selection.is_bulk_selected(initial_primary) and selection.is_bulk_selected(alpha_id), "sorting preserves both selection concepts by canonical ID")
	main.set("_fleet_roster_search_query", "Alpha")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.bulk_selected_ship_ids.size() == 1 and selection.is_bulk_selected(alpha_id), "search intersects bulk selection with the complete derived result")
	main.set("_fleet_roster_search_query", "")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	var select_all := main.find_child("FleetRosterSelectFiltered", true, false) as CheckBox
	select_all.button_pressed = true
	select_all.toggled.emit(true)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.bulk_selected_ship_ids.size() == Game.state.ships.size() and (main.find_child("FleetRosterSelectFiltered", true, false) as CheckBox).button_pressed, "Header CheckBox selects every filtered result before pagination")
	select_all = main.find_child("FleetRosterSelectFiltered", true, false) as CheckBox
	select_all.button_pressed = false
	select_all.toggled.emit(false)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.bulk_selected_ship_ids.is_empty(), "clicking a Checked Header CheckBox deselects all filtered results")
	_toggle_row_checkbox(main, alpha_id, true)
	await _redraw()
	var clear := main.find_child("FleetRosterBulkClear", true, false) as Button
	clear.pressed.emit()
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.bulk_selected_ship_ids.is_empty() and (main.find_child("FleetRosterBrowserSummary", true, false) as Label).text.contains("当前显示"), "Clear removes the full bulk set and restores the normal result summary")
	_toggle_row_checkbox(main, alpha_id, true)
	await _redraw()
	var cancel_selection := InputEventAction.new()
	cancel_selection.action = "ui_cancel"
	cancel_selection.pressed = true
	main.call("_unhandled_input", cancel_selection)
	await _redraw()
	_check(main.get("_fleet_roster_selection_state").bulk_selected_ship_ids.is_empty(), "Escape clears bulk selection when no popup or modal owns Escape")
	main.set("_fleet_roster_search_query", "NO MATCH")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	var zero_header := main.find_child("FleetRosterSelectFiltered", true, false) as CheckBox
	_check(zero_header.disabled and main.get("_fleet_roster_selection_state").bulk_selected_ship_ids.is_empty(), "a zero-result query disables Select Filtered Results")
	main.set("_fleet_roster_search_query", "")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()

	# Type and Formation changes prune hidden selection through the same pipeline.
	selection = main.get("_fleet_roster_selection_state")
	selection.set_bulk_selected(alpha_id, true)
	selection.set_bulk_selected(beta_id, true)
	main.set("_fleet_roster_ship_type_filter", "CRUISER")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.bulk_selected_ship_ids.size() == 1 and selection.is_bulk_selected(beta_id), "Ship Type filter prunes selected IDs excluded by the new derived result")
	main.set("_fleet_roster_ship_type_filter", "")
	selection.set_bulk_selected(reserve_id, true)
	main.set("_fleet_roster_formation_filter", "__UNASSIGNED__")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(not selection.is_bulk_selected(reserve_id), "Formation filter prunes selected ships outside the canonical formation result")
	main.set("_fleet_roster_formation_filter", "")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()

	# Mixed Favorite and Lock states execute only changed canonical IDs.
	Game.set_ship_favorite(alpha_id, true)
	Game.set_ship_locked(beta_id, true)
	main.call("_rebuild_active_page")
	await _redraw()
	_toggle_row_checkbox(main, alpha_id, true)
	await _redraw()
	_toggle_row_checkbox(main, beta_id, true)
	await _redraw()
	var domain_events: Array[Dictionary] = []
	var event_collector := func(event: Dictionary): domain_events.append(event.duplicate(true))
	Game.domain_event.connect(event_collector)
	await _activate_bulk_menu_item(main, 201)
	_check(bool(Game.state.ship_by_id(alpha_id).get("favorite", false)) and bool(Game.state.ship_by_id(beta_id).get("favorite", false)) and _event_count(domain_events, "ShipFavoriteChanged") == 1, "Add Favorite treats the existing target state as no-op and writes each changed ship once")
	domain_events.clear()
	await _activate_bulk_menu_item(main, 202)
	_check(not bool(Game.state.ship_by_id(alpha_id).get("favorite", false)) and not bool(Game.state.ship_by_id(beta_id).get("favorite", false)) and _event_count(domain_events, "ShipFavoriteChanged") == 2, "Remove Favorite explicitly targets the unfavorited state once per changed ship")
	domain_events.clear()
	await _activate_bulk_menu_item(main, 203)
	_check(bool(Game.state.ship_by_id(alpha_id).get("locked", false)) and bool(Game.state.ship_by_id(beta_id).get("locked", false)) and _event_count(domain_events, "ShipLockChanged") == 1, "Lock handles a mixed selection through the accepted persistent STEP 08 command path")
	domain_events.clear()
	await _activate_bulk_menu_item(main, 204)
	_check(not bool(Game.state.ship_by_id(alpha_id).get("locked", false)) and not bool(Game.state.ship_by_id(beta_id).get("locked", false)) and _event_count(domain_events, "ShipLockChanged") == 2, "Unlock explicitly targets the unlocked state without duplicate callbacks")

	# Lifecycle actions use the canonical availability/query path and prune newly hidden rows.
	main.set("_fleet_roster_filter", "ACTIVE")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	selection.clear_bulk()
	selection.set_bulk_selected(alpha_id, true)
	selection.set_bulk_selected(beta_id, true)
	main.call("_refresh_fleet_roster_results", false)
	await _redraw()
	domain_events.clear()
	await _activate_bulk_menu_item(main, 205)
	selection = main.get("_fleet_roster_selection_state")
	_check(String(Game.state.ship_by_id(alpha_id).get("maintenance_state", "")) == "READY_RESERVE" and String(Game.state.ship_by_id(beta_id).get("maintenance_state", "")) == "READY_RESERVE" and selection.bulk_selected_ship_ids.is_empty() and _event_count(domain_events, "ShipMaintenanceStateChanged") == 2, "Ready Reserve calls canonical lifecycle commands, refreshes counts, and prunes ships hidden by the active lifecycle filter")
	main.set("_fleet_roster_filter", "ALL")
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	selection.set_bulk_selected(alpha_id, true)
	main.call("_refresh_fleet_roster_results", false)
	await _redraw()
	domain_events.clear()
	await _activate_bulk_menu_item(main, 206)
	_check(String(Game.state.ship_by_id(alpha_id).get("maintenance_state", "")) == "MOTHBALLED" and _event_count(domain_events, "ShipMaintenanceStateChanged") == 1, "Mothball calls the same canonical lifecycle operation and skips no eligible target")

	# Rebuild with all results for lock-protected aggregate dismantle checks.
	main.call("_refresh_fleet_roster_results", true)
	await _redraw()
	Game.set_ship_locked(alpha_id, false)
	Game.set_ship_locked(beta_id, true)
	Game.state.ship_by_id(reserve_id)["maintenance_state"] = "ACTIVE"
	Game.set_ship_formation_assignment(reserve_id, SpaceGameState.DEFAULT_FORMATION_ID)
	main.call("_rebuild_active_page")
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	selection.clear_bulk()
	selection.set_bulk_selected(alpha_id, true)
	selection.set_bulk_selected(beta_id, true)
	selection.set_bulk_selected(reserve_id, true)
	selection.set_bulk_selected(gamma_id, true)
	main.call("_refresh_fleet_roster_results", false)
	await _redraw()
	var dismantle_ids: Array[String] = [alpha_id, beta_id, reserve_id, gamma_id]
	var classification := main.call("_classify_fleet_roster_bulk_dismantle", dismantle_ids) as Dictionary
	var alpha_recovery := Game.ship_scrap_availability(alpha_id).get("recovery", {}) as Dictionary
	var gamma_recovery := Game.ship_scrap_availability(gamma_id).get("recovery", {}) as Dictionary
	var expected_aggregate := _sum_resources(alpha_recovery, gamma_recovery)
	_check(int(classification.get("eligible_count", 0)) == 2 and int(classification.get("locked_count", 0)) == 1 and int(classification.get("other_skipped_count", 0)) == 1 and classification.get("recovery", {}) == expected_aggregate, "bulk dismantle separates eligible/locked/other ships and aggregates only real eligible recovery")
	var ships_before_cancel := Game.state.ships.size()
	main.call("_request_fleet_roster_bulk_dismantle")
	await _redraw()
	var dialog = main.find_child("FleetRosterBulkDismantleConfirmation", true, false)
	_check(dialog != null and int((dialog.get_meta("ship_ids", []) as Array).size()) == 4, "bulk dismantle opens the themed modal with a canonical-ID snapshot")
	if dialog != null:
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		dialog.call("_input", escape)
	await _redraw()
	_check(Game.state.ships.size() == ships_before_cancel, "bulk dismantle Escape/Cancel causes zero domain mutation")

	main.call("_request_fleet_roster_bulk_dismantle")
	await _redraw()
	dialog = main.find_child("FleetRosterBulkDismantleConfirmation", true, false)
	Game.set_ship_locked(alpha_id, true)
	if dialog != null: dialog.confirmed.emit()
	await _redraw()
	_check(Game.state.ship_by_id(gamma_id).is_empty() and not Game.state.ship_by_id(alpha_id).is_empty() and not Game.state.ship_by_id(beta_id).is_empty(), "confirm revalidation protects a newly locked ship while still applying once to another eligible ship")
	if dialog != null: dialog.canceled.emit()
	Game.set_ship_locked(alpha_id, false)
	await _redraw()
	main.call("_request_fleet_roster_bulk_dismantle")
	await _redraw()
	dialog = main.find_child("FleetRosterBulkDismantleConfirmation", true, false)
	domain_events.clear()
	if dialog != null:
		dialog.confirmed.emit()
		dialog.confirmed.emit()
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(Game.state.ship_by_id(alpha_id).is_empty() and not Game.state.ship_by_id(beta_id).is_empty() and _event_count(domain_events, "ShipScrapped") == 1 and not selection.is_bulk_selected(alpha_id) and selection.is_bulk_selected(beta_id), "repeated Confirm input cannot duplicate execution; dismantled IDs are removed while a visible locked ship remains selected")
	selection.clear_bulk()
	selection.set_bulk_selected(beta_id, true)
	selection.set_bulk_selected(reserve_id, true)
	main.call("_refresh_fleet_roster_results", false)
	await _redraw()
	main.call("_request_fleet_roster_bulk_dismantle")
	await _redraw()
	_check(main.find_child("FleetRosterBulkDismantleConfirmation", true, false) == null and not Game.state.ship_by_id(beta_id).is_empty() and not Game.state.ship_by_id(reserve_id).is_empty(), "an all-protected/ineligible selection cannot open an actionable destructive confirmation")
	if Game.domain_event.is_connected(event_collector): Game.domain_event.disconnect(event_collector)

	I18n.set_locale("en")
	main.call("_rebuild_active_page")
	await _redraw()
	selection = main.get("_fleet_roster_selection_state")
	_check(selection.is_bulk_selected(beta_id) and (main.find_child("FleetRosterBrowserSummary", true, false) as Label).text.contains("selected"), "language changes preserve canonical bulk IDs and localized contextual labels")
	var second_main := MainScene.instantiate() as Control
	second_main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	second_main.size = Vector2(1672, 941)
	second_main.set("_fleet_section", "roster")
	viewport.add_child(second_main)
	await _redraw()
	_check((second_main.get("_fleet_roster_selection_state").bulk_selected_ship_ids as Dictionary).is_empty(), "a fresh UI instance never restores transient bulk selection from preferences or save data")
	second_main.queue_free()
	main.queue_free()
	viewport.queue_free()
	await get_tree().process_frame


func _test_contextual_toolbar_scale_contract() -> void:
	Game.reset_game()
	I18n.set_locale("zh_CN")
	get_tree().root.set_meta(UiTokens.UI_SCALE_SESSION_META, 1.0)
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1672, 941)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.gui_embed_subwindows = true
	add_child(viewport)
	var main := MainScene.instantiate() as Control
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1672, 941)
	main.set("_fleet_section", "roster")
	viewport.add_child(main)
	await _redraw()
	var nav := main.find_child("Navigation_ships", true, false) as Button
	if is_instance_valid(nav): nav.pressed.emit()
	await _redraw()
	var primary_id := String(main.call("_fleet_roster_selected_ship_id"))
	var normal_header := main.find_child("FleetRosterBrowserHeader", true, false) as Control
	var normal_height := normal_header.size.y
	_toggle_row_checkbox(main, primary_id, true)
	await _redraw()
	var contextual_header := main.find_child("FleetRosterBrowserHeader", true, false) as Control
	var checkbox := main.find_child("FleetRosterSelectionControl_%s" % primary_id, true, false) as Control
	var controls_fit := true
	for control_name in ["FleetRosterSelectFiltered", "FleetRosterBulkClear", "FleetRosterBulkActions"]:
		var control := main.find_child(control_name, true, false) as Control
		controls_fit = controls_fit and is_instance_valid(control) and contextual_header.get_global_rect().encloses(control.get_global_rect())
	_check(contextual_header.size.y == normal_height and controls_fit and checkbox.size.x >= 11.0, "100% contextual toolbar and real checkbox follow the canonical scale path without clipping or layout shift")
	I18n.set_locale("en")
	main.call("_rebuild_active_page")
	await _redraw()
	contextual_header = main.find_child("FleetRosterBrowserHeader", true, false) as Control
	controls_fit = true
	for control_name in ["FleetRosterSelectFiltered", "FleetRosterBulkClear", "FleetRosterBulkActions"]:
		var control := main.find_child(control_name, true, false) as Control
		controls_fit = controls_fit and is_instance_valid(control) and contextual_header.get_global_rect().encloses(control.get_global_rect())
	_check(controls_fit and (main.find_child("FleetRosterBrowserSummary", true, false) as Label).text.contains("selected"), "English contextual labels fit at 100% without changing canonical selected IDs")
	main.queue_free()
	viewport.queue_free()
	await get_tree().process_frame


func _toggle_row_checkbox(main: Control, ship_id: String, pressed: bool) -> void:
	var checkbox := main.find_child("FleetRosterSelectionControl_%s" % ship_id, true, false) as CheckBox
	_check(checkbox != null, "row checkbox exists for %s" % ship_id)
	if checkbox == null: return
	checkbox.button_pressed = pressed
	checkbox.toggled.emit(pressed)


func _activate_bulk_menu_item(main: Control, item_id: int) -> void:
	var button := main.find_child("FleetRosterBulkActions", true, false) as Button
	_check(button != null, "contextual Bulk Actions button exists")
	if button == null: return
	button.pressed.emit()
	await _redraw()
	var popup := main.find_child("FleetRosterBulkActionsMenu", true, false) as PopupMenu
	_check(popup != null and popup.visible, "Bulk Actions opens the real themed popup")
	if popup == null: return
	var index := popup.get_item_index(item_id)
	_check(index >= 0 and not popup.is_item_disabled(index), "bulk menu item %d is enabled for the fixture" % item_id)
	if index >= 0 and not popup.is_item_disabled(index):
		popup.id_pressed.emit(item_id)
	await _redraw()


func _event_count(events: Array[Dictionary], event_type: String) -> int:
	return events.filter(func(event): return String(event.get("type", "")) == event_type).size()


func _sum_resources(first: Dictionary, second: Dictionary) -> Dictionary:
	var result := first.duplicate(true)
	for item_id_value in second.keys():
		var item_id := String(item_id_value)
		result[item_id] = int(result.get(item_id, 0)) + int(second.get(item_id, 0))
	return result


func _push_space(viewport: Viewport) -> void:
	var press := InputEventKey.new()
	press.keycode = KEY_SPACE
	press.physical_keycode = KEY_SPACE
	press.pressed = true
	viewport.push_input(press)
	var release := InputEventKey.new()
	release.keycode = KEY_SPACE
	release.physical_keycode = KEY_SPACE
	release.pressed = false
	viewport.push_input(release)


func _redraw() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
