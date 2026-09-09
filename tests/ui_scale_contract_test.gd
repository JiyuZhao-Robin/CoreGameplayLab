extends Node

const MainScene := preload("res://src/ui/main.tscn")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")
const FixedPolicy := preload("res://src/ui/responsive_ui_policy.gd")

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

	var main := await _spawn_main(UiTokens.DEFAULT_UI_SCALE)
	_test_fixed_shell_contract(main)
	_test_resize_is_presentation_only(main)
	main.queue_free()
	await get_tree().process_frame
	_clear_scale_session()

	var accessibility_main := await _spawn_main(2.0)
	_test_explicit_accessibility_scale(accessibility_main)
	accessibility_main.queue_free()
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


func _spawn_main(scale_value: float) -> Control:
	get_tree().root.set_meta(UiTokens.UI_SCALE_SESSION_META, scale_value)
	var main: Control = MainScene.instantiate()
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = FixedPolicy.DESIGN_VIEWPORT_SIZE
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	return main


func _test_scale_math() -> void:
	var expected := [0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
	for index in expected.size():
		_check(is_equal_approx(UiTokens.sanitize_ui_scale(float(UiTokens.SUPPORTED_UI_SCALES[index])), expected[index]), "supported UI scale %d%% remains stable" % int(expected[index] * 100.0))
	_check(is_equal_approx(UiTokens.sanitize_ui_scale(125.0), 1.25), "percentage-form UI scale values normalize to factors")
	_check(is_equal_approx(UiTokens.sanitize_ui_scale(0.75), 0.9), "the retired 75% step migrates safely to the supported 90% floor")
	UiTokens.set_ui_scale(1.25)
	_check(UiTokens.font_size(15) == 19, "125% converts the 15px base font to a readable 19px theme font")
	_check(UiTokens.layout_px(40.0) == 45, "accessibility geometry retains its moderated explicit scale")


func _test_fixed_shell_contract(main: Control) -> void:
	var snapshot: Dictionary = main.call("ui_responsive_snapshot")
	var selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	var selector_ids: Array[int] = []
	if selector != null:
		for index in selector.item_count:
			selector_ids.append(selector.get_item_id(index))
	_check(main.size.is_equal_approx(FixedPolicy.DESIGN_VIEWPORT_SIZE), "Main is authored on the 1920x1080 logical canvas")
	_check(selector != null and selector.item_count == UiTokens.SUPPORTED_UI_SCALES.size(), "the header exposes only explicit UI scale choices")
	_check(not selector_ids.has(FixedPolicy.AUTO_SELECTOR_ID), "window-driven AUTO is absent from the player selector")
	_check(selector != null and selector.get_item_id(selector.selected) == 125, "the fixed layout starts at the explicit 125% preference")
	_check(String(snapshot.get("preferred_mode", "")) == FixedPolicy.MODE_MANUAL, "the runtime owns one MANUAL Theme scale mode")
	_check(is_equal_approx(float(snapshot.get("manual_scale", 0.0)), 1.25) and is_equal_approx(float(snapshot.get("effective_scale", 0.0)), 1.25), "manual and effective Theme scales agree at startup")
	_check(String(snapshot.get("layout_profile", "")) == FixedPolicy.PROFILE_STANDARD, "the runtime owns one authored STANDARD layout profile")
	_check(Vector2(snapshot.get("design_viewport_size", Vector2.ZERO)).is_equal_approx(FixedPolicy.DESIGN_VIEWPORT_SIZE), "the runtime reports its fixed design viewport")
	_check(main.find_child("ResponsiveUiDebounce", true, false) == null, "window resize cannot schedule a Theme reload")
	_check(main.theme != null and main.theme.default_font_size == 19, "the explicit scale reaches the inherited Godot Theme")
	_check(main.scale.is_equal_approx(Vector2.ONE), "Main does not add a second Control transform on top of Window content scaling")
	var left := main.find_child("ResourceRailSurface", true, false) as Control
	var right := main.find_child("ContextInspectorSurface", true, false) as Control
	var navigation := main.find_child("WorkspaceNavigationBar", true, false) as Control
	var workspace := main.find_child("CentralWorkspace", true, false) as Control
	_check(left != null and right != null and not left.visible and not right.visible, "the compact baseline retains but hides both redundant global side regions")
	_check(navigation != null and navigation.visible and workspace != null and workspace.visible, "the compact baseline keeps global navigation and the command workspace available")


func _test_resize_is_presentation_only(main: Control) -> void:
	var before_snapshot: Dictionary = main.call("ui_responsive_snapshot")
	var before_geometry := _shell_geometry(main)
	var before_id := main.get_instance_id()
	var selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	var selector_id := selector.get_instance_id() if selector != null else 0
	main.call("_on_root_resized")
	var after_snapshot: Dictionary = main.call("ui_responsive_snapshot")
	_check(main.get_instance_id() == before_id, "resize keeps the Main scene instance")
	_check(selector != null and selector.get_instance_id() == selector_id, "resize keeps existing header controls")
	_check(_shell_geometry(main) == before_geometry, "resize leaves shell geometry unchanged in design coordinates")
	_check(is_equal_approx(float(before_snapshot.get("effective_scale", 0.0)), float(after_snapshot.get("effective_scale", -1.0))), "resize leaves effective Theme scale unchanged")
	_check(String(after_snapshot.get("layout_profile", "")) == FixedPolicy.PROFILE_STANDARD, "resize leaves the layout profile unchanged")
	var left := main.find_child("ResourceRailSurface", true, false) as Control
	var right := main.find_child("ContextInspectorSurface", true, false) as Control
	_check(left != null and right != null and not left.visible and not right.visible, "resize keeps redundant global side regions hidden rather than turning them into drawers")


func _test_explicit_accessibility_scale(main: Control) -> void:
	var snapshot: Dictionary = main.call("ui_responsive_snapshot")
	var selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	_check(is_equal_approx(float(snapshot.get("effective_scale", 0.0)), 2.0), "a fresh Main applies the explicit player 200% scale")
	_check(main.theme != null and main.theme.default_font_size == 30, "200% rerasterizes the inherited Theme instead of stretching a 125% texture")
	_check(selector != null and selector.get_item_id(selector.selected) == 200, "the selector presents the actual explicit 200% preference")
	var instance_id := main.get_instance_id()
	main.call("_on_root_resized")
	var resized_snapshot: Dictionary = main.call("ui_responsive_snapshot")
	_check(main.get_instance_id() == instance_id, "resize keeps the 200% Main instance")
	_check(is_equal_approx(float(resized_snapshot.get("effective_scale", 0.0)), 2.0), "later Window resize cannot project the explicit scale down")
	var header := main.find_child("TopStatusBar", true, false) as Control
	var navigation := main.find_child("WorkspaceNavigationBar", true, false) as Control
	var header_controls: Array = [
		main.find_child("UIScaleSelector", true, false),
		main.find_child("SaveButton", true, false),
		main.find_child("RestartButton", true, false)
	]
	var navigation_controls: Array = main.find_children("Navigation_*", "Button", true, false)
	_check(_controls_inside(header, header_controls), "200% keeps persistent header actions reachable inside the fixed design canvas")
	_check(_controls_inside(navigation, navigation_controls), "200% keeps every workspace navigation action reachable inside its authored region")


func _shell_geometry(main: Control) -> Dictionary:
	var result := {}
	for node_name in ["TopStatusBar", "WorkspaceNavigationBar", "CentralWorkspace", "CommandDockSurface"]:
		var control := main.find_child(node_name, true, false) as Control
		if control != null:
			result[node_name] = control.get_rect()
	return result


func _controls_inside(parent: Control, controls: Array) -> bool:
	if parent == null:
		return false
	var bounds := parent.get_global_rect().grow(1.0)
	for control_value in controls:
		var control := control_value as Control
		if control == null or not control.is_visible_in_tree() or not bounds.encloses(control.get_global_rect()):
			return false
	return true


func _clear_scale_session() -> void:
	get_tree().root.remove_meta(UiTokens.UI_SCALE_SESSION_META)
	get_tree().root.remove_meta(FixedPolicy.SESSION_STATE_META)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		failures.append(description)
		push_error("FAIL: %s" % description)
