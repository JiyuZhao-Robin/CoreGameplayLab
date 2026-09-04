class_name ShipDismantleModal
extends Control

signal confirmed
signal canceled

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const GOLDEN_SCALE := 1.5

var dialog_text := ""
var _warning_text := ""
var _recovery_text := ""
var _error_label: Label
var _cancel_button: Button
var _confirm_button: Button
var _closing := false
var _bulk_mode := false


func configure(title_text: String, warning_text: String, recovery_text: String, cancel_text: String, confirm_text: String) -> void:
	_bulk_mode = false
	_warning_text = warning_text
	_recovery_text = recovery_text
	dialog_text = "%s\n\n%s" % [_warning_text, _recovery_text]
	name = "FleetRosterDismantleConfirmation"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	z_index = 1000
	_build_interface(title_text, cancel_text, confirm_text)
	set_process_input(true)
	call_deferred("_focus_cancel")


func configure_bulk(title_text: String, warning_text: String, summary_text: String, recovery_text: String, cancel_text: String, confirm_text: String) -> void:
	_bulk_mode = true
	_warning_text = "%s\n\n%s" % [warning_text, summary_text]
	_recovery_text = recovery_text
	dialog_text = "%s\n\n%s" % [_warning_text, _recovery_text]
	name = "FleetRosterBulkDismantleConfirmation"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	z_index = 1000
	_build_interface(title_text, cancel_text, confirm_text)
	set_process_input(true)
	call_deferred("_focus_cancel")


func get_ok_button() -> Button:
	return _confirm_button


func get_cancel_button() -> Button:
	return _cancel_button


func show_error(message: String) -> void:
	dialog_text = "%s\n\n%s\n\n%s" % [_warning_text, _recovery_text, message]
	_error_label.text = message
	_error_label.visible = true
	_confirm_button.disabled = false
	_focus_cancel()


func set_confirm_enabled(enabled: bool) -> void:
	if is_instance_valid(_confirm_button):
		_confirm_button.disabled = not enabled


func _build_interface(title_text: String, cancel_text: String, confirm_text: String) -> void:
	var scrim := ColorRect.new()
	scrim.name = "FleetRosterDismantleScrim"
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.color = Color(0.0, 0.025, 0.022, 0.78)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	var center := CenterContainer.new()
	center.name = "FleetRosterDismantleCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(center)

	var panel := PanelContainer.new()
	panel.name = "FleetRosterDismantlePanel"
	panel.custom_minimum_size = Vector2(_px(730.0 if _bulk_mode else 690.0), _px(370.0 if _bulk_mode else 300.0))
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style := UiTokens.panel_style(UiTokens.COLOR_REGISTRY_SURFACE, UiTokens.COLOR_REGISTRY_BORDER.lightened(0.12), _px(4.0))
	panel_style.shadow_color = Color(0.0, 0.0, 0.0, 0.58)
	panel_style.shadow_size = _px(12.0)
	panel_style.shadow_offset = Vector2(0.0, _px(5.0))
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)

	var padding := MarginContainer.new()
	padding.add_theme_constant_override("margin_left", _px(24.0))
	padding.add_theme_constant_override("margin_top", _px(24.0))
	padding.add_theme_constant_override("margin_right", _px(24.0))
	padding.add_theme_constant_override("margin_bottom", _px(24.0))
	panel.add_child(padding)

	var content := VBoxContainer.new()
	content.name = "FleetRosterDismantleContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", _px(18.0))
	padding.add_child(content)

	var title := _label(title_text, 21, UiTokens.COLOR_TEXT)
	title.name = "FleetRosterDismantleTitle"
	title.custom_minimum_size.y = _px(30.0)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	content.add_child(title)

	var warning := _label(_warning_text, 16, UiTokens.COLOR_TEXT_SECONDARY)
	warning.name = "FleetRosterDismantleWarning"
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(warning)

	var recovery_panel := PanelContainer.new()
	recovery_panel.name = "FleetRosterDismantleRecoveryPanel"
	recovery_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var recovery_style := UiTokens.panel_style(UiTokens.COLOR_REGISTRY_INSET, UiTokens.COLOR_REGISTRY_BORDER, _px(3.0))
	recovery_panel.add_theme_stylebox_override("panel", recovery_style)
	content.add_child(recovery_panel)

	var recovery_padding := MarginContainer.new()
	recovery_padding.add_theme_constant_override("margin_left", _px(14.0))
	recovery_padding.add_theme_constant_override("margin_top", _px(12.0))
	recovery_padding.add_theme_constant_override("margin_right", _px(14.0))
	recovery_padding.add_theme_constant_override("margin_bottom", _px(12.0))
	recovery_panel.add_child(recovery_padding)
	var recovery := _label(_recovery_text, 15, UiTokens.COLOR_TEXT)
	recovery.name = "FleetRosterDismantleRecovery"
	recovery.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	recovery.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recovery_padding.add_child(recovery)

	_error_label = _label("", 14, UiTokens.COLOR_CRITICAL.lightened(0.12))
	_error_label.name = "FleetRosterDismantleError"
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.visible = false
	content.add_child(_error_label)

	var flexible_space := Control.new()
	flexible_space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flexible_space.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(flexible_space)

	var footer := HBoxContainer.new()
	footer.name = "FleetRosterDismantleActions"
	footer.custom_minimum_size.y = _px(44.0)
	footer.add_theme_constant_override("separation", _px(12.0))
	content.add_child(footer)
	var action_spacer := Control.new()
	action_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	action_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(action_spacer)

	_cancel_button = _action_button(cancel_text, false)
	_cancel_button.name = "FleetRosterCancelDismantle"
	_cancel_button.pressed.connect(_request_cancel)
	footer.add_child(_cancel_button)

	_confirm_button = _action_button(confirm_text, true)
	_confirm_button.name = "FleetRosterConfirmDismantle"
	_confirm_button.pressed.connect(_request_confirm)
	footer.add_child(_confirm_button)


func _action_button(text_value: String, destructive: bool) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(_px(150.0), _px(44.0))
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", _font_size(15))
	if destructive:
		button.add_theme_color_override("font_color", UiTokens.COLOR_CRITICAL.lightened(0.12))
		button.add_theme_color_override("font_hover_color", UiTokens.COLOR_CRITICAL.lightened(0.22))
		button.add_theme_color_override("font_pressed_color", UiTokens.COLOR_TEXT)
		button.add_theme_stylebox_override("normal", _button_style(UiTokens.COLOR_CRITICAL.darkened(0.78), UiTokens.COLOR_CRITICAL.darkened(0.35)))
		button.add_theme_stylebox_override("hover", _button_style(UiTokens.COLOR_CRITICAL.darkened(0.68), UiTokens.COLOR_CRITICAL))
		button.add_theme_stylebox_override("pressed", _button_style(UiTokens.COLOR_CRITICAL.darkened(0.48), UiTokens.COLOR_CRITICAL.lightened(0.12)))
		button.add_theme_stylebox_override("focus", _button_style(UiTokens.COLOR_CRITICAL.darkened(0.68), UiTokens.COLOR_CRITICAL.lightened(0.12)))
		button.add_theme_stylebox_override("disabled", _button_style(UiTokens.COLOR_REGISTRY_INSET, UiTokens.COLOR_REGISTRY_SEPARATOR))
	else:
		button.add_theme_stylebox_override("normal", _button_style(UiTokens.COLOR_REGISTRY_CONTROL, UiTokens.COLOR_REGISTRY_BORDER))
		button.add_theme_stylebox_override("hover", _button_style(UiTokens.COLOR_REGISTRY_CONTROL_HOVER, UiTokens.COLOR_FOCUS))
		button.add_theme_stylebox_override("pressed", _button_style(UiTokens.COLOR_REGISTRY_CONTROL_ACTIVE, UiTokens.COLOR_FOCUS))
		button.add_theme_stylebox_override("focus", _button_style(UiTokens.COLOR_REGISTRY_CONTROL_ACTIVE, UiTokens.COLOR_FOCUS))
	return button


func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := UiTokens.panel_style(background, border, _px(3.0))
	style.content_margin_left = _px(12.0)
	style.content_margin_right = _px(12.0)
	style.content_margin_top = _px(4.0)
	style.content_margin_bottom = _px(4.0)
	return style


func _label(text_value: String, golden_font_size: int, color: Color) -> Label:
	var result := Label.new()
	result.text = text_value
	result.add_theme_font_size_override("font_size", _font_size(golden_font_size))
	result.add_theme_color_override("font_color", color)
	return result


func _font_size(golden_size: int) -> int:
	return UiTokens.full_scale_px(float(golden_size) / GOLDEN_SCALE)


func _px(golden_pixels: float) -> int:
	return UiTokens.full_scale_px(golden_pixels / GOLDEN_SCALE)


func _focus_cancel() -> void:
	if is_instance_valid(_cancel_button):
		_cancel_button.grab_focus()


func _request_cancel() -> void:
	if _closing:
		return
	_closing = true
	canceled.emit()


func _request_confirm() -> void:
	if _closing or not is_instance_valid(_confirm_button) or _confirm_button.disabled:
		return
	confirmed.emit()


func _input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_request_cancel()
	elif key_event.keycode == KEY_TAB:
		get_viewport().set_input_as_handled()
		if get_viewport().gui_get_focus_owner() == _confirm_button:
			_cancel_button.grab_focus()
		else:
			_confirm_button.grab_focus()
