class_name IndustrialNetworkEdgeLayer
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var _graph: GraphEdit
var _nodes := {}
var _edges: Array = []
var _world_paths := {}
var _screen_paths := {}
var _screen_labels := {}
var _visual_phase := 0.0
var _reduced_motion := false
var _simulation_paused := false
var _selected_node_id := ""
var _hovered_node_id := ""
var _visible_layers := {"MATERIAL":true, "LOGISTICS":true, "DEMAND":true, "SERVICE":false}
var _focus_mode := ""
var _focus_nodes := {}
var _focus_edges := {}
var _viewport_signature := ""


func configure(graph: GraphEdit) -> void:
	_graph = graph
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip_contents = true


func set_graph_data(edges: Array, nodes: Dictionary) -> void:
	_edges = edges.duplicate(true)
	_nodes = nodes
	_rebuild_world_paths()
	_rebuild_screen_paths(true)


func set_layer_visibility(layer: String, visible: bool) -> void:
	_visible_layers[layer] = visible
	queue_redraw()


func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled
	queue_redraw()


func set_simulation_paused(paused: bool) -> void:
	_simulation_paused = paused
	queue_redraw()


func set_selected_node(node_id: String) -> void:
	_selected_node_id = node_id
	queue_redraw()


func set_hovered_node(node_id: String) -> void:
	_hovered_node_id = node_id
	queue_redraw()


func set_focus(mode: String, node_ids: Array, edge_ids: Array) -> void:
	_focus_mode = mode
	_focus_nodes.clear()
	_focus_edges.clear()
	for node_id in node_ids:
		_focus_nodes[str(node_id)] = true
	for edge_id in edge_ids:
		_focus_edges[str(edge_id)] = true
	queue_redraw()


func advance_visual(delta: float) -> void:
	if not is_instance_valid(_graph):
		return
	_rebuild_screen_paths(false)
	if not _reduced_motion and not _simulation_paused and is_visible_in_tree():
		_visual_phase = fmod(_visual_phase + delta, 120.0)
	queue_redraw()


func mark_geometry_dirty() -> void:
	_rebuild_world_paths()
	_rebuild_screen_paths(true)


func mark_viewport_dirty() -> void:
	_rebuild_screen_paths(true)


func animation_phase() -> float:
	return _visual_phase


func set_animation_phase(phase: float) -> void:
	_visual_phase = fposmod(maxf(0.0, phase), 120.0)
	queue_redraw()


func _rebuild_world_paths() -> void:
	_world_paths.clear()
	for edge_value in _edges:
		var edge := edge_value as Dictionary
		var source = _nodes.get(str(edge.get("source", ""))) as IndustrialNetworkNode
		var target = _nodes.get(str(edge.get("target", ""))) as IndustrialNetworkNode
		if not is_instance_valid(source) or not is_instance_valid(target):
			continue
		var source_port := source.output_port(str(edge.get("source_port", "")))
		var target_port := target.input_port(str(edge.get("target_port", "")))
		# GraphNode rebuilds its internal port cache during layout. Viewport signals
		# can arrive in the short interval before that cache is ready.
		if source_port < 0 or target_port < 0 or source_port >= source.get_output_port_count() or target_port >= target.get_input_port_count():
			continue
		var start: Vector2 = source.position_offset + source.get_output_port_position(source_port)
		var finish: Vector2 = target.position_offset + target.get_input_port_position(target_port)
		_world_paths[str(edge.get("id", ""))] = _curve_points(start, finish)


func _rebuild_screen_paths(force: bool) -> void:
	if not is_instance_valid(_graph):
		return
	var signature := "%.3f|%.1f|%.1f|%.1f|%.1f" % [_graph.zoom, _graph.scroll_offset.x, _graph.scroll_offset.y, size.x, size.y]
	if not force and signature == _viewport_signature:
		return
	_viewport_signature = signature
	_screen_paths.clear()
	_screen_labels.clear()
	for edge_value in _edges:
		var edge := edge_value as Dictionary
		var edge_id := str(edge.get("id", ""))
		var world: PackedVector2Array = _world_paths.get(edge_id, PackedVector2Array())
		if world.is_empty():
			continue
		var screen := PackedVector2Array()
		screen.resize(world.size())
		for index in world.size():
			screen[index] = (world[index] - _graph.scroll_offset) * _graph.zoom
		_screen_paths[edge_id] = screen
		_screen_labels[edge_id] = screen[screen.size() / 2]
	queue_redraw()


func _draw() -> void:
	_draw_grid()
	for edge_value in _edges:
		var edge := edge_value as Dictionary
		var layer := str(edge.get("layer", "MATERIAL"))
		if not bool(_visible_layers.get(layer, false)):
			continue
		var edge_id := str(edge.get("id", ""))
		var path: PackedVector2Array = _screen_paths.get(edge_id, PackedVector2Array())
		if path.size() < 2 or not _path_on_screen(path):
			continue
		var focused := _focus_mode.is_empty() or _focus_edges.has(edge_id)
		var alpha := 0.78 if focused else 0.10
		var color := _edge_color(edge)
		color.a *= alpha
		var utilization := clampf(float(edge.get("utilization", 0.0)), 0.0, 1.0)
		var width := (1.35 + utilization * 1.25) * maxf(0.75, _graph.zoom)
		if bool(edge.get("in_bottleneck", false)) and _focus_mode == "BOTTLENECK":
			color = UiTokens.COLOR_WARNING
			color.a = 0.98
			width += 1.4
		_draw_edge_path(path, color, width, str(edge.get("status", "IDLE")))
		_draw_arrow(path, color, width)
		if focused and float(edge.get("actual_flow", 0.0)) > 0.000001 and not _reduced_motion and not _simulation_paused and str(edge.get("status", "")) not in ["PAUSED", "BLOCKED"]:
			_draw_flow_packets(path, edge, color)
		if _should_show_label(edge):
			_draw_edge_label(edge, _screen_labels.get(edge_id, Vector2.ZERO), color)


func _draw_grid() -> void:
	if not is_instance_valid(_graph):
		return
	var minor := float(UiTokens.NETWORK_GRID_MINOR_SIZE) * _graph.zoom
	if minor < 8.0:
		minor *= 2.0
	var major := minor * float(UiTokens.NETWORK_GRID_MAJOR_EVERY)
	var origin := -Vector2(fposmod(_graph.scroll_offset.x * _graph.zoom, minor), fposmod(_graph.scroll_offset.y * _graph.zoom, minor))
	var major_origin := -Vector2(fposmod(_graph.scroll_offset.x * _graph.zoom, major), fposmod(_graph.scroll_offset.y * _graph.zoom, major))
	var x := origin.x
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), UiTokens.COLOR_GRID_MINOR, 1.0)
		x += minor
	var y := origin.y
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), UiTokens.COLOR_GRID_MINOR, 1.0)
		y += minor
	x = major_origin.x
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), UiTokens.COLOR_GRID_MAJOR, 1.0)
		x += major
	y = major_origin.y
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), UiTokens.COLOR_GRID_MAJOR, 1.0)
		y += major


func _curve_points(start: Vector2, finish: Vector2) -> PackedVector2Array:
	var result := PackedVector2Array()
	var direction := 1.0 if finish.x >= start.x else -1.0
	var reach := maxf(52.0, absf(finish.x - start.x) * 0.42)
	var control_a := start + Vector2(reach * direction, 0)
	var control_b := finish - Vector2(reach * direction, 0)
	const SAMPLES := 22
	result.resize(SAMPLES + 1)
	for index in SAMPLES + 1:
		var t := float(index) / float(SAMPLES)
		var inverse := 1.0 - t
		result[index] = inverse * inverse * inverse * start + 3.0 * inverse * inverse * t * control_a + 3.0 * inverse * t * t * control_b + t * t * t * finish
	return result


func _draw_edge_path(path: PackedVector2Array, color: Color, width: float, status: String) -> void:
	if status == "BLOCKED":
		for index in range(0, path.size() - 1, 2):
			draw_line(path[index], path[index + 1], color, width, true)
		return
	draw_polyline(path, color, width, true)


func _draw_arrow(path: PackedVector2Array, color: Color, width: float) -> void:
	var finish := path[path.size() - 1]
	var previous := path[path.size() - 2]
	var direction := (finish - previous).normalized()
	var perpendicular := Vector2(-direction.y, direction.x)
	var length := 7.0 + width
	var points := PackedVector2Array([finish, finish - direction * length + perpendicular * length * 0.48, finish - direction * length - perpendicular * length * 0.48])
	draw_colored_polygon(points, color)


func _draw_flow_packets(path: PackedVector2Array, edge: Dictionary, color: Color) -> void:
	var flow := maxf(0.0, float(edge.get("actual_flow", 0.0)))
	var utilization := clampf(float(edge.get("utilization", 0.0)), 0.0, 1.0)
	var speed := 0.10 + minf(0.85, log(1.0 + flow) / 7.0) * (0.55 + utilization * 0.45)
	if str(edge.get("status", "")) == "CONGESTED":
		speed *= 0.48
	var count := clampi(1 + int(utilization * 3.0), 1, 4)
	var seed := float(abs(str(edge.get("id", "")).hash()) % 997) / 997.0
	for packet_index in count:
		var progress := fposmod(seed + _visual_phase * speed + float(packet_index) / float(count), 1.0)
		var position := _sample_path(path, progress)
		var packet_color := color.lightened(0.22)
		packet_color.a = minf(1.0, color.a + 0.18)
		draw_circle(position, 2.2 + utilization * 1.2, packet_color)


func _sample_path(path: PackedVector2Array, progress: float) -> Vector2:
	var scaled := clampf(progress, 0.0, 1.0) * float(path.size() - 1)
	var index := mini(path.size() - 2, int(floor(scaled)))
	return path[index].lerp(path[index + 1], scaled - float(index))


func _should_show_label(edge: Dictionary) -> bool:
	if _graph.zoom >= 1.32:
		return true
	if _focus_mode == "BOTTLENECK":
		return bool(edge.get("in_bottleneck", false))
	var source := str(edge.get("source", ""))
	var target := str(edge.get("target", ""))
	return _selected_node_id in [source, target] or _hovered_node_id in [source, target]


func _draw_edge_label(edge: Dictionary, center: Vector2, color: Color) -> void:
	var text := I18n.core("industrial_network.edge.label", "Actual %.1f/h · Requested %.1f/h · Capacity %.1f/h") % [float(edge.get("actual_flow", 0.0)), float(edge.get("requested_flow", 0.0)), float(edge.get("capacity", 0.0))]
	var font := ThemeDB.fallback_font
	var font_size := UiTokens.font_size(10)
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var rect := Rect2(center - Vector2(text_size.x * 0.5 + 6.0, 12.0), Vector2(text_size.x + 12.0, 24.0))
	draw_style_box(UiTokens.panel_style(Color(UiTokens.COLOR_INSET, 0.94), color.darkened(0.18), 3), rect)
	draw_string(font, rect.position + Vector2(6, 16), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, UiTokens.COLOR_TEXT_SECONDARY)


func _path_on_screen(path: PackedVector2Array) -> bool:
	var bounds := Rect2(path[0], Vector2.ZERO)
	for point in path:
		bounds = bounds.expand(point)
	return bounds.grow(48.0).intersects(Rect2(Vector2.ZERO, size))


func _edge_color(edge: Dictionary) -> Color:
	match str(edge.get("status", "IDLE")):
		"CONGESTED": return UiTokens.COLOR_WARNING
		"BLOCKED": return UiTokens.COLOR_CRITICAL
		"PAUSED", "IDLE": return UiTokens.COLOR_INACTIVE
	match str(edge.get("layer", "MATERIAL")):
		"LOGISTICS": return UiTokens.COLOR_INFO
		"DEMAND": return UiTokens.COLOR_WARNING
		"SERVICE": return UiTokens.COLOR_ENERGY
		_: return UiTokens.COLOR_MATERIAL
