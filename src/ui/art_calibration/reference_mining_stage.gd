class_name ReferenceMiningStage
extends Control

## A self-contained camera and playback surface for one imported reference
## miner.  It deliberately has no Game commands or economy state.

signal view_changed
signal state_changed(running_state: bool)

const TILE_PIXELS := 54.0

var candidate_id := ""
var assets: RefCounted
var direction := ""
var playing := true
var running := true
var elapsed := 0.0
var zoom := 1.0
var camera := Vector2.ZERO
var visible_layers := {"base":true, "shadow":true, "emission":true, "ground":true, "ore":true}
var show_anchors := false

var _dragging := false
var _emission_pass: Control
var _overlay_pass: Control


func _ready() -> void:
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	if direction.is_empty() and assets != null:
		direction = str(assets.call("default_direction", candidate_id))
	zoom = float(assets.call("initial_zoom", candidate_id)) if assets != null else 1.0
	_emission_pass = Control.new()
	_emission_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_emission_pass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_emission_pass.material = additive
	add_child(_emission_pass)
	_emission_pass.draw.connect(_draw_emission)
	_overlay_pass = Control.new()
	_overlay_pass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_pass.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay_pass)
	_overlay_pass.draw.connect(_draw_overlay)
	gui_input.connect(_on_gui_input)
	refresh()


func _process(delta: float) -> void:
	if playing and running:
		elapsed += minf(delta, 0.1)
		refresh()


func request_running(value: bool) -> void:
	running = value
	state_changed.emit(running)
	refresh()


func set_direction(value: String) -> void:
	if assets == null:
		return
	var available: Array = assets.call("directions_for", candidate_id) as Array
	if value in available:
		direction = value
		refresh()


func seek_frame(frame: int) -> void:
	playing = false
	elapsed = float(clampi(frame, 0, current_frame_count() - 1)) / maxf(1.0, _animated_fps())
	refresh()


func set_zoom(value: float, anchor: Vector2 = size * 0.5) -> void:
	var before := world_at(anchor)
	zoom = clampf(value, 0.5, 2.0)
	camera += before - world_at(anchor)
	refresh()
	view_changed.emit()


func reset_view() -> void:
	zoom = float(assets.call("initial_zoom", candidate_id)) if assets != null else 1.0
	camera = Vector2.ZERO
	refresh()
	view_changed.emit()


func refresh() -> void:
	queue_redraw()
	if _emission_pass != null:
		_emission_pass.queue_redraw()
	if _overlay_pass != null:
		_overlay_pass.queue_redraw()


func current_frame() -> int:
	var count := current_frame_count()
	if count <= 1:
		return 0
	return posmod(floori(elapsed * _animated_fps() + 0.0001), count)


func current_frame_count() -> int:
	if assets == null:
		return 1
	var candidate: Dictionary = assets.call("candidate_definition", candidate_id) as Dictionary
	if candidate.has("frame_count"):
		return maxi(1, int(candidate.get("frame_count", 1)))
	return _base_frame_count()


func point(world: Vector2) -> Vector2:
	return size * Vector2(0.5, 0.51) + (world - camera) * TILE_PIXELS * zoom


func world_at(screen: Vector2) -> Vector2:
	return (screen - size * Vector2(0.5, 0.51)) / maxf(0.0001, TILE_PIXELS * zoom) + camera


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			_dragging = button.pressed
		if button.pressed and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			set_zoom(zoom + (0.125 if button.button_index == MOUSE_BUTTON_WHEEL_UP else -0.125), button.position)
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
	# The manifest determines the non-emission order.  Emission is deferred to
	# its additive CanvasItem so it cannot be accidentally alpha-composited.
	for layer in _layers():
		if str(layer.get("role", "base")) == "emission":
			continue
		if bool(layer.get("running_only", false)) and not running:
			continue
		if bool(visible_layers.get(str(layer.get("role", "base")), true)):
			_draw_layer(self, layer)


func _draw_ground() -> void:
	var texture: Texture2D = assets.call("texture", "ground") as Texture2D
	if texture == null:
		return
	var ground: Dictionary = (assets.get("manifest") as Dictionary).get("ground", {}) as Dictionary
	var span := maxf(1.0, float(ground.get("span_tiles", 8.0)))
	var minimum := world_at(Vector2.ZERO) / span
	var maximum := world_at(size) / span
	for y in range(floori(minimum.y), ceili(maximum.y) + 1):
		for x in range(floori(minimum.x), ceili(maximum.x) + 1):
			var rect := Rect2(point(Vector2(x, y) * span), Vector2.ONE * span * TILE_PIXELS * zoom)
			var flip := Vector2(-1 if posmod(x, 2) else 1, -1 if posmod(y, 2) else 1)
			var offset := rect.position + Vector2(rect.size.x if flip.x < 0 else 0.0, rect.size.y if flip.y < 0 else 0.0)
			draw_set_transform(offset, 0.0, flip)
			draw_texture_rect(texture, Rect2(Vector2.ZERO, rect.size), false, Color("7d8078"))
			draw_set_transform(Vector2.ZERO)


func _draw_ore() -> void:
	var texture: Texture2D = assets.call("texture", "ore") as Texture2D
	if texture == null:
		return
	for y in range(-3, 4):
		for x in range(1, 8):
			if pow(float(x - 4) / 3.6, 2) + pow(float(y) / 2.9, 2) > 1.0:
				continue
			var variation := posmod(x * 19 + y * 37, 6)
			var world := Vector2(3.15, 1.0) + Vector2(x - 4, y) * 0.68 + Vector2(variation * 0.035, variation * 0.02)
			var edge := TILE_PIXELS * zoom * (0.68 + variation * 0.04)
			draw_texture_rect(texture, Rect2(point(world) - Vector2.ONE * edge * 0.5, Vector2.ONE * edge), false, Color(1, 1, 1, 0.9))


func _draw_layer(target: CanvasItem, layer: Dictionary) -> void:
	var texture: Texture2D = assets.call("texture_frame", layer, elapsed) as Texture2D
	if texture == null:
		return
	var rect: Rect2 = assets.call("layer_rect", candidate_id, layer, point(Vector2.ZERO), TILE_PIXELS * zoom) as Rect2
	rect.position += _motion_offset(layer)
	var role := str(layer.get("role", "base"))
	var color := Color.WHITE
	var tint_value: Array = layer.get("tint", []) as Array
	if tint_value.size() >= 4:
		color *= Color(float(tint_value[0]), float(tint_value[1]), float(tint_value[2]), float(tint_value[3]))
	color.a *= clampf(float(layer.get("opacity", 1.0)), 0.0, 1.0)
	if role == "shadow":
		color.a *= 0.50
	target.draw_texture_rect(texture, rect, false, color)


func _draw_emission() -> void:
	if assets == null or not running or not bool(visible_layers.get("emission", true)):
		return
	for layer in _layers():
		if str(layer.get("role", "")) == "emission":
			_draw_layer(_emission_pass, layer)


func _draw_overlay() -> void:
	if assets == null or not show_anchors:
		return
	var candidate: Dictionary = assets.call("candidate_definition", candidate_id) as Dictionary
	var tiles_value: Array = candidate.get("footprint_tiles", [4, 4]) as Array
	var footprint := Vector2(float(tiles_value[0]), float(tiles_value[1]))
	var rect := Rect2(point(-footprint * 0.5), footprint * TILE_PIXELS * zoom)
	_overlay_pass.draw_rect(rect, Color("f3cf74"), false, 1.5)
	var anchor := point(Vector2.ZERO)
	_overlay_pass.draw_line(anchor - Vector2(13, 0), anchor + Vector2(13, 0), Color("f3cf74"), 2.0)
	_overlay_pass.draw_line(anchor - Vector2(0, 13), anchor + Vector2(0, 13), Color("f3cf74"), 2.0)
	for layer in _layers():
		if str(layer.get("role", "")) == "base":
			var layer_rect: Rect2 = assets.call("layer_rect", candidate_id, layer, anchor, TILE_PIXELS * zoom) as Rect2
			_overlay_pass.draw_rect(layer_rect, Color(0.48, 0.82, 1.0, 0.62), false, 1.0)
			break


func _layers() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if assets == null:
		return result
	var values: Array = assets.call("layers_for", candidate_id, direction) as Array
	for value in values:
		if value is Dictionary:
			result.append(value as Dictionary)
	return result


func _base_frame_count() -> int:
	if assets != null:
		var candidate: Dictionary = assets.call("candidate_definition", candidate_id) as Dictionary
		if candidate.has("frame_count"):
			return maxi(1, int(candidate.get("frame_count", 1)))
	for layer in _layers():
		if str(layer.get("role", "")) == "base":
			return maxi(1, int(layer.get("frame_count", 1)))
	return 1


func _animated_fps() -> float:
	if assets != null:
		var candidate: Dictionary = assets.call("candidate_definition", candidate_id) as Dictionary
		if candidate.has("fps"):
			return maxf(1.0, float(candidate.get("fps", 30.0)))
	for layer in _layers():
		if str(layer.get("role", "")) == "base":
			return maxf(1.0, float(layer.get("fps", 30.0)))
	return 30.0


func _motion_offset(layer: Dictionary) -> Vector2:
	var motion: Dictionary = layer.get("motion", {}) as Dictionary
	if motion.is_empty():
		return Vector2.ZERO
	var waypoints: Array = motion.get("waypoints", []) as Array
	if not waypoints.is_empty():
		var points: Array[Vector2] = []
		for point_value in waypoints:
			if point_value is Array and (point_value as Array).size() >= 2:
				var values: Array = point_value as Array
				points.append(Vector2(float(values[0]), float(values[1])))
		if not points.is_empty():
			var hold := maxf(0.0, float(motion.get("stop_duration_seconds", 0.0)))
			var transition := maxf(0.0, float(motion.get("transition_duration_seconds", 0.0)))
			var segment := hold + transition
			if segment <= 0.0:
				return points[0] * TILE_PIXELS * zoom
			var time := fposmod(elapsed, segment * points.size())
			var index := mini(points.size() - 1, floori(time / segment))
			var local_time := time - float(index) * segment
			var position := points[index]
			if transition > 0.0 and local_time > hold:
				position = position.lerp(points[posmod(index + 1, points.size())], clampf((local_time - hold) / transition, 0.0, 1.0))
			return position * TILE_PIXELS * zoom
	var axis_value: Array = motion.get("axis", [0, 0]) as Array
	if axis_value.size() < 2:
		return Vector2.ZERO
	var period := float(motion.get("period_seconds", 0.0))
	if period <= 0.0:
		return Vector2.ZERO
	var phase := float(motion.get("phase", 0.0))
	var distance := float(motion.get("amplitude_tiles", 0.0)) * sin(elapsed * TAU / period + phase)
	return Vector2(float(axis_value[0]), float(axis_value[1])) * distance * TILE_PIXELS * zoom
