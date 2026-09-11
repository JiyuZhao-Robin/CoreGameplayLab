extends SceneTree

const ContentDatabaseScript = preload("res://src/core/content_database.gd")
const FactoryGridSimulationScript = preload("res://src/core/factory_grid_simulation.gd")

const CORE_EXTRACTOR_ID := "grid_surface_mine"
const WIDE_FOOTPRINT := Vector2i(11, 11)
const WIDE_RADIUS := 18.0

var database: ContentDatabase
var factory: FactoryGridSimulation
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	database = ContentDatabaseScript.new()
	_check(database.load_from_file("res://data/content.json"), "Factory content loads: %s" % str(database.errors))
	if failures.is_empty():
		factory = FactoryGridSimulationScript.new(database.factory_buildings, database.factory_recipes, database.factory_grid_rules)
		_test_supported_catalog_and_snapshots()
		_test_large_miner_preserves_starting_geography()
		_test_circle_edge_and_corner_samples()
		_test_adjacent_building_reaches_ore()
		_test_circle_clips_to_world_and_irregular_mask()
		_test_same_resource_density_cap_and_mixed_rejection()
		_test_legacy_rectangle_behavior()
		_test_real_rate_cap_and_legacy_footprint()
	_finish()


func _test_supported_catalog_and_snapshots() -> void:
	var definition: Dictionary = database.factory_buildings.get(CORE_EXTRACTOR_ID, {})
	var footprint: Dictionary = definition.get("footprint", {})
	_check(
		Vector2i(int(footprint.get("width", 0)), int(footprint.get("height", 0))) == WIDE_FOOTPRINT
		and is_equal_approx(float(definition.get("mining_radius_tiles", 0.0)), WIDE_RADIUS),
		"supported Core Extractor catalog keeps its 11 x 11 physical footprint and declares radius 18"
	)
	var world := factory.create_world("circle-snapshot", "earth_orbit", Vector2i(128, 96), 11)
	_add_field(world, "ore-a", "iron_ore", Vector2i(52, 35), Vector2i(1, 1), 1.0, 0.25)
	_add_field(world, "ore-b", "iron_ore", Vector2i(82, 35), Vector2i(1, 1), 1.0, 0.25)
	var placed := factory.place_entity_immediate(world, CORE_EXTRACTOR_ID, Vector2i(30, 30), "", "wide")
	var queued := factory.queue_construction(world, CORE_EXTRACTOR_ID, Vector2i(60, 30))
	var snapshot := factory.workspace_snapshot(world)
	var entity := _row(snapshot.get("entities", []), "id", "wide")
	var ghost := _row(snapshot.get("construction_orders", []), "id", str(queued.get("order_id", "")))
	var palette := _row((snapshot.get("palette", {}) as Dictionary).get("buildings", []), "id", CORE_EXTRACTOR_ID)
	_check(bool(placed.get("ok", false)) and bool(queued.get("ok", false)), "a wide extractor and its finished-building ghost accept ore that lies outside their physical footprint")
	_check(
		int(entity.get("footprint_tiles", 0)) == 121
		and int(entity.get("mining_area_tiles", 0)) > int(entity.get("footprint_tiles", 0))
		and is_equal_approx(float(entity.get("mining_radius_tiles", 0.0)), WIDE_RADIUS),
		"entity snapshot separates physical footprint metadata from circular mining area metadata"
	)
	_check(
		is_equal_approx(float(ghost.get("mining_radius_tiles", 0.0)), WIDE_RADIUS)
		and int(ghost.get("mining_area_tiles", 0)) > 121,
		"construction ghost preserves circular reach metadata before deployment"
	)
	_check(is_equal_approx(float(palette.get("mining_radius_tiles", 0.0)), WIDE_RADIUS), "palette snapshot exposes the declared circular reach")


func _test_circle_edge_and_corner_samples() -> void:
	var world := factory.create_world("circle-edge", "earth_orbit", Vector2i(80, 80), 12)
	_add_field(world, "edge", "iron_ore", Vector2i(43, 35), Vector2i.ONE, 1.0, 0.5)
	_add_field(world, "corner", "iron_ore", Vector2i(41, 41), Vector2i.ONE, 1.0, 0.5)
	var profile := factory.resource_coverage_for_footprint(world, _footprint(Vector2i(30, 30), WIDE_FOOTPRINT), 0.1, 8.0)
	_check(
		int(profile.get("covered_resource_tiles", 0)) == 1
		and (profile.get("resource_field_ids", []) as Array) == ["edge"]
		and is_equal_approx(float(profile.get("coverage_efficiency", 0.0)), 1.0),
		"circle includes a tile-center exactly on its edge and excludes an AABB corner outside the radius"
	)


func _test_large_miner_preserves_starting_geography() -> void:
	var world := factory.create_world("starter-geography", "earth_orbit",Vector2i(144,96),730201)
	_add_field(world,"starter-iron","iron_ore",Vector2i(32,32),Vector2i(32,32),1.0,0.25)
	_add_field(world,"starter-copper","copper_ore",Vector2i(72,32),Vector2i(32,32),1.0,0.2)
	_check(world.resource_fields.size() == 2,"a larger circular mining reach does not prune either authored starting resource patch")


func _test_adjacent_building_reaches_ore() -> void:
	var world := factory.create_world("circle-adjacent", "earth_orbit", Vector2i(100, 96), 13)
	_add_field(world, "remote-iron", "iron_ore", Vector2i(52, 35), Vector2i.ONE, 1.0, 0.2)
	var placement := factory.can_place_entity(world, CORE_EXTRACTOR_ID, Vector2i(30, 30))
	_check(
		bool(placement.get("ok", false))
		and int((placement.get("resource_profile", {}) as Dictionary).get("covered_resource_tiles", 0)) == 1,
		"an extractor can stand beside an ore patch while its circular range reaches the patch"
	)


func _test_circle_clips_to_world_and_irregular_mask() -> void:
	var clipped := factory.create_world("circle-clipped", "earth_orbit", Vector2i(20, 20), 14)
	_add_field(clipped, "edge-ore", "iron_ore", Vector2i(19, 12), Vector2i.ONE, 1.0, 0.25)
	var clipped_profile := factory.resource_coverage_for_footprint(clipped, _footprint(Vector2i(7, 7), WIDE_FOOTPRINT), 0.1, WIDE_RADIUS)
	_check(
		int(clipped_profile.get("covered_resource_tiles", 0)) == 1
		and int(clipped_profile.get("mining_area_tiles", 0)) <= 400
		and is_equal_approx(float(clipped_profile.get("coverage_efficiency", 0.0)), 1.0),
		"circle samples are clipped to finite world bounds without treating off-world reach as missing ore"
	)

	var irregular := factory.create_world("circle-irregular", "earth_orbit", Vector2i(96, 96), 15)
	_add_field(irregular, "jagged", "iron_ore", Vector2i(30, 30), Vector2i(20, 20), 1.0, 0.25)
	irregular["resource_fields"]["jagged"]["shape"] = "IRREGULAR"
	irregular["resource_fields"]["jagged"]["seed"] = 71
	var footprint := _footprint(Vector2i(34, 34), WIDE_FOOTPRINT)
	var radius := 12.0
	var profile := factory.resource_coverage_for_footprint(irregular, footprint, 0.1, radius)
	var expected := _manual_circle_resource_count(irregular, footprint, radius)
	_check(int(profile.get("covered_resource_tiles", 0)) == expected and expected > 0, "circle coverage honors the sparse irregular resource tile mask")


func _test_same_resource_density_cap_and_mixed_rejection() -> void:
	var world := factory.create_world("circle-density", "earth_orbit", Vector2i(100, 96), 16)
	_add_field(world, "iron-a", "iron_ore", Vector2i(48, 34), Vector2i(2, 2), 1.0, 0.25)
	_add_field(world, "iron-b", "iron_ore", Vector2i(51, 34), Vector2i(2, 2), 1.0, 0.25)
	var profile := factory.resource_coverage_for_footprint(world, _footprint(Vector2i(30, 30), WIDE_FOOTPRINT), 0.1, WIDE_RADIUS)
	_check(
		(profile.get("resource_ids", []) as Array) == ["iron_ore"]
		and not bool(profile.get("mixed_resource_types", true))
		and int(profile.get("covered_resource_tiles", 0)) == 8
		and is_equal_approx(float(profile.get("sustainable_rate_per_second", 0.0)), 2.0),
		"same-resource fields share one extraction type and the summed tile density remains the production cap"
	)

	var mixed := factory.create_world("circle-mixed", "earth_orbit", Vector2i(100, 96), 17)
	_add_field(mixed, "iron", "iron_ore", Vector2i(20, 35), Vector2i.ONE, 1.0, 0.25)
	_add_field(mixed, "copper", "copper_ore", Vector2i(50, 35), Vector2i.ONE, 1.0, 0.25)
	var rejected := factory.can_place_entity(mixed, CORE_EXTRACTOR_ID, Vector2i(30, 30))
	_check(not bool(rejected.get("ok", true)) and str(rejected.get("reason_code", "")) == "MIXED_RESOURCE_COVERAGE", "circular reach retains mixed-resource rejection instead of selecting ore automatically")


func _test_legacy_rectangle_behavior() -> void:
	var world := factory.create_world("rectangle-legacy", "earth_orbit", Vector2i(64, 64), 18)
	_add_field(world, "single", "iron_ore", Vector2i(20, 20), Vector2i.ONE, 1.0, 0.25)
	var profile := factory.resource_coverage_for_footprint(world, _footprint(Vector2i(20, 20), Vector2i(3, 3)), 0.1)
	_check(
		int(profile.get("footprint_tiles", 0)) == 9
		and int(profile.get("mining_area_tiles", 0)) == 9
		and int(profile.get("missing_resource_tiles", 0)) == 8
		and is_zero_approx(float(profile.get("mining_radius_tiles", -1.0)))
		and is_equal_approx(float(profile.get("coverage_efficiency", 0.0)), 0.2),
		"definitions without mining_radius_tiles retain rectangular footprint coverage and loss behavior"
	)


func _manual_circle_resource_count(world: Dictionary, footprint: Dictionary, radius: float) -> int:
	var origin: Dictionary = footprint.get("origin", {})
	var size: Dictionary = footprint.get("size", {})
	var center := Vector2(float(origin.get("x", 0)) + float(size.get("x", 0)) * 0.5, float(origin.get("y", 0)) + float(size.get("y", 0)) * 0.5)
	var count := 0
	for y in range(floori(center.y - radius), ceili(center.y + radius)):
		for x in range(floori(center.x - radius), ceili(center.x + radius)):
			if Vector2(float(x) + 0.5, float(y) + 0.5).distance_squared_to(center) <= radius * radius + 0.000001 and not str(factory.tile_snapshot(world, Vector2i(x, y)).get("resource_id", "")).is_empty():
				count += 1
	return count


func _test_real_rate_cap_and_legacy_footprint() -> void:
	var world := factory.create_world("circle-runtime-cap","earth_orbit",Vector2i(96,96),22)
	factory.building_definitions["circle-test-power"] = {"id":"circle-test-power","kind":"POWER","footprint":{"width":1,"height":1},"power_generation_kw":100.0}
	_add_field(world,"tiny-rich-patch","iron_ore",Vector2i(48,35),Vector2i.ONE,2.0,0.25)
	_check(factory.place_entity_immediate(world,CORE_EXTRACTOR_ID,Vector2i(30,30),"","mine").get("ok",false),"runtime cap fixture deploys an adjacent circular extractor")
	_check(factory.place_entity_immediate(world,"circle-test-power",Vector2i(29,30),"","power").get("ok",false),"runtime cap fixture supplies a physical power source")
	_check(factory.edit_roads(world,[{"x":29,"y":31}],1).get("ok",false),"built road connects power to the miner's physical boundary")
	factory.advance_world(world,4000.0)
	_check(is_equal_approx(float(world.entities.mine.get("actual_rate",0.0)),0.25) and int(world.entities.mine.outputs.get("iron_ore",0)) == 1,"actual time progression caps a high-grade miner at the tiny patch's sustainable supply")
	# Simulate an already installed legacy machine without moving its neighbours.
	world.entities.mine.footprint.size = {"x":3,"y":3}
	_check(factory.edit_roads(world,[{"x":33,"y":30}],1).get("ok",false),"legacy fixture has a road inside the future enlarged footprint")
	var roads: Dictionary = world.roads.duplicate(true)
	var normalized := factory.normalize_world(world)
	factory.refresh_derived_state(normalized)
	_check(normalized.entities.mine.footprint.size == {"x":3,"y":3} and normalized.roads == roads,"normalization preserves legacy physical occupancy and nearby roads")
	_check(is_equal_approx(float(normalized.entities.mine.get("mining_radius_tiles",0.0)),18.0),"legacy installed machines consume the current circular mining rule without silently expanding physical occupancy")


func _add_field(world: Dictionary, id: String, resource_id: String, origin: Vector2i, size: Vector2i, grade: float, density: float) -> void:
	var result := factory.add_resource_field(world, id, resource_id, origin, size, grade, density, "solid")
	_check(bool(result.get("ok", false)), "resource fixture created: " + id + " " + str(result.get("reason_code", "")))


func _footprint(origin: Vector2i, size: Vector2i) -> Dictionary:
	return {"origin":{"x":origin.x, "y":origin.y}, "size":{"x":size.x, "y":size.y}}


func _row(rows: Array, key: String, value: String) -> Dictionary:
	for row_value in rows:
		var row := row_value as Dictionary
		if str(row.get(key, "")) == value:
			return row
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_CIRCULAR_MINING_TEST_PASS")
		quit(0)
	else:
		push_error("FACTORY_CIRCULAR_MINING_TEST_FAIL: " + "; ".join(failures))
		quit(1)
