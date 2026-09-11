extends SceneTree

## Rendered Factory canvas regression for layer ordering over the authored,
## irregular ore field.  This fixture is deliberately presentation-only: it
## supplies a bounded v1 snapshot and never creates Game state or commands.
##
## Run with a normal Compatibility renderer.  A dummy/headless DisplayServer
## still checks the preview record contract, but explicitly skips pixel checks.

const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const Terrain = preload("res://src/core/factory_terrain.gd")
const ViewModelScript = preload("res://src/ui/view_models/factory/factory_workspace_view_model.gd")

const LOGICAL_SIZE := Vector2(1920, 1080)
const PHYSICAL_SIZE := Vector2i(3840, 2160)
const CAPTURE_SCALE := 2.0
const FIXTURE_ZOOM := 2.0
const FIXTURE_CAMERA := Vector2(448, 156)
const ROAD_ORIGIN := Vector2i(42, 42)
const ROAD_LENGTH := 16
const VALID_PREVIEW_ORIGIN := Vector2i(43, 41)
const BUILDING_ORIGIN := Vector2i(54, 42)
const GHOST_ORIGIN := Vector2i(62, 46)
const MIN_CHANGED_RATIO := 0.10
const PIXEL_DELTA_THRESHOLD := 0.10

var failures: Array[String] = []
var evidence_output := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_parse_arguments()
	var building := _mine_building()
	var road_snapshot := _snapshot_with_roads()
	var entity_snapshot := _snapshot_with_entity()
	var view_model = ViewModelScript.new()
	var valid_preview: Dictionary = view_model.placement_preview(road_snapshot, building, VALID_PREVIEW_ORIGIN)
	var invalid_preview: Dictionary = view_model.placement_preview(entity_snapshot, building, BUILDING_ORIGIN)
	_assert_fixture_and_preview_contract(road_snapshot, entity_snapshot, valid_preview, invalid_preview)

	if _rendering_is_unavailable():
		print("FACTORY_VISUAL_LAYERS_RENDERED_ASSERTIONS_SKIPPED_HEADLESS")
		_finish()
		return

	root.size = PHYSICAL_SIZE
	var host := Control.new()
	host.name = "FactoryVisualLayersHost"
	host.size = LOGICAL_SIZE
	# The project canvas_items stretch performs the one production 2x mapping
	# from this logical Factory canvas to the actual 4K Window texture.
	root.add_child(host)
	var canvas = CanvasScript.new()
	canvas.name = "FactoryVisualLayersCanvas"
	canvas.size = LOGICAL_SIZE
	host.add_child(canvas)
	canvas.set_road_logistics_mode(true)
	await _settle()

	var pristine_snapshot := _snapshot()
	var pristine_serialized := JSON.stringify(pristine_snapshot)
	var ore_only: Image = await _render(canvas, pristine_snapshot, {}, "00-irregular-ore")
	var roads: Image = await _render(canvas, road_snapshot, {}, "01-road-over-irregular-ore")
	var entity: Image = await _render(canvas, entity_snapshot, {}, "02-building-over-irregular-ore")
	var ghost: Image = await _render(canvas, _snapshot_with_ghost(), {}, "03-ghost-over-irregular-ore")
	var valid_preview_image: Image = await _render(canvas, road_snapshot, valid_preview, "04-valid-preview-over-road-and-ore")
	var invalid_preview_image: Image = await _render(canvas, entity_snapshot, invalid_preview, "05-invalid-preview-over-building-and-ore")

	_check(ore_only.get_size() == PHYSICAL_SIZE, "the isolated canvas produces an actual 3840 x 2160 render target")
	_check(JSON.stringify(pristine_snapshot) == pristine_serialized, "rendering an immutable Factory snapshot does not mutate terrain, roads, or inventory data")
	_check(
		_changed_pixel_ratio(ore_only, roads, canvas._footprint_rect(_footprint(ROAD_ORIGIN, Vector2i(ROAD_LENGTH, 1)))) > MIN_CHANGED_RATIO,
		"roads retain a visible surface over the same irregular ore texture"
	)
	var entity_rect: Rect2 = canvas._entity_visible_icon_rect(canvas._footprint_rect(_entity_record().get("footprint", {})), "FULL").grow(2.0)
	_check(
		_changed_pixel_ratio(ore_only, entity, entity_rect) > MIN_CHANGED_RATIO,
		"finished building silhouettes remain visible over the irregular ore texture"
	)
	var ghost_rect: Rect2 = canvas._footprint_rect(_ghost_record().get("footprint", {}))
	_check(
		_changed_pixel_ratio(ore_only, ghost, ghost_rect) > MIN_CHANGED_RATIO,
		"unfinished building ghosts remain visible over the irregular ore texture"
	)
	var valid_rect: Rect2 = canvas._footprint_rect(valid_preview.get("footprint", {}))
	_check(
		_changed_pixel_ratio(roads, valid_preview_image, valid_rect) > MIN_CHANGED_RATIO
			and _teal_signal_ratio(valid_preview_image, valid_rect) > 0.01,
		"valid placement preview is the teal topmost layer over road and irregular ore"
	)
	var invalid_rect: Rect2 = canvas._footprint_rect(invalid_preview.get("footprint", {}))
	_check(
		_changed_pixel_ratio(entity, invalid_preview_image, invalid_rect) > MIN_CHANGED_RATIO
			and _red_signal_ratio(invalid_preview_image, invalid_rect) > 0.01,
		"invalid placement preview is the red topmost layer over a finished building and irregular ore"
	)
	canvas.clear_placement_preview()
	var selected: Array[String] = []
	canvas.entity_selected.connect(func(row: Dictionary) -> void: selected.append(str(row.get("id",""))))
	canvas.resource_field_selected.connect(func(row: Dictionary) -> void: selected.append(str(row.get("id",""))))
	var exact_rect: Rect2 = canvas._footprint_rect(_entity_record().get("footprint",{}))
	var sprite_point := Vector2(exact_rect.get_center().x, exact_rect.position.y - 4.0)
	canvas.set_placement_preview({"valid":true,"footprint":_entity_record().get("footprint",{})})
	_check(not canvas._placement_preview_hit(sprite_point), "visible sprite padding does not enlarge the deployable footprint")
	canvas.clear_placement_preview()
	canvas._select_at(sprite_point)
	_check(selected == ["finished-mine"], "clicking the visible mining tower outside its footprint selects the building above the ore")
	var neighbours := _snapshot_with_entity()
	var left := _entity_record()
	left["id"] = "a-left"
	var right := _entity_record()
	right["id"] = "z-right"
	right["footprint"] = _footprint(BUILDING_ORIGIN + Vector2i(3,0),Vector2i(3,3))
	neighbours["entities"] = [right,left]
	neighbours["topology_revision"] = 8
	await _render(canvas,neighbours,{},"06-adjacent-mining-sprites")
	selected.clear()
	var left_rect: Rect2 = canvas._footprint_rect(left["footprint"])
	var overlap_point := Vector2(left_rect.end.x,left_rect.position.y - 4.0)
	canvas._select_at(overlap_point)
	_check(selected == ["z-right"], "overlapping sprite clicks follow the same front-to-back order as drawing, independent of snapshot array order")

	canvas.queue_free()
	host.queue_free()
	await process_frame
	_finish()


func _assert_fixture_and_preview_contract(road_snapshot: Dictionary, entity_snapshot: Dictionary, valid_preview: Dictionary, invalid_preview: Dictionary) -> void:
	var field: Dictionary = (road_snapshot.get("resource_fields", []) as Array)[0] as Dictionary
	_check(
		str(field.get("shape", "")) == "IRREGULAR"
			and _footprint_is_inside_irregular_field(field, _footprint(ROAD_ORIGIN, Vector2i(ROAD_LENGTH, 1)))
			and _footprint_is_inside_irregular_field(field, _footprint(VALID_PREVIEW_ORIGIN, Vector2i(3, 3)))
			and _footprint_is_inside_irregular_field(field, _footprint(BUILDING_ORIGIN, Vector2i(3, 3)))
			and _footprint_is_inside_irregular_field(field, _footprint(GHOST_ORIGIN, Vector2i(6, 5))),
		"the road, building, ghost, and both previews are all positioned on a real central irregular ore field"
	)
	_check(
		Terrain.is_buildable(road_snapshot, VALID_PREVIEW_ORIGIN)
			and bool(valid_preview.get("valid", false))
			and not bool(invalid_preview.get("valid", true))
			and str(invalid_preview.get("reason_code", "")) == "FOOTPRINT_OCCUPIED",
		"the bounded terrain fixture supplies one valid and one occupied invalid placement without simulation mutation"
	)
	_check(
		str(valid_preview.get("definition_id", "")) == "grid_surface_mine"
			and str(valid_preview.get("node_kind", "")) == "EXTRACTOR"
			and str(invalid_preview.get("definition_id", "")) == "grid_surface_mine"
			and str(invalid_preview.get("node_kind", "")) == "EXTRACTOR",
		"valid and invalid placement previews carry definition_id and node_kind for their visible building identity"
	)
	_check((entity_snapshot.get("entities", []) as Array).size() == 1, "invalid preview baseline contains exactly one finished building beneath it")


func _render(canvas, snapshot: Dictionary, preview: Dictionary, evidence_name: String) -> Image:
	canvas.apply_snapshot(snapshot)
	# Make image sampling independent of the overview fit calculation. These are
	# logical canvas coordinates; project.godot supplies the only 2x window scale.
	canvas.set("_overview_mode", false)
	canvas.set("_zoom", FIXTURE_ZOOM)
	canvas.set("_camera", FIXTURE_CAMERA)
	if preview.is_empty():
		canvas.clear_placement_preview()
	else:
		canvas.set_placement_preview(preview)
	await _settle()
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if not evidence_output.is_empty():
		_save_evidence(image, evidence_name)
	return image


func _save_evidence(image: Image, evidence_name: String) -> void:
	var absolute_root := evidence_output if evidence_output.is_absolute_path() else ProjectSettings.globalize_path(evidence_output)
	var error := DirAccess.make_dir_recursive_absolute(absolute_root)
	var path := absolute_root.path_join(evidence_name + ".png")
	_check(error == OK and image.save_png(path) == OK, "4K evidence screenshot saves: %s" % path)


func _changed_pixel_ratio(before: Image, after: Image, logical_rect: Rect2) -> float:
	if before == null or after == null or before.get_size() != after.get_size():
		return 0.0
	var region := _physical_rect(logical_rect, before.get_size())
	if region.size.x <= 0 or region.size.y <= 0:
		return 0.0
	var changed := 0
	var total := region.size.x * region.size.y
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			if _color_delta(before.get_pixel(x, y), after.get_pixel(x, y)) >= PIXEL_DELTA_THRESHOLD:
				changed += 1
	return float(changed) / float(maxi(1, total))


func _teal_signal_ratio(image: Image, logical_rect: Rect2) -> float:
	return _color_signal_ratio(image, logical_rect, func(color: Color) -> bool:
		return color.g > 0.45 and color.g > color.r * 1.25 and color.g > color.b * 1.12
	)


func _red_signal_ratio(image: Image, logical_rect: Rect2) -> float:
	return _color_signal_ratio(image, logical_rect, func(color: Color) -> bool:
		return color.r > 0.50 and color.r > color.g * 1.25 and color.r > color.b * 1.25
	)


func _color_signal_ratio(image: Image, logical_rect: Rect2, predicate: Callable) -> float:
	var region := _physical_rect(logical_rect, image.get_size())
	if region.size.x <= 0 or region.size.y <= 0:
		return 0.0
	var matches := 0
	var total := region.size.x * region.size.y
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			if predicate.call(image.get_pixel(x, y)):
				matches += 1
	return float(matches) / float(maxi(1, total))


func _physical_rect(logical_rect: Rect2, image_size: Vector2i) -> Rect2i:
	var position := Vector2i(floori(logical_rect.position.x * CAPTURE_SCALE), floori(logical_rect.position.y * CAPTURE_SCALE))
	var end := Vector2i(ceili(logical_rect.end.x * CAPTURE_SCALE), ceili(logical_rect.end.y * CAPTURE_SCALE))
	position = Vector2i(clampi(position.x, 0, image_size.x), clampi(position.y, 0, image_size.y))
	end = Vector2i(clampi(end.x, 0, image_size.x), clampi(end.y, 0, image_size.y))
	return Rect2i(position, Vector2i(maxi(0, end.x - position.x), maxi(0, end.y - position.y)))


func _color_delta(a: Color, b: Color) -> float:
	return absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) + absf(a.a - b.a)


func _rendering_is_unavailable() -> bool:
	var display_name := DisplayServer.get_name().to_lower()
	return display_name == "headless" or display_name == "dummy"


func _parse_arguments() -> void:
	for value in OS.get_cmdline_user_args():
		var argument := str(value)
		if argument.begins_with("--evidence-output="):
			evidence_output = argument.trim_prefix("--evidence-output=")


func _snapshot() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"factory-visual-layers",
		"topology_revision":1,
		"runtime_revision":1,
		"elapsed_ms":0.0,
		"logistics_mode":"PLANET_SHARED_ROADS",
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":128, "y":96}},
		"canvas_limits":{"max_world_size_tiles":{"x":128, "y":96}},
		"chunk_size_tiles":64,
		"terrain_enabled":true,
		"terrain_seed":743,
		"terrain_scale_tiles":40.0,
		"terrain_safe_rect":{"origin":{"x":0, "y":0}, "size":{"x":128, "y":96}},
		"tile_deltas":{},
		"roads":[],
		"road_shipments":[],
		"links":[],
		"entities":[],
		"construction_orders":[],
		"resource_fields":[_irregular_iron_field()],
		"palette":{"buildings":[_mine_building()], "recipes":[]}
	}


func _snapshot_with_roads() -> Dictionary:
	var result := _snapshot()
	result["topology_revision"] = 2
	var roads: Array = []
	for x in range(ROAD_ORIGIN.x, ROAD_ORIGIN.x + ROAD_LENGTH):
		roads.append({"x":x, "y":ROAD_ORIGIN.y, "tier":1})
	result["roads"] = roads
	return result


func _snapshot_with_entity() -> Dictionary:
	var result := _snapshot()
	result["topology_revision"] = 3
	result["entities"] = [_entity_record()]
	return result


func _snapshot_with_ghost() -> Dictionary:
	var result := _snapshot()
	result["topology_revision"] = 4
	result["construction_orders"] = [_ghost_record()]
	return result


func _irregular_iron_field() -> Dictionary:
	return {
		"id":"iron-irregular-field",
		"resource_id":"iron_ore",
		"resource_name":"Iron Ore",
		"resource_color":"#d5a45c",
		"shape":"IRREGULAR",
		"seed":27,
		"grade":1.0,
		"footprint":_footprint(Vector2i(32, 20), Vector2i(56, 56))
	}


func _mine_building() -> Dictionary:
	return {
		"id":"grid_surface_mine",
		"name":"Surface Mine",
		"kind":"EXTRACTOR",
		"footprint":{"width":3, "height":3},
		"resource_categories":["solid"],
		"recipe_ids":[]
	}


func _entity_record() -> Dictionary:
	return {
		"id":"finished-mine",
		"definition_id":"grid_surface_mine",
		"name":"Surface Mine",
		"node_kind":"EXTRACTOR",
		"footprint":_footprint(BUILDING_ORIGIN, Vector2i(3, 3)),
		"status":"READY",
		"power_factor":1.0,
		"actual_rate":0.0,
		"road_connected":true,
		"ports":{"inputs":[], "outputs":[], "accepts_power":false, "provides_power":false},
		"inputs":{}, "outputs":{}, "inventory":{}
	}


func _ghost_record() -> Dictionary:
	return {
		"id":"awaiting-smelter",
		"definition_id":"grid_arc_smelter",
		"building_name":"Arc Smelter",
		"footprint":_footprint(GHOST_ORIGIN, Vector2i(6, 5)),
		"status":"WAITING_BUILDING",
		"progress":0.0,
		"deployment_item_id":"building_grid_arc_smelter",
		"required_items":{"building_grid_arc_smelter":1},
		"delivered_items":{}
	}


func _footprint(origin: Vector2i, extent: Vector2i) -> Dictionary:
	return {"origin":{"x":origin.x, "y":origin.y}, "size":{"x":extent.x, "y":extent.y}}


func _footprint_is_inside_irregular_field(field: Dictionary, footprint: Dictionary) -> bool:
	var origin: Dictionary = footprint.get("origin", {}) as Dictionary
	var size: Dictionary = footprint.get("size", {}) as Dictionary
	for y in range(int(origin.get("y", 0)), int(origin.get("y", 0)) + int(size.get("y", 0))):
		for x in range(int(origin.get("x", 0)), int(origin.get("x", 0)) + int(size.get("x", 0))):
			if not Terrain.field_contains(field, Vector2i(x, y)):
				return false
	return true


func _settle() -> void:
	for _frame in range(4):
		await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_VISUAL_LAYERS_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
