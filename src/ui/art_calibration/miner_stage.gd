class_name HelixMinerStage
extends Control

## A presentation-only review stage for the original 3D-baked miner clips.
## It uses the manifest's real bake frames and retains one world camera without
## compensating for the application's canvas-items window scale.

signal view_changed
signal state_changed(mode: String, running: bool)

const STARTUP := "STARTUP"
const WORKING := "WORKING"
const SHUTDOWN := "SHUTDOWN"
const STOPPED := "STOPPED"
const TILE_PIXELS := 56.0

var assets: RefCounted
var playing := true
var running := false
var elapsed := 0.0
var zoom := 1.15
var camera := Vector2.ZERO
var visible_layers := {"base":true, "shadow":true, "mask":true, "emission":true, "smoke":true, "ore":true, "ground":true}
var show_anchors := false
var show_grid := false
var tint := Color("d4a65a")
var daylight := 1.0
var mode := STOPPED

var _transition_elapsed := 0.0
var _working_elapsed := 0.0
var _shutdown_after_cycle := -1
var _stopped_after_shutdown := false
var _dragging := false
var _emission_pass: Control
var _smoke_pass: Control
var _overlay_pass: Control


func _ready() -> void:
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	_emission_pass = Control.new()
	_emission_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_emission_pass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_emission_pass.material = additive
	add_child(_emission_pass)
	_emission_pass.draw.connect(_draw_emission)
	_smoke_pass = Control.new()
	_smoke_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_smoke_pass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var smoke_material := ShaderMaterial.new()
	smoke_material.shader = preload("res://src/ui/art_calibration/smoke.gdshader")
	_smoke_pass.material = smoke_material
	add_child(_smoke_pass)
	_smoke_pass.draw.connect(_draw_smoke_pass)
	_overlay_pass = Control.new()
	_overlay_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_pass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay_pass)
	_overlay_pass.draw.connect(_draw_overlay)
	gui_input.connect(_on_input)


func _process(delta: float) -> void:
	if not playing:
		return
	var step := minf(delta, 0.1)
	elapsed += step
	match mode:
		STARTUP:
			_transition_elapsed += step
			if _transition_elapsed >= _clip_duration(STARTUP):
				if running:
					mode = WORKING
					_working_elapsed = 0.0
				else:
					_begin_shutdown()
				state_changed.emit(mode, running)
		WORKING:
			_working_elapsed += step
			if not running and _shutdown_after_cycle >= 0 and _working_elapsed >= float(_shutdown_after_cycle) * _clip_duration(WORKING):
				_begin_shutdown()
				state_changed.emit(mode, running)
		SHUTDOWN:
			_transition_elapsed += step
			if _transition_elapsed >= _clip_duration(SHUTDOWN):
				mode = STOPPED
				_stopped_after_shutdown = true
				if running:
					_begin_startup()
				state_changed.emit(mode, running)
		STOPPED:
			if running:
				_begin_startup()
	refresh()


func request_running(value: bool) -> void:
	running = value
	if running and mode == STOPPED:
		_begin_startup()
	elif mode == WORKING:
		if running:
			_shutdown_after_cycle = -1
		else:
			# Shutdown frame 0 matches the first working frame, so wait for this
			# 60-frame loop to wrap rather than cutting from an arbitrary baked pose.
			_shutdown_after_cycle = floori(_working_elapsed / _clip_duration(WORKING)) + 1
	# An interrupted transition is never rewound. It reaches a baked endpoint,
	# then observes this most recent request, so the 3D pose cannot jump.
	state_changed.emit(mode, running)
	refresh()


func seek_frame(frame: int) -> void:
	playing = false
	if mode == STARTUP or mode == SHUTDOWN:
		_transition_elapsed = float(clampi(frame, 0, current_frame_count() - 1)) / maxf(1.0, current_fps())
	else:
		mode = WORKING
		running = true
		_working_elapsed = float(clampi(frame, 0, current_frame_count() - 1)) / maxf(1.0, current_fps())
		_shutdown_after_cycle = -1
	state_changed.emit(mode, running)
	refresh()


func reset_view() -> void:
	zoom = 1.15
	camera = Vector2.ZERO
	refresh()
	view_changed.emit()


func refresh() -> void:
	queue_redraw()
	if _emission_pass != null:
		_emission_pass.queue_redraw()
	if _smoke_pass != null:
		_smoke_pass.queue_redraw()
	if _overlay_pass != null:
		_overlay_pass.queue_redraw()


func point(world: Vector2) -> Vector2:
	return size * Vector2(0.5, 0.50) + (world - camera) * TILE_PIXELS * zoom


func world_at(screen: Vector2) -> Vector2:
	return (screen - size * Vector2(0.5, 0.50)) / maxf(0.0001, TILE_PIXELS * zoom) + camera


func set_zoom(value: float, anchor: Vector2 = size * 0.5) -> void:
	var before := world_at(anchor)
	zoom = clampf(value, 0.50, 2.10)
	camera += before - world_at(anchor)
	refresh()
	view_changed.emit()


func current_clip() -> String:
	if mode == STOPPED:
		return SHUTDOWN.to_lower() if _stopped_after_shutdown else STARTUP.to_lower()
	return mode.to_lower()


func current_frame_count() -> int:
	if assets == null:
		return 1
	return maxi(1, int(assets.call("frame_count", current_clip())))


func current_fps() -> float:
	if assets == null:
		return 30.0
	return maxf(1.0, float(assets.call("fps", current_clip())))


func current_frame() -> int:
	if mode == STOPPED:
		return current_frame_count() - 1 if _stopped_after_shutdown else 0
	var time := _transition_elapsed if mode in [STARTUP, SHUTDOWN] else _working_elapsed
	var loop := mode == WORKING
	return int(assets.call("frame_index", current_clip(), time, true, loop)) if assets != null else 0


func _begin_startup() -> void:
	mode = STARTUP
	_transition_elapsed = 0.0
	_working_elapsed = 0.0
	_shutdown_after_cycle = -1
	_stopped_after_shutdown = false


func _begin_shutdown() -> void:
	mode = SHUTDOWN
	_transition_elapsed = 0.0
	_shutdown_after_cycle = -1


func _clip_duration(clip_mode: String) -> float:
	if assets == null:
		return 0.0
	var count := maxi(1, int(assets.call("frame_count", clip_mode.to_lower())))
	return float(count) / maxf(1.0, float(assets.call("fps", clip_mode.to_lower())))


func _on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			_dragging = mouse.pressed
		if mouse.pressed and mouse.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			set_zoom(zoom + (0.125 if mouse.button_index == MOUSE_BUTTON_WHEEL_UP else -0.125), mouse.position)
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		camera -= motion.relative / maxf(0.0001, TILE_PIXELS * zoom)
		refresh()
		view_changed.emit()


func _draw() -> void:
	if assets == null or not (assets.get("errors") as Array).is_empty():
		return
	if bool(visible_layers.get("ground", true)):
		_draw_ground()
	if bool(visible_layers.get("ore", true)):
		_draw_ore()
	if show_grid:
		_draw_grid()
	if bool(visible_layers.get("shadow", true)):
		_draw_static_layer(self, "shadow", Color(1, 1, 1, 0.48))
	if bool(visible_layers.get("base", true)):
		_draw_base()
	if bool(visible_layers.get("mask", true)):
		_draw_static_layer(self, "mask", tint * Color(daylight, daylight, daylight, 0.72))


func _draw_ground() -> void:
	var texture: Texture2D = assets.call("texture", "ground") as Texture2D
	if texture == null:
		return
	var ground: Dictionary = (assets.get("manifest") as Dictionary).get("ground", {}) as Dictionary
	var span := maxf(1.0, float(ground.get("span_tiles", 8.0)))
	var minimum := world_at(Vector2.ZERO) / span
	var maximum := world_at(size) / span
	for y in range(floori(minimum.y), ceili(maximum.y)):
		for x in range(floori(minimum.x), ceili(maximum.x)):
			var rect := Rect2(point(Vector2(x, y) * span), Vector2.ONE * span * TILE_PIXELS * zoom)
			var flip := Vector2(-1 if posmod(x, 2) else 1, -1 if posmod(y, 2) else 1)
			var offset := rect.position + Vector2(rect.size.x if flip.x < 0 else 0, rect.size.y if flip.y < 0 else 0)
			draw_set_transform(offset, 0.0, flip)
			draw_texture_rect(texture, Rect2(Vector2.ZERO, rect.size), false, Color(0.48, 0.44, 0.38) * Color(daylight, daylight, daylight, 1.0))
			draw_set_transform(Vector2.ZERO)


func _draw_ore() -> void:
	var texture: Texture2D = assets.call("texture", "ore") as Texture2D
	if texture == null:
		return
	for y in range(-3, 4):
		for x in range(1, 8):
			if pow(float(x - 4) / 3.6, 2) + pow(float(y) / 2.8, 2) > 1.0:
				continue
			var variation := posmod(x * 19 + y * 37, 6)
			var world := Vector2(3.2, 1.15) + Vector2(x - 4, y) * 0.67 + Vector2(variation * 0.03, variation * 0.02)
			var edge := TILE_PIXELS * zoom * (0.64 + variation * 0.04)
			draw_texture_rect(texture, Rect2(point(world) - Vector2.ONE * edge * 0.5, Vector2.ONE * edge), false, Color(daylight, daylight, daylight, 0.90))


func _draw_grid() -> void:
	var minimum := world_at(Vector2.ZERO)
	var maximum := world_at(size)
	for x in range(floori(minimum.x), ceili(maximum.x) + 1):
		draw_line(point(Vector2(x, minimum.y)), point(Vector2(x, maximum.y)), Color(0.87, 0.92, 0.85, 0.11), 1.0)
	for y in range(floori(minimum.y), ceili(maximum.y) + 1):
		draw_line(point(Vector2(minimum.x, y)), point(Vector2(maximum.x, y)), Color(0.87, 0.92, 0.85, 0.11), 1.0)


func _draw_base() -> void:
	var texture: Texture2D = assets.call("frame_texture", current_clip(), current_frame()) as Texture2D
	if texture == null:
		return
	var rect: Rect2 = assets.call("layer_rect", "base", point(Vector2.ZERO), TILE_PIXELS * zoom) as Rect2
	draw_texture_rect(texture, rect, false, Color(daylight, daylight, daylight, 1.0))


func _draw_static_layer(target: CanvasItem, id: String, color: Color) -> void:
	var texture: Texture2D = assets.call("texture", id) as Texture2D
	if texture == null:
		return
	var rect: Rect2 = assets.call("layer_rect", id, point(Vector2.ZERO), TILE_PIXELS * zoom) as Rect2
	target.draw_texture_rect(texture, rect, false, color)


func _draw_emission() -> void:
	if assets == null or mode == STOPPED or not bool(visible_layers.get("emission", true)):
		return
	_draw_static_layer(_emission_pass, "emission", Color(1.0, 0.78, 0.35, 0.92))


func _draw_smoke_pass() -> void:
	if assets == null or mode == STOPPED or not bool(visible_layers.get("smoke", true)):
		return
	var texture: Texture2D = assets.call("texture", "smoke", elapsed, true) as Texture2D
	if texture == null:
		return
	var edge := TILE_PIXELS * zoom * 2.3
	var rect := Rect2(point(Vector2(-0.15, -2.2)) - Vector2(edge * 0.5, edge * 0.75), Vector2(edge, edge))
	_smoke_pass.draw_texture_rect(texture, rect, false, Color(0.84, 0.88, 0.94, 0.42))


func _draw_overlay() -> void:
	if assets == null:
		return
	var footprint := _footprint_rect()
	if show_anchors:
		_overlay_pass.draw_rect(footprint, Color("f5c877"), false, 1.5)
		var anchor := point(Vector2.ZERO)
		_overlay_pass.draw_line(anchor - Vector2(13, 0), anchor + Vector2(13, 0), Color("f5c877"), 2.0)
		_overlay_pass.draw_line(anchor - Vector2(0, 13), anchor + Vector2(0, 13), Color("f5c877"), 2.0)
		var base_rect: Rect2 = assets.call("layer_rect", "base", anchor, TILE_PIXELS * zoom) as Rect2
		_overlay_pass.draw_rect(base_rect, Color(0.5, 0.8, 1.0, 0.48), false, 1.0)
	var font := ThemeDB.fallback_font
	var label := "%s  ·  %02d / %02d" % [mode, current_frame(), current_frame_count() - 1]
	var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
	var label_rect := Rect2(Vector2(18, 18), Vector2(label_size.x + 22, 30))
	_overlay_pass.draw_rect(label_rect, Color(0.025, 0.045, 0.055, 0.88), true)
	_overlay_pass.draw_string(font, label_rect.position + Vector2(11, 21), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("d8e6db"))


func _footprint_rect() -> Rect2:
	var building: Dictionary = assets.call("building_definition") as Dictionary
	var extent_value: Variant = building.get("footprint_tiles", [4, 4])
	var extent := Vector2(4, 4)
	if extent_value is Array and (extent_value as Array).size() >= 2:
		var values := extent_value as Array
		extent = Vector2(float(values[0]), float(values[1]))
	return Rect2(point(-extent * 0.5), extent * TILE_PIXELS * zoom)
