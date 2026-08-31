class_name GameShell
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

signal left_rail_toggled(collapsed: bool)
signal right_inspector_toggled(collapsed: bool)

var header_slot: MarginContainer
var left_slot: MarginContainer
var center_slot: VBoxContainer
var right_slot: MarginContainer
var bottom_slot: MarginContainer

var _left_panel: PanelContainer
var _right_panel: PanelContainer
var _left_content: Control
var _right_content: Control
var _left_toggle: Button
var _right_toggle: Button
var _left_collapsed := false
var _right_collapsed := false


func build() -> void:
	if is_instance_valid(center_slot):
		return
	name = "GameShell"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_background()
	var rows := VBoxContainer.new()
	rows.name = "ShellRows"
	rows.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rows.add_theme_constant_override("separation", 0)
	add_child(rows)

	var header_panel := _surface(UiTokens.COLOR_PANEL)
	header_panel.name = "TopStatusBar"
	header_panel.custom_minimum_size.y = UiTokens.TOP_BAR_HEIGHT
	rows.add_child(header_panel)
	header_slot = _margin(UiTokens.SPACING_LG, UiTokens.SPACING_SM, UiTokens.SPACING_MD, UiTokens.SPACING_SM)
	header_panel.add_child(header_slot)

	var workspace := HBoxContainer.new()
	workspace.name = "WorkspaceGrid"
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 0)
	rows.add_child(workspace)

	_left_panel = _surface(UiTokens.COLOR_PANEL)
	_left_panel.name = "ResourceRailSurface"
	_left_panel.custom_minimum_size.x = UiTokens.RESOURCE_RAIL_WIDTH
	workspace.add_child(_left_panel)
	var left_column := VBoxContainer.new()
	left_column.add_theme_constant_override("separation", 0)
	_left_panel.add_child(left_column)
	_left_toggle = _edge_toggle("CollapseResourceRail", "‹")
	_left_toggle.alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_left_toggle.size_flags_horizontal = Control.SIZE_SHRINK_END
	_left_toggle.pressed.connect(func(): set_left_collapsed(not _left_collapsed, true))
	left_column.add_child(_left_toggle)
	left_slot = _margin(UiTokens.SPACING_MD, UiTokens.SPACING_XS, UiTokens.SPACING_MD, UiTokens.SPACING_MD)
	left_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_column.add_child(left_slot)
	_left_content = left_slot

	center_slot = VBoxContainer.new()
	center_slot.name = "CentralWorkspace"
	center_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center_slot.add_theme_constant_override("separation", 0)
	workspace.add_child(center_slot)

	_right_panel = _surface(UiTokens.COLOR_PANEL)
	_right_panel.name = "ContextInspectorSurface"
	_right_panel.custom_minimum_size.x = UiTokens.INSPECTOR_WIDTH
	workspace.add_child(_right_panel)
	var right_column := VBoxContainer.new()
	right_column.add_theme_constant_override("separation", 0)
	_right_panel.add_child(right_column)
	_right_toggle = _edge_toggle("CollapseContextInspector", "›")
	_right_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_right_toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_right_toggle.pressed.connect(func(): set_right_collapsed(not _right_collapsed, true))
	right_column.add_child(_right_toggle)
	right_slot = _margin(UiTokens.SPACING_MD, UiTokens.SPACING_XS, UiTokens.SPACING_MD, UiTokens.SPACING_MD)
	right_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_column.add_child(right_slot)
	_right_content = right_slot

	var bottom_panel := _surface(UiTokens.COLOR_PANEL)
	bottom_panel.name = "CommandDockSurface"
	bottom_panel.custom_minimum_size.y = UiTokens.BOTTOM_BAR_HEIGHT
	rows.add_child(bottom_panel)
	bottom_slot = _margin(UiTokens.SPACING_MD, UiTokens.SPACING_SM, UiTokens.SPACING_MD, UiTokens.SPACING_SM)
	bottom_panel.add_child(bottom_slot)
	_refresh_toggle_copy()


func set_left_collapsed(collapsed: bool, emit_change := false) -> void:
	_left_collapsed = collapsed
	if not is_instance_valid(_left_panel):
		return
	_left_content.visible = not collapsed
	_left_panel.custom_minimum_size.x = UiTokens.COLLAPSED_RAIL_WIDTH if collapsed else UiTokens.RESOURCE_RAIL_WIDTH
	_left_toggle.text = "›" if collapsed else "‹"
	_refresh_toggle_copy()
	if emit_change:
		left_rail_toggled.emit(collapsed)


func set_right_collapsed(collapsed: bool, emit_change := false) -> void:
	_right_collapsed = collapsed
	if not is_instance_valid(_right_panel):
		return
	_right_content.visible = not collapsed
	_right_panel.custom_minimum_size.x = UiTokens.COLLAPSED_RAIL_WIDTH if collapsed else UiTokens.INSPECTOR_WIDTH
	_right_toggle.text = "‹" if collapsed else "›"
	_refresh_toggle_copy()
	if emit_change:
		right_inspector_toggled.emit(collapsed)


func refresh_locale() -> void:
	_refresh_toggle_copy()


func _refresh_toggle_copy() -> void:
	if is_instance_valid(_left_toggle):
		_left_toggle.tooltip_text = I18n.core("shell.expand_resource_rail", "Expand resource rail") if _left_collapsed else I18n.core("shell.collapse_resource_rail", "Collapse resource rail")
		_left_toggle.accessibility_name = _left_toggle.tooltip_text
	if is_instance_valid(_right_toggle):
		_right_toggle.tooltip_text = I18n.core("shell.expand_inspector", "Expand context inspector") if _right_collapsed else I18n.core("shell.collapse_inspector", "Collapse context inspector")
		_right_toggle.accessibility_name = _right_toggle.tooltip_text


func _build_background() -> void:
	var background := ColorRect.new()
	background.name = "ShellBackground"
	background.color = UiTokens.COLOR_CANVAS
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)


func _surface(color: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(color, UiTokens.COLOR_BORDER, 0))
	return panel


func _edge_toggle(node_name: String, caption: String) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size = Vector2(UiTokens.COLLAPSED_RAIL_WIDTH, UiTokens.COLLAPSE_BUTTON_HEIGHT)
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_SECONDARY)
	return button


func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var value := MarginContainer.new()
	value.add_theme_constant_override("margin_left", left)
	value.add_theme_constant_override("margin_top", top)
	value.add_theme_constant_override("margin_right", right)
	value.add_theme_constant_override("margin_bottom", bottom)
	return value
