extends SceneTree

const Workspace = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const Terrain = preload("res://src/core/factory_terrain.gd")
const Renderer = preload("res://src/ui/workspaces/factory/factory_terrain_renderer.gd")
const Canvas = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game: Node = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	game.state = SpaceGameState.create_new(game.content.domains.keys(),game.content.regions)
	game.simulation = SimulationEngine.new(game.content)
	game.simulation.ensure_frontier_state(game.state)
	var world: Dictionary = game.state.factory_worlds["earth-surface-grid"]
	var snapshot: Dictionary = game.factory_workspace_snapshot("earth-surface-grid")
	_check(snapshot.get("landing_required",false) and snapshot["palette"]["buildings"].size() == 1, "landing initially exposes only the core")
	_check(snapshot["bounds"]["size"] == {"x":1024,"y":640}, "Earth uses its larger finite logical extent")
	_check(snapshot["resource_fields"].size() > 10, "ore patches are scattered across the map")
	var first: Dictionary = world["resource_fields"]["starter-iron-field"]
	_check(not Terrain.field_contains(first,Vector2i(32,32)) and Terrain.field_contains(first,Vector2i(47,47)), "starter deposit has irregular corners and a usable mining core")
	world["tile_deltas"]["8:8"] = {"terrain_override":"WATER"}
	var before: Dictionary = game.state.to_dictionary().duplicate(true)
	var blocked: Dictionary = game.execute_factory_command({"protocol_version":1,"command_id":"landing-water","kind":"DEPLOY_BUILDING","world_id":"earth-surface-grid","base_topology_revision":int(world["topology_revision"]),"payload":{"definition_id":"grid_planetary_core","origin":{"x":8,"y":8}}})
	_check(not blocked.get("accepted",false) and blocked.get("reason_code") == "TERRAIN_BLOCKED" and game.state.to_dictionary() == before, "core cannot land on water and failed placement is atomic")
	world["tile_deltas"].clear()
	var host := Control.new()
	host.size = Vector2(1920,1080)
	root.add_child(host)
	var workspace := Workspace.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.apply_snapshot(game.factory_workspace_snapshot("earth-surface-grid"))
	await _settle()
	var canvas: Control = workspace.canvas()
	var renderer: RefCounted = canvas.get("_terrain_renderer")
	_check(renderer.call("has_art"), "generated terrain atlas is loaded by the canvas")
	_check(str(workspace.get("_selected_building_id")) == "grid_planetary_core", "landing tool is selected without deploying at an arbitrary default tile")
	_check(renderer.get("last_visible_chunks") > 0 and renderer.call("cached_chunk_count") <= Renderer.MAX_CACHED_CHUNKS, "only visible terrain chunks are built under a fixed cache budget")
	var meshes_before: int = renderer.get("mesh_build_count")
	canvas.queue_redraw()
	await _settle()
	_check(renderer.get("mesh_build_count") == meshes_before, "stationary viewport reuses cached meshes")
	canvas.focus_tile(Vector2i(700,420))
	await _settle()
	_check(renderer.get("mesh_build_count") > meshes_before and renderer.call("cached_chunk_count") <= Renderer.MAX_CACHED_CHUNKS, "panning prepares newly visible chunks without loading the entire planet")
	canvas.reset_camera()
	await _settle()
	_check(canvas.size.x * canvas.size.y / pow(canvas._tile_scale(), 2) <= float(Canvas.MAX_VISIBLE_CAMERA_TILES) + 1.0 and renderer.call("cached_chunk_count") <= Renderer.MAX_CACHED_CHUNKS, "reset view keeps the visible-tile and terrain-cache budgets instead of fitting the planet")
	var field_meshes_after_reset: int = renderer.get("field_mesh_build_count")
	canvas.queue_redraw()
	await _settle()
	_check(int(renderer.get("field_mesh_build_count")) == field_meshes_after_reset, "stationary limited view reuses irregular deposit meshes")
	if OS.get_cmdline_user_args().has("--capture"):
		canvas.set("_zoom",1.8)
		canvas.focus_tile(Vector2i(80,48))
		await _settle()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/helios-planetary-landing.png")
	workspace.queue_free()
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_LANDING_TERRAIN_UI_PASS")
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
