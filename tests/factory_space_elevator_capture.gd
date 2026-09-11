extends SceneTree

## Production deployment and workspace visual acceptance. No player save writes.
const Workspace = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const Art = preload("res://src/ui/workspaces/factory/factory_space_elevator_art.gd")
const WORLD := "earth-surface-grid"
var game: Node
var serial := 0
var failed := false

func _initialize() -> void:
	call_deferred("_run")

func _deploy(definition: String, origin: Vector2i) -> void:
	serial += 1
	game.state.location_inventory("earth_orbit")["building_" + definition] = 1
	var world: Dictionary = game.state.factory_worlds[WORLD]
	var result: Dictionary = game.execute_factory_command({"protocol_version":1,"command_id":"elevator-capture-%d" % serial,"kind":"DEPLOY_BUILDING","world_id":WORLD,"base_topology_revision":int(world.topology_revision),"payload":{"definition_id":definition,"origin":{"x":origin.x,"y":origin.y}}})
	if not bool(result.get("accepted", false)) or not bool(result.get("result", {}).get("deployed", false)):
		failed = true
		push_error(str(result))

func _run() -> void:
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	game.reset_game()
	# Unlock only this ephemeral visual fixture; player progression is never saved.
	for technology_id in game.content.technologies:
		game.state.technologies[technology_id] = true
	_deploy("grid_planetary_core", Vector2i(80,82))
	_deploy("grid_arc_smelter", Vector2i(54,83))
	_deploy("grid_engineering_works", Vector2i(112,88))
	_deploy("grid_dsp_oil_refinery", Vector2i(118,58))
	_deploy("grid_dsp_chemical_plant", Vector2i(52,56))
	_deploy("grid_dsp_thermal_power_plant", Vector2i(85,56))
	if failed:
		quit(1)
		return
	var snapshot: Dictionary = game.factory_workspace_snapshot(WORLD)
	var core_id := ""
	for entity in snapshot.entities:
		if str(entity.definition_id) == "grid_planetary_core":
			core_id = str(entity.id)
	assert(not core_id.is_empty())
	var host := Control.new()
	host.size = Vector2(1920,1080)
	root.add_child(host)
	var workspace := Workspace.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.apply_snapshot(snapshot)
	workspace.call("_set_active_subworkspace", "CANVAS")
	for index in 6:
		await process_frame
	var canvas: Control = workspace.canvas()
	canvas.set_process(false)
	canvas.set("_zoom", 1.1)
	canvas.focus_tile(Vector2i(90,83))
	canvas.call("_select_at", canvas.call("_world_to_screen", Vector2(90,92)))
	root.size = Vector2i(3840,2160)
	var directory := "res://artifacts/ui/space-elevator"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	for phase in [0.0, 0.5]:
		canvas.set("_elevator_animation_seconds", {core_id:phase})
		canvas.queue_redraw()
		for index in 5:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := directory + "/production-%02d.png" % roundi(phase * 10)
		var image := root.get_texture().get_image()
		assert(image.save_png(path) == OK)
		assert(image.save_jpg(path.replace(".png", ".jpg"), 0.94) == OK)
	assert(Art.errors().is_empty(), str(Art.errors()))
	if OS.get_cmdline_user_args().has("--animation"):
		root.size = Vector2i(1920,1080)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory + "/animation"))
		for frame in Art.frame_count():
			canvas.set("_elevator_animation_seconds", {core_id:float(frame) * Art.cycle_seconds() / Art.frame_count()})
			canvas.queue_redraw()
			await process_frame
			await RenderingServer.frame_post_draw
			assert(root.get_texture().get_image().save_jpg(directory + "/animation/%03d.jpg" % frame, 0.95) == OK)
	print("FACTORY_SPACE_ELEVATOR_PRODUCTION_CAPTURE_PASS")
	host.queue_free()
	await process_frame
	quit(0)
