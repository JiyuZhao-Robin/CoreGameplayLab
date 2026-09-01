class_name ShipAssemblyPaletteItem
extends Button

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var drag_payload: Dictionary = {}
var _caption := ""
var _art_path := ""


func configure(payload: Dictionary, caption: String, available: bool, hint: String, art_path: String = "") -> void:
	drag_payload = payload.duplicate(true)
	_caption = caption
	_art_path = art_path
	disabled = not available
	tooltip_text = hint
	mouse_default_cursor_shape = Control.CURSOR_DRAG if available else Control.CURSOR_FORBIDDEN
	_clear_visual_children()
	if _art_path.is_empty() or not ResourceLoader.exists(_art_path):
		text = caption
		custom_minimum_size = Vector2(208.0, 48.0)
		text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		return
	text = ""
	custom_minimum_size = Vector2(286.0, 104.0)
	clip_contents = true
	_apply_art_card_style()
	var content := _art_card_content(false)
	add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 9.0
	content.offset_top = 7.0
	content.offset_right = -9.0
	content.offset_bottom = -7.0


func _get_drag_data(_at_position: Vector2) -> Variant:
	if disabled or drag_payload.is_empty():
		return null
	var preview := PanelContainer.new()
	preview.add_theme_stylebox_override("panel", UiTokens.panel_style(UiTokens.COLOR_CONTROL_ACTIVE, UiTokens.COLOR_FOCUS, 4))
	if not _art_path.is_empty() and ResourceLoader.exists(_art_path):
		preview.custom_minimum_size = Vector2(250.0, 90.0)
		preview.add_child(_art_card_content(true))
	else:
		var label := Label.new()
		label.text = _caption
		label.custom_minimum_size = Vector2(190.0, 38.0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		preview.add_child(label)
	set_drag_preview(preview)
	return drag_payload.duplicate(true)


func _clear_visual_children() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


func _apply_art_card_style() -> void:
	var normal := UiTokens.control_style(Color("0b1514"), UiTokens.COLOR_BORDER_STRONG, 5)
	normal.shadow_color = Color(0.0, 0.0, 0.0, 0.34)
	normal.shadow_size = 8
	var hover := UiTokens.control_style(Color("102321"), UiTokens.COLOR_FOCUS.darkened(0.16), 5)
	hover.set_border_width_all(2)
	hover.shadow_color = Color(UiTokens.COLOR_FOCUS, 0.18)
	hover.shadow_size = 10
	var pressed := UiTokens.control_style(Color("132c29"), UiTokens.COLOR_FOCUS, 5)
	pressed.set_border_width_all(2)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover)
	add_theme_stylebox_override("pressed", pressed)
	add_theme_stylebox_override("focus", hover)


func _art_card_content(compact: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 10)
	var thumbnail_frame := PanelContainer.new()
	thumbnail_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumbnail_frame.custom_minimum_size = Vector2(70.0, 76.0) if compact else Vector2(78.0, 88.0)
	thumbnail_frame.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("07100f"), Color(UiTokens.COLOR_FOCUS, 0.30), 3))
	var thumbnail := TextureRect.new()
	thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	thumbnail.texture = load(_art_path) as Texture2D
	thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumbnail_frame.add_child(thumbnail)
	row.add_child(thumbnail_frame)
	var copy := VBoxContainer.new()
	copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.alignment = BoxContainer.ALIGNMENT_CENTER
	copy.add_theme_constant_override("separation", 3)
	var lines := _caption.split("\n", false)
	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text = lines[0] if not lines.is_empty() else _caption
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_color_override("font_color", UiTokens.COLOR_TEXT)
	title.add_theme_font_size_override("font_size", UiTokens.font_size(13))
	copy.add_child(title)
	var detail := Label.new()
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var detail_lines := PackedStringArray()
	for index in range(1, lines.size()):
		detail_lines.append(lines[index])
	detail.text = "\n".join(detail_lines)
	detail.custom_minimum_size.y = 38.0 if compact else 48.0
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	detail.add_theme_font_size_override("font_size", UiTokens.font_size(9 if compact else 10))
	copy.add_child(detail)
	row.add_child(copy)
	return row
