extends SceneTree

## Render the current finished-building/road startup through application commands.
## Opt-in evidence only; never read or write the player's save.
const WORLD := "earth-surface-grid"
var game: Node
var serial := 0
var output_root := "res://artifacts/ui/factory-visuals"
var failures: Array[String] = []
var stay_open := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if str(argument) == "--stay-open":
			stay_open = true
		if str(argument).begins_with("--evidence-output="):
			output_root = str(argument).trim_prefix("--evidence-output=")
	root.size = Vector2i(3840, 2160)
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	root.get_node("I18n").set_locale("zh_CN")
	game.reset_game()
	for entry in [
		["grid_planetary_core", Vector2i(110,32), ""],
		["grid_surface_mine", Vector2i(42,42), ""],
		["grid_surface_mine", Vector2i(82,42), ""],
		["grid_arc_smelter", Vector2i(8,61), "grid_refine_iron"],
		["grid_arc_smelter", Vector2i(28,61), "grid_refine_copper"],
		["grid_engineering_works", Vector2i(52,61), "grid_fabricate_electronics"]
	]:
		_command("DEPLOY_BUILDING", {"definition_id":entry[0], "origin":{"x":entry[1].x,"y":entry[1].y}, "recipe_id":entry[2]})
	var tiles: Array = []
	for x in range(8,110):
		tiles.append({"x":x,"y":60})
	for x in [42,82]:
		for y in range(53,60):
			tiles.append({"x":x,"y":y})
	for y in range(32,60):
		tiles.append({"x":109,"y":y})
	_command("BUILD_ROAD", {"tiles":tiles,"tier":1})
	_command("DEPLOY_BUILDING", {"definition_id":"grid_surface_mine", "origin":{"x":30,"y":45}})
	var main: Control = load("res://src/ui/main.tscn").instantiate()
	root.add_child(main)
	await _settle()
	main.find_child("Navigation_industry", true, false).pressed.emit()
	await _settle()
	var workspace: Control = main.find_child("FactoryWorkspace", true, false)
	workspace.call("_set_active_subworkspace", "CANVAS")
	await _settle()
	var canvas: Control = workspace.canvas()
	canvas.set("_zoom", 2.5)
	canvas.focus_tile(Vector2i(72,46))
	canvas.clear_placement_preview()
	game.set_process(true)
	await _capture("01-factory")
	workspace.call("_select_building_id", "grid_surface_mine")
	workspace.set("_preview_tile", Vector2i(42,42))
	workspace.call("_update_placement_preview")
	await _capture("02-placement-on-ore")
	canvas.set("_zoom", 2.5)
	canvas.focus_tile(Vector2i(48,43))
	await _capture("03-close-placement")
	workspace.call("_on_placement_cancelled")
	canvas.clear_placement_preview()
	canvas.set("_zoom", 3.2)
	canvas.focus_tile(Vector2i(49,48))
	for entity in game.factory_workspace_snapshot(WORLD).entities:
		if entity.definition_id == "grid_surface_mine" and int(entity.footprint.origin.x) == 42:
			var footprint: Rect2 = canvas.call("_footprint_rect",entity.footprint)
			canvas.call("_select_at",footprint.get_center())
			if str(canvas.selected_node_id()) != str(entity.id):
				failures.append("Real canvas selection failed for the circular mining preview")
			break
	await _capture("04-core-extractor-selected")
	# Inspect the actual mineral field at a free ore tile, outside the miner.
	canvas.call("_select_at", canvas.call("_world_to_screen", Vector2(38.5,43.5)))
	await _capture("05-mineral-inspector")
	var terrain = load("res://src/core/factory_terrain.gd")
	var world_snapshot: Dictionary = game.factory_workspace_snapshot(WORLD)
	var geography_focus := Vector2i(-1,-1)
	for y in range(112,560,16):
		for x in range(160,960,16):
			if terrain.terrain_type(world_snapshot, Vector2i(x,y)) == "WATER":
				geography_focus = Vector2i(x,y)
				break
		if geography_focus.x >= 0:
			break
	if geography_focus.x >= 0:
		canvas.set("_zoom", 2.2)
		canvas.focus_tile(geography_focus)
		await _capture("06-natural-geography")
	canvas.reset_camera()
	await _capture("07-planet-survey")
	if stay_open and failures.is_empty():
		canvas.set("_zoom", 3.2)
		canvas.focus_tile(Vector2i(49,48))
		for entity in game.factory_workspace_snapshot(WORLD).entities:
			if entity.definition_id == "grid_surface_mine" and int(entity.footprint.origin.x) == 42:
				canvas.call("_select_at", canvas.call("_footprint_rect", entity.footprint).get_center())
				break
		root.title = "Helios Factory / Natural Terrain & Core Extractor"
		print("FACTORY_CORE_EXTRACTOR_PREVIEW_READY")
		return
	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_VISUAL_CAPTURE_PASS: ", output_root)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _command(kind: String, payload: Dictionary) -> void:
	serial += 1
	var world: Dictionary = game.state.factory_worlds[WORLD]
	var response: Dictionary = game.execute_factory_command({"protocol_version":1,"command_id":"visual-%d" % serial,"kind":kind,"world_id":WORLD,"base_topology_revision":int(world.topology_revision),"payload":payload})
	if not bool(response.get("accepted",false)):
		failures.append("Setup command failed: %s %s" % [kind,response.get("reason_code","")])

func _settle() -> void:
	for frame in range(5):
		await process_frame

func _capture(name: String) -> void:
	await _settle()
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(output_root.path_join(name + ".png"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var picture := root.get_texture().get_image()
	if picture.get_size() != Vector2i(3840,2160) or picture.save_png(path) != OK:
		failures.append("4K capture failed: " + path)
	print("CAPTURE: ",path)
