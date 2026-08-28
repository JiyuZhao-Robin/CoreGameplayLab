extends Node

const MainScene := preload("res://src/ui/main.tscn")
const MARKER_PATH := "user://ui_persistence_audit_marker.json"
const RESULT_PATH := "res://artifacts/test-results/ui-persistence-audit.json"

var failures: Array[String] = []
var observations: Array[Dictionary] = []


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
	_check(not isolation_token.is_empty() and OS.get_user_data_dir().contains(isolation_token), "user:// resolves inside the runner's unique isolated directory")
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
	add_child(main)
	await _settle_ui()

	_press(main.find_child("RestartButton", true, false) as Button)
	await _settle_ui()
	var dialog := main.find_child("ResetConfirmation", true, false) as ConfirmationDialog
	_press(dialog.get_ok_button() if dialog != null else null)
	await _settle_ui()

	_press(main.find_child("Navigation_ships", true, false) as Button)
	await _settle_ui()
	var assignment := _first_enabled_named_prefix(main, "AssignMining_")
	_press(assignment)
	await _settle_ui()
	var ship_id := String(Game.state.ships[0].get("instance_id", "")) if not Game.state.ships.is_empty() else ""
	_check(not ship_id.is_empty() and Game.state.ship_fleet_domain(ship_id) == "mining", "visible Ships control creates the state later loaded by the reader")

	_press(main.find_child("Navigation_inventory", true, false) as Button)
	await _settle_ui()
	var revision_before := Game.state.revision
	_press(main.find_child("SaveButton", true, false) as Button)
	await _settle_ui()
	_check(FileAccess.file_exists("user://space_idle_save.json") and Game.state.revision > revision_before, "visible SaveButton writes the isolated LocalSaveRepository")

	var marker := FileAccess.open(MARKER_PATH, FileAccess.WRITE)
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
	var marker_data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MARKER_PATH)) if FileAccess.file_exists(MARKER_PATH) else null
	_check(marker_data is Dictionary, "reader finds the writer marker in the same isolated user data directory")
	if not marker_data is Dictionary:
		return
	var marker := marker_data as Dictionary
	for observation_value in marker.get("writerObservations", []):
		if observation_value is Dictionary:
			observations.append((observation_value as Dictionary).duplicate(true))
	var main: Control = MainScene.instantiate()
	add_child(main)
	await _settle_ui()

	_check(Game.state.save_id == String(marker.get("saveId", "")) and Game.state.revision >= int(marker.get("revision", 0)), "startup auto-load restores stable Save identity and revision")
	var ship_id := String(marker.get("shipId", ""))
	_check(Game.state.ship_fleet_domain(ship_id) == "mining", "startup auto-load restores the UI-created fleet assignment")
	var inventory_page := main.find_child("inventory", true, false) as Control
	_check(inventory_page != null and inventory_page.is_visible_in_tree(), "UI preferences restore the last active core page")
	_check(not Game.offline_report.is_empty() and float(Game.offline_report.get("simulated_ms", 0.0)) > 1000.0, "startup processes elapsed offline time through the shared orchestrator")
	var sidebar_text := _visible_text(main)
	_check(not Game.offline_report.is_empty() and sidebar_text.contains(I18n.core("sidebar.offline")), "the loaded UI visibly presents the offline-return report")

	_press(main.find_child("Navigation_ships", true, false) as Button)
	await _settle_ui()
	var fleet_text := _visible_text(main.find_child("fleet", true, false))
	var ship := Game.state.ship_by_id(ship_id)
	var zone := String(Game.state.fleet_logistics_runtime("expedition").get("formation", {}).get("ship_zones", {}).get(ship_id, "FRONT"))
	var expected_status := I18n.core("ships.roster.status") % [
		main.call("_status_text", String(ship.get("status", "DOCKED"))),
		I18n.core("ships.assignment.mining"),
		main.call("_zone_text", zone)
	]
	_check(not ship.is_empty() and fleet_text.contains(expected_status), "the loaded Ships page derives visible assignment state from the restored Domain state")
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
				"isolation":"APPDATA and LOCALAPPDATA redirected by tools/run_ui_persistence_audit.ps1"
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
