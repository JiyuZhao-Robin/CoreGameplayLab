class_name ShipAssemblyConnectionLayer
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var _graph: GraphEdit
var _visual_phase := 0.0


func configure(graph: GraphEdit) -> void:
	_graph = graph
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip_contents = true
	z_index = 1
	refresh()


func _process(delta: float) -> void:
	_visual_phase = fposmod(_visual_phase + delta, 120.0)
	queue_redraw()


func refresh() -> void:
	if not is_instance_valid(_graph):
		return
	var links := _graph.get("_links") as Array
	set_process(not links.is_empty() or not String(_graph.get("_connection_drag_module_name")).is_empty())
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(_graph):
		return
	_draw_canvas_material()
	_draw_established_connections()
	_draw_connection_preview()


func _draw_canvas_material() -> void:
	var spacing := 120.0 * _graph.zoom
	while spacing < 52.0:
		spacing *= 2.0
	var origin := Vector2(fposmod(-_graph.scroll_offset.x, spacing), fposmod(-_graph.scroll_offset.y, spacing))
	var material_line := Color(UiTokens.COLOR_FOCUS, 0.028)
	var x := origin.x
	while x < size.x:
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), material_line, 1.0)
		x += spacing
	var y := origin.y
	while y < size.y:
		draw_line(Vector2(0.0, y), Vector2(size.x, y), material_line, 1.0)
		y += spacing
	var center := size * 0.5
	draw_line(Vector2(center.x - 22.0, center.y), Vector2(center.x + 22.0, center.y), Color(UiTokens.COLOR_FOCUS, 0.08), 1.0, true)
	draw_line(Vector2(center.x, center.y - 22.0), Vector2(center.x, center.y + 22.0), Color(UiTokens.COLOR_FOCUS, 0.08), 1.0, true)
	draw_rect(Rect2(Vector2(1.0, 1.0), size - Vector2(2.0, 2.0)), Color(UiTokens.COLOR_BORDER_STRONG, 0.36), false, 1.0)


func _draw_established_connections() -> void:
	var links := _graph.get("_links") as Array
	var selected_key := String(_graph.get("_selected_connection_key"))
	for link_value in links:
		var link := link_value as Dictionary
		var world_path := _graph.call("_world_path_for_link", link) as PackedVector2Array
		var path := _world_to_screen(world_path)
		if path.size() < 2:
			continue
		var tone := _graph.call("_slot_tone", String(link.get("slot", "utility"))) as Color
		var socket_node_name := String(_graph.call("_socket_node_name", String(link.get("socket_id", ""))))
		var key := String(_graph.call("_connection_key", String(link.get("module_node_id", "")), socket_node_name))
		var selected := key == selected_key
		var width := 3.2 if selected else 2.15
		draw_polyline(path, UiTokens.COLOR_SHIP_LINK_SHADOW, width + 6.0, true)
		draw_polyline(path, Color(tone, 0.18 if not selected else 0.32), width + 3.0, true)
		draw_polyline(path, tone.lightened(0.14) if selected else tone, width, true)
		_draw_connection_arrow(path, tone.lightened(0.18), width)
		_draw_connection_packets(path, link, tone, selected)


func _draw_connection_packets(path: PackedVector2Array, link: Dictionary, tone: Color, selected: bool) -> void:
	var seed := float(abs(String(link.get("module_node_id", "")).hash()) % 997) / 997.0
	var packet_count := 2 if selected else 1
	for packet_index in packet_count:
		var progress := fposmod(seed + _visual_phase * 0.18 + float(packet_index) / float(packet_count), 1.0)
		var position := _sample_path(path, progress)
		draw_circle(position, 5.0 if selected else 4.0, Color(tone, 0.10))
		draw_circle(position, 2.4 if selected else 1.9, tone.lightened(0.28))


func _draw_connection_arrow(path: PackedVector2Array, tone: Color, width: float) -> void:
	var position := _sample_path(path, 0.84)
	var previous := _sample_path(path, 0.80)
	var direction := (position - previous).normalized()
	if direction.length_squared() < 0.1:
		return
	var perpendicular := Vector2(-direction.y, direction.x)
	var length := 5.5 + width
	draw_colored_polygon(PackedVector2Array([
		position + direction * length * 0.55,
		position - direction * length * 0.45 + perpendicular * length * 0.46,
		position - direction * length * 0.45 - perpendicular * length * 0.46
	]), Color(tone, 0.88))


func _draw_connection_preview() -> void:
	var source_name := String(_graph.get("_connection_drag_module_name"))
	if source_name.is_empty():
		return
	var source := _graph.get_node_or_null(NodePath(source_name)) as GraphNode
	if source == null or source.get_output_port_count() <= 0:
		return
	var source_world := source.position_offset + source.get_output_port_position(0)
	var target_screen := _graph.get_local_mouse_position()
	var target_world := (target_screen + _graph.scroll_offset) / maxf(_graph.zoom, 0.01)
	var path := _world_to_screen(_graph.call("_get_connection_line", source_world, target_world) as PackedVector2Array)
	var tone := UiTokens.COLOR_FOCUS
	var hovered_socket_id := String(_graph.get("_hovered_socket_id"))
	if not hovered_socket_id.is_empty():
		var socket := _graph.call("_hull_socket", hovered_socket_id) as Dictionary
		tone = UiTokens.COLOR_RUNNING if bool(_graph.call("_socket_matches_dragged_module", socket)) else UiTokens.COLOR_CRITICAL
	draw_polyline(path, Color(tone, 0.16), 13.0, true)
	_draw_dashed_path(path, tone.lightened(0.16), 3.0, 11.0, 7.0, _visual_phase * 34.0)
	draw_circle(target_screen, 9.0, Color(tone, 0.14))
	draw_circle(target_screen, 5.0, tone)
	draw_arc(target_screen, 7.0, 0.0, TAU, 24, Color.WHITE, 2.0, true)


func _draw_dashed_path(path: PackedVector2Array, color: Color, width: float, dash_length: float, gap_length: float, offset: float) -> void:
	if path.size() < 2:
		return
	var cycle := dash_length + gap_length
	var cursor := -fposmod(offset, cycle)
	for index in path.size() - 1:
		var start := path[index]
		var finish := path[index + 1]
		var length := start.distance_to(finish)
		if length <= 0.001:
			continue
		var direction := (finish - start) / length
		while cursor < length:
			var dash_start := maxf(0.0, cursor)
			var dash_end := minf(length, cursor + dash_length)
			if dash_end > dash_start:
				draw_line(start + direction * dash_start, start + direction * dash_end, color, width, true)
			cursor += cycle
		cursor -= length


func _sample_path(path: PackedVector2Array, progress: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	var total := 0.0
	for index in path.size() - 1:
		total += path[index].distance_to(path[index + 1])
	if total <= 0.001:
		return path[0]
	var target := clampf(progress, 0.0, 1.0) * total
	for index in path.size() - 1:
		var segment := path[index].distance_to(path[index + 1])
		if target <= segment:
			return path[index].lerp(path[index + 1], target / maxf(segment, 0.001))
		target -= segment
	return path[path.size() - 1]


func _world_to_screen(world_path: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(world_path.size())
	for index in world_path.size():
		result[index] = world_path[index] * _graph.zoom - _graph.scroll_offset
	return result
