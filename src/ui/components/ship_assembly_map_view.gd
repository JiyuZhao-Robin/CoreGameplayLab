class_name ShipAssemblyMapView
extends GraphEdit

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipPortGlyphScript = preload("res://src/ui/components/ship_port_glyph.gd")
const ShipHullBackplaneScript = preload("res://src/ui/components/ship_hull_backplane.gd")
const ShipHullProfiles = preload("res://src/ui/components/ship_hull_profiles.gd")
const ShipAssemblyConnectionLayerScript = preload("res://src/ui/components/ship_assembly_connection_layer.gd")

signal draft_changed(snapshot: Dictionary)
signal entity_selected(kind: String, entity_id: String)
signal notice_requested(message: String)

const HULL_NODE_NAME := "ship_design_hull"
const MODULE_NODE_PREFIX := "ship_design_module_"
const DEFAULT_ZOOM_MIN := 0.20
const FIT_PADDING := 72.0
const MODULE_CARD_SIZE := Vector2(278.0, 138.0)
const MODULE_MOVE_STRIP_HEIGHT := 28.0
const SOCKET_DROP_PADDING_PX := 30.0

var _catalog: Dictionary = {}
var _entities := {}
var _links: Array[Dictionary] = []
var _socket_nodes := {}
var _socket_glyphs := {}
var _module_glyphs := {}
var _next_node_serial := 1
var _connection_drag_module_name := ""
var _manual_connection_drag := false
var _manual_move_module_name := ""
var _manual_move_last_screen_position := Vector2.ZERO
var _manual_move_start_position := Vector2.ZERO
var _hovered_socket_id := ""
var _selected_connection_key := ""
var _visual_layer: Control
var _hull_backplane: ShipHullBackplane
var _hull_visual: ShipHullVisual
var _hull_hovered := false
var _hull_selected := false
var _invisible_port_icons := {}


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
	connection_lines_thickness = 0.0
	connection_lines_antialiased = true
	zoom_min = DEFAULT_ZOOM_MIN
	zoom_max = 1.65
	zoom_step = 1.12
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	add_theme_color_override("grid_minor", UiTokens.COLOR_SHIP_GRID_MINOR)
	add_theme_color_override("grid_major", UiTokens.COLOR_SHIP_GRID_MAJOR)
	add_theme_color_override("activity", UiTokens.COLOR_FOCUS)
	var canvas_style := UiTokens.panel_style(UiTokens.COLOR_SHIP_CANVAS, UiTokens.COLOR_BORDER, 0)
	canvas_style.shadow_color = Color(0.0, 0.0, 0.0, 0.44)
	canvas_style.shadow_size = 10
	add_theme_stylebox_override("panel", canvas_style)
	for port_type in [11, 12, 13, 14, 15, 16]:
		add_valid_connection_type(port_type, port_type)
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	connection_drag_started.connect(_on_connection_drag_started)
	connection_drag_ended.connect(_on_connection_drag_ended)
	delete_nodes_request.connect(_on_delete_nodes_request)
	end_node_move.connect(_on_node_move_finished)
	node_selected.connect(_on_node_selected)
	if has_signal("node_deselected"):
		connect("node_deselected", Callable(self, "_on_node_deselected"))
	resized.connect(_on_canvas_resized)
	gui_input.connect(_on_canvas_gui_input)
	scroll_offset_changed.connect(_on_scroll_offset_changed)
	if has_signal("zoom_changed"):
		connect("zoom_changed", Callable(self, "_on_zoom_changed"))
	add_theme_color_override("connection_hover_tint_color", Color.TRANSPARENT)
	add_theme_color_override("connection_rim_color", Color.TRANSPARENT)
	add_theme_constant_override("connection_hover_thickness", 0)
	# Keep native GraphEdit port dragging available and make its horizontal
	# pickup band forgiving. The visible connector symbol owns the same full-size
	# manual gesture; the rest of the module card is reserved for movement.
	add_theme_constant_override("port_hotzone_inner_extent", 38)
	add_theme_constant_override("port_hotzone_outer_extent", 52)
	_visual_layer = ShipAssemblyConnectionLayerScript.new()
	_visual_layer.name = "ShipAssemblyConnectionLayer"
	add_child(_visual_layer)
	_visual_layer.configure(self)
	var fit_button := Button.new()
	fit_button.name = "ShipAssemblyFitAll"
	fit_button.text = I18n.core("ships.shipyard.fit_all", "Fit all")
	fit_button.tooltip_text = I18n.core("ships.shipyard.fit_all_tooltip", "Fit the complete ship design inside the canvas")
	fit_button.pressed.connect(fit_design)
	get_menu_hbox().add_child(fit_button)


func _world_path_for_link(link: Dictionary) -> PackedVector2Array:
	var source := get_node_or_null(NodePath(String(link.get("module_node_id", "")))) as GraphNode
	var target := get_node_or_null(NodePath(_socket_node_name(String(link.get("socket_id", ""))))) as GraphNode
	if source == null or target == null or source.get_output_port_count() <= 0 or target.get_input_port_count() <= 0:
		return PackedVector2Array()
	# Route from entity centers. The connection layer sits behind both cards and
	# sockets, so the covered segment disappears naturally and the line appears
	# to leave the nearest edge without being hard-wired to the right-hand port.
	var start := _graph_node_center(source)
	var finish := _graph_node_center(target)
	return _get_entity_connection_line(source, finish, target)


func _graph_node_center(node: GraphNode) -> Vector2:
	return node.position_offset + _graph_node_size(node) * 0.5


func _graph_node_size(node: GraphNode) -> Vector2:
	var node_size := node.size
	if node_size.x <= 0.0 or node_size.y <= 0.0:
		node_size = node.custom_minimum_size
	return node_size


func _get_entity_connection_line(source: GraphNode, target_position: Vector2, target: GraphNode = null) -> PackedVector2Array:
	var source_position := _graph_node_center(source)
	var direction := 1.0 if target_position.x >= source_position.x else -1.0
	var source_rail_x := source_position.x + direction * (_graph_node_size(source).x * 0.5 + 24.0)
	var target_clearance := _graph_node_size(target).x * 0.5 + 18.0 if target != null else 18.0
	var target_rail_x := target_position.x - direction * target_clearance
	var route_y := _connection_route_center_y(source_position, target_position)
	return _rounded_orthogonal_path(PackedVector2Array([
		source_position,
		Vector2(source_rail_x, source_position.y),
		Vector2(source_rail_x, route_y),
		Vector2(target_rail_x, route_y),
		Vector2(target_rail_x, target_position.y),
		target_position
	]), 8.0)


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
	_module_glyphs.clear()
	_connection_drag_module_name = ""
	_manual_connection_drag = false
	_manual_move_module_name = ""
	_manual_move_last_screen_position = Vector2.ZERO
	_manual_move_start_position = Vector2.ZERO
	_hovered_socket_id = ""
	_selected_connection_key = ""
	_hull_backplane = null
	_hull_visual = null
	_hull_hovered = false
	_hull_selected = false
	for child in get_children():
		if child is GraphNode:
			remove_child(child)
			child.queue_free()
	_next_node_serial = 1
	_refresh_visual_layer()
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
		# Accept the gesture so _drop_data can explain why a second hull is
		# rejected instead of leaving the user with only a forbidden cursor.
		return true
	return kind == "module"


func _drop_data(at_position: Vector2, data: Variant) -> void:
	var kind := String(data.get("kind", "")) if data is Dictionary else ""
	if kind == "hull" and _entities.has(HULL_NODE_NAME):
		notice_requested.emit("HULL_ALREADY_PLACED")
		return
	if not _can_drop_data(at_position, data):
		return
	var graph_position := (at_position + scroll_offset) / zoom
	if kind == "hull":
		_add_hull(String(data.get("plan_id", "")), graph_position)
		var hull_node := get_node_or_null(NodePath(HULL_NODE_NAME)) as GraphNode
		if hull_node != null:
			hull_node.position_offset -= hull_node.custom_minimum_size * 0.5
			_layout_hull_socket_nodes()
		call_deferred("fit_design")
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
	var visual_spec := ShipHullProfiles.visual_spec(hull)
	var board_size := ShipHullProfiles.board_size(visual_spec)
	var ui_visual := (hull.get("ui_visual", {}) as Dictionary).duplicate(true)
	node.custom_minimum_size = board_size
	node.draggable = true
	node.selectable = true
	node.resizable = false
	node.mouse_default_cursor_shape = Control.CURSOR_MOVE
	node.set_meta("entity_kind", "hull")
	node.set_meta("entity_id", hull_id)
	node.z_index = 3
	var sockets: Array[Dictionary] = []
	var board_surface := ShipHullBackplaneScript.new()
	board_surface.name = "ShipHullProjection"
	board_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board_surface.custom_minimum_size = Vector2(board_size.x - 18.0, board_size.y - 18.0)
	board_surface.configure(UiTokens.COLOR_INFORMATION, visual_spec, ui_visual)
	var has_art := board_surface.has_visual_asset()
	if has_art:
		node.title = ""
	else:
		board_surface.custom_minimum_size = Vector2(board_size.x - 30.0, board_size.y - 58.0)
		var summary := Label.new()
		summary.text = I18n.core("ships.shipyard.projection_summary", "%s · L %.0fm × W %.0fm · MAX T%d / Ø%.0fm") % [String(_catalog.get("hull_summary_format")) % [String(hull.get("class", "Ship")), socket_count], float(visual_spec.get("length_m", 0.0)), float(visual_spec.get("beam_m", 0.0)), int(visual_spec.get("tier", 1)), ShipHullProfiles.socket_diameter_m(String(visual_spec.get("socket_size", "S")))]
		summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		summary.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_SECONDARY)
		summary.add_theme_font_size_override("font_size", UiTokens.font_size(11))
		node.add_child(summary)
	node.add_child(board_surface)
	var prepared_schema: Array[Dictionary] = []
	for socket_value in socket_schema:
		var definition := (socket_value as Dictionary).duplicate(true)
		if not definition.has("max_size"):
			definition["max_size"] = String(visual_spec.get("socket_size", "S"))
		definition["tier"] = ShipHullProfiles.size_tier(String(definition.get("max_size", "S")))
		definition["diameter_m"] = ShipHullProfiles.socket_diameter_m(String(definition.get("max_size", "S")))
		prepared_schema.append(definition)
	var socket_centers := ShipHullProfiles.layout_sockets(visual_spec, prepared_schema)
	var hull_rectangle := ShipHullProfiles.hull_rect(board_size, visual_spec)
	for definition in prepared_schema:
		var socket_id := String(definition.get("id", ""))
		var socket_size := ShipHullProfiles.socket_node_size(String(definition.get("max_size", "S")))
		var center_m := socket_centers.get(socket_id, Vector2(float(visual_spec.get("beam_m", 0.0)) * 0.5, float(visual_spec.get("length_m", 0.0)) * 0.5)) as Vector2
		definition["relative_position"] = hull_rectangle.position + center_m * ShipHullProfiles.WORLD_SCALE - socket_size * 0.5
		definition["major"] = String(definition.get("slot", "")) == "core" or int(definition.get("tier", 1)) >= 4
		definition["center_m"] = center_m
		sockets.append(_socket_record(definition))
	if has_art:
		_apply_art_node_style(node)
	else:
		_apply_node_style(node, UiTokens.COLOR_INFORMATION)
	_register_node_hover(node)
	add_child(node)
	_hull_backplane = board_surface
	_hull_visual = board_surface.ship_visual()
	_entities[String(node.name)] = {"kind":"hull", "definition_id":hull_id, "plan_id":plan_id, "sockets":sockets, "visual_spec":visual_spec, "art_mode":has_art}
	for socket in sockets:
		_add_hull_socket_node(node, socket)
	# GraphEdit's end_node_move signal arrives only after the pointer is released.
	# Follow the hull's position_offset signal instead so dependent sockets and
	# connection geometry remain rigidly attached throughout every drag frame.
	node.position_offset_changed.connect(_on_hull_position_offset_changed)
	_refresh_socket_visuals()
	_sync_hull_presentation()


func _socket_record(definition: Dictionary) -> Dictionary:
	var slot := String(definition.get("slot", "utility"))
	var mount_role := String(definition.get("mount_role", "SPECIAL"))
	var max_size := String(definition.get("max_size", "S"))
	return {"id":String(definition.get("id", "")), "slot":slot, "mount_role":mount_role, "shape":String(definition.get("shape", _slot_shape(slot, mount_role))), "relative_position":definition.get("relative_position", Vector2.ZERO), "center_m":definition.get("center_m", Vector2.ZERO), "max_size":max_size, "tier":int(definition.get("tier", ShipHullProfiles.size_tier(max_size))), "diameter_m":float(definition.get("diameter_m", ShipHullProfiles.socket_diameter_m(max_size))), "major":bool(definition.get("major", false))}


func _add_hull_socket_node(hull_node: GraphNode, socket: Dictionary) -> void:
	var socket_id := String(socket.get("id", ""))
	var slot := String(socket.get("slot", "utility"))
	var shape := String(socket.get("shape", _slot_shape(slot, String(socket.get("mount_role", "")))))
	var major := bool(socket.get("major", false))
	var max_size := String(socket.get("max_size", "S"))
	var tier := int(socket.get("tier", ShipHullProfiles.size_tier(max_size)))
	var diameter_m := float(socket.get("diameter_m", ShipHullProfiles.socket_diameter_m(max_size)))
	var socket_node := GraphNode.new()
	socket_node.name = "ship_design_%s" % socket_id
	socket_node.title = ""
	socket_node.position_offset = hull_node.position_offset + (socket.get("relative_position", Vector2.ZERO) as Vector2)
	socket_node.custom_minimum_size = ShipHullProfiles.socket_node_size(max_size)
	socket_node.draggable = false
	socket_node.selectable = false
	socket_node.resizable = false
	socket_node.mouse_default_cursor_shape = Control.CURSOR_CROSS
	socket_node.z_index = 4
	socket_node.set_meta("entity_kind", "socket")
	socket_node.set_meta("socket_id", socket_id)
	socket_node.visible = true
	socket_node.add_theme_icon_override("port", _invisible_port_icon_for_size(clampi(roundi(socket_node.custom_minimum_size.x), 52, 96)))
	var glyph_center := CenterContainer.new()
	glyph_center.custom_minimum_size = socket_node.custom_minimum_size - Vector2(12.0, 12.0)
	var glyph := ShipPortGlyphScript.new()
	glyph.name = "SocketGlyph_%s" % socket_id
	glyph.configure(shape, UiTokens.COLOR_BORDER_STRONG, false, "idle", tier, diameter_m)
	glyph_center.add_child(glyph)
	glyph.custom_minimum_size = Vector2.ONE * diameter_m * ShipHullProfiles.WORLD_SCALE
	socket_node.add_child(glyph_center)
	socket_node.set_slot(0, true, _slot_port_type(slot, String(socket.get("mount_role", ""))), UiTokens.COLOR_BORDER_STRONG, false, 0, Color.WHITE)
	_apply_socket_style(socket_node, UiTokens.COLOR_BORDER_STRONG, major, "idle")
	socket_node.mouse_entered.connect(_on_socket_hover_changed.bind(socket_id, true))
	socket_node.mouse_exited.connect(_on_socket_hover_changed.bind(socket_id, false))
	add_child(socket_node)
	_socket_nodes[socket_id] = String(socket_node.name)
	_socket_glyphs[socket_id] = glyph
	var base_tooltip := String(_catalog.get("core_socket_format")) % (int(socket_id.get_slice("_", 2)) + 1) if slot == "core" else String(_catalog.get("socket_label_format")) % [String(_catalog.get("slot_labels", {}).get(slot, slot.to_upper())), int(socket_id.get_slice("_", 2)) + 1, shape]
	socket_node.tooltip_text = I18n.core("ships.shipyard.socket_physical_scale", "%s · T%d / Ø%.0fm") % [base_tooltip, tier, diameter_m]


func _add_module(module_id: String, graph_position: Vector2, requested_name := "") -> void:
	var module := _catalog.get("modules", {}).get(module_id, {}) as Dictionary
	if module.is_empty():
		return
	var slot := String(module.get("slot", "utility"))
	var mount_role := String(module.get("assembly_mount", "SPECIAL"))
	var shape := _slot_shape(slot, mount_role)
	var module_size := String(module.get("size", "S"))
	var module_tier := ShipHullProfiles.size_tier(module_size)
	var module_diameter_m := ShipHullProfiles.socket_diameter_m(module_size)
	var node_name := requested_name
	if node_name.is_empty():
		node_name = "%s%04d" % [MODULE_NODE_PREFIX, _next_node_serial]
		_next_node_serial += 1
	var node := GraphNode.new()
	node.name = node_name
	node.title = ""
	node.position_offset = graph_position
	node.custom_minimum_size = Vector2(MODULE_CARD_SIZE.x, maxf(MODULE_CARD_SIZE.y, module_diameter_m * ShipHullProfiles.WORLD_SCALE + 72.0))
	# Movement is handled across the whole card except the connector symbol, so
	# disable GraphNode's title-bar-only drag gesture to avoid double movement.
	node.draggable = false
	node.selectable = true
	node.resizable = false
	node.mouse_default_cursor_shape = Control.CURSOR_CROSS
	node.set_meta("entity_kind", "module")
	node.set_meta("entity_id", module_id)
	node.z_index = 3
	node.add_theme_icon_override("port", _invisible_port_icon_for_size(56))
	var card := HBoxContainer.new()
	card.name = "ModuleCardSurface"
	card.custom_minimum_size = Vector2(244.0, maxf(108.0, node.custom_minimum_size.y - MODULE_MOVE_STRIP_HEIGHT))
	card.add_theme_constant_override("separation", 9)
	card.add_child(_build_module_thumbnail(module, slot, shape, module_tier, module_diameter_m))
	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.size_flags_vertical = Control.SIZE_EXPAND_FILL
	identity.alignment = BoxContainer.ALIGNMENT_CENTER
	identity.add_theme_constant_override("separation", 3)
	var name_label := Label.new()
	name_label.name = "ModuleName"
	name_label.text = String(module.get("title", module_id))
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_color_override("font_color", UiTokens.COLOR_TEXT)
	name_label.add_theme_font_size_override("font_size", UiTokens.font_size(14))
	identity.add_child(name_label)
	var slot_label := Label.new()
	slot_label.text = String(_catalog.get("slot_labels", {}).get(slot, slot.to_upper()))
	slot_label.add_theme_color_override("font_color", _slot_tone(slot))
	slot_label.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	identity.add_child(slot_label)
	var id_label := Label.new()
	id_label.text = module_id.replace("_", " ").to_upper()
	id_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	id_label.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	id_label.add_theme_font_size_override("font_size", UiTokens.font_size(8))
	identity.add_child(id_label)
	var label := Label.new()
	label.text = I18n.core("ships.shipyard.module_physical_scale", "%s · T%d / Ø%.0fm") % [String(_catalog.get("module_label_format")) % [module_size, String(_catalog.get("slot_labels", {}).get(slot, slot.to_upper())), shape], module_tier, module_diameter_m]
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_color_override("font_color", _slot_tone(slot))
	label.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	identity.add_child(label)
	card.add_child(identity)
	var glyph_frame := PanelContainer.new()
	glyph_frame.name = "ModuleConnectionSurface"
	glyph_frame.custom_minimum_size = Vector2.ONE * maxf(56.0, module_diameter_m * ShipHullProfiles.WORLD_SCALE + 12.0)
	var glyph_frame_style := UiTokens.panel_style(UiTokens.COLOR_INSET, _slot_tone(slot).darkened(0.32), 5)
	glyph_frame_style.shadow_color = Color(_slot_tone(slot), 0.10)
	glyph_frame_style.shadow_size = 4
	glyph_frame.add_theme_stylebox_override("panel", glyph_frame_style)
	var glyph := ShipPortGlyphScript.new()
	glyph.name = "ModuleConnectorGlyph"
	glyph.custom_minimum_size = Vector2.ONE * maxf(46.0, module_diameter_m * ShipHullProfiles.WORLD_SCALE)
	glyph.configure(shape, _slot_tone(slot), true, "idle", module_tier, module_diameter_m)
	glyph_frame.add_child(glyph)
	card.add_child(glyph_frame)
	_ignore_mouse_tree(card)
	# Only this complete symbol is a connection origin. Everything else passes
	# through to the module card's movement handler.
	glyph_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	glyph_frame.mouse_default_cursor_shape = Control.CURSOR_CROSS
	node.add_child(card)
	node.set_slot(0, false, 0, Color.WHITE, true, _slot_port_type(slot, mount_role), _slot_tone(slot))
	_apply_module_node_style(node, _slot_tone(slot))
	_register_node_hover(node)
	add_child(node)
	_entities[String(node.name)] = {"kind":"module", "definition_id":module_id, "slot":slot, "mount_role":mount_role, "shape":shape, "size":module_size, "tier":module_tier, "diameter_m":module_diameter_m}
	_module_glyphs[String(node.name)] = glyph
	node.tooltip_text = "拖动卡片主体可移动；只有右侧大接口符号用于拉线连接"
	node.gui_input.connect(_on_module_move_gui_input.bind(String(node.name), node))
	glyph_frame.gui_input.connect(_on_module_connector_gui_input.bind(String(node.name), glyph_frame))


func _build_module_thumbnail(module: Dictionary, slot: String, shape: String, tier: int, diameter_m: float) -> Control:
	var frame := PanelContainer.new()
	frame.name = "ModuleThumbnail"
	frame.custom_minimum_size = Vector2(78.0, 70.0)
	var tone := _slot_tone(slot)
	var style := UiTokens.panel_style(Color(UiTokens.COLOR_INSET, 0.96), Color(tone, 0.46), 6)
	style.shadow_color = Color(tone, 0.12)
	style.shadow_size = 7
	frame.add_theme_stylebox_override("panel", style)
	var ui_visual := module.get("ui_visual", {}) as Dictionary
	var icon_path := String(ui_visual.get("icon_texture", module.get("icon_texture", "")))
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		var texture := TextureRect.new()
		texture.name = "ModuleTexture"
		texture.texture = load(icon_path) as Texture2D
		texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.add_child(texture)
		return frame
	var center := CenterContainer.new()
	var fallback_glyph := ShipPortGlyphScript.new()
	fallback_glyph.name = "ModuleThumbnailFallback"
	fallback_glyph.custom_minimum_size = Vector2(66.0, 66.0)
	fallback_glyph.configure(shape, tone, true, "idle", tier, diameter_m)
	center.add_child(fallback_glyph)
	frame.add_child(center)
	return frame


func _ignore_mouse_tree(root: Control) -> void:
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in root.get_children():
		if child is Control:
			_ignore_mouse_tree(child as Control)


func _invisible_port_icon_for_size(side: int) -> Texture2D:
	if _invisible_port_icons.has(side):
		return _invisible_port_icons[side] as Texture2D
	# The native GraphEdit hit target is transparent and centered directly over
	# the visible connector glyph. Its dimensions match the complete symbol.
	var image := Image.create(side, side, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	var texture := ImageTexture.create_from_image(image)
	_invisible_port_icons[side] = texture
	return texture


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
	_refresh_socket_visuals()


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
	if int(module_data.get("tier", 1)) > int(socket.get("tier", 1)):
		notice_requested.emit("PORT_SIZE_MISMATCH")
		return
	for link in _links:
		if String(link.get("module_node_id", "")) == module_node_id or String(link.get("socket_id", "")) == String(socket.get("id", "")):
			notice_requested.emit("PORT_ALREADY_OCCUPIED")
			return
	connect_node(module_node_id, 0, String(socket_node.name), 0)
	_links.append({"module_node_id":module_node_id, "socket_id":String(socket.get("id", "")), "slot":String(socket.get("slot", "")), "shape":String(socket.get("shape", "")), "max_size":String(socket.get("max_size", "S")), "tier":int(socket.get("tier", 1))})
	_refresh_socket_visuals()
	var installed_glyph = _socket_glyphs.get(socket_id)
	if is_instance_valid(installed_glyph) and installed_glyph.has_method("flash_install"):
		installed_glyph.call("flash_install")
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
		_module_glyphs.erase(node_name)
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


func _on_module_connector_gui_input(event: InputEvent, module_node_id: String, connection_surface: Control) -> void:
	if event is not InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		_begin_module_card_connection(module_node_id)
		connection_surface.accept_event()
	elif _manual_connection_drag and _connection_drag_module_name == module_node_id:
		_complete_module_card_connection(get_local_mouse_position())
		connection_surface.accept_event()


func _on_module_move_gui_input(event: InputEvent, module_node_id: String, module_node: GraphNode) -> void:
	if event is not InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		_begin_module_move(module_node_id, module_node, get_local_mouse_position())
		module_node.accept_event()
	elif _manual_move_module_name == module_node_id:
		_finish_module_move()
		module_node.accept_event()


func _input(event: InputEvent) -> void:
	if _manual_connection_drag:
		if event is InputEventMouseMotion:
			_update_manual_connection_target(get_local_mouse_position())
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_complete_module_card_connection(get_local_mouse_position())
			get_viewport().set_input_as_handled()
		return
	if _manual_move_module_name.is_empty():
		return
	if event is InputEventMouseMotion:
		_update_module_move(get_local_mouse_position())
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_finish_module_move()
		get_viewport().set_input_as_handled()


func _begin_module_move(module_node_id: String, module_node: GraphNode, screen_position: Vector2) -> void:
	var entity := _entities.get(module_node_id, {}) as Dictionary
	if String(entity.get("kind", "")) != "module" or not is_instance_valid(module_node):
		return
	_manual_connection_drag = false
	_connection_drag_module_name = ""
	_hovered_socket_id = ""
	_manual_move_module_name = module_node_id
	_manual_move_last_screen_position = screen_position
	_manual_move_start_position = module_node.position_offset
	module_node.selected = true
	_refresh_socket_visuals()


func _update_module_move(screen_position: Vector2) -> void:
	if _manual_move_module_name.is_empty():
		return
	var module_node := get_node_or_null(NodePath(_manual_move_module_name)) as GraphNode
	if module_node == null:
		_manual_move_module_name = ""
		return
	var screen_delta := screen_position - _manual_move_last_screen_position
	module_node.position_offset += screen_delta / maxf(zoom, 0.01)
	_manual_move_last_screen_position = screen_position
	_refresh_visual_layer()


func _finish_module_move() -> void:
	if _manual_move_module_name.is_empty():
		return
	var module_node := get_node_or_null(NodePath(_manual_move_module_name)) as GraphNode
	var moved := module_node != null and module_node.position_offset.distance_squared_to(_manual_move_start_position) > 0.01
	_manual_move_module_name = ""
	_manual_move_last_screen_position = Vector2.ZERO
	_manual_move_start_position = Vector2.ZERO
	_refresh_visual_layer()
	if moved:
		_emit_draft_changed()


func _begin_module_card_connection(module_node_id: String) -> void:
	var entity := _entities.get(module_node_id, {}) as Dictionary
	if String(entity.get("kind", "")) != "module":
		return
	_manual_move_module_name = ""
	_manual_move_last_screen_position = Vector2.ZERO
	_manual_move_start_position = Vector2.ZERO
	_manual_connection_drag = true
	_connection_drag_module_name = module_node_id
	_update_manual_connection_target(get_local_mouse_position())
	_refresh_socket_visuals()
	_sync_hull_presentation()


func _complete_module_card_connection(screen_position: Vector2) -> void:
	if not _manual_connection_drag:
		return
	var module_node_id := _connection_drag_module_name
	# Once the preview has snapped to a compatible socket (green), retain that
	# target through mouse release. Release events can land a few pixels away
	# from the last motion event, especially while GraphEdit is zoomed/panned.
	var socket_id := _hovered_socket_id
	if socket_id.is_empty() or not _socket_matches_dragged_module(_hull_socket(socket_id)):
		socket_id = _socket_at_screen_position(screen_position)
	_manual_connection_drag = false
	if not module_node_id.is_empty() and not socket_id.is_empty():
		var socket_node_name := _socket_node_name(socket_id)
		if not socket_node_name.is_empty():
			_on_connection_request(StringName(module_node_id), 0, StringName(socket_node_name), 0)
	_connection_drag_module_name = ""
	_hovered_socket_id = ""
	_refresh_socket_visuals()
	_sync_hull_presentation()


func _update_manual_connection_target(screen_position: Vector2) -> void:
	var socket_id := _socket_at_screen_position(screen_position)
	if socket_id == _hovered_socket_id:
		_refresh_visual_layer()
		return
	_hovered_socket_id = socket_id
	_refresh_socket_visuals()


func _socket_at_screen_position(screen_position: Vector2) -> String:
	var closest_id := ""
	var closest_distance := INF
	for socket_id_value in _socket_nodes.keys():
		var socket_id := String(socket_id_value)
		var socket_node := get_node_or_null(NodePath(_socket_node_name(socket_id))) as GraphNode
		if socket_node == null or not socket_node.visible:
			continue
		var screen_rect := Rect2(socket_node.position_offset * zoom - scroll_offset, _graph_node_size(socket_node) * zoom)
		if not screen_rect.grow(SOCKET_DROP_PADDING_PX).has_point(screen_position):
			continue
		var distance := screen_position.distance_squared_to(screen_rect.get_center())
		if distance < closest_distance:
			closest_distance = distance
			closest_id = socket_id
	return closest_id


func _on_connection_drag_started(from_node: StringName, from_port: int, is_output: bool) -> void:
	var node_name := String(from_node)
	var entity := _entities.get(node_name, {}) as Dictionary
	_manual_connection_drag = false
	_manual_move_module_name = ""
	_manual_move_last_screen_position = Vector2.ZERO
	_manual_move_start_position = Vector2.ZERO
	_connection_drag_module_name = node_name if is_output and from_port == 0 and String(entity.get("kind", "")) == "module" else ""
	_hovered_socket_id = ""
	_refresh_socket_visuals()
	_sync_hull_presentation()


func _on_connection_drag_ended() -> void:
	# GraphEdit only emits connection_request when release lands in its internal
	# port rectangle. Our green snapped preview deliberately has a larger target,
	# so preserve that accepted target and commit it after native signal dispatch.
	var module_node_id := _connection_drag_module_name
	var socket_id := _hovered_socket_id
	var should_commit_green_target := not module_node_id.is_empty() \
		and not socket_id.is_empty() \
		and _socket_matches_dragged_module(_hull_socket(socket_id))
	_manual_connection_drag = false
	_connection_drag_module_name = ""
	_hovered_socket_id = ""
	_refresh_socket_visuals()
	_sync_hull_presentation()
	if should_commit_green_target:
		_commit_green_drag_target.call_deferred(module_node_id, socket_id)


func _commit_green_drag_target(module_node_id: String, socket_id: String) -> void:
	# A native connection_request may already have succeeded earlier in the same
	# input dispatch. In that case the fallback is intentionally a no-op.
	for link in _links:
		if String(link.get("module_node_id", "")) == module_node_id or String(link.get("socket_id", "")) == socket_id:
			return
	request_module_connection(module_node_id, socket_id)


func _refresh_socket_visuals() -> void:
	var connected := {}
	for link in _links:
		connected[String(link.get("socket_id", ""))] = true
	for socket_value in (_entities.get(HULL_NODE_NAME, {}) as Dictionary).get("sockets", []):
		var socket := socket_value as Dictionary
		var socket_id := String(socket.get("id", ""))
		var is_connected := bool(connected.get(socket_id, false))
		var is_drag_compatible := _socket_matches_dragged_module(socket)
		var state := "connected" if is_connected else ("compatible" if is_drag_compatible else ("incompatible" if socket_id == _hovered_socket_id and not _connection_drag_module_name.is_empty() else ("muted" if not _connection_drag_module_name.is_empty() else ("hover" if socket_id == _hovered_socket_id else "idle"))))
		var tone := _slot_tone(String(socket.get("slot", "utility"))) if is_connected or is_drag_compatible else UiTokens.COLOR_BORDER_STRONG
		var glyph = _socket_glyphs.get(socket_id)
		if is_instance_valid(glyph):
			glyph.configure(String(socket.get("shape", "SQUARE")), tone, is_connected, state, int(socket.get("tier", 1)), float(socket.get("diameter_m", 5.0)))
		var socket_node := get_node_or_null(NodePath(_socket_node_name(socket_id))) as GraphNode
		if socket_node != null:
			socket_node.set_slot(0, true, _slot_port_type(String(socket.get("slot", "utility")), String(socket.get("mount_role", ""))), tone, false, 0, Color.WHITE)
			socket_node.modulate.a = 0.34 if state == "muted" else 1.0
			_apply_socket_style(socket_node, tone, bool(socket.get("major", false)), state)
	var connected_modules := {}
	for link in _links:
		connected_modules[String(link.get("module_node_id", ""))] = true
	for node_name_value in _module_glyphs.keys():
		var node_name := String(node_name_value)
		var module := _entities.get(node_name, {}) as Dictionary
		var glyph = _module_glyphs.get(node_name)
		var state := "origin" if node_name == _connection_drag_module_name else ("connected" if bool(connected_modules.get(node_name, false)) else "idle")
		if is_instance_valid(glyph):
			glyph.configure(String(module.get("shape", "SQUARE")), _slot_tone(String(module.get("slot", "utility"))), state == "connected" or state == "origin", state, int(module.get("tier", 1)), float(module.get("diameter_m", 5.0)))
		var module_node := get_node_or_null(NodePath(node_name)) as GraphNode
		if module_node != null:
			_apply_module_node_style(module_node, _slot_tone(String(module.get("slot", "utility"))))
	_refresh_visual_layer()


func _socket_matches_dragged_module(socket: Dictionary) -> bool:
	if _connection_drag_module_name.is_empty():
		return false
	var module := _entities.get(_connection_drag_module_name, {}) as Dictionary
	var socket_id := String(socket.get("id", ""))
	for link in _links:
		if String(link.get("module_node_id", "")) == _connection_drag_module_name or String(link.get("socket_id", "")) == socket_id:
			return false
	return not socket_id.is_empty() \
		and String(module.get("slot", "")) == String(socket.get("slot", "")) \
		and String(module.get("mount_role", "")) == String(socket.get("mount_role", "")) \
		and String(module.get("shape", "")) == String(socket.get("shape", "")) \
		and int(module.get("tier", 1)) <= int(socket.get("tier", 1))


func _get_connection_line(from_position: Vector2, to_position: Vector2) -> PackedVector2Array:
	return _rounded_orthogonal_path(_orthogonal_connection_points(from_position, to_position), 8.0)


func _orthogonal_connection_points(from_position: Vector2, to_position: Vector2) -> PackedVector2Array:
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


func _rounded_orthogonal_path(points: PackedVector2Array, radius: float) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var compact := PackedVector2Array()
	for point in points:
		if compact.is_empty() or compact[compact.size() - 1].distance_squared_to(point) > 0.01:
			compact.append(point)
	if compact.size() < 3:
		return compact
	var result := PackedVector2Array([compact[0]])
	for index in range(1, compact.size() - 1):
		var previous := compact[index - 1]
		var corner := compact[index]
		var next := compact[index + 1]
		var incoming := corner - previous
		var outgoing := next - corner
		var incoming_length := incoming.length()
		var outgoing_length := outgoing.length()
		if incoming_length <= 0.01 or outgoing_length <= 0.01:
			continue
		var corner_radius := minf(radius, minf(incoming_length * 0.5, outgoing_length * 0.5))
		var before := corner - incoming / incoming_length * corner_radius
		var after := corner + outgoing / outgoing_length * corner_radius
		result.append(before)
		for sample_index in range(1, 5):
			var t := float(sample_index) / 4.0
			result.append(before * (1.0 - t) * (1.0 - t) + corner * 2.0 * (1.0 - t) * t + after * t * t)
	result.append(compact[compact.size() - 1])
	return result


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
	var hovered := bool(node.get_meta("visual_hovered", false))
	var border := UiTokens.COLOR_BORDER_STRONG.lerp(tone, 0.26)
	if hovered:
		border = tone.lerp(Color.WHITE, 0.08)
	var normal := UiTokens.panel_style(UiTokens.COLOR_NODE_SURFACE, border, 6)
	normal.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
	normal.shadow_size = 12 if hovered else 9
	normal.shadow_offset = Vector2(0.0, 8.0)
	if hovered:
		normal.set_border_width_all(2)
	var selected_fill := UiTokens.COLOR_NODE_SURFACE.lerp(UiTokens.COLOR_FOCUS, 0.07)
	var selected := UiTokens.panel_style(selected_fill, UiTokens.COLOR_FOCUS, 6)
	selected.set_border_width_all(2)
	selected.set_expand_margin_all(2.0)
	selected.shadow_color = Color(UiTokens.COLOR_FOCUS, 0.30)
	selected.shadow_size = 10
	selected.shadow_offset = Vector2(0.0, 5.0)
	var titlebar := UiTokens.panel_style(UiTokens.COLOR_NODE_HEADER, border.darkened(0.18), 6)
	titlebar.border_width_top = 2
	titlebar.border_color = border
	titlebar.border_width_bottom = 1
	var titlebar_selected := UiTokens.panel_style(UiTokens.COLOR_NODE_HEADER.lerp(UiTokens.COLOR_FOCUS, 0.05), UiTokens.COLOR_FOCUS, 6)
	titlebar_selected.border_width_top = 2
	titlebar_selected.border_width_bottom = 1
	node.add_theme_stylebox_override("panel", normal)
	node.add_theme_stylebox_override("panel_selected", selected)
	node.add_theme_stylebox_override("titlebar", titlebar)
	node.add_theme_stylebox_override("titlebar_selected", titlebar_selected)
	node.add_theme_color_override("title_color", UiTokens.COLOR_TEXT)
	node.add_theme_color_override("title_selected_color", UiTokens.COLOR_TEXT)
	node.add_theme_font_size_override("title_font_size", UiTokens.font_size(12))


func _apply_module_node_style(node: GraphNode, tone: Color) -> void:
	_apply_node_style(node, tone)
	# The name and metadata live inside one coherent card. Keep a transparent
	# title strip only as a familiar place to move the module around the canvas.
	var move_strip := StyleBoxFlat.new()
	move_strip.bg_color = Color.TRANSPARENT
	move_strip.set_content_margin(SIDE_LEFT, 0.0)
	move_strip.set_content_margin(SIDE_RIGHT, 0.0)
	move_strip.set_content_margin(SIDE_TOP, 9.0)
	move_strip.set_content_margin(SIDE_BOTTOM, 9.0)
	node.add_theme_stylebox_override("titlebar", move_strip)
	node.add_theme_stylebox_override("titlebar_selected", move_strip)
	node.add_theme_color_override("title_color", Color.TRANSPARENT)
	node.add_theme_color_override("title_selected_color", Color.TRANSPARENT)
	node.add_theme_font_size_override("title_font_size", 1)
	# Align the native output port with the large visible symbol inside the card.
	node.add_theme_constant_override("port_h_offset", 32)


func _apply_art_node_style(node: GraphNode) -> void:
	var empty := StyleBoxEmpty.new()
	empty.set_content_margin_all(0.0)
	node.add_theme_stylebox_override("panel", empty)
	node.add_theme_stylebox_override("panel_selected", empty)
	node.add_theme_stylebox_override("titlebar", empty)
	node.add_theme_stylebox_override("titlebar_selected", empty)
	node.add_theme_color_override("title_color", Color.TRANSPARENT)
	node.add_theme_color_override("title_selected_color", Color.TRANSPARENT)
	node.add_theme_font_size_override("title_font_size", 1)


func _apply_socket_style(node: GraphNode, tone: Color, major: bool, state: String) -> void:
	var surface_alpha := 0.96 if major else 0.82
	var border := tone.darkened(0.28)
	if state in ["connected", "compatible", "hover"]:
		border = tone.lightened(0.08)
	var surface := UiTokens.panel_style(Color(UiTokens.COLOR_NODE_SURFACE, surface_alpha), border, 16 if major else 8)
	surface.set_border_width_all(2 if major or state in ["connected", "compatible"] else 1)
	surface.shadow_color = Color(tone, 0.28 if state == "compatible" else (0.18 if state == "connected" else 0.06))
	surface.shadow_size = 12 if state == "compatible" else (8 if state == "connected" else 3)
	var transparent_title := StyleBoxFlat.new()
	transparent_title.bg_color = Color.TRANSPARENT
	transparent_title.set_content_margin_all(0.0)
	node.add_theme_stylebox_override("panel", surface)
	node.add_theme_stylebox_override("panel_selected", surface)
	node.add_theme_stylebox_override("titlebar", transparent_title)
	node.add_theme_stylebox_override("titlebar_selected", transparent_title)
	# Move the native input port from the left edge to the center of the complete
	# socket glyph, so its whole visible area accepts the connection drop.
	node.add_theme_constant_override("port_h_offset", roundi(_graph_node_size(node).x * 0.5))


func _register_node_hover(node: GraphNode) -> void:
	node.mouse_entered.connect(_on_visual_node_hover_changed.bind(node, true))
	node.mouse_exited.connect(_on_visual_node_hover_changed.bind(node, false))


func _on_visual_node_hover_changed(node: GraphNode, hovered: bool) -> void:
	if not is_instance_valid(node):
		return
	node.set_meta("visual_hovered", hovered)
	var entity := _entities.get(String(node.name), {}) as Dictionary
	if bool(entity.get("art_mode", false)):
		_hull_hovered = hovered
		_apply_art_node_style(node)
		_sync_hull_presentation()
		return
	var tone := UiTokens.COLOR_INFORMATION if String(entity.get("kind", "")) == "hull" else _slot_tone(String(entity.get("slot", "utility")))
	if String(entity.get("kind", "")) == "module":
		_apply_module_node_style(node, tone)
	else:
		_apply_node_style(node, tone)


func _on_socket_hover_changed(socket_id: String, hovered: bool) -> void:
	if hovered:
		_hovered_socket_id = socket_id
	elif _hovered_socket_id == socket_id:
		_hovered_socket_id = ""
	_refresh_socket_visuals()


func _connection_key(from_node: String, to_node: String) -> String:
	return "%s>%s" % [from_node, to_node]


func _on_canvas_gui_input(event: InputEvent) -> void:
	if event is not InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not _connection_drag_module_name.is_empty():
		return
	_select_connection_at(event.position)


func _select_connection_at(screen_position: Vector2) -> bool:
	var closest_key := ""
	var closest_distance := 9.0
	for link in _links:
		var path := _world_path_for_link(link)
		for index in path.size() - 1:
			var start := path[index] * zoom - scroll_offset
			var finish := path[index + 1] * zoom - scroll_offset
			var distance := _distance_to_segment(screen_position, start, finish)
			if distance <= closest_distance:
				closest_distance = distance
				closest_key = _connection_key(String(link.get("module_node_id", "")), _socket_node_name(String(link.get("socket_id", ""))))
	var changed := closest_key != _selected_connection_key
	_selected_connection_key = closest_key
	if changed and is_instance_valid(_visual_layer):
		_visual_layer.queue_redraw()
	return not closest_key.is_empty()


func _distance_to_segment(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.001:
		return point.distance_to(start)
	var t := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * t)


func _on_zoom_changed(_value: float) -> void:
	_sync_hull_presentation()
	_refresh_visual_layer()


func _on_scroll_offset_changed(_offset: Vector2) -> void:
	_refresh_visual_layer()


func _refresh_visual_layer() -> void:
	if is_instance_valid(_visual_layer):
		_visual_layer.call("refresh")


func _remove_hull_socket_nodes() -> void:
	for socket_node_name_value in _socket_nodes.values():
		var socket_node := get_node_or_null(NodePath(String(socket_node_name_value))) as GraphNode
		if socket_node != null:
			remove_child(socket_node)
			socket_node.queue_free()
	_socket_nodes.clear()
	_socket_glyphs.clear()
	_hull_backplane = null
	_hull_visual = null
	_hull_hovered = false
	_hull_selected = false


func _layout_hull_socket_nodes() -> void:
	var hull_node := get_node_or_null(NodePath(HULL_NODE_NAME)) as GraphNode
	if hull_node == null:
		return
	for socket_value in (_entities.get(HULL_NODE_NAME, {}) as Dictionary).get("sockets", []):
		var socket := socket_value as Dictionary
		var socket_node := get_node_or_null(NodePath(_socket_node_name(String(socket.get("id", ""))))) as GraphNode
		if socket_node != null:
			socket_node.position_offset = hull_node.position_offset + (socket.get("relative_position", Vector2.ZERO) as Vector2)


func _on_hull_position_offset_changed() -> void:
	_layout_hull_socket_nodes()
	# refresh() also invalidates the route cache, so established connection paths
	# are rebuilt from the newly moved socket positions in this same frame.
	_refresh_visual_layer()


func _emit_draft_changed() -> void:
	draft_changed.emit(draft_snapshot())


func _on_node_move_finished() -> void:
	_layout_hull_socket_nodes()
	_refresh_visual_layer()
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
	# zoom floor when necessary so the command always includes the whole design,
	# rather than the closest partial crop allowed by a fixed minimum zoom.
	zoom_min = minf(DEFAULT_ZOOM_MIN, maxf(0.02, required_zoom))
	zoom = clampf(required_zoom, zoom_min, minf(1.0, zoom_max))
	# GraphEdit's scroll offset is expressed in rendered canvas pixels.  Center
	# the world-space design after applying zoom, matching drop/hit-test math.
	scroll_offset = bounds.get_center() * zoom - size * 0.5
	_refresh_visual_layer()


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
		if String(node.get_meta("entity_kind", "")) == "hull":
			_hull_selected = true
			_sync_hull_presentation()
		entity_selected.emit(String(node.get_meta("entity_kind")), String(node.get_meta("entity_id")))


func _on_node_deselected(node: Node) -> void:
	if node.has_meta("entity_kind") and String(node.get_meta("entity_kind", "")) == "hull":
		_hull_selected = false
		_sync_hull_presentation()


func _sync_hull_presentation() -> void:
	if is_instance_valid(_hull_backplane):
		_hull_backplane.set_presentation_state(_hull_hovered, _hull_selected, zoom, 1.0 if not _connection_drag_module_name.is_empty() else 0.0)
