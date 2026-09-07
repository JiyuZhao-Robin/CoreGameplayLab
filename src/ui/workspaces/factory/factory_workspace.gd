class_name FactoryWorkspace
extends Control

## Mining/production-only workspace translated from the authorized factory
## interaction language. It has no domain dependency: the host supplies a v1
## snapshot and forwards emitted intents through its application boundary.

signal command_intent(intent: Dictionary)

const ViewModelScript = preload("res://src/ui/view_models/factory/factory_workspace_view_model.gd")
const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const PROTOCOL_VERSION := 1
const SURFACE := Color("131917")
const HEADER := Color("171e1b")
const BORDER := Color("3c4743")
const FOCUS := Color("62b5ae")
const MUTED := Color("9aa6a1")
const TEXT := Color("e6eeea")

var _view_model := ViewModelScript.new()
var _snapshot: Dictionary = {}
var _canvas
var _palette_list: VBoxContainer
var _inspector_body: VBoxContainer
var _status_label: Label
var _selected_definition_id := ""
var _selected_recipe_id := ""
var _selected_entity: Dictionary = {}
var _selected_resource: Dictionary = {}
var _selected_link: Dictionary = {}
var _selected_order: Dictionary = {}
var _reduced_motion := false
var _command_sequence := 0
var _command_session_id := ""
var _palette_signature := ""


func _ready() -> void:
	_command_session_id = "%d:%d" % [int(Time.get_unix_time_from_system() * 1000.0), get_instance_id()]
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_build_shell()
	_refresh_all()


func apply_snapshot(snapshot: Dictionary) -> void:
	var projected := _view_model.build(snapshot)
	var next_palette_signature := _palette_snapshot_signature(projected)
	var palette_changed := next_palette_signature != _palette_signature
	var had_selected_entity := not _selected_entity.is_empty()
	var had_selected_resource := not _selected_resource.is_empty()
	var had_selected_link := not _selected_link.is_empty()
	var had_selected_order := not _selected_order.is_empty()
	_snapshot = projected
	_selected_entity = _entity_by_id(str(_selected_entity.get("id", "")))
	_selected_resource = _resource_by_id(str(_selected_resource.get("id", "")))
	_selected_link = _link_by_id(str(_selected_link.get("id", "")))
	_selected_order = _order_by_id(str(_selected_order.get("id", "")))
	if not is_instance_valid(_canvas):
		return
	_canvas.apply_snapshot(_snapshot)
	_canvas.set_reduced_motion(_reduced_motion)
	if palette_changed:
		_palette_signature = next_palette_signature
		_refresh_palette()
	_refresh_status()
	var selection_invalidated := (had_selected_entity and _selected_entity.is_empty()) \
		or (had_selected_resource and _selected_resource.is_empty()) \
		or (had_selected_link and _selected_link.is_empty()) \
		or (had_selected_order and _selected_order.is_empty())
	if selection_invalidated or not _inspector_interaction_active():
		_refresh_inspector()


func clear_workspace() -> void:
	_snapshot.clear()
	_selected_definition_id = ""
	_selected_recipe_id = ""
	_selected_entity.clear()
	_selected_resource.clear()
	_selected_link.clear()
	_selected_order.clear()
	_palette_signature = ""
	if is_instance_valid(_canvas):
		_canvas.set_placement_mode(false)
	_refresh_all()


func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled
	if is_instance_valid(_canvas):
		_canvas.set_reduced_motion(enabled)


## Host or focused tests may use these gesture adapters without reaching into
## the application layer. They always emit the same command envelope as UI taps.
func request_placement(definition_id: String, origin: Vector2i, recipe_id: String = "", priority: int = 50) -> void:
	if not _valid_workspace() or definition_id.is_empty():
		return
	_emit_command("QUEUE_CONSTRUCTION", {
		"definition_id":definition_id,
		"recipe_id":recipe_id,
		"origin":{"x":origin.x, "y":origin.y},
		"priority":clampi(priority, 0, 100)
	})


func request_connection(source_id: String, target_id: String, link_kind: String, item_id: String = "", capacity_per_second: float = 1.0, priority: int = 1) -> void:
	if not _valid_workspace() or source_id.is_empty() or target_id.is_empty():
		return
	# Resource fields are visual terrain, never endpoints.
	if _entity_by_id(source_id).is_empty() or _entity_by_id(target_id).is_empty():
		return
	_emit_command("CONNECT_ENTITIES", {
		"source_id":source_id,
		"target_id":target_id,
		"link_kind":link_kind.to_upper(),
		"item_id":item_id,
		"capacity_per_second":maxf(0.01, capacity_per_second),
		"priority":clampi(priority, 0, 2)
	})


func request_remove_link(link_id: String) -> void:
	if _valid_workspace() and not _link_by_id(link_id).is_empty():
		_emit_command("REMOVE_LINK", {"link_id":link_id})


func request_fund_construction(order_id: String, storage_id: String) -> void:
	if _valid_workspace() and not _order_by_id(order_id).is_empty() and not _entity_by_id(storage_id).is_empty():
		_emit_command("FUND_CONSTRUCTION", {"order_id":order_id, "storage_id":storage_id})


func _build_shell() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var layout := HBoxContainer.new()
	layout.name = "FactoryWorkspaceLayout"
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.add_theme_constant_override("separation", 7)
	add_child(layout)

	var palette := PanelContainer.new()
	palette.name = "FactoryPalettePane"
	palette.custom_minimum_size.x = 210
	palette.size_flags_vertical = Control.SIZE_EXPAND_FILL
	palette.add_theme_stylebox_override("panel", _panel_style(SURFACE, BORDER, 5))
	var palette_margin := _margin_box(10)
	palette.add_child(palette_margin)
	var palette_content := VBoxContainer.new()
	palette_content.add_theme_constant_override("separation", 7)
	palette_margin.add_child(palette_content)
	palette_content.add_child(_heading("CONSTRUCTION", "FactoryPaletteTitle"))
	var palette_hint := _label("Select a unit, then choose an empty tile", 10, MUTED)
	palette_hint.name = "FactoryPaletteHint"
	palette_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	palette_content.add_child(palette_hint)
	var palette_scroll := ScrollContainer.new()
	palette_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	palette_content.add_child(palette_scroll)
	_palette_list = VBoxContainer.new()
	_palette_list.name = "FactoryPaletteList"
	_palette_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette_list.add_theme_constant_override("separation", 5)
	palette_scroll.add_child(_palette_list)
	layout.add_child(palette)

	var center := VBoxContainer.new()
	center.name = "FactoryCenterPane"
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_theme_constant_override("separation", 6)
	layout.add_child(center)
	var toolbar := PanelContainer.new()
	toolbar.name = "FactoryCanvasToolbar"
	toolbar.custom_minimum_size.y = 34
	toolbar.add_theme_stylebox_override("panel", _panel_style(HEADER, BORDER, 5))
	var toolbar_row := HBoxContainer.new()
	toolbar_row.add_theme_constant_override("separation", 8)
	toolbar.add_child(_margin_box(8, 5, 8, 5, toolbar_row))
	var title := _label("FACTORY GRID", 11, TEXT)
	title.name = "FactoryCanvasTitle"
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	toolbar_row.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar_row.add_child(spacer)
	_status_label = _label("Awaiting Factory snapshot", 10, MUTED)
	_status_label.name = "FactoryCanvasStatus"
	_status_label.custom_minimum_size.x = 72
	_status_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	toolbar_row.add_child(_status_label)
	center.add_child(toolbar)
	var canvas_surface := PanelContainer.new()
	canvas_surface.name = "FactoryCanvasSurface"
	canvas_surface.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_surface.add_theme_stylebox_override("panel", _panel_style(Color("0b100e"), BORDER, 5))
	_canvas = CanvasScript.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.entity_selected.connect(_on_entity_selected)
	_canvas.resource_field_selected.connect(_on_resource_selected)
	_canvas.link_selected.connect(_on_link_selected)
	_canvas.tile_selected.connect(_on_tile_selected)
	_canvas.placement_cancelled.connect(_cancel_placement)
	canvas_surface.add_child(_canvas)
	center.add_child(canvas_surface)

	var inspector := PanelContainer.new()
	inspector.name = "FactoryInspectorPane"
	inspector.custom_minimum_size.x = 280
	inspector.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector.add_theme_stylebox_override("panel", _panel_style(SURFACE, BORDER, 5))
	var inspector_margin := _margin_box(10)
	inspector.add_child(inspector_margin)
	var inspector_scroll := ScrollContainer.new()
	inspector_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_margin.add_child(inspector_scroll)
	_inspector_body = VBoxContainer.new()
	_inspector_body.name = "FactoryInspectorBody"
	_inspector_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_body.add_theme_constant_override("separation", 7)
	inspector_scroll.add_child(_inspector_body)
	layout.add_child(inspector)


func _refresh_all() -> void:
	if not is_instance_valid(_canvas):
		return
	_canvas.apply_snapshot(_snapshot)
	_canvas.set_reduced_motion(_reduced_motion)
	_palette_signature = _palette_snapshot_signature(_snapshot)
	_refresh_palette()
	_refresh_status()
	_refresh_inspector()


func _refresh_status() -> void:
	if not is_instance_valid(_status_label):
		return
	if not _valid_workspace():
		_status_label.text = "NO FACTORY WORLD"
		return
	var revision := int(_snapshot.get("topology_revision", 0))
	var entity_count := (_snapshot.get("entities", []) as Array).size()
	var link_count := (_snapshot.get("links", []) as Array).size()
	_status_label.text = "R%d · %dN · %dL" % [revision, entity_count, link_count]
	_status_label.tooltip_text = "Topology revision %d · %d entities · %d links" % [revision, entity_count, link_count]


func _refresh_palette() -> void:
	if not is_instance_valid(_palette_list):
		return
	for child in _palette_list.get_children():
		_palette_list.remove_child(child)
		child.queue_free()
	if not _valid_workspace():
		_palette_list.add_child(_label("No buildable Factory World.", 10, MUTED))
		return
	for building_value in (_snapshot.get("palette", {}) as Dictionary).get("buildings", []):
		var building := building_value as Dictionary
		var definition_id := str(building.get("id", ""))
		var button := Button.new()
		button.name = "FactoryPalette_%s" % definition_id
		button.text = "%s\n%s · %dx%d" % [str(building.get("name", definition_id)), str(building.get("kind", "UNIT")), int((building.get("footprint", {}) as Dictionary).get("width", 1)), int((building.get("footprint", {}) as Dictionary).get("height", 1))]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.tooltip_text = "Select %s for tile placement" % definition_id
		button.toggle_mode = true
		button.button_pressed = definition_id == _selected_definition_id
		button.custom_minimum_size.y = 46
		button.add_theme_font_size_override("font_size", 10)
		button.add_theme_stylebox_override("normal", _panel_style(HEADER, BORDER, 4))
		button.add_theme_stylebox_override("pressed", _panel_style(Color("1c2b27"), FOCUS, 4))
		button.add_theme_stylebox_override("hover", _panel_style(Color("1a2420"), FOCUS, 4))
		button.pressed.connect(_select_building.bind(definition_id, building.duplicate(true)))
		_palette_list.add_child(button)


func _refresh_inspector() -> void:
	if not is_instance_valid(_inspector_body):
		return
	for child in _inspector_body.get_children():
		_inspector_body.remove_child(child)
		child.queue_free()
	_inspector_body.add_child(_heading("INSPECTOR", "FactoryInspectorTitle"))
	if not _valid_workspace():
		_inspector_body.add_child(_label("Choose a Factory World to inspect mining and production infrastructure.", 11, MUTED))
		return
	if not _selected_link.is_empty():
		_build_link_inspector()
		return
	if not _selected_entity.is_empty():
		_build_entity_inspector()
		return
	if not _selected_resource.is_empty():
		_build_resource_inspector()
		return
	if not _selected_order.is_empty():
		_build_construction_order_inspector()
		return
	_build_world_inspector()


func _build_world_inspector() -> void:
	_inspector_body.add_child(_label("Factory overview", 14, TEXT))
	var power: Dictionary = _snapshot.get("power", {})
	_inspector_body.add_child(_metric("Power", "%.0f / %.0f kW" % [float(power.get("served_kw", 0.0)), float(power.get("demand_kw", 0.0))], "FactoryInspectorPower"))
	_inspector_body.add_child(_metric("Generation", "%.0f kW" % float(power.get("generation_kw", 0.0))))
	_inspector_body.add_child(_section_label("CONSTRUCTION ORDERS"))
	var orders: Array = _snapshot.get("construction_orders", [])
	if orders.is_empty():
		_inspector_body.add_child(_label("No active construction orders.", 10, MUTED))
	else:
		for order_value in orders:
			var order := order_value as Dictionary
			var order_button := Button.new()
			order_button.name = "FactoryConstruction_%s" % str(order.get("id", ""))
			order_button.text = "%s · %d%%" % [str(order.get("definition_id", "BUILD")), roundi(float(order.get("progress", 0.0)) * 100.0)]
			order_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			order_button.pressed.connect(_select_order.bind(order.duplicate(true)))
			_inspector_body.add_child(order_button)


func _build_resource_inspector() -> void:
	var field := _selected_resource
	_inspector_body.add_child(_label(str(field.get("resource_id", "RESOURCE")).to_upper(), 14, TEXT))
	_inspector_body.add_child(_metric("Classification", "Resource field · terrain"))
	_inspector_body.add_child(_metric("Grade", "%.2f" % float(field.get("grade", 1.0))))
	_inspector_body.add_child(_metric("Potential density", "%.2f" % float(field.get("potential_density", 1.0))))
	_inspector_body.add_child(_notice("Terrain resource fields are not entities and cannot be connected."))


func _build_construction_order_inspector() -> void:
	var order := _selected_order
	_inspector_body.add_child(_label("BUILD · %s" % str(order.get("definition_id", "ORDER")), 14, TEXT))
	_inspector_body.add_child(_metric("Status", str(order.get("status", "WAITING_MATERIALS")), "FactoryInspectorStatus"))
	_inspector_body.add_child(_metric("Blocker", str(order.get("blocker_code", "—")), "FactoryInspectorBlocker"))
	_inspector_body.add_child(_metric("Progress", "%d%%" % roundi(float(order.get("progress", 0.0)) * 100.0), "FactoryInspectorProgress"))
	_inspector_body.add_child(_metric("Delivered", _dictionary_summary(order.get("delivered_items", {})), "FactoryInspectorInventory"))
	_inspector_body.add_child(_metric("Required", _dictionary_summary(order.get("required_items", {})), "FactoryInspectorInputs"))
	var storages := _view_model.storage_entities(_snapshot)
	if storages.is_empty():
		_inspector_body.add_child(_notice("An operational storage entity is required to deliver construction materials."))
		return
	_inspector_body.add_child(_section_label("FUND FROM STORAGE"))
	var storage_select := OptionButton.new()
	storage_select.name = "FactoryFundingStorage"
	for storage_value in storages:
		var storage := storage_value as Dictionary
		storage_select.add_item(str(storage.get("name", storage.get("id", ""))))
		storage_select.set_item_metadata(storage_select.item_count - 1, str(storage.get("id", "")))
	_inspector_body.add_child(storage_select)
	var fund := Button.new()
	fund.name = "FactoryFundConstructionButton"
	fund.text = "DELIVER MATERIALS"
	fund.pressed.connect(func() -> void:
		request_fund_construction(str(order.get("id", "")), str(storage_select.get_selected_metadata()))
	)
	_inspector_body.add_child(fund)


func _build_entity_inspector() -> void:
	var entity := _selected_entity
	_inspector_body.add_child(_label(str(entity.get("name", entity.get("id", "Entity"))), 14, TEXT))
	_inspector_body.add_child(_metric("Status", str(entity.get("status", "IDLE")), "FactoryInspectorStatus"))
	var blocker := str(entity.get("blocker_code", ""))
	_inspector_body.add_child(_metric("Blocker", blocker if not blocker.is_empty() else "—", "FactoryInspectorBlocker"))
	_inspector_body.add_child(_metric("Throughput", "%.2f / s" % float(entity.get("actual_rate", 0.0)), "FactoryInspectorThroughput"))
	_inspector_body.add_child(_metric("Progress", "%d%%" % roundi(float(entity.get("progress", 0.0)) * 100.0), "FactoryInspectorProgress"))
	_inspector_body.add_child(_metric("Power", "%.0f%% · %.0f / %.0f kW" % [float(entity.get("power_factor", 1.0)) * 100.0, float(entity.get("power_generation_kw", 0.0)), float(entity.get("power_demand_kw", 0.0))], "FactoryInspectorPower"))
	_inspector_body.add_child(_section_label("I / O & INVENTORY"))
	_inspector_body.add_child(_metric("Inputs", _dictionary_summary(entity.get("inputs", {})), "FactoryInspectorInputs"))
	_inspector_body.add_child(_metric("Outputs", _dictionary_summary(entity.get("outputs", {})), "FactoryInspectorOutputs"))
	_inspector_body.add_child(_metric("Inventory", _dictionary_summary(entity.get("inventory", {})), "FactoryInspectorInventory"))
	_build_connect_controls(entity)
	_build_funding_controls()


func _build_link_inspector() -> void:
	var link := _selected_link
	_inspector_body.add_child(_label("%s LINK" % str(link.get("kind", "CARGO")), 14, TEXT))
	_inspector_body.add_child(_metric("Status", str(link.get("status", "IDLE")), "FactoryInspectorStatus"))
	_inspector_body.add_child(_metric("Endpoints", "%s → %s" % [str(link.get("source_id", "")), str(link.get("target_id", ""))]))
	_inspector_body.add_child(_metric("Flow", "%.2f / %.2f / s" % [float(link.get("last_flow", 0.0)), float(link.get("capacity_per_second", 0.0))], "FactoryInspectorThroughput"))
	var remove := Button.new()
	remove.name = "FactoryRemoveLinkButton"
	remove.text = "REMOVE CONNECTION"
	remove.tooltip_text = "Emit a versioned REMOVE_LINK intent"
	remove.pressed.connect(request_remove_link.bind(str(link.get("id", ""))))
	_inspector_body.add_child(remove)


func _build_connect_controls(entity: Dictionary) -> void:
	_inspector_body.add_child(_section_label("CONNECT"))
	var target_select := OptionButton.new()
	target_select.name = "FactoryConnectionTarget"
	var targets: Array = []
	for candidate_value in _snapshot.get("entities", []):
		var candidate := candidate_value as Dictionary
		if str(candidate.get("id", "")) == str(entity.get("id", "")):
			continue
		targets.append(candidate)
		target_select.add_item(str(candidate.get("name", candidate.get("id", ""))))
		target_select.set_item_metadata(target_select.item_count - 1, str(candidate.get("id", "")))
	_inspector_body.add_child(target_select)
	var kind_select := OptionButton.new()
	kind_select.name = "FactoryConnectionKind"
	kind_select.add_item("CARGO")
	kind_select.set_item_metadata(0, "CARGO")
	kind_select.add_item("POWER")
	kind_select.set_item_metadata(1, "POWER")
	_inspector_body.add_child(kind_select)
	var item_input := LineEdit.new()
	item_input.name = "FactoryConnectionItem"
	var outputs: Array = (entity.get("ports", {}) as Dictionary).get("outputs", [])
	item_input.text = str(outputs[0]) if not outputs.is_empty() else ""
	item_input.placeholder_text = "Cargo item id"
	_inspector_body.add_child(item_input)
	var connect := Button.new()
	connect.name = "FactoryConnectButton"
	connect.text = "CONNECT SELECTED"
	connect.disabled = targets.is_empty()
	connect.pressed.connect(func() -> void:
		if target_select.selected < 0:
			return
		request_connection(str(entity.get("id", "")), str(target_select.get_selected_metadata()), str(kind_select.get_selected_metadata()), item_input.text.strip_edges())
	)
	_inspector_body.add_child(connect)


func _build_funding_controls() -> void:
	var orders: Array = _snapshot.get("construction_orders", [])
	var storages := _view_model.storage_entities(_snapshot)
	if orders.is_empty() or storages.is_empty():
		return
	_inspector_body.add_child(_section_label("FUND CONSTRUCTION"))
	var order_select := OptionButton.new()
	order_select.name = "FactoryFundingOrder"
	for order_value in orders:
		var order := order_value as Dictionary
		order_select.add_item(str(order.get("definition_id", order.get("id", ""))))
		order_select.set_item_metadata(order_select.item_count - 1, str(order.get("id", "")))
	_inspector_body.add_child(order_select)
	var storage_select := OptionButton.new()
	storage_select.name = "FactoryFundingStorage"
	for storage_value in storages:
		var storage := storage_value as Dictionary
		storage_select.add_item(str(storage.get("name", storage.get("id", ""))))
		storage_select.set_item_metadata(storage_select.item_count - 1, str(storage.get("id", "")))
	_inspector_body.add_child(storage_select)
	var fund := Button.new()
	fund.name = "FactoryFundConstructionButton"
	fund.text = "DELIVER MATERIALS"
	fund.pressed.connect(func() -> void:
		request_fund_construction(str(order_select.get_selected_metadata()), str(storage_select.get_selected_metadata()))
	)
	_inspector_body.add_child(fund)


func _on_entity_selected(entity: Dictionary) -> void:
	_selected_entity = entity.duplicate(true)
	_selected_resource.clear()
	_selected_link.clear()
	_selected_order.clear()
	_refresh_inspector()


func _on_resource_selected(field: Dictionary) -> void:
	_selected_resource = field.duplicate(true)
	_selected_entity.clear()
	_selected_link.clear()
	_selected_order.clear()
	_refresh_inspector()


func _on_link_selected(link: Dictionary) -> void:
	_selected_link = link.duplicate(true)
	_selected_entity.clear()
	_selected_resource.clear()
	_selected_order.clear()
	_refresh_inspector()


func _on_tile_selected(tile: Vector2i) -> void:
	if _selected_definition_id.is_empty():
		return
	request_placement(_selected_definition_id, tile, _selected_recipe_id)


func _select_building(definition_id: String, building: Dictionary) -> void:
	if definition_id == _selected_definition_id:
		_cancel_placement()
		return
	_selected_definition_id = definition_id
	var recipe_ids: Array = building.get("recipe_ids", [])
	_selected_recipe_id = str(recipe_ids[0]) if not recipe_ids.is_empty() else ""
	var footprint: Dictionary = building.get("footprint", {})
	_canvas.set_placement_mode(true, Vector2i(maxi(1, int(footprint.get("width", 1))), maxi(1, int(footprint.get("height", 1)))))
	_refresh_palette()


func _cancel_placement() -> void:
	_selected_definition_id = ""
	_selected_recipe_id = ""
	if is_instance_valid(_canvas):
		_canvas.set_placement_mode(false)
	_refresh_palette()


func _select_order(order: Dictionary) -> void:
	_selected_order = order.duplicate(true)
	_selected_link.clear()
	_selected_entity.clear()
	_selected_resource.clear()
	_refresh_inspector()


func _emit_command(kind: String, payload: Dictionary) -> void:
	_command_sequence += 1
	var world_id := str(_snapshot.get("world_id", ""))
	if _command_session_id.is_empty():
		_command_session_id = "%d:%d" % [int(Time.get_unix_time_from_system() * 1000.0), get_instance_id()]
	var intent := {
		"protocol_version":PROTOCOL_VERSION,
		"command_id":"factory:%s:%s:%s:%d" % [world_id, kind.to_lower(), _command_session_id, _command_sequence],
		"kind":kind,
		"world_id":world_id,
		"base_topology_revision":int(_snapshot.get("topology_revision", 0)),
		"base_runtime_revision":int(_snapshot.get("runtime_revision", 0)),
		"payload":payload.duplicate(true)
	}
	command_intent.emit(intent)


func _valid_workspace() -> bool:
	return not _snapshot.is_empty() and bool(_snapshot.get("valid", true)) and int(_snapshot.get("protocol_version", 0)) == PROTOCOL_VERSION and not str(_snapshot.get("world_id", "")).is_empty()


func _inspector_interaction_active() -> bool:
	if not is_instance_valid(_inspector_body) or not is_inside_tree():
		return false
	var focused := get_viewport().gui_get_focus_owner()
	if focused == _inspector_body or (is_instance_valid(focused) and _inspector_body.is_ancestor_of(focused)):
		return true
	for option_value in _inspector_body.find_children("*", "OptionButton", true, false):
		var option := option_value as OptionButton
		if option.get_popup().visible:
			return true
	return false


func _palette_snapshot_signature(snapshot: Dictionary) -> String:
	return JSON.stringify({
		"valid":bool(snapshot.get("valid", false)),
		"world_id":str(snapshot.get("world_id", "")),
		"palette":snapshot.get("palette", {})
	})


func _entity_by_id(entity_id: String) -> Dictionary:
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity.duplicate(true)
	return {}


func _resource_by_id(resource_id: String) -> Dictionary:
	for resource_value in _snapshot.get("resource_fields", []):
		var resource := resource_value as Dictionary
		if str(resource.get("id", "")) == resource_id:
			return resource.duplicate(true)
	return {}


func _link_by_id(link_id: String) -> Dictionary:
	for link_value in _snapshot.get("links", []):
		var link := link_value as Dictionary
		if str(link.get("id", "")) == link_id:
			return link.duplicate(true)
	return {}


func _order_by_id(order_id: String) -> Dictionary:
	for order_value in _snapshot.get("construction_orders", []):
		var order := order_value as Dictionary
		if str(order.get("id", "")) == order_id:
			return order.duplicate(true)
	return {}


func _heading(value: String, node_name: String) -> Label:
	var label := _label(value, 10, FOCUS)
	label.name = node_name
	return label


func _section_label(value: String) -> Label:
	var label := _label(value, 9, MUTED)
	label.add_theme_constant_override("outline_size", 0)
	return label


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _metric(key: String, value: String, node_name: String = "") -> HBoxContainer:
	var row := HBoxContainer.new()
	if not node_name.is_empty():
		row.name = node_name
	var left := _label(key, 10, MUTED)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.autowrap_mode = TextServer.AUTOWRAP_OFF
	left.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(left)
	var right := _label(value, 10, TEXT)
	right.custom_minimum_size.x = 92
	right.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	right.autowrap_mode = TextServer.AUTOWRAP_OFF
	right.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	right.tooltip_text = value
	row.add_child(right)
	return row


func _notice(value: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style(Color("25211a"), Color("9d7a42"), 4))
	panel.add_child(_margin_box(7, 5, 7, 5, _label(value, 10, Color("e0c784"))))
	return panel


func _margin_box(all: int, top: int = -1, right: int = -1, bottom: int = -1, child: Control = null) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", all)
	margin.add_theme_constant_override("margin_top", all if top < 0 else top)
	margin.add_theme_constant_override("margin_right", all if right < 0 else right)
	margin.add_theme_constant_override("margin_bottom", all if bottom < 0 else bottom)
	if child != null:
		margin.add_child(child)
	return margin


func _panel_style(background: Color, border_color: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border_color
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style


func _dictionary_summary(value: Variant) -> String:
	if not value is Dictionary or (value as Dictionary).is_empty():
		return "—"
	var keys: Array = (value as Dictionary).keys()
	keys.sort()
	var pieces: Array[String] = []
	for key_value in keys:
		pieces.append("%s: %s" % [str(key_value), str((value as Dictionary).get(key_value, 0))])
	return ", ".join(pieces)
