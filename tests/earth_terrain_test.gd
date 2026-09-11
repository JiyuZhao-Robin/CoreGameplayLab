extends SceneTree
const Terrain = preload("res://src/core/factory_terrain.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_test_legacy_and_precedence()
	_test_seed_scale_coordinates_and_read_order()
	_test_landform_regions()
	_test_continuous_fields_and_starter()
	if failures.is_empty():
		print("PASS: Earth terrain geography, compatibility and continuous samples")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _world() -> Dictionary:
	return {"seed":730201, "generator_version":2, "terrain_profile":"earth_v2", "terrain_enabled":true, "terrain_scale_tiles":48.0,
		"bounds":{"origin":{"x":0,"y":0},"size":{"x":1024,"y":640}},
		"terrain_safe_rect":{"origin":{"x":0,"y":0},"size":{"x":144,"y":96}},"tile_deltas":{}}


func _test_legacy_and_precedence() -> void:
	var world := _world()
	world.erase("terrain_profile")
	# Golden outputs of the pre-Earth generator, covering all five terrain types.
	var fixture := {Vector2i(152,112):"FOREST", Vector2i(160,112):"PLAIN", Vector2i(192,112):"DESERT", Vector2i(480,120):"WATER", Vector2i(280,160):"MOUNTAIN"}
	for tile: Vector2i in fixture:
		_check(Terrain.terrain_type(world, tile) == fixture[tile], "unmarked legacy save preserves golden terrain at %s" % tile)
		_check(Terrain.surface_sample(world, tile).terrain == fixture[tile], "legacy visual and semantic samples agree")
	world["terrain_profile"] = "unrecognized_future_profile"
	_check(Terrain.terrain_type(world, Vector2i(480,120)) == "WATER", "only explicit earth_v2 opts into new geography")
	world = _world()
	world["terrain_enabled"] = false
	_check(Terrain.surface_sample(world, Vector2i(950,400)).terrain == "PLAIN", "disabled Earth terrain is plain")
	for terrain: String in Terrain.TERRAIN_TYPES:
		world["tile_deltas"] = {"40:40":{"terrain_override":terrain}}
		var sample := Terrain.surface_sample(world, Vector2i(40,40))
		_check(sample.terrain == terrain and Terrain.terrain_type(world, Vector2i(40,40)) == terrain, "delta wins over disabled Earth and safe zone for %s" % terrain)
		_check((float(sample.water_depth) > 0.0) == (terrain == "WATER"), "overrides do not retain obsolete water depth")
		_check((float(sample.forest_density) > 0.0) == (terrain == "FOREST"), "overrides do not retain obsolete trees")
	world["terrain_enabled"] = true
	world["tile_deltas"] = {"40:40":{"terrain_override":"INVALID"}}
	_check(Terrain.surface_sample(world, Vector2i(40,40)).terrain == "PLAIN", "invalid override falls through to safe zone")
	_check(not Terrain.is_buildable(world, Vector2i(-1,40)) and not Terrain.is_buildable(world, Vector2i(1024,40)), "Earth placement still rejects out-of-bounds coordinates")


func _test_seed_scale_coordinates_and_read_order() -> void:
	var world := _world()
	var untouched := world.duplicate(true)
	var shifted := world.duplicate(true)
	shifted.bounds.origin = {"x":-2048,"y":3072}
	shifted.terrain_safe_rect.origin = {"x":-2048,"y":3072}
	var alternate := world.duplicate(true)
	alternate["seed"] = 730202
	var scaled := world.duplicate(true)
	scaled["terrain_scale_tiles"] = 80.0
	var samples := {}
	var seed_changes := 0
	var scale_changes := 0
	for y in range(0,640,23):
		for x in range(0,1024,29):
			var tile := Vector2i(x,y)
			var sample := Terrain.surface_sample(world,tile)
			samples[tile] = sample
			_check(sample == Terrain.surface_sample(shifted,tile + Vector2i(-2048,3072)), "nonzero world and safe origins preserve relative geography at %s" % tile)
			_check(sample.terrain == Terrain.terrain_type(world,tile), "surface terrain remains authoritative")
			if sample.terrain != Terrain.surface_sample(alternate,tile).terrain:
				seed_changes += 1
			if sample.terrain != Terrain.surface_sample(scaled,tile).terrain:
				scale_changes += 1
	var keys := samples.keys()
	keys.reverse()
	for tile: Vector2i in keys:
		_check(samples[tile] == Terrain.surface_sample(world,tile), "reverse reads reproduce all continuous fields")
	_check(seed_changes > samples.size() / 10, "seed changes a meaningful portion of biome geography")
	_check(scale_changes > samples.size() / 12, "terrain scale changes actual landforms")
	_check(world == untouched, "sampling does not mutate authoritative world or create a tile cache")


func _test_landform_regions() -> void:
	var world := _world()
	const STEP := 4
	const WIDTH := 256
	const HEIGHT := 160
	var cells := PackedByteArray()
	cells.resize(WIDTH * HEIGHT)
	var counts := [0,0,0,0,0]
	for y in range(HEIGHT):
		for x in range(WIDTH):
			var terrain := Terrain.terrain_type(world,Vector2i(x * STEP,y * STEP))
			var kind := Terrain.TERRAIN_TYPES.find(terrain)
			cells[y * WIDTH + x] = kind
			counts[kind] += 1
	var total := float(cells.size())
	_check(counts[0] / total > 0.15 and counts[0] / total < 0.75, "open buildable grassland occupies a substantial area")
	_check(counts[1] / total > 0.10 and counts[1] / total < 0.60, "forest exists as substantial masses")
	_check(counts[2] / total > 0.001 and counts[2] / total < 0.05, "sand is restricted to narrow shore bands")
	_check(counts[3] / total > 0.10 and counts[3] / total < 0.35, "water has real regional extent")
	_check(counts[4] / total > 0.025 and counts[4] / total < 0.20, "mountain ranges have useful but bounded footprint")
	var waters := _components(cells,WIDTH,HEIGHT,3)
	var mountains := _components(cells,WIDTH,HEIGHT,4)
	var forests := _components(cells,WIDTH,HEIGHT,1)
	var river_lake := false
	var broad_sea := false
	for region: Dictionary in waters:
		var bounds: Rect2i = region.bounds
		if bounds.position.x < 80 and bounds.end.x < 100 and bounds.position.y < 33 and bounds.end.y > 120 and int(region.count) > 1000:
			river_lake = true
		if bounds.end.x == WIDTH and bounds.size.y > 145 and int(region.count) > 2500:
			broad_sea = true
	_check(river_lake, "one connected inland component contains a spring-fed river and broad lake")
	_check(broad_sea, "eastern coast bounds one connected broad water body")
	var long_range := false
	for region: Dictionary in mountains:
		var bounds: Rect2i = region.bounds
		if bounds.size.y > 30 and bounds.size.x > 10 and int(region.count) > 250:
			long_range = true
	_check(long_range, "mountain components form directional ranges instead of isolated noise spots")
	var large_forest := false
	for region: Dictionary in forests:
		large_forest = large_forest or int(region.count) > 400
	_check(large_forest, "tree terrain contains connected woodland masses")
	var pass_rows := 0
	for y in range(640):
		var clear := true
		for x in range(280,720,4):
			if Terrain.terrain_type(world,Vector2i(x,y)) == "MOUNTAIN":
				clear = false
				break
		if clear:
			pass_rows += 1
	_check(pass_rows >= 35, "wide buildable saddles prevent an impassable mountain wall")
	print("Earth occupancy PLAIN/FOREST/SAND/WATER/MOUNTAIN: ", counts, "; water regions: ", waters.size(), "; mountain regions: ", mountains.size(), "; pass rows: ", pass_rows)


func _components(cells: PackedByteArray, width: int, height: int, kind: int) -> Array:
	var seen := PackedByteArray()
	seen.resize(cells.size())
	var result := []
	for start in range(cells.size()):
		if seen[start] or cells[start] != kind:
			continue
		var queue := [start]
		seen[start] = 1
		var cursor := 0
		var minimum := Vector2i(start % width,start / width)
		var maximum := minimum
		while cursor < queue.size():
			var index: int = queue[cursor]
			cursor += 1
			var p := Vector2i(index % width,index / width)
			minimum = minimum.min(p)
			maximum = maximum.max(p)
			for delta: Vector2i in [Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
				var next := p + delta
				if next.x < 0 or next.x >= width or next.y < 0 or next.y >= height:
					continue
				var next_index := next.y * width + next.x
				if not seen[next_index] and cells[next_index] == kind:
					seen[next_index] = 1
					queue.append(next_index)
		result.append({"count":queue.size(),"bounds":Rect2i(minimum,maximum - minimum + Vector2i.ONE)})
	return result


func _test_continuous_fields_and_starter() -> void:
	var world := _world()
	var fields := ["elevation","moisture","forest_density","water_depth","rock"]
	var maximum_jump := {}
	for field: String in fields:
		maximum_jump[field] = 0.0
	for y in range(0,640,9):
		for x in range(0,1024,11):
			var tile := Vector2i(x,y)
			var sample := Terrain.surface_sample(world,tile)
			for field: String in fields:
				var value := float(sample[field])
				_check(is_finite(value) and value >= 0.0 and value <= 1.0, "continuous field %s stays normalized" % field)
				for adjacent: Vector2i in [tile + Vector2i.RIGHT,tile + Vector2i.DOWN]:
					maximum_jump[field] = maxf(float(maximum_jump[field]),absf(value - float(Terrain.surface_sample(world,adjacent)[field])))
	for field: String in fields:
		_check(float(maximum_jump[field]) < 0.19, "%s changes smoothly across one tile: %s" % [field,maximum_jump[field]])
	for mine_origin: Vector2i in [Vector2i(40,40),Vector2i(80,40)]:
		for y in range(mine_origin.y,mine_origin.y + 11):
			for x in range(mine_origin.x,mine_origin.x + 11):
				_check(Terrain.is_buildable(world,Vector2i(x,y)), "11x11 starter miners fit protected land")
	for tile: Vector2i in [Vector2i(0,0),Vector2i(143,95),Vector2i(72,48)]:
		var sample := Terrain.surface_sample(world,tile)
		_check(sample.terrain == "PLAIN" and sample.forest_density == 0.0 and sample.water_depth == 0.0, "safe region has consistent clear ground")
	for y in range(0,96,7):
		var inside := Terrain.surface_sample(world,Vector2i(143,y))
		var outside := Terrain.surface_sample(world,Vector2i(144,y))
		_check(absf(float(inside.elevation) - float(outside.elevation)) < 0.01 and float(outside.forest_density) < 0.02, "safe-zone border is feathered instead of a rectangular cliff or tree cut")
	print("Earth maximum adjacent field changes: ",maximum_jump)


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)
