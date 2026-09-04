extends Node

const MainScene := preload("res://src/ui/main.tscn")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")
const ResponsivePolicy := preload("res://src/ui/responsive_ui_policy.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("zh_CN")
	Engine.time_scale = 0.0
	Game.reset_game()
	_clear_scale_session()

	_test_scale_math()
	var default_main := await _spawn_main(-1.0, Vector2(1440.0, 900.0))
	await _test_default_shell(default_main)
	default_main.queue_free()
	await get_tree().process_frame

	_clear_scale_session()
	var large_main := await _spawn_main(2.0, Vector2(2560.0, 1440.0))
	_test_large_shell(large_main)
	large_main.queue_free()
	await get_tree().process_frame

	_clear_scale_session()
	var constrained_main := await _spawn_main(2.0, Vector2(1280.0, 720.0))
	_test_constrained_manual_shell(constrained_main)
	constrained_main.queue_free()
	await get_tree().process_frame

	_clear_scale_session()
	UiTokens.set_ui_scale(UiTokens.DEFAULT_UI_SCALE)
	Engine.time_scale = 1.0
	if failures.is_empty():
		print("UI_SCALE_CONTRACT_PASS")
		get_tree().quit(0)
	else:
		push_error("UI_SCALE_CONTRACT_FAIL\n%s" % "\n".join(failures))
		get_tree().quit(1)


func _spawn_main(scale_value: float, viewport_size: Vector2) -> Control:
	if scale_value > 0.0:
		get_tree().root.set_meta(UiTokens.UI_SCALE_SESSION_META, scale_value)
	var main: Control = MainScene.instantiate()
	# MainScene is normally the viewport root. Under this Node-based harness it
	# has no Control parent, so assign the production baseline explicitly.
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = viewport_size
	add_child(main)
	await get_tree().process_frame
	await get_tree().create_timer(0.25, true, false, true).timeout
	await get_tree().process_frame
	return main


func _test_scale_math() -> void:
	var expected := [0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
	for index in expected.size():
		_check(is_equal_approx(UiTokens.sanitize_ui_scale(float(UiTokens.SUPPORTED_UI_SCALES[index])), expected[index]), "supported UI scale %d%% remains stable" % int(expected[index] * 100.0))
	_check(is_equal_approx(UiTokens.sanitize_ui_scale(125.0), 1.25), "percentage-form UI scale values normalize to factors")
	_check(is_equal_approx(UiTokens.sanitize_ui_scale(0.75), 0.9), "the retired 75% step migrates safely to the supported 90% floor")
	_check(is_equal_approx(UiTokens.sanitize_ui_scale(1.31), 1.25), "unsupported UI scale values snap to the nearest supported step")
	UiTokens.set_ui_scale(1.25)
	_check(UiTokens.font_size(15) == 19, "125% converts the 15px base font to a readable 19px theme font")
	_check(UiTokens.layout_px(40.0) == 45, "layout geometry uses the moderated scale instead of doubling every panel")


func _test_default_shell(main: Control) -> void:
	var tabs := main.find_child("CentralWorkspace", true, false) as Control
	var system_page := main.find_child("system_map", true, false) as ScrollContainer
	_check(main.size.y >= 890.0 and tabs != null and tabs.size.y > 0.0 and system_page != null and system_page.size.y > 0.0, "the 1440x900 baseline retains a non-zero central gameplay workspace (root=%s, center=%s, page=%s)" % [main.size, tabs.size if tabs != null else Vector2.ZERO, system_page.size if system_page != null else Vector2.ZERO])
	var selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	_check(selector != null and selector.item_count == 8, "the global header exposes AUTO plus the seven approved manual scale steps")
	_check(selector != null and selector.get_item_id(selector.selected) == ResponsivePolicy.AUTO_SELECTOR_ID, "new installations default to AUTO without exposing a layout-profile control")
	var auto_index := selector.get_item_index(ResponsivePolicy.AUTO_SELECTOR_ID) if selector != null else -1
	_check(auto_index >= 0 and selector.get_item_text(auto_index) == "自动", "AUTO has a localized Chinese selector label")
	I18n.set_locale("en")
	_check(auto_index >= 0 and selector.get_item_text(auto_index) == "AUTO", "AUTO selector text refreshes during a live locale change")
	I18n.set_locale("zh_CN")
	var snapshot: Dictionary = main.call("ui_responsive_snapshot")
	_check(String(snapshot.get("preferred_mode", "")) == ResponsivePolicy.MODE_AUTO and is_equal_approx(float(snapshot.get("manual_scale", 0.0)), 1.25) and is_equal_approx(float(snapshot.get("effective_scale", 0.0)), 1.25), "AUTO keeps preferred, manual, and effective scale as distinct state at the 1440x900 baseline")
	main.call("_on_ui_scale_selected", selector.get_item_index(125))
	snapshot = main.call("ui_responsive_snapshot")
	_check(String(snapshot.get("preferred_mode", "")) == ResponsivePolicy.MODE_MANUAL and is_equal_approx(float(snapshot.get("manual_scale", 0.0)), 1.25), "selecting a percentage changes preferred mode to MANUAL without altering its safe value")
	main.call("_on_ui_scale_selected", selector.get_item_index(ResponsivePolicy.AUTO_SELECTOR_ID))
	snapshot = main.call("ui_responsive_snapshot")
	_check(String(snapshot.get("preferred_mode", "")) == ResponsivePolicy.MODE_AUTO and is_equal_approx(float(snapshot.get("effective_scale", 0.0)), float(snapshot.get("recommended_scale", 0.0))), "selecting AUTO makes effective scale follow the recommendation")
	var responsive_timer := main.find_child("ResponsiveUiDebounce", true, false) as Timer
	_check(responsive_timer != null and responsive_timer.one_shot and responsive_timer.ignore_time_scale and is_equal_approx(responsive_timer.wait_time, 0.2), "Main owns a one-shot 200ms resize debounce independent of simulation speed")
	_check(main.theme != null and main.theme.default_font_size == 19, "the selected scale reaches the inherited Godot theme")
	_check(is_equal_approx(float(get_tree().root.content_scale_factor), 1.0), "responsive scaling leaves Window content_scale_factor at native scale")
	var speed := main.find_child("Speed1", true, false) as Button
	_check(speed != null and speed.custom_minimum_size.y >= 38.0, "button hit areas grow with the UI scale")
	var left := main.find_child("ResourceRailSurface", true, false) as Control
	_check(left != null and left.custom_minimum_size.x > UiTokens.RESOURCE_RAIL_WIDTH, "desktop side rails grow with the UI scale")
	var flow := main.find_child("WorkspaceNavigationFlow", true, false) as HFlowContainer
	_check(flow != null, "workspace navigation uses a wrapping flow at readable scales")
	_check(main.scale.is_equal_approx(Vector2.ONE), "UI scale does not transform the root gameplay canvas")
	var map := main.find_child("SystemMapView", true, false) as Control
	_check(map == null or map.scale.is_equal_approx(Vector2.ONE), "system-map coordinates retain their independent canvas scale")
	main.size.x = 1300.0
	# Drawer behavior is synchronous; stop this fixture's AUTO debounce before
	# advancing frames so the test scene itself is not reloaded for a scale change.
	responsive_timer = main.find_child("ResponsiveUiDebounce", true, false) as Timer
	if responsive_timer != null:
		responsive_timer.stop()
	await get_tree().process_frame
	await get_tree().process_frame
	var right := main.find_child("ContextInspectorSurface", true, false) as Control
	_check(right != null and right.custom_minimum_size.x <= UiTokens.layout_px(UiTokens.COLLAPSED_RAIL_WIDTH) + 1.0, "resizing below the three-region width switches sidebars to drawer mode")


func _test_large_shell(main: Control) -> void:
	var selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	_check(selector != null and selector.get_item_id(selector.selected) == 200, "the session preference restores 200% without Domain-save coupling")
	var snapshot: Dictionary = main.call("ui_responsive_snapshot")
	_check(String(snapshot.get("preferred_mode", "")) == ResponsivePolicy.MODE_MANUAL and is_equal_approx(float(snapshot.get("manual_scale", 0.0)), 2.0) and is_equal_approx(float(snapshot.get("recommended_scale", 0.0)), 1.75) and is_equal_approx(float(snapshot.get("effective_scale", 0.0)), 2.0), "a supported legacy 200% session migrates to MANUAL while recommendation remains advisory")
	var header_status := main.find_child("HeaderStatus", true, false) as Label
	_check(header_status != null and not header_status.visible, "high UI scales release header space for primary controls")
	var navigation := main.find_child("WorkspaceNavigationBar", true, false) as Control
	_check(navigation != null and navigation.custom_minimum_size.y >= 120.0, "high UI scales reserve a multi-line navigation region")
	var left := main.find_child("ResourceRailSurface", true, false) as Control
	var right := main.find_child("ContextInspectorSurface", true, false) as Control
	_check(left != null and right != null, "the 2560x1440 minimum contract keeps both 200% shell regions available")
	var shell_regions_inside_window := left != null and right != null and main.get_global_rect().grow(1.0).encloses(left.get_global_rect()) and main.get_global_rect().grow(1.0).encloses(right.get_global_rect())
	_check(shell_regions_inside_window, "high-scale sidebars remain inside the physical window")
	var all_navigation_visible := true
	if navigation != null:
		var bounds := navigation.get_global_rect().grow(1.0)
		for candidate in main.find_children("Navigation_*", "Button", true, false):
			var button := candidate as Button
			all_navigation_visible = all_navigation_visible and button.is_visible_in_tree() and bounds.encloses(button.get_global_rect())
	_check(all_navigation_visible, "all core workspaces remain visible inside the navigation region at 200%")


func _test_constrained_manual_shell(main: Control) -> void:
	var selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	var snapshot: Dictionary = main.call("ui_responsive_snapshot")
	_check(selector != null and selector.get_item_id(selector.selected) == 200, "an unsupported saved Manual choice remains the player's visible preference")
	_check(String(snapshot.get("preferred_mode", "")) == ResponsivePolicy.MODE_MANUAL and is_equal_approx(float(snapshot.get("manual_scale", 0.0)), 2.0), "small-window safety does not overwrite the saved Manual 200% preference")
	var recommended := float(snapshot.get("recommended_scale", 0.0))
	var usable_size: Vector2 = snapshot.get("usable_size", Vector2.ZERO)
	_check(ResponsivePolicy.candidate_is_auto_safe(recommended, main.size, usable_size) and recommended <= 1.25 and is_equal_approx(float(snapshot.get("effective_scale", 0.0)), 1.25), "1280x720 keeps its active-page recommendation advisory and projects Manual 200% to the highest safe 125% step")
	_check(main.theme != null and main.theme.default_font_size == 19, "the safe effective scale, not the unsupported preference, reaches the Theme")
	_check(main.scale.is_equal_approx(Vector2.ONE) and is_equal_approx(float(get_tree().root.content_scale_factor), 1.0), "manual safety projection does not add a Control or viewport multiplier")
	main.size = Vector2(2560.0, 1440.0)
	main.call("_apply_responsive_state", false, true)
	snapshot = main.call("ui_responsive_snapshot")
	_check(is_equal_approx(float(snapshot.get("manual_scale", 0.0)), 2.0) and is_equal_approx(float(snapshot.get("effective_scale", 0.0)), 2.0), "Manual 200% automatically becomes effective again when the window returns to its supported contract")
	main.size = Vector2(1280.0, 720.0)
	main.call("_apply_responsive_state", false, true)
	snapshot = main.call("ui_responsive_snapshot")
	_check(is_equal_approx(float(snapshot.get("manual_scale", 0.0)), 2.0) and is_equal_approx(float(snapshot.get("effective_scale", 0.0)), 1.25), "a later compact resize still preserves Manual 200% while restoring the safe effective projection")
	var responsive_timer := main.find_child("ResponsiveUiDebounce", true, false) as Timer
	if responsive_timer != null:
		responsive_timer.stop()


func _clear_scale_session() -> void:
	get_tree().root.remove_meta(UiTokens.UI_SCALE_SESSION_META)
	get_tree().root.remove_meta(ResponsivePolicy.SESSION_STATE_META)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		failures.append(description)
		push_error("FAIL: %s" % description)
