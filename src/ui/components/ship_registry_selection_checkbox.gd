class_name ShipRegistrySelectionCheckbox
extends CheckBox

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var display_indeterminate := false:
	set(value):
		display_indeterminate = value
		queue_redraw()


func _ready() -> void:
	text = ""
	add_theme_font_size_override("font_size", 1)
	for style_name in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	toggled.connect(func(_pressed: bool):
		display_indeterminate = false
		queue_redraw()
	)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	resized.connect(queue_redraw)
	queue_redraw()


func set_indeterminate_state(value: bool) -> void:
	display_indeterminate = value


func _draw() -> void:
	var side := minf(minf(size.x, size.y), UiTokens.full_scale_px(18.0 / 1.5))
	var origin := (size - Vector2(side, side)) * 0.5
	var box := Rect2(origin, Vector2(side, side))
	var active := button_pressed or display_indeterminate
	var background := UiTokens.COLOR_REGISTRY_CONTROL_ACTIVE if active else UiTokens.COLOR_REGISTRY_INSET
	var border := UiTokens.COLOR_FOCUS if active or has_focus() else (UiTokens.COLOR_REGISTRY_BORDER.lightened(0.12) if is_hovered() else UiTokens.COLOR_REGISTRY_BORDER)
	if disabled:
		background = UiTokens.COLOR_REGISTRY_INSET.darkened(0.12)
		border = UiTokens.COLOR_REGISTRY_SEPARATOR.darkened(0.16)
	draw_style_box(_checkbox_style(background, border), box)
	if disabled:
		return
	var mark_color := UiTokens.COLOR_TEXT if active else UiTokens.COLOR_TEXT_MUTED
	if display_indeterminate:
		var inset := side * 0.25
		draw_line(Vector2(box.position.x + inset, box.get_center().y), Vector2(box.end.x - inset, box.get_center().y), mark_color, maxf(1.0, side * 0.13), true)
	elif button_pressed:
		var points := PackedVector2Array([
			Vector2(box.position.x + side * 0.22, box.position.y + side * 0.52),
			Vector2(box.position.x + side * 0.43, box.position.y + side * 0.72),
			Vector2(box.position.x + side * 0.79, box.position.y + side * 0.29)
		])
		draw_polyline(points, mark_color, maxf(1.0, side * 0.12), true)


func _checkbox_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(UiTokens.full_scale_px(2.0 / 1.5))
	return style
