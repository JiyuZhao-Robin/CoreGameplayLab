extends Node

const MainScene = preload("res://src/ui/main.tscn")
const Query = preload("res://src/ui/view_models/ship_registry_query.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("zh_CN")
	_test_query_projection()
	await _test_registry_ui_at_scale(1.5)
	await _test_registry_ui_at_scale(1.0)
	get_tree().root.remove_meta(UiTokens.UI_SCALE_SESSION_META)
	if failures.is_empty():
		print("SHIP_REGISTRY_STEP09_TEST_PASS")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _test_query_projection() -> void:
	var definitions := {
		"frigate":{"id":"frigate", "class":"Frigate"},
		"cruiser":{"id":"cruiser", "class":"Cruiser"}
	}
	var ships: Array = [
		{"instance_id":"SHIP-004", "name":"Alpha", "registry_code":"RG-A4", "blueprint_id":"frigate", "maintenance_state":"ACTIVE"},
		{"instance_id":"SHIP-002", "name":"beta", "blueprint_id":"frigate", "maintenance_state":"ACTIVE"},
		{"instance_id":"SHIP-003", "name":"Alpha", "blueprint_id":"cruiser", "maintenance_state":"READY_RESERVE"},
		{"instance_id":"SHIP-001", "name":"delta", "blueprint_id":"cruiser", "maintenance_state":"MOTHBALLED"},
		{"instance_id":"SHIP-005", "name":"", "blueprint_id":"frigate", "maintenance_state":"ACTIVE"}
	]
	var formations := {"SHIP-004":"formation_a", "SHIP-003":"formation_b"}
	var formation_lookup := func(ship_id: String): return String(formations.get(ship_id, ""))
	var before := ships.duplicate(true)
	_check(_ids(_derive(ships, definitions, formation_lookup, "Alpha")) == ["SHIP-004", "SHIP-003"], "search matches exact and partial displayed names")
	_check(_ids(_derive(ships, definitions, formation_lookup, "  ALpHa  ")) == ["SHIP-004", "SHIP-003"], "Latin search is case-insensitive and trims surrounding whitespace")
	_check(_ids(_derive(ships, definitions, formation_lookup, "ship-002")) == ["SHIP-002"], "search matches canonical Ship ID")
	_check(_ids(_derive(ships, definitions, formation_lookup, "rg-a4")) == ["SHIP-004"], "search matches an optional canonical registry code")
	_check(_ids(_derive(ships, definitions, formation_lookup, "")) == ["SHIP-004", "SHIP-002", "SHIP-003", "SHIP-001", "SHIP-005"] and _ids(_derive(ships, definitions, formation_lookup, "   ")) == ["SHIP-004", "SHIP-002", "SHIP-003", "SHIP-001", "SHIP-005"], "empty and whitespace-only search restore canonical order")
	_check(_derive(ships, definitions, formation_lookup, "missing registry").is_empty(), "missing registry codes and zero-result queries do not match presentation fallbacks")

	_check(_ids(Query.derive(ships, "ALL", "", "FRIGATE", "", Query.SORT_CANONICAL, definitions, formation_lookup)) == ["SHIP-004", "SHIP-002", "SHIP-005"], "All Ship Types and a real canonical ship type filter correctly")
	_check(_ids(Query.derive(ships, "ALL", "", "", "formation_a", Query.SORT_CANONICAL, definitions, formation_lookup)) == ["SHIP-004"], "real formation identifier filters the result")
	_check(_ids(Query.derive(ships, "ALL", "", "", Query.UNASSIGNED_FORMATION, Query.SORT_CANONICAL, definitions, formation_lookup)) == ["SHIP-002", "SHIP-001", "SHIP-005"], "Unassigned formation uses its internal sentinel rather than the rendered em dash")
	_check(_ids(Query.derive(ships, "ACTIVE", "alp", "FRIGATE", "formation_a", Query.SORT_CANONICAL, definitions, formation_lookup)) == ["SHIP-004"], "lifecycle + search + type + formation combine with logical AND")
	formations["SHIP-002"] = "formation_a"
	_check(_ids(Query.derive(ships, "ACTIVE", "", "FRIGATE", "formation_a", Query.SORT_CANONICAL, definitions, formation_lookup)) == ["SHIP-004", "SHIP-002"], "runtime formation changes are reflected by a fresh projection")

	_check(_ids(Query.derive(ships, "ALL", "", "", "", Query.SORT_CANONICAL, definitions, formation_lookup)) == ["SHIP-004", "SHIP-002", "SHIP-003", "SHIP-001", "SHIP-005"], "canonical registry sort restores source order")
	_check(_ids(Query.derive(ships, "ALL", "", "", "", Query.SORT_NAME_ASCENDING, definitions, formation_lookup)) == ["SHIP-003", "SHIP-004", "SHIP-002", "SHIP-001", "SHIP-005"], "name ascending is deterministic with missing values last and Ship ID tie-breaks")
	_check(_ids(Query.derive(ships, "ALL", "", "", "", Query.SORT_NAME_DESCENDING, definitions, formation_lookup)) == ["SHIP-001", "SHIP-002", "SHIP-003", "SHIP-004", "SHIP-005"], "name descending keeps missing values last and duplicate names stable by Ship ID")
	_check(_ids(Query.derive(ships, "ALL", "", "", "", Query.SORT_TYPE_THEN_NAME, definitions, formation_lookup)) == ["SHIP-003", "SHIP-001", "SHIP-004", "SHIP-002", "SHIP-005"], "ship type then name uses canonical type identity and final Ship ID tie-breaker")
	_check(_ids(Query.derive(ships, "ALL", "", "", "", Query.SORT_FORMATION_THEN_NAME, definitions, formation_lookup)) == ["SHIP-004", "SHIP-002", "SHIP-003", "SHIP-001", "SHIP-005"], "formation then name has deterministic missing-value placement")
	_check(Query.ship_type_ids(ships, definitions) == ["CRUISER", "FRIGATE"], "type options derive from real ship instances plus canonical definitions")
	_check(ships == before, "search/filter/sort never mutates canonical ship-domain data")


func _derive(ships: Array, definitions: Dictionary, formation_lookup: Callable, query: String) -> Array:
	return Query.derive(ships, "ALL", query, "", "", Query.SORT_CANONICAL, definitions, formation_lookup)


func _test_registry_ui_at_scale(scale_value: float) -> void:
	Game.reset_game()
	var modules := ["light_autocannon", "civilian_shield", "basic_drive", "sensor_array", "civilian_reactor_core"]
	var horizon := Game.state._create_ship_instance("belt_cruiser", modules, "ISS Horizon")
	var reserve := Game.state._create_ship_instance("lunar_pathfinder", modules, "ISS Reserve")
	reserve["maintenance_state"] = "READY_RESERVE"
	reserve["registry_code"] = "RSV-77"
	var unassigned_cruiser := Game.state._create_ship_instance("belt_cruiser", modules, "ISS Ranger")
	Game.state.set_formation_ship_ids(SpaceGameState.DEFAULT_FORMATION_ID, [String(horizon.get("instance_id", ""))])
	var domain_before := Game.state.ships.duplicate(true)
	get_tree().root.set_meta(UiTokens.UI_SCALE_SESSION_META, scale_value)
	var interaction_viewport := SubViewport.new()
	interaction_viewport.name = "ShipRegistryStep09InteractionViewport"
	interaction_viewport.size = Vector2i(1672, 941)
	interaction_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	interaction_viewport.gui_embed_subwindows = true
	add_child(interaction_viewport)
	var main := MainScene.instantiate() as Control
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1672, 941)
	interaction_viewport.add_child(main)
	await _redraw()
	var fleet_nav := main.find_child("Navigation_ships", true, false) as Button
	if fleet_nav != null:
		fleet_nav.pressed.emit()
	await _redraw()

	var toolbar := main.find_child("FleetRosterFilters", true, false) as HBoxContainer
	var query_controls := main.find_child("FleetRosterQueryControls", true, false) as HBoxContainer
	var search := main.find_child("FleetRosterSearch", true, false) as LineEdit
	var type_filter := main.find_child("FleetRosterShipTypeFilter", true, false) as MenuButton
	var formation_filter := main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
	var sort_control := main.find_child("FleetRosterSort", true, false) as MenuButton
	var master_detail := main.find_child("FleetRosterMasterDetail", true, false) as HBoxContainer
	_check(toolbar != null and query_controls != null and search != null and type_filter != null and formation_filter != null and sort_control != null and master_detail != null, "STEP 09 toolbar exists above the unchanged Master–Detail workspace at %d%%" % int(scale_value * 100.0))
	var scale_ratio := scale_value / 1.5
	_check(absf(search.size.x - roundi(302.0 * scale_ratio)) <= 1.0 and absf(type_filter.size.x - roundi(150.0 * scale_ratio)) <= 1.0 and absf(formation_filter.size.x - roundi(141.0 * scale_ratio)) <= 1.0 and absf(sort_control.size.x - roundi(146.0 * scale_ratio)) <= 1.0, "toolbar controls follow the one canonical 100%/150% scale path")
	_check(query_controls.global_position.x + query_controls.size.x <= toolbar.global_position.x + toolbar.size.x + 1.0 and master_detail.global_position.y > toolbar.get_global_rect().end.y, "query controls right-align on the lifecycle row and Master–Detail stays directly beneath it")
	_check(search.focus_next == search.get_path_to(type_filter) and type_filter.focus_next == type_filter.get_path_to(formation_filter) and formation_filter.focus_next == formation_filter.get_path_to(sort_control), "Tab order is Search → Ship Type → Formation → Sort")
	_check(search.get_signal_connection_list("text_changed").filter(func(connection): return (connection.get("callable") as Callable).get_method() == "_on_fleet_roster_search_changed").size() == 1, "search rebuild has exactly one signal path")
	_check(search.placeholder_text == I18n.core("ships.roster.search.placeholder"), "localized search placeholder is current")
	_check(_popup_metadata(type_filter.get_popup()) == ["", "CRUISER", "FRIGATE"], "Ship Type popup contains All plus only real types represented by the registry")
	_check(_popup_metadata(formation_filter.get_popup()) == ["", SpaceGameState.DEFAULT_FORMATION_ID, Query.UNASSIGNED_FORMATION], "Formation popup contains All, real formations, and canonical Unassigned sentinel")
	_check(_popup_metadata(sort_control.get_popup()) == Query.SORT_MODES, "Sort popup exposes the five approved real sort modes")

	if is_equal_approx(scale_value, 1.5):
		# Regression for the STEP 09 Formation-popup evidence defect: use the
		# control's normal keyboard activation path, prove that the real PopupMenu
		# is visible and populated, and activate two canonical choices through the
		# focused popup rather than assigning query state directly.
		var domain_before_formation_interaction := Game.state.ships.duplicate(true)
		var formation_popup := await _open_menu_button_through_keyboard(formation_filter)
		_check(is_instance_valid(formation_popup) and formation_popup.visible, "keyboard activation opens the real Formation PopupMenu")
		if is_instance_valid(formation_popup):
			_check(_popup_metadata(formation_popup) == ["", SpaceGameState.DEFAULT_FORMATION_ID, Query.UNASSIGNED_FORMATION], "open Formation popup exposes All, First Task Force, and Unassigned canonical identities")
			_check(_popup_labels(formation_popup) == ["全部编队", "第一特遣队", "未编队"], "open Formation popup exposes all localized Chinese labels")
			_check(_signal_handler_count(formation_popup, "id_pressed", "_on_fleet_roster_formation_selected") == 1, "Formation popup has exactly one production selection callback")
			var popup_rect := Rect2(formation_popup.position, formation_popup.size)
			var origin_rect := formation_filter.get_global_rect()
			var viewport_rect := formation_filter.get_viewport_rect()
			_check(absf(popup_rect.position.y - origin_rect.end.y) <= 1.0 and viewport_rect.encloses(popup_rect), "Formation popup anchors beneath its control and remains inside the controlled viewport (popup=%s origin=%s viewport=%s)" % [popup_rect, origin_rect, viewport_rect])
			main.call("_request_active_page_refresh", true)
			await _redraw()
			_check(formation_popup.visible, "a pending domain refresh does not destroy a newly opened Formation popup")
			var competing_type_filter := main.find_child("FleetRosterShipTypeFilter", true, false) as MenuButton
			var competing_popup := await _show_menu_button(competing_type_filter)
			_check(not formation_popup.visible and is_instance_valid(competing_popup) and competing_popup.visible, "opening another query dropdown closes the Formation popup")
			if is_instance_valid(competing_popup):
				_push_cancel(competing_type_filter.get_viewport())
				await _redraw()
				_check(not competing_popup.visible, "Escape closes the active query popup")
				_check(competing_type_filter.has_focus(), "closing a query popup restores focus to its origin control (focus=%s)" % str(competing_type_filter.get_viewport().gui_get_focus_owner()))
		formation_filter = main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
		formation_popup = await _open_menu_button_through_keyboard(formation_filter)
		if is_instance_valid(formation_popup):
			await _activate_popup_metadata_through_keyboard(formation_popup, SpaceGameState.DEFAULT_FORMATION_ID)
			await _redraw()
			_check(_visible_ship_names(main) == ["ISS Horizon"], "selecting First Task Force through the open popup updates the canonical result pipeline")
		formation_filter = main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
		formation_popup = await _open_menu_button_through_keyboard(formation_filter)
		_check(is_instance_valid(formation_popup) and formation_popup.visible, "Formation popup can reopen after selecting First Task Force")
		if is_instance_valid(formation_popup):
			await _activate_popup_metadata_through_keyboard(formation_popup, Query.UNASSIGNED_FORMATION)
			await _redraw()
			_check(_visible_ship_names(main) == ["ISS Pioneer", "ISS Reserve", "ISS Ranger"], "selecting Unassigned through the reopened popup updates the result pipeline")
		_check(Game.state.ships == domain_before_formation_interaction, "Formation popup interaction does not mutate ship-domain data")
		formation_filter = main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
		var reset_popup := await _open_menu_button_through_keyboard(formation_filter)
		if is_instance_valid(reset_popup):
			await _activate_popup_metadata_through_keyboard(reset_popup, Query.ALL_FORMATIONS)
			await _redraw()

		search = main.find_child("FleetRosterSearch", true, false) as LineEdit
		type_filter = main.find_child("FleetRosterShipTypeFilter", true, false) as MenuButton
		search.text = "  horizon "
		search.text_changed.emit(search.text)
		await _redraw()
		_check(_visible_ship_names(main) == ["ISS Horizon"] and String(main.call("_fleet_roster_selected_ship_id")) == String(horizon.get("instance_id", "")), "live search updates rows and deterministically synchronizes Inspector selection")
		search.text = ""
		search.text_changed.emit("")
		await _redraw()
		_check(String(main.call("_fleet_roster_selected_ship_id")) == String(horizon.get("instance_id", "")), "clearing search preserves a selected ship that remains visible")
		_select_popup_metadata(type_filter, "CRUISER")
		await _redraw()
		_check(_visible_ship_names(main) == ["ISS Horizon", "ISS Ranger"], "real Ship Type option restricts the visible registry")
		formation_filter = main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
		_select_popup_metadata(formation_filter, Query.UNASSIGNED_FORMATION)
		await _redraw()
		_check(_visible_ship_names(main) == ["ISS Ranger"], "Unassigned combines with the active type filter")
		search = main.find_child("FleetRosterSearch", true, false) as LineEdit
		search.text = "no match"
		search.text_changed.emit(search.text)
		await _redraw()
		_check(_visible_ship_names(main).is_empty() and String(main.call("_fleet_roster_selected_ship_id")).is_empty() and main.find_child("FleetRosterFavorite", true, false) == null and _has_exact_label(main, "未找到符合当前条件的舰船"), "zero results clear Inspector selection, disable stale actions, and show the localized neutral empty state")
		search.text = ""
		search.text_changed.emit("")
		await _redraw()
		main.set("_fleet_roster_ship_type_filter", "")
		main.set("_fleet_roster_formation_filter", "")
		main.call("_rebuild_active_page")
		await _redraw()
		var horizon_row := main.find_child("FleetRosterShip_%s" % String(horizon.get("instance_id", "")), true, false) as Button
		if horizon_row != null:
			horizon_row.pressed.emit()
		await _redraw()
		Game.state.ship_by_id(String(horizon.get("instance_id", "")))["favorite"] = true
		Game.state.ship_by_id(String(horizon.get("instance_id", "")))["locked"] = true
		main.call("_refresh_fleet_roster_results")
		await _redraw()
		_check((main.find_child("FleetRosterFavorite", true, false) as Button).button_pressed and (main.find_child("FleetRosterLock", true, false) as Button).button_pressed, "Favorite and Lock canonical states survive list rebuilding")
		var selected_before_sort := String(main.call("_fleet_roster_selected_ship_id"))
		sort_control = main.find_child("FleetRosterSort", true, false) as MenuButton
		_select_popup_metadata(sort_control, Query.SORT_NAME_DESCENDING)
		await _redraw()
		_check(String(main.call("_fleet_roster_selected_ship_id")) == selected_before_sort, "sorting reorders rows without changing selected Ship ID")
		Game.state.fleet_formations["audit_wing"] = {"id":"audit_wing", "name":"Audit Wing", "ship_ids":[]}
		main.call("_rebuild_active_page")
		await _redraw()
		formation_filter = main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
		_check(_popup_metadata(formation_filter.get_popup()).has("audit_wing"), "runtime formation additions refresh available options")
		main.set("_fleet_roster_formation_filter", "audit_wing")
		Game.state.fleet_formations.erase("audit_wing")
		main.call("_rebuild_active_page")
		await _redraw()
		_check(String(main.get("_fleet_roster_formation_filter")).is_empty(), "removed selected formation safely falls back to All Formations")
		I18n.set_locale("en")
		main.call("_rebuild_active_page")
		await _redraw()
		type_filter = main.find_child("FleetRosterShipTypeFilter", true, false) as MenuButton
		formation_filter = main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
		sort_control = main.find_child("FleetRosterSort", true, false) as MenuButton
		_check(type_filter.text == "Ship Type" and formation_filter.text == "Formation" and sort_control.text == "Name: Z–A" and _popup_metadata(sort_control.get_popup()) == Query.SORT_MODES and String(main.get("_fleet_roster_sort_mode")) == Query.SORT_NAME_DESCENDING, "Chinese/English labels change without changing canonical option identities or sort order")
		I18n.set_locale("zh_CN")

	# UI-only query state and navigation selection do not alter ship records.
	for ship_index in Game.state.ships.size():
		if is_equal_approx(scale_value, 1.5) and String(Game.state.ships[ship_index].get("instance_id", "")) == String(horizon.get("instance_id", "")):
			# The two explicitly asserted favorite/lock mutations are STEP 08 domain
			# state and are excluded from the query immutability comparison.
			Game.state.ships[ship_index]["favorite"] = domain_before[ship_index].get("favorite", false)
			Game.state.ships[ship_index]["locked"] = domain_before[ship_index].get("locked", false)
	_check(Game.state.ships == domain_before, "STEP 09 UI state never mutates canonical ship records")
	interaction_viewport.queue_free()
	await get_tree().process_frame


func _ids(ships: Array) -> Array[String]:
	var result: Array[String] = []
	for ship_value in ships:
		result.append(String((ship_value as Dictionary).get("instance_id", "")))
	return result


func _visible_ship_names(root: Node) -> Array[String]:
	var result: Array[String] = []
	var ship_list := root.find_child("FleetRosterShipList", true, false)
	if ship_list == null:
		return result
	for child in ship_list.get_children():
		if child is Button and String(child.name).begins_with("FleetRosterShip_"):
			var label := child.find_child("FleetRosterShipName_*", true, false) as Label
			if label != null:
				result.append(label.text)
	return result


func _popup_metadata(popup: PopupMenu) -> Array[String]:
	var result: Array[String] = []
	for item_index in popup.item_count:
		result.append(String(popup.get_item_metadata(item_index)))
	return result


func _popup_labels(popup: PopupMenu) -> Array[String]:
	var result: Array[String] = []
	for item_index in popup.item_count:
		result.append(popup.get_item_text(item_index))
	return result


func _open_menu_button_through_keyboard(button: MenuButton) -> PopupMenu:
	button.grab_focus()
	_push_accept(button.get_viewport())
	for _frame in range(8):
		await get_tree().process_frame
		if button.get_popup().visible:
			break
	return button.get_popup()


func _show_menu_button(button: MenuButton) -> PopupMenu:
	button.grab_focus()
	button.show_popup()
	for _frame in range(8):
		await get_tree().process_frame
		if button.get_popup().visible:
			break
	return button.get_popup()


func _activate_popup_metadata_through_keyboard(popup: PopupMenu, expected: String) -> void:
	for item_index in popup.item_count:
		if String(popup.get_item_metadata(item_index)) != expected:
			continue
		# The menu itself was opened through ui_accept above. Emit the PopupMenu's
		# real item activation signal (rather than assigning filter state) so the
		# same bound production handler, refresh, and persistence path executes.
		popup.id_pressed.emit(popup.get_item_id(item_index))
		popup.hide()
		await get_tree().process_frame
		await get_tree().process_frame
		return
	_check(false, "Popup option exists for keyboard activation: %s" % expected)


func _push_accept(viewport: Viewport) -> void:
	var press := InputEventAction.new()
	press.action = "ui_accept"
	press.pressed = true
	viewport.push_input(press)
	var release := InputEventAction.new()
	release.action = "ui_accept"
	release.pressed = false
	viewport.push_input(release)


func _push_cancel(viewport: Viewport) -> void:
	var press := InputEventAction.new()
	press.action = "ui_cancel"
	press.pressed = true
	viewport.push_input(press)
	var release := InputEventAction.new()
	release.action = "ui_cancel"
	release.pressed = false
	viewport.push_input(release)


func _signal_handler_count(object: Object, signal_name: String, method_name: String) -> int:
	var count := 0
	for connection in object.get_signal_connection_list(signal_name):
		var callback := connection.get("callable") as Callable
		if callback.get_method() == method_name:
			count += 1
	return count


func _select_popup_metadata(button: MenuButton, expected: String) -> void:
	var popup := button.get_popup()
	for item_index in popup.item_count:
		if String(popup.get_item_metadata(item_index)) == expected:
			popup.id_pressed.emit(popup.get_item_id(item_index))
			return


func _has_exact_label(root: Node, expected: String) -> bool:
	for child in root.find_children("*", "Label", true, false):
		if (child as Label).text == expected:
			return true
	return false


func _redraw() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
