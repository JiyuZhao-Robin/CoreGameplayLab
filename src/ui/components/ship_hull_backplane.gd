class_name ShipHullBackplane
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var tone := UiTokens.COLOR_INFORMATION


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(color: Color) -> void:
	tone = color
	queue_redraw()


func _draw() -> void:
	if size.x < 24.0 or size.y < 24.0:
		return
	var outer := Rect2(Vector2(2.0, 2.0), size - Vector2(4.0, 4.0))
	var outer_points := _cut_corners(outer, 11.0)
	draw_colored_polygon(outer_points, Color("0b1210"))
	_draw_polygon_outline(outer_points, Color(tone, 0.34), 1.0)

	var inner := outer.grow(-5.0)
	var inner_points := _cut_corners(inner, 8.0)
	draw_colored_polygon(inner_points, Color("101815"))
	_draw_polygon_outline(inner_points, Color(UiTokens.COLOR_SHIP_FRAME_INNER, 0.92), 1.0)

	var top_band := Rect2(inner.position + Vector2(1.0, 1.0), Vector2(inner.size.x - 2.0, 24.0))
	draw_rect(top_band, Color(UiTokens.COLOR_NODE_HEADER, 0.84))
	draw_line(Vector2(inner.position.x, top_band.end.y), Vector2(inner.end.x, top_band.end.y), Color(tone, 0.20), 1.0, true)

	var grid_color := Color(UiTokens.COLOR_SHIP_FRAME_INNER, 0.42)
	var x := inner.position.x + 28.0
	while x < inner.end.x:
		draw_line(Vector2(x, top_band.end.y), Vector2(x, inner.end.y), grid_color, 1.0)
		x += 28.0
	var y := top_band.end.y + 28.0
	while y < inner.end.y:
		draw_line(Vector2(inner.position.x, y), Vector2(inner.end.x, y), grid_color, 1.0)
		y += 28.0

	var center := inner.get_center() + Vector2(0.0, 8.0)
	draw_line(Vector2(inner.position.x + 16.0, center.y), Vector2(inner.end.x - 16.0, center.y), Color(tone, 0.12), 1.0, true)
	draw_line(Vector2(center.x, top_band.end.y + 10.0), Vector2(center.x, inner.end.y - 12.0), Color(tone, 0.12), 1.0, true)
	draw_arc(center, minf(34.0, inner.size.y * 0.23), 0.0, TAU, 48, Color(tone, 0.16), 1.0, true)
	draw_arc(center, minf(25.0, inner.size.y * 0.18), -2.65, 0.65, 28, Color(tone, 0.30), 2.0, true)

	for point in [
		inner.position + Vector2(12.0, 12.0),
		Vector2(inner.end.x - 12.0, inner.position.y + 12.0),
		Vector2(inner.position.x + 12.0, inner.end.y - 12.0),
		inner.end - Vector2(12.0, 12.0)
	]:
		draw_circle(point, 2.0, Color(UiTokens.COLOR_BORDER_STRONG, 0.72))
		draw_arc(point, 4.5, 0.0, TAU, 16, Color(tone, 0.18), 1.0, true)

	_draw_brackets(inner.grow(-2.0), Color(tone, 0.42), 14.0)


func _cut_corners(rect: Rect2, cut: float) -> PackedVector2Array:
	return PackedVector2Array([
		rect.position + Vector2(cut, 0.0),
		Vector2(rect.end.x - cut, rect.position.y),
		Vector2(rect.end.x, rect.position.y + cut),
		Vector2(rect.end.x, rect.end.y - cut),
		Vector2(rect.end.x - cut, rect.end.y),
		Vector2(rect.position.x + cut, rect.end.y),
		Vector2(rect.position.x, rect.end.y - cut),
		Vector2(rect.position.x, rect.position.y + cut)
	])


func _draw_polygon_outline(points: PackedVector2Array, color: Color, width: float) -> void:
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, color, width, true)


func _draw_brackets(rect: Rect2, color: Color, length: float) -> void:
	var top_left := rect.position
	var top_right := Vector2(rect.end.x, rect.position.y)
	var bottom_left := Vector2(rect.position.x, rect.end.y)
	var bottom_right := rect.end
	draw_line(top_left, top_left + Vector2(length, 0.0), color, 1.0, true)
	draw_line(top_left, top_left + Vector2(0.0, length), color, 1.0, true)
	draw_line(top_right, top_right - Vector2(length, 0.0), color, 1.0, true)
	draw_line(top_right, top_right + Vector2(0.0, length), color, 1.0, true)
	draw_line(bottom_left, bottom_left + Vector2(length, 0.0), color, 1.0, true)
	draw_line(bottom_left, bottom_left - Vector2(0.0, length), color, 1.0, true)
	draw_line(bottom_right, bottom_right - Vector2(length, 0.0), color, 1.0, true)
	draw_line(bottom_right, bottom_right - Vector2(0.0, length), color, 1.0, true)
