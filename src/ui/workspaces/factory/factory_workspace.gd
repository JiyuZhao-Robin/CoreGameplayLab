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
const BuildPaletteScript = preload("res://src/ui/workspaces/factory/factory_build_palette.gd")
const OperationsOverviewScript = preload("res://src/ui/workspaces/factory/factory_operations_overview.gd")
const ShipmentInspectorScript = preload("res://src/ui/workspaces/factory/factory_shipment_inspector.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const ItemArt = preload("res://src/ui/workspaces/location/location_item_icon.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const PROTOCOL_VERSION := 1
## Factory chrome uses charcoal and worn steel so the mineral/road canvas owns
## the color. Cyan is reserved for the selected construction focus; amber and
## red remain legible operational exceptions.
const UI_NAVY := Color("121615")
const UI_RAISED := Color("1b201e")
const UI_BORDER := Color("48514d")
const UI_CYAN := Color("64ddd0")
const UI_AMBER := Color("e3ad5d")
const UI_OFFWHITE := Color("e7ebe7")
const UI_MUTED := Color("a5afaa")
const UI_OPERATIONAL := Color("b7c9c0")
const UI_CRITICAL := Color("df7a6d")

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
var _road_tier := 1
var _selected_building_id := ""
var _copied_machine_config: Dictionary = {}
var _connection_kind := "CARGO"
var _connection_source_id := ""
var _connection_target_id := ""
var _connection_source_port_id := ""
var _connection_target_port_id := ""
var _selected_cargo_item_id := ""
var _active_subworkspace := "CANVAS"
var _production_filter := "ALL"
var _selection := {"kind":"", "id":"", "data":{}}
var _preview_tile := Vector2i.ZERO
var _pending_inspector_refresh := false
var _pending_link_selection_id := ""
var _pending_entity_selection_id := ""
var _pending_order_selection_id := ""
var _canvas_snapshot_dirty := true
var _canvas_startup_world_id := ""
var _canvas_focus_pending := false

var _world_label: Label
var _world_scale_label: Label
var _revision_label: Label
var _feedback_label: Label
var _reset_camera_button: Button
var _refresh_button: Button
var _toolbar_frame: Control
var _building_options: OptionButton
var _source_options: OptionButton
var _target_options: OptionButton
var _cargo_item_options: OptionButton
var _connect_button: Button
var _cargo_mode_button: Button
var _power_mode_button: Button
var _build_palette
var _connection_status_label: Label
var _connection_panel: Control
var _inspector_body: VBoxContainer
var _canvas
var _canvas_page: HBoxContainer
var _overview_page: Control
var _operations_overview
var _production_page: VBoxContainer
var _production_rows: VBoxContainer
var _production_filter_options: OptionButton
var _construction_page: VBoxContainer
var _construction_rows: VBoxContainer
var _workspace_tabs: Dictionary = {}
var _entities_by_id: Dictionary = {}
var _links_by_id: Dictionary = {}
var _orders_by_id: Dictionary = {}
var _exact_connection_keys: Dictionary = {}
var _cargo_source_item_keys: Dictionary = {}
var _cargo_target_item_keys: Dictionary = {}


func _ready() -> void:
	name = "FactoryWorkspace"
	focus_mode = Control.FOCUS_ALL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_interface()
	_apply_canvas_snapshot()
	_render()
	set_process(false)


func _process(_delta: float) -> void:
	if not _pending_inspector_refresh:
		set_process(false)
		return
	if _inspector_interaction_active():
		return
	_pending_inspector_refresh = false
	set_process(false)
	_clear_missing_selection()
	_apply_pending_command_selection()
	_render()
	if bool(_snapshot.get("landing_required", false)):
		_set_feedback("LANDING_REQUIRED", I18n.t("factory.landing.instruction", "Choose a clear site, then click to deploy your planetary development core."), UI_AMBER)
		if _active_tool.is_empty():
			_select_building_id(str(_snapshot.get("landing_definition_id", "")))


## The host may call this before or after adding this workspace to the tree.
func apply_snapshot(snapshot: Dictionary) -> void:
	var first_world := str(_snapshot.get("world_id", "")) != str(snapshot.get("world_id", ""))
	_snapshot = _view_model.build(snapshot)
	_rebuild_snapshot_lookups()
	if not _copied_machine_config.is_empty() and str(_copied_machine_config.get("world_id", "")) != str(_snapshot.get("world_id", "")):
		_copied_machine_config.clear()
	_canvas_snapshot_dirty = true
	if _active_subworkspace == "CANVAS":
		_apply_canvas_snapshot()
	elif _canvas != null and (_canvas.get("_snapshot") as Dictionary).is_empty():
		# A hidden canvas still receives its first immutable payload so focused UI
		# tests and later canvas gestures begin from a valid physical world. Further
		# hidden refreshes remain deferred to preserve the spatial-index contract.
		_apply_canvas_snapshot()
	# Runtime refreshes must not destroy an active inspector control or close an
	# open selector. The next refresh after the interaction ends performs the
	# normal rebuild with the latest immutable snapshot.
	if _inspector_interaction_active():
		_pending_inspector_refresh = true
		set_process(true)
		_world_label.text = I18n.t("factory.operations.world_telemetry", "LOCAL GRID · %s") % _location_telemetry_name()
		_refresh_world_scale()
		_revision_label.text = "ⓘ"
		_revision_label.tooltip_text = _revision_tooltip()
		return
	_pending_inspector_refresh = false
	set_process(false)
	_clear_missing_selection()
	_apply_pending_command_selection()
	_render()
	if bool(_snapshot.get("landing_required", false)):
		if first_world:
			_canvas.set("_zoom", 1.5)
			_canvas.focus_tile(Vector2i(80, 48))
		_set_feedback("LANDING_REQUIRED", I18n.t("factory.landing.instruction", "Choose a clear site and deploy the planetary core."), UI_AMBER)
		if _active_tool.is_empty():
			_select_building_id(str(_snapshot.get("landing_definition_id", "")))


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
		var operation_result: Dictionary = result.get("result", {}) if result.get("result", {}) is Dictionary else {}
		var accepted_message: String = message if not message.is_empty() else I18n.t("factory.feedback.accepted")
		var command_kind := str(result.get("command_kind", "")).to_upper()
		_set_feedback("ACCEPTED", accepted_message, UI_CYAN)
		if command_kind == "CONNECT_ENTITIES":
			_pending_link_selection_id = str(operation_result.get("link_id", ""))
			_active_tool = ""
			_connection_source_id = ""
			_connection_target_id = ""
			_selected_cargo_item_id = ""
		elif command_kind in ["QUEUE_CONSTRUCTION", "DEPLOY_BUILDING"]:
			if bool(operation_result.get("deployed", false)):
				_pending_entity_selection_id = str(operation_result.get("entity_id", ""))
				_pending_order_selection_id = ""
			else:
				_pending_entity_selection_id = ""
				_pending_order_selection_id = str(operation_result.get("order_id", ""))
	else:
		var rejection_code := reason_code if not reason_code.is_empty() else "COMMAND_REJECTED"
		var rejection_key := "factory.reason.%s" % rejection_code.to_lower()
		var localized_message: String = str(I18n.t(rejection_key))
		if localized_message == rejection_key:
			localized_message = message if not message.is_empty() else I18n.t("factory.feedback.rejected")
		_set_feedback(rejection_code, localized_message, UI_CRITICAL)
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
		_set_feedback("NO_FACTORY_WORLD", I18n.t("factory.feedback.no_world"), UI_CRITICAL)
		return
	refresh_requested.emit(world_id)


func selected_entity_id() -> String:
	return str(_selection.get("id", "")) if str(_selection.get("kind", "")) == "ENTITY" else ""


func selected_link_id() -> String:
	return str(_selection.get("id", "")) if str(_selection.get("kind", "")) == "LINK" else ""


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event.is_action_pressed("ui_cancel") and _active_tool in ["BUILD", "CONNECT", "ROAD_BUILD", "ROAD_REMOVE"]:
		_on_placement_cancelled()
		get_viewport().set_input_as_handled()
		return
	if _active_tool in ["BUILD", "CONNECT", "ROAD_BUILD", "ROAD_REMOVE"]:
		return
	if not event is InputEventKey or _shortcut_focus_blocked():
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or not (key_event.ctrl_pressed or key_event.meta_pressed):
		return
	if key_event.keycode == KEY_C:
		_copy_selected_machine_configuration()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_V:
		_paste_machine_configuration()
		get_viewport().set_input_as_handled()


func _shortcut_focus_blocked() -> bool:
	if not is_inside_tree():
		return false
	var focused := get_viewport().gui_get_focus_owner()
	if is_instance_valid(focused) and (focused is LineEdit or focused is TextEdit):
		return true
	for option_value in find_children("*", "OptionButton", true, false):
		var option := option_value as OptionButton
		if option.get_popup().visible:
			return true
	return false


func canvas() -> Control:
	return _canvas


func _build_interface() -> void:
	var root := VBoxContainer.new()
	root.name = "WorkspaceLayout"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	_toolbar_frame = PanelContainer.new()
	_toolbar_frame.name = "FactoryToolbarChrome"
	_toolbar_frame.add_theme_stylebox_override("panel", UiTokens.control_style(UI_RAISED, UI_BORDER, 3))
	root.add_child(_toolbar_frame)
	var toolbar := HBoxContainer.new()
	toolbar.name = "FactoryToolbar"
	toolbar.custom_minimum_size = Vector2(0, 32)
	_toolbar_frame.add_child(toolbar)
	_world_label = _make_label(I18n.t("factory.workspace.label"), UI_OFFWHITE)
	_world_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(_world_label)
	_feedback_label = _make_label("", UI_AMBER)
	_feedback_label.name = "FactoryCommandFeedback"
	_feedback_label.visible = false
	_feedback_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_feedback_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	toolbar.add_child(_feedback_label)
	_world_scale_label = _make_label("", UI_AMBER)
	_world_scale_label.name = "FactoryWorldScale"
	toolbar.add_child(_world_scale_label)
	_revision_label = _make_label("ⓘ", UI_MUTED)
	_revision_label.name = "FactoryRevisionInfo"
	_revision_label.custom_minimum_size = UiTokens.layout_vector(Vector2(20, 0))
	_revision_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toolbar.add_child(_revision_label)
	_reset_camera_button = _make_button(I18n.t("factory.action.reset_view"), I18n.t("factory.tooltip.reset_view"))
	_reset_camera_button.pressed.connect(func() -> void: _canvas.reset_camera())
	toolbar.add_child(_reset_camera_button)
	_refresh_button = _make_button(I18n.t("factory.action.refresh"), I18n.t("factory.tooltip.refresh"))
	_refresh_button.pressed.connect(request_refresh)
	toolbar.add_child(_refresh_button)
	var motion_toggle := CheckButton.new()
	motion_toggle.text = I18n.t("factory.action.reduced_motion")
	motion_toggle.tooltip_text = I18n.t("factory.tooltip.reduced_motion")
	motion_toggle.button_pressed = _reduced_motion
	motion_toggle.toggled.connect(set_reduced_motion)
	toolbar.add_child(motion_toggle)

	# The factory is a control room, not just a build palette. Keep the four
	# workspaces mounted and switch visibility so selector focus and canvas state
	# survive tab changes and runtime snapshot refreshes.
	var tabs_frame := PanelContainer.new()
	tabs_frame.name = "FactoryWorkspaceTabsChrome"
	tabs_frame.add_theme_stylebox_override("panel", UiTokens.control_style(UI_NAVY, UI_BORDER, 3))
	root.add_child(tabs_frame)
	var tabs := HBoxContainer.new()
	tabs.name = "FactoryWorkspaceTabs"
	tabs.add_theme_constant_override("separation", 5)
	tabs_frame.add_child(tabs)
	for workspace_id in ["OVERVIEW", "CANVAS", "PRODUCTION", "CONSTRUCTION"]:
		var tab := _make_button(
			I18n.t("factory.tab.%s" % workspace_id.to_lower(), workspace_id.capitalize()),
			I18n.t("factory.tooltip.open_%s" % workspace_id.to_lower(), "Open %s workspace" % workspace_id.to_lower())
		)
		tab.name = "FactoryTab%s" % workspace_id.capitalize()
		tab.custom_minimum_size = UiTokens.layout_vector(Vector2(120, 36))
		tab.toggle_mode = true
		tab.pressed.connect(_set_active_subworkspace.bind(workspace_id))
		tabs.add_child(tab)
		_workspace_tabs[workspace_id] = tab

	_build_overview_workspace(root)

	var body := HBoxContainer.new()
	body.name = "FactoryCanvasWorkspace"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)
	_canvas_page = body

	var center_column := VBoxContainer.new()
	center_column.name = "FactoryCenterColumn"
	center_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_column.add_theme_constant_override("separation", 6)
	body.add_child(center_column)

	# Direct canvas ports are the primary route workflow. Keep the selectors as a
	# compact keyboard/accessibility fallback without sacrificing canvas width.
	_connection_panel = PanelContainer.new()
	_connection_panel.name = "FactoryConnectionAssist"
	_connection_panel.add_theme_stylebox_override("panel", UiTokens.control_style(UI_RAISED, UI_BORDER, 3))
	center_column.add_child(_connection_panel)
	var connection_modes := HBoxContainer.new()
	connection_modes.name = "FactoryConnectionTools"
	connection_modes.add_theme_constant_override("separation", 5)
	_connection_panel.add_child(connection_modes)
	connection_modes.add_child(_make_section_label(I18n.t("factory.palette.connections")))
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
	_source_options.fit_to_longest_item = false
	_source_options.custom_minimum_size.x = 126
	_source_options.item_selected.connect(_on_source_selected)
	connection_modes.add_child(_source_options)
	_target_options = OptionButton.new()
	_target_options.name = "ConnectionTarget"
	_target_options.tooltip_text = I18n.t("factory.tooltip.connection_target")
	_target_options.fit_to_longest_item = false
	_target_options.custom_minimum_size.x = 126
	_target_options.item_selected.connect(_on_target_selected)
	connection_modes.add_child(_target_options)
	_cargo_item_options = OptionButton.new()
	_cargo_item_options.name = "CargoItem"
	_cargo_item_options.tooltip_text = I18n.t("factory.tooltip.cargo_item")
	_cargo_item_options.fit_to_longest_item = false
	_cargo_item_options.custom_minimum_size.x = 112
	_cargo_item_options.item_selected.connect(_on_cargo_item_selected)
	connection_modes.add_child(_cargo_item_options)
	_connect_button = _make_button(I18n.t("factory.action.create_connection"), I18n.t("factory.tooltip.create_connection"))
	_connect_button.name = "CreateConnection"
	_connect_button.pressed.connect(_request_connection)
	connection_modes.add_child(_connect_button)
	_connection_status_label = _make_label("", UI_MUTED)
	_connection_status_label.name = "ConnectionStatus"
	_connection_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_connection_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_connection_status_label.tooltip_text = I18n.t("factory.help.connection")
	connection_modes.add_child(_connection_status_label)

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
	_canvas.placement_cancelled.connect(_on_placement_cancelled)
	_canvas.machine_configuration_copy_requested.connect(_on_canvas_machine_configuration_copy_requested)
	_canvas.machine_configuration_paste_requested.connect(_on_canvas_machine_configuration_paste_requested)
	_canvas.port_drag_started.connect(_on_port_drag_started)
	_canvas.port_connection_requested.connect(_on_port_connection_requested)
	_canvas.port_drag_preview.connect(_on_port_drag_preview)
	_canvas.road_path_requested.connect(_on_road_path_requested)
	_canvas.road_path_rejected.connect(_on_road_path_rejected)
	center_column.add_child(_canvas)

	_build_palette = BuildPaletteScript.new()
	_build_palette.building_selected.connect(_select_building_id)
	_build_palette.road_tool_selected.connect(_set_road_tool)
	_build_palette.collapsed_changed.connect(_on_build_palette_collapsed_changed)
	center_column.add_child(_build_palette)
	_build_palette.ensure_built()
	_building_options = _build_palette.quick_filter()

	# A bare Panel deliberately owns the rail's minimum width.  PanelContainer
	# would inherit its scroll child's unwrapped Label minimum, allowing a long
	# empty-state sentence to consume the canvas.  The scroll content is clipped
	# and wrapped inside this authored rail instead.
	var inspector_rail := Panel.new()
	inspector_rail.name = "FactoryInspectorRail"
	inspector_rail.custom_minimum_size = Vector2(UiTokens.layout_px(312), 0)
	inspector_rail.size_flags_horizontal = Control.SIZE_SHRINK_END
	inspector_rail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inspector_rail.clip_contents = true
	inspector_rail.add_theme_stylebox_override("panel", UiTokens.control_style(UI_NAVY, UI_BORDER, 3))
	body.add_child(inspector_rail)
	var inspector_scroll := ScrollContainer.new()
	inspector_scroll.name = "InspectorScroll"
	inspector_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var inspector_inset := UiTokens.layout_px(8)
	inspector_scroll.offset_left = inspector_inset
	inspector_scroll.offset_top = inspector_inset
	inspector_scroll.offset_right = -inspector_inset
	inspector_scroll.offset_bottom = -inspector_inset
	inspector_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inspector_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	inspector_rail.add_child(inspector_scroll)
	_inspector_body = VBoxContainer.new()
	_inspector_body.name = "FactoryInspector"
	_inspector_body.custom_minimum_size = Vector2.ZERO
	_inspector_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_body.add_theme_constant_override("separation", 6)
	inspector_scroll.add_child(_inspector_body)

	_build_production_workspace(root)
	_build_construction_workspace(root)

func _build_overview_workspace(root: VBoxContainer) -> void:
	_overview_page = VBoxContainer.new()
	_overview_page.name = "FactoryOverviewWorkspace"
	_overview_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_overview_page)
	_operations_overview = OperationsOverviewScript.new()
	_operations_overview.action_requested.connect(_on_operations_action_requested)
	_overview_page.add_child(_operations_overview)


func _build_production_workspace(root: VBoxContainer) -> void:
	_production_page = VBoxContainer.new()
	_production_page.name = "FactoryProductionWorkspace"
	_production_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_production_page.add_theme_constant_override("separation", 8)
	root.add_child(_production_page)
	var header_panel := PanelContainer.new()
	header_panel.name = "ProductionBoardHeader"
	header_panel.add_theme_stylebox_override("panel", UiTokens.control_style(UI_RAISED, UI_BORDER, 4))
	_production_page.add_child(header_panel)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTokens.layout_px(12))
	header_panel.add_child(header)
	var headings := VBoxContainer.new()
	headings.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	headings.add_theme_constant_override("separation", 1)
	header.add_child(headings)
	var title := _make_section_label(I18n.t("factory.production.title", "Production management"))
	headings.add_child(title)
	headings.add_child(_make_label(I18n.t("factory.operations.production_board_hint", "Live rate, utilization and connected routes"), UI_MUTED))
	_production_filter_options = OptionButton.new()
	_production_filter_options.name = "ProductionStatusFilter"
	_production_filter_options.tooltip_text = I18n.t("factory.operations.production_board_hint", "Live rate, utilization and connected routes")
	_production_filter_options.add_theme_stylebox_override("normal", UiTokens.control_style(UI_NAVY, UI_BORDER, 3))
	_production_filter_options.add_theme_stylebox_override("focus", UiTokens.control_style(UI_NAVY, UI_CYAN, 3))
	for filter_id in ["ALL", "RUNNING", "INPUT_SHORTAGE", "OUTPUT_FULL", "BLOCKED", "IDLE"]:
		_production_filter_options.add_item(I18n.t("factory.production.filter.%s" % filter_id.to_lower(), filter_id.replace("_", " ").capitalize()))
		_production_filter_options.set_item_metadata(_production_filter_options.item_count - 1, filter_id)
	_production_filter_options.item_selected.connect(func(index: int) -> void:
		_production_filter = str(_production_filter_options.get_item_metadata(index))
		_refresh_production_workspace()
	)
	header.add_child(_production_filter_options)
	var scroll := ScrollContainer.new()
	scroll.name = "ProductionScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_production_page.add_child(scroll)
	_production_rows = VBoxContainer.new()
	_production_rows.name = "ProductionRows"
	_production_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_production_rows.add_theme_constant_override("separation", 6)
	scroll.add_child(_production_rows)


func _build_construction_workspace(root: VBoxContainer) -> void:
	_construction_page = VBoxContainer.new()
	_construction_page.name = "FactoryConstructionWorkspace"
	_construction_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_construction_page.add_theme_constant_override("separation", 8)
	root.add_child(_construction_page)
	var header_panel := PanelContainer.new()
	header_panel.name = "ConstructionBoardHeader"
	header_panel.add_theme_stylebox_override("panel", UiTokens.control_style(UI_RAISED, UI_BORDER, 4))
	_construction_page.add_child(header_panel)
	var headings := VBoxContainer.new()
	headings.add_theme_constant_override("separation", 1)
	header_panel.add_child(headings)
	headings.add_child(_make_section_label(I18n.t("factory.deployment.title", "Deployment ghosts")))
	headings.add_child(_make_label(I18n.t("factory.deployment.hint", "Missing finished buildings deploy automatically when they reach planet inventory."), UI_MUTED))
	var scroll := ScrollContainer.new()
	scroll.name = "ConstructionScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_construction_page.add_child(scroll)
	_construction_rows = VBoxContainer.new()
	_construction_rows.name = "ConstructionRows"
	_construction_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_construction_rows.add_theme_constant_override("separation", 7)
	scroll.add_child(_construction_rows)


func _set_active_subworkspace(workspace_id: String) -> void:
	_active_subworkspace = workspace_id if workspace_id in ["OVERVIEW", "CANVAS", "PRODUCTION", "CONSTRUCTION"] else "CANVAS"
	if _overview_page != null:
		_overview_page.visible = _active_subworkspace == "OVERVIEW"
	if _toolbar_frame != null:
		_toolbar_frame.visible = _active_subworkspace != "OVERVIEW"
	if _canvas_page != null:
		_canvas_page.visible = _active_subworkspace == "CANVAS"
	if _production_page != null:
		_production_page.visible = _active_subworkspace == "PRODUCTION"
	if _construction_page != null:
		_construction_page.visible = _active_subworkspace == "CONSTRUCTION"
	for workspace_id_value in _workspace_tabs.keys():
		var tab: Button = _workspace_tabs.get(workspace_id_value) as Button
		if tab != null:
			tab.button_pressed = str(workspace_id_value) == _active_subworkspace
	if _reset_camera_button != null:
		_reset_camera_button.visible = _active_subworkspace == "CANVAS"
	if _refresh_button != null:
		_refresh_button.visible = _active_subworkspace == "CANVAS"
	if _active_subworkspace == "OVERVIEW" and _operations_overview != null:
		_operations_overview.configure(_snapshot)
	elif _active_subworkspace == "CANVAS" and _canvas_snapshot_dirty:
		_apply_canvas_snapshot()
	if _active_subworkspace == "CANVAS":
		_schedule_pending_canvas_focus()
	elif _active_subworkspace == "PRODUCTION":
		_refresh_production_workspace()
	elif _active_subworkspace == "CONSTRUCTION":
		_refresh_construction_workspace()


func _render() -> void:
	if not is_instance_valid(_building_options):
		return
	var is_valid := bool(_snapshot.get("valid", false)) and int(_snapshot.get("protocol_version", 0)) == PROTOCOL_VERSION
	_world_label.text = I18n.t("factory.operations.world_telemetry", "LOCAL GRID · %s") % _location_telemetry_name()
	_revision_label.text = "ⓘ"
	_revision_label.tooltip_text = _revision_tooltip()
	_refresh_world_scale()
	if _operations_overview != null:
		_operations_overview.configure(_snapshot)
	var road_mode := _road_logistics_mode()
	if road_mode and _active_tool == "CONNECT":
		_clear_connection_state()
		_active_tool = ""
	if road_mode and str(_selection.get("kind", "")) == "LINK":
		_selection = {"kind":"", "id":"", "data":{}}
	if _connection_panel != null:
		_connection_panel.visible = not road_mode
	_rebuild_palette(is_valid)
	if not road_mode:
		_rebuild_connection_selectors(is_valid)
	_refresh_inspector()
	_set_active_subworkspace(_active_subworkspace)
	_canvas.set_road_logistics_mode(road_mode)
	_canvas.set_configuration_gestures_enabled(_active_tool not in ["BUILD", "CONNECT", "ROAD_BUILD", "ROAD_REMOVE"])
	_canvas.set_port_connections_enabled(not road_mode and _active_tool != "BUILD")
	_canvas.set_road_tool(_road_canvas_tool(), _road_tier)
	_update_placement_preview()
	_update_connection_preview()
func _apply_canvas_snapshot() -> void:
	if _canvas == null:
		return
	# The workspace already normalized and detached this immutable presentation
	# payload. Passing it through avoids a second deep copy and sort in Canvas.
	_canvas.apply_snapshot(_snapshot, true)
	var world_id := str(_snapshot.get("world_id", ""))
	if world_id != _canvas_startup_world_id:
		_canvas_startup_world_id = world_id
		_canvas_focus_pending = true
	_canvas.set_reduced_motion(_reduced_motion)
	_canvas_snapshot_dirty = false
	_schedule_pending_canvas_focus()


func _schedule_pending_canvas_focus() -> void:
	if not _canvas_focus_pending or _canvas == null or _active_subworkspace != "CANVAS":
		return
	call_deferred("_apply_pending_canvas_focus")


func _apply_pending_canvas_focus() -> void:
	if not _canvas_focus_pending or _canvas == null or _active_subworkspace != "CANVAS":
		return
	# Canvas pages may be hidden during their first snapshot. Deferring until the
	# mounted page has a real authored rectangle prevents a 0px-size overview zoom
	# from being retained as the first operational camera.
	if _canvas.size.x < 64.0 or _canvas.size.y < 64.0:
		call_deferred("_apply_pending_canvas_focus")
		return
	if bool(_snapshot.get("landing_required", false)):
		_canvas.set("_zoom", 1.5)
		_canvas.focus_tile(Vector2i(80, 48))
	else:
		_canvas.focus_operational_region()
	_canvas_focus_pending = false


func _rebuild_palette(is_valid: bool) -> void:
	var palette: Dictionary = _snapshot.get("palette", {}) if _snapshot.get("palette", {}) is Dictionary else {}
	_build_palette.set_buildings(palette.get("buildings", []) as Array, is_valid, _selected_building_id)
	_build_palette.set_road_tools_enabled(_road_logistics_mode(), _road_canvas_tool(), _road_tier, is_valid)


func _rebuild_connection_selectors(is_valid: bool) -> void:
	_populate_entity_options(_source_options, I18n.t("factory.select.source"), _connection_source_id, "SOURCE")
	_populate_entity_options(_target_options, I18n.t("factory.select.target"), _connection_target_id, "TARGET")
	_source_options.disabled = not is_valid
	_target_options.disabled = not is_valid
	_cargo_item_options.clear()
	_cargo_item_options.add_item(I18n.t("factory.select.cargo_item"))
	_cargo_item_options.set_item_metadata(0, "")
	var source := _entity_by_id(_connection_source_id)
	var target := _entity_by_id(_connection_target_id)
	var item_index := 1
	for item_value in _view_model.compatible_cargo_items(source, target, _catalog_item_ids()):
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
	_refresh_connection_status(source, target)


func _populate_entity_options(options: OptionButton, placeholder: String, selected_id: String, role: String) -> void:
	options.clear()
	options.add_item(placeholder)
	options.set_item_metadata(0, "")
	var index := 1
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		var entity_id := str(entity.get("id", ""))
		if not _entity_is_connection_candidate(entity, role):
			continue
		options.add_item(str(entity.get("name", entity_id)) + I18n.core("format.slash_separator") + entity_id)
		options.set_item_metadata(index, entity_id)
		if entity_id == selected_id:
			options.select(index)
		index += 1
	if options.selected < 0:
		options.select(0)


func _entity_is_connection_candidate(entity: Dictionary, role: String) -> bool:
	var entity_id := str(entity.get("id", ""))
	if role == "TARGET" and entity_id == _connection_source_id:
		return false
	var ports: Dictionary = entity.get("ports", {}) if entity.get("ports", {}) is Dictionary else {}
	if role == "SOURCE":
		return bool(ports.get("provides_power", false)) if _connection_kind == "POWER" else not (ports.get("outputs", []) as Array).is_empty()
	var source := _entity_by_id(_connection_source_id)
	if source.is_empty():
		return bool(ports.get("accepts_power", false)) if _connection_kind == "POWER" else not (ports.get("inputs", []) as Array).is_empty()
	return _view_model.is_power_connection_valid(source, entity) if _connection_kind == "POWER" else not _view_model.compatible_cargo_items(source, entity, _catalog_item_ids()).is_empty()


func _refresh_world_scale() -> void:
	if not is_instance_valid(_world_scale_label):
		return
	if _road_logistics_mode():
		var logistics: Dictionary = _snapshot.get("road_logistics", {}) if _snapshot.get("road_logistics", {}) is Dictionary else {}
		_world_scale_label.text = I18n.t("factory.road.network_metrics", "%d nodes · %d road tiles · %d/%d capacity") % [
			(_snapshot.get("entities", []) as Array).size(),
			(_snapshot.get("roads", []) as Array).size(),
			int(logistics.get("required", 0)),
			int(logistics.get("capacity", 0))
		]
		_world_scale_label.tooltip_text = I18n.t("factory.road.network_tooltip", "%d active shipments · %d%% utilization") % [
			int(logistics.get("active_shipments", 0)),
			roundi(clampf(float(logistics.get("utilization", 0.0)), 0.0, 1.0) * 100.0)
		]
		return
	_world_scale_label.text = I18n.t("factory.operations.network_metrics", "%d nodes · %d routes · %d orders") % [
		(_snapshot.get("entities", []) as Array).size(),
		(_snapshot.get("links", []) as Array).size(),
		(_snapshot.get("construction_orders", []) as Array).size()
	]
	var bounds: Dictionary = _snapshot.get("bounds", {}) if _snapshot.get("bounds", {}) is Dictionary else {}
	var extent := _view_model.footprint_size(bounds)
	var chunk_size := maxi(1, int(_snapshot.get("chunk_size_tiles", 64)))
	var profile: Dictionary = _snapshot.get("world_profile", {}) if _snapshot.get("world_profile", {}) is Dictionary else {}
	var scale_class := str(profile.get("scale_class", ""))
	_world_scale_label.tooltip_text = I18n.t("factory.workspace.scale") % [
		extent.x,
		extent.y,
		ceili(float(extent.x) / float(chunk_size)),
		ceili(float(extent.y) / float(chunk_size)),
		scale_class if not scale_class.is_empty() else I18n.t("factory.workspace.custom_scale", "CUSTOM")
	]


func _location_telemetry_name() -> String:
	var location_name := str(_snapshot.get("location_name", ""))
	return location_name if not location_name.is_empty() else str(_snapshot.get("world_id", I18n.t("factory.workspace.unavailable")))


func _road_logistics_mode() -> bool:
	return str(_snapshot.get("logistics_mode", "")).to_upper() == "PLANET_SHARED_ROADS"


func _road_canvas_tool() -> String:
	if _active_tool == "ROAD_BUILD":
		return "BUILD"
	if _active_tool == "ROAD_REMOVE":
		return "REMOVE"
	return ""


func _clear_connection_state() -> void:
	_connection_source_id = ""
	_connection_target_id = ""
	_connection_source_port_id = ""
	_connection_target_port_id = ""
	_selected_cargo_item_id = ""


func _refresh_connection_status(source: Dictionary, target: Dictionary) -> void:
	if not is_instance_valid(_connection_status_label):
		return
	var text_value: String = str(I18n.t("factory.connection.choose_mode", "Choose Cargo or Power to start connecting visible node ports."))
	var tone := Color("9aa6a1")
	if _active_tool == "CONNECT":
		if source.is_empty():
			text_value = I18n.t("factory.connection.step_source", "1/2 · Select an output/source node on the canvas.")
			tone = Color("d5a45c")
		elif target.is_empty():
			text_value = I18n.t("factory.connection.step_target", "2/2 · Select a compatible input/target node.")
			tone = Color("d5a45c")
		elif _connection_is_ready(source, target):
			text_value = I18n.t("factory.connection.ready", "Route valid · confirm the connection.")
			tone = Color("6fbf92")
		else:
			var reason_code := _connection_validation_reason(source, target)
			var reason_key := "factory.reason.%s" % reason_code.to_lower()
			text_value = str(I18n.t(reason_key))
			if text_value == reason_key:
				text_value = I18n.t("factory.connection.incompatible", "These ports are incompatible; choose another target or cargo item.")
			tone = Color("d86e63")
	_connection_status_label.text = text_value
	_connection_status_label.add_theme_color_override("font_color", tone)


func _clear_rows(container: VBoxContainer) -> void:
	if container == null:
		return
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _production_records() -> Array:
	var records: Array = []
	var production: Dictionary = _snapshot.get("production", {}) if _snapshot.get("production", {}) is Dictionary else {}
	var extended_by_entity: Dictionary = {}
	var production_rows: Array = production.get("rows", production.get("production_rows", production.get("machines", []))) if production.get("rows", production.get("production_rows", production.get("machines", []))) is Array else []
	for row_value in production_rows:
		if row_value is Dictionary:
			var row: Dictionary = row_value as Dictionary
			extended_by_entity[str(row.get("entity_id", row.get("id", "")))] = row
	for entity_value in _snapshot.get("entities", []):
		if not entity_value is Dictionary:
			continue
		var entity: Dictionary = entity_value as Dictionary
		var node_kind := str(entity.get("node_kind", ""))
		if node_kind not in ["MACHINE", "EXTRACTOR", "ROUTER"]:
			continue
		var entity_id := str(entity.get("id", ""))
		var row: Dictionary = extended_by_entity.get(entity_id, {}) as Dictionary
		records.append({"entity":entity, "production":row})
	return records


func _refresh_production_workspace() -> void:
	if _production_rows == null:
		return
	_clear_rows(_production_rows)
	var records := _production_records()
	var counts := {"RUNNING":0, "INPUT_SHORTAGE":0, "OUTPUT_FULL":0, "BLOCKED":0, "IDLE":0}
	for record_value in records:
		var record: Dictionary = record_value as Dictionary
		var entity: Dictionary = record.get("entity", {}) as Dictionary
		var status := str(entity.get("status", "IDLE")).to_upper()
		if status in ["FLOWING", "CONNECTED", "POWER_LIMITED", "PARTIAL_COVERAGE"]:
			status = "RUNNING"
		elif status == "READY":
			status = "IDLE"
		elif status in ["NO_POWER", "SOURCE_EMPTY", "WAITING_MATERIALS"]:
			status = "INPUT_SHORTAGE"
		elif status in ["TARGET_FULL"]:
			status = "OUTPUT_FULL"
		elif status not in counts:
			status = "BLOCKED" if not str(entity.get("blocker_code", "")).is_empty() else "IDLE"
		counts[status] = int(counts.get(status, 0)) + 1
	var production_summary: Dictionary = {}
	if _snapshot.get("production", {}) is Dictionary:
		var production: Dictionary = _snapshot.get("production", {}) as Dictionary
		if production.get("summary", {}) is Dictionary:
			production_summary = production.get("summary", {}) as Dictionary
	var summary_panel := PanelContainer.new()
	summary_panel.name = "ProductionStatusSummaryPanel"
	summary_panel.add_theme_stylebox_override("panel", UiTokens.control_style(UI_NAVY, Color(UI_CYAN, 0.52), 3))
	_production_rows.add_child(summary_panel)
	var summary := _make_label(I18n.t("factory.production.summary", "Running %d · input shortage %d · output full %d · blocked %d · idle %d") % [int(production_summary.get("running", counts.get("RUNNING", 0))), int(production_summary.get("input_shortage", counts.get("INPUT_SHORTAGE", 0))), int(production_summary.get("output_full", counts.get("OUTPUT_FULL", 0))), int(production_summary.get("blocked", counts.get("BLOCKED", 0))), int(production_summary.get("idle", counts.get("IDLE", 0)))], UI_AMBER)
	summary.name = "ProductionStatusSummary"
	summary_panel.add_child(summary)
	_production_rows.add_child(_production_material_ledger())
	for record_value in records:
		var record: Dictionary = record_value as Dictionary
		var entity: Dictionary = record.get("entity", {}) as Dictionary
		var row: Dictionary = record.get("production", {}) as Dictionary
		var status := str(row.get("status", entity.get("status", "IDLE"))).to_upper()
		var normalized_status := status
		if normalized_status in ["FLOWING", "CONNECTED", "POWER_LIMITED", "PARTIAL_COVERAGE"]:
			normalized_status = "RUNNING"
		elif normalized_status == "READY":
			normalized_status = "IDLE"
		elif normalized_status in ["NO_POWER", "SOURCE_EMPTY", "WAITING_MATERIALS"]:
			normalized_status = "INPUT_SHORTAGE"
		elif normalized_status == "TARGET_FULL":
			normalized_status = "OUTPUT_FULL"
		elif normalized_status not in counts:
			normalized_status = "BLOCKED" if not str(entity.get("blocker_code", "")).is_empty() else "IDLE"
		if _production_filter != "ALL" and normalized_status != _production_filter:
			continue
		var panel := PanelContainer.new()
		panel.name = "ProductionRow%s" % str(entity.get("id", ""))
		panel.custom_minimum_size.y = UiTokens.layout_px(126)
		panel.add_theme_stylebox_override("panel", UiTokens.control_style(UI_RAISED, Color(_status_color(normalized_status), 0.68), 3))
		_production_rows.add_child(panel)
		var layout := HBoxContainer.new()
		layout.add_theme_constant_override("separation", UiTokens.layout_px(10))
		panel.add_child(layout)
		layout.add_child(_building_thumbnail(str(entity.get("definition_id", "")), str(entity.get("node_kind", "")), _status_color(normalized_status), Vector2(104, 96)))
		var body := VBoxContainer.new()
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_theme_constant_override("separation", UiTokens.layout_px(4))
		layout.add_child(body)
		var header := HBoxContainer.new()
		body.add_child(header)
		var title := _make_label("%s · %s" % [str(entity.get("name", entity.get("id", I18n.t("factory.value.unit", "Unit")))), _status_name(normalized_status)], _status_color(normalized_status))
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(title)
		var focus := _make_button(I18n.t("factory.action.focus", "Focus"), I18n.t("factory.tooltip.focus_production", "Locate this production unit on the canvas"))
		focus.name = "FocusProduction%s" % str(entity.get("id", ""))
		focus.pressed.connect(_focus_entity_from_workspace.bind(entity.duplicate(true)))
		header.add_child(focus)
		var rate := float(row.get("rate_per_second", row.get("actual_rate", entity.get("actual_rate", 0.0))))
		var utilization := clampf(float(row.get("utilization", entity.get("utilization", entity.get("power_factor", 0.0)))), 0.0, 1.0)
		var recipe_name := _production_recipe_name(entity)
		body.add_child(_make_label((recipe_name + " · " if not recipe_name.is_empty() else "") + I18n.t("factory.production.rate", "Rate %.2f/s · utilization %d%%") % [rate, roundi(utilization * 100.0)], UI_OFFWHITE))
		var io := _production_io_line(entity)
		if not io.is_empty():
			body.add_child(_make_label(io, UI_MUTED))
		var meter := ProgressBar.new()
		meter.name = "ProductionUtilizationMeter"
		meter.max_value = 100.0
		meter.value = utilization * 100.0
		meter.show_percentage = false
		meter.add_theme_stylebox_override("background", UiTokens.panel_style(UI_NAVY, UI_BORDER, 2))
		meter.add_theme_stylebox_override("fill", UiTokens.panel_style(_status_color(normalized_status), _status_color(normalized_status), 2))
		body.add_child(meter)
		var blocker := str(row.get("blocker", row.get("blocked_reason", entity.get("blocker_code", ""))))
		if not blocker.is_empty():
			body.add_child(_make_label(I18n.t("factory.operations.constraint", "Constraint: %s") % _status_name(blocker), UI_CRITICAL))
		var deficit := _production_deficit_line(entity)
		if not deficit.is_empty():
			body.add_child(_make_label(deficit, UI_AMBER))
		var routes := HFlowContainer.new()
		body.add_child(routes)
		for neighbor_value in row.get("upstream", []):
			var upstream := _entity_by_id(str((neighbor_value as Dictionary).get("entity_id", "")))
			if not upstream.is_empty():
				var upstream_button := _make_button("↑ %s" % str(upstream.get("name", upstream.get("id", ""))), I18n.t("factory.tooltip.focus_upstream", "Focus upstream provider"))
				upstream_button.pressed.connect(_focus_entity_from_workspace.bind(upstream.duplicate(true)))
				routes.add_child(upstream_button)
		for neighbor_value in row.get("downstream", []):
			var downstream := _entity_by_id(str((neighbor_value as Dictionary).get("entity_id", "")))
			if not downstream.is_empty():
				var downstream_button := _make_button("↓ %s" % str(downstream.get("name", downstream.get("id", ""))), I18n.t("factory.tooltip.focus_downstream", "Focus downstream consumer"))
				downstream_button.pressed.connect(_focus_entity_from_workspace.bind(downstream.duplicate(true)))
				routes.add_child(downstream_button)
		if routes.get_child_count() == 0:
			routes.queue_free()
	if _production_rows.get_child_count() == 2:
		_production_rows.add_child(_make_label(I18n.t("factory.production.empty", "No units match this status filter."), UI_MUTED))
		_production_rows.add_child(_empty_state_open_build_button("PRODUCTION", "FactoryProductionEmptyOpenBuild"))


func _production_material_ledger() -> Control:
	var panel := PanelContainer.new()
	panel.name = "ProductionMaterialLedger"
	panel.add_theme_stylebox_override("panel", UiTokens.control_style(UI_NAVY, Color(UI_CYAN, 0.48), 3))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(3))
	panel.add_child(body)
	var heading := _make_label(I18n.t("factory.operations.flow_ledger", "Material flow ledger"), UI_CYAN)
	heading.name = "ProductionMaterialLedgerTitle"
	body.add_child(heading)
	var header := HBoxContainer.new()
	header.add_child(_flow_column_label(I18n.t("factory.operations.material", "Material"), 0.42, UI_MUTED))
	header.add_child(_flow_column_label(I18n.t("factory.operations.flow_output", "Output /s"), 0.19, UI_MUTED))
	header.add_child(_flow_column_label(I18n.t("factory.operations.flow_input", "Input /s"), 0.19, UI_MUTED))
	header.add_child(_flow_column_label(I18n.t("factory.operations.flow_storage", "Storage"), 0.20, UI_MUTED))
	body.add_child(header)
	var flow_rows := 0
	for material_value in _operations_materials():
		if not material_value is Dictionary:
			continue
		var material := material_value as Dictionary
		var output_rate := maxf(0.0, float(material.get("production_per_second", 0.0)))
		var input_rate := maxf(0.0, float(material.get("consumption_per_second", 0.0)))
		if is_zero_approx(output_rate) and is_zero_approx(input_rate) and int(material.get("stored", 0)) <= 0 and int(material.get("buffered", 0)) <= 0:
			continue
		var row := HBoxContainer.new()
		row.name = "ProductionFlow%s" % str(material.get("item_id", "")).to_pascal_case()
		row.add_child(_flow_column_label(_item_name(str(material.get("item_id", ""))), 0.42, UI_OFFWHITE))
		row.add_child(_flow_column_label("%.2f" % output_rate, 0.19, UI_CYAN))
		row.add_child(_flow_column_label("%.2f" % input_rate, 0.19, UI_AMBER))
		row.add_child(_flow_column_label(str(int(material.get("stored", 0))), 0.20, UI_OFFWHITE))
		body.add_child(row)
		flow_rows += 1
	if flow_rows == 0:
		body.add_child(_make_label(I18n.t("factory.operations.no_live_flows", "No active material throughput is reported."), UI_MUTED))
	return panel


func _operations_materials() -> Array:
	var operations: Dictionary = _snapshot.get("operations", {}) as Dictionary if _snapshot.get("operations", {}) is Dictionary else {}
	return operations.get("materials", []) as Array if operations.get("materials", []) is Array else []


func _flow_column_label(value: String, stretch: float, color: Color) -> Label:
	var label := _make_label(value, color)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_stretch_ratio = stretch
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


func _building_thumbnail(definition_id: String, kind: String, tone: Color, minimum_size: Vector2) -> Control:
	var frame := PanelContainer.new()
	frame.name = "FactoryBuildingThumbnail%s" % definition_id.to_pascal_case()
	frame.custom_minimum_size = UiTokens.layout_vector(minimum_size)
	frame.add_theme_stylebox_override("panel", UiTokens.panel_style(UI_NAVY, Color(tone, 0.68), 3))
	var artwork := TextureRect.new()
	artwork.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), definition_id, kind)
	artwork.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	artwork.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	artwork.modulate = Color(0.82, 0.94, 1.0, 0.96)
	frame.add_child(artwork)
	return frame


func _production_recipe_name(entity: Dictionary) -> String:
	var recipe_id := str(entity.get("recipe_id", ""))
	if recipe_id.is_empty():
		return ""
	var recipe := _view_model.recipe_by_id(_snapshot, recipe_id)
	return str(recipe.get("name", recipe_id))


func _production_recipe_manifest(entity: Dictionary, field: String) -> Dictionary:
	var recipe_id := str(entity.get("recipe_id", ""))
	var recipe := _view_model.recipe_by_id(_snapshot, recipe_id) if not recipe_id.is_empty() else {}
	return _quantity_manifest(recipe.get(field, []))


func _production_io_line(entity: Dictionary) -> String:
	if str(entity.get("node_kind", "")) == "EXTRACTOR":
		return I18n.t("factory.operations.output_buffer", "Output buffer · %s") % _item_amount_rows(entity.get("outputs", {}))
	var inputs := _production_recipe_manifest(entity, "inputs")
	var outputs := _production_recipe_manifest(entity, "outputs")
	if inputs.is_empty() and outputs.is_empty():
		return ""
	return I18n.t("factory.operations.recipe_io", "Per cycle · IN %s → OUT %s") % [_item_amount_rows(inputs), _item_amount_rows(outputs)]


func _production_deficit_line(entity: Dictionary) -> String:
	# Construction demand is not a machine input shortage. This diagnosis uses
	# the selected recipe and this machine's own authoritative input buffer.
	if str(entity.get("status", "")) != "INPUT_SHORTAGE":
		return ""
	var inputs := _production_recipe_manifest(entity, "inputs")
	if inputs.is_empty():
		return ""
	var missing: Array[String] = []
	for item_id in inputs.keys():
		var deficit := maxi(0, int(inputs[item_id]) - int(entity.get("inputs", {}).get(item_id, 0)))
		if deficit > 0:
			missing.append("%s %d" % [_item_name(item_id), deficit])
	return I18n.t("factory.operations.deficit_line", "DEFICIT · %s") % ", ".join(missing) if not missing.is_empty() else ""


func _quantity_manifest(value: Variant) -> Dictionary:
	var result: Dictionary = {}
	if value is Dictionary:
		for item_id_value in (value as Dictionary).keys():
			result[str(item_id_value)] = maxi(0, int((value as Dictionary).get(item_id_value, 0)))
	elif value is Array:
		for entry_value in value as Array:
			if not entry_value is Dictionary:
				continue
			var entry := entry_value as Dictionary
			var item_id := str(entry.get("item_id", entry.get("item", "")))
			if not item_id.is_empty():
				result[item_id] = maxi(0, int(entry.get("quantity", entry.get("amount", 0))))
	return result


func _refresh_construction_workspace() -> void:
	if _construction_rows == null:
		return
	_clear_rows(_construction_rows)
	var ghost_count := 0
	for order_value in _snapshot.get("construction_orders", []):
		if not order_value is Dictionary:
			continue
		var order: Dictionary = order_value as Dictionary
		# A construction-order record is player-visible in this workspace only when
		# it is the deployment ghost made by a missing finished-building item. The
		# old onsite-BOM states are not a second construction gameplay path.
		if not _is_waiting_for_finished_building(order):
			continue
		ghost_count += 1
		var order_id := str(order.get("id", ""))
		var panel := PanelContainer.new()
		panel.name = "ConstructionOrder%s" % order_id
		panel.custom_minimum_size.y = UiTokens.layout_px(112)
		panel.add_theme_stylebox_override("panel", UiTokens.control_style(UI_RAISED, Color(UI_AMBER, 0.66), 3))
		_construction_rows.add_child(panel)
		var layout := HBoxContainer.new()
		layout.add_theme_constant_override("separation", UiTokens.layout_px(10))
		panel.add_child(layout)
		layout.add_child(_building_thumbnail(str(order.get("definition_id", "")), "CONSTRUCTION", UI_AMBER, Vector2(86, 92)))
		var body := VBoxContainer.new()
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.add_theme_constant_override("separation", UiTokens.layout_px(4))
		layout.add_child(body)
		var header := HBoxContainer.new()
		body.add_child(header)
		var title := _make_label("%s · %s" % [str(order.get("building_name", order.get("definition_id", order_id))), I18n.t("factory.construction.waiting_building", "Awaiting finished building")], UI_AMBER)
		title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(title)
		var deployment_item := _make_label(I18n.t("factory.field.required", "Required") + " · " + _item_name(_deployment_item_id(order)), UI_AMBER)
		deployment_item.name = "ConstructionWaitingBuilding%s" % order_id
		deployment_item.tooltip_text = I18n.t("factory.construction.waiting_building_hint", "This ghost deploys automatically when %s reaches local available inventory.") % _item_name(_deployment_item_id(order))
		body.add_child(deployment_item)
		var ghost_actions := HBoxContainer.new()
		body.add_child(ghost_actions)
		var ghost_cancel := _make_button(I18n.t("factory.action.cancel_construction", "Cancel"), I18n.t("factory.tooltip.cancel_construction", "Cancel this deployment ghost"))
		ghost_cancel.name = "CancelConstruction%s" % order_id
		ghost_cancel.pressed.connect(_request_cancel_construction.bind(order_id))
		ghost_actions.add_child(ghost_cancel)
	if ghost_count == 0:
		_construction_rows.add_child(_make_label(I18n.t("factory.deployment.empty", "No deployment ghosts are awaiting a finished building."), UI_MUTED))
		_construction_rows.add_child(_empty_state_open_build_button("CONSTRUCTION", "FactoryConstructionEmptyOpenBuild"))


func _focus_entity_from_workspace(entity: Dictionary) -> void:
	if entity.is_empty():
		return
	_set_selection("ENTITY", str(entity.get("id", "")), entity)
	if _canvas != null:
		_canvas_focus_pending = false
		_canvas.focus_tile(_view_model.footprint_origin(entity.get("footprint", {})))
	_set_active_subworkspace("CANVAS")


func _on_operations_action_requested(action: Dictionary) -> void:
	var kind := str(action.get("kind", "")).to_upper()
	match kind:
		"OPEN_TAB":
			_set_active_subworkspace(str(action.get("tab", "OVERVIEW")).to_upper())
		"FOCUS_ENTITY":
			_focus_entity_from_workspace(_entity_by_id(str(action.get("target_id", ""))))
		"FOCUS_ORDER":
			var order := _order_by_id(str(action.get("target_id", action.get("order_id", ""))))
			if not order.is_empty():
				_set_selection("CONSTRUCTION_ORDER", str(order.get("id", "")), order)
				if _canvas != null:
					_canvas_focus_pending = false
					_canvas.focus_tile(_view_model.footprint_origin(order.get("footprint", {})))
				_set_active_subworkspace("CANVAS")
		"SELECT_BUILDING":
			_select_building_id(str(action.get("target_id", "")))


## Empty operational boards still need to lead back into the same physical
## placement path as the Operations overview.  This resolves only from the
## detached snapshot; it does not infer costs or issue a simulation command.
func _empty_state_open_build_button(stage_id: String, node_name: String) -> Button:
	var target_id := _empty_state_building_id(stage_id)
	var button := _make_button(
		I18n.t("factory.operations.open_build", "Open build"),
		I18n.t("factory.operations.open_build_tooltip", "Open this target in the physical Factory construction palette.")
	)
	button.name = node_name
	button.disabled = target_id.is_empty()
	button.add_theme_stylebox_override("normal", UiTokens.control_style(Color("173740"), UI_CYAN, 3))
	button.add_theme_stylebox_override("hover", UiTokens.control_style(Color("20515b"), UI_CYAN, 3))
	button.pressed.connect(_open_empty_state_build.bind(stage_id))
	return button


func _open_empty_state_build(stage_id: String) -> void:
	var target_id := _empty_state_building_id(stage_id)
	if target_id.is_empty():
		return
	# Keep the empty-board CTA on the same SELECT_BUILDING presentation intent
	# used by Operations overview plans. Only a subsequent tile placement emits
	# the deployment command; selection itself never consumes a building item.
	_on_operations_action_requested({"kind":"SELECT_BUILDING", "target_id":target_id})


func _empty_state_building_id(stage_id: String) -> String:
	var palette: Dictionary = _snapshot.get("palette", {}) as Dictionary if _snapshot.get("palette", {}) is Dictionary else {}
	var unlocked_ids := {}
	var building_ids: Array[String] = []
	for building_value in palette.get("buildings", []):
		if not building_value is Dictionary:
			continue
		var building_id := str((building_value as Dictionary).get("id", ""))
		if building_id.is_empty():
			continue
		unlocked_ids[building_id] = true
		building_ids.append(building_id)
	building_ids.sort()
	if unlocked_ids.is_empty():
		return ""
	var operations: Dictionary = _snapshot.get("operations", {}) as Dictionary if _snapshot.get("operations", {}) is Dictionary else {}
	for stage_value in operations.get("stages", []):
		if not stage_value is Dictionary:
			continue
		var stage := stage_value as Dictionary
		if str(stage.get("id", "")).to_upper() != stage_id.to_upper():
			continue
		var action: Dictionary = stage.get("action", {}) as Dictionary if stage.get("action", {}) is Dictionary else {}
		var action_target := str(action.get("target_id", ""))
		if str(action.get("kind", "")).to_upper() == "SELECT_BUILDING" and unlocked_ids.has(action_target):
			return action_target
	for plan_value in operations.get("build_plans", []):
		if not plan_value is Dictionary:
			continue
		var plan := plan_value as Dictionary
		var plan_id := str(plan.get("definition_id", ""))
		if bool(plan.get("affordable", false)) and unlocked_ids.has(plan_id):
			return plan_id
	# A present but currently unaffordable plan is still a legal palette target.
	# It gives the player its real BOM rather than inventing a different action.
	for plan_value in operations.get("build_plans", []):
		if not plan_value is Dictionary:
			continue
		var fallback_plan_id := str((plan_value as Dictionary).get("definition_id", ""))
		if unlocked_ids.has(fallback_plan_id):
			return fallback_plan_id
	if stage_id.to_upper() == "PRODUCTION":
		for building_id in building_ids:
			var building := _view_model.building_by_id(_snapshot, building_id)
			if str(building.get("kind", "")).to_upper() == "MACHINE":
				return building_id
	return building_ids[0]


func _on_building_selected(index: int) -> void:
	_select_building_id(str(_building_options.get_item_metadata(index)))


func _select_building_id(building_id: String, render_now: bool = true) -> void:
	_selected_building_id = building_id
	_active_tool = "BUILD" if not _selected_building_id.is_empty() else ""
	if _active_tool == "BUILD":
		_replace_selection_without_render("", "", {})
		_connection_source_id = ""
		_connection_target_id = ""
		_connection_source_port_id = ""
		_connection_target_port_id = ""
		_selected_cargo_item_id = ""
	if _build_palette != null:
		_build_palette.set_selected_building(_selected_building_id)
	if _active_tool == "BUILD":
		_set_active_subworkspace("CANVAS")
	if render_now:
		_render()


func _set_road_tool(tool_mode: String, tier: int) -> void:
	if not _road_logistics_mode():
		return
	var normalized := tool_mode.to_upper()
	if normalized not in ["BUILD", "REMOVE"]:
		return
	_road_tier = clampi(tier, 1, 2)
	_active_tool = "ROAD_BUILD" if normalized == "BUILD" else "ROAD_REMOVE"
	_selected_building_id = ""
	_replace_selection_without_render("", "", {})
	_clear_connection_state()
	if _build_palette != null:
		_build_palette.set_selected_building("")
	if _canvas != null:
		_canvas.clear_placement_preview()
	_set_active_subworkspace("CANVAS")
	_render()


func _on_build_palette_collapsed_changed(collapsed: bool) -> void:
	if collapsed and _active_tool in ["BUILD", "CONNECT", "ROAD_BUILD", "ROAD_REMOVE"]:
		# The collapsed dock intentionally returns to browsing.  It never leaves a
		# road or placement tool active after hiding that tool's visual state.
		_on_placement_cancelled()


func _on_road_path_requested(command_kind: String, tiles: Array, tier: int) -> void:
	if not _road_logistics_mode() or tiles.is_empty() or tiles.size() > 2048:
		return
	var normalized_kind := command_kind.to_upper()
	if normalized_kind == "BUILD_ROAD":
		_emit_command("BUILD_ROAD", {"tiles":tiles, "tier":clampi(tier, 1, 2)})
	elif normalized_kind == "REMOVE_ROAD":
		_emit_command("REMOVE_ROAD", {"tiles":tiles})


func _on_road_path_rejected(reason_code: String) -> void:
	var key := "factory.reason.%s" % reason_code.to_lower()
	var message := str(I18n.t(key))
	if message == key:
		message = I18n.t("factory.road.path_too_long", "Road path is too long.")
	_set_feedback(reason_code, message, UI_CRITICAL)


func _set_connection_mode(kind: String) -> void:
	if _road_logistics_mode():
		return
	_connection_kind = kind.to_upper()
	_active_tool = "CONNECT"
	_selected_building_id = ""
	_connection_source_id = ""
	_connection_target_id = ""
	_connection_source_port_id = ""
	_connection_target_port_id = ""
	_selected_cargo_item_id = ""
	if _canvas != null:
		_canvas.clear_placement_preview()
	_set_active_subworkspace("CANVAS")
	_render()


func _on_source_selected(index: int) -> void:
	_connection_source_id = str(_source_options.get_item_metadata(index))
	_connection_source_port_id = ""
	_connection_target_port_id = ""
	if _connection_source_id == _connection_target_id:
		_connection_target_id = ""
	_selected_cargo_item_id = ""
	_active_tool = "CONNECT"
	_render()


func _on_target_selected(index: int) -> void:
	_connection_target_id = str(_target_options.get_item_metadata(index))
	_connection_target_port_id = ""
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
		if _preview_tile == tile:
			return
		_preview_tile = tile
		_update_placement_preview()


func _on_tile_selected(tile: Vector2i) -> void:
	if _active_tool == "BUILD":
		_preview_tile = tile
		_request_construction(tile)
		return
	_set_selection("TILE", "%d,%d" % [tile.x, tile.y], {"coordinate":{"x":tile.x, "y":tile.y}})


func _on_placement_cancelled() -> void:
	if _active_tool not in ["BUILD", "CONNECT", "ROAD_BUILD", "ROAD_REMOVE"]:
		return
	_active_tool = ""
	_selected_building_id = ""
	_connection_source_id = ""
	_connection_target_id = ""
	_connection_source_port_id = ""
	_connection_target_port_id = ""
	_selected_cargo_item_id = ""
	if _canvas != null:
		_canvas.clear_placement_preview()
		_canvas.set_road_tool("", _road_tier)
	_render()


func _on_entity_selected(entity: Dictionary) -> void:
	var entity_id := str(entity.get("id", ""))
	if _active_tool == "CONNECT":
		if _connection_source_id.is_empty():
			if _entity_is_connection_candidate(entity, "SOURCE"):
				_connection_source_id = entity_id
			else:
				_set_feedback("INVALID_ENDPOINT", I18n.t("factory.feedback.invalid_connection"), Color("d86e63"))
		elif _connection_target_id.is_empty() and entity_id != _connection_source_id:
			if _entity_is_connection_candidate(entity, "TARGET"):
				_connection_target_id = entity_id
			else:
				_set_feedback("INVALID_ENDPOINT", I18n.t("factory.feedback.invalid_connection"), Color("d86e63"))
		else:
			_connection_source_id = entity_id if _entity_is_connection_candidate(entity, "SOURCE") else ""
			_connection_target_id = ""
		_selected_cargo_item_id = ""
		_connection_source_port_id = ""
		_connection_target_port_id = ""
		_rebuild_connection_selectors(bool(_snapshot.get("valid", false)))
		_update_connection_preview()
	_set_selection("ENTITY", entity_id, entity)


func _on_canvas_machine_configuration_copy_requested(entity: Dictionary) -> void:
	_on_entity_selected(entity)
	_copy_selected_machine_configuration()


func _on_canvas_machine_configuration_paste_requested(entity: Dictionary) -> void:
	_on_entity_selected(entity)
	_paste_machine_configuration()


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
		var reason_code := str(preview.get("reason_code", "INVALID_PLACEMENT"))
		var reason_key := "factory.reason.%s" % reason_code.to_lower()
		var reason_text := str(I18n.t(reason_key))
		if reason_text == reason_key:
			reason_text = I18n.t("factory.feedback.invalid_placement")
		_set_feedback(reason_code, reason_text, Color("d86e63"))
		return
	_emit_command("DEPLOY_BUILDING", {
		"definition_id":_selected_building_id,
		"recipe_id":"",
		"origin":{"x":tile.x, "y":tile.y},
		"priority":50
	})


func _request_connection() -> void:
	if _road_logistics_mode():
		return
	var source := _entity_by_id(_connection_source_id)
	var target := _entity_by_id(_connection_target_id)
	var reason_code := _connection_validation_reason(source, target)
	if not reason_code.is_empty():
		var reason_key := "factory.reason.%s" % reason_code.to_lower()
		var reason_text := str(I18n.t(reason_key))
		if reason_text == reason_key:
			reason_text = I18n.t("factory.feedback.invalid_connection")
		_set_feedback(reason_code, reason_text, Color("d86e63"))
		return
	var payload := {
		"link_kind":_connection_kind,
		"source_id":_connection_source_id,
		"target_id":_connection_target_id,
		"item_id":_selected_cargo_item_id if _connection_kind == "CARGO" else "",
		"capacity_per_second":1.0,
		"priority":1
	}
	if not _connection_source_port_id.is_empty():
		payload["source_port_id"] = _connection_source_port_id
	if not _connection_target_port_id.is_empty():
		payload["target_port_id"] = _connection_target_port_id
	_emit_command("CONNECT_ENTITIES", payload)


func _request_remove_link(link_id: String) -> void:
	if link_id.is_empty():
		return
	_emit_command("REMOVE_LINK", {"link_id":link_id})




func _request_cancel_construction(order_id: String) -> void:
	if order_id.is_empty():
		return
	_emit_command("CANCEL_CONSTRUCTION", {"order_id":order_id})


func _request_remove_entity(entity_id: String) -> void:
	if entity_id.is_empty():
		return
	_emit_command("REMOVE_ENTITY", {"entity_id":entity_id})


func _request_configure_link(link_id: String, priority: int) -> void:
	if link_id.is_empty():
		return
	# Lane count, tier, and throughput describe physical route equipment. Until
	# the Factory economy exposes an authoritative upgrade command and material
	# cost, the workspace must not grant those upgrades for free.
	_emit_command("CONFIGURE_LINK", {"link_id":link_id, "priority":clampi(priority, 0, 2)})


func _selected_machine_entity() -> Dictionary:
	if str(_selection.get("kind", "")) != "ENTITY":
		return {}
	var entity := _entity_by_id(str(_selection.get("id", "")))
	return entity if str(entity.get("node_kind", "")) == "MACHINE" else {}


func _copied_machine_configuration_reason(entity: Dictionary) -> String:
	if _copied_machine_config.is_empty():
		return "MACHINE_CONFIG_EMPTY"
	if entity.is_empty() or str(entity.get("node_kind", "")) != "MACHINE":
		return "MACHINE_CONFIG_REQUIRES_MACHINE"
	if str(_copied_machine_config.get("world_id", "")) != str(_snapshot.get("world_id", "")):
		return "MACHINE_CONFIG_STALE"
	var recipe_id := str(_copied_machine_config.get("recipe_id", ""))
	if recipe_id.is_empty() or _view_model.recipe_by_id(_snapshot, recipe_id).is_empty():
		return "MACHINE_CONFIG_STALE"
	var building := _view_model.building_by_id(_snapshot, str(entity.get("definition_id", "")))
	if building.is_empty() or not (building.get("recipe_ids", []) as Array).has(recipe_id):
		return "MACHINE_CONFIG_INCOMPATIBLE"
	return ""


func _copied_machine_configuration_compatible(entity: Dictionary) -> bool:
	return _copied_machine_configuration_reason(entity).is_empty()


func _copy_selected_machine_configuration() -> void:
	var entity := _selected_machine_entity()
	if entity.is_empty():
		_set_feedback("MACHINE_CONFIG_REQUIRES_MACHINE", I18n.t("factory.feedback.machine_config_requires_machine", "Select a machine before copying its configuration."), Color("d5a45c"))
		return
	var recipe_id := str(entity.get("recipe_id", ""))
	if recipe_id.is_empty() or _view_model.recipe_by_id(_snapshot, recipe_id).is_empty():
		_set_feedback("MACHINE_CONFIG_EMPTY", I18n.t("factory.feedback.machine_config_empty", "This machine has no recipe to copy."), Color("d5a45c"))
		return
	_copied_machine_config = {
		"schema_version":1,
		"world_id":str(_snapshot.get("world_id", "")),
		"recipe_id":recipe_id,
		"recipe_name":str(_view_model.recipe_by_id(_snapshot, recipe_id).get("name", recipe_id))
	}
	_set_feedback("MACHINE_CONFIG_COPIED", I18n.t("factory.feedback.machine_config_copied", "Copied machine recipe: %s") % str(_copied_machine_config.get("recipe_name", recipe_id)), Color("6fbf92"))
	_refresh_inspector()


func _paste_machine_configuration() -> void:
	var entity := _selected_machine_entity()
	var reason_code := _copied_machine_configuration_reason(entity)
	if not reason_code.is_empty():
		var reason_key := "factory.feedback.%s" % reason_code.to_lower()
		var reason_text := str(I18n.t(reason_key))
		if reason_text == reason_key:
			reason_text = I18n.t("factory.reason.incompatible_recipe")
		_set_feedback(reason_code, reason_text, Color("d86e63"))
		return
	_request_set_recipe(str(entity.get("id", "")), str(_copied_machine_config.get("recipe_id", "")))


func _request_set_recipe(entity_id: String, recipe_id: String) -> void:
	if entity_id.is_empty() or recipe_id.is_empty():
		_set_feedback("INCOMPATIBLE_RECIPE", I18n.t("factory.reason.incompatible_recipe"), Color("d86e63"))
		return
	var entity := _entity_by_id(entity_id)
	if entity.is_empty():
		_set_feedback("UNKNOWN_ENTITY", I18n.t("factory.reason.unknown_entity"), Color("d86e63"))
		return
	if str(entity.get("node_kind", "")) not in ["MACHINE", "POWER"]:
		_set_feedback("INVALID_MACHINE", I18n.t("factory.reason.invalid_machine"), Color("d86e63"))
		return
	var building := _view_model.building_by_id(_snapshot, str(entity.get("definition_id", "")))
	if building.is_empty() or not (building.get("recipe_ids", []) as Array).has(recipe_id) or _view_model.recipe_by_id(_snapshot, recipe_id).is_empty():
		_set_feedback("INCOMPATIBLE_RECIPE", I18n.t("factory.reason.incompatible_recipe"), Color("d86e63"))
		return
	if str(_view_model.recipe_by_id(_snapshot, recipe_id).get("runtime_metadata", {}).get("recipe_mode", "")) == "BLACK_HOLE":
		var confirm := ConfirmationDialog.new()
		confirm.name = "BlackHoleDestructionConfirmation"
		confirm.dialog_text = I18n.t("factory.dsp.confirm_destroy", "This will permanently destroy the selected material delivered by road. Continue?")
		add_child(confirm)
		confirm.confirmed.connect(func() -> void:
			_emit_command("SET_RECIPE", {"entity_id":entity_id, "recipe_id":recipe_id, "confirm_destroy":true})
			confirm.queue_free()
		)
		confirm.canceled.connect(confirm.queue_free)
		confirm.popup_centered(Vector2i(520,180))
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
	return _connection_validation_reason(source, target).is_empty()


func _connection_validation_reason(source: Dictionary, target: Dictionary) -> String:
	return _connection_validation_reason_for(
		_connection_source_id,
		_connection_source_port_id,
		_connection_target_id,
		_connection_target_port_id,
		_connection_kind,
		_selected_cargo_item_id,
		source,
		target
	)


func _connection_validation_reason_for(
		source_id: String,
		source_port_id: String,
		target_id: String,
		target_port_id: String,
		kind: String,
		item_id: String,
		source_override: Dictionary = {},
		target_override: Dictionary = {}) -> String:
	var source := source_override if not source_override.is_empty() else _entity_by_id(source_id)
	var target := target_override if not target_override.is_empty() else _entity_by_id(target_id)
	var normalized_kind := kind.to_upper()
	if source.is_empty() or target.is_empty() or source_id == target_id:
		return "INVALID_LINK"
	var source_port := _view_model.connection_port_by_id(source, source_port_id, "OUTPUT") if not source_port_id.is_empty() else {}
	var target_port := _view_model.connection_port_by_id(target, target_port_id, "INPUT") if not target_port_id.is_empty() else {}
	if not source_port_id.is_empty() or not target_port_id.is_empty():
		if source_port.is_empty() or target_port.is_empty() or not _view_model.compatible_port_pair(source, source_port, target, target_port):
			return "CARGO_INCOMPATIBLE"
	var cargo_item_id := item_id if normalized_kind == "CARGO" else ""
	if normalized_kind == "POWER":
		if not _view_model.is_power_connection_valid(source, target) or (not source_port.is_empty() and str(source_port.get("kind", "")) != "POWER"):
			return "INVALID_LINK"
	elif cargo_item_id.is_empty() or (not source_port.is_empty() and not _view_model.compatible_cargo_items_for_ports(source_port, target_port, source, _catalog_item_ids()).has(cargo_item_id)) or (source_port.is_empty() and not _view_model.compatible_cargo_items(source, target, _catalog_item_ids()).has(cargo_item_id)):
		return "CARGO_INCOMPATIBLE"
	var source_kind := str(source.get("node_kind", source.get("kind", ""))).to_upper()
	var target_kind := str(target.get("node_kind", target.get("kind", ""))).to_upper()
	var source_router_mode := str(source.get("router_mode", "BIDIRECTIONAL")).to_upper()
	var target_router_mode := str(target.get("router_mode", "BIDIRECTIONAL")).to_upper()
	var source_allows_fan_out := source_kind == "STORAGE" or (source_kind == "ROUTER" and source_router_mode != "MERGE")
	var target_allows_fan_in := target_kind == "ROUTER" and target_router_mode != "SPLIT"
	if _exact_connection_keys.has(_exact_connection_key(normalized_kind, source_id, target_id, cargo_item_id)):
		return "DUPLICATE_LINK"
	if normalized_kind == "CARGO":
		if not source_allows_fan_out and _cargo_source_item_keys.has(_endpoint_item_key(source_id, cargo_item_id)):
			return "CARGO_OUTPUT_OCCUPIED"
		if not target_allows_fan_in and _cargo_target_item_keys.has(_endpoint_item_key(target_id, cargo_item_id)):
			return "CARGO_INPUT_OCCUPIED"
	return ""


func _exact_connection_key(kind: String, source_id: String, target_id: String, item_id: String) -> String:
	return "\n".join(PackedStringArray([kind.to_upper(), source_id, target_id, item_id]))


func _endpoint_item_key(entity_id: String, item_id: String) -> String:
	return "\n".join(PackedStringArray([entity_id, item_id]))


func _on_port_drag_started(origin_id: String, origin_port: Dictionary, visible_candidates: Array) -> void:
	var candidate_keys: Array[String] = []
	for candidate_value in visible_candidates:
		var candidate := candidate_value as Dictionary
		var entity_id := str(candidate.get("entity_id", ""))
		var candidate_port: Dictionary = candidate.get("port", {}) as Dictionary
		var pair := _normalized_connection_pair(origin_id, origin_port, entity_id, candidate_port)
		if pair.is_empty():
			continue
		var preflight := _port_pair_preflight(
			str(pair.get("source_id", "")),
			pair.get("source_port", {}) as Dictionary,
			str(pair.get("target_id", "")),
			pair.get("target_port", {}) as Dictionary
		)
		if bool(preflight.get("valid", false)):
			candidate_keys.append("%s:%s" % [entity_id, str(candidate_port.get("id", ""))])
	_canvas.set_port_drag_candidates(candidate_keys)


func _on_port_connection_requested(source_id: String, source_port: Dictionary, target_id: String, target_port: Dictionary) -> void:
	var source := _entity_by_id(source_id)
	var target := _entity_by_id(target_id)
	if source.is_empty() or target.is_empty():
		return
	var preflight := _port_pair_preflight(source_id, source_port, target_id, target_port)
	if not bool(preflight.get("valid", false)):
		_set_connection_reason_feedback(str(preflight.get("reason_code", "INVALID_LINK")))
		return
	_connection_source_id = source_id
	_connection_target_id = target_id
	_connection_source_port_id = str(source_port.get("id", ""))
	_connection_target_port_id = str(target_port.get("id", ""))
	_connection_kind = str(source_port.get("kind", "CARGO")).to_upper()
	_active_tool = "CONNECT"
	var submit_immediately := _connection_kind == "POWER"
	if _connection_kind == "CARGO":
		var items: Array = preflight.get("item_ids", []) as Array
		_selected_cargo_item_id = str(items[0]) if items.size() == 1 else ""
		submit_immediately = items.size() == 1
	else:
		_selected_cargo_item_id = ""
	_rebuild_connection_selectors(bool(_snapshot.get("valid", false)))
	_update_connection_preview()
	if submit_immediately:
		_request_connection()
	elif _connection_kind == "CARGO":
		_set_feedback("SELECT_CARGO_ITEM", I18n.t("factory.connection.choose_item", "Choose the item carried by this route, then confirm the connection."), Color("d5a45c"))


func _on_port_drag_preview(source_id: String, source_port: Dictionary, target_id: String, target_port: Dictionary, structural_valid: bool) -> void:
	if source_id.is_empty() or target_id.is_empty():
		return
	if not structural_valid:
		_canvas.set_port_drag_validation(false, "CARGO_INCOMPATIBLE")
		_set_connection_reason_feedback("CARGO_INCOMPATIBLE")
		return
	var preflight := _port_pair_preflight(source_id, source_port, target_id, target_port)
	var valid := bool(preflight.get("valid", false))
	var reason_code := str(preflight.get("reason_code", ""))
	_canvas.set_port_drag_validation(valid, reason_code)
	if not valid:
		_set_connection_reason_feedback(reason_code)
		return
	var item_ids: Array = preflight.get("item_ids", []) as Array
	if item_ids.size() > 1:
		_set_feedback("SELECT_CARGO_ITEM", I18n.t("factory.connection.choose_item", "Choose the item carried by this route, then confirm the connection."), Color("d5a45c"))
	else:
		_set_feedback("PORT_READY", I18n.t("factory.connection.port_ready", "Compatible input port: %s") % target_id, Color("6fbf92"))


func _normalized_connection_pair(first_id: String, first_port: Dictionary, second_id: String, second_port: Dictionary) -> Dictionary:
	var first_direction := str(first_port.get("direction", "")).to_upper()
	var second_direction := str(second_port.get("direction", "")).to_upper()
	if first_direction == "OUTPUT" and second_direction == "INPUT":
		return {"source_id":first_id, "source_port":first_port, "target_id":second_id, "target_port":second_port}
	if first_direction == "INPUT" and second_direction == "OUTPUT":
		return {"source_id":second_id, "source_port":second_port, "target_id":first_id, "target_port":first_port}
	return {}


func _port_pair_preflight(source_id: String, source_port: Dictionary, target_id: String, target_port: Dictionary) -> Dictionary:
	var source := _entity_by_id(source_id)
	var target := _entity_by_id(target_id)
	if source.is_empty() or target.is_empty() or not _view_model.compatible_port_pair(source, source_port, target, target_port):
		return {"valid":false, "reason_code":"CARGO_INCOMPATIBLE", "item_ids":[]}
	var kind := str(source_port.get("kind", "CARGO")).to_upper()
	if kind == "POWER":
		var power_reason := _connection_validation_reason_for(source_id, str(source_port.get("id", "")), target_id, str(target_port.get("id", "")), kind, "", source, target)
		return {"valid":power_reason.is_empty(), "reason_code":power_reason, "item_ids":[]}
	var compatible_items := _view_model.compatible_cargo_items_for_ports(source_port, target_port, source, _catalog_item_ids())
	var valid_items: Array[String] = []
	var first_reason := "CARGO_INCOMPATIBLE"
	for item_value in compatible_items:
		var item_id := str(item_value)
		var reason := _connection_validation_reason_for(source_id, str(source_port.get("id", "")), target_id, str(target_port.get("id", "")), kind, item_id, source, target)
		if reason.is_empty():
			valid_items.append(item_id)
		elif first_reason == "CARGO_INCOMPATIBLE":
			first_reason = reason
	return {"valid":not valid_items.is_empty(), "reason_code":"" if not valid_items.is_empty() else first_reason, "item_ids":valid_items}


func _set_connection_reason_feedback(reason_code: String) -> void:
	var normalized_reason := reason_code if not reason_code.is_empty() else "INVALID_LINK"
	var reason_key := "factory.reason.%s" % normalized_reason.to_lower()
	var reason_text := str(I18n.t(reason_key))
	if reason_text == reason_key:
		reason_text = I18n.t("factory.feedback.invalid_connection")
	_set_feedback(normalized_reason, reason_text, Color("d86e63"))


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
	if _canvas == null:
		return
	if _road_logistics_mode() or _active_tool != "CONNECT":
		_canvas.set_connection_preview("", "", "")
		return
	var source := _entity_by_id(_connection_source_id)
	var target := _entity_by_id(_connection_target_id)
	var candidates: Array[String] = []
	if not source.is_empty():
		for entity_value in _snapshot.get("entities", []):
			var entity := entity_value as Dictionary
			var entity_id := str(entity.get("id", ""))
			if entity_id == _connection_source_id:
				continue
			var compatible := _view_model.is_power_connection_valid(source, entity) if _connection_kind == "POWER" else not _view_model.compatible_cargo_items(source, entity, _catalog_item_ids()).is_empty()
			if compatible:
				candidates.append(entity_id)
	_canvas.set_connection_preview(_connection_source_id, _connection_target_id, _connection_kind, not source.is_empty() and not target.is_empty() and _connection_is_ready(source, target), candidates, _connection_source_port_id, _connection_target_port_id)


func _clear_missing_selection() -> void:
	if not _connection_source_id.is_empty() and _entity_by_id(_connection_source_id).is_empty():
		_connection_source_id = ""
		_selected_cargo_item_id = ""
	if not _connection_target_id.is_empty() and _entity_by_id(_connection_target_id).is_empty():
		_connection_target_id = ""
		_selected_cargo_item_id = ""
	if not _selected_building_id.is_empty() and _view_model.building_by_id(_snapshot, _selected_building_id).is_empty():
		_selected_building_id = ""
		if _active_tool == "BUILD":
			_active_tool = ""
	var selection_kind := str(_selection.get("kind", ""))
	var selection_id := str(_selection.get("id", ""))
	if selection_id.is_empty():
		return
	if selection_kind == "ENTITY":
		var entity := _entity_by_id(selection_id)
		if entity.is_empty():
			_replace_selection_without_render("", "", {})
		else:
			_replace_selection_without_render("ENTITY", selection_id, entity)
	elif selection_kind == "LINK":
		var link := _link_by_id(selection_id)
		if link.is_empty():
			_replace_selection_without_render("", "", {})
		else:
			_replace_selection_without_render("LINK", selection_id, link)
	elif selection_kind == "CONSTRUCTION_ORDER":
		var order := _order_by_id(selection_id)
		if order.is_empty():
			_replace_selection_without_render("", "", {})
		else:
			_replace_selection_without_render("CONSTRUCTION_ORDER", selection_id, order)


func _apply_pending_command_selection() -> void:
	if not _pending_link_selection_id.is_empty():
		var link := _link_by_id(_pending_link_selection_id)
		if not link.is_empty():
			_replace_selection_without_render("LINK", _pending_link_selection_id, link)
			if _canvas != null:
				_canvas.select_link(_pending_link_selection_id)
			_pending_link_selection_id = ""
	if not _pending_entity_selection_id.is_empty():
		var entity := _entity_by_id(_pending_entity_selection_id)
		if not entity.is_empty():
			_replace_selection_without_render("ENTITY", _pending_entity_selection_id, entity)
			_pending_entity_selection_id = ""
	if not _pending_order_selection_id.is_empty():
		var order := _order_by_id(_pending_order_selection_id)
		if not order.is_empty():
			_replace_selection_without_render("CONSTRUCTION_ORDER", _pending_order_selection_id, order)
			_pending_order_selection_id = ""


func _replace_selection_without_render(kind: String, selection_id: String, data: Dictionary) -> void:
	# Snapshot reconciliation is always followed by one full render. Updating the
	# selection here without an eager Inspector rebuild avoids two same-frame
	# control trees and Godot's automatic renaming of the surviving controls.
	_selection = {"kind":kind, "id":selection_id, "data":data.duplicate(true)}
	selection_changed.emit(_selection.duplicate(true))


func _set_selection(kind: String, selection_id: String, data: Dictionary) -> void:
	_selection = {"kind":kind, "id":selection_id, "data":data.duplicate(true)}
	selection_changed.emit(_selection.duplicate(true))
	_refresh_inspector()


func _refresh_inspector() -> void:
	if not is_instance_valid(_inspector_body):
		return
	for child in _inspector_body.get_children():
		_inspector_body.remove_child(child)
		child.queue_free()
	_inspector_body.add_child(_make_section_label(I18n.t("factory.inspector.title")))
	if bool(_snapshot.get("landing_required", false)):
		_render_landing_inspector()
		return
	var selection_kind := str(_selection.get("kind", ""))
	var data: Dictionary = _selection.get("data", {}) if _selection.get("data", {}) is Dictionary else {}
	if selection_kind.is_empty():
		if _active_tool == "BUILD" and not _selected_building_id.is_empty():
			_render_active_building_inspector()
			return
		var empty := _make_inspector_label(I18n.t("factory.inspector.empty"), UI_MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_inspector_body.add_child(empty)
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
		_inspector_body.add_child(_make_inspector_label(I18n.t("factory.inspector.tile") % str(_selection.get("id", "")), Color("d5ddd8")))


func _render_active_building_inspector() -> void:
	var building := _view_model.building_by_id(_snapshot, _selected_building_id)
	if building.is_empty():
		_inspector_body.add_child(_make_inspector_label(I18n.t("factory.build.empty", "Choose a building to inspect its footprint, power and availability."), UI_MUTED))
		return
	var definition_id := str(building.get("id", _selected_building_id))
	var heading := HBoxContainer.new()
	heading.name = "ActiveBuildingInspectorHeader"
	heading.add_theme_constant_override("separation", UiTokens.layout_px(8))
	_inspector_body.add_child(heading)
	var icon := TextureRect.new()
	icon.name = "ActiveBuildingInspectorIcon"
	icon.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), definition_id, str(building.get("kind", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = UiTokens.layout_vector(Vector2(54, 54))
	heading.add_child(icon)
	var text_stack := VBoxContainer.new()
	text_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(text_stack)
	var name_label := _make_inspector_label(_building_name(definition_id, str(building.get("name", definition_id))), UI_OFFWHITE)
	name_label.name = "ActiveBuildingName"
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_stack.add_child(name_label)
	var placement_state := _make_inspector_label(I18n.t("factory.build.placing", "Placement active · click a valid tile") if _active_tool == "BUILD" else I18n.t("factory.build.ready", "Ready to place"), UI_CYAN if _active_tool == "BUILD" else UI_MUTED)
	placement_state.name = "PlacementStatus"
	placement_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_stack.add_child(placement_state)
	var footprint := _view_model.footprint_size(building.get("footprint", {}))
	var generation := float(building.get("power_generation_kw", 0.0))
	var demand := float(building.get("power_demand_kw", 0.0))
	var power_text := "+%.0f kW" % generation if generation > 0.0 else "-%.0f kW" % demand
	_add_detail(I18n.t("factory.field.footprint", "Footprint"), "%d × %d" % [footprint.x, footprint.y])
	_add_detail(I18n.t("factory.field.power", "Power"), power_text)
	var mining_radius := maxf(0.0, float(building.get("mining_radius_tiles", 0.0)))
	if mining_radius > 0.0:
		_add_detail(I18n.t("factory.field.circular_range", "Circular mining range"), I18n.t("factory.field.radius_tiles", "Radius %s tiles") % str(mining_radius))
	var available_count := maxi(0, int(building.get("available_count", 0)))
	var availability := _make_inspector_label(I18n.t("factory.building.available", "Available: %d") % available_count, UI_CYAN if available_count > 0 else UI_AMBER)
	availability.name = "BuildingDeploymentAvailability"
	_inspector_body.add_child(availability)
	var deployment_item_id := _deployment_item_id(building)
	var deployment_hint := _make_inspector_label(
		I18n.t("factory.building.deploy_available_hint", "Deploys one finished building from planet inventory.") if available_count > 0 else I18n.t("factory.building.deploy_missing_hint", "No finished building available. Placement creates a ghost that deploys automatically when one arrives."),
		UI_CYAN if available_count > 0 else UI_AMBER
	)
	deployment_hint.name = "BuildingDeploymentHint"
	deployment_hint.tooltip_text = "%s · %s" % [_item_name(deployment_item_id), deployment_hint.text]
	deployment_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_body.add_child(deployment_hint)
	if _active_tool == "BUILD":
		var cancel := _make_inspector_button(I18n.t("factory.action.cancel_placement", "Cancel placement"), I18n.t("factory.tooltip.cancel_placement", "Leave construction placement mode."))
		cancel.name = "CancelPlacement"
		cancel.pressed.connect(_on_placement_cancelled)
		_inspector_body.add_child(cancel)


func _render_landing_inspector() -> void:
	var portrait := TextureRect.new()
	portrait.name = "PlanetaryCorePortrait"
	portrait.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), "grid_planetary_core", "STORAGE")
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.custom_minimum_size = Vector2(220, 220)
	_inspector_body.add_child(portrait)
	_inspector_body.add_child(_make_section_label(_building_name("grid_planetary_core", "Planetary Development Core")))
	var instruction := _make_inspector_label(I18n.t("factory.landing.instruction", "Choose a clear site and deploy the planetary core."), UI_AMBER)
	instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_body.add_child(instruction)
	_add_detail(I18n.t("factory.field.power", "Power"), "400 kW")
	for definition_id in ["grid_surface_mine", "grid_arc_smelter", "grid_engineering_works"]:
		var row := HBoxContainer.new()
		var icon := TextureRect.new()
		icon.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), definition_id, "MACHINE")
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = Vector2(44, 44)
		row.add_child(icon)
		var label := _make_inspector_label("%s × %d" % [_building_name(definition_id, definition_id), 1 if definition_id == "grid_engineering_works" else 2], UI_OFFWHITE)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		_inspector_body.add_child(row)


func _inspector_interaction_active() -> bool:
	if not is_instance_valid(_inspector_body) or not is_inside_tree():
		return false
	var focused := get_viewport().gui_get_focus_owner()
	# Preserve controls only while the player is editing text. Buttons and closed
	# selectors retain keyboard focus after activation, so treating arbitrary
	# focus as an active interaction would postpone snapshots forever.
	if is_instance_valid(focused) and _inspector_body.is_ancestor_of(focused) and (focused is LineEdit or focused is TextEdit):
		return true
	for option_value in _inspector_body.find_children("*", "OptionButton", true, false):
		var option := option_value as OptionButton
		if option.get_popup().visible:
			return true
	return false


func _add_entity_inspector_header(entity: Dictionary, definition_id: String, entity_id: String) -> void:
	var header := HBoxContainer.new()
	header.name = "EntityInspectorHeader"
	header.add_theme_constant_override("separation", UiTokens.layout_px(8))
	_inspector_body.add_child(header)
	var icon := TextureRect.new()
	icon.name = "EntityInspectorIcon"
	icon.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), definition_id, str(entity.get("node_kind", "")))
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = UiTokens.layout_vector(Vector2(54, 54))
	header.add_child(icon)
	var text_stack := VBoxContainer.new()
	text_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(text_stack)
	var title := _make_inspector_label(_building_name(definition_id, str(entity.get("name", entity_id))), UI_OFFWHITE)
	title.name = "EntityInspectorName"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.tooltip_text = "%s · %s" % [_kind_name(str(entity.get("node_kind", "UNKNOWN"))), entity_id]
	text_stack.add_child(title)
	var status_id := str(entity.get("status", "UNKNOWN"))
	var status := _make_inspector_label(_status_name(status_id), _status_color(status_id))
	status.name = "EntityInspectorStatus"
	text_stack.add_child(status)
	var telemetry := _make_inspector_label("%s  %.2f/s    %s  %d%%" % [
		I18n.t("factory.field.rate", "Rate"),
		float(entity.get("actual_rate", 0.0)),
		I18n.t("factory.field.power", "Power"),
		roundi(float(entity.get("power_factor", 1.0)) * 100.0)
	], UI_MUTED)
	telemetry.name = "EntityInspectorTelemetry"
	telemetry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_stack.add_child(telemetry)


func _add_extractor_mining_context(entity: Dictionary) -> void:
	_inspector_body.add_child(HSeparator.new())
	var section := _make_section_label(I18n.t("factory.inspector.mining_context", "Mining envelope"))
	section.name = "ExtractorMiningContext"
	_inspector_body.add_child(section)
	_add_detail(I18n.t("factory.field.resource", "Resource"), _item_name(str(entity.get("resource_id", ""))))
	var mining_radius := maxf(0.0, float(entity.get("mining_radius_tiles", 0.0)))
	var area_tiles := maxi(1, int(entity.get("mining_area_tiles", entity.get("footprint_tiles", 0))))
	var coverage := float(entity.get("coverage_efficiency", 0.0)) if mining_radius <= 0.0 else clampf(float(entity.get("covered_resource_tiles", 0)) / float(area_tiles), 0.0, 1.0)
	if mining_radius > 0.0:
		_add_detail(I18n.t("factory.field.circular_range", "Circular mining range"), I18n.t("factory.field.radius_tiles", "Radius %s tiles") % str(mining_radius))
	_add_detail(I18n.t("factory.field.coverage", "Resource coverage"), "%d%%" % roundi(coverage * 100.0))
	_add_detail(I18n.t("factory.field.grade", "Grade"), "%.2f" % float(entity.get("average_grade", 0.0)))
	_add_detail(I18n.t("factory.field.sustainable_rate", "Sustainable field rate"), "%.2f/s" % float(entity.get("sustainable_rate_per_second", 0.0)))
	_add_detail(I18n.t("factory.field.covered_tiles", "Covered resource tiles"), "%d / %d" % [int(entity.get("covered_resource_tiles", 0)), area_tiles])
	_add_meter("ExtractorCoverageMeter", I18n.t("factory.field.coverage", "Resource coverage"), coverage)


func _render_entity_inspector(entity: Dictionary) -> void:
	var entity_id := str(entity.get("id", ""))
	var definition_id := str(entity.get("definition_id", ""))
	_add_entity_inspector_header(entity, definition_id, entity_id)
	_add_meter("EntityPowerMeter", I18n.t("factory.field.power"), float(entity.get("power_factor", 1.0)))
	var node_kind := str(entity.get("node_kind", ""))
	if _road_logistics_mode():
		var road_connected := bool(entity.get("road_connected", false))
		var component_id := str(entity.get("road_component_id", ""))
		_add_detail(I18n.t("factory.road.connection", "Road access"), I18n.t("factory.road.connected", "Connected") if road_connected else I18n.t("factory.road.disconnected", "Disconnected — build a road to collect goods automatically."))
		if road_connected and not component_id.is_empty():
			_add_detail(I18n.t("factory.road.component", "Road network"), component_id)
		if float(entity.get("power_factor", 1.0)) < 0.999:
			_add_detail(I18n.t("factory.road.power_notice", "Power"), I18n.t("factory.road.roads_carry_power", "Power travels along roads; a broken road network disconnects this building."))
	if node_kind == "EXTRACTOR":
		_add_extractor_mining_context(entity)
	var current_recipe_id := str(entity.get("recipe_id", ""))
	if not current_recipe_id.is_empty():
		var active_recipe := _view_model.recipe_by_id(_snapshot, current_recipe_id)
		_add_detail(I18n.t("factory.field.recipe"), str(active_recipe.get("name", current_recipe_id)))
		_add_detail(I18n.t("factory.field.cycle", "Cycle"), "%.1fs · %d%%" % [float(active_recipe.get("duration_seconds", 0.0)), roundi(float(entity.get("progress", 0.0)) * 100.0)])
		_add_detail(I18n.t("factory.field.recipe_inputs", "Recipe inputs"), _item_amount_rows(active_recipe.get("inputs", [])))
		_add_detail(I18n.t("factory.field.recipe_outputs", "Recipe outputs"), _item_amount_rows(active_recipe.get("outputs", [])))
	if not str(entity.get("blocker_code", "")).is_empty():
		_add_detail(I18n.t("factory.field.blocker"), _status_name(str(entity.get("blocker_code", ""))))
	_add_item_dictionary(I18n.t("factory.field.inputs"), entity.get("inputs", {}))
	_add_item_dictionary(I18n.t("factory.field.outputs"), entity.get("outputs", {}))
	if not (_road_logistics_mode() and node_kind == "STORAGE"):
		_add_item_dictionary(I18n.t("factory.field.inventory"), entity.get("inventory", {}))
	if node_kind in ["MACHINE", "POWER"]:
		_add_capacity_detail(I18n.t("factory.field.input_buffer", "Input buffer"), entity.get("inputs", {}), int(entity.get("input_capacity", 0)))
		_add_capacity_detail(I18n.t("factory.field.output_buffer", "Output buffer"), entity.get("outputs", {}), int(entity.get("output_capacity", 0)))
	var center_button := _make_inspector_button(I18n.t("factory.action.center"), I18n.t("factory.tooltip.center_entity"))
	center_button.pressed.connect(func() -> void: _canvas.focus_tile(_view_model.footprint_origin(entity.get("footprint", {}))))
	_inspector_body.add_child(center_button)
	if not _view_model.building_by_id(_snapshot, definition_id).get("recipe_ids", []).is_empty():
		_add_entity_recipe_controls(entity)
	var dsp: Dictionary = entity.get("dsp", {})
	if definition_id.begins_with("grid_dsp_"):
		var effects: Dictionary = _snapshot.get("dsp_effects", {})
		if definition_id in ["grid_dsp_matrix_lab", "grid_dsp_em_rail_ejector", "grid_dsp_vertical_launching_silo", "grid_dsp_ray_receiver"]:
			for key in ["research_points", "dyson_sails", "dyson_structure", "ray_available_kw"]:
				_add_detail(I18n.t("factory.dsp.%s" % key, key.replace("_", " ")), "%.0f" % float(effects.get(key,0)))
		elif definition_id == "grid_dsp_galactic_material_exporter":
			_add_detail(I18n.t("factory.dsp.galactic_credits", "Galactic credits"), str(effects.get("galactic_credits",0)))
			for project_id in effects.get("export_projects",{}):
				var project: Dictionary = effects["export_projects"][project_id]
				_add_detail(str(project_id), str(project.get("total_delivered",0)))
		elif definition_id == "grid_dsp_micro_black_hole_connector":
			_add_item_dictionary(I18n.t("factory.dsp.destroyed", "Permanently destroyed"), effects.get("destroyed",{}))
		elif definition_id == "grid_dsp_space_station_construction_launcher":
			_add_detail(I18n.t("factory.dsp.station_stage", "Orbital station material phase"), "%d / 16" % int(effects.get("station_phase_index",0)))
			_add_detail(I18n.t("factory.field.progress", "Progress"), str(effects.get("station_delivered",{})))
		elif definition_id == "grid_dsp_time_warp_device":
			_add_detail(I18n.t("factory.dsp.time_warp", "Realtime simulation"), "×%d" % int(effects.get("time_warp_multiplier",1)))
	if str(dsp.get("power_mode", "")) in ["FUEL_GENERATOR", "BATTERY", "ENERGY_EXCHANGER", "RAY_RECEIVER"]:
		_add_detail(I18n.t("factory.field.power", "Power"), "%.1f kW" % float(entity.get("generation_kw", 0.0)))
		_add_detail("MJ", "%.2f / %.2f" % [float(dsp.get("stored_energy_mj", 0.0)), float(dsp.get("energy_capacity_mj", 0.0))])
		for fuel_id in dsp.get("fuel_item_ids", []):
			_add_detail(_item_name(str(fuel_id)), str(entity.get("inputs", {}).get(fuel_id, 0)))
	if str(entity.get("node_kind", "")) == "STORAGE":
		if _road_logistics_mode():
			_add_shared_road_inventory(entity)
		_add_storage_transfer_controls(entity)
	# Delivery history and shipment queues can be long.  Keep them behind the
	# operational, mining and buffer facts that determine the next player action.
	_add_road_shipment_inspector(entity)
	var remove_entity := _make_inspector_button(I18n.t("factory.action.remove_entity", "Remove entity"), I18n.t("factory.tooltip.remove_entity", "Remove this Factory entity through a versioned command"))
	remove_entity.name = "RemoveFactoryEntity"
	remove_entity.pressed.connect(_request_remove_entity.bind(entity_id))
	_inspector_body.add_child(remove_entity)


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
		recipe_options.add_item(_machine_recipe_option_text(recipe, recipe_id))
		var outputs: Array = recipe.get("outputs", [])
		if not outputs.is_empty():
			recipe_options.set_item_icon(index, ItemArt.texture_for_item(str(outputs[0].get("item", ""))))
			recipe_options.get_popup().set_item_icon_max_width(index, 28)
		recipe_options.set_item_metadata(index, recipe_id)
		if recipe_id == current_recipe_id:
			selected_index = index
		index += 1
	recipe_options.select(selected_index)
	recipe_options.item_selected.connect(func(selected: int) -> void:
		var recipe_id := str(recipe_options.get_item_metadata(selected))
		if recipe_id.is_empty():
			return
		_request_set_recipe(str(entity.get("id", "")), recipe_id)
	)
	_inspector_body.add_child(recipe_options)
	var recipe_status := _make_inspector_label(
		I18n.t("factory.machine.unconfigured", "No recipe configured") if current_recipe_id.is_empty() else I18n.t("factory.machine.recipe_selection_hint", "Select a recipe to apply it immediately."),
		Color("e0ae5c") if current_recipe_id.is_empty() else Color("9aa6a1")
	)
	recipe_status.name = "MachineRecipeStatus"
	_inspector_body.add_child(recipe_status)
	var copy_button := _make_inspector_button(I18n.t("factory.action.copy_machine_configuration", "Copy machine configuration"), I18n.t("factory.tooltip.copy_machine_configuration", "Copy this machine's recipe without copying inventory, progress, or connections."))
	copy_button.name = "CopyMachineConfiguration"
	copy_button.disabled = current_recipe_id.is_empty() or _view_model.recipe_by_id(_snapshot, current_recipe_id).is_empty()
	copy_button.pressed.connect(_copy_selected_machine_configuration)
	_inspector_body.add_child(copy_button)
	var paste_button := _make_inspector_button(I18n.t("factory.action.paste_machine_configuration", "Paste machine configuration"), I18n.t("factory.tooltip.paste_machine_configuration", "Apply the copied recipe if it is compatible with this machine."))
	paste_button.name = "PasteMachineConfiguration"
	paste_button.disabled = not _copied_machine_configuration_compatible(entity)
	paste_button.pressed.connect(_paste_machine_configuration)
	_inspector_body.add_child(paste_button)


func _machine_recipe_option_text(recipe: Dictionary, fallback_recipe_id: String) -> String:
	var building_definition_id := str(recipe.get("building_definition_id", ""))
	if not building_definition_id.is_empty():
		var building_name := _building_name(building_definition_id, building_definition_id.replace("_", " ").capitalize())
		return I18n.t("factory.machine.recipe_building", "Manufactures building: %s") % building_name
	return str(recipe.get("name", fallback_recipe_id))


func _render_resource_inspector(field: Dictionary) -> void:
	var resource_id := str(field.get("resource_id", ""))
	var resource_title := _make_inspector_label(str(field.get("resource_name", _item_name(resource_id))) if not resource_id.is_empty() else I18n.t("factory.resource_field"), UI_OFFWHITE)
	resource_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	resource_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inspector_body.add_child(resource_title)
	_add_detail(I18n.t("factory.field.field_id"), str(field.get("id", "")))
	_add_detail(I18n.t("factory.field.category"), _category_name(str(field.get("resource_category", ""))))
	_add_detail(I18n.t("factory.field.grade"), "%.2f" % float(field.get("grade", 0.0)))
	_add_detail(I18n.t("factory.field.density"), "%.2f" % float(field.get("potential_density", 0.0)))
	_add_detail(I18n.t("factory.field.mapped_potential", "Mapped potential"), "%.2f/s" % float(field.get("mapped_potential_per_second", 0.0)))
	for building_value in _snapshot.get("palette", {}).get("buildings", []):
		var building := building_value as Dictionary
		if str(building.get("kind", "")) != "EXTRACTOR" or not (building.get("resource_categories", []) as Array).has(str(field.get("resource_category", ""))):
			continue
		var allowed: Array = building.get("allowed_resource_ids", [])
		if not allowed.is_empty() and not allowed.has(resource_id):
			continue
		var extractor_id := str(building.get("id", ""))
		var build_button := _make_inspector_button(I18n.t("factory.action.build_extractor", "Place %s") % _building_name(extractor_id, str(building.get("name", extractor_id))), I18n.t("factory.tooltip.build_extractor", "Enter placement mode at this resource field."))
		build_button.name = "BuildExtractor"
		build_button.pressed.connect(_select_building_for_field.bind(extractor_id, field.duplicate(true)))
		_inspector_body.add_child(build_button)
	var center_button := _make_inspector_button(I18n.t("factory.action.center"), I18n.t("factory.tooltip.center_resource"))
	center_button.pressed.connect(func() -> void: _canvas.focus_tile(_view_model.footprint_origin(field.get("footprint", {}))))
	_inspector_body.add_child(center_button)


func _select_building_for_field(building_id: String, field: Dictionary) -> void:
	_select_building_id(building_id, false)
	_preview_tile = _view_model.footprint_origin(field.get("footprint", {}))
	_canvas.focus_tile(_preview_tile)
	_render()


func _render_link_inspector(link: Dictionary) -> void:
	var link_id := str(link.get("id", ""))
	_inspector_body.add_child(_make_inspector_label(I18n.t("factory.inspector.link") % _connection_name(str(link.get("kind", "CARGO"))), Color("d5ddd8")))
	_add_detail(I18n.t("factory.field.id"), link_id)
	_add_detail(I18n.t("factory.field.route"), "%s -> %s" % [str(link.get("source_id", "")), str(link.get("target_id", ""))])
	var item_id := str(link.get("item_id", ""))
	_add_detail(I18n.t("factory.field.item"), _item_name(item_id) if not item_id.is_empty() else "-")
	_add_detail(I18n.t("factory.field.status"), _status_name(str(link.get("status", "IDLE"))))
	_add_detail(I18n.t("factory.field.flow"), "%.2f / %.2f" % [float(link.get("last_flow", 0.0)), float(link.get("capacity_per_second", 0.0))])
	_add_detail(I18n.t("factory.field.congestion", "Congestion"), "%d%%" % roundi(clampf(float(link.get("congestion", link.get("utilization", 0.0))), 0.0, 1.0) * 100.0))
	if not str(link.get("blocked_reason", "")).is_empty():
		_add_detail(I18n.t("factory.field.blocked", "Blocked"), _status_name(str(link.get("blocked_reason", ""))))
	for endpoint in [
		{"id":str(link.get("source_id", "")), "action":"factory.action.center_source", "tooltip":"factory.tooltip.center_source"},
		{"id":str(link.get("target_id", "")), "action":"factory.action.center_target", "tooltip":"factory.tooltip.center_target"}
	]:
		var entity := _entity_by_id(str(endpoint.get("id", "")))
		if entity.is_empty():
			continue
		var focus_button := _make_inspector_button(I18n.t(str(endpoint.get("action", ""))), I18n.t(str(endpoint.get("tooltip", ""))))
		focus_button.pressed.connect(func() -> void: _canvas.focus_tile(_view_model.footprint_origin(entity.get("footprint", {}))))
		_inspector_body.add_child(focus_button)
	var remove_button := _make_inspector_button(I18n.t("factory.action.remove_link"), I18n.t("factory.tooltip.remove_link"))
	remove_button.pressed.connect(func() -> void: _request_remove_link(link_id))
	_inspector_body.add_child(remove_button)
	_add_link_configuration_controls(link)


func _add_link_configuration_controls(link: Dictionary) -> void:
	if str(link.get("kind", "")).to_upper() != "CARGO":
		return
	_inspector_body.add_child(HSeparator.new())
	_inspector_body.add_child(_make_section_label(I18n.t("factory.route.controls", "Route controls")))
	var priority := SpinBox.new()
	priority.name = "LinkPriority"
	priority.min_value = 0.0
	priority.max_value = 2.0
	priority.step = 1.0
	priority.value = clampi(int(link.get("priority", 1)), 0, 2)
	_inspector_body.add_child(priority)
	var apply := _make_inspector_button(I18n.t("factory.action.configure_link", "Apply route controls"), I18n.t("factory.tooltip.configure_link", "Configure route priority"))
	apply.name = "ConfigureFactoryLink"
	apply.pressed.connect(func() -> void:
		_request_configure_link(str(link.get("id", "")), int(priority.value))
	)
	_inspector_body.add_child(apply)


func _render_order_inspector(order: Dictionary) -> void:
	var order_id := str(order.get("id", ""))
	_inspector_body.add_child(_make_inspector_label(I18n.t("factory.inspector.order"), UI_OFFWHITE))
	var definition_id := str(order.get("definition_id", ""))
	_add_detail(I18n.t("factory.field.building"), _building_name(definition_id, definition_id))
	if not _is_waiting_for_finished_building(order):
		# Compatibility records must not revive the retired onsite-material
		# construction flow in a player-facing inspector.
		var inactive := _make_inspector_label(I18n.t("factory.deployment.inactive_record", "This record is not an active deployment ghost."), UI_MUTED)
		inactive.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_inspector_body.add_child(inactive)
		return
	_render_waiting_building_order(order, order_id)


func _render_waiting_building_order(order: Dictionary, order_id: String) -> void:
	var deployment_item_id := _deployment_item_id(order)
	var waiting := _make_inspector_label(I18n.t("factory.construction.waiting_building", "Awaiting finished building"), UI_AMBER)
	waiting.name = "ConstructionWaitingBuilding"
	_inspector_body.add_child(waiting)
	var item_name := _item_name(deployment_item_id)
	var item := _make_inspector_label(I18n.t("factory.field.required", "Required") + " · " + item_name, Color("d5ddd8"))
	item.name = "ConstructionDeploymentItem"
	item.tooltip_text = deployment_item_id
	_inspector_body.add_child(item)
	var hint := _make_inspector_label(I18n.t("factory.construction.waiting_building_hint", "This ghost deploys automatically when %s reaches local available inventory.") % item_name, UI_MUTED)
	hint.name = "ConstructionWaitingBuildingHint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_body.add_child(hint)
	var cancel_button := _make_inspector_button(I18n.t("factory.action.cancel_construction", "Cancel construction"), I18n.t("factory.tooltip.cancel_construction", "Cancel this construction order"))
	cancel_button.name = "CancelConstructionOrder"
	cancel_button.pressed.connect(_request_cancel_construction.bind(order_id))
	_inspector_body.add_child(cancel_button)


func _is_waiting_for_finished_building(order: Dictionary) -> bool:
	return str(order.get("status", "")).to_upper() == "WAITING_BUILDING"


func _add_storage_transfer_controls(storage: Dictionary) -> void:
	if _road_logistics_mode():
		return
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
	var export_button := _make_inspector_button(I18n.t("factory.action.export"), I18n.t("factory.tooltip.export"))
	export_button.disabled = item_index <= 1
	export_button.pressed.connect(func() -> void: _request_storage_transfer("EXPORT_TO_LOCATION", storage_id, str(item_options.get_item_metadata(item_options.selected)), int(quantity.value)))
	_inspector_body.add_child(export_button)
	var import_button := _make_inspector_button(I18n.t("factory.action.import"), I18n.t("factory.tooltip.import"))
	import_button.disabled = location_inventory.is_empty()
	import_button.pressed.connect(func() -> void: _request_storage_transfer("IMPORT_FROM_LOCATION", storage_id, str(item_options.get_item_metadata(item_options.selected)), int(quantity.value)))
	_inspector_body.add_child(import_button)
	var transfer_help := _make_inspector_label(I18n.t("factory.help.transfer"), Color("9aa6a1"))
	transfer_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_body.add_child(transfer_help)


func _add_shared_road_inventory(storage: Dictionary) -> void:
	var shared: Variant = storage.get("shared_inventory", _snapshot.get("shared_inventory", {}))
	if not shared is Dictionary:
		return
	var inventory: Dictionary = shared as Dictionary
	if inventory.has("items") and inventory.get("items") is Dictionary:
		inventory = inventory.get("items", {}) as Dictionary
	if inventory.is_empty():
		return
	_inspector_body.add_child(HSeparator.new())
	var section := _make_section_label(I18n.t("factory.road.shared_inventory", "Planet shared inventory"))
	section.name = "RoadSharedInventory"
	_inspector_body.add_child(section)
	_add_item_dictionary(I18n.t("factory.field.inventory"), inventory)
	var hint := _make_inspector_label(I18n.t("factory.road.shared_inventory_hint", "Road-connected storage is read-only here; local machines collect automatically."), UI_MUTED)
	hint.name = "RoadSharedInventoryHint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector_body.add_child(hint)


func _add_road_shipment_inspector(entity: Dictionary) -> void:
	if not _road_logistics_mode():
		return
	var node_kind := str(entity.get("node_kind", "")).to_upper()
	if node_kind not in ["STORAGE", "MACHINE", "EXTRACTOR"]:
		return
	var inspector := ShipmentInspectorScript.new()
	inspector.configure(_snapshot, entity)
	_inspector_body.add_child(inspector)


func _location_inventory() -> Dictionary:
	var source: Variant = _snapshot.get("location_available_inventory", _snapshot.get("location_inventory", {}))
	if source is Dictionary:
		var source_dict := source as Dictionary
		if source_dict.get("items", {}) is Dictionary:
			return (source_dict.get("items", {}) as Dictionary).duplicate(true)
		return source_dict.duplicate(true)
	return {}


func _add_detail(label_text: String, value: String) -> void:
	_add_detail_to(_inspector_body, label_text, value)


func _add_detail_to(container: Control, label_text: String, value: String) -> void:
	var label := _make_inspector_label(I18n.core("diagnostics.economy.demand_entry") % [label_text, value], Color("a5b2ac"))
	container.add_child(label)


func _add_meter(node_name: String, label_text: String, ratio: float) -> void:
	var meter := ProgressBar.new()
	meter.name = node_name
	meter.min_value = 0.0
	meter.max_value = 100.0
	meter.value = clampf(ratio, 0.0, 1.0) * 100.0
	meter.show_percentage = false
	meter.custom_minimum_size = Vector2(0, 8)
	meter.tooltip_text = I18n.t("factory.format.meter_tooltip") % [label_text, roundi(meter.value)]
	_inspector_body.add_child(meter)


func _add_capacity_detail(label_text: String, values: Variant, capacity: int) -> void:
	var used := 0
	if values is Dictionary:
		for quantity_value in (values as Dictionary).values():
			used += maxi(0, int(quantity_value))
	_add_detail(label_text, I18n.t("factory.format.capacity") % [used, maxi(0, capacity)])


func _item_amount_rows(value: Variant) -> String:
	var rows: Array[String] = []
	if value is Array:
		for entry_value in value as Array:
			if not entry_value is Dictionary:
				continue
			var entry := entry_value as Dictionary
			var item_id := str(entry.get("item", entry.get("item_id", "")))
			if not item_id.is_empty():
				rows.append(I18n.core("format.item_quantity") % [_item_name(item_id), maxi(0, int(entry.get("quantity", entry.get("amount", 0))))])
	elif value is Dictionary:
		for item_id_value in (value as Dictionary).keys():
			rows.append(I18n.core("format.item_quantity") % [_item_name(str(item_id_value)), maxi(0, int((value as Dictionary).get(item_id_value, 0)))])
	rows.sort()
	return ", ".join(rows) if not rows.is_empty() else I18n.t("factory.value.none", "None")


func _add_item_dictionary(label_text: String, value: Variant) -> void:
	if not value is Dictionary or (value as Dictionary).is_empty():
		return
	var rows: Array = []
	for item_id_value in (value as Dictionary).keys():
		rows.append(I18n.core("format.item_quantity") % [_item_name(str(item_id_value)), int((value as Dictionary).get(item_id_value, 0))])
	rows.sort()
	_add_detail(label_text, ", ".join(rows))


func _entity_by_id(entity_id: String) -> Dictionary:
	return _entities_by_id.get(entity_id, {})


func _link_by_id(link_id: String) -> Dictionary:
	return _links_by_id.get(link_id, {})


func _order_by_id(order_id: String) -> Dictionary:
	return _orders_by_id.get(order_id, {})


func _rebuild_snapshot_lookups() -> void:
	_entities_by_id.clear()
	_links_by_id.clear()
	_orders_by_id.clear()
	_exact_connection_keys.clear()
	_cargo_source_item_keys.clear()
	_cargo_target_item_keys.clear()
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		_entities_by_id[str(entity.get("id", ""))] = entity
	for link_value in _snapshot.get("links", []):
		var link := link_value as Dictionary
		_links_by_id[str(link.get("id", ""))] = link
		var kind := str(link.get("kind", "")).to_upper()
		var source_id := str(link.get("source_id", ""))
		var target_id := str(link.get("target_id", ""))
		var item_id := str(link.get("item_id", "")) if kind == "CARGO" else ""
		_exact_connection_keys[_exact_connection_key(kind, source_id, target_id, item_id)] = true
		if kind == "CARGO":
			_cargo_source_item_keys[_endpoint_item_key(source_id, item_id)] = true
			_cargo_target_item_keys[_endpoint_item_key(target_id, item_id)] = true
	for order_value in _snapshot.get("construction_orders", []):
		var order := order_value as Dictionary
		_orders_by_id[str(order.get("id", ""))] = order


func _catalog_item_ids() -> Array:
	var names: Dictionary = _snapshot.get("item_names", {}) if _snapshot.get("item_names", {}) is Dictionary else {}
	return names.keys()


func _set_feedback(code: String, message: String, color: Color) -> void:
	if _feedback_label == null:
		return
	_feedback_label.text = "[" + code + "] " + message
	_feedback_label.tooltip_text = _feedback_label.text
	_feedback_label.visible = not message.is_empty()
	_feedback_label.add_theme_color_override("font_color", color)


func _revision_tooltip() -> String:
	return "T%d · R%d" % [int(_snapshot.get("topology_revision", 0)), int(_snapshot.get("runtime_revision", 0))]


func _make_section_label(text_value: String) -> Label:
	var label := _make_label(text_value, UI_OFFWHITE)
	label.add_theme_font_size_override("font_size", UiTokens.font_size(15))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _make_label(text_value: String, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_color_override("font_color", color)
	return label


func _make_inspector_label(text_value: String, color: Color) -> Label:
	var label := _make_label(text_value, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.clip_text = false
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _make_button(text_value: String, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text_value
	button.tooltip_text = tooltip
	button.add_theme_font_size_override("font_size", UiTokens.font_size(12))
	button.add_theme_color_override("font_color", UI_OFFWHITE)
	button.add_theme_color_override("font_hover_color", UI_OFFWHITE)
	button.add_theme_color_override("font_pressed_color", UI_CYAN)
	button.add_theme_stylebox_override("normal", UiTokens.control_style(UI_RAISED, UI_BORDER, 3))
	button.add_theme_stylebox_override("hover", UiTokens.control_style(Color("242b28"), Color("75807a"), 3))
	button.add_theme_stylebox_override("pressed", UiTokens.control_style(Color("293a34"), UI_CYAN, 3))
	button.add_theme_stylebox_override("focus", UiTokens.control_style(UI_RAISED, UI_CYAN, 3))
	button.add_theme_stylebox_override("disabled", UiTokens.control_style(Color("171a19"), UI_BORDER, 3))
	return button


func _make_inspector_button(text_value: String, tooltip: String) -> Button:
	var button := _make_button(text_value, tooltip)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.clip_text = false
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return button


func _status_name(status_id: String) -> String:
	match status_id.to_upper():
		"MISSING_MATERIALS", "MATERIAL_SHORTAGE": return I18n.t("factory.operations.status.material_shortage", "Material shortage")
	return I18n.status(status_id)


func _status_color(status_id: String) -> Color:
	match status_id.to_upper():
		"RUNNING", "FLOWING", "CONNECTED", "READY", "COMPLETED": return UI_OPERATIONAL
		"NO_POWER", "INPUT_SHORTAGE", "WAITING_MATERIALS", "WAITING_BUILDING", "SOURCE_EMPTY", "QUEUED": return UI_AMBER
		"OUTPUT_FULL", "TARGET_FULL", "BLOCKED", "NO_RESOURCE": return UI_CRITICAL
	return UI_MUTED


func _item_name(item_id: String) -> String:
	if item_id.is_empty():
		return ""
	var names: Dictionary = _snapshot.get("item_names", {}) if _snapshot.get("item_names", {}) is Dictionary else {}
	return str(names.get(item_id, item_id.replace("_", " ").capitalize()))


func _deployment_item_id(record: Dictionary) -> String:
	var item_id := str(record.get("deployment_item_id", ""))
	if not item_id.is_empty():
		return item_id
	var required: Dictionary = record.get("required_items", {}) if record.get("required_items", {}) is Dictionary else {}
	var required_ids: Array[String] = []
	for required_item_id_value in required.keys():
		var required_item_id := str(required_item_id_value)
		if required_item_id.begins_with("building_"):
			return required_item_id
		required_ids.append(required_item_id)
	required_ids.sort()
	if required_ids.size() == 1:
		return required_ids[0]
	var definition_id := str(record.get("definition_id", record.get("id", "")))
	return "building_" + definition_id if not definition_id.is_empty() else ""


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
