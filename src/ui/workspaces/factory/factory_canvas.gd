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
signal machine_configuration_copy_requested(entity: Dictionary)
signal machine_configuration_paste_requested(entity: Dictionary)
## Port gestures are presentation-only. The workspace supplies authoritative
## candidate/preflight state and converts a completed gesture into a command.
signal port_drag_started(entity_id: String, port: Dictionary, visible_candidates: Array)
signal port_connection_requested(source_id: String, source_port: Dictionary, target_id: String, target_port: Dictionary)
signal port_drag_preview(source_id: String, source_port: Dictionary, target_id: String, target_port: Dictionary, valid: bool)

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
const POINTER_DRAG_THRESHOLD_PIXELS := 8.0
const PORT_START_HIT_RADIUS_PIXELS := 10.0
const PORT_SNAP_HIT_RADIUS_PIXELS := 24.0

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
var _port_hit_rects := {}
var _placement_preview: Dictionary = {}
var _connection_preview := {"source_id":"", "target_id":"", "kind":""}
var _connection_candidate_ids: Dictionary = {}
var _keyboard_tile := Vector2i.ZERO
var _entities_by_id: Dictionary = {}
var _links_by_id: Dictionary = {}
var _resources_by_id: Dictionary = {}
var _orders_by_id: Dictionary = {}
var _recipe_names_by_id: Dictionary = {}
var _visible_records: Dictionary = {}
var _has_active_flow_cache := false
var _visible_active_flow := false
var _node_style_cache: Dictionary = {}
var _hit_geometry_dirty := true
var _detail_stage_cache := "FULL"
var _port_drag: Dictionary = {}
var _left_pointer: Dictionary = {}
var _configuration_gestures_enabled := true
var _port_connections_enabled := true


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
	var previous_topology_signature := _topology_signature()
	_snapshot = snapshot if already_normalized else _view_model.build(snapshot)
	_rebuild_snapshot_indexes()
	if not _port_drag.is_empty() and previous_topology_signature != _topology_signature():
		cancel_port_drag()
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


func set_configuration_gestures_enabled(enabled: bool) -> void:
	_configuration_gestures_enabled = enabled


func set_port_connections_enabled(enabled: bool) -> void:
	_port_connections_enabled = enabled
	if not enabled:
		cancel_port_drag()


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


func cancel_port_drag() -> void:
	_port_drag.clear()
	queue_redraw()


## The workspace calls these synchronously from the drag signals. This keeps
## duplicate/fan-in/fan-out rules out of the canvas while ensuring the color the
## player sees is the same result that controls submission.
func set_port_drag_validation(valid: bool, reason_code: String = "") -> void:
	if _port_drag.is_empty() or str(_port_drag.get("target_id", "")).is_empty():
		return
	_port_drag["valid"] = valid
	_port_drag["reason_code"] = reason_code
	queue_redraw()


func set_port_drag_candidates(candidate_keys: Array[String]) -> void:
	if _port_drag.is_empty():
		return
	var candidates: Dictionary = {}
	var candidate_entities: Dictionary = {}
	for key in candidate_keys:
		candidates[key] = true
		candidate_entities[key.get_slice(":", 0)] = true
	_port_drag["candidate_keys"] = candidates
	_port_drag["candidate_entity_ids"] = candidate_entities
	queue_redraw()


func set_connection_preview(source_id: String, target_id: String, kind: String, valid: bool = false, candidate_ids: Array[String] = [], source_port_id: String = "", target_port_id: String = "") -> void:
	_connection_candidate_ids.clear()
	for candidate_id in candidate_ids:
		_connection_candidate_ids[candidate_id] = true
	_connection_preview = {
		"source_id":source_id,
		"target_id":target_id,
		"kind":kind.to_upper(),
		"valid":valid,
		"candidate_ids":candidate_ids.duplicate(),
		"source_port_id":source_port_id,
		"target_port_id":target_port_id
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
	_port_hit_rects.clear()
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
		var kind_width := header_rect.size.x - 18.0
		var recipe_label := ""
		if kind_id == "MACHINE":
			var recipe_id := str(entity.get("recipe_id", ""))
			recipe_label = str(_recipe_names_by_id.get(recipe_id, recipe_id)) if not recipe_id.is_empty() else I18n.t("factory.node.unconfigured", "UNCONFIGURED")
			kind_width = maxf(24.0, header_rect.size.x * 0.42)
		draw_string(font, header_rect.position + Vector2(16, 14), kind, HORIZONTAL_ALIGNMENT_LEFT, kind_width, 9, Color("a5b2ac"))
		if kind_id == "MACHINE":
			draw_string(font, header_rect.position + Vector2(kind_width + 8.0, 14), recipe_label, HORIZONTAL_ALIGNMENT_RIGHT, maxf(0.0, header_rect.size.x - kind_width - 14.0), 8, Color("e0ae5c") if str(entity.get("recipe_id", "")).is_empty() else Color("d5a45c"))
		draw_string(font, rect.position + Vector2(8, minf(39.0, rect.size.y - 8.0)), str(entity.get("name", entity.get("id", I18n.t("factory.value.unit", "Unit")))), HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 11, Color("e6eeea"))
		if detail_stage == "MEDIUM":
			continue
		if rect.size.y >= 68.0:
			var input_summary := _buffer_summary(entity.get("inputs", {}))
			var output_summary := _buffer_summary(entity.get("outputs", {}))
			var inventory_summary := _buffer_summary(entity.get("inventory", {}))
			var io_y := rect.position.y + 54.0
			if not input_summary.is_empty():
				draw_string(font, Vector2(rect.position.x + 8.0, io_y), I18n.t("factory.node.input_short", "IN") + "  " + input_summary, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, Color("8ebbb2"))
				io_y += 11.0
			if not output_summary.is_empty() and io_y < rect.end.y - 17.0:
				draw_string(font, Vector2(rect.position.x + 8.0, io_y), I18n.t("factory.node.output_short", "OUT") + "  " + output_summary, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, Color("d5a45c"))
				io_y += 11.0
			if not inventory_summary.is_empty() and io_y < rect.end.y - 17.0:
				draw_string(font, Vector2(rect.position.x + 8.0, io_y), I18n.t("factory.node.stock_short", "STOCK") + "  " + inventory_summary, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 8, Color("9aa6a1"))
		var progress := clampf(float(entity.get("progress", 0.0)), 0.0, 1.0)
		var bar := Rect2(rect.position + Vector2(8, maxf(45.0, rect.size.y - 14.0)), Vector2(maxf(0.0, rect.size.x - 16.0), 4.0))
		if bar.position.y + bar.size.y <= rect.end.y - 4.0:
			draw_rect(bar, Color("26302c"), true)
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * (float(entity.get("power_factor", 1.0)) if progress <= 0.0 else progress), bar.size.y)), tone, true)
			var rate := "%.2f/s" % float(entity.get("actual_rate", 0.0))
			draw_string(font, rect.position + Vector2(8, bar.position.y - rect.position.y - 4.0), rate, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16, 9, Color("9aa6a1"))


func _buffer_summary(value: Variant) -> String:
	if not value is Dictionary:
		return ""
	var buffer := value as Dictionary
	var item_ids: Array = buffer.keys()
	item_ids.sort_custom(func(left, right): return str(left) < str(right))
	var parts: Array[String] = []
	for item_id_value in item_ids:
		var item_id := str(item_id_value)
		var quantity := maxi(0, int(buffer.get(item_id_value, 0)))
		if quantity <= 0:
			continue
		parts.append("%s %d" % [_item_name(item_id), quantity])
		if parts.size() >= 2:
			break
	if parts.is_empty():
		return ""
	if buffer.keys().size() > parts.size():
		parts.append("…")
	return " · ".join(parts)


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
	if not _port_drag.is_empty():
		_draw_port_drag_preview()
		return
	var source_id := str(_connection_preview.get("source_id", ""))
	var target_id := str(_connection_preview.get("target_id", ""))
	if source_id.is_empty() or target_id.is_empty() or source_id == target_id:
		return
	var source := _entity_by_id(source_id)
	var target := _entity_by_id(target_id)
	if source.is_empty() or target.is_empty():
		return
	var endpoints := _connection_endpoints(source, target, str(_connection_preview.get("kind", "CARGO")), str(_connection_preview.get("source_port_id", "")), str(_connection_preview.get("target_port_id", "")))
	var from: Vector2 = endpoints[0]
	var to: Vector2 = endpoints[1]
	if not Rect2(from, Vector2.ZERO).expand(to).grow(DRAW_CULL_MARGIN_PIXELS).intersects(_visible_draw_rect()):
		return
	var kind := str(_connection_preview.get("kind", "CARGO"))
	var tone := Color("6fbf92") if bool(_connection_preview.get("valid", false)) else Color("d86e63")
	_draw_orthogonal_route(_orthogonal_route(from, to), tone, 2.0, true)
	_draw_link_arrow(_orthogonal_route(from, to), tone)


func _draw_port_drag_preview() -> void:
	var source_id := str(_port_drag.get("source_id", ""))
	var source := _entity_by_id(source_id)
	var source_port: Dictionary = _port_drag.get("source_port", {}) as Dictionary
	var origin_id := str(_port_drag.get("origin_id", ""))
	var origin := _entity_by_id(origin_id)
	var origin_port: Dictionary = _port_drag.get("origin_port", {}) as Dictionary
	if origin.is_empty() or origin_port.is_empty():
		return
	var origin_direction := str(origin_port.get("direction", "OUTPUT"))
	var origin_center := _port_center(origin, origin_port, _footprint_rect(origin.get("footprint", {}), 4.0), origin_direction, str(origin_port.get("kind", "CARGO")))
	var from := origin_center
	var target_id := str(_port_drag.get("target_id", ""))
	var target_port: Dictionary = _port_drag.get("target_port", {}) as Dictionary
	var to := Vector2(_port_drag.get("pointer", from))
	if not source.is_empty() and not source_port.is_empty():
		from = _port_center(source, source_port, _footprint_rect(source.get("footprint", {}), 4.0), "OUTPUT", str(source_port.get("kind", "CARGO")))
	if not target_id.is_empty() and not target_port.is_empty():
		var target := _entity_by_id(target_id)
		if not target.is_empty():
			to = _port_center(target, target_port, _footprint_rect(target.get("footprint", {}), 4.0), "INPUT", str(target_port.get("kind", "CARGO")))
	elif origin_direction == "INPUT":
		to = origin_center
		from = Vector2(_port_drag.get("pointer", origin_center))
	var valid := bool(_port_drag.get("valid", false))
	var has_hover := not str(_port_drag.get("hover_key", "")).is_empty()
	var tone := Color("8de0a9") if valid else Color("ef9b8f") if has_hover else Color("79d9ca")
	var route := _orthogonal_route(from, to)
	_draw_orthogonal_route(route, Color(tone, 0.20), 6.0, false)
	_draw_orthogonal_route(route, tone, 2.0, true)
	_draw_link_arrow(route, tone)
	draw_circle(to, 5.0, Color(tone, 0.22))
	draw_circle(to, 5.0, tone, false, 1.5)


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
		var endpoints := _connection_endpoints(source, target, str(link.get("kind", "CARGO")), str(link.get("source_port_id", "")), str(link.get("target_port_id", "")))
		var from: Vector2 = endpoints[0]
		var to: Vector2 = endpoints[1]
		var route := _link_route(link, from, to)
		var hit := _route_bounds(route).grow(8.0)
		if not hit.intersects(_visible_draw_rect()):
			continue
		var kind := str(link.get("kind", "CARGO"))
		var color := POWER_COLOR if kind == "POWER" else CARGO_COLOR
		var selected := _selected_link_id == str(link.get("id", ""))
		var status := str(link.get("status", "IDLE"))
		var congestion := clampf(float(link.get("congestion", link.get("utilization", 0.0))), 0.0, 1.0)
		var blocked := bool(link.get("blocked", false)) or not str(link.get("blocked_reason", "")).is_empty() or status in ["SOURCE_EMPTY", "TARGET_FULL", "BLOCKED"]
		if blocked:
			color = Color("d86e63")
		elif congestion >= 0.80:
			color = Color("e0ae5c")
		var lane_count := maxi(1, int(link.get("lane_count", 1)))
		var tier := str(link.get("tier", "MK1")).to_upper()
		var width := 1.4 + clampf(float(link.get("utilization", 0.0)), 0.0, 1.0) * 1.8 + minf(1.8, float(lane_count - 1) * 0.35) + minf(0.8, float(_tier_number(tier) - 1) * 0.2)
		if selected:
			color = FOCUS_COLOR
			width += 1.5
		_draw_orthogonal_route(route, color, width, false)
		var shows_detail := _tile_scale() >= 0.75
		if shows_detail:
			_draw_link_arrow(route, color)
			if _tile_scale() >= 1.25 and not blocked:
				var label: String = str(I18n.t("factory.route.label", "L%d · %s · %d%%")) % [lane_count, tier, roundi(congestion * 100.0)]
				draw_string(get_theme_default_font(), _route_midpoint(route) + Vector2(4, -5), label, HORIZONTAL_ALIGNMENT_LEFT, 120, 9, color)
		_link_hit_rects[str(link.get("id", ""))] = hit
		if flow_animation_allowed and float(link.get("last_flow", 0.0)) > 0.00001 and not _reduced_motion and not blocked:
			_visible_active_flow = true
			var packet_position := _point_on_route(route, fposmod(_visual_phase * 0.62 + float(str(link.get("id", "")).hash() % 13) / 13.0, 1.0))
			draw_circle(packet_position, 2.4, Color("f4e7c5") if kind == "CARGO" else Color("d5fffa"))


func _draw_connection_ports(entity: Dictionary, rect: Rect2, detail_stage: String) -> void:
	var entity_id := str(entity.get("id", ""))
	var is_source := entity_id == str(_connection_preview.get("source_id", ""))
	var is_target := entity_id == str(_connection_preview.get("target_id", ""))
	var drag_candidates: Dictionary = _port_drag.get("candidate_entity_ids", {}) if _port_drag.get("candidate_entity_ids", {}) is Dictionary else {}
	var drag_related := entity_id == str(_port_drag.get("origin_id", "")) or entity_id == str(_port_drag.get("hover_id", ""))
	var is_candidate := _connection_candidate_ids.has(entity_id) or drag_candidates.has(entity_id)
	if is_source or is_target:
		draw_rect(rect.grow(3.0), Color("d5a45c") if is_source else Color("62b5ae"), false, 2.0)
	elif is_candidate:
		# Candidate means structurally compatible. The selected route turns green
		# only after duplicate/input-occupancy preflight also passes.
		draw_rect(rect.grow(2.0), Color(FOCUS_COLOR, 0.72), false, 1.5)
	if detail_stage == "COMPACT" and not drag_related and not is_candidate:
		return
	var radius := 4.0 if detail_stage == "FULL" or drag_related or is_candidate else 3.0
	_draw_entity_ports(entity, rect, "INPUT", radius)
	_draw_entity_ports(entity, rect, "OUTPUT", radius)


func _draw_entity_ports(entity: Dictionary, rect: Rect2, direction: String, radius: float) -> void:
	var ports := _view_model.connection_ports(entity, direction)
	var cargo_ports: Array = []
	var power_ports: Array = []
	for port_value in ports:
		var port: Dictionary = port_value as Dictionary
		if str(port.get("kind", "CARGO")) == "POWER":
			power_ports.append(port)
		else:
			cargo_ports.append(port)
	for index in cargo_ports.size():
		var port: Dictionary = cargo_ports[index] as Dictionary
		var fraction := float(index + 1) / float(cargo_ports.size() + 1)
		var center := Vector2(rect.position.x if direction == "INPUT" else rect.end.x, lerpf(rect.position.y, rect.end.y, fraction))
		_draw_port_marker(entity, port, center, radius, CARGO_COLOR)
	for index in power_ports.size():
		var port: Dictionary = power_ports[index] as Dictionary
		var fraction := float(index + 1) / float(power_ports.size() + 1)
		var center := Vector2(lerpf(rect.position.x, rect.end.x, fraction), rect.position.y if direction == "INPUT" else rect.end.y)
		_draw_port_marker(entity, port, center, radius, POWER_COLOR)


func _draw_port_marker(entity: Dictionary, port: Dictionary, center: Vector2, radius: float, color: Color) -> void:
	var key := "%s:%s" % [str(entity.get("id", "")), str(port.get("id", ""))]
	var is_drag_origin := key == str(_port_drag.get("origin_key", ""))
	var is_drag_hover := key == str(_port_drag.get("hover_key", ""))
	var candidate_keys: Dictionary = _port_drag.get("candidate_keys", {}) if _port_drag.get("candidate_keys", {}) is Dictionary else {}
	var is_candidate := candidate_keys.has(key)
	var tone := color
	if is_drag_origin:
		tone = Color("d5a45c")
	elif is_drag_hover:
		tone = Color("8de0a9") if bool(_port_drag.get("valid", false)) else Color("ef9b8f")
	elif is_candidate:
		tone = Color("8de0a9")
	elif not _port_drag.is_empty():
		tone = Color(color, 0.34)
	draw_circle(center, radius + (1.5 if is_drag_origin or is_drag_hover else 0.0), tone)
	_register_port_hit(entity, port, center, radius)


func _register_port_hit(entity: Dictionary, port: Dictionary, center: Vector2, radius: float) -> void:
	var key := "%s:%s" % [str(entity.get("id", "")), str(port.get("id", ""))]
	var hit_radius := maxf(PORT_SNAP_HIT_RADIUS_PIXELS, radius + 3.0)
	_port_hit_rects[key] = {"rect":Rect2(center - Vector2.ONE * hit_radius, Vector2.ONE * hit_radius * 2.0), "entity_id":str(entity.get("id", "")), "port":port.duplicate(false), "center":center}


func _register_entity_port_hits(entity: Dictionary, rect: Rect2, radius: float) -> void:
	for direction in ["INPUT", "OUTPUT"]:
		var cargo_ports: Array = []
		var power_ports: Array = []
		for port_value in _view_model.connection_ports(entity, direction):
			var port := port_value as Dictionary
			if str(port.get("kind", "CARGO")) == "POWER":
				power_ports.append(port)
			else:
				cargo_ports.append(port)
		for index in cargo_ports.size():
			var cargo_port := cargo_ports[index] as Dictionary
			var cargo_fraction := float(index + 1) / float(cargo_ports.size() + 1)
			var cargo_center := Vector2(rect.position.x if direction == "INPUT" else rect.end.x, lerpf(rect.position.y, rect.end.y, cargo_fraction))
			_register_port_hit(entity, cargo_port, cargo_center, radius)
		for index in power_ports.size():
			var power_port := power_ports[index] as Dictionary
			var power_fraction := float(index + 1) / float(power_ports.size() + 1)
			var power_center := Vector2(lerpf(rect.position.x, rect.end.x, power_fraction), rect.position.y if direction == "INPUT" else rect.end.y)
			_register_port_hit(entity, power_port, power_center, radius)


func _draw_link_arrow(route: PackedVector2Array, color: Color) -> void:
	if route.size() < 2:
		return
	var from := route[route.size() - 2]
	var to := route[route.size() - 1]
	var direction := (to - from).normalized()
	if direction.is_zero_approx():
		return
	var center := from.lerp(to, 0.54)
	var side := Vector2(-direction.y, direction.x)
	var triangle := PackedVector2Array([center + direction * 6.0, center - direction * 4.0 + side * 3.0, center - direction * 4.0 - side * 3.0])
	draw_colored_polygon(triangle, color)


func _connection_endpoints(source: Dictionary, target: Dictionary, kind: String, source_port_id: String = "", target_port_id: String = "") -> Array[Vector2]:
	var source_rect := _footprint_rect(source.get("footprint", {}), 4.0)
	var target_rect := _footprint_rect(target.get("footprint", {}), 4.0)
	var source_port := _view_model.connection_port_by_id(source, source_port_id, "OUTPUT") if not source_port_id.is_empty() else {}
	var target_port := _view_model.connection_port_by_id(target, target_port_id, "INPUT") if not target_port_id.is_empty() else {}
	if not source_port.is_empty() or not target_port.is_empty():
		return [_port_center(source, source_port, source_rect, "OUTPUT", kind), _port_center(target, target_port, target_rect, "INPUT", kind)]
	if kind == "POWER":
		return [Vector2(source_rect.get_center().x, source_rect.end.y), Vector2(target_rect.get_center().x, target_rect.position.y)]
	return [Vector2(source_rect.end.x, source_rect.get_center().y), Vector2(target_rect.position.x, target_rect.get_center().y)]


func _port_center(entity: Dictionary, port: Dictionary, rect: Rect2, direction: String, kind: String) -> Vector2:
	if port.is_empty():
		return Vector2(rect.get_center().x, rect.end.y if direction == "OUTPUT" else rect.position.y) if kind == "POWER" else Vector2(rect.end.x if direction == "OUTPUT" else rect.position.x, rect.get_center().y)
	var ports := _view_model.connection_ports(entity, direction)
	var same_kind: Array = []
	for candidate_value in ports:
		var candidate: Dictionary = candidate_value as Dictionary
		if str(candidate.get("kind", "CARGO")) == str(port.get("kind", "CARGO")):
			same_kind.append(candidate)
	var index := 0
	for candidate_index in same_kind.size():
		if str((same_kind[candidate_index] as Dictionary).get("id", "")) == str(port.get("id", "")):
			index = candidate_index
			break
	var fraction := float(index + 1) / float(same_kind.size() + 1)
	if str(port.get("kind", "CARGO")) == "POWER":
		return Vector2(lerpf(rect.position.x, rect.end.x, fraction), rect.end.y if direction == "OUTPUT" else rect.position.y)
	return Vector2(rect.end.x if direction == "OUTPUT" else rect.position.x, lerpf(rect.position.y, rect.end.y, fraction))


## DSPONLINE-style routes leave the port horizontally/vertically, travel on a
## shared orthogonal spine, then enter the target.  Corners are rounded in the
## renderer; explicit path_tiles are honored when a future topology snapshot
## supplies authored routing geometry.
func _link_route(link: Dictionary, from: Vector2, to: Vector2) -> PackedVector2Array:
	var authored := PackedVector2Array()
	var path_tiles: Variant = link.get("path_tiles", [])
	if path_tiles is Array:
		for point_value in path_tiles as Array:
			var point: Dictionary = point_value as Dictionary if point_value is Dictionary else {}
			if point.is_empty():
				continue
			# Domain paths address logical tiles; render through their centers so the
			# topology remains independent from current zoom and theme geometry.
			authored.append(_world_to_screen(Vector2(float(point.get("x", 0.0)) + 0.5, float(point.get("y", 0.0)) + 0.5)))
	if authored.size() >= 2:
		var first_was_horizontal := is_equal_approx(authored[0].y, authored[1].y)
		var last_was_horizontal := is_equal_approx(authored[-2].y, authored[-1].y)
		if authored.size() == 2:
			return _deduplicate_route_points(PackedVector2Array([
				from,
				Vector2(to.x, from.y) if first_was_horizontal else Vector2(from.x, to.y),
				to
			]))
		var connected := PackedVector2Array([from])
		var first_control := authored[1]
		connected.append(Vector2(first_control.x, from.y) if first_was_horizontal else Vector2(from.x, first_control.y))
		for index in range(1, authored.size() - 1):
			connected.append(authored[index])
		var last_control := authored[-2]
		connected.append(Vector2(to.x, last_control.y) if last_was_horizontal else Vector2(last_control.x, to.y))
		connected.append(to)
		return _deduplicate_route_points(connected)
	var lane_offset := (float(maxi(1, int(link.get("lane_count", 1))) - 1) * 2.0) + float(_tier_number(str(link.get("tier", "MK1"))) - 1)
	return _orthogonal_route(from, to, lane_offset)


func _tier_number(tier: String) -> int:
	match tier.to_upper():
		"MK3", "3": return 3
		"MK2", "2": return 2
	return 1


func _orthogonal_route(from: Vector2, to: Vector2, lane_offset: float = 0.0) -> PackedVector2Array:
	var horizontal := absf(to.x - from.x) >= absf(to.y - from.y)
	var route := PackedVector2Array([from])
	if horizontal:
		var horizontal_direction := 1.0 if to.x >= from.x else -1.0
		var lead := minf(34.0, maxf(12.0, absf(to.x - from.x) * 0.25))
		var spine_y := (from.y + to.y) * 0.5 + lane_offset
		route.append(Vector2(from.x + lead * horizontal_direction, from.y))
		route.append(Vector2(from.x + lead * horizontal_direction, spine_y))
		route.append(Vector2(to.x - lead * horizontal_direction, spine_y))
		route.append(Vector2(to.x - lead * horizontal_direction, to.y))
	else:
		var vertical_direction := 1.0 if to.y >= from.y else -1.0
		var lead := minf(34.0, maxf(12.0, absf(to.y - from.y) * 0.25))
		var spine_x := (from.x + to.x) * 0.5 + lane_offset
		route.append(Vector2(from.x, from.y + lead * vertical_direction))
		route.append(Vector2(spine_x, from.y + lead * vertical_direction))
		route.append(Vector2(spine_x, to.y - lead * vertical_direction))
		route.append(Vector2(to.x, to.y - lead * vertical_direction))
	route.append(to)
	return _deduplicate_route_points(route)


func _deduplicate_route_points(route: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in route:
		if result.is_empty() or result[result.size() - 1].distance_to(point) > 0.01:
			result.append(point)
	return result


func _draw_orthogonal_route(route: PackedVector2Array, color: Color, width: float, dashed: bool) -> void:
	if route.size() < 2:
		return
	var visible_rect := _visible_draw_rect().grow(width + 2.0)
	for index in range(route.size() - 1):
		var from := route[index]
		var to := route[index + 1]
		if not Rect2(from, Vector2.ZERO).expand(to).grow(width).intersects(visible_rect):
			continue
		if dashed:
			draw_dashed_line(from, to, color, width, 5.0)
		else:
			draw_line(from, to, color, width, true)
	# A small round cap at each turn retains the readable rounded-corner DSP
	# aesthetic without generating a per-link Curve2D allocation every frame.
	if not dashed:
		for index in range(1, route.size() - 1):
			var previous := route[index - 1]
			var point := route[index]
			var following := route[index + 1]
			var is_turn := not (is_equal_approx(previous.x, point.x) and is_equal_approx(point.x, following.x)) \
				and not (is_equal_approx(previous.y, point.y) and is_equal_approx(point.y, following.y))
			if is_turn and visible_rect.has_point(point):
				draw_circle(point, width * 0.5, color)


func _route_bounds(route: PackedVector2Array) -> Rect2:
	if route.is_empty():
		return Rect2()
	var bounds := Rect2(route[0], Vector2.ZERO)
	for point in route:
		bounds = bounds.expand(point)
	return bounds


func _route_midpoint(route: PackedVector2Array) -> Vector2:
	return _point_on_route(route, 0.5)


func _point_on_route(route: PackedVector2Array, ratio: float) -> Vector2:
	if route.is_empty():
		return Vector2.ZERO
	if route.size() == 1:
		return route[0]
	var total := 0.0
	for index in range(route.size() - 1):
		total += route[index].distance_to(route[index + 1])
	if total <= 0.001:
		return route[0]
	var remaining := clampf(ratio, 0.0, 1.0) * total
	for index in range(route.size() - 1):
		var from := route[index]
		var to := route[index + 1]
		var length := from.distance_to(to)
		if remaining <= length or index == route.size() - 2:
			return from.lerp(to, remaining / maxf(0.001, length))
		remaining -= length
	return route[route.size() - 1]


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


func _topology_signature() -> String:
	if _snapshot.is_empty() or not bool(_snapshot.get("valid", true)):
		return ""
	return "%s:%d" % [str(_snapshot.get("world_id", "")), int(_snapshot.get("topology_revision", 0))]


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
	if _is_placement_cancel_event(event) and (not _placement_preview.is_empty() or connection_active or not _port_drag.is_empty() or not _left_pointer.is_empty()):
		_left_pointer.clear()
		_dragging = false
		cancel_port_drag()
		if not _placement_preview.is_empty() or connection_active:
			placement_cancelled.emit()
		accept_event()
		return
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.pressed and mouse_event.shift_pressed and _configuration_gestures_allowed():
			if mouse_event.button_index == MOUSE_BUTTON_RIGHT:
				var copy_entity := _machine_at(mouse_event.position)
				if not copy_entity.is_empty():
					machine_configuration_copy_requested.emit(copy_entity)
					accept_event()
					return
			if mouse_event.button_index == MOUSE_BUTTON_LEFT:
				var paste_entity := _machine_at(mouse_event.position)
				if not paste_entity.is_empty():
					machine_configuration_paste_requested.emit(paste_entity)
					accept_event()
					return
		if mouse_event.button_index == MOUSE_BUTTON_MIDDLE:
			if mouse_event.pressed:
				_left_pointer.clear()
				cancel_port_drag()
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
		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if _dragging:
				accept_event()
				return
			if mouse_event.pressed:
				if bool(_port_drag.get("click_mode", false)):
					_finish_port_drag(mouse_event.position, true)
					accept_event()
					return
				if _begin_port_drag(mouse_event.position):
					accept_event()
					return
				if _point_has_interactive_hit(mouse_event.position):
					_select_at(mouse_event.position)
				else:
					_left_pointer = {"start":mouse_event.position, "last":mouse_event.position, "moved":false}
			elif not _port_drag.is_empty():
				_finish_port_drag(mouse_event.position)
			elif not _left_pointer.is_empty():
				var was_moved := bool(_left_pointer.get("moved", false))
				_left_pointer.clear()
				if not was_moved:
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
		if not _port_drag.is_empty():
			_update_port_drag(motion.position)
			accept_event()
			return
		if not _left_pointer.is_empty():
			var start: Vector2 = _left_pointer.get("start", motion.position)
			if not bool(_left_pointer.get("moved", false)) and start.distance_to(motion.position) > POINTER_DRAG_THRESHOLD_PIXELS:
				_left_pointer["moved"] = true
				_overview_mode = false
			if bool(_left_pointer.get("moved", false)):
				var last: Vector2 = _left_pointer.get("last", motion.position)
				_camera += motion.position - last
				_clamp_camera_to_bounds()
				_invalidate_hit_geometry()
				queue_redraw()
			_left_pointer["last"] = motion.position
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


func _configuration_gestures_allowed() -> bool:
	return not _dragging and _configuration_gestures_enabled and _placement_preview.is_empty() and str(_connection_preview.get("kind", "")).is_empty() and _port_drag.is_empty()


func _machine_at(point: Vector2) -> Dictionary:
	_ensure_hit_geometry()
	var node_ids: Array = _node_rects.keys()
	node_ids.reverse()
	for node_id_value in node_ids:
		var node_id := str(node_id_value)
		var row: Dictionary = _node_rects.get(node_id, {})
		if not bool(row.get("is_entity", false)):
			continue
		var entity: Dictionary = row.get("data", {}) as Dictionary
		if str(entity.get("node_kind", "")) != "MACHINE":
			continue
		var rect: Rect2 = row.get("rect", Rect2())
		if rect.has_point(point):
			return entity.duplicate(true)
	return {}


func _begin_port_drag(point: Vector2) -> bool:
	if not _port_connections_enabled or not _placement_preview.is_empty() or _dragging:
		return false
	_ensure_hit_geometry()
	# A wide target snap radius makes dense layouts forgiving, but using that
	# same radius for activation would turn the center of a small entity into a
	# hidden port. Keep a body-safe inspector region and a tighter start radius.
	if _point_in_entity_safe_body(point):
		return false
	var row := _port_at(point, "", false, PORT_START_HIT_RADIUS_PIXELS)
	if row.is_empty():
		return false
	var port: Dictionary = row.get("port", {}) as Dictionary
	var direction := str(port.get("direction", "")).to_upper()
	if direction not in ["INPUT", "OUTPUT"]:
		return false
	var entity_id := str(row.get("entity_id", ""))
	var port_key := "%s:%s" % [entity_id, str(port.get("id", ""))]
	_port_drag = {
		"origin_id":entity_id,
		"origin_port":port.duplicate(false),
		"origin_key":port_key,
		"source_id":entity_id if direction == "OUTPUT" else "",
		"source_port":port.duplicate(false) if direction == "OUTPUT" else {},
		"target_id":entity_id if direction == "INPUT" else "",
		"target_port":port.duplicate(false) if direction == "INPUT" else {},
		"hover_id":"",
		"hover_key":"",
		"pointer":point,
		"start_pointer":point,
		"moved":false,
		"click_mode":false,
		"candidate_keys":{},
		"candidate_entity_ids":{},
		"valid":false,
		"reason_code":""
	}
	var visible_candidates := _set_structural_port_candidates()
	port_drag_started.emit(entity_id, port.duplicate(false), visible_candidates)
	queue_redraw()
	return true


func _update_port_drag(point: Vector2) -> void:
	if _port_drag.is_empty():
		return
	var origin_port: Dictionary = _port_drag.get("origin_port", {}) as Dictionary
	var origin_direction := str(origin_port.get("direction", "")).to_upper()
	var opposite_direction := "INPUT" if origin_direction == "OUTPUT" else "OUTPUT"
	var previous_hover_key := str(_port_drag.get("hover_key", ""))
	var row := _port_at(point, opposite_direction, true, PORT_SNAP_HIT_RADIUS_PIXELS)
	var pair: Dictionary = {}
	var hover_id := ""
	var hover_port: Dictionary = {}
	if not row.is_empty():
		hover_port = (row.get("port", {}) as Dictionary).duplicate(false)
		hover_id = str(row.get("entity_id", ""))
		if hover_id != str(_port_drag.get("origin_id", "")):
			pair = _normalized_port_pair(str(_port_drag.get("origin_id", "")), origin_port, hover_id, hover_port)
	var structural_valid := false
	if not pair.is_empty():
		structural_valid = _view_model.compatible_port_pair(
			_entity_by_id(str(pair.get("source_id", ""))),
			pair.get("source_port", {}) as Dictionary,
			_entity_by_id(str(pair.get("target_id", ""))),
			pair.get("target_port", {}) as Dictionary
		)
	_port_drag["moved"] = bool(_port_drag.get("moved", false)) or Vector2(_port_drag.get("start_pointer", point)).distance_to(point) > POINTER_DRAG_THRESHOLD_PIXELS
	_port_drag["pointer"] = point
	_port_drag["hover_id"] = hover_id
	var hover_key := "%s:%s" % [hover_id, str(hover_port.get("id", ""))] if not hover_id.is_empty() else ""
	_port_drag["hover_key"] = hover_key
	if pair.is_empty():
		_reset_port_drag_endpoint()
	else:
		_port_drag["source_id"] = str(pair.get("source_id", ""))
		_port_drag["source_port"] = (pair.get("source_port", {}) as Dictionary).duplicate(false)
		_port_drag["target_id"] = str(pair.get("target_id", ""))
		_port_drag["target_port"] = (pair.get("target_port", {}) as Dictionary).duplicate(false)
	if hover_key != previous_hover_key:
		_port_drag["valid"] = structural_valid
		_port_drag["reason_code"] = "" if structural_valid else "CARGO_INCOMPATIBLE" if not hover_id.is_empty() else ""
		port_drag_preview.emit(
			str(_port_drag.get("source_id", "")),
			(_port_drag.get("source_port", {}) as Dictionary).duplicate(false),
			str(_port_drag.get("target_id", "")),
			(_port_drag.get("target_port", {}) as Dictionary).duplicate(false),
			structural_valid
		)
	queue_redraw()


func _finish_port_drag(point: Vector2, force_click_commit: bool = false) -> void:
	if _port_drag.is_empty():
		return
	var stationary := Vector2(_port_drag.get("start_pointer", point)).distance_to(point) <= POINTER_DRAG_THRESHOLD_PIXELS and not bool(_port_drag.get("moved", false))
	if not force_click_commit and not bool(_port_drag.get("click_mode", false)) and stationary:
		_port_drag["click_mode"] = true
		_port_drag["pointer"] = point
		_port_drag["hover_id"] = ""
		_port_drag["hover_key"] = ""
		_reset_port_drag_endpoint()
		queue_redraw()
		return
	_update_port_drag(point)
	var source_id := str(_port_drag.get("source_id", ""))
	var source_port: Dictionary = _port_drag.get("source_port", {}) as Dictionary
	var target_id := str(_port_drag.get("target_id", ""))
	var target_port: Dictionary = _port_drag.get("target_port", {}) as Dictionary
	var valid := bool(_port_drag.get("valid", false))
	_port_drag.clear()
	queue_redraw()
	if valid:
		port_connection_requested.emit(source_id, source_port.duplicate(false), target_id, target_port.duplicate(false))


func _port_at(point: Vector2, preferred_direction: String = "", require_direction: bool = false, maximum_distance: float = PORT_SNAP_HIT_RADIUS_PIXELS) -> Dictionary:
	var best: Dictionary = {}
	var best_direction_rank := 2
	var best_distance_squared := INF
	var best_key := ""
	for key_value in _port_hit_rects.keys():
		var row: Dictionary = _port_hit_rects.get(key_value, {}) as Dictionary
		var rect: Rect2 = row.get("rect", Rect2())
		if not rect.has_point(point):
			continue
		var port: Dictionary = row.get("port", {}) as Dictionary
		if require_direction and str(port.get("direction", "")).to_upper() != preferred_direction.to_upper():
			continue
		var direction_rank := 0 if preferred_direction.is_empty() or str(port.get("direction", "")) == preferred_direction else 1
		var center: Vector2 = row.get("center", rect.get_center())
		var distance_squared := center.distance_squared_to(point)
		if distance_squared > maximum_distance * maximum_distance:
			continue
		var key := str(key_value)
		if best.is_empty() \
				or direction_rank < best_direction_rank \
				or (direction_rank == best_direction_rank and distance_squared < best_distance_squared - 0.001) \
				or (direction_rank == best_direction_rank and is_equal_approx(distance_squared, best_distance_squared) and key < best_key):
			best = row
			best_direction_rank = direction_rank
			best_distance_squared = distance_squared
			best_key = key
	return best


func _point_in_entity_safe_body(point: Vector2) -> bool:
	for row_value in _node_rects.values():
		var row := row_value as Dictionary
		if not bool(row.get("is_entity", false)):
			continue
		var rect: Rect2 = row.get("rect", Rect2())
		var inset := minf(8.0, minf(rect.size.x, rect.size.y) * 0.30)
		if inset > 0.0 and rect.grow(-inset).has_point(point):
			return true
	return false


func _normalized_port_pair(first_id: String, first_port: Dictionary, second_id: String, second_port: Dictionary) -> Dictionary:
	var first_direction := str(first_port.get("direction", "")).to_upper()
	var second_direction := str(second_port.get("direction", "")).to_upper()
	if first_direction == "OUTPUT" and second_direction == "INPUT":
		return {"source_id":first_id, "source_port":first_port, "target_id":second_id, "target_port":second_port}
	if first_direction == "INPUT" and second_direction == "OUTPUT":
		return {"source_id":second_id, "source_port":second_port, "target_id":first_id, "target_port":first_port}
	return {}


func _reset_port_drag_endpoint() -> void:
	var origin_id := str(_port_drag.get("origin_id", ""))
	var origin_port: Dictionary = _port_drag.get("origin_port", {}) as Dictionary
	if str(origin_port.get("direction", "")).to_upper() == "OUTPUT":
		_port_drag["source_id"] = origin_id
		_port_drag["source_port"] = origin_port.duplicate(false)
		_port_drag["target_id"] = ""
		_port_drag["target_port"] = {}
	else:
		_port_drag["source_id"] = ""
		_port_drag["source_port"] = {}
		_port_drag["target_id"] = origin_id
		_port_drag["target_port"] = origin_port.duplicate(false)
	_port_drag["valid"] = false
	_port_drag["reason_code"] = ""


func _set_structural_port_candidates() -> Array:
	var origin_id := str(_port_drag.get("origin_id", ""))
	var origin_port: Dictionary = _port_drag.get("origin_port", {}) as Dictionary
	var opposite_direction := "INPUT" if str(origin_port.get("direction", "")).to_upper() == "OUTPUT" else "OUTPUT"
	var candidate_keys: Array[String] = []
	var candidate_rows: Array = []
	for key_value in _port_hit_rects.keys():
		var row: Dictionary = _port_hit_rects.get(key_value, {}) as Dictionary
		var candidate_id := str(row.get("entity_id", ""))
		var candidate_port: Dictionary = row.get("port", {}) as Dictionary
		if candidate_id == origin_id or str(candidate_port.get("direction", "")).to_upper() != opposite_direction:
			continue
		var pair := _normalized_port_pair(origin_id, origin_port, candidate_id, candidate_port)
		if not pair.is_empty() and _view_model.compatible_port_pair(
				_entity_by_id(str(pair.get("source_id", ""))),
				pair.get("source_port", {}) as Dictionary,
				_entity_by_id(str(pair.get("target_id", ""))),
				pair.get("target_port", {}) as Dictionary):
			candidate_keys.append(str(key_value))
			candidate_rows.append({"entity_id":candidate_id, "port":candidate_port.duplicate(false)})
	set_port_drag_candidates(candidate_keys)
	return candidate_rows


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
	_port_hit_rects.clear()
	_hit_geometry_dirty = true


func _ensure_hit_geometry() -> void:
	if not _hit_geometry_dirty:
		return
	_node_rects.clear()
	_link_hit_rects.clear()
	_construction_order_rects.clear()
	_port_hit_rects.clear()
	var visible_rect := _visible_draw_rect()
	var visible_records := _chunk_index.query(_visible_world_query_rect())
	_visible_records = visible_records
	var hit_detail_stage := _detail_stage()
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
			if hit_detail_stage != "COMPACT":
				_register_entity_port_hits(entity, entity_rect, 4.0 if hit_detail_stage == "FULL" else 3.0)
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
		var endpoints := _connection_endpoints(source, target, str(link.get("kind", "CARGO")), str(link.get("source_port_id", "")), str(link.get("target_port_id", "")))
		var from: Vector2 = endpoints[0]
		var to: Vector2 = endpoints[1]
		var hit := _route_bounds(_link_route(link, from, to)).grow(8.0)
		if hit.intersects(visible_rect):
			_link_hit_rects[str(link.get("id", ""))] = hit
	_hit_geometry_dirty = false


func _select_at(point: Vector2) -> void:
	_ensure_hit_geometry()
	# The visible build preview is the topmost action surface. It must win over
	# fields, entities and routes beneath it.
	if _placement_preview_contains(point):
		_select_tile(point)
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
	# Entities are drawn above resource fields, and both are drawn above links.
	for entity_pass in [true, false]:
		for node_id_value in node_ids:
			var node_id := str(node_id_value)
			var row: Dictionary = _node_rects.get(node_id, {})
			if bool(row.get("is_entity", false)) != entity_pass:
				continue
			var rect: Rect2 = row.get("rect", Rect2())
			if not rect.has_point(point):
				continue
			_selected_node_id = node_id
			_selected_link_id = ""
			if entity_pass:
				entity_selected.emit((row.get("data", {}) as Dictionary).duplicate(true))
			else:
				resource_field_selected.emit((row.get("data", {}) as Dictionary).duplicate(true))
			queue_redraw()
			return
	var link_id := _nearest_link_at(point)
	if not link_id.is_empty():
		_selected_link_id = link_id
		_selected_node_id = ""
		link_selected.emit(_link_by_id(link_id))
		queue_redraw()
		return
	_select_tile(point)


func _point_has_interactive_hit(point: Vector2) -> bool:
	_ensure_hit_geometry()
	if _placement_preview_hit(point):
		return true
	if _port_connections_enabled and not _point_in_entity_safe_body(point) and not _port_at(point, "", false, PORT_START_HIT_RADIUS_PIXELS).is_empty():
		return true
	for order_value in _construction_order_rects.values():
		var order_row := order_value as Dictionary
		var order_rect: Rect2 = order_row.get("rect", Rect2())
		if order_rect.has_point(point):
			return true
	for node_value in _node_rects.values():
		var node_row := node_value as Dictionary
		var node_rect: Rect2 = node_row.get("rect", Rect2())
		if node_rect.has_point(point):
			return true
	return not _nearest_link_at(point).is_empty()


func _nearest_link_at(point: Vector2) -> String:
	var best_id := ""
	var best_distance := INF
	for link_id_value in _link_hit_rects.keys():
		var link_id := str(link_id_value)
		var hit: Rect2 = _link_hit_rects.get(link_id, Rect2())
		if not hit.has_point(point):
			continue
		var distance := _distance_to_link(point, link_id)
		if distance <= 8.0 and (best_id.is_empty() or distance < best_distance - 0.001 or (is_equal_approx(distance, best_distance) and link_id < best_id)):
			best_id = link_id
			best_distance = distance
	return best_id


func _placement_preview_hit(point: Vector2) -> bool:
	var footprint_value: Variant = _placement_preview.get("footprint", {})
	return footprint_value is Dictionary and _footprint_rect(footprint_value, 2.0).has_point(point)


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
	var endpoints := _connection_endpoints(source, target, str(link.get("kind", "CARGO")), str(link.get("source_port_id", "")), str(link.get("target_port_id", "")))
	var route := _link_route(link, endpoints[0], endpoints[1])
	var distance := INF
	for index in range(route.size() - 1):
		distance = minf(distance, Geometry2D.get_closest_point_to_segment(point, route[index], route[index + 1]).distance_to(point))
	return distance


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
		"NO_POWER", "INPUT_SHORTAGE", "WAITING_MATERIALS", "SOURCE_EMPTY", "NO_RECIPE": return Color("e0ae5c")
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
	_recipe_names_by_id.clear()
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
	var palette: Dictionary = _snapshot.get("palette", {}) if _snapshot.get("palette", {}) is Dictionary else {}
	for recipe_value in palette.get("recipes", []):
		if recipe_value is Dictionary:
			var recipe := recipe_value as Dictionary
			_recipe_names_by_id[str(recipe.get("id", ""))] = str(recipe.get("name", recipe.get("id", "")))


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
