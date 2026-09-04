extends Node

const MainScene := preload("res://src/ui/main.tscn")
const ResponsivePolicy := preload("res://src/ui/responsive_ui_policy.gd")
const RESULT_PATH := "res://artifacts/test-results/ui-persistence-audit.json"

var failures: Array[String] = []
var observations: Array[Dictionary] = []
var audit_root := ""
var marker_path := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var phase := ""
	var isolation_token := ""
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--ui-persistence-phase="):
			phase = argument.trim_prefix("--ui-persistence-phase=")
		elif argument.begins_with("--ui-persistence-isolation-token="):
			isolation_token = argument.trim_prefix("--ui-persistence-isolation-token=")
		elif argument.begins_with("--ui-persistence-root="):
			audit_root = argument.trim_prefix("--ui-persistence-root=").simplify_path()
	marker_path = audit_root.path_join("ui_persistence_audit_marker.json")
	_check(not isolation_token.is_empty() and audit_root.is_absolute_path() and audit_root.contains(isolation_token) and audit_root.get_file().begins_with("helios-ui-persistence-audit-"), "save, UI preferences and marker resolve inside the runner's unique isolated directory")
	if not Game.persistence_enabled:
		_fail("persistence audit must run without --no-persistence")
		_finish(phase)
		return
	match phase:
		"write": await _write_phase()
		"read": await _read_phase()
		_: _fail("persistence phase must be write or read")
	_finish(phase)


func _write_phase() -> void:
	Engine.time_scale = 0.0
	var main: Control = MainScene.instantiate()
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1440.0, 900.0)
	add_child(main)
	await _settle_ui()

	_press(main.find_child("RestartButton", true, false) as Button)
	await _settle_ui()
	var dialog := main.find_child("ResetConfirmation", true, false) as ConfirmationDialog
	_press(dialog.get_ok_button() if dialog != null else null)
	await _settle_ui()

	_press(main.find_child("Navigation_ships", true, false) as Button)
	await _settle_ui()
	var ship_id := String(Game.state.ships[0].get("instance_id", "")) if not Game.state.ships.is_empty() else ""
	var favorite_button := main.find_child("FleetRosterFavorite", true, false) as Button
	if favorite_button != null:
		favorite_button.button_pressed = true
		favorite_button.toggled.emit(true)
	await _settle_ui()
	var lock_button := main.find_child("FleetRosterLock", true, false) as Button
	if lock_button != null:
		lock_button.button_pressed = true
		lock_button.toggled.emit(true)
	await _settle_ui()
	var ship := Game.state.ship_by_id(ship_id)
	_check(not ship_id.is_empty() and bool(ship.get("favorite", false)) and bool(ship.get("locked", false)), "visible Ship Registry controls create Favorite and Lock state later loaded by the reader")
	main.set("_fleet_roster_search_query", "ISS")
	main.set("_fleet_roster_ship_type_filter", "FRIGATE")
	main.set("_fleet_roster_formation_filter", "__UNASSIGNED__")
	main.set("_fleet_roster_sort_mode", "NAME_ASCENDING")
	main.call("_save_ui_preferences")

	_press(main.find_child("Navigation_inventory", true, false) as Button)
	await _settle_ui()
	var revision_before := Game.state.revision
	_press(main.find_child("SaveButton", true, false) as Button)
	await _settle_ui()
	_check(FileAccess.file_exists(audit_root.path_join("space_idle_save.json")) and Game.state.revision > revision_before, "visible SaveButton writes the isolated LocalSaveRepository")
	var ui_preferences := ConfigFile.new()
	var ui_preferences_loaded := ui_preferences.load(audit_root.path_join("core_gameplay_ui.cfg")) == OK
	_check(ui_preferences_loaded and String(ui_preferences.get_value("display", "ui_scale_mode", "")) == "auto" and is_equal_approx(float(ui_preferences.get_value("display", "manual_ui_scale", 0.0)), 1.25), "AUTO mode and the independent Manual preference persist in the isolated device-local preference file")
	_check(ui_preferences_loaded and is_equal_approx(float(ui_preferences.get_value("display", "ui_scale", 0.0)), 1.25), "the legacy ui_scale rollback shadow stores the Manual preference")
	_check(ui_preferences_loaded and not ui_preferences.has_section_key("display", "recommended_ui_scale") and not ui_preferences.has_section_key("display", "effective_ui_scale"), "environment-dependent recommended and effective scales are never persisted")
	_check(ui_preferences_loaded and String(ui_preferences.get_value("ship_registry", "search_query", "")) == "ISS" and String(ui_preferences.get_value("ship_registry", "ship_type_filter", "")) == "FRIGATE" and String(ui_preferences.get_value("ship_registry", "formation_filter", "")) == "__UNASSIGNED__" and String(ui_preferences.get_value("ship_registry", "sort_mode", "")) == "NAME_ASCENDING", "STEP 09 presentation state uses the existing device-local UI preference file without changing the Domain save schema")

	var marker := FileAccess.open(marker_path, FileAccess.WRITE)
	if marker == null:
		_fail("writer creates the isolated persistence marker")
	else:
		marker.store_string(JSON.stringify({
			"saveId":Game.state.save_id,
			"shipId":ship_id,
			"revision":Game.state.revision,
			"activePage":"inventory",
			"writerObservations":observations.duplicate(true)
		}, "  "))
		_check(true, "writer records expected identity in isolated user data")
	main.queue_free()
	await get_tree().process_frame


func _read_phase() -> void:
	Engine.time_scale = 0.0
	var marker_data: Variant = JSON.parse_string(FileAccess.get_file_as_string(marker_path)) if FileAccess.file_exists(marker_path) else null
	_check(marker_data is Dictionary, "reader finds the writer marker in the same isolated user data directory")
	if not marker_data is Dictionary:
		return
	var marker := marker_data as Dictionary
	for observation_value in marker.get("writerObservations", []):
		if observation_value is Dictionary:
			observations.append((observation_value as Dictionary).duplicate(true))
	var main: Control = MainScene.instantiate()
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1440.0, 900.0)
	add_child(main)
	await _settle_ui()

	_check(Game.state.save_id == String(marker.get("saveId", "")) and Game.state.revision >= int(marker.get("revision", 0)), "startup auto-load restores stable Save identity and revision")
	var ship_id := String(marker.get("shipId", ""))
	var restored_ship := Game.state.ship_by_id(ship_id)
	_check(bool(restored_ship.get("favorite", false)) and bool(restored_ship.get("locked", false)), "startup auto-load restores the UI-created Favorite and Lock state")
	var inventory_page := main.find_child("inventory", true, false) as Control
	_check(inventory_page != null and inventory_page.is_visible_in_tree(), "UI preferences restore the last active core page")
	var ui_scale_selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	var responsive_snapshot: Dictionary = main.call("ui_responsive_snapshot")
	_check(ui_scale_selector != null and ui_scale_selector.get_item_id(ui_scale_selector.selected) == ResponsivePolicy.AUTO_SELECTOR_ID, "UI preferences restore AUTO independently of the Domain save")
	_check(String(responsive_snapshot.get("preferred_mode", "")) == ResponsivePolicy.MODE_AUTO and is_equal_approx(float(responsive_snapshot.get("manual_scale", 0.0)), 1.25), "AUTO restore retains the player's dormant Manual preference")
	_check(not Game.offline_report.is_empty() and float(Game.offline_report.get("simulated_ms", 0.0)) > 1000.0, "startup processes elapsed offline time through the shared orchestrator")
	var sidebar_text := _visible_text(main)
	_check(not Game.offline_report.is_empty() and sidebar_text.contains(I18n.core("sidebar.offline")), "the loaded UI visibly presents the offline-return report")

	_press(main.find_child("Navigation_ships", true, false) as Button)
	await _settle_ui()
	var favorite_button := main.find_child("FleetRosterFavorite", true, false) as Button
	var lock_button := main.find_child("FleetRosterLock", true, false) as Button
	var dismantle_button := main.find_child("FleetRosterDismantle", true, false) as Button
	_check(not restored_ship.is_empty() and favorite_button != null and favorite_button.button_pressed and lock_button != null and lock_button.button_pressed and dismantle_button != null and dismantle_button.disabled, "the loaded Ship Registry visibly restores Favorite, Lock, and the protected Dismantle state")
	var registry_search := main.find_child("FleetRosterSearch", true, false) as LineEdit
	_check(registry_search != null and registry_search.text == "ISS" and String(main.get("_fleet_roster_ship_type_filter")) == "FRIGATE" and String(main.get("_fleet_roster_formation_filter")) == "__UNASSIGNED__" and String(main.get("_fleet_roster_sort_mode")) == "NAME_ASCENDING", "STEP 09 search/filter/sort presentation state survives closing and reopening through the canonical UI preference layer")
	main.queue_free()
	await get_tree().process_frame


func _finish(phase: String) -> void:
	Engine.time_scale = 1.0
	if phase == "read":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RESULT_PATH.get_base_dir()))
		var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({
				"schemaVersion":1,
				"source":"tests/ui_persistence_audit_test.gd",
				"passed":failures.is_empty(),
				"observations":observations,
				"failures":failures,
				"isolation":"save, UI preferences and marker redirected to a unique platform-runner temporary root"
			}, "  "))
	if failures.is_empty():
		print("UI_PERSISTENCE_%s_PASS" % phase.to_upper())
		get_tree().quit(0)
	else:
		push_error("UI_PERSISTENCE_%s_FAIL\n%s" % [phase.to_upper(), "\n".join(failures)])
		get_tree().quit(1)


func _press(button: Button) -> void:
	if button == null or not button.is_visible_in_tree() or button.disabled:
		_fail("required visible enabled UI control is missing")
		return
	button.pressed.emit()


func _first_enabled_named_prefix(root: Node, prefix: String) -> Button:
	for value in root.find_children("%s*" % prefix, "Button", true, false):
		var button := value as Button
		if button.is_visible_in_tree() and not button.disabled:
			return button
	return null


func _visible_text(root: Node) -> String:
	if root == null:
		return ""
	var lines: Array[String] = []
	for value in root.find_children("*", "Control", true, false):
		var control := value as Control
		if not control.is_visible_in_tree():
			continue
		if control is Label:
			lines.append((control as Label).text)
		elif control is RichTextLabel:
			lines.append((control as RichTextLabel).text)
		elif control is Button:
			lines.append((control as Button).text)
	return "\n".join(lines)


func _settle_ui() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.23, true, false, true).timeout
	await get_tree().process_frame


func _check(condition: bool, description: String) -> void:
	observations.append({"description":description, "passed":condition})
	if condition:
		print("PASS: %s" % description)
	else:
		_fail(description)


func _fail(description: String) -> void:
	failures.append(description)
	push_error("FAIL: %s" % description)
