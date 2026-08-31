class_name IndustrialNetworkGlyph
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var glyph_kind := "PRODUCTION"
var tone := UiTokens.COLOR_MATERIAL
var filled := true
var line_width := 1.5


func configure(kind: String, color: Color, is_filled := true) -> void:
	glyph_kind = kind
	tone = color
	filled = is_filled
	custom_minimum_size = Vector2(20, 20)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.31
	match glyph_kind:
		"MATERIAL": _draw_square(center, radius)
		"SERVICE": _draw_circle(center, radius)
		"DEMAND": _draw_triangle(center, radius)
		"INFORMATION": _draw_diamond(center, radius)
		"SOURCE": _draw_source(center, radius)
		"BUFFER": _draw_buffer(center, radius)
		"LOGISTICS": _draw_logistics(center, radius)
		"INFRASTRUCTURE": _draw_infrastructure(center, radius)
		_: _draw_production(center, radius)


func _draw_square(center: Vector2, radius: float) -> void:
	var rect := Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
	if filled:
		draw_rect(rect, tone, true)
	else:
		draw_rect(rect, tone, false, line_width)


func _draw_circle(center: Vector2, radius: float) -> void:
	if filled:
		draw_circle(center, radius, tone)
	else:
		draw_arc(center, radius, 0.0, TAU, 24, tone, line_width, true)


func _draw_triangle(center: Vector2, radius: float) -> void:
	var points := PackedVector2Array([
		center + Vector2(0, -radius),
		center + Vector2(radius * 0.92, radius),
		center + Vector2(-radius * 0.92, radius)
	])
	if filled:
		draw_colored_polygon(points, tone)
	else:
		var outline := PackedVector2Array([points[0], points[1], points[2], points[0]])
		draw_polyline(outline, tone, line_width, true)


func _draw_diamond(center: Vector2, radius: float) -> void:
	var points := PackedVector2Array([
		center + Vector2(0, -radius), center + Vector2(radius, 0),
		center + Vector2(0, radius), center + Vector2(-radius, 0)
	])
	if filled:
		draw_colored_polygon(points, tone)
	else:
		var outline := PackedVector2Array([points[0], points[1], points[2], points[3], points[0]])
		draw_polyline(outline, tone, line_width, true)


func _draw_source(center: Vector2, radius: float) -> void:
	draw_line(center + Vector2(-radius, radius), center + Vector2(radius, radius), tone, line_width, true)
	draw_line(center + Vector2(-radius * 0.72, radius * 0.2), center, tone, line_width, true)
	draw_line(center, center, tone, line_width, true)
	draw_line(center, center - Vector2(0, radius), tone, line_width, true)
	draw_circle(center - Vector2(0, radius), 2.0, tone)


func _draw_buffer(center: Vector2, radius: float) -> void:
	for offset in [-0.55, 0.0, 0.55]:
		var y := center.y + radius * float(offset)
		draw_line(Vector2(center.x - radius, y), Vector2(center.x + radius, y), tone, line_width, true)
	draw_rect(Rect2(center - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0)), tone, false, line_width)


func _draw_logistics(center: Vector2, radius: float) -> void:
	draw_line(center - Vector2(radius, 0), center + Vector2(radius * 0.65, 0), tone, line_width, true)
	draw_colored_polygon(PackedVector2Array([center + Vector2(radius, 0), center + Vector2(radius * 0.35, -radius * 0.48), center + Vector2(radius * 0.35, radius * 0.48)]), tone)
	draw_circle(center - Vector2(radius * 0.7, 0), 2.4, tone)


func _draw_infrastructure(center: Vector2, radius: float) -> void:
	draw_arc(center, radius, 0.0, TAU, 24, tone, line_width, true)
	draw_line(center - Vector2(radius, 0), center + Vector2(radius, 0), tone, line_width, true)
	draw_line(center - Vector2(0, radius), center + Vector2(0, radius), tone, line_width, true)


func _draw_production(center: Vector2, radius: float) -> void:
	draw_arc(center, radius * 0.72, 0.0, TAU, 20, tone, line_width, true)
	draw_circle(center, radius * 0.25, tone if filled else Color.TRANSPARENT)
	for index in 4:
		var angle := float(index) * PI * 0.5
		var direction := Vector2(cos(angle), sin(angle))
		draw_line(center + direction * radius * 0.65, center + direction * radius, tone, line_width, true)
