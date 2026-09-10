extends SceneTree

var failures: Array[String] = []
var game: Node
const WORLD := "earth-surface-grid"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.set_process(false)
	game.persistence_enabled = false
	game.state = SpaceGameState.create_new(game.content.domains.keys(), game.content.regions)
	game.simulation = SimulationEngine.new(game.content)
	game.simulation.ensure_frontier_state(game.state)
	var before: Dictionary = game.state.to_dictionary().duplicate(true)
	var guidance: Dictionary = game.guidance_snapshot()
	var dashboard: Dictionary = game.location_operations_snapshot("earth_orbit")
	_check(guidance.get("step_id") == "deploy_planetary_core", "guidance starts with player-selected core deployment")
	_check(dashboard.get("landing_required", false) and dashboard.get("hero_definition_id") == "grid_planetary_core", "empty home dashboard shows the actual landing core")
	_check(dashboard["task_empty_action"].get("section") == "CANVAS" and dashboard["task_empty_action"].get("definition_id") == "grid_planetary_core", "empty tasks lead to landing, not a retired work queue")
	_check(game.state.to_dictionary() == before, "guidance and dashboard reads do not grant items or mutate gameplay")
	var result: Dictionary = game.execute_factory_command({
		"protocol_version":1, "command_id":"sync-core", "kind":"DEPLOY_BUILDING",
		"world_id":WORLD, "base_topology_revision":game.state.factory_worlds[WORLD].get("topology_revision", 0),
		"payload":{"definition_id":"grid_planetary_core", "origin":{"x":110, "y":32}}
	})
	_check(result.get("accepted", false), "real application command deploys the core")
	_check(game.guidance_snapshot().get("step_id") == "deploy_starter_grid_surface_mine", "landing advances guidance to stocked mining equipment")
	dashboard = game.location_operations_snapshot("earth_orbit")
	_check(not dashboard.get("landing_required", true) and dashboard.get("hero_definition_id") == "grid_planetary_core", "deployed core remains the real dashboard facility")
	var world: Dictionary = game.state.factory_worlds[WORLD]
	# Legacy custody is migrated once by the application, never counted twice.
	var core: Dictionary = world["entities"].values()[0]
	core["inventory"] = {"iron_ore":99}
	game.state.location_inventory("earth_orbit")["iron_ore"] = 7
	dashboard = game.location_operations_snapshot("earth_orbit")
	var rows: Array = dashboard["inventory"].filter(func(row): return row.get("id") == "iron_ore")
	_check(rows.size() == 1 and int(rows[0].get("quantity", -1)) == 106 and int(rows[0].get("warehouse_quantity", -1)) == 0, "migrated stock is displayed once, solely in Location inventory: %s" % [rows])
	dashboard = game.location_operations_snapshot("earth_orbit")
	rows = dashboard["inventory"].filter(func(row): return row.get("id") == "iron_ore")
	_check(int(rows[0].get("quantity", -1)) == 106, "subsequent reads do not repeat the legacy custody transfer")
	var solar: Dictionary = game.content.factory_buildings["grid_dsp_solar_panel"]
	var nominal := float(solar.get("power_generation_kw", 0.0))
	var grid: FactoryGridSimulation = game.simulation.factory_grid
	var isolated := grid.create_world("sync-solar", "", Vector2i(128, 128))
	isolated["environment"] = {"solar_flux":0.0}
	_check(nominal > 0.0 and is_zero_approx(grid.effective_generation_kw(isolated, solar)), "actual imported DSP solar panel stops without sunlight")
	isolated["environment"] = {"solar_flux":4.0}
	_check(is_equal_approx(grid.effective_generation_kw(isolated, solar), nominal * 2.0), "imported DSP solar follows the shared environment rule")
	var core_definition: Dictionary = game.content.factory_buildings["grid_planetary_core"]
	_check(is_equal_approx(grid.effective_generation_kw(isolated, core_definition), 400.0), "core power is not incorrectly boosted by solar flux")
	for locale in ["en", "zh_CN"]:
		root.get_node("I18n").current_locale = locale
		for key in ["deploy_core", "deploy_building", "connect_roads", "prepare_frame", "assemble_frame", "commission_research"]:
			_check(root.get_node("I18n").core("guidance.start." + key, "MISSING") != "MISSING", "startup guidance is localized: %s/%s" % [locale, key])
	if OS.get_cmdline_user_args().has("--capture"):
		await _capture_real_location()
	if failures.is_empty():
		print("CONTENT_SYNC_FLOW_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _capture_real_location() -> void:
	# Optional normal-render evidence uses a fresh real game, not UI fixtures.
	game.reset_game()
	game.set_process(false)
	root.size = Vector2i(3840, 2160)
	var main: Control = (load("res://src/ui/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	main.call("_open_location", "earth_orbit")
	await main.call("_set_capture_viewport_size", Vector2i(3840, 2160))
	for frame in range(8):
		await process_frame
	await RenderingServer.frame_post_draw
	var capture := main.get_viewport().get_texture().get_image()
	_check(capture.get_size() == Vector2i(3840, 2160), "capture has actual 4K pixels")
	_check(capture.save_png("/tmp/helios-content-sync-location-4k.png") == OK, "real 4K Location capture saves outside the repository")
	main.queue_free()
	await process_frame
