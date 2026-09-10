extends SceneTree

## Focused presentation contract for shared planet roads. It uses immutable
## snapshot data and asserts only UI intents; no Game or simulation authority is
## instantiated here.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Control.new()
	host.name = "FactoryRoadWorkspaceTestHost"
	host.size = Vector2(1920, 1080)
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.apply_snapshot(_fixture())
	workspace.call("_set_active_subworkspace", "CANVAS")
	await _settle()
	_check(workspace.canvas().get("_road_surface") is Texture2D, "generated road artwork is loaded instead of relying on placeholder geometry")
	workspace.call("_on_entity_selected", _entity("storage-a", "STORAGE", "Bulk Depot", Vector2i(30, 30), true, {"iron_ingot":7}))
	await _settle()

	var intents: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	_test_road_mode_chrome(workspace)
	_test_road_order_funding(workspace, intents)
	await _test_road_draw_and_remove_dispatch(workspace, intents)
	await _test_road_cancel_returns_blank_left_pan(workspace, intents)
	_test_finite_index_and_fixed_bottom_bar(workspace)
	if OS.get_cmdline_user_args().has("--road-screenshot"):
		await _capture_road_scene(workspace)

	workspace.queue_free()
	await process_frame
	host.queue_free()
	await process_frame
	_finish()


func _test_road_mode_chrome(workspace) -> void:
	var connection_panel := workspace.find_child("FactoryConnectionAssist", true, false) as Control
	var road_tools := workspace.find_child("FactoryRoadTools", true, false) as Control
	var tier_one := workspace.find_child("FactoryRoadTierOne", true, false) as Button
	var tier_two := workspace.find_child("FactoryRoadTierTwo", true, false) as Button
	var remove := workspace.find_child("FactoryRoadRemove", true, false) as Button
	var cost_label := workspace.find_child("FactoryRoadCost", true, false) as Label
	var transfer_item: Node = workspace.find_child("StorageTransferItem", true, false)
	var shared_inventory: Node = workspace.find_child("RoadSharedInventory", true, false)
	_check(
		connection_panel != null and not connection_panel.visible
		and road_tools != null and road_tools.visible
		and tier_one != null and tier_two != null and remove != null
		and transfer_item == null and shared_inventory != null,
		"road snapshots replace port wiring and individual storage transfers with bottom-bar road tools and a read-only inspector"
	)
	_check(
		tier_one != null and tier_two != null and tier_one.tooltip_text != tier_two.tooltip_text
		and cost_label != null and not cost_label.text.is_empty(),
		"bootstrap road costs distinguish free basic roads from one-iron reinforced roads"
	)


func _capture_road_scene(workspace) -> void:
	var visual := _fixture()
	visual["topology_revision"] = 18
	visual["roads"] = []
	for x in range(30, 52):
		visual["roads"].append({"x":x, "y":34, "tier":1 if x < 40 else 2})
	workspace.apply_snapshot(visual)
	workspace.call("_on_placement_cancelled")
	workspace.canvas().reset_camera()
	for _step in range(8):
		workspace.canvas().call("_adjust_zoom", 1.14)
	workspace.canvas().focus_tile(Vector2i(40, 33))
	workspace.call("_on_entity_selected", visual["entities"][0])
	await _settle()
	await RenderingServer.frame_post_draw
	var screenshot := root.get_texture().get_image()
	_check(screenshot.save_png("/tmp/planet-road-workspace.png") == OK, "road workspace screenshot captured")


func _test_road_draw_and_remove_dispatch(workspace, intents: Array) -> void:
	var canvas = workspace.canvas()
	var tier_one := workspace.find_child("FactoryRoadTierOne", true, false) as Button
	var tier_two := workspace.find_child("FactoryRoadTierTwo", true, false) as Button
	var remove := workspace.find_child("FactoryRoadRemove", true, false) as Button
	if tier_one != null:
		tier_one.pressed.emit()
	await _settle()
	_check(str(workspace.get("_active_tool")) == "ROAD_BUILD" and str(canvas.call("road_tool_mode")) == "BUILD", "basic road button enters canvas road-draw mode")
	var before_build := intents.size()
	_draw_drag(canvas, Vector2i(6, 8), Vector2i(10, 11))
	_check(intents.size() == before_build + 1, "releasing a road drag emits exactly one batch command")
	if intents.size() > before_build:
		var intent := intents.back() as Dictionary
		var payload: Dictionary = intent.get("payload", {}) as Dictionary
		var tiles: Array = payload.get("tiles", []) as Array
		_check(
			str(intent.get("kind", "")) == "BUILD_ROAD"
			and int(payload.get("tier", 0)) == 1
			and tiles.size() == 8
			and _tile_at(tiles, 0) == Vector2i(6, 8)
			and _tile_at(tiles, tiles.size() - 1) == Vector2i(10, 11),
			"road drawing submits a cardinal Manhattan tile sequence through the stable BUILD_ROAD boundary"
		)
	if tier_two != null:
		tier_two.pressed.emit()
	await _settle()
	var before_tier_two := intents.size()
	_draw_drag(canvas, Vector2i(20, 8), Vector2i(21, 8))
	if intents.size() > before_tier_two:
		var reinforced := intents.back() as Dictionary
		_check(str(reinforced.get("kind", "")) == "BUILD_ROAD" and int((reinforced.get("payload", {}) as Dictionary).get("tier", 0)) == 2, "reinforced road tool preserves tier 2 in the batch payload")
	if remove != null:
		remove.pressed.emit()
	await _settle()
	var before_remove := intents.size()
	_draw_drag(canvas, Vector2i(6, 8), Vector2i(7, 8))
	if intents.size() > before_remove:
		var removal := intents.back() as Dictionary
		var removal_payload: Dictionary = removal.get("payload", {}) as Dictionary
		_check(str(removal.get("kind", "")) == "REMOVE_ROAD" and removal_payload.has("tiles") and not removal_payload.has("tier"), "road removal emits the canonical tier-free REMOVE_ROAD payload")


func _test_road_order_funding(workspace, intents: Array) -> void:
	workspace.call("_on_construction_order_selected", {
		"id":"road-build", "definition_id":"grid_bulk_depot", "building_name":"Bulk Depot",
		"status":"WAITING_MATERIALS", "progress":0.0, "required_items":{"iron_ingot":2}, "delivered_items":{},
		"footprint":{"origin":{"x":70, "y":70}, "size":{"x":4, "y":4}}
	})
	var storage_selector: Node = workspace.find_child("FundingStorage", true, false)
	var fund_from_shared := workspace.find_child("FundConstructionFromSharedInventory", true, false) as Button
	var before := intents.size()
	if fund_from_shared != null:
		fund_from_shared.pressed.emit()
	_check(storage_selector == null and fund_from_shared != null, "road construction orders do not offer a per-storage funding selector")
	if intents.size() > before:
		var intent := intents.back() as Dictionary
		_check(str(intent.get("kind", "")) == "FUND_CONSTRUCTION_FROM_LOCATION", "road construction funding uses the existing shared-location command only")


func _test_road_cancel_returns_blank_left_pan(workspace, intents: Array) -> void:
	var canvas = workspace.canvas()
	workspace.call("_on_placement_cancelled")
	canvas.reset_camera()
	for _step in range(24):
		canvas.call("_adjust_zoom", 1.14)
	canvas.focus_tile(Vector2i(100, 80))
	await process_frame
	var start: Vector2 = canvas.size * 0.5 + Vector2(18, 14)
	var before_camera: Vector2 = canvas.get("_camera")
	var before_intents := intents.size()
	canvas.call("_on_gui_input", _left_button(start, true))
	canvas.call("_on_gui_input", _mouse_motion(start + Vector2(42, 26)))
	canvas.call("_on_gui_input", _left_button(start + Vector2(42, 26), false))
	var after_camera: Vector2 = canvas.get("_camera")
	_check(
		str(canvas.call("road_tool_mode")).is_empty()
		and after_camera.distance_to(before_camera) > 20.0
		and intents.size() == before_intents,
		"cancelling a road tool preserves normal blank-left-drag panning without emitting a road command"
	)


func _test_finite_index_and_fixed_bottom_bar(workspace) -> void:
	var canvas = workspace.canvas()
	var roads_by_id: Dictionary = canvas.get("_roads_by_id") as Dictionary
	var index = canvas.get("_chunk_index")
	var visible: Dictionary = index.query(Rect2(Vector2(0, 0), Vector2(64, 64)))
	var palette := workspace.find_child("FactoryBuildPalette", true, false) as Control
	var center := workspace.find_child("FactoryCenterColumn", true, false) as Control
	_check(
		roads_by_id.size() == 3 and (visible.get("road_ids", []) as Array).size() == 3
		and palette != null and center != null
		and palette.get_global_rect().end.y <= center.get_global_rect().end.y + 0.5,
		"road coordinates are indexed by finite-world chunks and the 1920 logical bottom bar remains inside the Factory center column"
	)


func _draw_drag(canvas, start_tile: Vector2i, end_tile: Vector2i) -> void:
	var start := canvas.call("_world_to_screen", Vector2(start_tile) + Vector2.ONE * 0.5) as Vector2
	var finish := canvas.call("_world_to_screen", Vector2(end_tile) + Vector2.ONE * 0.5) as Vector2
	canvas.call("_on_gui_input", _left_button(start, true))
	canvas.call("_on_gui_input", _mouse_motion(finish))
	canvas.call("_on_gui_input", _left_button(finish, false))


func _tile_at(tiles: Array, index: int = 0) -> Vector2i:
	if tiles.is_empty() or index < 0 or index >= tiles.size() or not tiles[index] is Dictionary:
		return Vector2i(-1, -1)
	var tile := tiles[index] as Dictionary
	return Vector2i(int(tile.get("x", -1)), int(tile.get("y", -1)))


func _left_button(point: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = point
	return event


func _mouse_motion(point: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = point
	return event


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"road-ui-grid",
		"location_name":"Earth",
		"topology_revision":17,
		"runtime_revision":9,
		"logistics_mode":"PLANET_SHARED_ROADS",
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":256, "y":160}},
		"canvas_limits":{"max_world_size_tiles":{"x":256, "y":160}},
		"chunk_size_tiles":64,
		"roads":[{"x":4, "y":4, "tier":1}, {"x":5, "y":4, "tier":1}, {"x":6, "y":4, "tier":2}],
		"road_logistics":{"capacity":12, "required":5, "utilization":0.42, "active_shipments":2},
		"shared_inventory":{"iron_ingot":7, "iron_ore":3},
		"item_names":{"iron_ingot":"Iron ingot", "iron_ore":"Iron ore"},
		"entities":[
			_entity("storage-a", "STORAGE", "Bulk Depot", Vector2i(30, 30), true, {"iron_ingot":7}),
			_entity("mine-a", "EXTRACTOR", "Surface Mine", Vector2i(48, 30), false)
		],
		"links":[],
		"resource_fields":[],
		"construction_orders":[{"id":"road-build", "definition_id":"grid_bulk_depot", "footprint":{"origin":{"x":70, "y":70}, "size":{"x":4, "y":4}}, "status":"WAITING_MATERIALS", "progress":0.0, "required_items":{"iron_ingot":2}, "delivered_items":{}}],
		"palette":{"buildings":[
			{"id":"grid_surface_mine", "name":"Surface Mine", "kind":"EXTRACTOR", "footprint":{"width":3, "height":3}, "resource_categories":["solid"], "recipe_ids":[]},
			{"id":"grid_bulk_depot", "name":"Bulk Depot", "kind":"STORAGE", "footprint":{"width":4, "height":4}, "recipe_ids":[]}
		], "recipes":[]}
	}


func _entity(entity_id: String, kind: String, title: String, origin: Vector2i, road_connected: bool, inventory: Dictionary = {}) -> Dictionary:
	return {
		"id":entity_id,
		"node_kind":kind,
		"name":title,
		"definition_id":"grid_bulk_depot" if kind == "STORAGE" else "grid_surface_mine",
		"footprint":{"origin":{"x":origin.x, "y":origin.y}, "size":{"x":4, "y":4}},
		"status":"READY",
		"power_factor":0.5 if not road_connected else 1.0,
		"actual_rate":0.0,
		"road_connected":road_connected,
		"road_component_id":"road-main" if road_connected else "",
		"ports":{"inputs":[], "outputs":[], "accepts_power":false, "provides_power":false},
		"inputs":{}, "outputs":{}, "inventory":inventory,
		"shared_inventory":{"iron_ingot":7} if kind == "STORAGE" else {}
	}


func _settle() -> void:
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_ROAD_WORKSPACE_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
