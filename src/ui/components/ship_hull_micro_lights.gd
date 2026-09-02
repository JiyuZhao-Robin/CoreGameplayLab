class_name ShipHullMicroLights
extends Control

## Passive, event-driven traveling highlights for authored hull structure.
## Paths are normalized presentation data. This node never owns gameplay state.

class HullMicroLight:
	extends Control

	var _path := PackedVector2Array()
	var _cumulative := PackedFloat32Array()
	var _path_length := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		custom_minimum_size = Vector2(22.0, 22.0)
		size = custom_minimum_size
		pivot_offset = size * 0.5
		visible = false

	func set_tone(tone: Color) -> void:
		self_modulate = Color(tone, 1.0)
		queue_redraw()

	func begin(path: PackedVector2Array, drawing_size: Vector2) -> void:
		_path.clear()
		_cumulative.clear()
		_path_length = 0.0
		for normalized_point in path:
			var local_point := Vector2(normalized_point.x * drawing_size.x, normalized_point.y * drawing_size.y)
			if not _path.is_empty():
				_path_length += local_point.distance_to(_path[-1])
			_path.append(local_point)
			_cumulative.append(_path_length)
		visible = _path.size() >= 2 and _path_length > 0.1
		set_progress(0.0)

	func set_progress(progress: float) -> void:
		if _path.size() < 2 or _path_length <= 0.1:
			return
		var eased_progress := clampf(progress, 0.0, 1.0)
		var target_distance := eased_progress * _path_length
		var segment := 1
		while segment < _cumulative.size() - 1 and _cumulative[segment] < target_distance:
			segment += 1
		var segment_start := float(_cumulative[segment - 1])
		var segment_length := maxf(float(_cumulative[segment]) - segment_start, 0.001)
		var segment_progress := clampf((target_distance - segment_start) / segment_length, 0.0, 1.0)
		var start := _path[segment - 1]
		var finish := _path[segment]
		var tangent := (finish - start).normalized()
		position = start.lerp(finish, segment_progress) - size * 0.5
		rotation = tangent.angle()
		var envelope := smoothstep(0.0, 0.16, eased_progress) * (1.0 - smoothstep(0.72, 1.0, eased_progress))
		# A second, low-amplitude term keeps the point from reading as a perfectly
		# constant UI cursor while the Tween remains responsible for movement.
		modulate.a = envelope * (0.88 + sin(eased_progress * 17.0 + segment * 1.7) * 0.08)

	func _draw() -> void:
		var center := size * 0.5
		# A short directional wake keeps the event attached to a conduit rather
		# than reading as a free-floating particle.
		draw_circle(center - Vector2(6.0, 0.0), 4.8, Color(1.0, 1.0, 1.0, 0.040))
		draw_circle(center - Vector2(3.0, 0.0), 4.2, Color(1.0, 1.0, 1.0, 0.085))
		draw_circle(center, 7.0, Color(1.0, 1.0, 1.0, 0.060))
		draw_circle(center, 3.5, Color(1.0, 1.0, 1.0, 0.18))
		draw_circle(center, 1.65, Color(0.86, 1.0, 1.0, 0.76))
		draw_circle(center, 0.65, Color(0.94, 1.0, 1.0, 0.92))


const MIN_EVENT_DELAY := 3.0
const MAX_EVENT_DELAY := 8.0
const MIN_EVENT_DURATION := 1.35
const MAX_EVENT_DURATION := 2.45
const FAR_LOD_CUTOFF := 0.30

var _paths: Array[PackedVector2Array] = []
var _points: Array[HullMicroLight] = []
var _active_tweens: Dictionary = {}
var _event_timer: Timer
var _rng := RandomNumberGenerator.new()
var _lod_amount := 1.0
var _zoom_level := 1.0
var _tone := Color("62c8cc")
var _events_started := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false
	set_process(false)
	_ensure_runtime_nodes()
	_schedule_next_event(true)


func configure(path_data: Variant, tone: Color, stable_seed: String) -> void:
	_tone = tone
	_paths = _parse_paths(path_data)
	_rng.seed = hash(stable_seed)
	_ensure_runtime_nodes()
	for point in _points:
		point.set_tone(_tone)
	_schedule_next_event(true)


func set_presentation_state(zoom_level: float, lod_amount: float) -> void:
	_zoom_level = zoom_level
	_lod_amount = lod_amount
	visible = _lod_amount >= FAR_LOD_CUTOFF
	if not visible:
		_stop_active_events()
	elif is_instance_valid(_event_timer) and _event_timer.is_stopped():
		_schedule_next_event(false)


func events_started() -> int:
	return _events_started


func active_light_count() -> int:
	var count := 0
	for point in _points:
		if point.visible:
			count += 1
	return count


func force_event_for_test(path_index: int = 0) -> void:
	_start_event(path_index)


func _ensure_runtime_nodes() -> void:
	if not is_instance_valid(_event_timer):
		_event_timer = Timer.new()
		_event_timer.name = "AmbientEventTimer"
		_event_timer.one_shot = true
		_event_timer.timeout.connect(_on_event_timer_timeout)
		add_child(_event_timer)
	while _points.size() < 2:
		var point := HullMicroLight.new()
		point.name = "TravelingHighlight%d" % (_points.size() + 1)
		point.set_tone(_tone)
		add_child(point)
		_points.append(point)


func _parse_paths(path_data: Variant) -> Array[PackedVector2Array]:
	var parsed: Array[PackedVector2Array] = []
	if not path_data is Array:
		return parsed
	for path_value in path_data:
		if not path_value is Array:
			continue
		var path := PackedVector2Array()
		for point_value in path_value:
			if point_value is Array and point_value.size() >= 2:
				path.append(Vector2(
					clampf(float(point_value[0]), 0.0, 1.0),
					clampf(float(point_value[1]), 0.0, 1.0)
				))
		if path.size() >= 2:
			parsed.append(path)
	return parsed


func _on_event_timer_timeout() -> void:
	if visible and _lod_amount >= FAR_LOD_CUTOFF and not _paths.is_empty():
		_start_event(_rng.randi_range(0, _paths.size() - 1))
	_schedule_next_event(false)


func _start_event(path_index: int) -> void:
	if _paths.is_empty() or not visible or _lod_amount < FAR_LOD_CUTOFF:
		return
	var point := _available_point()
	if point == null:
		return
	var selected_path := _paths[clampi(path_index, 0, _paths.size() - 1)]
	point.begin(selected_path, size)
	if not point.visible:
		return
	_events_started += 1
	var duration := _rng.randf_range(MIN_EVENT_DURATION, MAX_EVENT_DURATION)
	# At close zoom an occasional second point may coexist; normal zoom remains
	# one sparse event for the entire hull.
	var tween := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_active_tweens[point] = tween
	tween.tween_method(point.set_progress, 0.0, 1.0, duration)
	tween.tween_callback(_finish_point.bind(point))


func _available_point() -> HullMicroLight:
	for point in _points:
		if not point.visible:
			return point
	return null


func _finish_point(point: HullMicroLight) -> void:
	point.visible = false
	_active_tweens.erase(point)


func _stop_active_events() -> void:
	for tween_value in _active_tweens.values():
		var tween := tween_value as Tween
		if tween != null and tween.is_valid():
			tween.kill()
	_active_tweens.clear()
	for point in _points:
		point.visible = false


func _schedule_next_event(initial: bool) -> void:
	if not is_inside_tree() or not is_instance_valid(_event_timer) or _paths.is_empty():
		return
	var delay := _rng.randf_range(2.4, 4.0) if initial else _rng.randf_range(MIN_EVENT_DELAY, MAX_EVENT_DELAY)
	_event_timer.start(delay)
