extends Node

const MainScene := preload("res://src/ui/main.tscn")
const Policy := preload("res://src/ui/responsive_ui_policy.gd")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")
const WINDOW_MATRIX := [
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
	Vector2i(3440, 1440),
	Vector2i(1440, 900),
	Vector2i(1366, 768)
]

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Engine.time_scale = 0.0
	Game.reset_game()
	_clear_scale_session()
	_check_project_contract()

	var original_window_size := get_window().size
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	var main: Control = MainScene.instantiate()
	get_tree().root.add_child(main)
	get_tree().current_scene = main
	await get_tree().process_frame
	await get_tree().process_frame

	var baseline := _shell_geometry(main)
	var main_instance_id := main.get_instance_id()
	var selector := main.find_child("UIScaleSelector", true, false) as OptionButton
	var selector_instance_id := selector.get_instance_id() if selector != null else 0
	var active_workspace := main.find_child("SystemMap2D", true, false) as Control
	var active_workspace_id := active_workspace.get_instance_id() if active_workspace != null else 0
	var system_map_signature := _system_map_signature(active_workspace)
	_check(not baseline.is_empty(), "fixed-layout matrix captured the compact command shell baseline")
	_check(main.find_child("ResponsiveUiDebounce", true, false) == null, "Main no longer owns a resize debounce that can reload the UI")
	_check(get_tree().root.find_child("AuditCaptureViewport", false, false) == null, "ordinary startup creates no capture-only SubViewport")
	_check(_global_rails_are_hidden(main), "the compact command shell retains but hides redundant global sidebars")

	for physical_size in WINDOW_MATRIX:
		get_window().size = physical_size
		await get_tree().process_frame
		await get_tree().process_frame
		var snapshot: Dictionary = main.call("ui_responsive_snapshot")
		var content_rect: Rect2 = snapshot.get("canvas_content_rect", Rect2())
		var logical_visible_size := get_viewport().get_visible_rect().size
		_check(get_window().size == physical_size, "%s becomes the actual physical Window client size" % physical_size)
		_check(get_window().content_scale_size == Vector2i(1920, 1080), "%s keeps the runtime content-scale design size" % physical_size)
		_check(get_window().content_scale_mode == Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, "%s keeps CanvasItem runtime scaling" % physical_size)
		_check(get_window().content_scale_aspect == Window.CONTENT_SCALE_ASPECT_KEEP, "%s keeps the runtime aspect policy" % physical_size)
		_check(logical_visible_size.is_equal_approx(Policy.DESIGN_VIEWPORT_SIZE), "%s keeps the actual logical viewport at 1920x1080" % physical_size)
		_check(is_instance_valid(main) and main.get_instance_id() == main_instance_id, "%s resize keeps the existing Main scene instance" % physical_size)
		_check(selector != null and is_instance_valid(selector) and selector.get_instance_id() == selector_instance_id, "%s resize does not rebuild header controls" % physical_size)
		_check(active_workspace != null and is_instance_valid(active_workspace) and active_workspace.get_instance_id() == active_workspace_id, "%s resize keeps the active workspace instance" % physical_size)
		_check(main.size.is_equal_approx(Policy.DESIGN_VIEWPORT_SIZE), "%s keeps the logical root at 1920x1080" % physical_size)
		_check(_geometry_matches(_shell_geometry(main), baseline), "%s preserves all shell rectangles in design coordinates" % physical_size)
		_check(_system_map_signature(active_workspace) == system_map_signature, "%s preserves System Map world and button coordinates" % physical_size)
		_check(_global_rails_are_hidden(main), "%s keeps redundant global sidebars hidden instead of resizing the command workspace" % physical_size)
		_check(String(snapshot.get("preferred_mode", "")) == Policy.MODE_MANUAL, "%s keeps the fixed MANUAL scale mode" % physical_size)
		_check(is_equal_approx(float(snapshot.get("effective_scale", 0.0)), UiTokens.DEFAULT_UI_SCALE), "%s cannot change the effective Theme scale" % physical_size)
		_check(String(snapshot.get("layout_profile", "")) == Policy.PROFILE_STANDARD, "%s cannot switch the authored layout profile" % physical_size)
		_check(Vector2(snapshot.get("design_viewport_size", Vector2.ZERO)).is_equal_approx(Policy.DESIGN_VIEWPORT_SIZE), "%s reports the fixed design viewport" % physical_size)
		_check(is_equal_approx(content_rect.size.aspect(), Policy.DESIGN_VIEWPORT_SIZE.aspect()), "%s uses uniform keep-aspect scaling" % physical_size)
		_check(content_rect.position.x >= -0.01 and content_rect.position.y >= -0.01, "%s centers letterbox/pillarbox space outside the UI" % physical_size)
		if physical_size == Vector2i(3840, 2160):
			_check(content_rect.position.is_equal_approx(Vector2.ZERO) and content_rect.size.is_equal_approx(Vector2(3840, 2160)), "3840x2160 is an exact 2x canvas transform with no offset")

	await _check_factory_canvas_invariance(main)
	await _check_ship_assembly_invariance(main)
	var audit_viewport := await _check_capture_surface_contract(main)
	get_tree().current_scene = self
	get_window().size = original_window_size
	if audit_viewport != null:
		audit_viewport.queue_free()
	else:
		main.queue_free()
	await get_tree().process_frame
	_clear_scale_session()
	UiTokens.set_ui_scale(UiTokens.DEFAULT_UI_SCALE)
	Engine.time_scale = 1.0
	if failures.is_empty():
		print("RESPONSIVE_UI_MATRIX_PASS")
		get_tree().quit(0)
	else:
		push_error("RESPONSIVE_UI_MATRIX_FAIL\n%s" % "\n".join(failures))
		get_tree().quit(1)


func _check_project_contract() -> void:
	_check(int(ProjectSettings.get_setting("display/window/size/viewport_width", 0)) == 1920, "project design viewport width is 1920")
	_check(int(ProjectSettings.get_setting("display/window/size/viewport_height", 0)) == 1080, "project design viewport height is 1080")
	_check(String(ProjectSettings.get_setting("display/window/stretch/mode", "")) == "canvas_items", "project uses CanvasItem content scaling")
	_check(String(ProjectSettings.get_setting("display/window/stretch/aspect", "")) == "keep", "project preserves the 16:9 design aspect")


func _check_factory_canvas_invariance(main: Control) -> void:
	get_window().size = Vector2i(1920, 1080)
	main.call("_switch_page", "industry")
	await _settle()
	var canvas_tab := main.find_child("FactoryTabCanvas", true, false) as Button
	_check(canvas_tab != null, "Factory exposes its authored canvas tab from the overview")
	if canvas_tab != null:
		canvas_tab.pressed.emit()
	await _settle()
	var canvas := main.find_child("FactoryCanvas", true, false) as Control
	_check(canvas != null, "Factory workspace exposes its independent canvas")
	if canvas == null:
		return
	var canvas_id := canvas.get_instance_id()
	var camera_before: Vector2 = canvas.get("_camera")
	var zoom_before := float(canvas.get("_zoom"))
	var origin_before: Vector2 = canvas.call("_world_to_screen", Vector2.ZERO)
	var sample_before: Vector2 = canvas.call("_world_to_screen", Vector2(256.0, 160.0))
	for physical_size in WINDOW_MATRIX:
		get_window().size = physical_size
		await _settle()
		_check(is_instance_valid(canvas) and canvas.get_instance_id() == canvas_id, "%s keeps the Factory Canvas instance" % physical_size)
		_check(Vector2(canvas.get("_camera")).is_equal_approx(camera_before) and is_equal_approx(float(canvas.get("_zoom")), zoom_before), "%s preserves Factory camera and zoom" % physical_size)
		_check(Vector2(canvas.call("_world_to_screen", Vector2.ZERO)).is_equal_approx(origin_before) and Vector2(canvas.call("_world_to_screen", Vector2(256.0, 160.0))).is_equal_approx(sample_before), "%s preserves Factory world-to-design projection" % physical_size)


func _check_ship_assembly_invariance(main: Control) -> void:
	get_window().size = Vector2i(1920, 1080)
	main.call("_switch_page", "fleet")
	main.call("_select_fleet_section", "shipyard")
	await _settle()
	var canvas := main.find_child("ShipAssemblyMap", true, false) as GraphEdit
	_check(canvas != null, "Ship Assembly exposes its independent engineering canvas")
	if canvas == null:
		return
	canvas.call("_drop_data", Vector2(620.0, 260.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	canvas.call("_drop_data", Vector2(120.0, 160.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	canvas.call("request_module_connection", "ship_design_module_0001", "socket_weapon_0")
	await _settle()
	var canvas_id := canvas.get_instance_id()
	var zoom_before := canvas.zoom
	var scroll_before := canvas.scroll_offset
	var draft_before: Dictionary = canvas.call("draft_snapshot")
	var draft_nodes := draft_before.get("nodes", []) as Array
	var draft_connections := draft_before.get("connections", []) as Array
	_check(draft_nodes.size() == 2 and draft_connections.size() == 1, "Ship Assembly resize fixture contains a positioned hull, module, and authored connection")
	_check(_draft_has_distinct_positions(draft_nodes), "Ship Assembly resize fixture owns distinct non-empty world coordinates")
	for physical_size in WINDOW_MATRIX:
		get_window().size = physical_size
		await _settle()
		_check(is_instance_valid(canvas) and canvas.get_instance_id() == canvas_id, "%s keeps the Ship Assembly canvas instance" % physical_size)
		_check(is_equal_approx(canvas.zoom, zoom_before) and canvas.scroll_offset.is_equal_approx(scroll_before), "%s preserves Ship Assembly zoom and scroll center" % physical_size)
		_check((canvas.call("draft_snapshot") as Dictionary) == draft_before, "%s preserves Ship Assembly draft coordinates" % physical_size)


func _draft_has_distinct_positions(nodes: Array) -> bool:
	if nodes.size() < 2:
		return false
	var seen := {}
	for node_value in nodes:
		var node := node_value as Dictionary
		var position_value = node.get("position", {})
		if not position_value is Dictionary:
			return false
		var key := "%s,%s" % [position_value.get("x", 0.0), position_value.get("y", 0.0)]
		seen[key] = true
	return seen.size() == nodes.size()


func _check_capture_surface_contract(main: Control) -> SubViewport:
	var shell_before := _shell_geometry(main)
	await main.call("_set_capture_viewport_size", Vector2i(3840, 2160))
	var audit_viewport := main.get_viewport() as SubViewport
	_check(audit_viewport != null and audit_viewport.name == "AuditCaptureViewport" and audit_viewport.size == Vector2i(3840, 2160), "capture path owns an exact 4K physical output viewport")
	_check(main.size.is_equal_approx(Policy.DESIGN_VIEWPORT_SIZE), "capture output does not become a new logical UI layout size")
	_check(main.scale.is_equal_approx(Vector2(2.0, 2.0)) and main.position.is_equal_approx(Vector2.ZERO), "3840x2160 capture applies one exact 2x 16:9 transform with no offset")
	_check(_geometry_matches(_shell_geometry(main), shell_before), "capture transform preserves internal shell geometry")
	_check(_global_rails_are_hidden(main), "capture transform preserves the compact command-shell sidebar policy")
	return audit_viewport


func _system_map_signature(system_map: Control) -> String:
	if system_map == null:
		return ""
	var parts: Array[String] = [str(system_map.size), str(system_map.get("_positions"))]
	for child_value in system_map.get_children():
		var child := child_value as Control
		if child != null and child.name.begins_with("Location_"):
			parts.append("%s:%s" % [child.name, child.get_rect()])
	return "|".join(parts)


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame


func _shell_geometry(main: Control) -> Dictionary:
	var names := [
		"TopStatusBar",
		"WorkspaceNavigationBar",
		"CentralWorkspace",
		"CommandDockSurface"
	]
	var result := {}
	for node_name in names:
		var control := main.find_child(node_name, true, false) as Control
		if control == null:
			return {}
		result[node_name] = control.get_rect()
	return result


func _global_rails_are_hidden(main: Control) -> bool:
	var left := main.find_child("ResourceRailSurface", true, false) as Control
	var right := main.find_child("ContextInspectorSurface", true, false) as Control
	return left != null and right != null and not left.visible and not right.visible


func _geometry_matches(current: Dictionary, expected: Dictionary) -> bool:
	if current.size() != expected.size():
		return false
	for key_value in expected.keys():
		var key := String(key_value)
		if not current.has(key):
			return false
		var current_rect: Rect2 = current.get(key, Rect2())
		var expected_rect: Rect2 = expected.get(key, Rect2())
		if not current_rect.is_equal_approx(expected_rect):
			return false
	return true


func _clear_scale_session() -> void:
	get_tree().root.remove_meta(UiTokens.UI_SCALE_SESSION_META)
	get_tree().root.remove_meta(Policy.SESSION_STATE_META)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		failures.append(description)
		push_error("FAIL: %s" % description)
