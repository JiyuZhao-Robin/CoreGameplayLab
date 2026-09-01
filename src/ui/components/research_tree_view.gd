class_name ResearchTreeView
extends GraphEdit

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

signal project_selected(project_id: String)
signal project_action(project_id: String, route_id: String)
signal pause_requested
signal unlock_guidance_requested(project_id: String)

const NODE_WIDTH := 244.0
const COLUMN_GAP := 304.0
const ROW_GAP := 138.0
const TECHNOLOGY_TOP := 74.0
const SHIP_TOP := 900.0

var _model: Dictionary = {}
var _node_data: Dictionary = {}


func _ready() -> void:
	name = "ResearchTechnologyGraph"
	custom_minimum_size.y = 640.0
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	show_grid = true
	show_menu = false
	snapping_enabled = false
	minimap_enabled = false
	connection_lines_curvature = 0.0
	zoom_min = 0.48
	zoom_max = 1.35
	zoom_step = 1.12
	add_theme_color_override("grid_minor", UiTokens.COLOR_GRID_MINOR)
	add_theme_color_override("grid_major", UiTokens.COLOR_GRID_MAJOR)
	add_theme_color_override("activity", UiTokens.COLOR_FOCUS)
	add_theme_stylebox_override("panel", UiTokens.panel_style(UiTokens.COLOR_CANVAS, UiTokens.COLOR_BORDER, 2))
	node_selected.connect(_on_node_selected)


func configure(model: Dictionary) -> void:
	_model = model
	_rebuild()


func _rebuild() -> void:
	for child in get_children():
		if child is GraphNode:
			child.queue_free()
	clear_connections()
	_node_data.clear()
	var nodes: Array = _model.get("nodes", [])
	for node_value in nodes:
		var data := node_value as Dictionary
		_node_data[String(data.get("id", ""))] = data
	var tier_cache := {}
	var tier_groups := {}
	for node_value in nodes:
		var data := node_value as Dictionary
		var project_id := String(data.get("id", ""))
		var tier := _tier_for(project_id, tier_cache, {})
		var lane := String(data.get("lane", "TECHNOLOGY"))
		var key := "%s:%d" % [lane, tier]
		if not tier_groups.has(key):
			tier_groups[key] = []
		(tier_groups[key] as Array).append(data)
	for group_value in tier_groups.values():
		(group_value as Array).sort_custom(func(a: Dictionary, b: Dictionary): return String(a.get("title", "")) < String(b.get("title", "")))

	var core := _build_core_node()
	add_child(core)
	for node_value in nodes:
		var data := node_value as Dictionary
		var project_id := String(data.get("id", ""))
		var tier := int(tier_cache.get(project_id, 0))
		var lane := String(data.get("lane", "TECHNOLOGY"))
		var group: Array = tier_groups.get("%s:%d" % [lane, tier], [])
		var row := group.find(data)
		var graph_node := _build_project_node(data)
		graph_node.position_offset = Vector2(300.0 + tier * COLUMN_GAP, (TECHNOLOGY_TOP if lane == "TECHNOLOGY" else SHIP_TOP) + row * ROW_GAP)
		add_child(graph_node)

	for node_value in nodes:
		var data := node_value as Dictionary
		var project_id := String(data.get("id", ""))
		var dependencies: Array = data.get("dependencies", [])
		if dependencies.is_empty():
			connect_node("research_core", 0, project_id, 0)
			continue
		for dependency_value in dependencies:
			var dependency := String(dependency_value)
			if _node_data.has(dependency):
				connect_node(dependency, 0, project_id, 0)
	call_deferred("_reset_view")


func _build_core_node() -> GraphNode:
	var node := GraphNode.new()
	node.name = "research_core"
	node.title = String(_model.get("core_title", "RESEARCH CORE"))
	node.position_offset = Vector2(32.0, 310.0)
	node.custom_minimum_size = Vector2(190.0, 92.0)
	node.draggable = false
	node.selectable = false
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = String(_model.get("core_subtitle", ""))
	label.add_theme_color_override("font_color", UiTokens.COLOR_FOCUS)
	label.add_theme_font_size_override("font_size", UiTokens.font_size(12))
	body.add_child(label)
	var summary := Label.new()
	summary.text = String(_model.get("core_summary", ""))
	summary.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	summary.add_theme_font_size_override("font_size", UiTokens.font_size(11))
	body.add_child(summary)
	node.add_child(body)
	node.set_slot(0, false, 0, UiTokens.COLOR_INACTIVE, true, 0, UiTokens.COLOR_RESEARCH)
	_apply_node_style(node, UiTokens.COLOR_RESEARCH, "AVAILABLE")
	return node


func _build_project_node(data: Dictionary) -> GraphNode:
	var project_id := String(data.get("id", ""))
	var status_id := String(data.get("status_id", "LOCKED"))
	var tone := _status_tone(status_id, String(data.get("lane", "TECHNOLOGY")))
	var node := GraphNode.new()
	node.name = project_id
	node.title = String(data.get("title", project_id))
	node.custom_minimum_size = Vector2(NODE_WIDTH, 82.0)
	node.draggable = false
	node.selectable = true
	node.resizable = false
	node.set_meta("project_id", project_id)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 5)
	body.custom_minimum_size.x = NODE_WIDTH - 20.0
	var status := Label.new()
	status.name = "ResearchNodeStatus"
	status.text = String(_model.get("status_format")) % String(data.get("status", status_id))
	status.add_theme_color_override("font_color", tone)
	status.add_theme_font_size_override("font_size", UiTokens.font_size(11))
	body.add_child(status)
	node.tooltip_text = String(data.get("summary", ""))
	_add_project_actions(body, data, tone)
	node.add_child(body)
	node.set_slot(0, true, 0, tone, true, 0, tone)
	_apply_node_style(node, tone, status_id)
	return node


func _add_project_actions(body: VBoxContainer, data: Dictionary, tone: Color) -> void:
	var project_id := String(data.get("id", ""))
	var action_mode := String(data.get("action_mode", "LOCKED"))
	var action_enabled := bool(data.get("action_enabled", false))
	var reason := String(data.get("reason", ""))
	if action_mode == "COMPLETED":
		return
	if action_mode == "GUIDANCE":
		var guidance := _node_button(String(data.get("action_label", "OPEN OBJECTIVES")), tone, true)
		guidance.name = "ResearchUnlockGuidance_%s" % project_id
		guidance.tooltip_text = reason
		guidance.pressed.connect(_emit_unlock_guidance.bind(project_id))
		body.add_child(guidance)
		return
	if action_mode == "PAUSE":
		var pause := _node_button(String(data.get("action_label", "PAUSE")), UiTokens.COLOR_WARNING, false)
		pause.name = "PauseResearch_%s" % project_id
		pause.pressed.connect(func(): pause_requested.emit())
		body.add_child(pause)
		return
	if action_mode == "RESUME":
		var resume := _node_button(String(data.get("action_label", "RESUME")), tone, not action_enabled)
		resume.name = "ResumeResearch_%s" % project_id
		resume.tooltip_text = reason
		resume.pressed.connect(_emit_project_action.bind(project_id, String(data.get("active_route_id", ""))))
		body.add_child(resume)
		return
	var routes: Array = data.get("routes", [])
	if routes.is_empty():
		var start := _node_button(String(data.get("action_label", "START")), tone, not action_enabled)
		start.name = "StartResearch_%s" % project_id
		start.tooltip_text = reason
		start.pressed.connect(_emit_project_action.bind(project_id, ""))
		body.add_child(start)
		return
	for route_value in routes:
		var route := route_value as Dictionary
		var route_id := String(route.get("id", ""))
		var route_enabled := bool(route.get("enabled", action_enabled))
		var route_button := _node_button(String(route.get("label", route_id)), tone, not route_enabled)
		route_button.name = "StartResearch_%s_%s" % [project_id, route_id]
		route_button.tooltip_text = reason if not route_enabled else String(route.get("description", ""))
		route_button.pressed.connect(_emit_project_action.bind(project_id, route_id))
		body.add_child(route_button)


func _node_button(caption: String, tone: Color, disabled: bool) -> Button:
	var button := Button.new()
	button.text = caption
	button.disabled = disabled
	button.custom_minimum_size.y = 27.0
	button.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	button.add_theme_color_override("font_color", tone)
	button.add_theme_color_override("font_disabled_color", UiTokens.COLOR_TEXT_MUTED.darkened(0.25))
	return button


func _apply_node_style(node: GraphNode, tone: Color, status_id: String) -> void:
	var fill := UiTokens.COLOR_NODE_SURFACE
	if status_id in ["RUNNING", "BLOCKED"]:
		fill = UiTokens.COLOR_CONTROL_ACTIVE
	elif status_id == "COMPLETED":
		fill = UiTokens.COLOR_RUNNING.darkened(0.72)
	var panel := UiTokens.panel_style(fill, tone.darkened(0.25), 5)
	var selected := UiTokens.panel_style(UiTokens.COLOR_CONTROL_ACTIVE, tone, 5)
	selected.set_border_width_all(2)
	var titlebar := UiTokens.panel_style(UiTokens.COLOR_NODE_HEADER, tone.darkened(0.42), 4)
	node.add_theme_stylebox_override("panel", panel)
	node.add_theme_stylebox_override("panel_selected", selected)
	node.add_theme_stylebox_override("titlebar", titlebar)
	node.add_theme_stylebox_override("titlebar_selected", selected)
	node.add_theme_color_override("title_color", UiTokens.COLOR_TEXT)
	node.add_theme_font_size_override("title_font_size", UiTokens.font_size(12))


func _status_tone(status_id: String, lane: String) -> Color:
	match status_id:
		"COMPLETED": return UiTokens.COLOR_RUNNING
		"RUNNING": return UiTokens.COLOR_FOCUS
		"PAUSED": return UiTokens.COLOR_WARNING
		"BLOCKED": return UiTokens.COLOR_CRITICAL
		"AVAILABLE": return UiTokens.COLOR_RESEARCH if lane == "TECHNOLOGY" else UiTokens.COLOR_INFORMATION
	return UiTokens.COLOR_INACTIVE


func _tier_for(project_id: String, cache: Dictionary, visiting: Dictionary) -> int:
	if cache.has(project_id):
		return int(cache[project_id])
	if visiting.has(project_id):
		return 0
	visiting[project_id] = true
	var result := 0
	var data: Dictionary = _node_data.get(project_id, {})
	for dependency_value in data.get("dependencies", []):
		var dependency := String(dependency_value)
		if _node_data.has(dependency):
			result = maxi(result, _tier_for(dependency, cache, visiting.duplicate()) + 1)
	cache[project_id] = result
	return result


func _reset_view() -> void:
	zoom = 0.88
	scroll_offset = Vector2(0.0, 0.0)


func _on_node_selected(node: Node) -> void:
	if node.has_meta("project_id"):
		project_selected.emit(String(node.get_meta("project_id")))


func _emit_project_action(project_id: String, route_id: String) -> void:
	project_action.emit(project_id, route_id)


func _emit_unlock_guidance(project_id: String) -> void:
	unlock_guidance_requested.emit(project_id)
