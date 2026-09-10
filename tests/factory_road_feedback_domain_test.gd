extends SceneTree

const Transport = preload("res://src/core/factory_road_transport.gd")
const OperationsProjection = preload("res://src/core/factory_operations_projection.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_detached_task_projection()
	_test_shared_stock_projection()
	_test_actual_building_online_delivery()
	if OS.get_cmdline_user_args().has("--feedback-screenshot"):
		await _capture_feedback()
	if failures.is_empty():
		print("FACTORY_ROAD_FEEDBACK_DOMAIN_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_detached_task_projection() -> void:
	var job := {"id":"job", "source_id":"mine", "target_id":"store", "source_kind":"ENTITY", "destination_kind":"WAREHOUSE", "item_id":"iron_ore", "cargo":{"iron_ore":1}, "status":"IN_TRANSIT", "travel_ms":2000.0, "remaining_ms":1000.0, "loading_remaining_ms":1000.0, "path_tiles":["0,0", "1,0", "1,1"]}
	var world := {"road_shipments":{"job":job}}
	var before := world.duplicate(true)
	var row: Dictionary = Transport.workspace_shipments(world, {})[0]
	_check(row["phase"] == "TRAVEL" and row["quantity"] == 1 and row["position"] == {"x":1.5, "y":0.5} and is_equal_approx(row["eta_ms"], 2000.0), "travel snapshot exposes real position, quantity and remaining transport/loading work")
	row["cargo"]["iron_ore"] = 99
	row["path_tiles"].clear()
	_check(world == before, "UI snapshot is detached and never changes transit custody")
	world["roads"] = {"0,0":{"tier":1},"1,0":{"tier":1},"1,1":{"tier":2}}
	row = Transport.workspace_shipments(world, {})[0]
	_check(is_equal_approx(row["position"]["x"], 1.25) and is_equal_approx(row["position"]["y"], 0.5), "mixed road tiers advance the cargo position by per-segment travel time")
	job["source_kind"] = "WAREHOUSE"
	job["remaining_ms"] = 2000.0
	row = Transport.workspace_shipments(world, {})[0]
	_check(row["phase"] == "LOADING" and row["position"] == {"x":0.5,"y":0.5}, "warehouse pickup stays at its road entrance while loading")
	job["source_kind"] = "ENTITY"
	job["remaining_ms"] = 0.0
	job["loading_remaining_ms"] = 500.0
	row = Transport.workspace_shipments(world, {})[0]
	_check(row["phase"] == "UNLOADING" and is_equal_approx(row["phase_progress"], 0.5) and row["position"] == {"x":1.5,"y":1.5}, "warehouse unloading has independent progress at the destination")
	for status in ["BLOCKED_PATH", "BLOCKED_TARGET_FULL", "BLOCKED_TARGET", "BLOCKED_MANIFEST"]:
		job["status"] = status
		row = Transport.workspace_shipments(world, {})[0]
		_check(row["phase"] == "BLOCKED" and row["status"] == status and row["eta_ms"] == -1.0, "blocked task %s has no misleading arrival countdown" % status)


func _test_shared_stock_projection() -> void:
	var snapshot := {"logistics_mode":"PLANET_SHARED_ROADS", "shared_inventory":{"iron_ore":17,"copper_ore":36}, "location_available_inventory":{"iron_ore":10,"copper_ore":36}, "entities":[{"id":"warehouse-a","node_kind":"STORAGE","status":"IDLE","inventory":{"iron_ore":99}}, {"id":"warehouse-b","node_kind":"STORAGE","status":"IDLE","inventory":{}}]}
	var result: Dictionary = OperationsProjection.build(snapshot)
	_check(result["metrics"]["stored_items"] == 53, "warehouse inventory KPI uses the planetary stock once, not empty or duplicated entity stock")
	for value in result["materials"]:
		var row: Dictionary = value
		if row["item_id"] == "iron_ore":
			_check(row["stored"] == 17 and row["available"] == 10, "on-hand stock and unreserved available stock remain distinct without double counting")


func _test_actual_building_online_delivery() -> void:
	var game = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	game.state = SpaceGameState.create_new(game.content.domains.keys(), game.content.regions)
	game.simulation = SimulationEngine.new(game.content)
	game.simulation.ensure_frontier_state(game.state)
	var world: Dictionary = game.state.factory_worlds["earth-surface-grid"]
	var grid = game.simulation.factory_grid
	grid.place_entity_immediate(world, "grid_planetary_core", Vector2i(110,32), "", "starter-depot")
	world["starter_package_delivered"] = true
	# Real content: 20x20 self-powered development core and 3x3 mines;
	# same route lengths as the reported player layout, no 1x1 test stand-ins.
	for entry in [["grid_surface_mine",Vector2i(52,52),"iron-mine"], ["grid_surface_mine",Vector2i(93,52),"copper-mine"]]:
		var placed: Dictionary = grid.place_entity_immediate(world, entry[0], entry[1], "", entry[2])
		if not placed.get("ok", false):
			_check(false, "real content fixture placement failed: %s" % str(placed))
			return
	var tiles: Array = []
	for x in range(52,110):
		tiles.append({"x":x,"y":55})
	for x in [109]:
		for y in range(32,55):
			tiles.append({"x":x,"y":y})
	_check(bool(grid.edit_roads(world, tiles).get("ok", false)), "real-size depot and mines connect along footprint edges")
	for _tick in range(600):
		game.advance_game_time(100.0)
	var snapshot: Dictionary = game.factory_workspace_snapshot("earth-surface-grid")
	_check(game.state.item_quantity("iron_ore","earth_orbit") > 0 and game.state.item_quantity("copper_ore","earth_orbit") > 0, "normal 100ms application updates deliver both ores into the shared warehouse")
	_check(not snapshot["road_shipments"].is_empty(), "actual application workspace exposes active road tasks")
	for item in ["iron_ore","copper_ore"]:
		var owned: int = game.state.item_quantity(item,"earth_orbit")
		for entity in world["entities"].values():
			owned += int(entity.get("outputs",{}).get(item,0))
		for job in world["road_shipments"].values():
			owned += int(job.get("cargo",{}).get(item,0))
		_check(owned == int(world["statistics"]["produced"][item]), "feedback does not change %s asset conservation" % item)
		for row in snapshot["operations"]["materials"]:
			if row["item_id"] == item:
				_check(row["stored"] == game.state.item_quantity(item,"earth_orbit"), "industrial Storage column matches actual %s stock" % item)


func _capture_feedback() -> void:
	var game = root.get_node("Game")
	var workspace = load("res://src/ui/workspaces/factory/factory_workspace.gd").new()
	root.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	workspace.apply_snapshot(game.factory_workspace_snapshot("earth-surface-grid"))
	workspace.call("_set_active_subworkspace", "CANVAS")
	for _frame in range(4):
		await process_frame
	workspace.canvas().call("_adjust_zoom", 1.5)
	workspace.canvas().focus_tile(Vector2i(83,33))
	workspace.call("_on_entity_selected", workspace.get("_snapshot")["entities"].filter(func(entity): return entity["id"] == "starter-depot")[0])
	for _tick in range(5):
		game.advance_game_time(100.0)
		workspace.apply_snapshot(game.factory_workspace_snapshot("earth-surface-grid"))
		await process_frame
	await RenderingServer.frame_post_draw
	_check(root.get_texture().get_image().save_png("/tmp/factory-road-feedback.png") == OK, "real-content transport inspector screenshot captured")
	workspace.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)
