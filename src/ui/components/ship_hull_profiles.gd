class_name ShipHullProfiles
extends RefCounted

const WORLD_SCALE := 4.0
const REFERENCE_LENGTH_M := 42.0
const HULL_BOARD_PADDING := 12.0
const SLOT_DIAMETERS_M := {"S":5.0, "M":11.0, "L":22.0, "XL":44.0, "XXL":88.0}
const SIZE_TIERS := {"S":1, "M":2, "L":3, "XL":4, "XXL":5}

const PROFILE_HALVES := {
	"p01":[[0.0,-44.0],[3.0,-40.0],[5.0,-31.0],[5.0,-21.0],[9.0,-13.0],[7.0,-4.0],[8.0,8.0],[6.0,22.0],[5.0,34.0],[0.0,44.0]],
	"p04":[[0.0,-44.0],[6.0,-39.0],[9.0,-30.0],[18.0,-25.0],[21.0,-14.0],[18.0,-6.0],[24.0,2.0],[22.0,13.0],[16.0,18.0],[19.0,31.0],[10.0,38.0],[0.0,44.0]],
	"p10":[[0.0,-44.0],[7.0,-39.0],[12.0,-31.0],[19.0,-23.0],[25.0,-13.0],[22.0,-3.0],[17.0,3.0],[20.0,15.0],[17.0,28.0],[10.0,38.0],[0.0,44.0]],
	"p12":[[0.0,-44.0],[8.0,-40.0],[13.0,-32.0],[20.0,-27.0],[25.0,-17.0],[22.0,-8.0],[28.0,0.0],[26.0,12.0],[20.0,17.0],[22.0,28.0],[14.0,37.0],[0.0,44.0]],
	"p13":[[0.0,-44.0],[7.0,-39.0],[12.0,-31.0],[18.0,-22.0],[22.0,-12.0],[21.0,-1.0],[26.0,8.0],[22.0,18.0],[18.0,29.0],[10.0,39.0],[0.0,44.0]],
	"p14":[[0.0,-44.0],[4.0,-39.0],[7.0,-31.0],[9.0,-21.0],[16.0,-13.0],[14.0,-4.0],[10.0,4.0],[12.0,16.0],[15.0,28.0],[8.0,37.0],[0.0,44.0]],
	"p18":[[0.0,-44.0],[8.0,-40.0],[14.0,-33.0],[24.0,-27.0],[31.0,-17.0],[29.0,-6.0],[24.0,2.0],[30.0,11.0],[28.0,23.0],[20.0,32.0],[11.0,39.0],[0.0,44.0]],
	"p19":[[0.0,-44.0],[6.0,-40.0],[10.0,-33.0],[16.0,-26.0],[21.0,-17.0],[20.0,-7.0],[17.0,0.0],[21.0,10.0],[18.0,21.0],[14.0,31.0],[8.0,39.0],[0.0,44.0]],
	"p21":[[0.0,-44.0],[5.0,-40.0],[8.0,-32.0],[11.0,-23.0],[15.0,-14.0],[13.0,-4.0],[10.0,5.0],[14.0,16.0],[12.0,27.0],[8.0,37.0],[0.0,44.0]],
	"p24":[[0.0,-44.0],[5.0,-42.0],[8.0,-37.0],[12.0,-31.0],[15.0,-24.0],[21.0,-17.0],[25.0,-9.0],[23.0,-1.0],[28.0,7.0],[26.0,15.0],[21.0,21.0],[23.0,28.0],[17.0,34.0],[14.0,39.0],[7.0,42.0],[0.0,44.0]],
	"p26":[[0.0,-44.0],[8.0,-39.0],[15.0,-32.0],[23.0,-24.0],[30.0,-14.0],[29.0,-3.0],[25.0,7.0],[29.0,18.0],[23.0,28.0],[14.0,37.0],[0.0,44.0]],
	"p28":[[0.0,-44.0],[8.0,-41.0],[13.0,-36.0],[16.0,-29.0],[22.0,-22.0],[23.0,-13.0],[29.0,-7.0],[30.0,2.0],[27.0,10.0],[24.0,16.0],[26.0,24.0],[21.0,31.0],[16.0,37.0],[9.0,38.0],[6.0,43.0],[0.0,44.0]],
	"p29":[[0.0,-44.0],[10.0,-41.0],[18.0,-35.0],[25.0,-27.0],[29.0,-17.0],[29.0,-5.0],[27.0,7.0],[29.0,19.0],[24.0,30.0],[15.0,38.0],[0.0,44.0]]
}

const PROFILE_BAYS := {
	"p13":[{"x":0.0,"top":-9.0,"bottom":13.0,"width":10.0}],
	"p18":[{"x":15.0,"top":-15.0,"bottom":21.0,"width":9.0}],
	"p24":[{"x":14.0,"top":-18.0,"bottom":9.0,"width":7.0}],
	"p26":[{"x":0.0,"top":-17.0,"bottom":19.0,"width":14.0}],
	"p28":[{"x":15.0,"top":-24.0,"bottom":8.0,"width":9.0}],
	"p29":[{"x":14.0,"top":-20.0,"bottom":27.0,"width":10.0}]
}


static func visual_spec(hull: Dictionary) -> Dictionary:
	var raw := hull.get("hull_visual", {}) as Dictionary
	var profile_id := String(raw.get("profile", "p10"))
	if not PROFILE_HALVES.has(profile_id):
		profile_id = "p10"
	var allowed_sizes := hull.get("allowed_sizes", ["S"]) as Array
	var socket_size := String(raw.get("socket_size", allowed_sizes.back() if not allowed_sizes.is_empty() else "S"))
	if not SLOT_DIAMETERS_M.has(socket_size):
		socket_size = "S"
	return {
		"profile":profile_id,
		"half":PROFILE_HALVES[profile_id],
		"bays":PROFILE_BAYS.get(profile_id, []),
		"length_m":maxf(24.0, float(raw.get("length_m", 120.0))),
		"beam_m":maxf(8.0, float(raw.get("beam_m", 36.0))),
		"socket_size":socket_size,
		"tier":int(SIZE_TIERS.get(socket_size, 1))
	}


static func board_size(spec: Dictionary) -> Vector2:
	var hull_width := float(spec.get("beam_m", 36.0)) * WORLD_SCALE
	var hull_height := float(spec.get("length_m", 120.0)) * WORLD_SCALE
	return Vector2(hull_width, hull_height) + Vector2.ONE * HULL_BOARD_PADDING * 2.0


static func hull_rect(board: Vector2, spec: Dictionary) -> Rect2:
	var dimensions := Vector2(float(spec.get("beam_m", 36.0)), float(spec.get("length_m", 120.0))) * WORLD_SCALE
	return Rect2((board - dimensions) * 0.5, dimensions)


static func size_tier(size_id: String) -> int:
	return int(SIZE_TIERS.get(size_id, 1))


static func socket_diameter_m(size_id: String) -> float:
	return float(SLOT_DIAMETERS_M.get(size_id, 5.0))


static func socket_node_size(size_id: String) -> Vector2:
	var side := socket_diameter_m(size_id) * WORLD_SCALE + 14.0
	return Vector2(side, side)


static func outline_meters(spec: Dictionary) -> PackedVector2Array:
	var half := spec.get("half", []) as Array
	var beam := float(spec.get("beam_m", 36.0))
	var length := float(spec.get("length_m", 120.0))
	var maximum_half_width := _maximum_half_width(half)
	var result := PackedVector2Array()
	for value in half:
		var point := _array_point(value)
		result.append(Vector2(beam * 0.5 + point.x / maximum_half_width * beam * 0.5, (point.y + 44.0) / 88.0 * length))
	for index in range(half.size() - 2, 0, -1):
		var point := _array_point(half[index])
		result.append(Vector2(beam * 0.5 - point.x / maximum_half_width * beam * 0.5, (point.y + 44.0) / 88.0 * length))
	return result


static func layout_sockets(spec: Dictionary, socket_schema: Array) -> Dictionary:
	var polygon := outline_meters(spec)
	var beam := float(spec.get("beam_m", 36.0))
	var length := float(spec.get("length_m", 120.0))
	var candidates: Array[Dictionary] = []
	for y_index in 49:
		for x_index in 29:
			var point := Vector2(beam * float(x_index) / 28.0, length * float(y_index) / 48.0)
			if _point_inside(point, polygon):
				candidates.append({"point":point, "edge":_edge_distance(point, polygon)})
	var counts := {}
	for value in socket_schema:
		var socket := value as Dictionary
		var key := _zone_key(socket)
		counts[key] = int(counts.get(key, 0)) + 1
	var indices := {}
	var occupied: Array[Dictionary] = []
	var positions := {}
	var ordered := socket_schema.duplicate(true)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return size_tier(String(a.get("max_size", spec.get("socket_size", "S")))) > size_tier(String(b.get("max_size", spec.get("socket_size", "S"))))
	)
	for value in ordered:
		var socket := value as Dictionary
		var key := _zone_key(socket)
		var index := int(indices.get(key, 0))
		indices[key] = index + 1
		var target := _socket_target(key, index, int(counts.get(key, 1)), beam, length)
		var size_id := String(socket.get("max_size", spec.get("socket_size", "S")))
		var radius := socket_diameter_m(size_id) * 0.5
		var envelope := radius * 1.16 + 0.8
		var best := Vector2(-1.0, -1.0)
		var best_score := INF
		for candidate in candidates:
			if float(candidate.get("edge", 0.0)) < envelope:
				continue
			var point := candidate.get("point", Vector2.ZERO) as Vector2
			var collides := false
			for installed in occupied:
				if point.distance_to(installed.get("point", Vector2.ZERO) as Vector2) < envelope + float(installed.get("envelope", 0.0)) + 0.8:
					collides = true
					break
			if collides:
				continue
			var score := point.distance_to(target)
			if score < best_score:
				best = point
				best_score = score
		if best.x < 0.0:
			best = _fallback_point(candidates, occupied, target, envelope)
		positions[String(socket.get("id", ""))] = best
		occupied.append({"point":best, "envelope":envelope, "radius":radius})
	return positions


static func layout_violations(spec: Dictionary, socket_schema: Array, positions: Dictionary) -> Array[String]:
	var polygon := outline_meters(spec)
	var installed: Array[Dictionary] = []
	var violations: Array[String] = []
	for socket_value in socket_schema:
		var socket := socket_value as Dictionary
		var socket_id := String(socket.get("id", ""))
		if not positions.has(socket_id):
			violations.append(I18n.core("ships.shipyard.audit.missing_position", "%s has no position") % socket_id)
			continue
		var point := positions[socket_id] as Vector2
		var size_id := String(socket.get("max_size", spec.get("socket_size", "S")))
		var envelope := socket_diameter_m(size_id) * 0.5 * 1.16 + 0.8
		if not _point_inside(point, polygon):
			violations.append(I18n.core("ships.shipyard.audit.outside_hull", "%s is outside the hull") % socket_id)
		elif _edge_distance(point, polygon) + 0.01 < envelope:
			violations.append(I18n.core("ships.shipyard.audit.crosses_edge", "%s crosses the hull edge") % socket_id)
		for other in installed:
			var minimum_distance := envelope + float(other.get("envelope", 0.0)) + 0.8
			if point.distance_to(other.get("point", Vector2.ZERO) as Vector2) + 0.01 < minimum_distance:
				violations.append(I18n.core("ships.shipyard.audit.overlap", "%s overlaps %s") % [socket_id, String(other.get("id", ""))])
		installed.append({"id":socket_id, "point":point, "envelope":envelope})
	return violations


static func _socket_target(key: String, index: int, count: int, beam: float, length: float) -> Vector2:
	var pair_index := index / 2
	var side := -1.0 if index % 2 == 0 else 1.0
	if count == 1 and key in ["core", "drive"]:
		side = 0.0
	var x_spread := 0.22 + float(pair_index % 3) * 0.11
	match key:
		"weapon": return Vector2(beam * (0.5 + side * x_spread), length * (0.28 + float(pair_index) * 0.10))
		"shield": return Vector2(beam * (0.5 + side * (0.27 + float(pair_index) * 0.07)), length * (0.66 + float(pair_index) * 0.09))
		"drive": return Vector2(beam * (0.5 + side * (0.18 + float(pair_index) * 0.10)), length * (0.18 + float(pair_index) * 0.07))
		"utility_special":
			# The first utility plugin deliberately begins on starboard.  Plugin
			# placement is allowed to be asymmetric even though the hull never is.
			return Vector2(beam * (0.5 - side * x_spread), length * (0.36 + float(pair_index) * 0.13))
		"utility_structural": return Vector2(beam * (0.5 + side * x_spread), length * (0.76 - float(pair_index) * 0.09))
		_: return Vector2(beam * 0.5, length * (0.50 + float(index) * 0.07))


static func _zone_key(socket: Dictionary) -> String:
	var slot := String(socket.get("slot", "utility"))
	if slot == "utility":
		return "utility_structural" if String(socket.get("mount_role", "SPECIAL")) == "STRUCTURAL" else "utility_special"
	return slot


static func _fallback_point(candidates: Array[Dictionary], occupied: Array[Dictionary], target: Vector2, envelope: float) -> Vector2:
	var best := target
	var best_score := INF
	for candidate in candidates:
		var point := candidate.get("point", Vector2.ZERO) as Vector2
		var clearance := float(candidate.get("edge", 0.0))
		var separation := INF
		for installed in occupied:
			separation = minf(separation, point.distance_to(installed.get("point", Vector2.ZERO) as Vector2) - float(installed.get("envelope", 0.0)))
		var score := point.distance_to(target) + maxf(0.0, envelope - clearance) * 1000.0 + maxf(0.0, envelope - separation) * 1000.0
		if score < best_score:
			best = point
			best_score = score
	return best


static func _point_inside(point: Vector2, polygon: PackedVector2Array) -> bool:
	var inside := false
	var previous := polygon.size() - 1
	for index in polygon.size():
		var current_point := polygon[index]
		var previous_point := polygon[previous]
		if (current_point.y > point.y) != (previous_point.y > point.y) and point.x < (previous_point.x - current_point.x) * (point.y - current_point.y) / ((previous_point.y - current_point.y) if absf(previous_point.y - current_point.y) > 0.0001 else 0.0001) + current_point.x:
			inside = not inside
		previous = index
	return inside


static func _edge_distance(point: Vector2, polygon: PackedVector2Array) -> float:
	var result := INF
	for index in polygon.size():
		result = minf(result, _segment_distance(point, polygon[index], polygon[(index + 1) % polygon.size()]))
	return result


static func _segment_distance(point: Vector2, start: Vector2, finish: Vector2) -> float:
	var segment := finish - start
	var length_squared := segment.length_squared()
	if length_squared <= 0.0001:
		return point.distance_to(start)
	var progress := clampf((point - start).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_to(start + segment * progress)


static func _maximum_half_width(half: Array) -> float:
	var result := 1.0
	for value in half:
		result = maxf(result, _array_point(value).x)
	return result


static func _array_point(value: Variant) -> Vector2:
	var pair := value as Array
	return Vector2(float(pair[0]), float(pair[1]))
