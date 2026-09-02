class_name ShipAssemblyTrashDropTarget
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const TARGET_SIZE := Vector2(340.0, 124.0)
const TARGET_BOTTOM_MARGIN := 22.0
const HIDDEN_MARGIN := 18.0

var reveal_progress := 0.0:
	set(value):
		reveal_progress = clampf(value, 0.0, 1.0)
		visible = reveal_progress > 0.001
		queue_redraw()
var drop_hovered := false:
	set(value):
		if drop_hovered == value:
			return
		drop_hovered = value
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	z_index = 50
	visible = false


func drop_rect() -> Rect2:
	var target_size := UiTokens.layout_vector(TARGET_SIZE)
	return Rect2(
		Vector2((size.x - target_size.x) * 0.5, size.y - target_size.y - UiTokens.layout_px(TARGET_BOTTOM_MARGIN)),
		target_size
	)


func contains_screen_position(screen_position: Vector2) -> bool:
	return reveal_progress > 0.001 and drop_rect().has_point(screen_position)


func _animated_rect() -> Rect2:
	var shown := drop_rect()
	var hidden_y := size.y + UiTokens.layout_px(HIDDEN_MARGIN)
	var eased := smoothstep(0.0, 1.0, reveal_progress)
	shown.position.y = lerpf(hidden_y, shown.position.y, eased)
	return shown


func _draw() -> void:
	if reveal_progress <= 0.001:
		return
	var rectangle := _animated_rect()
	var tone := UiTokens.COLOR_CRITICAL if drop_hovered else UiTokens.COLOR_TEXT_MUTED
	var surface := UiTokens.COLOR_NODE_SURFACE.lerp(tone, 0.13 if drop_hovered else 0.035)
	var outline := Color(tone, 0.96 if drop_hovered else 0.58)
	var corners := _chamfered_rect(rectangle, UiTokens.layout_px(14.0))
	var shadow := corners.duplicate()
	for index in range(shadow.size()):
		shadow[index] += Vector2(0.0, UiTokens.layout_px(7.0))
	draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.40))
	draw_colored_polygon(corners, Color(surface, 0.98))
	_draw_polygon_outline(corners, outline, 2.0 if drop_hovered else 1.0)

	var icon_center := Vector2(rectangle.position.x + UiTokens.layout_px(54.0), rectangle.get_center().y - UiTokens.layout_px(5.0))
	var icon_scale := UiTokens.layout_scale()
	var body := PackedVector2Array([
		icon_center + Vector2(-17.0, -9.0) * icon_scale,
		icon_center + Vector2(17.0, -9.0) * icon_scale,
		icon_center + Vector2(13.0, 22.0) * icon_scale,
		icon_center + Vector2(-13.0, 22.0) * icon_scale
	])
	draw_colored_polygon(body, Color(tone, 0.28 if drop_hovered else 0.16))
	_draw_polygon_outline(body, outline, 2.0)
	draw_line(icon_center + Vector2(-21.0, -15.0) * icon_scale, icon_center + Vector2(21.0, -15.0) * icon_scale, outline, 3.0, true)
	draw_line(icon_center + Vector2(-8.0, -20.0) * icon_scale, icon_center + Vector2(8.0, -20.0) * icon_scale, outline, 3.0, true)
	for x_offset in [-7.0, 0.0, 7.0]:
		draw_line(icon_center + Vector2(x_offset, -3.0) * icon_scale, icon_center + Vector2(x_offset, 15.0) * icon_scale, Color(tone, 0.74), 1.5, true)

	var title := I18n.core("ships.shipyard.trash_drop_release", "Release to remove") if drop_hovered else I18n.core("ships.shipyard.trash_drop", "Drag here to remove")
	var hint := I18n.core("ships.shipyard.trash_backspace", "Backspace removes selected part")
	var text_left := rectangle.position.x + UiTokens.layout_px(94.0)
	var text_width := rectangle.end.x - text_left - UiTokens.layout_px(16.0)
	var font := get_theme_default_font()
	draw_string(font, Vector2(text_left, rectangle.position.y + UiTokens.layout_px(51.0)), title, HORIZONTAL_ALIGNMENT_LEFT, text_width, UiTokens.font_size(16), Color(tone.lightened(0.14) if drop_hovered else UiTokens.COLOR_TEXT))
	draw_string(font, Vector2(text_left, rectangle.position.y + UiTokens.layout_px(79.0)), hint, HORIZONTAL_ALIGNMENT_LEFT, text_width, UiTokens.font_size(11), UiTokens.COLOR_TEXT_MUTED)


func _chamfered_rect(rectangle: Rect2, cut: float) -> PackedVector2Array:
	return PackedVector2Array([
		rectangle.position + Vector2(cut, 0.0),
		Vector2(rectangle.end.x - cut, rectangle.position.y),
		Vector2(rectangle.end.x, rectangle.position.y + cut),
		Vector2(rectangle.end.x, rectangle.end.y - cut),
		Vector2(rectangle.end.x - cut, rectangle.end.y),
		Vector2(rectangle.position.x + cut, rectangle.end.y),
		Vector2(rectangle.position.x, rectangle.end.y - cut),
		Vector2(rectangle.position.x, rectangle.position.y + cut)
	])


func _draw_polygon_outline(points: PackedVector2Array, color: Color, width: float) -> void:
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, color, width, true)
