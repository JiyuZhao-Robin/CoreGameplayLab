extends RefCounted

## Earth v2 is an analytic landform model, not an erosion simulation. Broad
## drainage and mountain spines are authored functions of seeded coordinates;
## smooth noise shapes their banks, foothills and ecology. Every query has fixed
## cost and no mutable RNG or tile cache, including queries outside map bounds.
const MODULUS := 2_147_483_647


static func sample(world: Dictionary, tile: Vector2i, seed: int, scale: float) -> Dictionary:
	var bounds: Dictionary = world.get("bounds", {}) if world.get("bounds", {}) is Dictionary else {}
	var origin := _point(bounds.get("origin", {}), Vector2.ZERO)
	var size := _point(bounds.get("size", {}), Vector2(1024.0, 640.0))
	size = Vector2(maxf(size.x, 64.0), maxf(size.y, 64.0))
	var p := Vector2(tile) - origin
	var unit := scale / 48.0
	var phase := _value(seed, 11, 37) * TAU
	var shift := (_value(seed, 29, 71) - 0.5) * 0.08
	var coarse := _noise(seed + 83, p / (scale * 2.4))
	var detail := _noise(seed + 719, p / (scale * 0.23))
	var bank_detail := (detail - 0.5) * 3.0 * unit

	# A river described as x(y) is connected by construction: no disconnected
	# threshold-noise puddles. Its valley lowers the surrounding floodplain.
	var lake_y := size.y * (0.67 + shift * 0.6)
	var spring_y := size.y * (0.155 + shift * 0.4)
	var channel_y := clampf(p.y, spring_y, lake_y)
	var river_x := _river_x(channel_y, size, unit, phase, shift)
	var river_width := (5.2 + 1.4 * sin(p.y / (49.0 * unit) + phase)) * unit
	var river_distance := Vector2(p.x - river_x, p.y - channel_y).length() - river_width
	var lake_center := Vector2(_river_x(lake_y, size, unit, phase, shift), lake_y)
	var lake_radius := Vector2(size.x * 0.105, size.y * 0.135) * sqrt(unit)
	var lake_offset := p - lake_center
	var lake_warp := Vector2(lake_offset.x + sin(lake_offset.y / (38.0 * unit) + phase) * 9.0 * unit, lake_offset.y)
	var lake_distance := (Vector2(lake_warp.x / lake_radius.x, lake_warp.y / lake_radius.y).length() - 1.0) * minf(lake_radius.x, lake_radius.y) + bank_detail
	# A single connected sea enters at the eastern edge, with long bays and
	# modest shoreline detail instead of scattered, tile-sized water holes.
	var coast_x := size.x * (0.885 + shift) + sin(p.y / (119.0 * unit) + phase) * 30.0 * unit + sin(p.y / (43.0 * unit) - phase) * 9.0 * unit
	var coast_distance := coast_x - p.x + bank_detail
	var shore_distance := minf(river_distance, minf(lake_distance, coast_distance))
	var natural_weight := _clearing_weight(world.get("terrain_safe_rect", {}), Vector2(tile), seed, unit, origin)
	# Move the bank itself around protected land, so water depth reaches zero
	# continuously instead of cutting a deep-water mask at a clearing threshold.
	shore_distance = lerpf(28.0 * unit, shore_distance, natural_weight)
	var valley := 1.0 - smoothstep(8.0 * unit, 43.0 * unit, absf(p.x - river_x))

	# A curved spine and its diverging branch create long directional ranges.
	# Narrow ridges sit inside a much wider foothill envelope. Height variation
	# along the spine creates peaks without breaking the underlying mountain belt.
	var ridge_x := size.x * (0.405 + shift) + (p.y - size.y * 0.5) * 0.19 + sin(p.y / (106.0 * unit) + phase) * 31.0 * unit
	var branch_x := ridge_x + absf(p.y - size.y * 0.53) * 0.39 + 19.0 * unit
	var ridge_distance := minf(absf(p.x - ridge_x), absf(p.x - branch_x))
	var ridge_width := (17.0 + 5.0 * sin(p.y / (61.0 * unit) - phase)) * unit
	var ridge := exp(-pow(ridge_distance / ridge_width, 2.0))
	var foothills := exp(-pow(ridge_distance / (58.0 * unit), 2.0))
	var peaks := 0.91 + 0.09 * sin(p.y / (23.0 * unit) + phase)
	# Wide saddles keep construction routes through the range possible with
	# today's roads, which have neither tunnels nor terrain modification.
	var pass_a := exp(-pow((p.y - size.y * (0.30 + shift)) / (21.0 * unit), 4.0))
	var pass_b := exp(-pow((p.y - size.y * (0.77 - shift)) / (24.0 * unit), 4.0))
	var pass_weight := 1.0 - maxf(pass_a, pass_b) * 0.94
	var elevation := 0.35 + (coarse - 0.5) * 0.095 + (detail - 0.5) * 0.025
	elevation += foothills * 0.21 + ridge * peaks * 0.37 * pass_weight
	elevation -= valley * 0.065
	# Water and its immediate shore share one elevation contour; mountains
	# cannot accidentally tower out of a low river cell.
	var shore_blend := smoothstep(0.0, 18.0 * unit, maxf(shore_distance, 0.0))
	elevation = lerpf(0.285 + maxf(shore_distance, 0.0) * 0.0018 / unit, elevation, shore_blend)
	var depth := smoothstep(0.0, 27.0 * unit, -shore_distance)
	if shore_distance < 0.0:
		elevation = 0.285 - depth * 0.19

	var ecology := _noise(seed + 47_393, p / (scale * 1.35)) * 0.76 + _noise(seed + 104_729, p / (scale * 0.39)) * 0.24
	var riparian := 1.0 - smoothstep(4.0 * unit, 31.0 * unit, maxf(shore_distance, 0.0))
	var moisture := clampf(0.23 + ecology * 0.55 + riparian * 0.20 - ridge * 0.13, 0.0, 1.0)
	var forest_density := smoothstep(0.38, 0.70, ecology + riparian * 0.13)
	forest_density *= 1.0 - smoothstep(0.56, 0.77, elevation)
	# Give banks a broad grass/understorey transition; a four-tile density ramp
	# made diagonal shorelines jump from bare sand to nearly full trees in a tile.
	forest_density *= smoothstep(1.8 * unit, 14.0 * unit, shore_distance)
	var rock := smoothstep(0.46, 0.83, elevation)

	# A feathered, noisy clearing extends beyond the guaranteed rectangle.
	# Both heights and tree density approach the starter terrain continuously;
	# the exact rectangle never appears as a sudden visual cut through a forest.
	elevation = lerpf(0.38, elevation, natural_weight)
	forest_density *= natural_weight
	rock *= natural_weight
	var water := shore_distance < 0.0
	if not water:
		depth = 0.0
	var terrain := "PLAIN"
	if water:
		terrain = "WATER"
		forest_density = 0.0
		rock = 0.0
	elif elevation > 0.665:
		terrain = "MOUNTAIN"
	elif shore_distance >= 0.0 and shore_distance < 2.8 * unit and natural_weight > 0.985:
		terrain = "DESERT" # The existing semantic type supplies narrow sandy banks.
	elif forest_density > 0.42:
		terrain = "FOREST"
	return {"terrain":terrain, "elevation":clampf(elevation, 0.0, 1.0), "moisture":moisture, "forest_density":clampf(forest_density, 0.0, 1.0), "water_depth":clampf(depth, 0.0, 1.0), "rock":clampf(rock, 0.0, 1.0)}


static func _river_x(y: float, size: Vector2, unit: float, phase: float, shift: float) -> float:
	return size.x * (0.165 + shift * 0.4) + y * 0.11 + sin(y / (83.0 * unit) + phase) * 25.0 * unit + sin(y / (29.0 * unit) - phase) * 7.0 * unit


static func _clearing_weight(rect_value: Variant, p: Vector2, seed: int, unit: float, world_origin: Vector2) -> float:
	if rect_value is not Dictionary:
		return 1.0
	var rect := rect_value as Dictionary
	var size := _point(rect.get("size", {}), Vector2.ZERO)
	if size.x <= 0.0 or size.y <= 0.0:
		return 1.0
	var origin := _point(rect.get("origin", {}), Vector2.ZERO)
	var center := origin + (size - Vector2.ONE) * 0.5
	var half_size := (size - Vector2.ONE) * 0.5
	var outside := Vector2(maxf(absf(p.x - center.x) - half_size.x, 0.0), maxf(absf(p.y - center.y) - half_size.y, 0.0))
	var feather := (18.0 + 16.0 * _noise(seed + 881, (p - world_origin) / (29.0 * unit))) * unit
	return smoothstep(0.0, feather, outside.length())


static func _point(value: Variant, fallback: Vector2) -> Vector2:
	if value is not Dictionary:
		return fallback
	var data := value as Dictionary
	return Vector2(_number(data.get("x", fallback.x), fallback.x), _number(data.get("y", fallback.y), fallback.y))


static func _number(value: Variant, fallback: float) -> float:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return fallback
	var result := float(value)
	return result if is_finite(result) else fallback


static func _noise(seed: int, p: Vector2) -> float:
	var x := floori(p.x)
	var y := floori(p.y)
	var f := p - Vector2(x, y)
	f = f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	return lerpf(lerpf(_value(seed, x, y), _value(seed, x + 1, y), f.x), lerpf(_value(seed, x, y + 1), _value(seed, x + 1, y + 1), f.x), f.y)


static func _value(seed: int, x: int, y: int) -> float:
	var value := posmod(seed, MODULUS)
	value = posmod(value + posmod(x * 73_856_093, MODULUS) + posmod(y * 19_349_663, MODULUS), MODULUS)
	value = ((value ^ (value >> 16)) * 73_244_475) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 73_244_475) & 0x7fffffff
	return float((value ^ (value >> 16)) & 0x7fffffff) / float(MODULUS - 1)
