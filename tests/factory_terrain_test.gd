extends SceneTree
const FactoryTerrain = preload("res://src/core/factory_terrain.gd")

## Focused pure contract for sparse procedural terrain and irregular fields.
## It intentionally does not instantiate FactoryGridSimulation: the primary
## agent owns that integration and runs this suite serially.

var failures: Array[String] = []


func _initialize() -> void:
	_test_determinism_and_seed_variation()
	_test_terrain_mix_and_safe_region()
	_test_delta_overrides_and_bounds()
	_test_irregular_field_geometry()
	_test_legacy_field_geometry()
	_test_chunk_independent_read_order()
	_finish()


func _test_determinism_and_seed_variation() -> void:
	var first := _world(7_302_01)
	var second := _world(7_302_01)
	var alternate := _world(7_302_02)
	var samples := [Vector2i(177, 121), Vector2i(224, 181), Vector2i(305, 79), Vector2i(411, 233), Vector2i(497, 347)]
	var changed := false
	for tile in samples:
		var original := FactoryTerrain.terrain_type(first, tile)
		_check(original == FactoryTerrain.terrain_type(second, tile), "same seed and tile always return the same terrain")
		changed = changed or original != FactoryTerrain.terrain_type(alternate, tile)
	_check(changed, "changing the terrain seed changes at least one sampled tile")


func _test_terrain_mix_and_safe_region() -> void:
	var world := _world(7_302_01)
	var seen := {}
	for y in range(112, 480, 8):
		for x in range(152, 704, 8):
			seen[FactoryTerrain.terrain_type(world, Vector2i(x, y))] = true
	_check(seen.has("WATER") and seen.has("MOUNTAIN") and seen.has("FOREST") and seen.has("DESERT") and seen.has("PLAIN"), "a sampled enabled world contains every authored terrain category")
	for tile in [Vector2i(0, 0), Vector2i(143, 95), Vector2i(72, 48)]:
		_check(FactoryTerrain.terrain_type(world, tile) == "PLAIN" and FactoryTerrain.is_buildable(world, tile), "starter safe rectangle is always plain and buildable at %s" % tile)


func _test_delta_overrides_and_bounds() -> void:
	var world := _world(31)
	world["tile_deltas"] = {
		"40:40":{"terrain_override":"WATER"},
		"41:40":{"terrain_override":"MOUNTAIN"},
		"42:40":{"terrain_override":"DESERT"},
		"43:40":{"terrain_override":"not-a-terrain"}
	}
	_check(FactoryTerrain.terrain_type(world, Vector2i(40, 40)) == "WATER" and not FactoryTerrain.is_buildable(world, Vector2i(40, 40)), "water delta overrides the generated safe terrain and blocks construction")
	_check(FactoryTerrain.terrain_type(world, Vector2i(41, 40)) == "MOUNTAIN" and not FactoryTerrain.is_buildable(world, Vector2i(41, 40)), "mountain delta overrides the generated safe terrain and blocks construction")
	_check(FactoryTerrain.terrain_type(world, Vector2i(42, 40)) == "DESERT" and FactoryTerrain.is_buildable(world, Vector2i(42, 40)), "valid buildable terrain delta wins over the safe terrain")
	_check(FactoryTerrain.terrain_type(world, Vector2i(43, 40)) == "PLAIN", "invalid terrain deltas do not invent a sixth terrain type")
	_check(not FactoryTerrain.is_buildable(world, Vector2i(-1, 0)) and not FactoryTerrain.is_buildable(world, Vector2i(768, 0)), "geographic buildability respects authored finite bounds")


func _test_irregular_field_geometry() -> void:
	var field := {
		"id":"irregular-iron", "shape":"IRREGULAR", "seed":912_451,
		"footprint":{"origin":{"x":200, "y":140}, "size":{"x":40, "y":30}}
	}
	_check(not FactoryTerrain.field_contains(field, Vector2i(199, 140)), "irregular fields reject a tile outside their authored footprint")
	_check(not FactoryTerrain.field_contains(field, Vector2i(200, 140)), "irregular field corners are cut away instead of exposing a full rectangle")
	var core_origin := Vector2i(200 + (40 - 3) / 2, 140 + (30 - 3) / 2)
	for y in range(core_origin.y, core_origin.y + 3):
		for x in range(core_origin.x, core_origin.x + 3):
			_check(FactoryTerrain.field_contains(field, Vector2i(x, y)), "the central 3x3 of an irregular field always accepts a starter miner")
	_check(FactoryTerrain.field_contains(field, Vector2i(232, 155)), "the broad irregular-field core remains useful beyond the exact central 3x3")


func _test_legacy_field_geometry() -> void:
	var legacy := {"id":"legacy-rectangle", "footprint":{"origin":{"x":10, "y":20}, "size":{"x":4, "y":3}}}
	_check(FactoryTerrain.field_contains(legacy, Vector2i(10, 20)) and FactoryTerrain.field_contains(legacy, Vector2i(13, 22)), "unmarked legacy resource fields remain complete rectangles")
	_check(not FactoryTerrain.field_contains(legacy, Vector2i(14, 22)), "legacy field geometry still excludes tiles outside its footprint")
	var disabled := {"terrain_enabled":false, "bounds":{"origin":{"x":0, "y":0}, "size":{"x":16, "y":16}}}
	_check(FactoryTerrain.terrain_type(disabled, Vector2i(8, 8)) == "PLAIN" and FactoryTerrain.is_buildable(disabled, Vector2i(8, 8)), "terrain-disabled legacy worlds preserve fully buildable plain behavior")


func _test_chunk_independent_read_order() -> void:
	var world := _world(842)
	var coordinates := [Vector2i(152, 104), Vector2i(227, 189), Vector2i(398, 214), Vector2i(575, 331), Vector2i(721, 447)]
	var forward := {}
	for tile in coordinates:
		forward[_tile_key(tile)] = FactoryTerrain.terrain_type(world, tile)
	var reverse := {}
	for index in range(coordinates.size() - 1, -1, -1):
		var tile: Vector2i = coordinates[index]
		reverse[_tile_key(tile)] = FactoryTerrain.terrain_type(world, tile)
	_check(forward == reverse, "terrain samples do not depend on viewport, chunk, or query order")


func _world(seed: int) -> Dictionary:
	return {
		"seed":seed,
		"generator_version":2,
		"terrain_enabled":true,
		"terrain_safe_rect":{"origin":{"x":0, "y":0}, "size":{"x":144, "y":96}},
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":768, "y":480}},
		"tile_deltas":{}
	}


func _tile_key(tile: Vector2i) -> String:
	return "%d:%d" % [tile.x, tile.y]


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Factory terrain")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
