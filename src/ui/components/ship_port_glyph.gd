class_name ShipPortGlyph
extends Control

var shape := "SQUARE"
var tone := Color.WHITE
var filled := true


func _ready() -> void:
	custom_minimum_size = Vector2(18.0, 18.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(value: String, color: Color, is_filled := true) -> void:
	shape = value
	tone = color
	filled = is_filled
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.34
	match shape:
		"CIRCLE":
			if filled:
				draw_circle(center, radius, tone)
			else:
				draw_arc(center, radius, 0.0, TAU, 32, tone, 2.0, true)
		"TRIANGLE":
			_draw_polygon(PackedVector2Array([center + Vector2(0.0, -radius), center + Vector2(radius, radius), center + Vector2(-radius, radius)]))
		"DIAMOND":
			_draw_polygon(PackedVector2Array([center + Vector2(0.0, -radius), center + Vector2(radius, 0.0), center + Vector2(0.0, radius), center + Vector2(-radius, 0.0)]))
		"PENTAGON":
			var points := PackedVector2Array()
			for index in 5:
				var angle := -PI * 0.5 + TAU * float(index) / 5.0
				points.append(center + Vector2(cos(angle), sin(angle)) * radius)
			_draw_polygon(points)
		"HEXAGON":
			var points := PackedVector2Array()
			for index in 6:
				var angle := -PI * 0.5 + TAU * float(index) / 6.0
				points.append(center + Vector2(cos(angle), sin(angle)) * radius)
			_draw_polygon(points)
		_:
			if filled:
				draw_rect(Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), tone, true)
			else:
				draw_rect(Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), tone, false, 2.0)


func _draw_polygon(points: PackedVector2Array) -> void:
	if filled:
		draw_colored_polygon(points, tone)
	else:
		var outline := points.duplicate()
		outline.append(points[0])
		draw_polyline(outline, tone, 2.0, true)
