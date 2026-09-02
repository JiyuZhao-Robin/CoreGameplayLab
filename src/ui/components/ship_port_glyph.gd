class_name ShipPortGlyph
extends Control

const ShipPortFxShader = preload("res://src/ui/shaders/ship_port_fx.gdshader")
const INSTALL_FLASH_DURATION := 0.20
const PACKET_FLASH_DURATION := 0.18

var shape := "SQUARE"
var tone := Color.WHITE
var filled := true
var visual_state := "idle"
var tier := 1
var diameter_m := 5.0
var functional_shape := false
var _install_flash_remaining := 0.0
var _hovered := false
var _selected := false
var _stable_id := ""
var _fx_surface: ColorRect
var _fx_material: ShaderMaterial
var _arrival_tween: Tween
var _display_size := Vector2(18.0, 18.0)


func _ready() -> void:
	custom_minimum_size = _display_size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_fx_surface()
	resized.connect(_layout_fx_surface)
	_layout_fx_surface()
	_sync_fx_parameters()
	set_process(false)


func set_display_size(display_size: Vector2) -> void:
	_display_size = Vector2(maxf(1.0, display_size.x), maxf(1.0, display_size.y))
	custom_minimum_size = _display_size


func configure(value: String, color: Color, is_filled := true, state := "idle", socket_tier := 1, physical_diameter_m := 5.0, use_functional_shape := false) -> void:
	functional_shape = use_functional_shape
	shape = value.to_upper() if functional_shape else "CIRCLE"
	tone = color
	filled = is_filled
	visual_state = state
	tier = clampi(socket_tier, 1, 5)
	diameter_m = maxf(1.0, physical_diameter_m)
	_ensure_fx_surface()
	_sync_fx_parameters()
	queue_redraw()


func set_activity_seed(stable_id: String) -> void:
	_stable_id = stable_id
	_sync_fx_parameters()


func set_focus_state(hovered: bool, selected: bool) -> void:
	_hovered = hovered
	_selected = selected
	_sync_fx_parameters()


func flash_install() -> void:
	_play_arrival(INSTALL_FLASH_DURATION, 1.0)


func flash_packet_arrival() -> void:
	_play_arrival(PACKET_FLASH_DURATION, 0.62)


func fx_material() -> ShaderMaterial:
	return _fx_material


func _ensure_fx_surface() -> void:
	if is_instance_valid(_fx_surface):
		return
	_fx_surface = ColorRect.new()
	_fx_surface.name = "ShipPortFx"
	_fx_surface.color = Color.WHITE
	_fx_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_material = ShaderMaterial.new()
	_fx_material.shader = ShipPortFxShader
	_fx_surface.material = _fx_material
	add_child(_fx_surface)
	_fx_surface.set_anchors_preset(Control.PRESET_TOP_LEFT)
	call_deferred("_layout_fx_surface")


func _layout_fx_surface() -> void:
	if not is_instance_valid(_fx_surface):
		return
	var side := minf(size.x, size.y)
	if side <= 0.0:
		side = minf(custom_minimum_size.x, custom_minimum_size.y)
	var square_size := Vector2.ONE * maxf(1.0, side)
	_fx_surface.position = (size - square_size) * 0.5
	_fx_surface.size = square_size


func _sync_fx_parameters() -> void:
	if not is_instance_valid(_fx_material):
		return
	var disabled := visual_state in ["muted", "incompatible", "disabled"]
	var active := 0.0
	if not disabled:
		active = 1.0 if visual_state == "connected" else (0.72 if visual_state == "origin" else (0.48 if visual_state == "compatible" else 0.0))
	var stable_value := _stable_id if not _stable_id.is_empty() else String(name)
	var seed := float(abs(stable_value.hash()) % 4093) / 4093.0
	_fx_material.set_shader_parameter("interface_color", Color("8d5148") if visual_state == "incompatible" else tone)
	_fx_material.set_shader_parameter("active_amount", active)
	_fx_material.set_shader_parameter("filled_amount", 1.0 if filled else 0.0)
	_fx_material.set_shader_parameter("hover_amount", 1.0 if _hovered or visual_state == "hover" else 0.0)
	_fx_material.set_shader_parameter("selection_amount", 1.0 if _selected else 0.0)
	_fx_material.set_shader_parameter("phase_offset", seed)
	_fx_material.set_shader_parameter("sweep_period", 6.0 + seed * 6.0)


func _play_arrival(duration: float, strength: float) -> void:
	_ensure_fx_surface()
	if is_instance_valid(_arrival_tween):
		_arrival_tween.kill()
	_install_flash_remaining = duration
	_fx_material.set_shader_parameter("arrival_amount", 1.0)
	_fx_material.set_shader_parameter("arrival_strength", strength)
	_arrival_tween = create_tween()
	_arrival_tween.set_trans(Tween.TRANS_QUAD)
	_arrival_tween.set_ease(Tween.EASE_OUT)
	_arrival_tween.tween_method(_set_arrival_progress.bind(duration), 0.0, 1.0, duration)
	_arrival_tween.tween_callback(_finish_arrival)


func _set_arrival_progress(progress: float, duration: float) -> void:
	_install_flash_remaining = duration * (1.0 - progress)
	if is_instance_valid(_fx_material):
		_fx_material.set_shader_parameter("arrival_amount", 1.0 - progress)


func _finish_arrival() -> void:
	_install_flash_remaining = 0.0
	if is_instance_valid(_fx_material):
		_fx_material.set_shader_parameter("arrival_amount", 0.0)
		_fx_material.set_shader_parameter("arrival_strength", 0.0)


func _draw() -> void:
	var center := size * 0.5
	# Functional geometry is engineering information, not decoration. Use nearly
	# the complete socket bay so triangles, diamonds and pentagons stay legible to
	# a human at normal zoom instead of reading as tiny colored dots.
	var radius := minf(size.x, size.y) * 0.40
	var state_alpha := 0.30 if visual_state in ["muted", "incompatible"] else 1.0
	var display_tone := tone
	if visual_state == "incompatible":
		display_tone = Color("8d5148")
	display_tone.a *= state_alpha

	var mounting_radius := minf(minf(size.x, size.y) * 0.48, radius + 3.0)
	draw_circle(center, mounting_radius, Color("0b1210"))
	draw_arc(center, mounting_radius, 0.0, TAU, 32, Color(display_tone, 0.30 * state_alpha), 1.0, true)
	if shape == "CIRCLE":
		if filled:
			draw_circle(center, radius, display_tone)
		else:
			draw_arc(center, radius, 0.0, TAU, 32, display_tone, 2.0, true)
	else:
		var points := _shape_points(center, radius, shape)
		if filled:
			draw_colored_polygon(points, display_tone)
		_draw_polygon_outline(points, display_tone, 3.0)
	if filled:
		draw_circle(center - Vector2(radius * 0.24, radius * 0.28), maxf(1.0, radius * 0.14), Color(1.0, 1.0, 1.0, 0.48 * state_alpha))


func _shape_points(center: Vector2, radius: float, shape_name: String) -> PackedVector2Array:
	var sides := int({"TRIANGLE":3, "SQUARE":4, "DIAMOND":4, "PENTAGON":5}.get(shape_name, 4))
	var rotation := -PI * 0.5
	if shape_name == "SQUARE":
		rotation = PI * 0.25
	elif shape_name == "DIAMOND":
		rotation = 0.0
	var points := PackedVector2Array()
	for index in sides:
		var angle := rotation + TAU * float(index) / float(sides)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points


func _draw_polygon_outline(points: PackedVector2Array, color: Color, width: float) -> void:
	if points.size() < 2:
		return
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, color, width, true)
