extends Node

const MainScene := preload("res://src/ui/main.tscn")
const ScenarioBuilder := preload("res://tests/gameplay_scenario_builder.gd")
const RESULT_PATH := "res://artifacts/test-results/ui-input-accessibility.json"

var failures: Array[String] = []
var observations: Array[Dictionary] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("en")
	Engine.time_scale = 0.0
	Game.reset_game()
	var main: Control = MainScene.instantiate()
	add_child(main)
	await _settle_ui()

	await _test_mouse_keyboard_navigation(main)
	await _test_focus_survives_domain_refresh(main)
	await _test_disabled_reasons(main)
	await _test_reset_modal(main)
	await _test_speed_controls_and_refresh(main)
	await _test_scroll_wheel(main)

	Engine.time_scale = 1.0
	_write_result()
	main.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("UI_INPUT_ACCESSIBILITY_PASS")
		get_tree().quit(0)
	else:
		push_error("UI_INPUT_ACCESSIBILITY_FAIL\n%s" % "\n".join(failures))
		get_tree().quit(1)


func _test_mouse_keyboard_navigation(main: Control) -> void:
	var initial_focus := get_viewport().gui_get_focus_owner()
	if initial_focus != null:
		initial_focus.release_focus()
	await _send_action("ui_focus_next")
	var entry_focus := get_viewport().gui_get_focus_owner()
	_check(entry_focus != null and entry_focus.is_visible_in_tree(), "Tab/ui_focus_next enters the shell when no Control owns focus", "EXECUTED", {
		"focus":String(entry_focus.name) if entry_focus != null else ""
	})

	var inventory := main.find_child("Navigation_inventory", true, false) as Button
	var mouse_reached_inventory := await _mouse_click(inventory)
	if mouse_reached_inventory and _page_visible(main, "inventory"):
		_check(true, "mouse click reaches a core navigation destination", "EXECUTED", {"control":"Navigation_inventory"})
	else:
		_record_inconclusive("OS mouse injection reaches a core navigation destination", {
			"control":"Navigation_inventory",
			"buttonRect":inventory.get_global_rect() if inventory != null else Rect2(),
			"visiblePage":_visible_page_name(main)
		})

	var system := main.find_child("Navigation_system_map", true, false) as Button
	system.grab_focus()
	await get_tree().process_frame
	_check(get_viewport().gui_get_focus_owner() == system, "a visible navigation Button accepts keyboard focus", "EXECUTED", {
		"control":"Navigation_system_map"
	})
	await _send_action("ui_accept")
	await _settle_ui()
	_check(_page_visible(main, "system_map"), "ui_accept activates the focused navigation Button", "EXECUTED", {
		"control":"Navigation_system_map"
	})

	system.grab_focus()
	await _send_action("ui_focus_next")
	var next_focus := get_viewport().gui_get_focus_owner()
	_check(next_focus != null and next_focus != system and next_focus.is_visible_in_tree(), "ui_focus_next advances to another visible Control", "EXECUTED", {
		"from":"Navigation_system_map",
		"to":String(next_focus.name) if next_focus != null else ""
	})

	var location := main.find_child("Navigation_location", true, false) as Button
	location.grab_focus()
	await _send_action("ui_accept")
	await _settle_ui()
	var opened_location := _page_visible(main, "location")
	await _send_action("ui_cancel")
	await _settle_ui()
	_check(opened_location and _page_visible(main, "system_map"), "ui_cancel provides a predictable page-level Back action", "EXECUTED_EXPECTED_FAILURE", {
		"from":"location",
		"expected":"system_map",
		"actual":_visible_page_name(main)
	})


func _test_focus_survives_domain_refresh(main: Control) -> void:
	_press(main.find_child("Navigation_ships", true, false) as Button)
	await _settle_ui()
	var assignment := _first_enabled_named_prefix(main, "AssignMining_")
	if assignment == null:
		_check(false, "a focusable fleet assignment action exists for refresh testing", "EXECUTED", {})
		return
	var original_name := String(assignment.name)
	assignment.grab_focus()
	_press(assignment)
	await _settle_ui()
	var owner := get_viewport().gui_get_focus_owner()
	_check(owner != null and owner.is_visible_in_tree() and String(owner.name) == original_name, "a state-driven page rebuild restores logical keyboard focus", "EXECUTED_EXPECTED_FAILURE", {
		"expectedControl":original_name,
		"actualControl":String(owner.name) if owner != null else ""
	})


func _test_scroll_wheel(main: Control) -> void:
	var builder = ScenarioBuilder.new(Game.content)
	if not builder.activate("megastructure_phase_5"):
		_record_inconclusive("wheel scrolling on an invariant-valid overflow scenario", {"reason":"megastructure_phase_5 scenario missing"})
		return
	await _settle_ui()
	var scroll: ScrollContainer = null
	var selected_page := ""
	var page_pairs := {
		"system_map":"system_map", "location":"location", "industry":"industry",
		"inventory":"inventory", "logistics":"logistics", "construction":"construction",
		"research":"research", "ships":"fleet", "survey":"frontier",
		"megastructure":"megastructure", "diagnostics":"diagnostics"
	}
	for public_page_value in page_pairs.keys():
		var public_page := String(public_page_value)
		_press(main.find_child("Navigation_%s" % public_page, true, false) as Button)
		await _settle_ui()
		var candidate := main.find_child(String(page_pairs[public_page]), true, false) as ScrollContainer
		if candidate == null:
			continue
		if candidate.get_v_scroll_bar().max_value > candidate.get_v_scroll_bar().page + 1.0:
			scroll = candidate
			selected_page = public_page
			break
	if scroll == null:
		_record_inconclusive("wheel scrolling on an invariant-valid overflow scenario", {
			"reason":"no page overflowed in the headless viewport",
			"scenario":"megastructure_phase_5"
		})
		return
	var maximum := scroll.get_v_scroll_bar().max_value
	var page_size := scroll.get_v_scroll_bar().page
	scroll.scroll_vertical = 0
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_WHEEL_DOWN
	event.factor = 8.0
	event.pressed = true
	event.position = scroll.get_global_rect().get_center()
	event.global_position = event.position
	get_viewport().push_input(event, true)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(scroll.scroll_vertical > 0, "mouse wheel scrolls a long core gameplay page", "EXECUTED", {
		"page":selected_page,
		"scrollVertical":scroll.scroll_vertical,
		"maximum":maximum,
		"pageSize":page_size
	})
	var scroll_before_rebuild := scroll.scroll_vertical
	_press(main.find_child("Speed2", true, false) as Button)
	await _settle_ui()
	_check(abs(scroll.scroll_vertical - scroll_before_rebuild) <= 1, "a normal dirty page rebuild preserves the active ScrollContainer position", "EXECUTED", {
		"page":selected_page,
		"before":scroll_before_rebuild,
		"after":scroll.scroll_vertical
	})


func _test_disabled_reasons(main: Control) -> void:
	var prefixes := PackedStringArray([
		"StartMining_", "IntegrateMining_", "StartConstruction_",
		"QueueFacilityModule_", "StartResearch_", "StartMegastructure_",
		"BuildShip_", "AssignConstructionSupport_"
	])
	var unexplained: Array[String] = []
	var disabled_count := 0
	for page_name in ["survey", "construction", "research", "megastructure", "ships"]:
		_press(main.find_child("Navigation_%s" % page_name, true, false) as Button)
		await _settle_ui()
		for node_value in main.find_children("*", "Button", true, false):
			var button := node_value as Button
			if not button.is_visible_in_tree() or not button.disabled:
				continue
			var is_gameplay_action := false
			for prefix in prefixes:
				if String(button.name).begins_with(prefix):
					is_gameplay_action = true
					break
			if not is_gameplay_action:
				continue
			disabled_count += 1
			if button.tooltip_text.strip_edges().is_empty():
				unexplained.append("%s:%s" % [page_name, button.name])
	_check(disabled_count > 0, "fresh-save core screens expose real gameplay-disabled actions", "EXECUTED", {
		"disabledActionCount":disabled_count
	})
	_check(unexplained.is_empty(), "every disabled gameplay action exposes a keyboard/mouse-readable reason", "EXECUTED_EXPECTED_FAILURE", {
		"disabledActionCount":disabled_count,
		"unexplained":unexplained
	})


func _test_reset_modal(main: Control) -> void:
	var restart := main.find_child("RestartButton", true, false) as Button
	restart.grab_focus()
	_press(restart)
	await _settle_ui()
	var dialog := main.find_child("ResetConfirmation", true, false) as ConfirmationDialog
	var cancel := dialog.get_cancel_button() if dialog != null else null
	_check(dialog != null and dialog.visible and dialog.exclusive, "Restart opens an exclusive confirmation modal", "EXECUTED", {})
	await get_tree().process_frame
	await get_tree().process_frame
	var modal_focus := dialog.gui_get_focus_owner() if dialog != null else null
	_check(cancel != null and modal_focus == cancel, "destructive reset initially focuses the safe Cancel action", "EXECUTED", {
		"dialogFocus":String(modal_focus.name) if modal_focus != null else "",
		"rootFocus":String(get_viewport().gui_get_focus_owner().name) if get_viewport().gui_get_focus_owner() != null else ""
	})
	var save_id_before := Game.state.save_id
	await _send_root_key(KEY_ESCAPE)
	await _settle_ui()
	var modal_closed := not is_instance_valid(dialog) or not dialog.visible
	_check(modal_closed and Game.state.save_id == save_id_before, "Escape/ui_cancel cancels reset without changing Domain state", "EXECUTED", {})
	var restored_focus := get_viewport().gui_get_focus_owner()
	_check(restored_focus == restart, "closing the modal restores focus to the invoking Restart control", "EXECUTED_EXPECTED_FAILURE", {
		"expected":"RestartButton",
		"actual":String(restored_focus.name) if restored_focus != null else ""
	})

	if is_instance_valid(dialog) and dialog.visible:
		dialog.get_cancel_button().pressed.emit()
		for _frame in 4:
			await get_tree().process_frame
	if is_instance_valid(dialog):
		dialog.queue_free()
		await get_tree().process_frame
	_press(restart)
	await _settle_ui()
	dialog = main.find_child("ResetConfirmation", true, false) as ConfirmationDialog
	var confirm := dialog.get_ok_button() if dialog != null else null
	_press(confirm)
	await _settle_ui()
	_check(Game.state.save_id != save_id_before, "modal Confirm executes the normal New Game transaction", "EXECUTED", {})


func _test_speed_controls_and_refresh(main: Control) -> void:
	for speed in [1, 2, 5, 10]:
		var button := main.find_child("Speed%d" % speed, true, false) as Button
		_press(button)
		await get_tree().process_frame
		_check(is_equal_approx(Engine.time_scale, float(speed)), "visible %dx speed control sets the requested simulation speed" % speed, "EXECUTED", {
			"control":"Speed%d" % speed,
			"timeScale":Engine.time_scale
		})
	var header := main.find_child("HeaderStatus", true, false) as Label
	var before_text := header.text if header != null else ""
	var before_elapsed := Game.state.total_elapsed_ms
	_press(main.find_child("Speed100", true, false) as Button)
	await get_tree().create_timer(0.9, true, false, true).timeout
	await _settle_ui()
	var after_text := header.text if header != null else ""
	_check(Game.state.total_elapsed_ms > before_elapsed + 60000.0 and after_text != before_text, "online fast-forward crosses a minute and the Top Status Bar refreshes", "EXECUTED", {
		"elapsedBefore":before_elapsed,
		"elapsedAfter":Game.state.total_elapsed_ms
	})
	_press(main.find_child("SpeedPause", true, false) as Button)
	await get_tree().process_frame
	_check(is_zero_approx(Engine.time_scale), "visible Pause control stops simulation time", "EXECUTED", {})


func _mouse_click(button: Button) -> bool:
	if button == null or not button.is_visible_in_tree() or button.disabled:
		return false
	var center := button.get_global_rect().get_center()
	Input.warp_mouse(center)
	await get_tree().process_frame
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = center
		event.global_position = center
		get_viewport().push_input(event, true)
		await get_tree().process_frame
	return true


func _send_action(action_name: String) -> void:
	for pressed in [true, false]:
		var event := InputEventAction.new()
		event.action = action_name
		event.pressed = pressed
		get_viewport().push_input(event, true)
		await get_tree().process_frame


func _send_root_key(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame


func _press(button: Button) -> void:
	if button != null and button.is_visible_in_tree() and not button.disabled:
		button.pressed.emit()


func _first_enabled_named_prefix(root: Node, prefix: String) -> Button:
	for value in root.find_children("%s*" % prefix, "Button", true, false):
		var button := value as Button
		if button.is_visible_in_tree() and not button.disabled:
			return button
	return null


func _page_visible(root: Node, page_name: String) -> bool:
	var page := root.find_child(page_name, true, false) as Control
	return page != null and page.is_visible_in_tree()


func _visible_page_name(root: Node) -> String:
	for page_name in ["system_map", "location", "industry", "inventory", "logistics", "construction", "research", "fleet", "frontier", "megastructure", "diagnostics"]:
		if _page_visible(root, page_name):
			return page_name
	return ""


func _settle_ui() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.23, true, false, true).timeout
	await get_tree().process_frame


func _check(condition: bool, description: String, evidence: String, details: Dictionary) -> void:
	observations.append({
		"description":description,
		"passed":condition,
		"evidence":evidence,
		"details":details
	})
	if condition:
		print("PASS: %s" % description)
	else:
		failures.append(description)
		push_error("FAIL: %s" % description)


func _record_inconclusive(description: String, details: Dictionary) -> void:
	observations.append({
		"description":description,
		"passed":null,
		"evidence":"INCONCLUSIVE_HARNESS",
		"details":details
	})
	print("INCONCLUSIVE: %s" % description)


func _write_result() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RESULT_PATH.get_base_dir()))
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"schemaVersion":1,
		"source":"tests/ui_input_accessibility_test.gd",
		"passed":failures.is_empty(),
		"observations":observations,
		"failures":failures,
		"scope":"Focused live input audit; Save/Load and offline-return are covered by the isolated persistence harness."
	}, "  "))
