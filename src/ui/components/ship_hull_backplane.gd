class_name ShipHullBackplane
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipHullProfiles = preload("res://src/ui/components/ship_hull_profiles.gd")
const ShipHullVisualScript = preload("res://src/ui/components/ship_hull_visual.gd")

var tone := UiTokens.COLOR_INFORMATION
var visual_spec: Dictionary = {}
var ui_visual: Dictionary = {}
var _ship_visual: ShipHullVisual
var _art_active := false
var _engineering_emphasis := 1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func configure(color: Color, spec: Dictionary = {}, presentation: Dictionary = {}) -> void:
	tone = color
	visual_spec = spec.duplicate(true)
	ui_visual = presentation.duplicate(true)
	_install_visual_layer()
	queue_redraw()


func has_visual_asset() -> bool:
	return _art_active


func ship_visual() -> ShipHullVisual:
	return _ship_visual if _art_active else null


func set_presentation_state(hovered: bool, selected: bool, zoom_level: float, connection_activity: float) -> void:
	_engineering_emphasis = 1.0 + (0.08 if hovered else 0.0) + (0.14 if selected else 0.0)
	if is_instance_valid(_ship_visual):
		_ship_visual.set_presentation_state(hovered, selected, zoom_level, connection_activity)
	queue_redraw()


func _install_visual_layer() -> void:
	if is_instance_valid(_ship_visual):
		remove_child(_ship_visual)
		_ship_visual.queue_free()
	_ship_visual = ShipHullVisualScript.new()
	_ship_visual.name = "ShipHullVisual"
	_ship_visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ship_visual.show_behind_parent = true
	add_child(_ship_visual)
	_ship_visual.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art_active = _ship_visual.configure(ui_visual, visual_spec)
	if not _art_active:
		remove_child(_ship_visual)
		_ship_visual.queue_free()
		_ship_visual = null


func _draw() -> void:
	if size.x < 24.0 or size.y < 24.0:
		return
	if not _art_active:
		var panel := Rect2(Vector2(2.0, 2.0), size - Vector2(4.0, 4.0))
		var panel_points := _cut_corners(panel, 11.0)
		draw_colored_polygon(panel_points, Color("08100e"))
		_draw_polygon_outline(panel_points, Color(tone, 0.34), 1.0)
		_draw_metric_grid(panel.grow(-5.0))
	if visual_spec.is_empty():
		return
	var hull_rectangle := _local_hull_rect()
	var outline := _scaled_outline(visual_spec, hull_rectangle)
	if _art_active:
		# The authored alpha silhouette is authoritative in high-detail mode.
		# Keep only a nearly invisible logical registration trace; procedural
		# ribs and dimension labels must not fight the authored art.
		_draw_polygon_outline(outline, Color(tone, _overlay_alpha(0.13)), 1.0)
		return
	if not _art_active:
		draw_colored_polygon(outline, Color("101815"))
	_draw_polygon_outline(outline, Color(tone, _overlay_alpha(1.0)), 2.0)
	var inner := PackedVector2Array()
	var center := hull_rectangle.get_center()
	for point in outline:
		inner.append(center + (point - center) * 0.91)
	_draw_polygon_outline(inner, Color(UiTokens.COLOR_SHIP_FRAME_INNER, _overlay_alpha(0.94)), 1.0)
	_draw_hull_structure(hull_rectangle)
	_draw_bays(hull_rectangle)


func _draw_metric_grid(rectangle: Rect2) -> void:
	var major_m := _engineering_step(float(visual_spec.get("length_m", 120.0)) / 16.0) if not visual_spec.is_empty() else 20.0
	var minor_px := major_m / 5.0 * ShipHullProfiles.WORLD_SCALE
	var minor_color := Color(UiTokens.COLOR_SHIP_GRID_MINOR, 0.38)
	var major_color := Color(UiTokens.COLOR_SHIP_GRID_MAJOR, 0.72)
	var x := rectangle.position.x
	var index := 0
	while x <= rectangle.end.x:
		draw_line(Vector2(x, rectangle.position.y), Vector2(x, rectangle.end.y), major_color if index % 5 == 0 else minor_color, 1.0)
		x += minor_px
		index += 1
	var y := rectangle.position.y
	index = 0
	while y <= rectangle.end.y:
		draw_line(Vector2(rectangle.position.x, y), Vector2(rectangle.end.x, y), major_color if index % 5 == 0 else minor_color, 1.0)
		y += minor_px
		index += 1
	var grid_text := I18n.core("ships.shipyard.projection_grid", "GRID %.0fm / %.0fm") % [major_m / 5.0, major_m]
	draw_string(ThemeDB.fallback_font, rectangle.position + Vector2(8.0, 20.0), grid_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, UiTokens.ship_assembly_font_size(10), UiTokens.COLOR_TEXT_MUTED)


func _draw_hull_structure(rectangle: Rect2) -> void:
	var center_x := rectangle.get_center().x
	draw_line(Vector2(center_x, rectangle.position.y + 4.0), Vector2(center_x, rectangle.end.y - 4.0), Color(tone, _overlay_alpha(0.48)), 1.0, true)
	for station_value in [-0.34, -0.20, -0.06, 0.08, 0.22, 0.36]:
		var station: float = float(station_value)
		var normalized_y: float = station * 88.0
		var y: float = rectangle.position.y + (normalized_y + 44.0) / 88.0 * rectangle.size.y
		var half_width := _half_width_at(normalized_y) / _maximum_half_width() * rectangle.size.x * 0.5 * 0.78
		draw_line(Vector2(center_x - half_width, y), Vector2(center_x + half_width, y), Color(UiTokens.COLOR_SHIP_FRAME_INNER, _overlay_alpha(0.82)), 1.0, true)
	var left_spine := PackedVector2Array()
	var right_spine := PackedVector2Array()
	var half := visual_spec.get("half", []) as Array
	for index in half.size():
		if index == 0 or index == half.size() - 1 or index % 2 == 0:
			continue
		var value := half[index] as Array
		var normalized_y := float(value[1])
		var y := rectangle.position.y + (normalized_y + 44.0) / 88.0 * rectangle.size.y
		var x_offset := float(value[0]) / _maximum_half_width() * rectangle.size.x * 0.21
		left_spine.append(Vector2(center_x - x_offset, y))
		right_spine.append(Vector2(center_x + x_offset, y))
	if left_spine.size() > 1:
		draw_polyline(left_spine, Color(tone, _overlay_alpha(0.38)), 1.0, true)
		draw_polyline(right_spine, Color(tone, _overlay_alpha(0.38)), 1.0, true)


func _draw_bays(rectangle: Rect2) -> void:
	var bays := visual_spec.get("bays", []) as Array
	for bay_value in bays:
		var bay := bay_value as Dictionary
		var center_x := float(bay.get("x", 0.0))
		_draw_single_bay(rectangle, center_x, bay)
		if not is_zero_approx(center_x):
			_draw_single_bay(rectangle, -center_x, bay)


func _draw_single_bay(rectangle: Rect2, center_x: float, bay: Dictionary) -> void:
	var top := float(bay.get("top", -10.0))
	var bottom := float(bay.get("bottom", 10.0))
	var width := float(bay.get("width", 8.0))
	var points := PackedVector2Array()
	for value in [[center_x-width*0.36,top],[center_x+width*0.36,top],[center_x+width*0.5,top+4.0],[center_x+width*0.44,bottom-4.0],[center_x+width*0.26,bottom],[center_x-width*0.26,bottom],[center_x-width*0.44,bottom-4.0],[center_x-width*0.5,top+4.0]]:
		var pair := value as Array
		points.append(Vector2(rectangle.get_center().x + float(pair[0]) / _maximum_half_width() * rectangle.size.x * 0.5, rectangle.position.y + (float(pair[1]) + 44.0) / 88.0 * rectangle.size.y))
	if not _art_active:
		draw_colored_polygon(points, Color("08100e"))
	_draw_polygon_outline(points, Color(UiTokens.COLOR_SHIP_FRAME_INNER, _overlay_alpha(0.92)), 1.0)


func _local_hull_rect() -> Rect2:
	var dimensions := Vector2(float(visual_spec.get("beam_m", 36.0)), float(visual_spec.get("length_m", 120.0))) * ShipHullProfiles.WORLD_SCALE
	return Rect2(Vector2((size.x - dimensions.x) * 0.5, (size.y - dimensions.y) * 0.5), dimensions)


func _overlay_alpha(value: float) -> float:
	var art_multiplier := 0.50 if _art_active else 1.0
	return clampf(value * art_multiplier * _engineering_emphasis, 0.0, 1.0)


func _scaled_outline(spec: Dictionary, rectangle: Rect2) -> PackedVector2Array:
	var meters := ShipHullProfiles.outline_meters(spec)
	var beam := float(spec.get("beam_m", 36.0))
	var length := float(spec.get("length_m", 120.0))
	var result := PackedVector2Array()
	for point in meters:
		result.append(rectangle.position + Vector2(point.x / beam * rectangle.size.x, point.y / length * rectangle.size.y))
	return result


func _half_width_at(y: float) -> float:
	var half := visual_spec.get("half", []) as Array
	for index in half.size() - 1:
		var start := half[index] as Array
		var finish := half[index + 1] as Array
		if y < float(start[1]) or y > float(finish[1]):
			continue
		var progress := (y - float(start[1])) / maxf(0.0001, float(finish[1]) - float(start[1]))
		return lerpf(float(start[0]), float(finish[0]), progress)
	return 0.0


func _maximum_half_width() -> float:
	var result := 1.0
	for value in visual_spec.get("half", []) as Array:
		result = maxf(result, float((value as Array)[0]))
	return result


func _engineering_step(value: float) -> float:
	var exponent := floorf(log(maxf(value, 0.001)) / log(10.0))
	var power := pow(10.0, exponent)
	var scaled := value / power
	var nice := 1.0 if scaled <= 1.0 else (2.0 if scaled <= 2.0 else (5.0 if scaled <= 5.0 else 10.0))
	return nice * power


func _cut_corners(rect: Rect2, cut: float) -> PackedVector2Array:
	return PackedVector2Array([
		rect.position + Vector2(cut, 0.0), Vector2(rect.end.x - cut, rect.position.y),
		Vector2(rect.end.x, rect.position.y + cut), Vector2(rect.end.x, rect.end.y - cut),
		Vector2(rect.end.x - cut, rect.end.y), Vector2(rect.position.x + cut, rect.end.y),
		Vector2(rect.position.x, rect.end.y - cut), Vector2(rect.position.x, rect.position.y + cut)
	])


func _draw_polygon_outline(points: PackedVector2Array, color: Color, width: float) -> void:
	if points.is_empty():
		return
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, color, width, true)
