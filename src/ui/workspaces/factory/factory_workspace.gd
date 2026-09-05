class_name FactoryWorkspace
extends Control

## Standalone Factory Workspace protocol v1 client. It owns transient UI state
## only: selected palette entry, canvas focus, and pending command feedback.
## The mounting host supplies immutable snapshots and forwards command intents
## to the application boundary.

signal command_requested(intent: Dictionary)
signal refresh_requested(world_id: String)
signal selection_changed(selection: Dictionary)

const ViewModelScript = preload("res://src/ui/view_models/factory/factory_workspace_view_model.gd")
const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const PROTOCOL_VERSION := 1

## Resolve the localization autoload at runtime so this standalone component
## also compiles when loaded by a --script SceneTree test.
@onready var I18n = get_node("/root/I18n")

## Receipts are keyed by command_id. Keep this process-wide rather than per
## workspace instance so page/locale rebuilds cannot replay a prior command.
static var _global_command_sequence := 0
static var _command_session_id := "%x-%x" % [int(Time.get_unix_time_from_system() * 1000000.0), OS.get_process_id()]

var _view_model := ViewModelScript.new()
var _snapshot: Dictionary = {}
var _reduced_motion := false
var _active_tool := ""
var _selected_building_id := ""
var _selected_recipe_id := ""
var _connection_kind := "CARGO"
var _connection_source_id := ""
var _connection_target_id := ""
var _selected_cargo_item_id := ""
var _selection := {"kind":"", "id":"", "data":{}}
var _preview_tile := Vector2i.ZERO

var _world_label: Label
var _revision_label: Label
var _feedback_label: Label
var _building_options: OptionButton
var _recipe_options: OptionButton
var _source_options: OptionButton
var _target_options: OptionButton
var _cargo_item_options: OptionButton
var _connect_button: Button
var _cargo_mode_button: Button
var _power_mode_button: Button
var _inspector_body: VBoxContainer
var _canvas


func _ready() -> void:
	name = "FactoryWorkspace"
	focus_mode = Control.FOCUS_ALL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_interface()
	_render()


## The host may call this before or after adding this workspace to the tree.
func apply_snapshot(snapshot: Dictionary) -> void:
	_snapshot = _view_model.build(snapshot)
	if _canvas != null:
		_canvas.apply_snapshot(_snapshot)
		_canvas.set_reduced_motion(_reduced_motion)
	_clear_missing_selection()
	_render()


## The host calls this immediately after forwarding command_requested to the
## application facade. A separate refresh_requested signal asks the host for a
## fresh immutable snapshot; this component never fetches or mutates state.
func apply_command_result(result: Dictionary) -> void:
	var accepted := bool(result.get("accepted", false))
	var reason_code := str(result.get("reason_code", ""))
	var message := str(result.get("message", ""))
	if int(result.get("protocol_version", PROTOCOL_VERSION)) != PROTOCOL_VERSION:
		accepted = false
		reason_code = "UNSUPPORTED_PROTOCOL"
		message = I18n.t("factory.feedback.unsupported_protocol")
	if accepted:
		_set_feedback("ACCEPTED", message if not message.is_empty() else I18n.t("factory.feedback.accepted"), Color("6fbf92"))
	else:
		var rejection_code := reason_code if not reason_code.is_empty() else "COMMAND_REJECTED"
		var rejection_key := "factory.reason.%s" % rejection_code.to_lower()
		var localized_message: String = str(I18n.t(rejection_key))
		if localized_message == rejection_key:
			localized_message = message if not message.is_empty() else I18n.t("factory.feedback.rejected")
		_set_feedback(rejection_code, localized_message, Color("d86e63"))
	var response_world_id := str(result.get("world_id", _snapshot.get("world_id", "")))
	if not response_world_id.is_empty():
		refresh_requested.emit(response_world_id)


func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled
	if _canvas != null:
		_canvas.set_reduced_motion(enabled)


func request_refresh() -> void:
	var world_id := str(_snapshot.get("world_id", ""))
	if world_id.is_empty():
		_set_feedback("NO_FACTORY_WORLD", I18n.t("factory.feedback.no_world"), Color("d86e63"))
		return
	refresh_requested.emit(world_id)


func selected_entity_id() -> String:
	return str(_selection.get("id", "")) if str(_selection.get("kind", "")) == "ENTITY" else ""


func selected_link_id() -> String:
	return str(_selection.get("id", "")) if str(_selection.get("kind", "")) == "LINK" else ""


func canvas() -> Control:
	return _canvas


func _build_interface() -> void:
	var root := VBoxContainer.new()
	root.name = "WorkspaceLayout"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var toolbar := HBoxContainer.new()
	toolbar.name = "FactoryToolbar"
	toolbar.custom_minimum_size = Vector2(0, 32)
	root.add_child(toolbar)
	_world_label = _make_label(I18n.t("factory.workspace.label"), Color("d5ddd8"))
	_world_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(_world_label)
	_revision_label = _make_label(I18n.t("factory.workspace.topology_empty"), Color("9aa6a1"))
	toolbar.add_child(_revision_label)
	var reset_camera_button := _make_button(I18n.t("factory.action.reset_view"), I18n.t("factory.tooltip.reset_view"))
	reset_camera_button.pressed.connect(func() -> void: _canvas.reset_camera())
	toolbar.add_child(reset_camera_button)
	var refresh_button := _make_button(I18n.t("factory.action.refresh"), I18n.t("factory.tooltip.refresh"))
	refresh_button.pressed.connect(request_refresh)
	toolbar.add_child(refresh_button)
	var motion_toggle := CheckButton.new()
	motion_toggle.text = I18n.t("factory.action.reduced_motion")
	motion_toggle.tooltip_text = I18n.t("factory.tooltip.reduced_motion")
	motion_toggle.button_pressed = _reduced_motion
	motion_toggle.toggled.connect(set_reduced_motion)
	toolbar.add_child(motion_toggle)

	var body := HBoxContainer.new()
	body.name = "FactoryWorkspaceBody"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	var palette_scroll := ScrollContainer.new()
	palette_scroll.name = "PaletteScroll"
	palette_scroll.custom_minimum_size = Vector2(238, 0)
	palette_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(palette_scroll)
	var palette := VBoxContainer.new()
	palette.name = "FactoryPalette"
	palette.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	palette.add_theme_constant_override("separation", 7)
	palette_scroll.add_child(palette)
	palette.add_child(_make_section_label(I18n.t("factory.palette.construction")))
	_building_options = OptionButton.new()
	_building_options.name = "BuildingPalette"
	_building_options.tooltip_text = I18n.t("factory.tooltip.building_palette")
	_building_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_building_options.item_selected.connect(_on_building_selected)
	palette.add_child(_building_options)
	_recipe_options = OptionButton.new()
	_recipe_options.name = "RecipePalette"
	_recipe_options.tooltip_text = I18n.t("factory.tooltip.recipe_palette")
	_recipe_options.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_options.item_selected.connect(_on_recipe_selected)
	palette.add_child(_recipe_options)
	var placement_help := _make_label(I18n.t("factory.help.placement"), Color("9aa6a1"))
	placement_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	palette.add_child(placement_help)

	palette.add_child(HSeparator.new())
	palette.add_child(_make_section_label(I18n.t("factory.palette.connections")))
	var connection_modes := HBoxContainer.new()
	palette.add_child(connection_modes)
	_cargo_mode_button = _make_button(I18n.t("factory.connection.cargo"), I18n.t("factory.tooltip.cargo"))
	_cargo_mode_button.name = "CargoConnectionMode"
	_cargo_mode_button.toggle_mode = true
	_cargo_mode_button.pressed.connect(func() -> void: _set_connection_mode("CARGO"))
	connection_modes.add_child(_cargo_mode_button)
	_power_mode_button = _make_button(I18n.t("factory.connection.power"), I18n.t("factory.tooltip.power"))
	_power_mode_button.name = "PowerConnectionMode"
	_power_mode_button.toggle_mode = true
	_power_mode_button.pressed.connect(func() -> void: _set_connection_mode("POWER"))
	connection_modes.add_child(_power_mode_button)
	_source_options = OptionButton.new()
	_source_options.name = "ConnectionSource"
	_source_options.tooltip_text = I18n.t("factory.tooltip.connection_source")
	_source_options.item_selected.connect(_on_source_selected)
	palette.add_child(_source_options)
	_target_options = OptionButton.new()
	_target_options.name = "ConnectionTarget"
	_target_options.tooltip_text = I18n.t("factory.tooltip.connection_target")
	_target_options.item_selected.connect(_on_target_selected)
	palette.add_child(_target_options)
	_cargo_item_options = OptionButton.new()
	_cargo_item_options.name = "CargoItem"
	_cargo_item_options.tooltip_text = I18n.t("factory.tooltip.cargo_item")
	_cargo_item_options.item_selected.connect(_on_cargo_item_selected)
	palette.add_child(_cargo_item_options)
	_connect_button = _make_button(I18n.t("factory.action.create_connection"), I18n.t("factory.tooltip.create_connection"))
	_connect_button.name = "CreateConnection"
	_connect_button.pressed.connect(_request_connection)
	palette.add_child(_connect_button)
	var connection_help := _make_label(I18n.t("factory.help.connection"), Color("9aa6a1"))
	connection_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	palette.add_child(connection_help)

	_canvas = CanvasScript.new()
	_canvas.name = "FactoryCanvas"
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.custom_minimum_size = Vector2(440, 360)
	_canvas.entity_selected.connect(_on_entity_selected)
	_canvas.resource_field_selected.connect(_on_resource_field_selected)
	_canvas.link_selected.connect(_on_link_selected)
	_canvas.construction_order_selected.connect(_on_construction_order_selected)
	_canvas.tile_hovered.connect(_on_tile_hovered)
	_canvas.tile_selected.connect(_on_tile_selected)
	body.add_child(_canvas)

	var inspector_scroll := ScrollContainer.new()
	inspector_scroll.name = "InspectorScroll"
	inspector_scroll.custom_minimum_size = Vector2(270, 0)
	inspector_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(inspector_scroll)
	_inspector_body = VBoxContainer.new()
	_inspector_body.name = "FactoryInspector"
	_inspector_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_body.add_theme_constant_override("separation", 6)
	inspector_scroll.add_child(_inspector_body)

	_feedback_label = _make_label(I18n.t("factory.feedback.waiting"), Color("9aa6a1"))
	_feedback_label.name = "FactoryCommandFeedback"
	_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_feedback_label)


func _render() -> void:
	if not is_instance_valid(_building_options):
		return
	var is_valid := bool(_snapshot.get("valid", false)) and int(_snapshot.get("protocol_version", 0)) == PROTOCOL_VERSION
	_world_label.text = I18n.t("factory.workspace.world") % str(_snapshot.get("world_id", I18n.t("factory.workspace.unavailable")))
	_revision_label.text = I18n.t("factory.workspace.revisions") % [int(_snapshot.get("topology_revision", 0)), int(_snapshot.get("runtime_revision", 0))]
	_rebuild_palette(is_valid)
	_rebuild_connection_selectors(is_valid)
	_refresh_inspector()
	if _canvas != null:
		_canvas.apply_snapshot(_snapshot)
		_canvas.set_reduced_motion(_reduced_motion)
	_update_placement_preview()
	_update_connection_preview()


func _rebuild_palette(is_valid: bool) -> void:
	_building_options.clear()
	_building_options.add_item(I18n.t("factory.select.building"))
	_building_options.set_item_metadata(0, "")
	var palette: Dictionary = _snapshot.get("palette", {}) if _snapshot.get("palette", {}) is Dictionary else {}
	var index := 1
	for building_value in palette.get("buildings", []):
		var building := building_value as Dictionary
		var building_id := str(building.get("id", ""))
		_building_options.add_item(str(building.get("name", building_id)) + I18n.core("format.slash_separator") + str(building.get("kind", "")))
		_building_options.set_item_metadata(index, building_id)
		if building_id == _selected_building_id:
			_building_options.select(index)
		index += 1
	if _building_options.selected < 0:
		_building_options.select(0)
	_building_options.disabled = not is_valid

	_recipe_options.clear()
	_recipe_options.add_item(I18n.t("factory.select.no_recipe"))
	_recipe_options.set_item_metadata(0, "")
	var building := _view_model.building_by_id(_snapshot, _selected_building_id)
	var recipe_index := 1
	for recipe_id_value in building.get("recipe_ids", []):
		var recipe_id := str(recipe_id_value)
		var recipe := _view_model.recipe_by_id(_snapshot, recipe_id)
		_recipe_options.add_item(str(recipe.get("name", recipe_id)))
		_recipe_options.set_item_metadata(recipe_index, recipe_id)
		if recipe_id == _selected_recipe_id:
			_recipe_options.select(recipe_index)
		recipe_index += 1
	if recipe_index > 1 and _selected_recipe_id.is_empty():
		_selected_recipe_id = str(_recipe_options.get_item_metadata(1))
		_recipe_options.select(1)
	if _recipe_options.selected < 0:
		_recipe_options.select(0)
	_recipe_options.disabled = not is_valid or recipe_index <= 1


func _rebuild_connection_selectors(is_valid: bool) -> void:
	_populate_entity_options(_source_options, I18n.t("factory.select.source"), _connection_source_id)
	_populate_entity_options(_target_options, I18n.t("factory.select.target"), _connection_target_id)
	_source_options.disabled = not is_valid
	_target_options.disabled = not is_valid
	_cargo_item_options.clear()
	_cargo_item_options.add_item(I18n.t("factory.select.cargo_item"))
	_cargo_item_options.set_item_metadata(0, "")
	var source := _entity_by_id(_connection_source_id)
	var target := _entity_by_id(_connection_target_id)
	var item_index := 1
	for item_value in _view_model.compatible_cargo_items(source, target):
		var item_id := str(item_value)
		_cargo_item_options.add_item(_item_name(item_id))
		_cargo_item_options.set_item_metadata(item_index, item_id)
		if item_id == _selected_cargo_item_id:
			_cargo_item_options.select(item_index)
		item_index += 1
	if item_index == 2 and _selected_cargo_item_id.is_empty():
		_selected_cargo_item_id = str(_cargo_item_options.get_item_metadata(1))
		_cargo_item_options.select(1)
	if _cargo_item_options.selected < 0:
		_cargo_item_options.select(0)
	_cargo_item_options.visible = _connection_kind == "CARGO"
	_cargo_item_options.disabled = not is_valid or _connection_kind != "CARGO" or item_index <= 1
	_cargo_mode_button.button_pressed = _active_tool == "CONNECT" and _connection_kind == "CARGO"
	_power_mode_button.button_pressed = _active_tool == "CONNECT" and _connection_kind == "POWER"
	_connect_button.disabled = not is_valid or not _connection_is_ready(source, target)
	_connect_button.text = I18n.t("factory.action.create_kind_connection") % I18n.t("factory.connection.%s" % _connection_kind.to_lower())


func _populate_entity_options(options: OptionButton, placeholder: String, selected_id: String) -> void:
	options.clear()
	options.add_item(placeholder)
	options.set_item_metadata(0, "")
	var index := 1
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		var entity_id := str(entity.get("id", ""))
		options.add_item(str(entity.get("name", entity_id)) + I18n.core("format.slash_separator") + entity_id)
		options.set_item_metadata(index, entity_id)
		if entity_id == selected_id:
			options.select(index)
		index += 1
	if options.selected < 0:
		options.select(0)


func _on_building_selected(index: int) -> void:
	_selected_building_id = str(_building_options.get_item_metadata(index))
	_selected_recipe_id = ""
	_active_tool = "BUILD" if not _selected_building_id.is_empty() else ""
	if _active_tool == "BUILD":
		_connection_source_id = ""
		_connection_target_id = ""
		_selected_cargo_item_id = ""
	_render()


func _on_recipe_selected(index: int) -> void:
	_selected_recipe_id = str(_recipe_options.get_item_metadata(index))
	_update_placement_preview()


func _set_connection_mode(kind: String) -> void:
	_connection_kind = kind.to_upper()
	_active_tool = "CONNECT"
	_selected_building_id = ""
	_selected_recipe_id = ""
	if _canvas != null:
		_canvas.clear_placement_preview()
	_render()


func _on_source_selected(index: int) -> void:
	_connection_source_id = str(_source_options.get_item_metadata(index))
	if _connection_source_id == _connection_target_id:
		_connection_target_id = ""
	_selected_cargo_item_id = ""
	_active_tool = "CONNECT"
	_render()


func _on_target_selected(index: int) -> void:
	_connection_target_id = str(_target_options.get_item_metadata(index))
	if _connection_target_id == _connection_source_id:
		_connection_source_id = ""
	_selected_cargo_item_id = ""
	_active_tool = "CONNECT"
	_render()


func _on_cargo_item_selected(index: int) -> void:
	_selected_cargo_item_id = str(_cargo_item_options.get_item_metadata(index))
	_update_connection_preview()
	_rebuild_connection_selectors(bool(_snapshot.get("valid", false)))


func _on_tile_hovered(tile: Vector2i) -> void:
	if _active_tool == "BUILD":
		_preview_tile = tile
		_update_placement_preview()


func _on_tile_selected(tile: Vector2i) -> void:
	if _active_tool == "BUILD":
		_preview_tile = tile
		_request_construction(tile)
		return
	_set_selection("TILE", "%d,%d" % [tile.x, tile.y], {"coordinate":{"x":tile.x, "y":tile.y}})


func _on_entity_selected(entity: Dictionary) -> void:
	var entity_id := str(entity.get("id", ""))
	if _active_tool == "CONNECT":
		if _connection_source_id.is_empty():
			_connection_source_id = entity_id
		elif _connection_target_id.is_empty() and entity_id != _connection_source_id:
			_connection_target_id = entity_id
		else:
			_connection_source_id = entity_id
			_connection_target_id = ""
		_selected_cargo_item_id = ""
		_rebuild_connection_selectors(bool(_snapshot.get("valid", false)))
		_update_connection_preview()
	_set_selection("ENTITY", entity_id, entity)


func _on_resource_field_selected(field: Dictionary) -> void:
	_set_selection("RESOURCE_FIELD", str(field.get("id", "")), field)


func _on_link_selected(link: Dictionary) -> void:
	_set_selection("LINK", str(link.get("id", "")), link)


func _on_construction_order_selected(order: Dictionary) -> void:
	_set_selection("CONSTRUCTION_ORDER", str(order.get("id", "")), order)


func _request_construction(tile: Vector2i) -> void:
	var building := _view_model.building_by_id(_snapshot, _selected_building_id)
	var preview := _view_model.placement_preview(_snapshot, building, tile)
	if not bool(preview.get("valid", false)):
		_set_feedback(str(preview.get("reason_code", "INVALID_PLACEMENT")), I18n.t("factory.feedback.invalid_placement"), Color("d86e63"))
		return
	_emit_command("QUEUE_CONSTRUCTION", {
		"definition_id":_selected_building_id,
		"recipe_id":_selected_recipe_id,
		"origin":{"x":tile.x, "y":tile.y},
		"priority":50
	})


func _request_connection() -> void:
	var source := _entity_by_id(_connection_source_id)
	var target := _entity_by_id(_connection_target_id)
	if not _connection_is_ready(source, target):
		_set_feedback("INVALID_CONNECTION", I18n.t("factory.feedback.invalid_connection"), Color("d86e63"))
		return
	var payload := {
		"link_kind":_connection_kind,
		"source_id":_connection_source_id,
		"target_id":_connection_target_id,
		"item_id":_selected_cargo_item_id if _connection_kind == "CARGO" else "",
		"capacity_per_second":1.0,
		"priority":1
	}
	_emit_command("CONNECT_ENTITIES", payload)


func _request_remove_link(link_id: String) -> void:
	if link_id.is_empty():
		return
	_emit_command("REMOVE_LINK", {"link_id":link_id})


func _request_fund_construction(order_id: String, storage_id: String) -> void:
	if order_id.is_empty() or storage_id.is_empty():
		_set_feedback("MISSING_FUNDING_SOURCE", I18n.t("factory.feedback.missing_funding_source"), Color("d86e63"))
		return
	_emit_command("FUND_CONSTRUCTION", {"order_id":order_id, "storage_id":storage_id})


func _request_set_recipe(entity_id: String, recipe_id: String) -> void:
	if entity_id.is_empty() or recipe_id.is_empty():
		_set_feedback("INCOMPATIBLE_RECIPE", I18n.t("factory.reason.incompatible_recipe"), Color("d86e63"))
		return
	_emit_command("SET_RECIPE", {"entity_id":entity_id, "recipe_id":recipe_id})


## These forward-compatible controls deliberately emit only protocol intents.
## The integration layer may supply location_inventory in future snapshots; the
## UI does not read location state or assume that a transfer is always allowed.
func _request_storage_transfer(kind: String, storage_id: String, item_id: String, quantity: int) -> void:
	if storage_id.is_empty() or item_id.is_empty() or quantity <= 0:
		_set_feedback("INVALID_TRANSFER", I18n.t("factory.feedback.invalid_transfer"), Color("d86e63"))
		return
	_emit_command(kind, {"storage_id":storage_id, "item_id":item_id, "quantity":quantity})


func _emit_command(kind: String, payload: Dictionary) -> void:
	if not bool(_snapshot.get("valid", false)) or int(_snapshot.get("protocol_version", 0)) != PROTOCOL_VERSION:
		_set_feedback("WORKSPACE_UNAVAILABLE", I18n.t("factory.feedback.workspace_unavailable"), Color("d86e63"))
		return
	_global_command_sequence += 1
	var world_id := str(_snapshot.get("world_id", "factory"))
	var command_id := "factory-ui-%s-%s-%06d" % [world_id.validate_filename(), _command_session_id, _global_command_sequence]
	var intent := _view_model.command_intent(_snapshot, command_id, kind, payload)
	_set_feedback("PENDING", I18n.t("factory.feedback.pending") % [_command_name(kind), command_id], Color("e0ae5c"))
	command_requested.emit(intent)


func _connection_is_ready(source: Dictionary, target: Dictionary) -> bool:
	if source.is_empty() or target.is_empty() or _connection_source_id == _connection_target_id:
		return false
	if _connection_kind == "POWER":
		return _view_model.is_power_connection_valid(source, target)
	return not _selected_cargo_item_id.is_empty() and _view_model.compatible_cargo_items(source, target).has(_selected_cargo_item_id)


func _update_placement_preview() -> void:
	if _canvas == null:
		return
	if _active_tool != "BUILD" or _selected_building_id.is_empty():
		_canvas.clear_placement_preview()
		return
	var building := _view_model.building_by_id(_snapshot, _selected_building_id)
	var preview := _view_model.placement_preview(_snapshot, building, _preview_tile)
	_canvas.set_placement_preview(preview)


func _update_connection_preview() -> void:
	if _canvas != null:
		_canvas.set_connection_preview(_connection_source_id, _connection_target_id, _connection_kind)


func _clear_missing_selection() -> void:
	if not _connection_source_id.is_empty() and _entity_by_id(_connection_source_id).is_empty():
		_connection_source_id = ""
		_selected_cargo_item_id = ""
	if not _connection_target_id.is_empty() and _entity_by_id(_connection_target_id).is_empty():
		_connection_target_id = ""
		_selected_cargo_item_id = ""
	if not _selected_building_id.is_empty() and _view_model.building_by_id(_snapshot, _selected_building_id).is_empty():
		_selected_building_id = ""
		_selected_recipe_id = ""
		if _active_tool == "BUILD":
			_active_tool = ""
	var selection_kind := str(_selection.get("kind", ""))
	var selection_id := str(_selection.get("id", ""))
	if selection_id.is_empty():
		return
	if selection_kind == "ENTITY":
		var entity := _entity_by_id(selection_id)
		if entity.is_empty():
			_set_selection("", "", {})
		else:
			_set_selection("ENTITY", selection_id, entity)
	elif selection_kind == "LINK":
		var link := _link_by_id(selection_id)
		if link.is_empty():
			_set_selection("", "", {})
		else:
			_set_selection("LINK", selection_id, link)
	elif selection_kind == "CONSTRUCTION_ORDER":
		var order := _order_by_id(selection_id)
		if order.is_empty():
			_set_selection("", "", {})
		else:
			_set_selection("CONSTRUCTION_ORDER", selection_id, order)


func _set_selection(kind: String, selection_id: String, data: Dictionary) -> void:
	_selection = {"kind":kind, "id":selection_id, "data":data.duplicate(true)}
	selection_changed.emit(_selection.duplicate(true))
	_refresh_inspector()


func _refresh_inspector() -> void:
	if not is_instance_valid(_inspector_body):
		return
	for child in _inspector_body.get_children():
		child.queue_free()
	_inspector_body.add_child(_make_section_label(I18n.t("factory.inspector.title")))
	var selection_kind := str(_selection.get("kind", ""))
	var data: Dictionary = _selection.get("data", {}) if _selection.get("data", {}) is Dictionary else {}
	if selection_kind.is_empty():
		_inspector_body.add_child(_make_label(I18n.t("factory.inspector.empty"), Color("9aa6a1")))
		return
	if selection_kind == "ENTITY":
		_render_entity_inspector(data)
	elif selection_kind == "RESOURCE_FIELD":
		_render_resource_inspector(data)
	elif selection_kind == "LINK":
		_render_link_inspector(data)
	elif selection_kind == "CONSTRUCTION_ORDER":
		_render_order_inspector(data)
	else:
		_inspector_body.add_child(_make_label(I18n.t("factory.inspector.tile") % str(_selection.get("id", "")), Color("d5ddd8")))


func _render_entity_inspector(entity: Dictionary) -> void:
	var entity_id := str(entity.get("id", ""))
	var definition_id := str(entity.get("definition_id", ""))
	_inspector_body.add_child(_make_label(_building_name(definition_id, str(entity.get("name", entity_id))), Color("d5ddd8")))
	_add_detail(I18n.t("factory.field.id"), entity_id)
	_add_detail(I18n.t("factory.field.kind"), _kind_name(str(entity.get("node_kind", "UNKNOWN"))))
	_add_detail(I18n.t("factory.field.status"), _status_name(str(entity.get("status", "UNKNOWN"))))
	_add_detail(I18n.t("factory.field.rate"), "%.2f/s" % float(entity.get("actual_rate", 0.0)))
	_add_detail(I18n.t("factory.field.power"), "%d%%" % roundi(float(entity.get("power_factor", 1.0)) * 100.0))
	var current_recipe_id := str(entity.get("recipe_id", ""))
	if not current_recipe_id.is_empty():
		_add_detail(I18n.t("factory.field.recipe"), str(_view_model.recipe_by_id(_snapshot, current_recipe_id).get("name", current_recipe_id)))
	if not str(entity.get("blocker_code", "")).is_empty():
		_add_detail(I18n.t("factory.field.blocker"), _status_name(str(entity.get("blocker_code", ""))))
	_add_item_dictionary(I18n.t("factory.field.inputs"), entity.get("inputs", {}))
	_add_item_dictionary(I18n.t("factory.field.outputs"), entity.get("outputs", {}))
	_add_item_dictionary(I18n.t("factory.field.inventory"), entity.get("inventory", {}))
	var center_button := _make_button(I18n.t("factory.action.center"), I18n.t("factory.tooltip.center_entity"))
	center_button.pressed.connect(func() -> void: _canvas.focus_tile(_view_model.footprint_origin(entity.get("footprint", {}))))
	_inspector_body.add_child(center_button)
	if str(entity.get("node_kind", "")) == "MACHINE":
		_add_entity_recipe_controls(entity)
	if str(entity.get("node_kind", "")) == "STORAGE":
		_add_storage_transfer_controls(entity)


func _add_entity_recipe_controls(entity: Dictionary) -> void:
	var building := _view_model.building_by_id(_snapshot, str(entity.get("definition_id", "")))
	var recipe_options := OptionButton.new()
	recipe_options.name = "EntityRecipeSelector"
	recipe_options.add_item(I18n.t("factory.select.recipe"))
	recipe_options.set_item_metadata(0, "")
	var current_recipe_id := str(entity.get("recipe_id", ""))
	var selected_index := 0
	var index := 1
	for recipe_id_value in building.get("recipe_ids", []):
		var recipe_id := str(recipe_id_value)
		var recipe := _view_model.recipe_by_id(_snapshot, recipe_id)
		if recipe.is_empty():
			continue
		recipe_options.add_item(str(recipe.get("name", recipe_id)))
		recipe_options.set_item_metadata(index, recipe_id)
		if recipe_id == current_recipe_id:
			selected_index = index
		index += 1
	recipe_options.select(selected_index)
	_inspector_body.add_child(recipe_options)
	var apply_button := _make_button(I18n.t("factory.action.set_recipe"), I18n.t("factory.tooltip.set_recipe"))
	apply_button.name = "ApplyEntityRecipe"
	apply_button.disabled = index <= 1
	apply_button.pressed.connect(func() -> void: _request_set_recipe(str(entity.get("id", "")), str(recipe_options.get_item_metadata(recipe_options.selected))))
	_inspector_body.add_child(apply_button)


func _render_resource_inspector(field: Dictionary) -> void:
	var resource_id := str(field.get("resource_id", ""))
	_inspector_body.add_child(_make_label(str(field.get("resource_name", _item_name(resource_id))) if not resource_id.is_empty() else I18n.t("factory.resource_field"), Color("d5ddd8")))
	_add_detail(I18n.t("factory.field.field_id"), str(field.get("id", "")))
	_add_detail(I18n.t("factory.field.category"), _category_name(str(field.get("resource_category", ""))))
	_add_detail(I18n.t("factory.field.grade"), "%.2f" % float(field.get("grade", 0.0)))
	_add_detail(I18n.t("factory.field.density"), "%.2f" % float(field.get("potential_density", 0.0)))
	var center_button := _make_button(I18n.t("factory.action.center"), I18n.t("factory.tooltip.center_resource"))
	center_button.pressed.connect(func() -> void: _canvas.focus_tile(_view_model.footprint_origin(field.get("footprint", {}))))
	_inspector_body.add_child(center_button)


func _render_link_inspector(link: Dictionary) -> void:
	var link_id := str(link.get("id", ""))
	_inspector_body.add_child(_make_label(I18n.t("factory.inspector.link") % _connection_name(str(link.get("kind", "CARGO"))), Color("d5ddd8")))
	_add_detail(I18n.t("factory.field.id"), link_id)
	_add_detail(I18n.t("factory.field.route"), "%s -> %s" % [str(link.get("source_id", "")), str(link.get("target_id", ""))])
	var item_id := str(link.get("item_id", ""))
	_add_detail(I18n.t("factory.field.item"), _item_name(item_id) if not item_id.is_empty() else "-")
	_add_detail(I18n.t("factory.field.status"), _status_name(str(link.get("status", "IDLE"))))
	_add_detail(I18n.t("factory.field.flow"), "%.2f / %.2f" % [float(link.get("last_flow", 0.0)), float(link.get("capacity_per_second", 0.0))])
	var remove_button := _make_button(I18n.t("factory.action.remove_link"), I18n.t("factory.tooltip.remove_link"))
	remove_button.pressed.connect(func() -> void: _request_remove_link(link_id))
	_inspector_body.add_child(remove_button)


func _render_order_inspector(order: Dictionary) -> void:
	var order_id := str(order.get("id", ""))
	_inspector_body.add_child(_make_label(I18n.t("factory.inspector.order"), Color("d5ddd8")))
	_add_detail(I18n.t("factory.field.order"), order_id)
	var definition_id := str(order.get("definition_id", ""))
	_add_detail(I18n.t("factory.field.building"), str(order.get("building_name", _building_name(definition_id, definition_id.replace("_", " ").capitalize()))))
	_add_detail(I18n.t("factory.field.status"), _status_name(str(order.get("status", "WAITING_MATERIALS"))))
	_add_detail(I18n.t("factory.field.progress"), "%d%%" % roundi(float(order.get("progress", 0.0)) * 100.0))
	_add_item_dictionary(I18n.t("factory.field.required"), order.get("required_items", {}))
	_add_item_dictionary(I18n.t("factory.field.delivered"), order.get("delivered_items", {}))
	var storage_options := OptionButton.new()
	storage_options.name = "FundingStorage"
	storage_options.add_item(I18n.t("factory.select.storage"))
	storage_options.set_item_metadata(0, "")
	var storage_index := 1
	for storage_value in _view_model.storage_entities(_snapshot):
		var storage := storage_value as Dictionary
		var storage_id := str(storage.get("id", ""))
		storage_options.add_item(str(storage.get("name", storage_id)) + I18n.core("format.slash_separator") + storage_id)
		storage_options.set_item_metadata(storage_index, storage_id)
		storage_index += 1
	_inspector_body.add_child(storage_options)
	var fund_button := _make_button(I18n.t("factory.action.fund"), I18n.t("factory.tooltip.fund"))
	fund_button.disabled = storage_index <= 1
	fund_button.pressed.connect(func() -> void: _request_fund_construction(order_id, str(storage_options.get_item_metadata(storage_options.selected))))
	_inspector_body.add_child(fund_button)
	var location_fund_button := _make_button(I18n.t("factory.action.fund_location"), I18n.t("factory.tooltip.fund_location"))
	location_fund_button.pressed.connect(func() -> void: _emit_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":order_id}))
	_inspector_body.add_child(location_fund_button)
	var location_fund_help := _make_label(I18n.t("factory.help.fund_location"), Color("9aa6a1"))
	location_fund_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_body.add_child(location_fund_help)


func _add_storage_transfer_controls(storage: Dictionary) -> void:
	_inspector_body.add_child(HSeparator.new())
	_inspector_body.add_child(_make_section_label(I18n.t("factory.transfer.title")))
	var storage_id := str(storage.get("id", ""))
	var item_options := OptionButton.new()
	item_options.name = "StorageTransferItem"
	item_options.add_item(I18n.t("factory.select.item"))
	item_options.set_item_metadata(0, "")
	var storage_inventory: Dictionary = storage.get("inventory", {}) if storage.get("inventory", {}) is Dictionary else {}
	var location_inventory := _location_inventory()
	var item_ids: Array = []
	for item_id_value in storage_inventory.keys():
		if not item_ids.has(str(item_id_value)):
			item_ids.append(str(item_id_value))
	for item_id_value in location_inventory.keys():
		if not item_ids.has(str(item_id_value)):
			item_ids.append(str(item_id_value))
	item_ids.sort()
	var item_index := 1
	for item_id_value in item_ids:
		var item_id := str(item_id_value)
		item_options.add_item(_item_name(item_id))
		item_options.set_item_metadata(item_index, item_id)
		item_index += 1
	_inspector_body.add_child(item_options)
	var quantity := SpinBox.new()
	quantity.name = "StorageTransferQuantity"
	quantity.min_value = 1.0
	quantity.max_value = 999999.0
	quantity.step = 1.0
	quantity.value = 1.0
	quantity.tooltip_text = I18n.t("factory.tooltip.transfer_quantity")
	_inspector_body.add_child(quantity)
	var export_button := _make_button(I18n.t("factory.action.export"), I18n.t("factory.tooltip.export"))
	export_button.disabled = item_index <= 1
	export_button.pressed.connect(func() -> void: _request_storage_transfer("EXPORT_TO_LOCATION", storage_id, str(item_options.get_item_metadata(item_options.selected)), int(quantity.value)))
	_inspector_body.add_child(export_button)
	var import_button := _make_button(I18n.t("factory.action.import"), I18n.t("factory.tooltip.import"))
	import_button.disabled = location_inventory.is_empty()
	import_button.pressed.connect(func() -> void: _request_storage_transfer("IMPORT_FROM_LOCATION", storage_id, str(item_options.get_item_metadata(item_options.selected)), int(quantity.value)))
	_inspector_body.add_child(import_button)
	var transfer_help := _make_label(I18n.t("factory.help.transfer"), Color("9aa6a1"))
	transfer_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_body.add_child(transfer_help)


func _location_inventory() -> Dictionary:
	var source: Variant = _snapshot.get("location_available_inventory", _snapshot.get("location_inventory", {}))
	if source is Dictionary:
		var source_dict := source as Dictionary
		if source_dict.get("items", {}) is Dictionary:
			return (source_dict.get("items", {}) as Dictionary).duplicate(true)
		return source_dict.duplicate(true)
	return {}


func _add_detail(label_text: String, value: String) -> void:
	_inspector_body.add_child(_make_label(I18n.core("diagnostics.economy.demand_entry") % [label_text, value], Color("a5b2ac")))


func _add_item_dictionary(label_text: String, value: Variant) -> void:
	if not value is Dictionary or (value as Dictionary).is_empty():
		return
	var rows: Array = []
	for item_id_value in (value as Dictionary).keys():
		rows.append(I18n.core("format.item_quantity") % [_item_name(str(item_id_value)), int((value as Dictionary).get(item_id_value, 0))])
	rows.sort()
	_add_detail(label_text, ", ".join(rows))


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


func _order_by_id(order_id: String) -> Dictionary:
	for order_value in _snapshot.get("construction_orders", []):
		var order := order_value as Dictionary
		if str(order.get("id", "")) == order_id:
			return order
	return {}


func _set_feedback(code: String, message: String, color: Color) -> void:
	if _feedback_label == null:
		return
	_feedback_label.text = "[" + code + "] " + message
	_feedback_label.add_theme_color_override("font_color", color)


func _make_section_label(text_value: String) -> Label:
	var label := _make_label(text_value, Color("d5a45c"))
	label.add_theme_font_size_override("font_size", 14)
	return label


func _make_label(text_value: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_color_override("font_color", color)
	return label


func _make_button(text_value: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text_value
	button.tooltip_text = tooltip
	return button


func _status_name(status_id: String) -> String:
	return I18n.status(status_id)


func _item_name(item_id: String) -> String:
	if item_id.is_empty():
		return ""
	var names: Dictionary = _snapshot.get("item_names", {}) if _snapshot.get("item_names", {}) is Dictionary else {}
	return str(names.get(item_id, item_id.replace("_", " ").capitalize()))


func _building_name(definition_id: String, fallback: String) -> String:
	return _localized_or("factory.building.%s" % definition_id, fallback)


func _kind_name(kind_id: String) -> String:
	return _localized_or("factory.kind.%s" % kind_id.to_lower(), kind_id.replace("_", " ").capitalize())


func _category_name(category_id: String) -> String:
	return _localized_or("factory.category.%s" % category_id.to_lower(), category_id.capitalize())


func _connection_name(kind_id: String) -> String:
	return _localized_or("factory.connection.%s" % kind_id.to_lower(), kind_id.capitalize())


func _command_name(kind: String) -> String:
	return _localized_or("factory.command.%s" % kind.to_lower(), kind.replace("_", " ").capitalize())


func _localized_or(key: String, fallback: String) -> String:
	var localized: String = str(I18n.t(key))
	return fallback if localized == key else localized
