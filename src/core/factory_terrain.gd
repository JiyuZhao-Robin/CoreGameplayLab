class_name FactoryTerrain
extends RefCounted

## Stateless, deterministic terrain and sparse resource-field geometry for a
## Factory world. The authoritative world stores only generator inputs and
## player-made deltas; this module never materializes a planet-sized tile map.
##
## Current runtime is flat. Saved terrain inputs still reproduce the historical
## resource-placement geography; they do not enable mountains, water or trees.

const PLAIN := "PLAIN"
const FOREST := "FOREST"
const DESERT := "DESERT"
const WATER := "WATER"
const MOUNTAIN := "MOUNTAIN"
const TERRAIN_TYPES := [PLAIN, FOREST, DESERT, WATER, MOUNTAIN]
const BLOCKED_TERRAIN := [WATER, MOUNTAIN]
const NOISE_MODULUS := 2_147_483_647
const SOLID_FIELD_CORE_RADIUS := 0.60
const EarthTerrain = preload("res://src/core/earth_terrain.gd")
## Current product scope: plain ground everywhere, retaining saved generation
## inputs and resource geography so this temporary policy never rewrites saves.
const FLAT_GROUND_ONLY := true


## Shared runtime classification for construction, inspection and rendering.
static func terrain_type(world: Dictionary, tile: Vector2i) -> String:
	if FLAT_GROUND_ONLY:
		return PLAIN
	return resource_geography_type(world, tile)


## Historical geography is used only to preserve resource placement and its RNG
## sequence. Rendering and construction must use terrain_type/surface_sample.
static func resource_geography_type(world: Dictionary, tile: Vector2i) -> String:
	var override := _terrain_override(world, tile)
	if not override.is_empty():
		return override
	if not bool(world.get("terrain_enabled", false)):
		return PLAIN
	if _rect_contains(world.get("terrain_safe_rect", {}), tile):
		return PLAIN
	if str(world.get("terrain_profile", "")) == "earth_v2":
		return str(EarthTerrain.sample(world, tile, _world_seed(world), _earth_scale(world))["terrain"])

	var seed := _world_seed(world)
	var scale := maxf(8.0, _finite_number(world.get("terrain_scale_tiles", 48.0), 48.0))
	var point := Vector2(tile.x, tile.y)
	var elevation := _fractal_value(seed, point, scale)
	var moisture := _fractal_value(seed + 47_393, point + Vector2(173.0, -271.0), scale * 0.82)

	# Broad elevation bands create connected water and mountains. Moisture then
	# separates the middle band into desert, forest and buildable plain.
	if elevation < 0.17:
		return WATER
	if elevation > 0.83:
		return MOUNTAIN
	if moisture < 0.31:
		return DESERT
	if moisture > 0.67:
		return FOREST
	return PLAIN


## Continuous runtime surface, flattened before historical overrides can apply.
static func surface_sample(world: Dictionary, tile: Vector2i) -> Dictionary:
	if FLAT_GROUND_ONLY:
		return _uniform_sample(PLAIN)
	var override := _terrain_override(world, tile)
	if not override.is_empty():
		return _uniform_sample(override)
	if not bool(world.get("terrain_enabled", false)):
		return _uniform_sample(PLAIN)
	if str(world.get("terrain_profile", "")) == "earth_v2":
		return EarthTerrain.sample(world, tile, _world_seed(world), _earth_scale(world))
	return _uniform_sample(terrain_type(world, tile))


static func _earth_scale(world: Dictionary) -> float:
	return clampf(_finite_number(world.get("terrain_scale_tiles", 48.0), 48.0), 8.0, 256.0)


static func _uniform_sample(terrain: String) -> Dictionary:
	return {
		"terrain":terrain,
		"elevation":0.16 if terrain == WATER else (0.86 if terrain == MOUNTAIN else 0.38),
		"moisture":0.95 if terrain == WATER else (0.78 if terrain == FOREST else (0.25 if terrain == DESERT else 0.5)),
		"forest_density":0.85 if terrain == FOREST else 0.0,
		"water_depth":0.7 if terrain == WATER else 0.0,
		"rock":0.9 if terrain == MOUNTAIN else 0.0,
	}


## Buildability is geographic only; entity, road and resource-placement rules
## remain in FactoryGridSimulation. An authored bounds record also rejects
## out-of-world queries so callers can use this safely during placement.
static func is_buildable(world: Dictionary, tile: Vector2i) -> bool:
	if not _tile_in_world(world, tile):
		return false
	return terrain_type(world, tile) not in BLOCKED_TERRAIN


## Tests whether one sparse field owns a tile. Legacy fields deliberately keep
## their complete rectangular footprint. New `IRREGULAR` fields use a jagged
## ellipse with a broad deterministic core and do not persist per-tile masks.
static func field_contains(field: Dictionary, tile: Vector2i) -> bool:
	var footprint_value: Variant = field.get("footprint", {})
	if footprint_value is not Dictionary:
		return false
	var footprint := footprint_value as Dictionary
	if not _rect_contains(footprint, tile):
		return false
	if str(field.get("shape", "RECTANGLE")).to_upper() != "IRREGULAR":
		return true

	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	if size.x < 3 or size.y < 3:
		# Tiny authored fields retain their usable footprint. A 3x3 miner cannot
		# fit here, so applying an irregular cutout would only make them worse.
		return true

	# The exact central 3x3 is always solid, allowing the standard starter miner
	# to be placed without relying on a lucky edge-noise sample.
	var core_origin := origin + Vector2i((size.x - 3) / 2, (size.y - 3) / 2)
	if tile.x >= core_origin.x and tile.x < core_origin.x + 3 and tile.y >= core_origin.y and tile.y < core_origin.y + 3:
		return true

	var center := Vector2(
		float(origin.x) + float(size.x - 1) * 0.5,
		float(origin.y) + float(size.y - 1) * 0.5
	)
	var radius_x := maxf(1.0, float(size.x - 1) * 0.5)
	var radius_y := maxf(1.0, float(size.y - 1) * 0.5)
	var local := Vector2((float(tile.x) - center.x) / radius_x, (float(tile.y) - center.y) / radius_y)
	var ellipse_radius := local.length()
	if ellipse_radius <= SOLID_FIELD_CORE_RADIUS:
		return true
	if ellipse_radius > 1.08:
		return false

	# Smooth local noise bends the outer ellipse without creating isolated single
	# tiles. The field seed lets two same-sized deposits look different while the
	# result stays independent of read order and viewport/chunk traversal.
	var field_seed := _field_seed(field, origin, size)
	var local_tile := tile - origin
	var edge_noise := _fractal_value(field_seed, Vector2(float(local_tile.x), float(local_tile.y)), 7.0)
	var edge_radius := 0.86 + (edge_noise - 0.5) * 0.22
	return ellipse_radius <= edge_radius


static func _terrain_override(world: Dictionary, tile: Vector2i) -> String:
	var deltas_value: Variant = world.get("tile_deltas", {})
	if deltas_value is not Dictionary:
		return ""
	var delta_value: Variant = (deltas_value as Dictionary).get(_tile_key(tile), {})
	if delta_value is not Dictionary:
		return ""
	var candidate := str((delta_value as Dictionary).get("terrain_override", "")).to_upper()
	return candidate if TERRAIN_TYPES.has(candidate) else ""


static func _world_seed(world: Dictionary) -> int:
	var seed := _integer(world.get("terrain_seed", world.get("seed", 1)), 1)
	return seed + _integer(world.get("generator_version", 1), 1) * 104_729


static func _field_seed(field: Dictionary, origin: Vector2i, size: Vector2i) -> int:
	if field.has("seed"):
		return _integer(field.get("seed", 1), 1)
	# The fallback intentionally derives only from persisted geometry. It avoids
	# non-deterministic runtime hashes while remaining distinct for valid,
	# non-overlapping fields.
	return origin.x * 73_856_093 + origin.y * 19_349_663 + size.x * 8_191 + size.y * 7_919


## Three octaves of interpolated value noise: cheap enough for per-visible-tile
## rendering, continuous between samples, and free of mutable RNG state.
static func _fractal_value(seed: int, point: Vector2, scale: float) -> float:
	var coarse := _smooth_value_noise(seed, point / scale)
	var medium := _smooth_value_noise(seed + 7_919, point / maxf(2.0, scale * 0.42))
	var detail := _smooth_value_noise(seed + 104_729, point / maxf(1.0, scale * 0.16))
	return clampf(coarse * 0.57 + medium * 0.30 + detail * 0.13, 0.0, 1.0)


static func _smooth_value_noise(seed: int, point: Vector2) -> float:
	var base_x := floori(point.x)
	var base_y := floori(point.y)
	var x_fraction := point.x - float(base_x)
	var y_fraction := point.y - float(base_y)
	var eased_x := x_fraction * x_fraction * (3.0 - 2.0 * x_fraction)
	var eased_y := y_fraction * y_fraction * (3.0 - 2.0 * y_fraction)
	var top := lerpf(_value_at(seed, base_x, base_y), _value_at(seed, base_x + 1, base_y), eased_x)
	var bottom := lerpf(_value_at(seed, base_x, base_y + 1), _value_at(seed, base_x + 1, base_y + 1), eased_x)
	return lerpf(top, bottom, eased_y)


static func _value_at(seed: int, x: int, y: int) -> float:
	return float(_coordinate_noise(seed, x, y)) / float(NOISE_MODULUS - 1)


static func _coordinate_noise(seed: int, x: int, y: int) -> int:
	var value := posmod(seed, NOISE_MODULUS)
	value = posmod(value + posmod(x * 73_856_093, NOISE_MODULUS) + posmod(y * 19_349_663, NOISE_MODULUS), NOISE_MODULUS)
	# Nonlinear avalanche avoids diagonal stripes from a linear congruence.
	value = ((value ^ (value >> 16)) * 73_244_475) & 0x7fffffff
	value = ((value ^ (value >> 13)) * 73_244_475) & 0x7fffffff
	return (value ^ (value >> 16)) & 0x7fffffff


static func _tile_in_world(world: Dictionary, tile: Vector2i) -> bool:
	var bounds_value: Variant = world.get("bounds", null)
	if bounds_value is not Dictionary:
		return true
	var bounds := bounds_value as Dictionary
	var size := _point(bounds.get("size", {}))
	if size.x <= 0 or size.y <= 0:
		return true
	var origin := _point(bounds.get("origin", {}))
	return tile.x >= origin.x and tile.y >= origin.y and tile.x < origin.x + size.x and tile.y < origin.y + size.y


static func _rect_contains(rect_value: Variant, tile: Vector2i) -> bool:
	if rect_value is not Dictionary:
		return false
	var rect := rect_value as Dictionary
	var origin := _point(rect.get("origin", {}))
	var size := _point(rect.get("size", {}))
	return size.x > 0 and size.y > 0 and tile.x >= origin.x and tile.y >= origin.y and tile.x < origin.x + size.x and tile.y < origin.y + size.y


static func _point(value: Variant) -> Vector2i:
	if value is not Dictionary:
		return Vector2i.ZERO
	var data := value as Dictionary
	return Vector2i(_integer(data.get("x", 0), 0), _integer(data.get("y", 0), 0))


static func _integer(value: Variant, fallback: int) -> int:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return fallback
	var numeric := float(value)
	return int(numeric) if is_finite(numeric) else fallback


static func _finite_number(value: Variant, fallback: float) -> float:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return fallback
	var numeric := float(value)
	return numeric if is_finite(numeric) else fallback


static func _tile_key(tile: Vector2i) -> String:
	return "%d:%d" % [tile.x, tile.y]
