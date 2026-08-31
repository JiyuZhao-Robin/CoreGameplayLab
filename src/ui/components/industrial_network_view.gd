class_name IndustrialNetworkView
extends VBoxContainer

signal entity_selected(node: Dictionary)
signal entity_activated(node: Dictionary)
signal preferences_changed(preferences: Dictionary)
signal reduced_motion_changed(enabled: bool)

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const NodeScript = preload("res://src/ui/components/industrial_network_node.gd")
const EdgeLayerScript = preload("res://src/ui/components/industrial_network_edge_layer.gd")

var _graph: GraphEdit
var _edge_layer: IndustrialNetworkEdgeLayer
var _canvas: Control
var _nodes := {}
var _node_signatures := {}
var _projection: Dictionary = {}
var _preferences: Dictionary = {}
var _location_id := ""
var _selected_node_id := ""
var _hovered_node_id := ""
var _reduced_motion := false
var _simulation_paused := false
var _product_filter := ""
var _focus_mode := ""
var _product_selector: OptionButton
var _product_ids: Array[String] = []
var _bottleneck_button: Button
var _reduced_motion_toggle: CheckButton
var _camera_tween: Tween
var _space_held := false
var _space_panning := false
var _last_pointer := Vector2.ZERO
var _visual_time := 0.0
var _last_geometry_revision := 0
var _pending_initial_fit := false
var _applying_projection := false


func build(preferences: Dictionary = {}, reduced_motion := false) -> void:
	_preferences = _sanitize_preferences(preferences)
	_reduced_motion = reduced_motion
	add_theme_constant_override("separation", 6)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_build_toolbar())

	_canvas = Control.new()
	_canvas.name = "IndustrialNetworkCanvas"
	_canvas.custom_minimum_size.y = 280
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.clip_contents = true
	add_child(_canvas)

	_edge_layer = EdgeLayerScript.new()
	_canvas.add_child(_edge_layer)
	_edge_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_graph = GraphEdit.new()
	_graph.name = "IndustrialNetworkGraph"
	_graph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_graph.show_menu = false
	_graph.show_arrange_button = false
	_graph.show_grid = false
	_graph.minimap_enabled = false
	_graph.right_disconnects = false
	_graph.zoom_min = 0.35
	_graph.zoom_max = 1.65
	_graph.zoom_step = 1.12
	_graph.add_valid_connection_type(0, 0)
	var transparent := StyleBoxFlat.new()
	transparent.bg_color = Color.TRANSPARENT
	transparent.border_width_left = 0
	transparent.border_width_right = 0
	transparent.border_width_top = 0
	transparent.border_width_bottom = 0
	_graph.add_theme_stylebox_override("panel", transparent)
	_canvas.add_child(_graph)
	_edge_layer.configure(_graph)
	_graph.node_selected.connect(_on_graph_node_selected)
	_graph.node_deselected.connect(_on_graph_node_deselected)
	_graph.scroll_offset_changed.connect(_on_viewport_changed)
	_graph.resized.connect(_on_graph_resized)
	_graph.gui_input.connect(_on_graph_gui_input)
	set_process(true)


func apply_projection(projection: Dictionary) -> void:
	_applying_projection = true
	_projection = projection.duplicate(true)
	var next_location := str(projection.get("location_id", ""))
	var location_changed := next_location != _location_id
	_location_id = next_location
	var expected := {}
	for node_value in projection.get("nodes", []):
		var node_data := node_value as Dictionary
		var node_id := str(node_data.get("id", ""))
		expected[node_id] = true
		var signature := JSON.stringify(node_data)
		var visual_node = _nodes.get(node_id) as IndustrialNetworkNode
		if not is_instance_valid(visual_node):
			visual_node = NodeScript.new()
			visual_node.configure(node_data)
			_graph.add_child(visual_node)
			_nodes[node_id] = visual_node
			_node_signatures[node_id] = signature
			visual_node.activated.connect(_activate_node)
			visual_node.hover_changed.connect(_on_node_hover_changed)
			visual_node.position_offset_changed.connect(_on_node_position_changed.bind(node_id))
			_restore_or_place_node(visual_node, node_data)
		else:
			if str(_node_signatures.get(node_id, "")) != signature:
				visual_node.apply_projection(node_data)
				_node_signatures[node_id] = signature
	for existing_id_value in _nodes.keys():
		var existing_id := str(existing_id_value)
		if expected.has(existing_id):
			continue
		var stale = _nodes.get(existing_id) as IndustrialNetworkNode
		if is_instance_valid(stale):
			_graph.remove_child(stale)
			stale.queue_free()
		_nodes.erase(existing_id)
		_node_signatures.erase(existing_id)
		if _selected_node_id == existing_id:
			_selected_node_id = ""
	if location_changed:
		_pending_initial_fit = not _restore_viewport()
	_refresh_product_selector()
	_edge_layer.set_graph_data(projection.get("edges", []), _nodes)
	call_deferred("_refresh_edge_geometry_after_layout")
	_edge_layer.set_reduced_motion(_reduced_motion)
	_edge_layer.set_simulation_paused(_simulation_paused)
	_apply_focus()
	_last_geometry_revision += 1
	if _selected_node_id.is_empty() and not _nodes.is_empty() and location_changed and _pending_initial_fit:
		call_deferred("_try_initial_fit")
	_applying_projection = false


func set_simulation_paused(paused: bool) -> void:
	_simulation_paused = paused
	if is_instance_valid(_edge_layer):
		_edge_layer.set_simulation_paused(paused)


func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled
	if is_instance_valid(_reduced_motion_toggle):
		_reduced_motion_toggle.set_pressed_no_signal(enabled)
	if is_instance_valid(_edge_layer):
		_edge_layer.set_reduced_motion(enabled)


func set_visual_phase_for_capture(phase: float) -> void:
	_visual_time = fposmod(maxf(0.0, phase), 120.0)
	if is_instance_valid(_edge_layer):
		_edge_layer.set_animation_phase(_visual_time)


func selected_entity() -> Dictionary:
	return _node_data(_selected_node_id)


func select_entity(node_id: String, notify := false) -> bool:
	if not _nodes.has(node_id):
		return false
	_select_node(node_id, notify)
	return true


func clear_selection() -> bool:
	if _focus_mode.is_empty() and _product_filter.is_empty() and _selected_node_id.is_empty():
		return false
	if not _focus_mode.is_empty() or not _product_filter.is_empty():
		_focus_mode = ""
		_product_filter = ""
		if is_instance_valid(_product_selector):
			_product_selector.select(0)
		_apply_focus()
		_emit_preferences()
		return true
	if not _selected_node_id.is_empty():
		var selected = _nodes.get(_selected_node_id) as IndustrialNetworkNode
		if is_instance_valid(selected):
			selected.selected = false
		_selected_node_id = ""
		_edge_layer.set_selected_node("")
		return true
	return false


func export_preferences() -> Dictionary:
	_store_viewport()
	var positions := _preferences.get("positions", {}) as Dictionary
	var location_positions: Dictionary = positions.get(_location_id, {})
	for node_id_value in _nodes.keys():
		var node_id := str(node_id_value)
		var node = _nodes[node_id] as IndustrialNetworkNode
		if is_instance_valid(node):
			location_positions[node_id] = [node.position_offset.x, node.position_offset.y]
	positions[_location_id] = location_positions
	_preferences["positions"] = positions
	_preferences["layers"] = _layer_state()
	_preferences["product_filter"] = _product_filter
	return _preferences.duplicate(true)


func auto_arrange() -> void:
	var columns := {}
	for node_value in _projection.get("nodes", []):
		var node := node_value as Dictionary
		var column := int(node.get("column", 0))
		if not columns.has(column):
			columns[column] = []
		columns[column].append(str(node.get("id", "")))
	var column_ids: Array = columns.keys()
	column_ids.sort()
	var normalized_index := 0
	for column_value in column_ids:
		var column := int(column_value)
		var ids: Array = columns[column]
		ids.sort()
		for row_index in ids.size():
			var node = _nodes.get(str(ids[row_index])) as IndustrialNetworkNode
			if not is_instance_valid(node):
				continue
			node.position_offset = Vector2(84.0 + float(normalized_index) * float(UiTokens.NETWORK_NODE_WIDTH + UiTokens.NETWORK_NODE_GAP_X), 70.0 + float(row_index) * 214.0)
		normalized_index += 1
	_edge_layer.mark_geometry_dirty()
	_emit_preferences()
	fit_all(true)


func fit_all(animated := true) -> void:
	if _nodes.is_empty() or not is_instance_valid(_graph):
		return
	var bounds := _nodes_bounds()
	var viewport_size := _graph.size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		return
	var target_zoom := clampf(minf((viewport_size.x - 96.0) / maxf(1.0, bounds.size.x), (viewport_size.y - 96.0) / maxf(1.0, bounds.size.y)), _graph.zoom_min, minf(1.1, _graph.zoom_max))
	var target_scroll := bounds.get_center() - viewport_size / (2.0 * target_zoom)
	_move_camera(target_scroll, target_zoom, animated)


func focus_selected(animated := true) -> void:
	var node = _nodes.get(_selected_node_id) as IndustrialNetworkNode
	if not is_instance_valid(node):
		return
	var target_scroll: Vector2 = node.position_offset + node.size * 0.5 - _graph.size / (2.0 * _graph.zoom)
	_move_camera(target_scroll, maxf(0.85, _graph.zoom), animated)


func focus_bottleneck(animated := true) -> void:
	var node_ids: Array = _projection.get("bottleneck_node_ids", [])
	if node_ids.is_empty():
		return
	_focus_mode = "BOTTLENECK"
	_product_filter = ""
	if is_instance_valid(_product_selector):
		_product_selector.select(0)
	_apply_focus()
	var primary_id := _primary_bottleneck_node(node_ids)
	_select_node(primary_id, true)
	_focus_node_ids(node_ids, animated, primary_id)
	_emit_preferences()


func focus_production_method(activity_id: String, animated := true) -> bool:
	for node_value in _projection.get("nodes", []):
		var node := node_value as Dictionary
		if str(node.get("kind", "")) != "PRODUCTION":
			continue
		if str((node.get("buffer", {}) as Dictionary).get("method_id", "")) != activity_id:
			continue
		var node_id := str(node.get("id", ""))
		var focus_ids: Array = [node_id]
		for edge_value in _projection.get("edges", []):
			var edge := edge_value as Dictionary
			if str(edge.get("source", "")) == node_id:
				focus_ids.append(str(edge.get("target", "")))
			elif str(edge.get("target", "")) == node_id:
				focus_ids.append(str(edge.get("source", "")))
		_select_node(node_id, true)
		_focus_node_ids(focus_ids, animated)
		return true
	return false


func _build_toolbar() -> Control:
	var toolbar := HFlowContainer.new()
	toolbar.name = "IndustrialNetworkToolbar"
	toolbar.add_theme_constant_override("h_separation", 5)
	toolbar.add_theme_constant_override("v_separation", 5)
	var arrange := _toolbar_button(I18n.core("industrial_network.auto_arrange", "Auto arrange"), auto_arrange)
	arrange.name = "IndustrialNetworkAutoArrange"
	toolbar.add_child(arrange)
	var fit := _toolbar_button(I18n.core("industrial_network.fit_all", "Fit all"), fit_all.bind(true))
	fit.name = "IndustrialNetworkFitAll"
	toolbar.add_child(fit)
	var focus := _toolbar_button(I18n.core("industrial_network.focus_selection", "Focus selection"), focus_selected.bind(true))
	focus.name = "IndustrialNetworkFocusSelection"
	toolbar.add_child(focus)
	_bottleneck_button = _toolbar_button(I18n.core("industrial_network.focus_bottleneck", "Locate bottleneck"), focus_bottleneck)
	_bottleneck_button.name = "IndustrialNetworkFocusBottleneck"
	toolbar.add_child(_bottleneck_button)
	_product_selector = OptionButton.new()
	_product_selector.name = "IndustrialNetworkProductFilter"
	_product_selector.custom_minimum_size.x = 190
	_product_selector.item_selected.connect(_on_product_selected)
	toolbar.add_child(_product_selector)
	for definition in [
		["MATERIAL", "industrial_network.layer.material"],
		["LOGISTICS", "industrial_network.layer.logistics"],
		["DEMAND", "industrial_network.layer.demand"],
		["SERVICE", "industrial_network.layer.service"]
	]:
		var toggle := CheckButton.new()
		toggle.name = "IndustrialNetworkLayer_%s" % str(definition[0])
		toggle.text = I18n.core(str(definition[1]))
		toggle.button_pressed = bool(_layer_state().get(str(definition[0]), str(definition[0])) in ["MATERIAL", "LOGISTICS", "DEMAND"])
		toggle.toggled.connect(_on_layer_toggled.bind(str(definition[0])))
		toolbar.add_child(toggle)
	_reduced_motion_toggle = CheckButton.new()
	_reduced_motion_toggle.name = "IndustrialNetworkReducedMotion"
	_reduced_motion_toggle.text = I18n.core("industrial_network.reduced_motion", "Reduce motion")
	_reduced_motion_toggle.button_pressed = _reduced_motion
	_reduced_motion_toggle.toggled.connect(_on_reduced_motion_toggled)
	toolbar.add_child(_reduced_motion_toggle)
	return toolbar


func _toolbar_button(caption: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = caption
	button.focus_mode = Control.FOCUS_ALL
	button.pressed.connect(callback)
	return button


func _restore_or_place_node(node: IndustrialNetworkNode, data: Dictionary) -> void:
	var position = _saved_position(node.node_id)
	if position is Vector2:
		node.position_offset = position
		return
	var column := int(data.get("column", 0))
	var display_column := _display_column(column)
	var row := 0
	for other_value in _nodes.values():
		var other = other_value as IndustrialNetworkNode
		if other == node or not is_instance_valid(other):
			continue
		if int(other.projection.get("column", 0)) == column:
			row += 1
	node.position_offset = Vector2(84.0 + float(display_column) * float(UiTokens.NETWORK_NODE_WIDTH + UiTokens.NETWORK_NODE_GAP_X), 70.0 + float(row) * 214.0)


func _display_column(raw_column: int) -> int:
	var columns := {}
	for node_value in _projection.get("nodes", []):
		columns[int((node_value as Dictionary).get("column", 0))] = true
	var ordered: Array = columns.keys()
	ordered.sort()
	return maxi(0, ordered.find(raw_column))


func _saved_position(node_id: String):
	var positions: Dictionary = _preferences.get("positions", {})
	var location_positions: Dictionary = positions.get(_location_id, {}) if positions.has(_location_id) and positions[_location_id] is Dictionary else {}
	var raw = location_positions.get(node_id, null)
	if raw is Array and raw.size() == 2:
		if typeof(raw[0]) in [TYPE_FLOAT, TYPE_INT] and typeof(raw[1]) in [TYPE_FLOAT, TYPE_INT]:
			var result := Vector2(float(raw[0]), float(raw[1]))
			if is_finite(result.x) and is_finite(result.y) and absf(result.x) < 1000000.0 and absf(result.y) < 1000000.0:
				return result
	return null


func _restore_viewport() -> bool:
	var viewports: Dictionary = _preferences.get("viewports", {})
	var has_saved_viewport := viewports.has(_location_id) and viewports[_location_id] is Dictionary
	var raw: Dictionary = viewports.get(_location_id, {}) if has_saved_viewport else {}
	var zoom_value := float(raw.get("zoom", 1.0))
	var scroll = raw.get("scroll", [0.0, 0.0])
	_graph.zoom = clampf(zoom_value, _graph.zoom_min, _graph.zoom_max) if is_finite(zoom_value) else 1.0
	if scroll is Array and scroll.size() == 2:
		_graph.scroll_offset = Vector2(float(scroll[0]), float(scroll[1]))
	return has_saved_viewport


func _on_graph_resized() -> void:
	if _pending_initial_fit:
		call_deferred("_try_initial_fit")


func _refresh_edge_geometry_after_layout() -> void:
	if is_instance_valid(_edge_layer):
		_edge_layer.mark_geometry_dirty()


func _try_initial_fit() -> void:
	if not _pending_initial_fit or not is_instance_valid(_graph):
		return
	if _graph.size.x <= 1.0 or _graph.size.y <= 1.0 or _nodes.is_empty():
		return
	_pending_initial_fit = false
	# The first view favors readable nodes and a clear left-to-right entry point.
	# The separate overview action remains available for lower-detail framing.
	var bounds := _nodes_bounds()
	_graph.zoom = clampf(0.68, _graph.zoom_min, _graph.zoom_max)
	_graph.scroll_offset = bounds.position - Vector2(24.0, 24.0)
	_edge_layer.mark_geometry_dirty()


func _store_viewport() -> void:
	if not is_instance_valid(_graph) or _location_id.is_empty():
		return
	var viewports: Dictionary = _preferences.get("viewports", {})
	viewports[_location_id] = {"zoom":_graph.zoom, "scroll":[_graph.scroll_offset.x, _graph.scroll_offset.y]}
	_preferences["viewports"] = viewports


func _refresh_product_selector() -> void:
	if not is_instance_valid(_product_selector):
		return
	var previous := _product_filter
	_product_selector.clear()
	_product_ids.clear()
	_product_selector.add_item(I18n.core("industrial_network.product_filter", "All products"))
	_product_ids.append("")
	for product_id_value in _projection.get("products", []):
		var product_id := str(product_id_value)
		_product_selector.add_item(_product_title(product_id))
		_product_ids.append(product_id)
		if product_id == previous:
			_product_selector.select(_product_selector.item_count - 1)


func _product_title(product_id: String) -> String:
	for node_value in _projection.get("nodes", []):
		var node := node_value as Dictionary
		if str(node.get("kind", "")) == "BUFFER" and str(node.get("domain_entity_id", "")) == product_id:
			return str(node.get("title", product_id))
	return product_id


func _on_graph_node_selected(node: Node) -> void:
	if node is IndustrialNetworkNode:
		_select_node((node as IndustrialNetworkNode).node_id, false)


func _on_graph_node_deselected(node: Node) -> void:
	if node is IndustrialNetworkNode and (node as IndustrialNetworkNode).node_id == _selected_node_id:
		_selected_node_id = ""
		_edge_layer.set_selected_node("")


func _select_node(node_id: String, emit_signal: bool) -> void:
	_selected_node_id = node_id
	for candidate_value in _nodes.values():
		var candidate = candidate_value as IndustrialNetworkNode
		if is_instance_valid(candidate):
			candidate.selected = candidate.node_id == node_id
	_edge_layer.set_selected_node(node_id)
	if emit_signal or not node_id.is_empty():
		entity_selected.emit(_node_data(node_id))


func _activate_node(node_id: String) -> void:
	_select_node(node_id, true)
	entity_activated.emit(_node_data(node_id))


func _on_node_hover_changed(node_id: String, hovered: bool) -> void:
	_hovered_node_id = node_id if hovered else ("" if _hovered_node_id == node_id else _hovered_node_id)
	_edge_layer.set_hovered_node(_hovered_node_id)


func _on_node_position_changed(node_id: String) -> void:
	if not _nodes.has(node_id):
		return
	_edge_layer.mark_geometry_dirty()
	if not _applying_projection:
		_emit_preferences()


func _on_viewport_changed(_offset: Vector2) -> void:
	_edge_layer.mark_viewport_dirty()
	if not _applying_projection:
		_emit_preferences()


func _on_product_selected(index: int) -> void:
	_product_filter = _product_ids[index] if index >= 0 and index < _product_ids.size() else ""
	_focus_mode = "PRODUCT" if not _product_filter.is_empty() else ""
	_apply_focus()
	_emit_preferences()


func _on_layer_toggled(enabled: bool, layer: String) -> void:
	var layers := _layer_state()
	layers[layer] = enabled
	_preferences["layers"] = layers
	_edge_layer.set_layer_visibility(layer, enabled)
	_emit_preferences()


func _on_reduced_motion_toggled(enabled: bool) -> void:
	set_reduced_motion(enabled)
	reduced_motion_changed.emit(enabled)
	_emit_preferences()


func _apply_focus() -> void:
	var focus_nodes: Array = []
	var focus_edges: Array = []
	if _focus_mode == "BOTTLENECK":
		focus_nodes = _projection.get("bottleneck_node_ids", [])
		focus_edges = _projection.get("bottleneck_edge_ids", [])
	elif _focus_mode == "PRODUCT" and not _product_filter.is_empty():
		var connected := {}
		for edge_value in _projection.get("edges", []):
			var edge := edge_value as Dictionary
			if str(edge.get("item_id", "")) != _product_filter:
				continue
			focus_edges.append(str(edge.get("id", "")))
			connected[str(edge.get("source", ""))] = true
			connected[str(edge.get("target", ""))] = true
		focus_nodes = connected.keys()
	for node_id_value in _nodes.keys():
		var node_id := str(node_id_value)
		var node = _nodes[node_id] as IndustrialNetworkNode
		if not is_instance_valid(node):
			continue
		if _focus_mode.is_empty():
			node.set_focus_tone("NORMAL")
		elif focus_nodes.has(node_id):
			node.set_focus_tone("BOTTLENECK" if _focus_mode == "BOTTLENECK" else "FOCUS")
		else:
			node.set_focus_tone("DIM")
	_edge_layer.set_focus(_focus_mode, focus_nodes, focus_edges)
	for layer in _layer_state().keys():
		_edge_layer.set_layer_visibility(str(layer), bool(_layer_state()[layer]))
	if is_instance_valid(_bottleneck_button):
		_bottleneck_button.disabled = (_projection.get("bottleneck_node_ids", []) as Array).is_empty()
		_bottleneck_button.tooltip_text = I18n.core("industrial_network.no_bottleneck", "No current bottleneck chain") if _bottleneck_button.disabled else str(_projection.get("primary_bottleneck", ""))


func _node_data(node_id: String) -> Dictionary:
	var node = _nodes.get(node_id) as IndustrialNetworkNode
	return node.projection.duplicate(true) if is_instance_valid(node) else {}


func _nodes_bounds() -> Rect2:
	var first := true
	var bounds := Rect2()
	for node_value in _nodes.values():
		var node = node_value as IndustrialNetworkNode
		if not is_instance_valid(node):
			continue
		var node_rect := Rect2(node.position_offset, node.size if node.size.length_squared() > 1.0 else Vector2(UiTokens.NETWORK_NODE_WIDTH, 210))
		bounds = node_rect if first else bounds.merge(node_rect)
		first = false
	return bounds.grow(36.0)


func _primary_bottleneck_node(node_ids: Array) -> String:
	for node_id_value in node_ids:
		var node_data := _node_data(str(node_id_value))
		if not (node_data.get("blocker", {}) as Dictionary).is_empty():
			return str(node_id_value)
	for node_id_value in node_ids:
		var node_data := _node_data(str(node_id_value))
		if str(node_data.get("kind", "")) == "PRODUCTION":
			return str(node_id_value)
	return str(node_ids[0]) if not node_ids.is_empty() else ""


func _focus_node_ids(node_ids: Array, animated: bool, preferred_node_id := "") -> void:
	var first := true
	var bounds := Rect2()
	for node_id_value in node_ids:
		var node = _nodes.get(str(node_id_value)) as IndustrialNetworkNode
		if not is_instance_valid(node):
			continue
		var node_size: Vector2 = node.size if node.size.length_squared() > 1.0 else Vector2(UiTokens.NETWORK_NODE_WIDTH, 210.0)
		var node_rect := Rect2(node.position_offset, node_size)
		bounds = node_rect if first else bounds.merge(node_rect)
		first = false
	if first or _graph.size.x <= 1.0 or _graph.size.y <= 1.0:
		return
	bounds = bounds.grow(42.0)
	var fit_zoom := minf((_graph.size.x - 64.0) / maxf(1.0, bounds.size.x), (_graph.size.y - 64.0) / maxf(1.0, bounds.size.y))
	var target_zoom := clampf(fit_zoom, 0.72, minf(1.05, _graph.zoom_max))
	var focus_center := bounds.get_center()
	if fit_zoom < 0.72 and not preferred_node_id.is_empty():
		var preferred = _nodes.get(preferred_node_id) as IndustrialNetworkNode
		if is_instance_valid(preferred):
			focus_center = preferred.position_offset + preferred.size * 0.5
	var target_scroll := focus_center - _graph.size / (2.0 * target_zoom)
	if not preferred_node_id.is_empty():
		var preferred = _nodes.get(preferred_node_id) as IndustrialNetworkNode
		if is_instance_valid(preferred):
			var safe_inset: float = 28.0
			var screen_left: float = (preferred.position_offset.x - target_scroll.x) * target_zoom
			var screen_right: float = (preferred.position_offset.x + preferred.size.x - target_scroll.x) * target_zoom
			if screen_left < safe_inset:
				target_scroll.x -= (safe_inset - screen_left) / target_zoom
			elif screen_right > _graph.size.x - safe_inset:
				target_scroll.x += (screen_right - (_graph.size.x - safe_inset)) / target_zoom
			# GraphNode title decorations extend slightly beyond the measured content rect.
			# Keep an extra visual gutter so CJK titles are not clipped at compact widths.
			target_scroll.x -= 48.0 / target_zoom
	_move_camera(target_scroll, target_zoom, animated)


func _move_camera(target_scroll: Vector2, target_zoom: float, animated: bool) -> void:
	if is_instance_valid(_camera_tween):
		_camera_tween.kill()
	if _reduced_motion or not animated:
		_graph.zoom = target_zoom
		_graph.scroll_offset = target_scroll
		_edge_layer.mark_viewport_dirty()
		return
	_camera_tween = create_tween().set_parallel(true)
	_camera_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_camera_tween.tween_property(_graph, "zoom", target_zoom, 0.34)
	_camera_tween.tween_property(_graph, "scroll_offset", target_scroll, 0.34)


func _on_graph_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_SPACE:
		_space_held = event.pressed
		if not _space_held:
			_space_panning = false
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and _space_held:
		_space_panning = event.pressed
		_last_pointer = event.position
		if is_instance_valid(_camera_tween):
			_camera_tween.kill()
		_graph.accept_event()
		return
	if event is InputEventMouseMotion and _space_panning:
		var delta: Vector2 = event.position - _last_pointer
		_last_pointer = event.position
		_graph.scroll_offset -= delta / maxf(0.01, _graph.zoom)
		_graph.accept_event()


func _process(delta: float) -> void:
	if not is_visible_in_tree() or not is_instance_valid(_edge_layer):
		return
	if _pending_initial_fit:
		_try_initial_fit()
	_visual_time = fmod(_visual_time + delta, 120.0)
	_edge_layer.advance_visual(delta)
	for node_value in _nodes.values():
		var node = node_value as IndustrialNetworkNode
		if is_instance_valid(node) and node.is_visible_in_tree():
			node.apply_visual_time(_visual_time, delta, _reduced_motion)


func _emit_preferences() -> void:
	preferences_changed.emit(export_preferences())


func _layer_state() -> Dictionary:
	var fallback := {"MATERIAL":true, "LOGISTICS":true, "DEMAND":true, "SERVICE":false}
	var layers = _preferences.get("layers", fallback)
	if layers is not Dictionary:
		return fallback
	var result := fallback.duplicate()
	for layer in result.keys():
		if layers.has(layer):
			result[layer] = bool(layers[layer])
	return result


func _sanitize_preferences(raw: Dictionary) -> Dictionary:
	var result := {"version":1, "positions":{}, "viewports":{}, "layers":{"MATERIAL":true, "LOGISTICS":true, "DEMAND":true, "SERVICE":false}, "product_filter":""}
	if raw.get("positions", null) is Dictionary:
		result["positions"] = raw.get("positions", {}).duplicate(true)
	if raw.get("viewports", null) is Dictionary:
		result["viewports"] = raw.get("viewports", {}).duplicate(true)
	if raw.get("layers", null) is Dictionary:
		result["layers"] = raw.get("layers", {}).duplicate(true)
	result["product_filter"] = str(raw.get("product_filter", ""))
	return result
