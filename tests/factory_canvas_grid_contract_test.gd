extends SceneTree

## Coordinate-only contract for the Factory canvas. It deliberately avoids a
## window or renderer so the primary can run it alongside the focused UI suite
## without producing a screenshot artifact.

const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	var canvas = CanvasScript.new()
	canvas.size = Vector2(1920, 1080)
	canvas.set("_snapshot", _shifted_snapshot())
	canvas.set("_camera", Vector2(17.25, -31.75))
	canvas.set("_zoom", 2.0)

	_test_non_zero_origin_round_trip(canvas)
	_test_exact_footprint_and_placement_hit(canvas)
	_test_visual_icon_is_not_domain_geometry(canvas)
	_test_grid_phase_at_multiple_zooms(canvas)
	_test_ground_tile_phase(canvas)
	canvas.free()
	_finish()


func _test_non_zero_origin_round_trip(canvas) -> void:
	var world_point := Vector2(103.25, 207.75)
	var screen_point: Vector2 = canvas._world_to_screen(world_point)
	var restored_world: Vector2 = canvas._screen_to_world(screen_point)
	var tile_center: Vector2 = canvas._world_to_screen(Vector2(116.5, 244.5))
	_check(
		restored_world.is_equal_approx(world_point)
		and canvas._screen_to_tile(tile_center) == Vector2i(116, 244),
		"non-zero world origins round-trip through canvas projection and resolve the same placement tile"
	)


func _test_exact_footprint_and_placement_hit(canvas) -> void:
	var footprint := {"origin":{"x":103, "y":204}, "size":{"x":2, "y":3}}
	var rect: Rect2 = canvas._footprint_rect(footprint, 4.0)
	var expected_position: Vector2 = canvas._world_to_screen(Vector2(103, 204))
	_check(
		rect.position.is_equal_approx(expected_position)
		and rect.size.is_equal_approx(Vector2(16, 24)),
		"authoritative 2 x 3 footprint remains exactly 2 x 3 tiles despite legacy minimum-size callers"
	)
	canvas.set("_placement_preview", {"footprint":footprint, "valid":true})
	_check(
		canvas._placement_preview_contains(rect.get_center())
		and not canvas._placement_preview_contains(rect.end + Vector2(0.01, 0.01)),
		"placement preview and hit testing use the exact physical footprint"
	)


func _test_visual_icon_is_not_domain_geometry(canvas) -> void:
	var first_entity := _compact_entity("compact-a", Vector2i(110, 210))
	var second_entity := _compact_entity("compact-b", Vector2i(112, 210))
	canvas.set("_camera", Vector2(-800.0, -1550.0))
	canvas.set("_zoom", 2.0)
	var first_footprint: Dictionary = first_entity.get("footprint", {}) as Dictionary
	var second_footprint: Dictionary = second_entity.get("footprint", {}) as Dictionary
	var exact_rect: Rect2 = canvas._footprint_rect(first_footprint)
	var second_exact_rect: Rect2 = canvas._footprint_rect(second_footprint)
	var icon_rect: Rect2 = canvas._entity_visible_icon_rect(exact_rect, "COMPACT")
	var icon_only_point := icon_rect.position + Vector2(1.0, 1.0)
	var snapshot := _shifted_snapshot()
	snapshot["entities"] = [first_entity, second_entity]
	canvas.set("_snapshot", snapshot)
	canvas.set("_entities_by_id", {"compact-a":first_entity, "compact-b":second_entity})
	canvas.set("_visible_records", {})
	canvas.set("_hit_geometry_dirty", true)
	canvas.get("_chunk_index").rebuild(snapshot)
	canvas.set("_placement_preview", {"footprint":first_footprint, "valid":true})
	var selected_ids: Array[String] = []
	canvas.entity_selected.connect(func(entity: Dictionary) -> void: selected_ids.append(str(entity.get("id", ""))))
	# The icon-only point lies outside all true footprints. It remains invalid for
	# construction, then selects the nearest overlapping visible icon.
	canvas._select_at(icon_only_point)
	var icon_does_not_place: bool = not canvas._placement_preview_hit(icon_only_point)
	canvas.set("_placement_preview", {})
	# Exact geometry still wins over the neighbouring icon overlap.
	canvas._select_at(second_exact_rect.get_center())
	var endpoints: Array[Vector2] = canvas._connection_endpoints(first_entity, second_entity, "CARGO")
	_check(
		icon_rect.size.x >= 38.0
		and icon_rect.size.y >= 38.0
		and not exact_rect.has_point(icon_only_point)
		and not second_exact_rect.has_point(icon_only_point)
		and icon_does_not_place
		and selected_ids == ["compact-a", "compact-b"]
		and endpoints == [Vector2(exact_rect.end.x, exact_rect.get_center().y), Vector2(second_exact_rect.position.x, second_exact_rect.get_center().y)],
		"compact icons remain clickable with nearest-centre overlap resolution while placement, exact-footprint priority, and port endpoints stay on real tiles"
	)


func _test_grid_phase_at_multiple_zooms(canvas) -> void:
	canvas.set("_zoom", 2.0)
	var readable_step: int = canvas._grid_step_tiles()
	var readable_first: int = canvas._first_grid_coordinate(103.1, 100, readable_step)
	canvas.set("_zoom", 0.5)
	var macro_step: int = canvas._grid_step_tiles()
	var macro_first: int = canvas._first_grid_coordinate(103.1, 100, macro_step)
	canvas.set("_camera", Vector2(-143.0, 67.0))
	var phased_screen_x: float = canvas._world_to_screen(Vector2(macro_first, 0.0)).x
	_check(
		readable_step == 1
		and readable_first == 104
		and macro_step > 1
		and macro_first == 116
		and is_equal_approx(phased_screen_x, -143.0 + float(macro_first) * canvas._tile_scale()),
		"exact and macro grid LODs retain one origin-anchored phase while camera movement changes only screen projection"
	)


func _test_ground_tile_phase(canvas) -> void:
	_check(
		canvas._ground_cell_coordinate(100.0, 100) == 100
		and canvas._ground_cell_coordinate(163.999, 100) == 100
		and canvas._ground_cell_coordinate(164.0, 100) == 164
		and canvas._ground_cell_coordinate(99.5, 100) == 36,
		"regolith material cells tile from the same non-zero world origin instead of stretching with the visible world"
	)


func _shifted_snapshot() -> Dictionary:
	return {
		"valid":true,
		"world_id":"canvas-grid-contract",
		"bounds":{"origin":{"x":100, "y":200}, "size":{"x":256, "y":160}}
	}


func _compact_entity(entity_id: String, origin: Vector2i) -> Dictionary:
	return {
		"id":entity_id,
		"node_kind":"MACHINE",
		"definition_id":"grid_arc_smelter",
		"footprint":{"origin":{"x":origin.x, "y":origin.y}, "size":{"x":1, "y":1}},
		"ports":{"inputs":[], "outputs":[], "accepts_power":false, "provides_power":false}
	}


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_CANVAS_GRID_CONTRACT_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
