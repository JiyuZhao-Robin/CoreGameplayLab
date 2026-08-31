class_name ShipAssemblyMapView
extends GraphEdit

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipPortGlyphScript = preload("res://src/ui/components/ship_port_glyph.gd")

signal draft_changed(snapshot: Dictionary)
signal entity_selected(kind: String, entity_id: String)
signal notice_requested(message: String)

const HULL_NODE_NAME := "ship_design_hull"
const MODULE_NODE_PREFIX := "ship_design_module_"
const DEFAULT_ZOOM_MIN := 0.20
const FIT_PADDING := 72.0

var _catalog: Dictionary = {}
var _entities := {}
var _links: Array[Dictionary] = []
var _socket_nodes := {}
var _socket_glyphs := {}
var _next_node_serial := 1
var _connection_drag_module_name := ""


func _ready() -> void:
	name = "ShipAssemblyMap"
	custom_minimum_size.y = 420.0
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	show_grid = true
	grid_pattern = GraphEdit.GRID_PATTERN_DOTS
	show_menu = true
	show_zoom_label = true
	snapping_enabled = true
	snapping_distance = 20
	minimap_enabled = true
	connection_lines_curvature = 0.0
	connection_lines_thickness = 2.0
	zoom_min = DEFAULT_ZOOM_MIN
	zoom_max = 1.65
	zoom_step = 1.12
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	add_theme_color_override("grid_minor", UiTokens.COLOR_FACTORY_GRID_DOT)
	add_theme_color_override("grid_major", UiTokens.COLOR_FACTORY_GRID_DOT)
	add_theme_color_override("activity", UiTokens.COLOR_FOCUS)
	add_theme_stylebox_override("panel", UiTokens.panel_style(UiTokens.COLOR_FACTORY_CANVAS, UiTokens.COLOR_BORDER, 0))
	for port_type in [11, 12, 13, 14, 15, 16]:
		add_valid_connection_type(port_type, port_type)
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	connection_drag_started.connect(_on_connection_drag_started)
	connection_drag_ended.connect(_on_connection_drag_ended)
	delete_nodes_request.connect(_on_delete_nodes_request)
	end_node_move.connect(_on_node_move_finished)
	node_selected.connect(_on_node_selected)
	resized.connect(_on_canvas_resized)
	var fit_button := Button.new()
	fit_button.name = "ShipAssemblyFitAll"
	fit_button.text = I18n.core("ships.shipyard.fit_all", "Fit all")
	fit_button.tooltip_text = I18n.core("ships.shipyard.fit_all_tooltip", "Fit the complete ship design inside the canvas")
	fit_button.pressed.connect(fit_design)
	get_menu_hbox().add_child(fit_button)


func configure(catalog: Dictionary, draft: Dictionary = {}) -> void:
	_catalog = catalog.duplicate(true)
	clear_draft(false)
	if not draft.is_empty():
		_restore_draft(draft)
	call_deferred("fit_design")


func clear_draft(emit_change := true) -> void:
	clear_connections()
	_links.clear()
	_entities.clear()
	_socket_nodes.clear()
	_socket_glyphs.clear()
	_connection_drag_module_name = ""
	for child in get_children():
		if child is GraphNode:
			remove_child(child)
			child.queue_free()
	_next_node_serial = 1
	if emit_change:
		_emit_draft_changed()


func draft_snapshot() -> Dictionary:
	var nodes: Array[Dictionary] = []
	var plan_id := ""
	var hull_id := ""
	var node_names: Array = _entities.keys()
	node_names.sort()
	for node_name_value in node_names:
		var node_name := String(node_name_value)
		var data := _entities[node_name] as Dictionary
		var graph_node := get_node_or_null(NodePath(node_name)) as GraphNode
		if graph_node == null:
			continue
		var kind := String(data.get("kind", ""))
		if kind == "hull":
			plan_id = String(data.get("plan_id", ""))
			hull_id = String(data.get("definition_id", ""))
		nodes.append({
			"node_id":node_name,
			"kind":kind,
			"definition_id":String(data.get("definition_id", "")),
			"position":{"x":graph_node.position_offset.x, "y":graph_node.position_offset.y}
		})
	return {"plan_id":plan_id, "hull_id":hull_id, "nodes":nodes, "connections":_links.duplicate(true)}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if data is not Dictionary or not bool(data.get("ship_assembly_palette", false)):
		return false
	var kind := String(data.get("kind", ""))
	if kind == "hull":
		return not _entities.has(HULL_NODE_NAME)
	return kind == "module"


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not _can_drop_data(at_position, data):
		notice_requested.emit("HULL_ALREADY_PLACED")
		return
	var graph_position := (at_position + scroll_offset) / zoom
	if String(data.get("kind", "")) == "hull":
		_add_hull(String(data.get("plan_id", "")), graph_position)
	else:
		_add_module(String(data.get("definition_id", "")), graph_position)
	_emit_draft_changed()


func _add_hull(plan_id: String, graph_position: Vector2, requested_name := HULL_NODE_NAME) -> void:
	var plan := _catalog.get("plans", {}).get(plan_id, {}) as Dictionary
	var hull_id := String(plan.get("ship_id", ""))
	var hull := _catalog.get("hulls", {}).get(hull_id, {}) as Dictionary
	if plan.is_empty() or hull.is_empty():
		return
	var node := GraphNode.new()
	node.name = requested_name
	node.title = String(plan.get("title", plan_id))
	node.position_offset = graph_position
	var socket_schema := plan.get("assembly_sockets", []) as Array
	var socket_count := socket_schema.size()
	var board_size := Vector2(350.0 + minf(100.0, maxf(0.0, float(socket_count - 5) * 12.0)), 230.0 + minf(60.0, maxf(0.0, float(socket_count - 5) * 8.0)))
	node.custom_minimum_size = board_size
	node.draggable = true
	node.selectable = true
	node.resizable = false
	node.mouse_default_cursor_shape = Control.CURSOR_MOVE
	node.set_meta("entity_kind", "hull")
	node.set_meta("entity_id", hull_id)
	var sockets: Array[Dictionary] = []
	var summary := Label.new()
	summary.text = String(_catalog.get("hull_summary_format")) % [String(hull.get("class", "Ship")), socket_count]
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_SECONDARY)
	summary.add_theme_font_size_override("font_size", 11)
	node.add_child(summary)
	var board_surface := Control.new()
	board_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board_surface.custom_minimum_size = Vector2(board_size.x - 30.0, board_size.y - 58.0)
	node.add_child(board_surface)
	var special_definitions: Array[Dictionary] = []
	var structural_definitions: Array[Dictionary] = []
	var drive_definitions: Array[Dictionary] = []
	var core_definitions: Array[Dictionary] = []
	for socket_value in socket_schema:
		var definition := (socket_value as Dictionary).duplicate(true)
		match String(definition.get("mount_role", "SPECIAL")):
			"STRUCTURAL": structural_definitions.append(definition)
			"DRIVE": drive_definitions.append(definition)
			"CORE": core_definitions.append(definition)
			_: special_definitions.append(definition)
	for flank_index in special_definitions.size():
		var definition := special_definitions[flank_index]
		var side := flank_index % 2
		var row_index := flank_index / 2
		definition["relative_position"] = Vector2(30.0 if side == 0 else board_size.x - 66.0, 58.0 + float(row_index) * 42.0)
		sockets.append(_socket_record(definition))
	for drive_index in drive_definitions.size():
		var drive_definition := drive_definitions[drive_index]
		var drive_x := board_size.x * 0.5 + (float(drive_index) - float(drive_definitions.size() - 1) * 0.5) * 54.0 - 18.0
		drive_definition["relative_position"] = Vector2(drive_x, 36.0)
		sockets.append(_socket_record(drive_definition))
	for structural_index in structural_definitions.size():
		var structural_definition := structural_definitions[structural_index]
		var structural_x := board_size.x * float(structural_index + 1) / float(structural_definitions.size() + 1) - 18.0
		structural_definition["relative_position"] = Vector2(structural_x, board_size.y - 54.0)
		sockets.append(_socket_record(structural_definition))
	for core_index in core_definitions.size():
		var core_definition := core_definitions[core_index]
		core_definition["relative_position"] = Vector2(board_size.x * 0.5 - 34.0, board_size.y * 0.5 - 22.0)
		core_definition["major"] = true
		sockets.append(_socket_record(core_definition))
	_apply_node_style(node, UiTokens.COLOR_INFORMATION)
	add_child(node)
	_entities[String(node.name)] = {"kind":"hull", "definition_id":hull_id, "plan_id":plan_id, "sockets":sockets}
	for socket in sockets:
		_add_hull_socket_node(node, socket)
	_refresh_socket_visuals()


func _socket_record(definition: Dictionary) -> Dictionary:
	var slot := String(definition.get("slot", "utility"))
	var mount_role := String(definition.get("mount_role", "SPECIAL"))
	return {"id":String(definition.get("id", "")), "slot":slot, "mount_role":mount_role, "shape":String(definition.get("shape", _slot_shape(slot, mount_role))), "relative_position":definition.get("relative_position", Vector2.ZERO), "major":bool(definition.get("major", false))}


func _add_hull_socket_node(hull_node: GraphNode, socket: Dictionary) -> void:
	var socket_id := String(socket.get("id", ""))
	var slot := String(socket.get("slot", "utility"))
	var shape := String(socket.get("shape", _slot_shape(slot, String(socket.get("mount_role", "")))))
	var major := bool(socket.get("major", false))
	var socket_node := GraphNode.new()
	socket_node.name = "ship_design_%s" % socket_id
	socket_node.title = ""
	socket_node.position_offset = hull_node.position_offset + (socket.get("relative_position", Vector2.ZERO) as Vector2)
	socket_node.custom_minimum_size = Vector2(78.0, 78.0) if major else Vector2(42.0, 42.0)
	socket_node.draggable = false
	socket_node.selectable = false
	socket_node.resizable = false
	socket_node.mouse_default_cursor_shape = Control.CURSOR_CROSS
	socket_node.z_index = 4
	socket_node.set_meta("entity_kind", "socket")
	socket_node.set_meta("socket_id", socket_id)
	var glyph_center := CenterContainer.new()
	glyph_center.custom_minimum_size = socket_node.custom_minimum_size - Vector2(12.0, 12.0)
	var glyph := ShipPortGlyphScript.new()
	glyph.configure(shape, UiTokens.COLOR_BORDER_STRONG, false)
	glyph_center.add_child(glyph)
	glyph.custom_minimum_size = Vector2(58.0, 58.0) if major else Vector2(24.0, 24.0)
	socket_node.add_child(glyph_center)
	socket_node.set_slot(0, true, _slot_port_type(slot, String(socket.get("mount_role", ""))), UiTokens.COLOR_BORDER_STRONG, false, 0, Color.WHITE)
	_apply_socket_style(socket_node, UiTokens.COLOR_BORDER_STRONG, major)
	add_child(socket_node)
	_socket_nodes[socket_id] = String(socket_node.name)
	_socket_glyphs[socket_id] = glyph
	socket_node.tooltip_text = String(_catalog.get("core_socket_format")) % (int(socket_id.get_slice("_", 2)) + 1) if slot == "core" else String(_catalog.get("socket_label_format")) % [String(_catalog.get("slot_labels", {}).get(slot, slot.to_upper())), int(socket_id.get_slice("_", 2)) + 1, _slot_shape(slot)]


func _add_module(module_id: String, graph_position: Vector2, requested_name := "") -> void:
	var module := _catalog.get("modules", {}).get(module_id, {}) as Dictionary
	if module.is_empty():
		return
	var slot := String(module.get("slot", "utility"))
	var mount_role := String(module.get("assembly_mount", "SPECIAL"))
	var shape := _slot_shape(slot, mount_role)
	var node_name := requested_name
	if node_name.is_empty():
		node_name = "%s%04d" % [MODULE_NODE_PREFIX, _next_node_serial]
		_next_node_serial += 1
	var node := GraphNode.new()
	node.name = node_name
	node.title = String(module.get("title", module_id))
	node.position_offset = graph_position
	node.custom_minimum_size = Vector2(210.0, 70.0)
	node.draggable = true
	node.selectable = true
	node.resizable = false
	node.mouse_default_cursor_shape = Control.CURSOR_MOVE
	node.set_meta("entity_kind", "module")
	node.set_meta("entity_id", module_id)
	var row := HBoxContainer.new()
	row.custom_minimum_size.x = 180.0
	row.add_theme_constant_override("separation", 7)
	var label := Label.new()
	label.text = String(_catalog.get("module_label_format")) % [String(module.get("size", "S")), String(_catalog.get("slot_labels", {}).get(slot, slot.to_upper())), shape]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", _slot_tone(slot))
	label.add_theme_font_size_override("font_size", 11)
	row.add_child(label)
	var glyph := ShipPortGlyphScript.new()
	glyph.configure(shape, _slot_tone(slot))
	row.add_child(glyph)
	node.add_child(row)
	node.set_slot(0, false, 0, Color.WHITE, true, _slot_port_type(slot, mount_role), _slot_tone(slot))
	_apply_node_style(node, _slot_tone(slot))
	add_child(node)
	_entities[String(node.name)] = {"kind":"module", "definition_id":module_id, "slot":slot, "mount_role":mount_role, "shape":shape}


func _restore_draft(draft: Dictionary) -> void:
	var stored_nodes := draft.get("nodes", []) as Array
	for node_value in stored_nodes:
		var data := node_value as Dictionary
		if String(data.get("kind", "")) == "hull":
			_add_hull(String(draft.get("plan_id", "")), _stored_position(data), String(data.get("node_id", HULL_NODE_NAME)))
	for node_value in stored_nodes:
		var data := node_value as Dictionary
		if String(data.get("kind", "")) == "module":
			_add_module(String(data.get("definition_id", "")), _stored_position(data), String(data.get("node_id", "")))
	for link_value in draft.get("connections", []):
		var link := link_value as Dictionary
		var module_node_id := String(link.get("module_node_id", ""))
		var socket_node_name := _socket_node_name(String(link.get("socket_id", "")))
		if _entities.has(module_node_id) and not socket_node_name.is_empty():
			connect_node(module_node_id, 0, socket_node_name, 0)
			_links.append(link.duplicate(true))


func _stored_position(data: Dictionary) -> Vector2:
	var value = data.get("position", {})
	if value is Vector2:
		return value
	if value is Dictionary:
		return Vector2(float(value.get("x", 0.0)), float(value.get("y", 0.0)))
	return Vector2.ZERO


func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var module_node_id := String(from_node)
	var socket_node := get_node_or_null(NodePath(String(to_node))) as GraphNode
	if from_port != 0 or to_port != 0 or socket_node == null or String(socket_node.get_meta("entity_kind", "")) != "socket":
		notice_requested.emit("PORT_DIRECTION_INVALID")
		return
	var module_data := _entities.get(module_node_id, {}) as Dictionary
	var hull_data := _entities.get(HULL_NODE_NAME, {}) as Dictionary
	var sockets := hull_data.get("sockets", []) as Array
	var socket_id := String(socket_node.get_meta("socket_id", ""))
	var socket := _hull_socket(socket_id)
	if String(module_data.get("kind", "")) != "module" or socket.is_empty() or not sockets.has(socket):
		notice_requested.emit("PORT_DIRECTION_INVALID")
		return
	if String(module_data.get("slot", "")) != String(socket.get("slot", "")) or String(module_data.get("mount_role", "")) != String(socket.get("mount_role", "")) or String(module_data.get("shape", "")) != String(socket.get("shape", "")):
		notice_requested.emit("PORT_SHAPE_MISMATCH")
		return
	for link in _links:
		if String(link.get("module_node_id", "")) == module_node_id or String(link.get("socket_id", "")) == String(socket.get("id", "")):
			notice_requested.emit("PORT_ALREADY_OCCUPIED")
			return
	connect_node(module_node_id, 0, String(socket_node.name), 0)
	_links.append({"module_node_id":module_node_id, "socket_id":String(socket.get("id", "")), "slot":String(socket.get("slot", "")), "shape":String(socket.get("shape", ""))})
	_refresh_socket_visuals()
	_emit_draft_changed()


func _on_disconnection_request(from_node: StringName, _from_port: int, to_node: StringName, to_port: int) -> void:
	disconnect_node(from_node, 0, to_node, to_port)
	var target := get_node_or_null(NodePath(String(to_node))) as GraphNode
	var socket_id := String(target.get_meta("socket_id", "")) if target != null else ""
	_links = _links.filter(func(link: Dictionary) -> bool:
		return String(link.get("module_node_id", "")) != String(from_node) or String(link.get("socket_id", "")) != socket_id
	)
	_refresh_socket_visuals()
	_emit_draft_changed()


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	for node_name_value in nodes:
		var node_name := String(node_name_value)
		var node := get_node_or_null(NodePath(node_name)) as GraphNode
		if node == null:
			continue
		if String(node.get_meta("entity_kind", "")) == "socket":
			continue
		_links = _links.filter(func(link: Dictionary) -> bool:
			return String(link.get("module_node_id", "")) != node_name and node_name != HULL_NODE_NAME
		)
		if node_name == HULL_NODE_NAME:
			_remove_hull_socket_nodes()
		_entities.erase(node_name)
		remove_child(node)
		node.queue_free()
	_rebuild_connections()
	_emit_draft_changed()


func _rebuild_connections() -> void:
	clear_connections()
	if not _entities.has(HULL_NODE_NAME):
		_links.clear()
		return
	var valid: Array[Dictionary] = []
	for link in _links:
		var module_node_id := String(link.get("module_node_id", ""))
		var socket_node_name := _socket_node_name(String(link.get("socket_id", "")))
		if _entities.has(module_node_id) and not socket_node_name.is_empty():
			connect_node(module_node_id, 0, socket_node_name, 0)
			valid.append(link)
	_links = valid
	_refresh_socket_visuals()


func _hull_socket_port(socket_id: String) -> int:
	return 0 if not _socket_node_name(socket_id).is_empty() else -1


func _hull_socket(socket_id: String) -> Dictionary:
	var sockets := (_entities.get(HULL_NODE_NAME, {}) as Dictionary).get("sockets", []) as Array
	for socket_value in sockets:
		var socket := socket_value as Dictionary
		if String(socket.get("id", "")) == socket_id:
			return socket
	return {}


func _socket_node_name(socket_id: String) -> String:
	var node_name := String(_socket_nodes.get(socket_id, ""))
	return node_name if not node_name.is_empty() and has_node(NodePath(node_name)) else ""


func request_module_connection(module_node_id: String, socket_id: String) -> void:
	var socket_node_name := _socket_node_name(socket_id)
	if not socket_node_name.is_empty():
		_on_connection_request(StringName(module_node_id), 0, StringName(socket_node_name), 0)


func _on_connection_drag_started(from_node: StringName, from_port: int, is_output: bool) -> void:
	var node_name := String(from_node)
	var entity := _entities.get(node_name, {}) as Dictionary
	_connection_drag_module_name = node_name if is_output and from_port == 0 and String(entity.get("kind", "")) == "module" else ""
	_refresh_socket_visuals()


func _on_connection_drag_ended() -> void:
	_connection_drag_module_name = ""
	_refresh_socket_visuals()


func _refresh_socket_visuals() -> void:
	var connected := {}
	for link in _links:
		connected[String(link.get("socket_id", ""))] = true
	for socket_value in (_entities.get(HULL_NODE_NAME, {}) as Dictionary).get("sockets", []):
		var socket := socket_value as Dictionary
		var socket_id := String(socket.get("id", ""))
		var is_connected := bool(connected.get(socket_id, false))
		var is_drag_compatible := _socket_matches_dragged_module(socket)
		var tone := _slot_tone(String(socket.get("slot", "utility"))) if is_connected or is_drag_compatible else UiTokens.COLOR_BORDER_STRONG
		var glyph = _socket_glyphs.get(socket_id)
		if is_instance_valid(glyph):
			glyph.configure(String(socket.get("shape", "SQUARE")), tone, is_connected)
		var socket_node := get_node_or_null(NodePath(_socket_node_name(socket_id))) as GraphNode
		if socket_node != null:
			socket_node.set_slot(0, true, _slot_port_type(String(socket.get("slot", "utility")), String(socket.get("mount_role", ""))), tone, false, 0, Color.WHITE)
			_apply_socket_style(socket_node, tone, bool(socket.get("major", false)))


func _socket_matches_dragged_module(socket: Dictionary) -> bool:
	if _connection_drag_module_name.is_empty():
		return false
	var module := _entities.get(_connection_drag_module_name, {}) as Dictionary
	return String(module.get("slot", "")) == String(socket.get("slot", "")) \
		and String(module.get("mount_role", "")) == String(socket.get("mount_role", "")) \
		and String(module.get("shape", "")) == String(socket.get("shape", ""))


func _get_connection_line(from_position: Vector2, to_position: Vector2) -> PackedVector2Array:
	# Mirror DSPONLINE's orthogonal belt presentation: a short lead from each
	# handle, two vertical drops, and one shared horizontal route rail.
	var direction := 1.0 if to_position.x >= from_position.x else -1.0
	var lead := minf(34.0, maxf(12.0, absf(to_position.x - from_position.x) / 4.0))
	var route_y := _connection_route_center_y(from_position, to_position)
	return PackedVector2Array([
		from_position,
		Vector2(from_position.x + lead * direction, from_position.y),
		Vector2(from_position.x + lead * direction, route_y),
		Vector2(to_position.x - lead * direction, route_y),
		Vector2(to_position.x - lead * direction, to_position.y),
		to_position
	])


func _connection_route_center_y(from_position: Vector2, to_position: Vector2) -> float:
	# DSPONLINE's auto route tests the straight corridor against node bounds,
	# then chooses the nearer upper/lower rail with a 52 px clearance.
	var left := minf(from_position.x, to_position.x)
	var right := maxf(from_position.x, to_position.x)
	var blockers: Array[Rect2] = []
	for child in get_children():
		var graph_node := child as GraphNode
		if graph_node == null or String(graph_node.get_meta("entity_kind", "")) != "module":
			continue
		var node_size := graph_node.size
		if node_size.x <= 0.0 or node_size.y <= 0.0:
			node_size = graph_node.custom_minimum_size
		var rectangle := Rect2(graph_node.position_offset, node_size)
		if rectangle.grow(6.0).has_point(from_position) or rectangle.grow(6.0).has_point(to_position):
			continue
		if rectangle.position.x > right or rectangle.end.x < left:
			continue
		var ratio := 0.5
		if right - left > 0.001:
			ratio = clampf((rectangle.position.x + rectangle.size.x * 0.5 - left) / (right - left), 0.0, 1.0)
		var direct_y := lerpf(from_position.y, to_position.y, ratio)
		if direct_y >= rectangle.position.y - 18.0 and direct_y <= rectangle.end.y + 18.0:
			blockers.append(rectangle)
	var midpoint := (from_position.y + to_position.y) * 0.5
	if blockers.is_empty():
		return snappedf(midpoint, 10.0)
	var upper := minf(from_position.y, to_position.y)
	var lower := maxf(from_position.y, to_position.y)
	for blocker in blockers:
		upper = minf(upper, blocker.position.y)
		lower = maxf(lower, blocker.end.y)
	upper -= 52.0
	lower += 52.0
	return snappedf(upper if absf(midpoint - upper) <= absf(lower - midpoint) else lower, 10.0)


func _slot_shape(slot: String, mount_role := "") -> String:
	if mount_role == "STRUCTURAL":
		return "SQUARE"
	if mount_role == "SPECIAL" and slot == "utility":
		return "PENTAGON"
	match slot:
		"weapon": return "TRIANGLE"
		"shield": return "SQUARE"
		"drive": return "DIAMOND"
		"core": return "CIRCLE"
		_: return "SQUARE"


func _slot_port_type(slot: String, mount_role := "") -> int:
	match "%s:%s" % [slot, mount_role]:
		"weapon:SPECIAL": return 11
		"shield:STRUCTURAL": return 12
		"drive:DRIVE": return 13
		"utility:SPECIAL": return 14
		"utility:STRUCTURAL": return 15
		"core:CORE": return 16
		_: return 0


func _slot_tone(slot: String) -> Color:
	match slot:
		"weapon": return UiTokens.COLOR_CRITICAL
		"shield": return UiTokens.COLOR_INFORMATION
		"drive": return UiTokens.COLOR_FOCUS
		"core": return UiTokens.COLOR_WARNING
		_: return UiTokens.COLOR_RUNNING


func _apply_node_style(node: GraphNode, tone: Color) -> void:
	# DSPONLINE factory-node: #131917 body, #41504a one-pixel border,
	# six-pixel corners and a restrained black lift shadow.
	var normal := UiTokens.panel_style(UiTokens.COLOR_NODE_SURFACE, UiTokens.COLOR_BORDER_STRONG, 6)
	normal.shadow_color = Color(0.0, 0.0, 0.0, 0.26)
	normal.shadow_size = 8
	normal.shadow_offset = Vector2(0.0, 8.0)
	var selected_fill := UiTokens.COLOR_NODE_SURFACE.lerp(UiTokens.COLOR_FOCUS, 0.07)
	var selected := UiTokens.panel_style(selected_fill, UiTokens.COLOR_FOCUS, 6)
	selected.set_border_width_all(2)
	selected.shadow_color = Color(UiTokens.COLOR_FOCUS, 0.32)
	selected.shadow_size = 4
	var titlebar := UiTokens.panel_style(UiTokens.COLOR_NODE_HEADER, UiTokens.COLOR_BORDER, 6)
	titlebar.border_width_bottom = 1
	node.add_theme_stylebox_override("panel", normal)
	node.add_theme_stylebox_override("panel_selected", selected)
	node.add_theme_stylebox_override("titlebar", titlebar)
	node.add_theme_stylebox_override("titlebar_selected", selected)
	node.add_theme_color_override("title_color", UiTokens.COLOR_TEXT)
	node.add_theme_font_size_override("title_font_size", 12)


func _apply_socket_style(node: GraphNode, tone: Color, major: bool) -> void:
	var surface := UiTokens.panel_style(Color(UiTokens.COLOR_NODE_SURFACE, 0.92 if major else 0.72), tone.darkened(0.28), 20 if major else 10)
	surface.set_border_width_all(2 if major else 1)
	var transparent_title := StyleBoxFlat.new()
	transparent_title.bg_color = Color.TRANSPARENT
	transparent_title.set_content_margin_all(0.0)
	node.add_theme_stylebox_override("panel", surface)
	node.add_theme_stylebox_override("panel_selected", surface)
	node.add_theme_stylebox_override("titlebar", transparent_title)
	node.add_theme_stylebox_override("titlebar_selected", transparent_title)
	node.add_theme_constant_override("port_h_offset", 0)


func _remove_hull_socket_nodes() -> void:
	for socket_node_name_value in _socket_nodes.values():
		var socket_node := get_node_or_null(NodePath(String(socket_node_name_value))) as GraphNode
		if socket_node != null:
			remove_child(socket_node)
			socket_node.queue_free()
	_socket_nodes.clear()
	_socket_glyphs.clear()


func _layout_hull_socket_nodes() -> void:
	var hull_node := get_node_or_null(NodePath(HULL_NODE_NAME)) as GraphNode
	if hull_node == null:
		return
	for socket_value in (_entities.get(HULL_NODE_NAME, {}) as Dictionary).get("sockets", []):
		var socket := socket_value as Dictionary
		var socket_node := get_node_or_null(NodePath(_socket_node_name(String(socket.get("id", ""))))) as GraphNode
		if socket_node != null:
			socket_node.position_offset = hull_node.position_offset + (socket.get("relative_position", Vector2.ZERO) as Vector2)


func _emit_draft_changed() -> void:
	draft_changed.emit(draft_snapshot())


func _on_node_move_finished() -> void:
	_layout_hull_socket_nodes()
	_emit_draft_changed()


func _reset_view() -> void:
	zoom = 0.82
	scroll_offset = Vector2.ZERO


func fit_design() -> void:
	var bounds := _design_bounds()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or size.x <= FIT_PADDING * 2.0 or size.y <= FIT_PADDING * 2.0:
		_reset_view()
		return
	var available := size - Vector2(FIT_PADDING * 2.0, FIT_PADDING * 2.0)
	var required_zoom := minf(available.x / bounds.size.x, available.y / bounds.size.y)
	# Designs may be deliberately spread across a large workspace.  Lower the
	# zoom floor when necessary so "Fit all" always means the whole design,
	# rather than the closest partial crop allowed by a fixed minimum zoom.
	zoom_min = minf(DEFAULT_ZOOM_MIN, maxf(0.02, required_zoom))
	zoom = clampf(required_zoom, zoom_min, minf(1.0, zoom_max))
	scroll_offset = bounds.get_center() - size / (2.0 * zoom)


func _design_bounds() -> Rect2:
	var has_bounds := false
	var bounds := Rect2()
	for child in get_children():
		var graph_node := child as GraphNode
		if graph_node == null:
			continue
		var node_size := graph_node.size
		if node_size.x <= 0.0 or node_size.y <= 0.0:
			node_size = graph_node.custom_minimum_size
		var node_bounds := Rect2(graph_node.position_offset, node_size)
		bounds = bounds.merge(node_bounds) if has_bounds else node_bounds
		has_bounds = true
	return bounds.grow(FIT_PADDING) if has_bounds else Rect2()


func _on_canvas_resized() -> void:
	if not _entities.is_empty():
		call_deferred("fit_design")


func _on_node_selected(node: Node) -> void:
	if node.has_meta("entity_kind"):
		entity_selected.emit(String(node.get_meta("entity_kind")), String(node.get_meta("entity_id")))
