class_name SystemMapView
extends Control

signal location_selected(location_id: String)

const COLOR_SPACE := Color("070d14")
const COLOR_GRID := Color(0.22, 0.45, 0.55, 0.24)
const COLOR_ROUTE := Color(0.42, 0.60, 0.68, 0.62)
const COLOR_ROUTE_LOCKED := Color(0.24, 0.31, 0.36, 0.45)
const COLOR_DISCOVERED := Color("58dce4")
const COLOR_UNKNOWN := Color("6e7b86")
const COLOR_SELECTED := Color("9bd66f")
const NODE_SIZE := Vector2(156.0, 58.0)

var _locations: Array[Dictionary] = []
var _routes: Array[Dictionary] = []
var _selected_location_id := ""
var _node_buttons: Dictionary = {}
var _positions: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(760.0, 560.0)
	mouse_filter = Control.MOUSE_FILTER_PASS
	clip_contents = true
	resized.connect(_on_resized)


func configure(locations: Array[Dictionary], routes: Array[Dictionary], selected_location_id: String) -> void:
	_locations = locations.duplicate(true)
	_routes = routes.duplicate(true)
	_selected_location_id = selected_location_id
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_node_buttons.clear()
	for location in _locations:
		var location_id := String(location.get("id", ""))
		if location_id.is_empty():
			continue
		var discovered := bool(location.get("discovered", false))
		var button := Button.new()
		button.name = "Location_%s" % location_id
		button.text = "%s\n%s" % [String(location.get("name", location_id)), String(location.get("survey_state", "UNKNOWN"))]
		button.disabled = false
		button.alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.custom_minimum_size = NODE_SIZE
		button.add_theme_font_size_override("font_size", 12)
		button.add_theme_color_override("font_color", COLOR_DISCOVERED if discovered else COLOR_UNKNOWN)
		button.add_theme_color_override("font_disabled_color", COLOR_UNKNOWN)
		button.add_theme_stylebox_override("normal", _node_style(Color(0.02, 0.09, 0.12, 0.94), COLOR_SELECTED if location_id == _selected_location_id else COLOR_DISCOVERED))
		button.add_theme_stylebox_override("hover", _node_style(Color(0.03, 0.14, 0.18, 0.98), COLOR_SELECTED))
		button.add_theme_stylebox_override("pressed", _node_style(Color(0.02, 0.18, 0.20, 1.0), COLOR_SELECTED))
		button.add_theme_stylebox_override("disabled", _node_style(Color(0.02, 0.035, 0.05, 0.92), COLOR_UNKNOWN))
		button.pressed.connect(location_selected.emit.bind(location_id))
		add_child(button)
		_node_buttons[location_id] = button
	_layout_nodes()
	queue_redraw()


func _on_resized() -> void:
	_layout_nodes()
	queue_redraw()


func _layout_nodes() -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	_positions.clear()
	var center := Vector2(size.x * 0.50, size.y * 0.50)
	var orbit_step := minf(size.x, size.y) * 0.072
	var first_orbit := minf(size.x, size.y) * 0.16
	var count := maxi(1, _locations.size())
	for index in _locations.size():
		var location := _locations[index]
		var location_id := String(location.get("id", ""))
		var angle := -PI * 0.82 + float(index) * TAU / float(count)
		var radius := first_orbit + float(index) * orbit_step
		var position := center + Vector2(cos(angle), sin(angle) * 0.72) * radius
		position.x = clampf(position.x, NODE_SIZE.x * 0.55 + 18.0, size.x - NODE_SIZE.x * 0.55 - 18.0)
		position.y = clampf(position.y, NODE_SIZE.y * 0.55 + 18.0, size.y - NODE_SIZE.y * 0.55 - 18.0)
		_positions[location_id] = position
		var button := _node_buttons.get(location_id) as Button
		if is_instance_valid(button):
			button.position = position - NODE_SIZE * 0.5
			button.size = NODE_SIZE


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COLOR_SPACE)
	_draw_stars()
	var center := Vector2(size.x * 0.50, size.y * 0.50)
	var orbit_step := minf(size.x, size.y) * 0.072
	var first_orbit := minf(size.x, size.y) * 0.16
	for index in _locations.size():
		var radius := first_orbit + float(index) * orbit_step
		draw_arc(center, radius, 0.0, TAU, 96, COLOR_GRID, 1.0, true)
	for route in _routes:
		var from_id := String(route.get("from", ""))
		var to_id := String(route.get("to", ""))
		if not _positions.has(from_id) or not _positions.has(to_id):
			continue
		var active := bool(route.get("active", false))
		draw_dashed_line(_positions[from_id], _positions[to_id], COLOR_ROUTE if active else COLOR_ROUTE_LOCKED, 2.0 if active else 1.0, 9.0, true)
	_draw_star(center)
	_draw_legend()


func _draw_stars() -> void:
	for index in 84:
		var x := fmod(float(index * 83 + 29), 997.0) / 997.0 * size.x
		var y := fmod(float(index * 151 + 47), 991.0) / 991.0 * size.y
		var alpha: float = 0.18 + float(index % 5) * 0.06
		draw_circle(Vector2(x, y), 0.7 + float(index % 3) * 0.35, Color(0.50, 0.82, 0.92, alpha))


func _draw_star(center: Vector2) -> void:
	for radius in [42.0, 31.0, 21.0, 12.0]:
		var alpha: float = 0.05 + (42.0 - radius) / 70.0
		draw_circle(center, radius, Color(0.35, 0.90, 1.0, alpha))
	draw_circle(center, 8.0, Color("d9f7ff"))
	draw_line(center - Vector2(28.0, 0.0), center + Vector2(28.0, 0.0), Color(0.40, 0.92, 1.0, 0.42), 1.0)
	draw_line(center - Vector2(0.0, 28.0), center + Vector2(0.0, 28.0), Color(0.40, 0.92, 1.0, 0.42), 1.0)


func _draw_legend() -> void:
	var origin := Vector2(18.0, size.y - 64.0)
	draw_circle(origin, 4.0, COLOR_DISCOVERED)
	draw_string(ThemeDB.fallback_font, origin + Vector2(12.0, 5.0), "DISCOVERED / OPERABLE", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.70, 0.82, 0.86))
	draw_circle(origin + Vector2(0.0, 24.0), 4.0, COLOR_UNKNOWN)
	draw_string(ThemeDB.fallback_font, origin + Vector2(12.0, 29.0), "UNKNOWN / LOCKED", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color(0.48, 0.56, 0.61))


func _node_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	return style
