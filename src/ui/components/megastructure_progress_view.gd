class_name MegastructureProgressView
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const COLOR_SPACE := Color("07111b")
const COLOR_GRID := Color(0.20, 0.47, 0.55, 0.24)
const COLOR_FRAME := Color("3f8394")
const COLOR_ACTIVE := Color("58dce4")
const COLOR_COMPLETE := Color("9bd66f")
const COLOR_ENERGY := Color("e1b85c")
const COLOR_MUTED := Color("6e7b86")

var _phase_index := 0
var _phase_count := 8
var _complete := false
var _stage_name := ""


func _ready() -> void:
	custom_minimum_size = Vector2(720.0, 300.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func configure(phase_index: int, phase_count: int, complete: bool, stage_name: String) -> void:
	_phase_count = maxi(1, phase_count)
	_phase_index = clampi(phase_index, 0, _phase_count)
	_complete = complete
	_stage_name = stage_name
	tooltip_text = I18n.core("megastructure.progress_tooltip") % [_stage_name, _phase_count if _complete else _phase_index, _phase_count]
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, COLOR_SPACE, true)
	draw_rect(rect.grow(-1.0), COLOR_GRID, false, 1.0)
	var center := Vector2(size.x * 0.50, size.y * 0.53)
	var limit := minf(size.x * 0.36, size.y * 0.39)
	_draw_grid(center, limit)
	_draw_star(center)
	var visible_layers := _phase_count if _complete else _phase_index
	if visible_layers >= 1:
		_draw_forward_base(center, limit)
	if visible_layers >= 2:
		_draw_foundation(center, limit)
	if visible_layers >= 3:
		_draw_primary_frame(center, limit)
	if visible_layers >= 4:
		_draw_energy_backbone(center, limit)
	if visible_layers >= 5:
		_draw_collectors(center, limit)
	if visible_layers >= 6:
		_draw_integration(center, limit)
	if visible_layers >= 7:
		_draw_commissioning(center, limit)
	if _complete or visible_layers >= _phase_count:
		_draw_operational(center, limit)
	_draw_phase_caption()


func _draw_grid(center: Vector2, limit: float) -> void:
	for index in range(1, 5):
		var radius := limit * float(index) / 4.0
		draw_arc(center, radius, 0.0, TAU, 96, COLOR_GRID, 1.0)
	draw_line(Vector2(22.0, center.y), Vector2(size.x - 22.0, center.y), COLOR_GRID, 1.0)
	draw_line(Vector2(center.x, 22.0), Vector2(center.x, size.y - 36.0), COLOR_GRID, 1.0)


func _draw_star(center: Vector2) -> void:
	for radius in [28.0, 21.0, 14.0]:
		var alpha: float = 0.16 + (28.0 - float(radius)) * 0.02
		draw_circle(center, radius, Color(COLOR_ENERGY, alpha))
	draw_circle(center, 9.0, COLOR_ENERGY)


func _draw_forward_base(center: Vector2, limit: float) -> void:
	var base := center + Vector2(-limit * 0.88, limit * 0.58)
	draw_rect(Rect2(base - Vector2(23.0, 11.0), Vector2(46.0, 22.0)), COLOR_FRAME, true)
	draw_line(base + Vector2(-30.0, 14.0), base + Vector2(30.0, 14.0), COLOR_ACTIVE, 3.0)
	draw_line(base, center + Vector2(-limit * 0.66, 0.0), COLOR_FRAME, 2.0)


func _draw_foundation(center: Vector2, limit: float) -> void:
	draw_arc(center, limit * 0.66, -2.78, -0.36, 72, COLOR_FRAME, 8.0)
	for angle in [-2.65, -2.05, -1.45, -0.85, -0.45]:
		var outer := center + Vector2.from_angle(angle) * limit * 0.70
		var inner := center + Vector2.from_angle(angle) * limit * 0.55
		draw_line(inner, outer, COLOR_ACTIVE, 4.0)


func _draw_primary_frame(center: Vector2, limit: float) -> void:
	draw_arc(center, limit * 0.78, -2.95, -0.18, 96, COLOR_FRAME, 5.0)
	draw_arc(center, limit * 0.54, -2.95, -0.18, 96, COLOR_FRAME, 4.0)
	for index in range(9):
		var angle := lerpf(-2.88, -0.25, float(index) / 8.0)
		draw_line(center + Vector2.from_angle(angle) * limit * 0.54, center + Vector2.from_angle(angle) * limit * 0.78, COLOR_FRAME, 3.0)


func _draw_energy_backbone(center: Vector2, limit: float) -> void:
	draw_arc(center, limit * 0.88, -3.05, -0.09, 112, COLOR_ENERGY, 3.0)
	for index in range(7):
		var angle := lerpf(-2.92, -0.22, float(index) / 6.0)
		var node := center + Vector2.from_angle(angle) * limit * 0.88
		draw_circle(node, 5.0, COLOR_ENERGY)


func _draw_collectors(center: Vector2, limit: float) -> void:
	for index in range(12):
		var angle := lerpf(-2.98, -0.16, float(index) / 11.0)
		var radial := Vector2.from_angle(angle)
		var point := center + radial * limit * 0.70
		var tangent := radial.rotated(PI * 0.5)
		var polygon := PackedVector2Array([
			point - tangent * 10.0 - radial * 7.0,
			point + tangent * 10.0 - radial * 7.0,
			point + tangent * 8.0 + radial * 7.0,
			point - tangent * 8.0 + radial * 7.0
		])
		draw_colored_polygon(polygon, Color(COLOR_ACTIVE, 0.72))


func _draw_integration(center: Vector2, limit: float) -> void:
	for radius_scale in [0.61, 0.71, 0.82]:
		draw_arc(center, limit * radius_scale, -3.02, -0.12, 96, Color(COLOR_ACTIVE, 0.60), 2.0)


func _draw_commissioning(center: Vector2, limit: float) -> void:
	for index in range(5):
		var angle := lerpf(-2.75, -0.39, float(index) / 4.0)
		var point := center + Vector2.from_angle(angle) * limit * 0.95
		draw_circle(point, 8.0, Color(COLOR_COMPLETE, 0.32))
		draw_circle(point, 3.0, COLOR_COMPLETE)


func _draw_operational(center: Vector2, limit: float) -> void:
	draw_arc(center, limit, -3.10, -0.04, 128, COLOR_COMPLETE, 4.0)
	draw_arc(center, limit * 1.04, -3.10, -0.04, 128, Color(COLOR_COMPLETE, 0.30), 8.0)


func _draw_phase_caption() -> void:
	var font := ThemeDB.fallback_font
	var stage := _stage_name if not _stage_name.is_empty() else I18n.core("megastructure.progress_default_stage")
	var counter := I18n.core("common.ratio") % [_phase_count if _complete else _phase_index, _phase_count]
	draw_string(font, Vector2(18.0, size.y - 15.0), stage, HORIZONTAL_ALIGNMENT_LEFT, size.x - 105.0, UiTokens.font_size(13), COLOR_MUTED)
	draw_string(font, Vector2(size.x - 86.0, size.y - 15.0), counter, HORIZONTAL_ALIGNMENT_RIGHT, 68.0, UiTokens.font_size(13), COLOR_COMPLETE if _complete else COLOR_ACTIVE)
