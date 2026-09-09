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
const DEFAULT_CAMERA_ZOOM := 0.88

var _model: Dictionary = {}
var _node_data: Dictionary = {}
var _camera_initialized := false
var _focused_project_id := ""
var _pending_initial_project_id := ""
var _configuration_revision := 0
var _camera_operation_revision := 0
var _programmatic_selection := false


func _ready() -> void:
	name = "ResearchTechnologyGraph"
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
	zoom = DEFAULT_CAMERA_ZOOM
	add_theme_color_override("grid_minor", UiTokens.COLOR_GRID_MINOR)
	add_theme_color_override("grid_major", UiTokens.COLOR_GRID_MAJOR)
	add_theme_color_override("activity", UiTokens.COLOR_FOCUS)
	add_theme_stylebox_override("panel", UiTokens.panel_style(UiTokens.COLOR_CANVAS, UiTokens.COLOR_BORDER, 2))
	node_selected.connect(_on_node_selected)
	resized.connect(_on_research_view_resized)


func configure(model: Dictionary) -> void:
	# The application refreshes this model when research state changes. A no-op
	# refresh must not recreate a large graph or jump the player's camera. When
	# data does change, preserve the same world-space camera instead of calling a
	# generic fit/reset operation.
	if model == _model and not _node_data.is_empty():
		return
	var preserved_camera := camera_state() if _camera_initialized else Vector3.ZERO
	var preserved_focus := _focused_project_id
	_model = model.duplicate(true)
	_configuration_revision += 1
	_rebuild()
	if _camera_initialized:
		restore_camera(preserved_camera)
		_restore_focused_project(preserved_focus)
		call_deferred("_restore_camera_after_refresh", preserved_camera, preserved_focus, _configuration_revision, _camera_operation_revision)
	else:
		_pending_initial_project_id = _initial_project_id()
		call_deferred("_apply_pending_initial_focus", _configuration_revision)


func camera_state() -> Vector3:
	return Vector3(scroll_offset.x, scroll_offset.y, zoom)


func restore_camera(camera: Vector3) -> void:
	# This is intentionally local GraphEdit state. It is not multiplied by the
	# game's canvas scale or the player's text-scale preference.
	_camera_operation_revision += 1
	_apply_camera(camera)
	_camera_initialized = true
	_pending_initial_project_id = ""
	call_deferred("_restore_camera_after_refresh", camera, _focused_project_id, _configuration_revision, _camera_operation_revision)


func focus_project(project_id: String) -> bool:
	var graph_node := get_node_or_null(NodePath(project_id)) as GraphNode
	if graph_node == null or not graph_node.has_meta("project_id"):
		return false
	_select_graph_node(graph_node)
	_focused_project_id = project_id
	_pending_initial_project_id = ""
	if size.x < 2.0 or size.y < 2.0:
		# A caller may select a project while its page is still being mounted. Keep
		# the intent and centre it once GraphEdit receives its actual workspace.
		_pending_initial_project_id = project_id
		return true
	_center_on_project_node(graph_node)
	_camera_operation_revision += 1
	call_deferred("_recenter_project_after_layout", project_id, _camera_operation_revision)
	_camera_initialized = true
	return true


func _rebuild() -> void:
	clear_connections()
	for child in get_children():
		if child is GraphNode:
			remove_child(child)
			child.queue_free()
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


func _initial_project_id() -> String:
	# Active work has precedence. In a fresh save, early technology research is
	# more useful than whichever ship-development ID happens to sort first; that
	# keeps the opening camera in the technology lane instead of the far-lower
	# locked fleet lane.
	var candidates: Array[Dictionary] = []
	for data_value in _node_data.values():
		candidates.append(data_value as Dictionary)
	candidates.sort_custom(_compare_initial_project_candidates)
	for status_id in ["RUNNING", "PAUSED", "BLOCKED"]:
		for data in candidates:
			if String(data.get("status_id", "LOCKED")) == status_id:
				return String(data.get("id", ""))
	for data in candidates:
		if String(data.get("status_id", "LOCKED")) == "AVAILABLE" and String(data.get("lane", "TECHNOLOGY")) == "TECHNOLOGY":
			return String(data.get("id", ""))
	for data in candidates:
		if String(data.get("status_id", "LOCKED")) == "AVAILABLE":
			return String(data.get("id", ""))
	for data in candidates:
		if String(data.get("lane", "TECHNOLOGY")) == "TECHNOLOGY":
			return String(data.get("id", ""))
	return String(candidates[0].get("id", "")) if not candidates.is_empty() else ""


func _compare_initial_project_candidates(a: Dictionary, b: Dictionary) -> bool:
	var a_technology := String(a.get("lane", "TECHNOLOGY")) == "TECHNOLOGY"
	var b_technology := String(b.get("lane", "TECHNOLOGY")) == "TECHNOLOGY"
	if a_technology != b_technology:
		return a_technology
	var tier_cache := {}
	var a_tier := _tier_for(String(a.get("id", "")), tier_cache, {})
	var b_tier := _tier_for(String(b.get("id", "")), tier_cache, {})
	if a_tier != b_tier:
		return a_tier < b_tier
	return String(a.get("id", "")) < String(b.get("id", ""))


func _apply_pending_initial_focus(revision: int) -> void:
	if revision != _configuration_revision or _pending_initial_project_id.is_empty() or _camera_initialized:
		return
	if size.x < 2.0 or size.y < 2.0:
		return
	focus_project(_pending_initial_project_id)


func _restore_camera_after_refresh(camera: Vector3, project_id: String, configuration_revision: int, camera_revision: int) -> void:
	# GraphEdit may reconcile GraphNode bounds during the idle layout pass. Reapply
	# the exact player camera once that pass is complete, but never override a
	# newer explicit focus/restore request.
	if configuration_revision != _configuration_revision or camera_revision != _camera_operation_revision:
		return
	_apply_camera(camera)
	_restore_focused_project(project_id)


func _recenter_project_after_layout(project_id: String, camera_revision: int) -> void:
	if camera_revision != _camera_operation_revision or project_id != _focused_project_id:
		return
	var graph_node := get_node_or_null(NodePath(project_id)) as GraphNode
	if graph_node != null and size.x >= 2.0 and size.y >= 2.0:
		_center_on_project_node(graph_node)


func _apply_camera(camera: Vector3) -> void:
	zoom = clampf(camera.z, zoom_min, zoom_max)
	scroll_offset = Vector2(camera.x, camera.y)


func _select_graph_node(graph_node: GraphNode) -> void:
	# Programmatic focus is a presentation command, not player node activation.
	# Suppress GraphEdit's selection signal until the current idle pass completes,
	# otherwise Main selects/rebuilds the page recursively and can overwrite the
	# intended initial focus with a stale project ID.
	_programmatic_selection = true
	set_block_signals(true)
	for child in get_children():
		if child is GraphNode and child != graph_node:
			(child as GraphNode).selected = false
	graph_node.selected = true
	set_block_signals(false)
	call_deferred("_release_programmatic_selection")


func _release_programmatic_selection() -> void:
	_programmatic_selection = false


func _on_research_view_resized() -> void:
	if not _pending_initial_project_id.is_empty() and not _camera_initialized:
		call_deferred("_apply_pending_initial_focus", _configuration_revision)


func _restore_focused_project(project_id: String) -> void:
	if project_id.is_empty():
		return
	var graph_node := get_node_or_null(NodePath(project_id)) as GraphNode
	if graph_node != null:
		_select_graph_node(graph_node)
		_focused_project_id = project_id
	else:
		_focused_project_id = ""


func _center_on_project_node(graph_node: GraphNode) -> void:
	var node_size := graph_node.size
	if node_size.x <= 0.0 or node_size.y <= 0.0:
		node_size = graph_node.custom_minimum_size
	var world_center := graph_node.position_offset + node_size * 0.5
	scroll_offset = world_center * zoom - size * 0.5


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


func _on_node_selected(node: Node) -> void:
	if not _programmatic_selection and node.has_meta("project_id"):
		_focused_project_id = String(node.get_meta("project_id"))
		project_selected.emit(_focused_project_id)


func _emit_project_action(project_id: String, route_id: String) -> void:
	project_action.emit(project_id, route_id)


func _emit_unlock_guidance(project_id: String) -> void:
	unlock_guidance_requested.emit(project_id)
