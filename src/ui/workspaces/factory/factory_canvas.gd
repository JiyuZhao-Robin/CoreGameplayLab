class_name FactoryWorkspaceCanvas
extends Control

## Local, draw-batched factory canvas. It is intentionally ignorant of Game and
## exposes selection/tile gestures only; FactoryWorkspace translates them into
## versioned application intents.

signal entity_selected(entity: Dictionary)
signal resource_field_selected(field: Dictionary)
signal link_selected(link: Dictionary)
signal construction_order_selected(order: Dictionary)
signal tile_selected(tile: Vector2i)
signal tile_hovered(tile: Vector2i)
signal placement_cancelled

const ViewModelScript = preload("res://src/ui/view_models/factory/factory_workspace_view_model.gd")
const ChunkIndexScript = preload("res://src/ui/workspaces/factory/factory_canvas_chunk_index.gd")
const CANVAS_COLOR := Color("0b100e")
const WORLD_COLOR := Color("101814")
const WORLD_BOUNDARY_COLOR := Color("62b5ae")
const GRID_COLOR := Color("3c4743")
const NODE_COLOR := Color("131917")
const HEADER_COLOR := Color("171e1b")
const FOCUS_COLOR := Color("62b5ae")
const CARGO_COLOR := Color("d5a45c")
const POWER_COLOR := Color("62b5ae")
const BASE_TILE_PIXELS := 4.0
const MAX_DETAIL_TILE_PIXELS := 10.0
const OVERVIEW_PADDING_PIXELS := 24.0
const FLOW_REDRAW_INTERVAL_SECONDS := 0.05
const DRAW_CULL_MARGIN_PIXELS := 32.0
const MAX_ANIMATED_SNAPSHOT_RECORDS := 512
const MEDIUM_DETAIL_VISIBLE_RECORDS := 160
const COMPACT_DETAIL_VISIBLE_RECORDS := 480
const MEDIUM_DETAIL_EXIT_RECORDS := 128
const COMPACT_DETAIL_EXIT_RECORDS := 400

## Keep the canvas independently loadable by SceneTree-based component tests.
@onready var I18n = get_node("/root/I18n")

var _view_model := ViewModelScript.new()
var _chunk_index := ChunkIndexScript.new()
var _chunk_index_signature := ""
var _snapshot: Dictionary = {}
var _camera := Vector2(0.0, 0.0)
var _zoom := 1.0
var _reduced_motion := false
var _visual_phase := 0.0
var _flow_redraw_elapsed := 0.0
var _overview_mode := true
var _last_canvas_size := Vector2.ZERO
var _selected_node_id := ""
var _selected_link_id := ""
var _dragging := false
var _last_pointer := Vector2.ZERO
var _node_rects := {}
var _link_hit_rects := {}
var _construction_order_rects := {}
var _placement_preview: Dictionary = {}
var _connection_preview := {"source_id":"", "target_id":"", "kind":""}
var _connection_candidate_ids: Dictionary = {}
var _keyboard_tile := Vector2i.ZERO
var _entities_by_id: Dictionary = {}
var _links_by_id: Dictionary = {}
var _resources_by_id: Dictionary = {}
var _orders_by_id: Dictionary = {}
var _visible_records: Dictionary = {}
var _has_active_flow_cache := false
var _visible_active_flow := false
var _node_style_cache: Dictionary = {}
var _hit_geometry_dirty := true
var _detail_stage_cache := "FULL"


func _ready() -> void:
	name = "FactoryCanvas"
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(360, 300)
	gui_input.connect(_on_gui_input)
	resized.connect(_on_canvas_resized)
	_last_canvas_size = size


func apply_snapshot(snapshot: Dictionary, already_normalized: bool = false) -> void:
	var previous_layout_signature := _world_layout_signature()
	_snapshot = snapshot if already_normalized else _view_model.build(snapshot)
	_rebuild_snapshot_indexes()
	var next_chunk_index_signature := _chunk_layout_signature()
	if next_chunk_index_signature != _chunk_index_signature:
		_chunk_index.rebuild(_snapshot)
		_chunk_index_signature = next_chunk_index_signature
	_selected_node_id = "" if not _has_node(_selected_node_id) else _selected_node_id
	_selected_link_id = "" if not _has_link(_selected_link_id) else _selected_link_id
	if previous_layout_signature != _world_layout_signature():
		_overview_mode = true
		_detail_stage_cache = "FULL"
		_keyboard_tile = _bounds_origin()
		_zoom = _overview_zoom()
		_camera = Vector2.ZERO
	else:
		_keyboard_tile = _clamp_tile_to_bounds(_keyboard_tile)
		_zoom = _clamp_zoom(_zoom)
	_clamp_camera_to_bounds()
	_invalidate_hit_geometry()
	queue_redraw()


func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled
	queue_redraw()


func selected_node_id() -> String:
	return _selected_node_id


func selected_link_id() -> String:
	return _selected_link_id


func select_link(link_id: String) -> void:
	_selected_link_id = link_id if _has_link(link_id) else ""
	if not _selected_link_id.is_empty():
		_selected_node_id = ""
	queue_redraw()


func focus_tile(tile: Vector2i) -> void:
	_overview_mode = false
	_keyboard_tile = _clamp_tile_to_bounds(tile)
	var tile_position := _world_to_screen(Vector2(_keyboard_tile))
	_camera += size * 0.5 - tile_position
	_clamp_camera_to_bounds()
	_invalidate_hit_geometry()
	queue_redraw()


func reset_camera() -> void:
	_overview_mode = true
	_camera = Vector2.ZERO
	_zoom = _overview_zoom()
	_keyboard_tile = _bounds_origin()
	_clamp_camera_to_bounds()
	_invalidate_hit_geometry()
	queue_redraw()


## The workspace provides this presentation-only preview after checking its
## immutable snapshot. The canvas never validates or mutates factory state.
func set_placement_preview(preview: Dictionary) -> void:
	_placement_preview = preview.duplicate(true)
	queue_redraw()


func clear_placement_preview() -> void:
	_placement_preview.clear()
	queue_redraw()


func set_connection_preview(source_id: String, target_id: String, kind: String, valid: bool = false, candidate_ids: Array[String] = []) -> void:
	_connection_candidate_ids.clear()
	for candidate_id in candidate_ids:
		_connection_candidate_ids[candidate_id] = true
	_connection_preview = {
		"source_id":source_id,
		"target_id":target_id,
		"kind":kind.to_upper(),
		"valid":valid,
		"candidate_ids":candidate_ids.duplicate()
	}
	queue_redraw()


func _process(delta: float) -> void:
	if not _reduced_motion and visible and _visible_active_flow:
		_flow_redraw_elapsed += delta
		if _flow_redraw_elapsed >= FLOW_REDRAW_INTERVAL_SECONDS:
			_visual_phase = fmod(_visual_phase + _flow_redraw_elapsed, 120.0)
			_flow_redraw_elapsed = fmod(_flow_redraw_elapsed, FLOW_REDRAW_INTERVAL_SECONDS)
			queue_redraw()
	else:
		_flow_redraw_elapsed = 0.0


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), CANVAS_COLOR)
	_visible_active_flow = false
	if _snapshot.is_empty() or not bool(_snapshot.get("valid", true)):
		_visible_records.clear()
		_invalidate_hit_geometry()
		_hit_geometry_dirty = false
		_draw_empty()
		return
	var world_rect := _world_screen_rect()
	_visible_records = _chunk_index.query(_visible_world_query_rect())
	draw_rect(world_rect, WORLD_COLOR, true)
	_draw_grid()
	_draw_chunk_boundaries()
	_node_rects.clear()
	_link_hit_rects.clear()
	_construction_order_rects.clear()
	_draw_placement_preview()
	_draw_links()
	_draw_connection_preview()
	_draw_resource_fields()
	_draw_entities()
	_draw_construction_orders()
	draw_rect(world_rect, WORLD_BOUNDARY_COLOR, false, 2.0)
	_hit_geometry_dirty = false


func _draw_empty() -> void:
	var font := get_theme_default_font()
	draw_string(font, Vector2(20, 34), I18n.t("factory.canvas.unavailable"), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("9aa6a1"))


func _draw_grid() -> void:
	var tile_scale := _tile_scale()
	var step_tiles := 1
	while float(step_tiles) * tile_scale < 24.0:
		step_tiles *= 2
	var spacing := float(step_tiles) * tile_scale
	var visible_world := _world_screen_rect().intersection(Rect2(Vector2.ZERO, size))
	if not visible_world.has_area():
		return
	var world_start := _world_to_screen(Vector2(_bounds_origin()))
	var start_x := visible_world.position.x + fposmod(world_start.x - visible_world.position.x, spacing)
	var start_y := visible_world.position.y + fposmod(world_start.y - visible_world.position.y, spacing)
	var x := start_x
	while x <= visible_world.end.x:
		draw_line(Vector2(x, visible_world.position.y), Vector2(x, visible_world.end.y), Color(GRID_COLOR, 0.32), 1.0)
		x += spacing
	var y := start_y
	while y <= visible_world.end.y:
		draw_line(Vector2(visible_world.position.x, y), Vector2(visible_world.end.x, y), Color(GRID_COLOR, 0.32), 1.0)
		y += spacing


func _draw_chunk_boundaries() -> void:
	var visible_world := _visible_world_query_rect().intersection(Rect2(Vector2(_bounds_origin()), Vector2(_bounds_size())))
	if not visible_world.has_area():
		return
	var chunk_size := maxi(1, _chunk_index.chunk_size_tiles())
	var origin := _bounds_origin()
	var first_chunk_x := floori((visible_world.position.x - float(origin.x)) / float(chunk_size))
	var last_chunk_x := floori((visible_world.end.x - 0.0001 - float(origin.x)) / float(chunk_size))
	var first_chunk_y := floori((visible_world.position.y - float(origin.y)) / float(chunk_size))
	var last_chunk_y := floori((visible_world.end.y - 0.0001 - float(origin.y)) / float(chunk_size))
	var screen_world := _world_screen_rect().intersection(Rect2(Vector2.ZERO, size))
	for boundary_offset in _chunk_boundary_offsets(_bounds_size().x, first_chunk_x, last_chunk_x, chunk_size):
		var x := _world_to_screen(Vector2(origin.x + boundary_offset, 0)).x
		draw_line(Vector2(x, screen_world.position.y), Vector2(x, screen_world.end.y), Color(WORLD_BOUNDARY_COLOR, 0.26), 1.0)
	for boundary_offset in _chunk_boundary_offsets(_bounds_size().y, first_chunk_y, last_chunk_y, chunk_size):
		var y := _world_to_screen(Vector2(0, origin.y + boundary_offset)).y
		draw_line(Vector2(screen_world.position.x, y), Vector2(screen_world.end.x, y), Color(WORLD_BOUNDARY_COLOR, 0.26), 1.0)


func _chunk_boundary_offsets(extent: int, first_chunk: int, last_chunk: int, chunk_size: int) -> Array[int]:
	var result: Array[int] = []
	var chunk_count := ceili(float(maxi(0, extent)) / float(maxi(1, chunk_size)))
	var first_boundary := maxi(1, first_chunk)
	var last_boundary := mini(chunk_count - 1, last_chunk + 1)
	for boundary_index in range(first_boundary, last_boundary + 1):
		result.append(boundary_index * chunk_size)
	return result


func _draw_resource_fields() -> void:
	var visible_rect := _visible_draw_rect()
	var detail_stage := _detail_stage()
	for field_id_value in _visible_records.get("resource_ids", []):
		var field: Dictionary = _resources_by_id.get(str(field_id_value), {})
		if field.is_empty():
			continue
		var rect := _footprint_rect(field.get("footprint", {}), 1.0)
		if not rect.intersects(visible_rect):
			continue
		_node_rects[str(field.get("id", ""))] = {"rect":rect, "data":field, "is_entity":false}
		var color := _parse_color(str(field.get("resource_color", "#86936D")), Color("86936d"))
		var selected := _selected_node_id == str(field.get("id", ""))
		draw_rect(rect, Color(color, 0.18), true)
		draw_rect(rect, FOCUS_COLOR if selected else Color(color, 0.72), false, 1.4)
		var font := get_theme_default_font()
		var resource_id := str(field.get("resource_id", ""))
		if detail_stage != "COMPACT" and rect.size.x >= 48.0 and rect.size.y >= 18.0:
			var label := str(field.get("resource_name", _item_name(resource_id))) + " ×" + ("%.2f" % float(field.get("grade", 1.0)))
			draw_string(font, rect.position + Vector2(5, 15), label, HORIZONTAL_ALIGNMENT_LEFT, maxf(0.0, rect.size.x - 8.0), 10, Color("d5ddd8"))


func _draw_entities() -> void:
	var visible_rect := _visible_draw_rect()
	var detail_stage := _detail_stage()
	for entity_id_value in _visible_records.get("entity_ids", []):
		var entity: Dictionary = _entities_by_id.get(str(entity_id_value), {})
		if entity.is_empty():
			continue
		var rect := _footprint_rect(entity.get("footprint", {}), 4.0)
		if not rect.intersects(visible_rect):
			continue
		_node_rects[str(entity.get("id", ""))] = {"rect":rect, "data":entity, "is_entity":true}
		var status := str(entity.get("status", "IDLE"))
		var tone := _status_color(status)
		var selected := _selected_node_id == str(entity.get("id", ""))
		draw_style_box(_node_style(tone, selected), rect)
		_draw_connection_ports(entity, rect, detail_stage)
		if detail_stage == "COMPACT" or rect.size.x < 48.0 or rect.size.y < 34.0:
			draw_circle(rect.get_center(), minf(3.0, minf(rect.size.x, rect.size.y) * 0.25), tone)
			continue
		var header_rect := Rect2(rect.position, Vector2(rect.size.x, minf(22.0, rect.size.y)))
		draw_rect(header_rect, HEADER_COLOR, true)
		draw_circle(header_rect.position + Vector2(9, 11), 3.0, tone)
		var font := get_theme_default_font()
		var kind_id := str(entity.get("node_kind", "UNIT"))
		var kind: String = str(I18n.t("factory.kind.%s" % kind_id.to_lower()))
		draw_string(font, header_rect.position + Vector2(16, 14), kind, HORIZONTAL_ALIGNMENT_LEFT, header_rect.size.x - 18, 9, Color("a5b2ac"))
		draw_string(font, rect.position + Vector2(8, minf(39.0, rect.size.y - 8.0)), str(entity.get("name", entity.get("id", "Unit"))), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 11, Color("e6eeea"))
		if detail_stage == "MEDIUM":
			continue
		var progress := clampf(float(entity.get("progress", 0.0)), 0.0, 1.0)
		var bar := Rect2(rect.position + Vector2(8, maxf(45.0, rect.size.y - 14.0)), Vector2(maxf(0.0, rect.size.x - 16.0), 4.0))
		if bar.position.y + bar.size.y <= rect.end.y - 4.0:
			draw_rect(bar, Color("26302c"), true)
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * (float(entity.get("power_factor", 1.0)) if progress <= 0.0 else progress), bar.size.y)), tone, true)
			var rate := "%.2f/s" % float(entity.get("actual_rate", 0.0))
			draw_string(font, rect.position + Vector2(8, bar.position.y - rect.position.y - 4.0), rate, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 9, Color("9aa6a1"))


func _draw_construction_orders() -> void:
	var visible_rect := _visible_draw_rect()
	for order_id_value in _visible_records.get("order_ids", []):
		var order: Dictionary = _orders_by_id.get(str(order_id_value), {})
		if order.is_empty():
			continue
		var rect := _footprint_rect(order.get("footprint", {}), 4.0)
		if not rect.intersects(visible_rect):
			continue
		_construction_order_rects[str(order.get("id", ""))] = {"rect":rect, "data":order}
		var tone := _status_color(str(order.get("status", "WAITING_MATERIALS")))
		if rect.size.x < 40.0 or rect.size.y < 18.0:
			draw_rect(rect, tone, false, 1.0)
			continue
		draw_dashed_line(rect.position, Vector2(rect.end.x, rect.position.y), tone, 1.0, 4.0)
		draw_dashed_line(Vector2(rect.end.x, rect.position.y), rect.end, tone, 1.0, 4.0)
		draw_dashed_line(rect.end, Vector2(rect.position.x, rect.end.y), tone, 1.0, 4.0)
		draw_dashed_line(Vector2(rect.position.x, rect.end.y), rect.position, tone, 1.0, 4.0)
		var font := get_theme_default_font()
		draw_string(font, rect.position + Vector2(5, 14), I18n.t("factory.canvas.build_progress") % roundi(float(order.get("progress", 0.0)) * 100.0), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 8, 9, tone)


func _draw_placement_preview() -> void:
	if _placement_preview.is_empty():
		return
	var footprint_value: Variant = _placement_preview.get("footprint", {})
	if not footprint_value is Dictionary:
		return
	var rect := _footprint_rect(footprint_value, 2.0)
	var is_valid := bool(_placement_preview.get("valid", false))
	var tone := Color("6fbf92") if is_valid else Color("d86e63")
	draw_rect(rect, Color(tone, 0.20), true)
	draw_dashed_line(rect.position, Vector2(rect.end.x, rect.position.y), tone, 2.0, 5.0)
	draw_dashed_line(Vector2(rect.end.x, rect.position.y), rect.end, tone, 2.0, 5.0)
	draw_dashed_line(rect.end, Vector2(rect.position.x, rect.end.y), tone, 2.0, 5.0)
	draw_dashed_line(Vector2(rect.position.x, rect.end.y), rect.position, tone, 2.0, 5.0)
	var status := _status_name("READY") if is_valid else _placement_reason_name(str(_placement_preview.get("reason_code", "BLOCKED")))
	draw_string(get_theme_default_font(), rect.position + Vector2(4, -4), status, HORIZONTAL_ALIGNMENT_LEFT, 160, 10, tone)


func _draw_connection_preview() -> void:
	var source_id := str(_connection_preview.get("source_id", ""))
	var target_id := str(_connection_preview.get("target_id", ""))
	if source_id.is_empty() or target_id.is_empty() or source_id == target_id:
		return
	var source := _entity_by_id(source_id)
	var target := _entity_by_id(target_id)
	if source.is_empty() or target.is_empty():
		return
	var endpoints := _connection_endpoints(source, target, str(_connection_preview.get("kind", "CARGO")))
	var from: Vector2 = endpoints[0]
	var to: Vector2 = endpoints[1]
	if not Rect2(from, Vector2.ZERO).expand(to).grow(DRAW_CULL_MARGIN_PIXELS).intersects(_visible_draw_rect()):
		return
	var kind := str(_connection_preview.get("kind", "CARGO"))
	var tone := Color("6fbf92") if bool(_connection_preview.get("valid", false)) else Color("d86e63")
	draw_dashed_line(from, to, tone, 2.0, 5.0)
	_draw_link_arrow(from, to, tone)


func _draw_links() -> void:
	var flow_animation_allowed := _flow_animation_allowed()
	for link_id_value in _visible_records.get("link_ids", []):
		var link: Dictionary = _links_by_id.get(str(link_id_value), {})
		if link.is_empty():
			continue
		var source: Dictionary = _entities_by_id.get(str(link.get("source_id", "")), {})
		var target: Dictionary = _entities_by_id.get(str(link.get("target_id", "")), {})
		if source.is_empty() or target.is_empty():
			continue
		var endpoints := _connection_endpoints(source, target, str(link.get("kind", "CARGO")))
		var from: Vector2 = endpoints[0]
		var to: Vector2 = endpoints[1]
		var hit := Rect2(from, Vector2.ZERO).expand(to).grow(7.0)
		if not hit.intersects(_visible_draw_rect()):
			continue
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
		var shows_detail := _tile_scale() >= 0.75
		if shows_detail:
			_draw_link_arrow(from, to, color)
		_link_hit_rects[str(link.get("id", ""))] = hit
		if flow_animation_allowed and float(link.get("last_flow", 0.0)) > 0.00001 and not _reduced_motion and status not in ["BLOCKED", "SOURCE_EMPTY", "TARGET_FULL"]:
			_visible_active_flow = true
			var packet_position := from.lerp(to, fposmod(_visual_phase * 0.62 + float(str(link.get("id", "")).hash() % 13) / 13.0, 1.0))
			draw_circle(packet_position, 2.4, Color("f4e7c5") if kind == "CARGO" else Color("d5fffa"))


func _draw_connection_ports(entity: Dictionary, rect: Rect2, detail_stage: String) -> void:
	var entity_id := str(entity.get("id", ""))
	var is_source := entity_id == str(_connection_preview.get("source_id", ""))
	var is_target := entity_id == str(_connection_preview.get("target_id", ""))
	var is_candidate := _connection_candidate_ids.has(entity_id)
	if is_source or is_target:
		draw_rect(rect.grow(3.0), Color("d5a45c") if is_source else Color("62b5ae"), false, 2.0)
	elif is_candidate:
		# Candidate means structurally compatible. The selected route turns green
		# only after duplicate/input-occupancy preflight also passes.
		draw_rect(rect.grow(2.0), Color(FOCUS_COLOR, 0.72), false, 1.5)
	if detail_stage == "COMPACT":
		return
	var ports: Dictionary = entity.get("ports", {}) if entity.get("ports", {}) is Dictionary else {}
	var radius := 4.0 if detail_stage == "FULL" else 3.0
	if not (ports.get("inputs", []) as Array).is_empty():
		draw_circle(Vector2(rect.position.x, rect.get_center().y), radius, CARGO_COLOR)
	if not (ports.get("outputs", []) as Array).is_empty():
		draw_circle(Vector2(rect.end.x, rect.get_center().y), radius, CARGO_COLOR)
	if bool(ports.get("accepts_power", false)):
		draw_circle(Vector2(rect.get_center().x, rect.position.y), radius, POWER_COLOR)
	if bool(ports.get("provides_power", false)):
		draw_circle(Vector2(rect.get_center().x, rect.end.y), radius, POWER_COLOR)


func _draw_link_arrow(from: Vector2, to: Vector2, color: Color) -> void:
	var direction := (to - from).normalized()
	if direction.is_zero_approx():
		return
	var center := from.lerp(to, 0.54)
	var side := Vector2(-direction.y, direction.x)
	var triangle := PackedVector2Array([center + direction * 6.0, center - direction * 4.0 + side * 3.0, center - direction * 4.0 - side * 3.0])
	draw_colored_polygon(triangle, color)


func _connection_endpoints(source: Dictionary, target: Dictionary, kind: String) -> Array[Vector2]:
	var source_rect := _footprint_rect(source.get("footprint", {}), 4.0)
	var target_rect := _footprint_rect(target.get("footprint", {}), 4.0)
	if kind == "POWER":
		return [Vector2(source_rect.get_center().x, source_rect.end.y), Vector2(target_rect.get_center().x, target_rect.position.y)]
	return [Vector2(source_rect.end.x, source_rect.get_center().y), Vector2(target_rect.position.x, target_rect.get_center().y)]


func _footprint_rect(footprint_value: Variant, minimum_tiles: float) -> Rect2:
	var footprint: Dictionary = footprint_value as Dictionary if footprint_value is Dictionary else {}
	var origin := _view_model.footprint_origin(footprint)
	var extent := _view_model.footprint_size(footprint)
	var tile_scale := _tile_scale()
	var rect := Rect2(_world_to_screen(Vector2(origin)), Vector2(extent) * tile_scale)
	var min_size := Vector2(minimum_tiles * tile_scale, minimum_tiles * tile_scale)
	rect.size = rect.size.max(min_size)
	return rect


func _world_to_screen(world: Vector2) -> Vector2:
	return _camera + world * _tile_scale()


func _screen_to_tile(screen: Vector2) -> Vector2i:
	var world := _screen_to_world(screen)
	return Vector2i(floori(world.x), floori(world.y))


func _screen_to_world(screen: Vector2) -> Vector2:
	return (screen - _camera) / _tile_scale()


func _bounds_origin() -> Vector2i:
	var bounds: Dictionary = _snapshot.get("bounds", {})
	var origin: Dictionary = bounds.get("origin", {})
	return Vector2i(int(origin.get("x", 0)), int(origin.get("y", 0)))


func _bounds_size() -> Vector2i:
	var bounds: Dictionary = _snapshot.get("bounds", {})
	var bounds_size: Dictionary = bounds.get("size", {})
	return Vector2i(maxi(0, int(bounds_size.get("x", 0))), maxi(0, int(bounds_size.get("y", 0))))


func _world_screen_rect() -> Rect2:
	var tile_scale := _tile_scale()
	return Rect2(_world_to_screen(Vector2(_bounds_origin())), Vector2(_bounds_size()) * tile_scale)


func _tile_scale() -> float:
	return maxf(0.000001, BASE_TILE_PIXELS * _zoom)


func _visible_draw_rect() -> Rect2:
	return Rect2(Vector2.ZERO, size).grow(DRAW_CULL_MARGIN_PIXELS)


func _visible_world_query_rect() -> Rect2:
	var screen_rect := _visible_draw_rect()
	var first := _screen_to_world(screen_rect.position)
	var last := _screen_to_world(screen_rect.end)
	return Rect2(first.min(last), (last - first).abs())


func _world_layout_signature() -> String:
	if _snapshot.is_empty() or not bool(_snapshot.get("valid", true)):
		return ""
	var origin := _bounds_origin()
	var bounds_size := _bounds_size()
	var maximum_size := _maximum_canvas_size()
	return "%s:%d,%d:%d,%d:%d,%d" % [str(_snapshot.get("world_id", "")), origin.x, origin.y, bounds_size.x, bounds_size.y, maximum_size.x, maximum_size.y]


func _chunk_layout_signature() -> String:
	if _snapshot.is_empty() or not bool(_snapshot.get("valid", true)):
		return ""
	var origin := _bounds_origin()
	var bounds_size := _bounds_size()
	return "%s:%d:%d:%d,%d:%d,%d" % [
		str(_snapshot.get("world_id", "")),
		int(_snapshot.get("topology_revision", 0)),
		int(_snapshot.get("chunk_size_tiles", 64)),
		origin.x,
		origin.y,
		bounds_size.x,
		bounds_size.y
	]


func _maximum_canvas_size() -> Vector2i:
	var limits: Dictionary = _snapshot.get("canvas_limits", {}) if _snapshot.get("canvas_limits", {}) is Dictionary else {}
	var authored_value: Variant = limits.get("max_world_size_tiles", {})
	var authored: Dictionary = authored_value as Dictionary if authored_value is Dictionary else {}
	return Vector2i(
		maxi(_bounds_size().x, int(authored.get("x", 0))),
		maxi(_bounds_size().y, int(authored.get("y", 0)))
	)


func _overview_zoom() -> float:
	var reference_size := _maximum_canvas_size()
	if reference_size.x <= 0 or reference_size.y <= 0 or size.x <= 0.0 or size.y <= 0.0:
		return 1.0
	var available := (size - Vector2.ONE * OVERVIEW_PADDING_PIXELS * 2.0).max(Vector2.ONE)
	var fitted_zoom := minf(
		available.x / (float(reference_size.x) * BASE_TILE_PIXELS),
		available.y / (float(reference_size.y) * BASE_TILE_PIXELS)
	)
	return maxf(0.000001, minf(fitted_zoom, MAX_DETAIL_TILE_PIXELS / BASE_TILE_PIXELS))


func _maximum_zoom() -> float:
	# The planet may be wider than the viewport at detail zoom. Spatial chunk
	# culling, rather than shrinking the whole world, bounds the draw workload.
	return maxf(_overview_zoom(), MAX_DETAIL_TILE_PIXELS / BASE_TILE_PIXELS)


func _clamp_zoom(value: float) -> float:
	return clampf(value, _overview_zoom(), _maximum_zoom())


func _tile_in_bounds(tile: Vector2i) -> bool:
	var origin := _bounds_origin()
	var bounds_size := _bounds_size()
	return bounds_size.x > 0 and bounds_size.y > 0 and tile.x >= origin.x and tile.y >= origin.y and tile.x < origin.x + bounds_size.x and tile.y < origin.y + bounds_size.y


func _clamp_tile_to_bounds(tile: Vector2i) -> Vector2i:
	var origin := _bounds_origin()
	var bounds_size := _bounds_size()
	if bounds_size.x <= 0 or bounds_size.y <= 0:
		return tile
	return Vector2i(
		clampi(tile.x, origin.x, origin.x + bounds_size.x - 1),
		clampi(tile.y, origin.y, origin.y + bounds_size.y - 1)
	)


func _clamp_camera_to_bounds() -> void:
	var bounds_size := _bounds_size()
	if bounds_size.x <= 0 or bounds_size.y <= 0 or size.x <= 0.0 or size.y <= 0.0:
		return
	var tile_scale := _tile_scale()
	var world_origin_pixels := Vector2(_bounds_origin()) * tile_scale
	var world_size_pixels := Vector2(bounds_size) * tile_scale
	if world_size_pixels.x <= size.x:
		_camera.x = (size.x - world_size_pixels.x) * 0.5 - world_origin_pixels.x
	else:
		_camera.x = clampf(_camera.x, size.x - world_origin_pixels.x - world_size_pixels.x, -world_origin_pixels.x)
	if world_size_pixels.y <= size.y:
		_camera.y = (size.y - world_size_pixels.y) * 0.5 - world_origin_pixels.y
	else:
		_camera.y = clampf(_camera.y, size.y - world_origin_pixels.y - world_size_pixels.y, -world_origin_pixels.y)


func _on_canvas_resized() -> void:
	var previous_size := _last_canvas_size
	var previous_center_world := _screen_to_world(previous_size * 0.5) if previous_size.x > 0.0 and previous_size.y > 0.0 else Vector2(_bounds_origin())
	if _overview_mode:
		_zoom = _overview_zoom()
		_camera = Vector2.ZERO
	else:
		_zoom = _clamp_zoom(_zoom)
		_camera = size * 0.5 - previous_center_world * _tile_scale()
	_clamp_camera_to_bounds()
	_last_canvas_size = size
	_invalidate_hit_geometry()
	queue_redraw()


func _on_gui_input(event: InputEvent) -> void:
	var connection_active := not str(_connection_preview.get("kind", "")).is_empty()
	if _is_placement_cancel_event(event) and (not _placement_preview.is_empty() or connection_active):
		placement_cancelled.emit()
		accept_event()
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mouse_event.pressed
			_last_pointer = mouse_event.position
			if mouse_event.pressed:
				_overview_mode = false
			accept_event()
			return
		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP or mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom_around(mouse_event.position, _screen_to_world(mouse_event.position), _zoom * (1.14 if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.88))
			accept_event()
			return
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			_select_at(mouse_event.position)
			accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging:
			_camera += motion.position - _last_pointer
			_last_pointer = motion.position
			_clamp_camera_to_bounds()
			_invalidate_hit_geometry()
			queue_redraw()
			accept_event()
			return
		var hovered_tile := _screen_to_tile(motion.position)
		if _tile_in_bounds(hovered_tile) and hovered_tile != _keyboard_tile:
			_keyboard_tile = hovered_tile
			tile_hovered.emit(_keyboard_tile)
	elif event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return
		var handled := true
		match key_event.keycode:
			KEY_LEFT:
				_move_keyboard_tile(Vector2i.LEFT)
			KEY_RIGHT:
				_move_keyboard_tile(Vector2i.RIGHT)
			KEY_UP:
				_move_keyboard_tile(Vector2i.UP)
			KEY_DOWN:
				_move_keyboard_tile(Vector2i.DOWN)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				if _tile_in_bounds(_keyboard_tile):
					tile_selected.emit(_keyboard_tile)
			KEY_PLUS, KEY_EQUAL:
				_adjust_zoom(1.14)
			KEY_MINUS:
				_adjust_zoom(0.88)
			KEY_HOME:
				reset_camera()
			_:
				handled = false
		if handled:
			accept_event()


func _is_placement_cancel_event(event: InputEvent) -> bool:
	if event.is_action_pressed("ui_cancel"):
		return true
	if event is InputEventKey:
		var key_event := event as InputEventKey
		return key_event.pressed and not key_event.echo and key_event.keycode == KEY_ESCAPE
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		return mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_RIGHT
	return false


func _move_keyboard_tile(offset: Vector2i) -> void:
	_keyboard_tile = _clamp_tile_to_bounds(_keyboard_tile + offset)
	focus_tile(_keyboard_tile)
	tile_hovered.emit(_keyboard_tile)


func _adjust_zoom(multiplier: float) -> void:
	_set_zoom_around(size * 0.5, Vector2(_keyboard_tile), _zoom * multiplier)


func _set_zoom_around(screen_anchor: Vector2, world_anchor: Vector2, requested_zoom: float) -> void:
	_overview_mode = false
	_zoom = _clamp_zoom(requested_zoom)
	_camera = screen_anchor - world_anchor * _tile_scale()
	_clamp_camera_to_bounds()
	_invalidate_hit_geometry()
	queue_redraw()


func _invalidate_hit_geometry() -> void:
	_node_rects.clear()
	_link_hit_rects.clear()
	_construction_order_rects.clear()
	_hit_geometry_dirty = true


func _ensure_hit_geometry() -> void:
	if not _hit_geometry_dirty:
		return
	_node_rects.clear()
	_link_hit_rects.clear()
	_construction_order_rects.clear()
	var visible_rect := _visible_draw_rect()
	var visible_records := _chunk_index.query(_visible_world_query_rect())
	for resource_id_value in visible_records.get("resource_ids", []):
		var resource: Dictionary = _resources_by_id.get(str(resource_id_value), {})
		var resource_rect := _footprint_rect(resource.get("footprint", {}), 1.0)
		if resource_rect.intersects(visible_rect):
			_node_rects[str(resource.get("id", ""))] = {"rect":resource_rect, "data":resource, "is_entity":false}
	for entity_id_value in visible_records.get("entity_ids", []):
		var entity: Dictionary = _entities_by_id.get(str(entity_id_value), {})
		var entity_rect := _footprint_rect(entity.get("footprint", {}), 4.0)
		if entity_rect.intersects(visible_rect):
			_node_rects[str(entity.get("id", ""))] = {"rect":entity_rect, "data":entity, "is_entity":true}
	for order_id_value in visible_records.get("order_ids", []):
		var order: Dictionary = _orders_by_id.get(str(order_id_value), {})
		var order_rect := _footprint_rect(order.get("footprint", {}), 4.0)
		if order_rect.intersects(visible_rect):
			_construction_order_rects[str(order.get("id", ""))] = {"rect":order_rect, "data":order}
	for link_id_value in visible_records.get("link_ids", []):
		var link: Dictionary = _links_by_id.get(str(link_id_value), {})
		var source: Dictionary = _entities_by_id.get(str(link.get("source_id", "")), {})
		var target: Dictionary = _entities_by_id.get(str(link.get("target_id", "")), {})
		if source.is_empty() or target.is_empty():
			continue
		var endpoints := _connection_endpoints(source, target, str(link.get("kind", "CARGO")))
		var from: Vector2 = endpoints[0]
		var to: Vector2 = endpoints[1]
		var hit := Rect2(from, Vector2.ZERO).expand(to).grow(7.0)
		if hit.intersects(visible_rect):
			_link_hit_rects[str(link.get("id", ""))] = hit
	_hit_geometry_dirty = false


func _select_at(point: Vector2) -> void:
	_ensure_hit_geometry()
	for link_id_value in _link_hit_rects.keys():
		var link_id := str(link_id_value)
		var hit: Rect2 = _link_hit_rects.get(link_id, Rect2())
		if hit.has_point(point) and _distance_to_link(point, link_id) <= 8.0:
			_selected_link_id = link_id
			_selected_node_id = ""
			link_selected.emit(_link_by_id(link_id))
			queue_redraw()
			return
	# Construction orders are drawn above resource fields.  Their inspector must
	# remain reachable when an in-progress build occupies an extraction field.
	for order_id_value in _construction_order_rects.keys():
		var order_id := str(order_id_value)
		var order_row: Dictionary = _construction_order_rects.get(order_id, {})
		var order_rect: Rect2 = order_row.get("rect", Rect2())
		if order_rect.has_point(point):
			_selected_node_id = ""
			_selected_link_id = ""
			construction_order_selected.emit((order_row.get("data", {}) as Dictionary).duplicate(true))
			queue_redraw()
			return
	var node_ids: Array = _node_rects.keys()
	node_ids.reverse()
	for node_id_value in node_ids:
		var node_id := str(node_id_value)
		var row: Dictionary = _node_rects.get(node_id, {})
		var rect: Rect2 = row.get("rect", Rect2())
		if rect.has_point(point):
			# A valid placement preview on a resource field (notably an
			# extractor) is an intentional build gesture, not field selection.
			if not bool(row.get("is_entity", false)) and _placement_preview_contains(point):
				_select_tile(point)
				return
			_selected_node_id = node_id
			_selected_link_id = ""
			if bool(row.get("is_entity", false)):
				entity_selected.emit((row.get("data", {}) as Dictionary).duplicate(true))
			else:
				resource_field_selected.emit((row.get("data", {}) as Dictionary).duplicate(true))
			queue_redraw()
			return
	_select_tile(point)


func _placement_preview_contains(point: Vector2) -> bool:
	if not bool(_placement_preview.get("valid", false)):
		return false
	var footprint_value: Variant = _placement_preview.get("footprint", {})
	return footprint_value is Dictionary and _footprint_rect(footprint_value, 2.0).has_point(point)


func _select_tile(point: Vector2) -> void:
	_selected_node_id = ""
	_selected_link_id = ""
	var selected_tile := _screen_to_tile(point)
	if not _tile_in_bounds(selected_tile):
		queue_redraw()
		return
	_keyboard_tile = selected_tile
	tile_selected.emit(_keyboard_tile)
	queue_redraw()


func _distance_to_link(point: Vector2, link_id: String) -> float:
	var link := _link_by_id(link_id)
	var source := _entity_by_id(str(link.get("source_id", "")))
	var target := _entity_by_id(str(link.get("target_id", "")))
	if source.is_empty() or target.is_empty():
		return INF
	var endpoints := _connection_endpoints(source, target, str(link.get("kind", "CARGO")))
	var from: Vector2 = endpoints[0]
	var to: Vector2 = endpoints[1]
	return Geometry2D.get_closest_point_to_segment(point, from, to).distance_to(point)


func _node_style(tone: Color, selected: bool) -> StyleBoxFlat:
	var cache_key := "%s:%s" % [tone.to_html(true), str(selected)]
	if _node_style_cache.has(cache_key):
		return _node_style_cache.get(cache_key) as StyleBoxFlat
	var style := StyleBoxFlat.new()
	style.bg_color = NODE_COLOR
	style.border_color = FOCUS_COLOR if selected else Color(tone, 0.85)
	style.set_border_width_all(2 if selected else 1)
	style.set_corner_radius_all(5)
	_node_style_cache[cache_key] = style
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
	return _entities_by_id.get(entity_id, {})


func _link_by_id(link_id: String) -> Dictionary:
	return _links_by_id.get(link_id, {})


func _has_node(node_id: String) -> bool:
	return not _entity_by_id(node_id).is_empty() or _resource_by_id(node_id).size() > 0


func _resource_by_id(resource_id: String) -> Dictionary:
	return _resources_by_id.get(resource_id, {})


func _has_link(link_id: String) -> bool:
	return not _link_by_id(link_id).is_empty()


func _has_active_flow() -> bool:
	return _has_active_flow_cache


func _flow_animation_allowed() -> bool:
	if not _has_active_flow_cache or _overview_mode or _tile_scale() < 0.75:
		return false
	var record_count := _visible_record_count()
	return record_count <= MAX_ANIMATED_SNAPSHOT_RECORDS


func _visible_record_count() -> int:
	var records := _visible_records if not _visible_records.is_empty() else _chunk_index.query(_visible_world_query_rect())
	return int(records.get("resource_ids", []).size()) + int(records.get("entity_ids", []).size()) + int(records.get("link_ids", []).size()) + int(records.get("order_ids", []).size())


func _detail_stage() -> String:
	var visible_count := _visible_record_count()
	if _tile_scale() < 0.75 \
			or visible_count >= COMPACT_DETAIL_VISIBLE_RECORDS \
			or (_detail_stage_cache == "COMPACT" and visible_count >= COMPACT_DETAIL_EXIT_RECORDS):
		_detail_stage_cache = "COMPACT"
	elif _tile_scale() < 1.5 \
			or visible_count >= MEDIUM_DETAIL_VISIBLE_RECORDS \
			or (_detail_stage_cache in ["MEDIUM", "COMPACT"] and visible_count >= MEDIUM_DETAIL_EXIT_RECORDS):
		_detail_stage_cache = "MEDIUM"
	else:
		_detail_stage_cache = "FULL"
	return _detail_stage_cache


func _rebuild_snapshot_indexes() -> void:
	_entities_by_id.clear()
	_links_by_id.clear()
	_resources_by_id.clear()
	_orders_by_id.clear()
	_visible_records.clear()
	_has_active_flow_cache = false
	_visible_active_flow = false
	for entity_value in _snapshot.get("entities", []):
		if entity_value is Dictionary:
			var entity := entity_value as Dictionary
			_entities_by_id[str(entity.get("id", ""))] = entity
	for link_value in _snapshot.get("links", []):
		if link_value is Dictionary:
			var link := link_value as Dictionary
			_links_by_id[str(link.get("id", ""))] = link
			_has_active_flow_cache = _has_active_flow_cache or float(link.get("last_flow", 0.0)) > 0.00001
	for resource_value in _snapshot.get("resource_fields", []):
		if resource_value is Dictionary:
			var resource := resource_value as Dictionary
			_resources_by_id[str(resource.get("id", ""))] = resource
	for order_value in _snapshot.get("construction_orders", []):
		if order_value is Dictionary:
			var order := order_value as Dictionary
			_orders_by_id[str(order.get("id", ""))] = order


func _status_name(status_id: String) -> String:
	return I18n.status(status_id)


func _placement_reason_name(reason_code: String) -> String:
	var key := "factory.reason.%s" % reason_code.to_lower()
	var localized := str(I18n.t(key))
	return _status_name(reason_code) if localized == key else localized


func _item_name(item_id: String) -> String:
	if item_id.is_empty():
		return I18n.t("factory.resource_field")
	var names: Dictionary = _snapshot.get("item_names", {}) if _snapshot.get("item_names", {}) is Dictionary else {}
	return str(names.get(item_id, item_id.replace("_", " ").capitalize()))
