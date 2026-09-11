extends SceneTree

## Real application deployment through palette/canvas signals, followed by
## immutable flight snapshots for empty-flight and interpolation presentation.
const Workspace = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const Art = preload("res://src/ui/workspaces/factory/factory_drone_art.gd")
const ShipmentInspector = preload("res://src/ui/workspaces/factory/factory_shipment_inspector.gd")
const WORLD := "earth-surface-grid"
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	game.reset_game()
	var world: Dictionary = game.state.factory_worlds[WORLD]
	var core_result: Dictionary = game.execute_factory_command({"protocol_version":1, "command_id":"drone-ui-core", "kind":"DEPLOY_BUILDING", "world_id":WORLD, "base_topology_revision":int(world.topology_revision), "payload":{"definition_id":"grid_planetary_core", "origin":{"x":110,"y":32}}})
	_check(bool(core_result.get("accepted", false)), "core deployment opens the real Factory player path")
	# Fixture supplies one manufactured kit; UI must consume it via a command.
	game.state.location_inventory(str(world.location_id))["building_grid_drone_tower"] = 1
	var host := Control.new()
	host.size = Vector2(1920,1080)
	root.add_child(host)
	var workspace := Workspace.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.apply_snapshot(game.factory_workspace_snapshot(WORLD))
	workspace.call("_set_active_subworkspace", "CANVAS")
	await _settle()
	var canvas: Control = workspace.canvas()
	_check(workspace.find_child("FactoryRoadTools", true, false) == null, "road tools are absent from the player dock")
	_check(not canvas.has_signal("road_path_requested") and not canvas.has_method("set_road_tool"), "canvas cannot emit retired road construction gestures")
	_check(not bool(canvas.get("_port_connections_enabled")), "drone mode keeps manual cargo and power ports disabled")
	var palette: Control = workspace.find_child("FactoryBuildPalette", true, false)
	if palette != null:
		_check(bool(palette.call("_building_matches_filter", {"id":"grid_drone_tower", "kind":"STORAGE", "drone_tower":true}, "LOGISTICS")), "drone tower is discoverable in the Logistics category")
	var card := workspace.find_child("FactoryBuildCardGridDroneTower", true, false) as Button
	_check(card != null, "drone tower appears in the actual build palette")
	if card != null:
		var icon := card.find_child("FactoryBuildCardIcon", true, false) as TextureRect
		_check(icon != null and icon.texture == Art.icon_texture(), "tower palette loads the licensed tower sprite")
		card.pressed.emit()
	canvas.emit_signal("tile_hovered", Vector2i(150,40))
	await _settle()
	var preview: Dictionary = canvas.get("_placement_preview")
	_check(bool(preview.get("drone_tower", false)) and float(preview.get("drone_radius_tiles", 0)) == 64.0, "placement preview carries the exact circular service radius")
	var responses: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: responses.append(game.execute_factory_command(intent)))
	canvas.emit_signal("tile_selected", Vector2i(150,40))
	_check(responses.size() == 1 and bool(responses[0].get("accepted", false)), "palette and canvas placement reaches the real application deployment transaction")
	if not responses.is_empty():
		workspace.apply_command_result(responses[0])
	var snapshot: Dictionary = game.factory_workspace_snapshot(WORLD)
	var tower: Dictionary = {}
	for entity in snapshot.get("entities", []):
		if str(entity.get("definition_id", "")) == "grid_drone_tower":
			tower = entity
	_check(not tower.is_empty(), "the tower is a completed entity after the UI command")
	workspace.apply_snapshot(snapshot)
	workspace.call("_on_placement_cancelled")
	canvas.set("_zoom", 0.6)
	canvas.focus_tile(Vector2i(153,43))
	await _settle()
	canvas.call("_select_at", canvas.call("_world_to_screen", Vector2(153,43)))
	_check(str(canvas.get("_selected_node_id")) == str(tower.get("id", "")), "clicking the placed tower selects the circle's actual entity")
	await _settle()
	var rows := [
		{"id":"empty-pickup", "tower_id":str(tower.get("id", "")), "source_id":"producer", "target_id":"", "item_id":"iron_ingot", "quantity":0, "phase":"TO_PICKUP", "status":"TRAVEL", "position":{"x":140.0,"y":43.0}, "heading":0.0, "progress":0.25},
		{"id":"empty-return", "tower_id":str(tower.get("id", "")), "source_id":"producer", "target_id":str(tower.get("id", "")), "item_id":"iron_ingot", "quantity":0, "phase":"RETURNING", "status":"TRAVEL", "position":{"x":142.0,"y":48.0}, "heading":PI, "progress":0.5}
	]
	snapshot["drone_shipments"] = rows
	snapshot["runtime_revision"] = int(snapshot.get("runtime_revision", 0)) + 1
	workspace.apply_snapshot(snapshot)
	await _settle()
	_check((canvas.call("_visible_shipment_ids") as Array).size() == 2, "empty pickup and return flights remain visible without ground paths or cargo")
	var inspector := ShipmentInspector.new()
	inspector.configure(snapshot,tower)
	_check(inspector.shipment_rows().size() == 2, "tower inspector includes all its owned flights even before a destination exists")
	_check(str(inspector.call("_phase", rows[0])) == "TO_PICKUP" and str(inspector.call("_phase", rows[1])) == "RETURNING", "inspector distinguishes collection from returning empty")
	inspector.free()
	var next: Dictionary = snapshot.duplicate(true)
	next["drone_shipments"][0]["position"] = {"x":148.0,"y":43.0}
	next["runtime_revision"] += 1
	workspace.apply_snapshot(next)
	canvas.set_process(false)
	canvas.set("_shipment_blend_elapsed",0.125)
	var middle: Vector2 = canvas.call("_cargo_world_position", next["drone_shipments"][0])
	_check(middle.x >= 140.0 and middle.x <= 148.0, "flight interpolation stays between two observed positions")
	canvas.set("_shipment_blend_elapsed",2.0)
	_check(is_equal_approx((canvas.call("_cargo_world_position",next["drone_shipments"][0]) as Vector2).x,148.0), "stale snapshots never extrapolate a drone past the real position")
	if DisplayServer.get_name() != "headless":
		root.size = Vector2i(3840,2160)
		canvas.queue_redraw()
		await _settle()
		await RenderingServer.frame_post_draw
		var capture_path := OS.get_environment("TEMP").path_join("helios-factory-drone-ui.png")
		_check(root.get_texture().get_image().save_png(capture_path) == OK, "rendered tower coverage and empty drone capture saved")
		print("DRONE_UI_CAPTURE=" + capture_path)
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS: factory_drone_ui_test")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _settle() -> void:
	for index in range(4):
		await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
