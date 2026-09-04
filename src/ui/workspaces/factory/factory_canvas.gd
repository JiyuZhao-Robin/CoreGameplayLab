class_name FactoryWorkspaceCanvas
extends Control

## Local, draw-batched factory canvas. It is intentionally ignorant of Game and
## exposes selection/tile gestures only; FactoryWorkspace translates them into
## versioned application intents.

signal entity_selected(entity: Dictionary)
signal resource_field_selected(field: Dictionary)
signal link_selected(link: Dictionary)
signal tile_selected(tile: Vector2i)

const ViewModelScript = preload("res://src/ui/view_models/factory/factory_workspace_view_model.gd")
const CANVAS_COLOR := Color("0b100e")
const GRID_COLOR := Color("3c4743")
const NODE_COLOR := Color("131917")
const HEADER_COLOR := Color("171e1b")
const FOCUS_COLOR := Color("62b5ae")
const CARGO_COLOR := Color("d5a45c")
const POWER_COLOR := Color("62b5ae")

var _view_model := ViewModelScript.new()
var _snapshot: Dictionary = {}
var _camera := Vector2(0.0, 0.0)
var _zoom := 1.0
var _reduced_motion := false
var _visual_phase := 0.0
var _selected_node_id := ""
var _selected_link_id := ""
var _dragging := false
var _last_pointer := Vector2.ZERO
var _node_rects := {}
var _link_hit_rects := {}


func _ready() -> void:
	name = "FactoryCanvas"
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(360, 300)
	gui_input.connect(_on_gui_input)


func apply_snapshot(snapshot: Dictionary) -> void:
	_snapshot = _view_model.build(snapshot)
	_selected_node_id = "" if not _has_node(_selected_node_id) else _selected_node_id
	_selected_link_id = "" if not _has_link(_selected_link_id) else _selected_link_id
	queue_redraw()


func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled
	queue_redraw()


func selected_node_id() -> String:
	return _selected_node_id


func selected_link_id() -> String:
	return _selected_link_id


func focus_tile(tile: Vector2i) -> void:
	var tile_position := _world_to_screen(Vector2(tile))
	_camera += size * 0.5 - tile_position
	queue_redraw()


func _process(delta: float) -> void:
	if not _reduced_motion and visible and _has_active_flow():
		_visual_phase = fmod(_visual_phase + delta, 120.0)
		queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), CANVAS_COLOR)
	if _snapshot.is_empty() or not bool(_snapshot.get("valid", true)):
		_draw_empty()
		return
	_draw_grid()
	_node_rects.clear()
	_link_hit_rects.clear()
	_draw_links()
	_draw_resource_fields()
	_draw_entities()
	_draw_construction_orders()


func _draw_empty() -> void:
	var font := get_theme_default_font()
	draw_string(font, Vector2(20, 34), "Factory telemetry unavailable", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("9aa6a1"))


func _draw_grid() -> void:
	var spacing := clampf(20.0 * _zoom, 10.0, 48.0)
	var start_x := fposmod(_camera.x, spacing)
	var start_y := fposmod(_camera.y, spacing)
	for x in range(int(start_x), int(size.x) + 1, int(spacing)):
		for y in range(int(start_y), int(size.y) + 1, int(spacing)):
			draw_circle(Vector2(x, y), 1.0, Color(GRID_COLOR, 0.43))


func _draw_resource_fields() -> void:
	for field_value in _snapshot.get("resource_fields", []):
		var field := field_value as Dictionary
		var rect := _footprint_rect(field.get("footprint", {}), 1.0)
		_node_rects[str(field.get("id", ""))] = {"rect":rect, "data":field, "is_entity":false}
		var color := _parse_color(str(field.get("resource_color", "#86936D")), Color("86936d"))
		var selected := _selected_node_id == str(field.get("id", ""))
		draw_rect(rect, Color(color, 0.18), true)
		draw_rect(rect, FOCUS_COLOR if selected else Color(color, 0.72), false, 1.4)
		var font := get_theme_default_font()
		var label := "%s  ×%.2f" % [str(field.get("resource_id", "RESOURCE")).to_upper(), float(field.get("grade", 1.0))]
		draw_string(font, rect.position + Vector2(5, 15), label, HORIZONTAL_ALIGNMENT_LEFT, maxf(0.0, rect.size.x - 8.0), 10, Color("d5ddd8"))


func _draw_entities() -> void:
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		var rect := _footprint_rect(entity.get("footprint", {}), 4.0)
		_node_rects[str(entity.get("id", ""))] = {"rect":rect, "data":entity, "is_entity":true}
		var status := str(entity.get("status", "IDLE"))
		var tone := _status_color(status)
		var selected := _selected_node_id == str(entity.get("id", ""))
		draw_style_box(_node_style(tone, selected), rect)
		var header_rect := Rect2(rect.position, Vector2(rect.size.x, minf(22.0, rect.size.y)))
		draw_rect(header_rect, HEADER_COLOR, true)
		draw_circle(header_rect.position + Vector2(9, 11), 3.0, tone)
		var font := get_theme_default_font()
		var kind := str(entity.get("node_kind", "UNIT")).replace("_", " ")
		draw_string(font, header_rect.position + Vector2(16, 14), kind, HORIZONTAL_ALIGNMENT_LEFT, header_rect.size.x - 18, 9, Color("a5b2ac"))
		draw_string(font, rect.position + Vector2(8, minf(39.0, rect.size.y - 8.0)), str(entity.get("name", entity.get("id", "Unit"))), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 11, Color("e6eeea"))
		var progress := clampf(float(entity.get("progress", 0.0)), 0.0, 1.0)
		var bar := Rect2(rect.position + Vector2(8, maxf(45.0, rect.size.y - 14.0)), Vector2(maxf(0.0, rect.size.x - 16.0), 4.0))
		if bar.position.y + bar.size.y <= rect.end.y - 4.0:
			draw_rect(bar, Color("26302c"), true)
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * (float(entity.get("power_factor", 1.0)) if progress <= 0.0 else progress), bar.size.y)), tone, true)
			var rate := "%.2f/s" % float(entity.get("actual_rate", 0.0))
			draw_string(font, rect.position + Vector2(8, bar.position.y - rect.position.y - 4.0), rate, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 9, Color("9aa6a1"))


func _draw_construction_orders() -> void:
	for order_value in _snapshot.get("construction_orders", []):
		var order := order_value as Dictionary
		var rect := _footprint_rect(order.get("footprint", {}), 4.0)
		var tone := _status_color(str(order.get("status", "WAITING_MATERIALS")))
		draw_dashed_line(rect.position, Vector2(rect.end.x, rect.position.y), tone, 1.0, 4.0)
		draw_dashed_line(Vector2(rect.end.x, rect.position.y), rect.end, tone, 1.0, 4.0)
		draw_dashed_line(rect.end, Vector2(rect.position.x, rect.end.y), tone, 1.0, 4.0)
		draw_dashed_line(Vector2(rect.position.x, rect.end.y), rect.position, tone, 1.0, 4.0)
		var font := get_theme_default_font()
		draw_string(font, rect.position + Vector2(5, 14), "BUILD %d%%" % roundi(float(order.get("progress", 0.0)) * 100.0), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 8, 9, tone)


func _draw_links() -> void:
	var entities := {}
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		entities[str(entity.get("id", ""))] = entity
	for link_value in _snapshot.get("links", []):
		var link := link_value as Dictionary
		var source: Dictionary = entities.get(str(link.get("source_id", "")), {})
		var target: Dictionary = entities.get(str(link.get("target_id", "")), {})
		if source.is_empty() or target.is_empty():
			continue
		var from := _footprint_rect(source.get("footprint", {}), 4.0).get_center()
		var to := _footprint_rect(target.get("footprint", {}), 4.0).get_center()
		var kind := str(link.get("kind", "CARGO"))
		var color := POWER_COLOR if kind == "POWER" else CARGO_COLOR
		var selected := _selected_link_id == str(link.get("id", ""))
		var status := str(link.get("status", "IDLE"))
		if status in ["SOURCE_EMPTY", "TARGET_FULL", "BLOCKED"]:
			color = Color("d86e63")
		var width := 1.6 + clampf(float(link.get("utilization", 0.0)), 0.0, 1.0) * 2.0
		if selected:
			color = FOCUS_COLOR
			width += 1.5
		draw_line(from, to, color, width, true)
		_draw_link_arrow(from, to, color)
		var hit := Rect2(from, Vector2.ZERO).expand(to).grow(7.0)
		_link_hit_rects[str(link.get("id", ""))] = hit
		if float(link.get("last_flow", 0.0)) > 0.00001 and not _reduced_motion and status not in ["BLOCKED", "SOURCE_EMPTY", "TARGET_FULL"]:
			var packet_position := from.lerp(to, fposmod(_visual_phase * 0.62 + float(str(link.get("id", "")).hash() % 13) / 13.0, 1.0))
			draw_circle(packet_position, 2.4, Color("f4e7c5") if kind == "CARGO" else Color("d5fffa"))


func _draw_link_arrow(from: Vector2, to: Vector2, color: Color) -> void:
	var direction := (to - from).normalized()
	if direction.is_zero_approx():
		return
	var center := from.lerp(to, 0.54)
	var side := Vector2(-direction.y, direction.x)
	var triangle := PackedVector2Array([center + direction * 6.0, center - direction * 4.0 + side * 3.0, center - direction * 4.0 - side * 3.0])
	draw_colored_polygon(triangle, color)


func _footprint_rect(footprint_value: Variant, minimum_tiles: float) -> Rect2:
	var footprint: Dictionary = footprint_value as Dictionary if footprint_value is Dictionary else {}
	var origin := _view_model.footprint_origin(footprint)
	var extent := _view_model.footprint_size(footprint)
	var tile_scale := maxf(2.0, 4.0 * _zoom)
	var rect := Rect2(_world_to_screen(Vector2(origin)), Vector2(extent) * tile_scale)
	var min_size := Vector2(minimum_tiles * tile_scale, minimum_tiles * tile_scale)
	rect.size = rect.size.max(min_size)
	return rect


func _world_to_screen(world: Vector2) -> Vector2:
	return _camera + world * maxf(2.0, 4.0 * _zoom)


func _screen_to_tile(screen: Vector2) -> Vector2i:
	var scale := maxf(2.0, 4.0 * _zoom)
	return Vector2i(floori((screen.x - _camera.x) / scale), floori((screen.y - _camera.y) / scale))


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mouse_event.pressed
			_last_pointer = mouse_event.position
			accept_event()
			return
		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP or mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var before := _screen_to_tile(mouse_event.position)
			_zoom = clampf(_zoom * (1.14 if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.88), 0.35, 2.5)
			_camera = mouse_event.position - Vector2(before) * maxf(2.0, 4.0 * _zoom)
			queue_redraw()
			accept_event()
			return
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			_select_at(mouse_event.position)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		_camera += motion.position - _last_pointer
		_last_pointer = motion.position
		queue_redraw()
		accept_event()


func _select_at(point: Vector2) -> void:
	for link_id_value in _link_hit_rects.keys():
		var link_id := str(link_id_value)
		var hit: Rect2 = _link_hit_rects.get(link_id, Rect2())
		if hit.has_point(point) and _distance_to_link(point, link_id) <= 8.0:
			_selected_link_id = link_id
			_selected_node_id = ""
			link_selected.emit(_link_by_id(link_id))
			queue_redraw()
			return
	var node_ids: Array = _node_rects.keys()
	node_ids.reverse()
	for node_id_value in node_ids:
		var node_id := str(node_id_value)
		var row: Dictionary = _node_rects.get(node_id, {})
		var rect: Rect2 = row.get("rect", Rect2())
		if rect.has_point(point):
			_selected_node_id = node_id
			_selected_link_id = ""
			if bool(row.get("is_entity", false)):
				entity_selected.emit((row.get("data", {}) as Dictionary).duplicate(true))
			else:
				resource_field_selected.emit((row.get("data", {}) as Dictionary).duplicate(true))
			queue_redraw()
			return
	_selected_node_id = ""
	_selected_link_id = ""
	tile_selected.emit(_screen_to_tile(point))
	queue_redraw()


func _distance_to_link(point: Vector2, link_id: String) -> float:
	var link := _link_by_id(link_id)
	var source := _entity_by_id(str(link.get("source_id", "")))
	var target := _entity_by_id(str(link.get("target_id", "")))
	if source.is_empty() or target.is_empty():
		return INF
	var from := _footprint_rect(source.get("footprint", {}), 4.0).get_center()
	var to := _footprint_rect(target.get("footprint", {}), 4.0).get_center()
	return Geometry2D.get_closest_point_to_segment(point, from, to).distance_to(point)


func _node_style(tone: Color, selected: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = NODE_COLOR
	style.border_color = FOCUS_COLOR if selected else Color(tone, 0.85)
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(5)
	return style


func _status_color(status: String) -> Color:
	match status:
		"RUNNING", "FLOWING", "CONNECTED", "READY": return Color("6fbf92")
		"NO_POWER", "INPUT_SHORTAGE", "WAITING_MATERIALS", "SOURCE_EMPTY": return Color("e0ae5c")
		"OUTPUT_FULL", "TARGET_FULL", "BLOCKED", "NO_RESOURCE": return Color("d86e63")
	return Color("7f9289")


func _parse_color(value: String, fallback: Color) -> Color:
	var color := Color(value)
	return fallback if color == Color.TRANSPARENT else color


func _entity_by_id(entity_id: String) -> Dictionary:
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity
	return {}


func _link_by_id(link_id: String) -> Dictionary:
	for link_value in _snapshot.get("links", []):
		var link := link_value as Dictionary
		if str(link.get("id", "")) == link_id:
			return link
	return {}


func _has_node(node_id: String) -> bool:
	return not _entity_by_id(node_id).is_empty() or _resource_by_id(node_id).size() > 0


func _resource_by_id(resource_id: String) -> Dictionary:
	for resource_value in _snapshot.get("resource_fields", []):
		var resource := resource_value as Dictionary
		if str(resource.get("id", "")) == resource_id:
			return resource
	return {}


func _has_link(link_id: String) -> bool:
	return not _link_by_id(link_id).is_empty()


func _has_active_flow() -> bool:
	for link_value in _snapshot.get("links", []):
		if float((link_value as Dictionary).get("last_flow", 0.0)) > 0.00001:
			return true
	return false
