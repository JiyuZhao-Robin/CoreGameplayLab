extends Node

const MainScene := preload("res://src/ui/main.tscn")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")

const MATRIX_VIEWPORTS := [
	Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1440, 900),
	Vector2i(1600, 900), Vector2i(1672, 941), Vector2i(1920, 1080),
	Vector2i(1920, 1200), Vector2i(2560, 1080), Vector2i(2560, 1440),
	Vector2i(3440, 1440), Vector2i(3840, 2160)
]

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Engine.time_scale = 0.0
	I18n.set_locale("zh_CN")
	Game.reset_game()
	# MainScene performs canonical lazy initialization on first presentation.
	# Warm it once, then prove every QA-only transition is Domain-neutral.
	var warmup := await _spawn_roster(Vector2i(1280, 720), 1.0)
	(warmup.viewport as SubViewport).queue_free()
	await _settle()
	var domain_before := Game.state.to_dictionary()
	_test_scale_policy()
	for viewport_size in MATRIX_VIEWPORTS:
		await _test_matrix_combination(viewport_size, 1.0)
		if UiTokens.ui_scale_supported_for_viewport(1.5, viewport_size):
			await _test_matrix_combination(viewport_size, 1.5)
		if UiTokens.ui_scale_supported_for_viewport(2.0, viewport_size):
			await _test_matrix_combination(viewport_size, 2.0)
	await _test_scale_roundtrip()
	await _test_live_resize_and_transients()
	if OS.get_cmdline_user_args().has("--exercise-window-mode"):
		await _test_window_mode_roundtrip()
	_check(Game.state.to_dictionary() == domain_before, "scale, resize, popup and modal QA never mutate Domain state")
	get_tree().root.remove_meta(UiTokens.UI_SCALE_SESSION_META)
	UiTokens.set_ui_scale(UiTokens.DEFAULT_UI_SCALE)
	I18n.set_locale("zh_CN")
	Engine.time_scale = 1.0
	if failures.is_empty():
		print("SHIP_REGISTRY_STEP12_TEST_PASS")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _test_scale_policy() -> void:
	_check(UiTokens.minimum_viewport_for_ui_scale(1.0) == Vector2i(1280, 720), "100% supports the audited compact minimum")
	_check(UiTokens.minimum_viewport_for_ui_scale(1.5) == Vector2i(1600, 900), "150% declares its measured minimum viewport")
	_check(UiTokens.minimum_viewport_for_ui_scale(2.0) == Vector2i(2560, 1440), "200% declares its measured minimum viewport")
	_check(not UiTokens.ui_scale_supported_for_viewport(1.5, Vector2i(1366, 768)), "compact windows do not falsely claim 150% support")
	_check(not UiTokens.ui_scale_supported_for_viewport(2.0, Vector2i(2560, 1080)), "short ultrawide windows do not falsely claim 200% support")


func _test_matrix_combination(viewport_size: Vector2i, scale_value: float) -> void:
	var fixture := await _spawn_roster(viewport_size, scale_value)
	var viewport := fixture.viewport as SubViewport
	var main := fixture.main as Control
	var root_bounds := Rect2(Vector2.ZERO, Vector2(viewport_size)).grow(1.0)
	var page := main.find_child("fleet", true, false) as ScrollContainer
	var inspector_host := main.find_child("FleetRosterInspectorHost", true, false) as ScrollContainer
	var browser := main.find_child("FleetRosterListSurface", true, false) as Control
	var inspector := main.find_child("FleetRosterInspectorSurface", true, false) as Control
	var search := main.find_child("FleetRosterSearch", true, false) as Control
	var ship_type := main.find_child("FleetRosterShipTypeFilter", true, false) as Control
	var formation := main.find_child("FleetRosterFormationFilter", true, false) as Control
	var sort := main.find_child("FleetRosterSort", true, false) as Control
	var footer := main.find_child("FleetRosterFooterActions", true, false) as Control
	var ship_art := main.find_child("FleetRosterShipVisual", true, false) as TextureRect
	var transforms_native := main.scale.is_equal_approx(Vector2.ONE)
	var transformed_controls: Array[String] = []
	for node_value in main.find_children("*", "Control", true, false):
		var control := node_value as Control
		# GraphEdit owns an independent canvas zoom for hidden Research nodes. The
		# Ship Registry and shell must remain native; canvas zoom is not UI scale.
		if is_instance_valid(control) and is_instance_valid(page) and page.is_ancestor_of(control) and not control.scale.is_equal_approx(Vector2.ONE):
			transforms_native = false
			transformed_controls.append("%s=%s" % [control.name, control.scale])
	if not transformed_controls.is_empty():
		print("STEP12_NON_NATIVE_CONTROLS: %s" % ", ".join(transformed_controls))
	var page_h := page.get_h_scroll_bar() if is_instance_valid(page) else null
	var page_v := page.get_v_scroll_bar() if is_instance_valid(page) else null
	var host_h := inspector_host.get_h_scroll_bar() if is_instance_valid(inspector_host) else null
	var shell_inside := _inside_rect(root_bounds, [browser, inspector, search, ship_type, formation, sort])
	var no_page_scroll := is_instance_valid(page_h) and not page_h.visible and is_instance_valid(page_v) and not page_v.visible
	var no_horizontal_scroll := is_instance_valid(host_h) and not host_h.visible
	var footer_accessible := is_instance_valid(inspector_host) and is_instance_valid(footer)
	if footer_accessible and inspector_host.get_v_scroll_bar().visible:
		inspector_host.scroll_vertical = int(inspector_host.get_v_scroll_bar().max_value)
		await _settle()
		footer_accessible = inspector_host.get_global_rect().grow(1.0).intersects(footer.get_global_rect())
	_check(main.size.is_equal_approx(Vector2(viewport_size)), "%s/%d%% root follows the actual usable viewport" % [viewport_size, int(scale_value * 100.0)])
	_check(transforms_native, "%s/%d%% uses native Control geometry without nested scale transforms" % [viewport_size, int(scale_value * 100.0)])
	_check(is_equal_approx(main.get_window().content_scale_factor, 1.0), "%s/%d%% keeps content_scale_factor at 1" % [viewport_size, int(scale_value * 100.0)])
	_check(shell_inside and no_page_scroll and no_horizontal_scroll, "%s/%d%% keeps the roster shell inside the viewport without page/horizontal scroll" % [viewport_size, int(scale_value * 100.0)])
	_check(footer_accessible, "%s/%d%% keeps all Inspector footer actions reachable" % [viewport_size, int(scale_value * 100.0)])
	_check(is_instance_valid(ship_art) and ship_art.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "%s/%d%% preserves aspect-centered ship artwork" % [viewport_size, int(scale_value * 100.0)])
	print("STEP12_MATRIX_PASS viewport=%dx%d scale=%d page_scroll=%s inspector_scroll=%s" % [viewport_size.x, viewport_size.y, int(scale_value * 100.0), page_v.visible, inspector_host.get_v_scroll_bar().visible])
	viewport.queue_free()
	await _settle()


func _test_scale_roundtrip() -> void:
	var signatures: Array[String] = []
	var state_before := Game.state.to_dictionary()
	for scale_value in [1.0, 1.5, 2.0, 1.0]:
		var fixture := await _spawn_roster(Vector2i(2560, 1440), scale_value)
		var main := fixture.main as Control
		signatures.append(_geometry_signature(main))
		(fixture.viewport as SubViewport).queue_free()
		await _settle()
	_check(signatures.size() == 4 and signatures[0] == signatures[3], "100→150→200→100 returns to byte-stable integer geometry without rounding drift")
	_check(Game.state.to_dictionary() == state_before, "UI scale roundtrip does not rebuild or mutate Domain data")


func _test_live_resize_and_transients() -> void:
	# This fixture audits transient geometry, not Theme reconstruction. Keep its
	# Manual preference valid across every compact/grown resize in the sequence;
	# unsafe high-scale fallback/recovery has a dedicated responsive contract test.
	var fixture := await _spawn_roster(Vector2i(1672, 941), 1.0)
	var viewport := fixture.viewport as SubViewport
	var main := fixture.main as Control
	var ship_id := String(main.call("_fleet_roster_selected_ship_id"))
	var query := String(Game.state.ship_by_id(ship_id).get("name", ""))
	main.call("_on_fleet_roster_search_changed", query)
	await _settle()
	var checkbox := main.find_child("FleetRosterSelectionControl_%s" % ship_id, true, false) as CheckBox
	if is_instance_valid(checkbox):
		checkbox.button_pressed = true
		checkbox.toggled.emit(true)
	await _settle()
	var selection = main.get("_fleet_roster_selection_state")
	var primary_before := String(selection.primary_ship_id)
	var bulk_before := _bulk_ids(selection)
	for transition in [
		[Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(1280, 720)],
		[Vector2i(1672, 941), Vector2i(2560, 1440), Vector2i(1672, 941)],
		[Vector2i(1920, 1080), Vector2i(3440, 1440), Vector2i(1920, 1080)]
	]:
		for target in transition:
			viewport.size = target
			main.size = Vector2(target)
			await _settle()
			selection = main.get("_fleet_roster_selection_state")
			_check(String(selection.primary_ship_id) == primary_before and _bulk_ids(selection) == bulk_before, "resize %s preserves primary and bulk canonical IDs" % target)
			_check(String(main.get("_fleet_roster_search_query")) == query, "resize %s preserves active search text" % target)

	viewport.size = Vector2i(1672, 941)
	main.size = Vector2(1672, 941)
	await _settle()
	var formation := main.find_child("FleetRosterFormationFilter", true, false) as MenuButton
	if is_instance_valid(formation):
		formation.show_popup()
	await _settle()
	var formation_popup := formation.get_popup() if is_instance_valid(formation) else null
	if is_instance_valid(formation_popup):
		main.call("_position_fleet_roster_query_popup", formation, formation_popup)
		viewport.size = Vector2i(1920, 1080)
		main.size = Vector2(1920, 1080)
		await _settle()
	_check(_popup_inside(viewport, formation_popup), "Formation popup remains above the Inspector and inside the resized viewport")
	if is_instance_valid(formation_popup):
		formation_popup.hide()
	await _settle()
	viewport.size = Vector2i(1672, 941)
	main.size = Vector2(1672, 941)
	await _settle()

	var more := main.find_child("FleetRosterMore", true, false) as Button
	if is_instance_valid(more) and not more.disabled:
		more.pressed.emit()
	await _settle()
	var more_popup := main.get("_fleet_roster_popup") as PopupMenu
	viewport.size = Vector2i(1280, 720)
	main.size = Vector2(1280, 720)
	await _settle()
	_check(_popup_inside(viewport, more_popup), "More popup remains inside the viewport during compact live resize")
	if is_instance_valid(more_popup):
		more_popup.hide()
	await _settle()
	viewport.size = Vector2i(1672, 941)
	main.size = Vector2(1672, 941)
	await _settle()

	var bulk_actions := main.find_child("FleetRosterBulkActions", true, false) as Button
	if is_instance_valid(bulk_actions):
		bulk_actions.pressed.emit()
	await _settle()
	var bulk_popup := main.get("_fleet_roster_popup") as PopupMenu
	viewport.size = Vector2i(1920, 1080)
	main.size = Vector2(1920, 1080)
	await _settle()
	_check(_popup_inside(viewport, bulk_popup), "Bulk Actions popup remains inside the viewport after live resizing")
	if is_instance_valid(bulk_popup):
		bulk_popup.hide()
	await _settle()
	viewport.size = Vector2i(1672, 941)
	main.size = Vector2(1672, 941)
	await _settle()

	main.call("_request_fleet_roster_bulk_dismantle")
	await _settle()
	var bulk_modal := main.get("_fleet_roster_bulk_dismantle_dialog") as Control
	viewport.size = Vector2i(1280, 720)
	main.size = Vector2(1280, 720)
	await _settle()
	var bulk_scrim := bulk_modal.find_child("FleetRosterDismantleScrim", true, false) as Control if is_instance_valid(bulk_modal) else null
	_check(is_instance_valid(bulk_modal) and bulk_modal.get_global_rect().is_equal_approx(main.get_global_rect()) and is_instance_valid(bulk_scrim) and bulk_scrim.get_global_rect().is_equal_approx(main.get_global_rect()), "bulk dismantle modal retains full-viewport ownership during compact resize")
	if is_instance_valid(bulk_modal):
		var bulk_cancel := bulk_modal.find_child("FleetRosterCancelDismantle", true, false) as Button
		if is_instance_valid(bulk_cancel):
			bulk_cancel.pressed.emit()
	await _settle()
	viewport.size = Vector2i(1672, 941)
	main.size = Vector2(1672, 941)
	await _settle()

	var dismantle := main.find_child("FleetRosterDismantle", true, false) as Button
	if is_instance_valid(dismantle) and not dismantle.disabled:
		dismantle.pressed.emit()
	await _settle()
	var modal := main.get("_fleet_roster_dismantle_dialog") as Control
	viewport.size = Vector2i(1920, 1080)
	main.size = Vector2(1920, 1080)
	await _settle()
	var scrim := modal.find_child("FleetRosterDismantleScrim", true, false) as Control if is_instance_valid(modal) else null
	_check(is_instance_valid(modal) and modal.get_global_rect().is_equal_approx(main.get_global_rect()) and is_instance_valid(scrim) and scrim.get_global_rect().is_equal_approx(main.get_global_rect()), "single dismantle modal traps a full-viewport scrim after resize")
	if is_instance_valid(modal):
		var cancel := modal.find_child("FleetRosterCancelDismantle", true, false) as Button
		if is_instance_valid(cancel):
			cancel.pressed.emit()
	await _settle()
	viewport.size = Vector2i(1280, 720)
	main.size = Vector2(1280, 720)
	main.call("_on_fleet_roster_search_changed", "NO-SUCH-SHIP")
	await _settle()
	selection = main.get("_fleet_roster_selection_state")
	_check(String(selection.primary_ship_id).is_empty() and _has_exact_label(main, I18n.core("ships.roster.no_results")), "zero-result state remains cleared and visible during compact resize")
	main.call("_on_fleet_roster_search_changed", query)
	viewport.size = Vector2i(1672, 941)
	main.size = Vector2(1672, 941)
	await _settle()
	selection = main.get("_fleet_roster_selection_state")
	var restored_primary := String(selection.primary_ship_id)
	var restored_bulk := _bulk_ids(selection)

	I18n.set_locale("en")
	await _settle()
	I18n.set_locale("zh_CN")
	await _settle()
	selection = main.get("_fleet_roster_selection_state")
	_check(String(selection.primary_ship_id) == restored_primary and _bulk_ids(selection) == restored_bulk, "Chinese→English→Chinese preserves canonical selections")
	_check(String(main.get("_fleet_roster_search_query")) == query, "language roundtrip preserves the presentation query state")
	viewport.queue_free()
	await _settle()


func _test_window_mode_roundtrip() -> void:
	var window := get_window()
	var original_mode := window.mode
	var original_size := window.size
	window.mode = Window.MODE_FULLSCREEN
	await _settle()
	_check(window.mode == Window.MODE_FULLSCREEN, "Windowed→fullscreen reaches the real host Window mode")
	window.mode = Window.MODE_WINDOWED
	window.size = original_size
	await _settle()
	_check(window.mode == Window.MODE_WINDOWED and window.size == original_size, "fullscreen→windowed restores the original host Window geometry")
	window.mode = original_mode


func _spawn_roster(viewport_size: Vector2i, scale_value: float) -> Dictionary:
	get_tree().root.set_meta(UiTokens.UI_SCALE_SESSION_META, scale_value)
	var viewport := SubViewport.new()
	viewport.size = viewport_size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.gui_embed_subwindows = true
	add_child(viewport)
	var main := MainScene.instantiate() as Control
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(viewport_size)
	main.set("_fleet_section", "roster")
	viewport.add_child(main)
	await _settle()
	var navigation := main.find_child("Navigation_ships", true, false) as Button
	if is_instance_valid(navigation):
		navigation.pressed.emit()
	await _settle()
	return {"viewport":viewport, "main":main}


func _geometry_signature(main: Control) -> String:
	var values: Array[String] = []
	for control_name in [
		"TopStatusBar", "WorkspaceNavigationBar", "FleetRosterFilters",
		"FleetRosterMasterDetail", "FleetRosterListSurface", "FleetRosterInspectorSurface",
		"FleetRosterShipVisualPanel", "FleetRosterOperationalStatusPanel",
		"FleetRosterBasicInformationPanel", "FleetRosterConfigurationSummaryPanel",
		"FleetRosterReadinessPanel", "FleetRosterFooterActions"
	]:
		var control := main.find_child(control_name, true, false) as Control
		if is_instance_valid(control):
			values.append("%s:%d,%d,%d,%d" % [control_name, roundi(control.position.x), roundi(control.position.y), roundi(control.size.x), roundi(control.size.y)])
	return "|".join(values)


func _inside_rect(bounds: Rect2, controls: Array) -> bool:
	for control_value in controls:
		var control := control_value as Control
		if not is_instance_valid(control) or not bounds.encloses(control.get_global_rect()):
			return false
	return true


func _popup_inside(viewport: SubViewport, popup: PopupMenu) -> bool:
	if not is_instance_valid(viewport) or not is_instance_valid(popup) or not popup.visible:
		return false
	return Rect2(Vector2.ZERO, Vector2(viewport.size)).grow(1.0).encloses(Rect2(Vector2(popup.position), Vector2(popup.size)))


func _bulk_ids(selection) -> Array[String]:
	var result: Array[String] = []
	for value in selection.bulk_selected_ship_ids.keys():
		result.append(String(value))
	result.sort()
	return result


func _has_exact_label(root: Node, expected_text: String) -> bool:
	for node_value in root.find_children("*", "Label", true, false):
		var label := node_value as Label
		if is_instance_valid(label) and label.visible and label.text == expected_text:
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)
		push_error("FAIL: %s" % message)


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
