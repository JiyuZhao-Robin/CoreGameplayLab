extends Node

const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipModuleInspectorScript = preload("res://src/ui/components/ship_module_inspector.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []
var view: ShipAssemblyMapView
var reactor: GraphNode
var inspector_panel: PanelContainer
var inspector: ShipModuleInspector


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	get_window().size = Vector2i(1800, 1050)
	var background := ColorRect.new()
	background.color = UiTokens.COLOR_SHIP_CANVAS
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view = ShipAssemblyMapViewScript.new()
	add_child(view)
	view.position = Vector2(24.0, 24.0)
	view.size = Vector2(1752.0, 1002.0)
	view.configure(_catalog(), {})
	await _frames(3)
	view.call("_drop_data", Vector2(900.0, 450.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	await _frames(4)
	view.call("_drop_data", Vector2(210.0, 520.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"civilian_reactor_core"})
	await _frames(4)
	reactor = view.get_node_or_null(NodePath("ship_design_module_0001")) as GraphNode
	var hull := view.get_node_or_null(NodePath("ship_design_hull")) as GraphNode
	_check(reactor != null and hull != null, "representative unified-module scene contains the existing hull and module entities")
	if reactor == null or hull == null:
		_finish()
		return
	hull.position_offset = Vector2(720.0, 190.0)
	reactor.position_offset = Vector2(220.0, 440.0)
	view.call("_layout_hull_socket_nodes")
	_frame_focus(Vector2(700.0, 500.0), 1.05)
	await _capture("01_reactor_idle")

	view.call("_on_visual_node_hover_changed", reactor, true)
	await _capture("02_reactor_hover")

	view.call("_on_visual_node_hover_changed", reactor, false)
	reactor.selected = true
	view.call("_on_node_selected", reactor)
	await _capture("03_reactor_selected")

	view.call("_begin_module_move", String(reactor.name), reactor, Vector2(320.0, 520.0))
	await _capture("04_reactor_dragging")
	view.call("_finish_module_move")

	view.call("_begin_module_card_connection", String(reactor.name))
	view.call("_on_socket_hover_changed", "socket_core_0", true)
	await _capture("05_compatible_socket_target")
	view.call("_complete_module_card_connection", Vector2(-1000.0, -1000.0))
	await get_tree().create_timer(0.50).timeout
	await _capture("06_installed_connection")

	_frame_focus(Vector2(700.0, 500.0), 0.88)
	await _capture("07_normal_zoom")

	_frame_focus(Vector2(700.0, 500.0), 0.42)
	await _capture("08_far_zoom")

	_build_inspector()
	view.size = Vector2(1328.0, 1002.0)
	inspector_panel.visible = true
	_frame_focus(Vector2(700.0, 500.0), 0.92)
	await _capture("09_reactor_selected_inspector")

	inspector_panel.visible = false
	view.size = Vector2(1752.0, 1002.0)
	view.fit_design()
	view.call("_on_zoom_changed", view.zoom)
	await _capture("10_whole_assembly_canvas")
	_finish()


func _catalog() -> Dictionary:
	var plan_id := "construct_lunar_pathfinder"
	var plan := (Game.content.ship_construction_projects[plan_id] as Dictionary).duplicate(true)
	plan["title"] = "Lunar Pathfinder"
	plan["assembly_sockets"] = Game.ship_design_socket_schema(plan_id)
	var hull_id := String(plan.get("ship_id", ""))
	var hull := (Game.content.ships[hull_id] as Dictionary).duplicate(true)
	var module := (Game.content.modules["civilian_reactor_core"] as Dictionary).duplicate(true)
	module["title"] = "Civilian Reactor Core"
	module["assembly_mount"] = Game.ship_module_mount_role("civilian_reactor_core")
	return {
		"plans":{plan_id:plan},
		"hulls":{hull_id:hull},
		"modules":{"civilian_reactor_core":module},
		"slot_labels":{"core":"核心 / CORE"},
		"socket_label_format":"%s %d",
		"module_label_format":"%s · %s",
		"hull_summary_format":"%s · %d sockets",
		"core_socket_format":"Energy Core %d"
	}


func _build_inspector() -> void:
	inspector_panel = PanelContainer.new()
	inspector_panel.name = "ReactorInspectorPanel"
	inspector_panel.position = Vector2(1364.0, 24.0)
	inspector_panel.size = Vector2(412.0, 1002.0)
	inspector_panel.add_theme_stylebox_override("panel", UiTokens.panel_style(UiTokens.COLOR_PANEL, UiTokens.COLOR_BORDER_STRONG, 4))
	add_child(inspector_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	inspector_panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var heading := Label.new()
	heading.text = "SHIP DESIGN INSPECTOR"
	heading.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(9))
	heading.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	column.add_child(heading)
	inspector = ShipModuleInspectorScript.new()
	var module := (Game.content.modules["civilian_reactor_core"] as Dictionary).duplicate(true)
	inspector.configure(module, {
		"display_name":"Civilian Reactor Core",
		"family_label":"核心 / CORE",
		"tier_label":"T1",
		"diameter_label":"Ø5m",
		"mount_role":"CORE",
		"installation_state":"INSTALLED",
		"art_path":ShipAssemblyMapViewScript.module_icon_path(module),
		"tone":UiTokens.COLOR_WARNING
	})
	column.add_child(inspector)
	inspector_panel.visible = false


func _frame_focus(world_focus: Vector2, target_zoom: float) -> void:
	view.zoom = target_zoom
	view.call("_on_zoom_changed", view.zoom)
	view.scroll_offset = world_focus * view.zoom - view.size * 0.5


func _capture(label: String) -> void:
	await _frames(3)
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	_check(image != null, "%s screenshot image is available" % label)
	if image != null:
		_check(image.save_png("res://.audit-logs/ship_module_visual_%s.png" % label) == OK, "%s audit screenshot saves" % label)


func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_MODULE_VISUAL_TEST_PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
