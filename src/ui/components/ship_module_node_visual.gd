class_name ShipModuleNodeVisual
extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipPortGlyphScript = preload("res://src/ui/components/ship_port_glyph.gd")

signal socket_gui_input(event: InputEvent)

const CARD_SIZE := Vector2(328.0, 128.0)
const ART_RECT_LEFT := Rect2(12.0, 12.0, 100.0, 104.0)
const ART_RECT_RIGHT := Rect2(216.0, 12.0, 100.0, 104.0)
const SOCKET_HIT_SIZE := Vector2(52.0, 52.0)
const SOCKET_INSET_HORIZONTAL := 44.0

var module_id := ""
var display_name := ""
var family_label := ""
var english_subtitle := ""
var metadata_text := ""
var shape := "SQUARE"
var tone := Color.WHITE
var tier := 1
var diameter_m := 5.0
var functional_shape := false

var _facing_normal := Vector2.RIGHT
var _hovered := false
var _selected := false
var _dragging := false
var _connection_active := false
var _connected := false
var _invalid := false
var _zoom_level := 1.0

var _artwork: TextureRect
var _name_label: Label
var _family_label: Label
var _subtitle_label: Label
var _metadata_label: Label
var _socket_hit: Control
var _socket_glyph: ShipPortGlyph


func _ready() -> void:
	custom_minimum_size = CARD_SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false
	_ensure_children()
	_layout_content()


func configure(presentation: Dictionary) -> void:
	module_id = String(presentation.get("module_id", ""))
	display_name = String(presentation.get("display_name", module_id))
	family_label = String(presentation.get("family_label", ""))
	english_subtitle = String(presentation.get("english_subtitle", ""))
	metadata_text = String(presentation.get("metadata", ""))
	shape = String(presentation.get("shape", "SQUARE"))
	tone = presentation.get("tone", Color.WHITE) as Color
	tier = int(presentation.get("tier", 1))
	diameter_m = float(presentation.get("diameter_m", 5.0))
	functional_shape = bool(presentation.get("functional_shape", false))
	_ensure_children()
	_socket_glyph.set_activity_seed(String(presentation.get("stable_id", module_id)))
	_name_label.text = display_name
	_family_label.text = family_label
	_subtitle_label.text = english_subtitle
	_metadata_label.text = metadata_text
	var art_path := String(presentation.get("art_path", ""))
	_artwork.texture = load(art_path) as Texture2D if not art_path.is_empty() and ResourceLoader.exists(art_path) else null
	_sync_visual_state()
	_layout_content()


func set_presentation_state(hovered: bool, selected: bool, dragging: bool, connection_active: bool, connected: bool, invalid: bool, zoom_level: float, facing_normal: Vector2) -> void:
	_hovered = hovered
	_selected = selected
	_dragging = dragging
	_connection_active = connection_active
	_connected = connected
	_invalid = invalid
	_zoom_level = zoom_level
	_facing_normal = _cardinal_normal(facing_normal)
	_sync_visual_state()
	_layout_content()
	queue_redraw()


func routing_port_local() -> Vector2:
	return routing_port_local_for_normal(_facing_normal)


func routing_port_local_for_normal(normal_value: Vector2) -> Vector2:
	var normal := _cardinal_normal(normal_value)
	var socket_center := visual_socket_center_local_for_normal(normal)
	if normal == Vector2.LEFT:
		return Vector2(0.0, socket_center.y)
	if normal == Vector2.RIGHT:
		return Vector2(CARD_SIZE.x, socket_center.y)
	if normal == Vector2.UP:
		return Vector2(socket_center.x, 0.0)
	return Vector2(socket_center.x, CARD_SIZE.y)


func visual_socket_center_local() -> Vector2:
	return visual_socket_center_local_for_normal(_facing_normal)


func visual_socket_center_local_for_normal(normal_value: Vector2) -> Vector2:
	var normal := _cardinal_normal(normal_value)
	if normal == Vector2.LEFT:
		return Vector2(SOCKET_INSET_HORIZONTAL, CARD_SIZE.y * 0.5)
	# Keep the connector ball vertically centered on the card's right side. Top
	# and bottom routes turn only the short stub toward their selected edge; the
	# interactive ball itself no longer jumps up or down as routing changes.
	return Vector2(CARD_SIZE.x - SOCKET_INSET_HORIZONTAL, CARD_SIZE.y * 0.5)


func socket_glyph() -> ShipPortGlyph:
	return _socket_glyph


func socket_hit_target() -> Control:
	return _socket_hit


func facing_normal() -> Vector2:
	return _facing_normal


func lod_level() -> String:
	if _zoom_level < 0.34:
		return "very_far"
	if _zoom_level < 0.58:
		return "far"
	if _zoom_level < 1.08:
		return "normal"
	return "close"


func _ensure_children() -> void:
	if is_instance_valid(_artwork):
		return
	_artwork = TextureRect.new()
	_artwork.name = "ModuleArtwork"
	_artwork.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_artwork.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_artwork.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_artwork)

	_name_label = _new_label("ModuleName", UiTokens.ship_assembly_font_size(11), UiTokens.COLOR_TEXT)
	_name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_name_label.max_lines_visible = 1
	add_child(_name_label)
	_family_label = _new_label("ModuleFamily", UiTokens.ship_assembly_font_size(9), tone)
	add_child(_family_label)
	_subtitle_label = _new_label("ModuleEnglishSubtitle", UiTokens.ship_assembly_font_size(7), UiTokens.COLOR_TEXT_MUTED)
	add_child(_subtitle_label)
	_metadata_label = _new_label("ModuleMetadata", UiTokens.ship_assembly_font_size(9), Color(tone, 0.82))
	add_child(_metadata_label)

	_socket_hit = Control.new()
	_socket_hit.name = "VisualSocketBay"
	_socket_hit.custom_minimum_size = SOCKET_HIT_SIZE
	_socket_hit.mouse_filter = Control.MOUSE_FILTER_STOP
	_socket_hit.mouse_default_cursor_shape = Control.CURSOR_CROSS
	_socket_hit.gui_input.connect(func(event: InputEvent) -> void: socket_gui_input.emit(event))
	add_child(_socket_hit)
	_socket_glyph = ShipPortGlyphScript.new()
	_socket_glyph.name = "VisualModuleSocket"
	_socket_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_socket_hit.add_child(_socket_glyph)
	_socket_glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _new_label(node_name: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _layout_content() -> void:
	if not is_instance_valid(_artwork):
		return
	var art_rect := ART_RECT_RIGHT if _facing_normal == Vector2.LEFT else ART_RECT_LEFT
	_artwork.position = art_rect.position
	_artwork.size = art_rect.size
	var info_rect := Rect2(72.0, 12.0, 140.0, 104.0) if _facing_normal == Vector2.LEFT else Rect2(120.0, 12.0, 138.0, 104.0)
	_name_label.position = info_rect.position
	_name_label.size = Vector2(info_rect.size.x, 32.0)
	_family_label.position = info_rect.position + Vector2(0.0, 34.0)
	_family_label.size = Vector2(info_rect.size.x, 28.0)
	_metadata_label.position = info_rect.position + Vector2(0.0, 62.0)
	_metadata_label.size = Vector2(info_rect.size.x, 24.0)
	_subtitle_label.position = info_rect.position + Vector2(0.0, 86.0)
	_subtitle_label.size = Vector2(info_rect.size.x, 18.0)
	var socket_center := visual_socket_center_local()
	_socket_hit.position = socket_center - SOCKET_HIT_SIZE * 0.5
	_socket_hit.size = SOCKET_HIT_SIZE

	var lod := lod_level()
	var accessibility_compact := UiTokens.ui_scale() >= 1.5
	_name_label.visible = lod != "very_far"
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if accessibility_compact else TextServer.AUTOWRAP_OFF
	_name_label.max_lines_visible = 2 if accessibility_compact else 1
	if accessibility_compact:
		_name_label.position = info_rect.position
		_name_label.size = info_rect.size
	_subtitle_label.visible = not accessibility_compact and lod == "close" and not english_subtitle.is_empty()
	# Technical metadata is useful only while it has enough actual screen pixels
	# to be read. At smaller graph zooms, hide it instead of leaving a faint row
	# that technically renders but is illegible to a person.
	var metadata_screen_size := float(_metadata_label.get_theme_font_size("font_size")) * _zoom_level
	_metadata_label.visible = not accessibility_compact and lod in ["close", "normal"] and metadata_screen_size >= 12.0
	_family_label.visible = not accessibility_compact and lod != "very_far"
	_artwork.modulate = Color(1.0, 1.0, 1.0, 1.0 if _selected or _hovered else 0.82)


func _sync_visual_state() -> void:
	if not is_instance_valid(_socket_glyph):
		return
	_family_label.add_theme_color_override("font_color", tone)
	var focused := _hovered or _selected or _dragging or _connection_active
	_name_label.add_theme_color_override("font_color", Color(UiTokens.COLOR_TEXT, 1.0 if focused else 0.78))
	_family_label.add_theme_color_override("font_color", Color(tone, 0.94 if focused else 0.68))
	_subtitle_label.add_theme_color_override("font_color", Color(UiTokens.COLOR_TEXT_MUTED, 0.90 if focused else 0.62))
	_metadata_label.add_theme_color_override("font_color", Color(tone, 0.86 if focused else 0.72))
	var state := "incompatible" if _invalid else ("origin" if _connection_active else ("connected" if _connected else ("hover" if _hovered else "idle")))
	_socket_glyph.configure(shape, tone, _connected or _connection_active, state, tier, diameter_m, functional_shape)
	_socket_glyph.set_focus_state(_hovered, _selected)


func _draw() -> void:
	var shadow := _chamfered_rect(Rect2(Vector2(0.0, 5.0), CARD_SIZE), 12.0)
	draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.32 if not _dragging else 0.46))
	var chassis := _chamfered_rect(Rect2(Vector2.ZERO, CARD_SIZE), 12.0)
	draw_colored_polygon(chassis, Color("0b1110"))
	_draw_polygon_outline(chassis, Color(UiTokens.COLOR_BORDER_STRONG, 0.62 if _hovered else 0.42), 1.0)
	var inner := _chamfered_rect(Rect2(Vector2(4.0, 4.0), CARD_SIZE - Vector2(8.0, 8.0)), 8.0)
	draw_colored_polygon(inner, Color("101715"))
	_draw_polygon_outline(inner, Color("26332f"), 1.0)

	var art_rect := ART_RECT_RIGHT if _facing_normal == Vector2.LEFT else ART_RECT_LEFT
	draw_rect(art_rect, Color("070d0c"), true)
	draw_rect(art_rect, Color(tone, 0.18 if _hovered else 0.10), false, 1.0)
	if lod_level() in ["normal", "close"]:
		for offset in [24.0, 48.0, 72.0]:
			draw_line(art_rect.position + Vector2(offset, 0.0), art_rect.position + Vector2(offset, art_rect.size.y), Color(tone, 0.025), 1.0)
		for offset in [24.0, 48.0, 72.0, 96.0]:
			draw_line(art_rect.position + Vector2(0.0, offset), art_rect.position + Vector2(art_rect.size.x, offset), Color(tone, 0.025), 1.0)

	var socket_center := visual_socket_center_local()
	var bay := _chamfered_rect(Rect2(socket_center - SOCKET_HIT_SIZE * 0.5, SOCKET_HIT_SIZE), 8.0)
	draw_colored_polygon(bay, Color("080e0d"))
	_draw_polygon_outline(bay, Color(tone, 0.34 if _selected or _hovered else 0.20), 1.0)
	var port := routing_port_local()
	draw_line(socket_center, port, Color("060a09"), 5.0, true)
	draw_line(socket_center, port, Color(tone, 0.56 if _selected or _hovered else 0.28), 1.0, true)
	draw_circle(port, 2.0, Color(tone, 0.68 if _selected else 0.40))

	# Category color is restricted to short structural accents, the functional
	# socket, metadata and connection stub; the chassis itself remains neutral.
	if _facing_normal.x != 0.0:
		var accent_x := CARD_SIZE.x - 2.0 if _facing_normal == Vector2.RIGHT else 2.0
		draw_line(Vector2(accent_x, 28.0), Vector2(accent_x, 52.0), Color(tone, 0.82), 2.0)
		draw_line(Vector2(accent_x, 76.0), Vector2(accent_x, 100.0), Color(tone, 0.52), 1.0)
	else:
		var accent_y := CARD_SIZE.y - 2.0 if _facing_normal == Vector2.DOWN else 2.0
		draw_line(Vector2(264.0, accent_y), Vector2(304.0, accent_y), Color(tone, 0.82), 2.0)

	if _selected:
		_draw_corner_brackets(Color(tone, 0.88))
	if _invalid:
		var warning_center := Vector2(CARD_SIZE.x - 16.0, 16.0)
		draw_colored_polygon(PackedVector2Array([warning_center + Vector2(0.0, -6.0), warning_center + Vector2(6.0, 5.0), warning_center + Vector2(-6.0, 5.0)]), Color("a95b4e"))


func _draw_corner_brackets(color: Color) -> void:
	for corner in [Vector2(8.0, 8.0), Vector2(CARD_SIZE.x - 8.0, 8.0), Vector2(8.0, CARD_SIZE.y - 8.0), Vector2(CARD_SIZE.x - 8.0, CARD_SIZE.y - 8.0)]:
		var horizontal_direction := 1.0 if corner.x < CARD_SIZE.x * 0.5 else -1.0
		var vertical_direction := 1.0 if corner.y < CARD_SIZE.y * 0.5 else -1.0
		draw_line(corner, corner + Vector2(horizontal_direction * 16.0, 0.0), color, 1.5, true)
		draw_line(corner, corner + Vector2(0.0, vertical_direction * 16.0), color, 1.5, true)


func _cardinal_normal(value: Vector2) -> Vector2:
	if absf(value.x) >= absf(value.y):
		return Vector2.RIGHT if value.x >= 0.0 else Vector2.LEFT
	return Vector2.DOWN if value.y >= 0.0 else Vector2.UP


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
