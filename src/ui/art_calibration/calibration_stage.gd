extends Control

var assets: RefCounted
var zoom := 1.25
var camera := Vector2.ZERO
var playing := true
var running := true
var elapsed := 0.0
var daylight := 1.0
var show_grid := false
var show_anchors := false
var visible_layers := {"base":true, "shadow":true, "mask":true, "emission":true, "smoke":true, "ore":true}
var tint := Color("c48c42")
var dragging := false
var emission_pass: Control
var smoke_pass: Control
var overlay_pass: Control
const CENTERS := [Vector2(-7, 0), Vector2.ZERO, Vector2(7, 0)]
const TILE_PIXELS := 48.0
signal view_changed

func _ready() -> void:
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	emission_pass = Control.new()
	emission_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	emission_pass.material = additive
	add_child(emission_pass)
	emission_pass.draw.connect(_draw_emission)
	smoke_pass = Control.new()
	smoke_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var smoke_material := ShaderMaterial.new()
	smoke_material.shader = preload("res://src/ui/art_calibration/smoke.gdshader")
	smoke_pass.material = smoke_material
	add_child(smoke_pass)
	smoke_pass.draw.connect(_draw_smoke)
	overlay_pass = Control.new()
	overlay_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay_pass)
	overlay_pass.draw.connect(_draw_overlay)
	gui_input.connect(_on_input)
	mouse_default_cursor_shape = Control.CURSOR_DRAG

func _process(delta: float) -> void:
	if playing and running:
		elapsed += minf(delta, 0.1)
		refresh()

func refresh() -> void:
	queue_redraw()
	if emission_pass != null:
		emission_pass.queue_redraw()
		smoke_pass.queue_redraw()
		overlay_pass.queue_redraw()

func point(world: Vector2) -> Vector2:
	return size * Vector2(0.5, 0.48) + (world - camera) * TILE_PIXELS * zoom

func world_at(screen: Vector2) -> Vector2:
	return (screen - size * Vector2(0.5, 0.48)) / (TILE_PIXELS * zoom) + camera

func set_zoom(value: float, anchor: Vector2 = size * 0.5) -> void:
	var before := world_at(anchor)
	zoom = clampf(value, 0.5, 2.0)
	camera += before - world_at(anchor)
	refresh()
	view_changed.emit()

func _on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = event.pressed
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			set_zoom(zoom + (0.125 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.125), event.position)
	if event is InputEventMouseMotion and dragging:
		camera -= event.relative / (TILE_PIXELS * zoom)
		refresh()

func _draw() -> void:
	if assets == null or not assets.errors.is_empty():
		return
	_draw_ground()
	if visible_layers.ore:
		_draw_ore()
	if show_grid:
		_draw_grid()
	# Every shadow is below every body. Each independent layer keeps its offset.
	for index in 3:
		if visible_layers.shadow and index != 2:
			_draw_layer(self, "shadow", index)
	for index in 3:
		if visible_layers.base:
			_draw_layer(self, "base", index)
		if visible_layers.mask:
			_draw_layer(self, "mask", index)

func _draw_ground() -> void:
	var texture: Texture2D = assets.texture("ground")
	var span := float(assets.manifest.ground.span_tiles)
	var minimum := world_at(Vector2.ZERO) / span
	var maximum := world_at(size) / span
	for y in range(floori(minimum.y), ceili(maximum.y)):
		for x in range(floori(minimum.x), ceili(maximum.x)):
			var rect := Rect2(point(Vector2(x, y) * span), Vector2.ONE * span * TILE_PIXELS * zoom)
			var flip := Vector2(-1 if posmod(x, 2) else 1, -1 if posmod(y, 2) else 1)
			var offset := rect.position + Vector2(rect.size.x if flip.x < 0 else 0, rect.size.y if flip.y < 0 else 0)
			draw_set_transform(offset, 0, flip)
			draw_texture_rect(texture, Rect2(Vector2.ZERO, rect.size), false, Color(0.4, 0.43, 0.45) * Color(daylight, daylight, daylight, 1))
			draw_set_transform(Vector2.ZERO)

func _draw_ore() -> void:
	# A visual scatter of the selected item render, not a simulated mine deposit.
	var texture: Texture2D = assets.texture("ore")
	for y in range(-3, 4):
		for x in range(-4, 5):
			if pow(float(x) / 4.3, 2) + pow(float(y) / 3.3, 2) > 1.0:
				continue
			var variation := posmod(x * 31 + y * 17, 7)
			var world := Vector2(7, 0.3) + Vector2(x, y) * 0.78 + Vector2(variation * 0.037, variation * 0.023)
			var width := TILE_PIXELS * zoom * (0.65 + variation * 0.035)
			var rect := Rect2(point(world) - Vector2.ONE * width * 0.5, Vector2.ONE * width)
			draw_texture_rect(texture, rect, false, Color(daylight, daylight, daylight, 0.9))

func _draw_grid() -> void:
	var minimum := world_at(Vector2.ZERO)
	var maximum := world_at(size)
	for x in range(floori(minimum.x), ceili(maximum.x)):
		draw_line(point(Vector2(x, minimum.y)), point(Vector2(x, maximum.y)), Color(0.83, 0.9, 0.86, 0.1), 1.0)
	for y in range(floori(minimum.y), ceili(maximum.y)):
		draw_line(point(Vector2(minimum.x, y)), point(Vector2(maximum.x, y)), Color(0.83, 0.9, 0.86, 0.1), 1.0)

func _draw_layer(target: CanvasItem, id: String, index: int) -> void:
	var active := index == 0 and running
	var rect: Rect2 = assets.layer_rect(id, point(CENTERS[index]), TILE_PIXELS * zoom)
	var color := Color(daylight, daylight, daylight, 1)
	if id == "shadow":
		color = Color(1, 1, 1, 0.4)
	if id == "mask":
		color *= tint
	if id == "emission":
		color = Color(1, 0.85, 0.65, 0.8)
	if index == 2:
		color = Color(0.48, 1.0, 0.8, 0.55) if id == "base" else Color(0.3, 1, 0.7, 0.3)
	var time := elapsed if index == 0 else 0.0
	target.draw_texture_rect(assets.texture(id, time, active), rect, false, color)

func _draw_emission() -> void:
	if assets != null and assets.errors.is_empty() and visible_layers.emission and running:
		_draw_layer(emission_pass, "emission", 0)

func _draw_smoke() -> void:
	if assets == null or not assets.errors.is_empty():
		return
	if visible_layers.smoke and running:
		var definition: Dictionary = assets.manifest.smoke
		var smoke_size := Vector2(float(definition.frame_size[0]), float(definition.frame_size[1]))
		var width := TILE_PIXELS * zoom * 2.8
		var rect := Rect2(point(CENTERS[0] + Vector2(-0.15, -2.15)) - Vector2(width * 0.5, width * 0.75), smoke_size * width / smoke_size.x)
		smoke_pass.draw_texture_rect(assets.texture("smoke", elapsed), rect, false, Color(0.8, 0.84, 0.86, 0.48))

func _draw_overlay() -> void:
	if assets == null or not assets.errors.is_empty():
		return
	var font := ThemeDB.fallback_font
	for index in 3:
		var color := Color("6bd8b0") if index != 1 else Color("a5acae")
		var rect := Rect2(point(CENTERS[index] - Vector2(2, 2)), Vector2.ONE * 4 * TILE_PIXELS * zoom)
		if show_anchors or index == 2:
			overlay_pass.draw_rect(rect, Color(0.04, 0.07, 0.07, 0.9), false, 4)
			overlay_pass.draw_rect(rect, color, false, 1.5)
		if show_anchors:
			var anchor := point(CENTERS[index])
			overlay_pass.draw_line(anchor - Vector2(10, 0), anchor + Vector2(10, 0), Color("ffc876"), 2)
			overlay_pass.draw_line(anchor - Vector2(0, 10), anchor + Vector2(0, 10), Color("ffc876"), 2)
			var base_rect: Rect2 = assets.layer_rect("base", anchor, TILE_PIXELS * zoom)
			overlay_pass.draw_rect(base_rect, Color(0.6, 0.8, 1, 0.5), false, 1)
		var labels := ["01  运行样本" if running else "01  停机样本", "02  停机对照", "03  矿区放置预览"]
		var text_position := point(CENTERS[index] + Vector2(0, 2.65))
		var text_size := font.get_string_size(labels[index], HORIZONTAL_ALIGNMENT_LEFT, -1, 19)
		var label_rect := Rect2(text_position - Vector2(text_size.x * 0.5 + 12, 23), Vector2(text_size.x + 24, 34))
		overlay_pass.draw_rect(label_rect, Color(0.035, 0.045, 0.05, 0.9))
		overlay_pass.draw_string(font, text_position - Vector2(text_size.x * 0.5, 0), labels[index], HORIZONTAL_ALIGNMENT_LEFT, -1, 19, color)
