class_name ShipPortGlyph
extends Control

var shape := "SQUARE"
var tone := Color.WHITE
var filled := true
var visual_state := "idle"
var _phase := 0.0


func _ready() -> void:
	custom_minimum_size = Vector2(18.0, 18.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func configure(value: String, color: Color, is_filled := true, state := "idle") -> void:
	shape = value
	tone = color
	filled = is_filled
	visual_state = state
	set_process(visual_state in ["compatible", "origin"])
	queue_redraw()


func _process(delta: float) -> void:
	_phase = fposmod(_phase + delta, 4.0)
	queue_redraw()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.27
	var state_alpha := 0.30 if visual_state in ["muted", "incompatible"] else 1.0
	var display_tone := tone
	if visual_state == "incompatible":
		display_tone = Color("8d5148")
	display_tone.a *= state_alpha

	var pulse := 0.5 + sin(_phase * TAU * 0.85) * 0.5
	var halo_alpha := 0.0
	if visual_state == "compatible":
		halo_alpha = 0.12 + pulse * 0.16
	elif visual_state == "origin":
		halo_alpha = 0.18 + pulse * 0.18
	elif visual_state == "connected":
		halo_alpha = 0.14
	elif visual_state == "hover":
		halo_alpha = 0.12
	if halo_alpha > 0.0:
		draw_circle(center, radius + 8.0, Color(display_tone, halo_alpha))
	draw_circle(center, radius + 5.0, Color("0b1210"))
	draw_arc(center, radius + 5.0, 0.0, TAU, 32, Color(display_tone, 0.30 * state_alpha), 1.0, true)
	draw_arc(center, radius + 2.0, -2.55, 0.55, 20, Color(display_tone.lightened(0.20), 0.68 * state_alpha), 1.5, true)

	match shape:
		"CIRCLE":
			if filled:
				draw_circle(center, radius, display_tone)
			else:
				draw_arc(center, radius, 0.0, TAU, 32, display_tone, 2.0, true)
		"TRIANGLE":
			_draw_polygon(PackedVector2Array([center + Vector2(0.0, -radius), center + Vector2(radius, radius), center + Vector2(-radius, radius)]), display_tone)
		"DIAMOND":
			_draw_polygon(PackedVector2Array([center + Vector2(0.0, -radius), center + Vector2(radius, 0.0), center + Vector2(0.0, radius), center + Vector2(-radius, 0.0)]), display_tone)
		"PENTAGON":
			var points := PackedVector2Array()
			for index in 5:
				var angle := -PI * 0.5 + TAU * float(index) / 5.0
				points.append(center + Vector2(cos(angle), sin(angle)) * radius)
			_draw_polygon(points, display_tone)
		"HEXAGON":
			var points := PackedVector2Array()
			for index in 6:
				var angle := -PI * 0.5 + TAU * float(index) / 6.0
				points.append(center + Vector2(cos(angle), sin(angle)) * radius)
			_draw_polygon(points, display_tone)
		_:
			if filled:
				draw_rect(Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), display_tone, true)
			else:
				draw_rect(Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0), display_tone, false, 2.0)
	if filled:
		draw_circle(center - Vector2(radius * 0.24, radius * 0.28), maxf(1.0, radius * 0.14), Color(1.0, 1.0, 1.0, 0.48 * state_alpha))


func _draw_polygon(points: PackedVector2Array, color: Color) -> void:
	if filled:
		draw_colored_polygon(points, color)
	else:
		var outline := points.duplicate()
		outline.append(points[0])
		draw_polyline(outline, color, 2.0, true)
