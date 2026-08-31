class_name ShipAssemblyPaletteItem
extends Button

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var drag_payload: Dictionary = {}


func configure(payload: Dictionary, caption: String, available: bool, hint: String) -> void:
	drag_payload = payload.duplicate(true)
	text = caption
	disabled = not available
	tooltip_text = hint
	custom_minimum_size = Vector2(208.0, 48.0)
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	mouse_default_cursor_shape = Control.CURSOR_DRAG if available else Control.CURSOR_FORBIDDEN


func _get_drag_data(_at_position: Vector2) -> Variant:
	if disabled or drag_payload.is_empty():
		return null
	var preview := PanelContainer.new()
	preview.add_theme_stylebox_override("panel", UiTokens.panel_style(UiTokens.COLOR_CONTROL_ACTIVE, UiTokens.COLOR_FOCUS, 4))
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(190.0, 38.0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview.add_child(label)
	set_drag_preview(preview)
	return drag_payload.duplicate(true)
