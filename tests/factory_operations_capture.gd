extends SceneTree

## Opt-in rendered evidence for every Industrial view. Seed a real factory via
## application commands; never paint a mockup or modify a user's persisted game.
const WORLD := "earth-surface-grid"
var game: Node
var serial := 0
var output_root := "res://artifacts/ui/factory-overhaul"
var locale := "zh_CN"
var physical := Vector2i(3840, 2160)
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for value in OS.get_cmdline_user_args():
		var argument := str(value)
		if argument.begins_with("--evidence-locale="):
			locale = argument.get_slice("=", 1)
		elif argument.begins_with("--evidence-output="):
			output_root = argument.get_slice("=", 1)
		elif argument.begins_with("--evidence-window="):
			var dimensions := argument.get_slice("=", 1).split("x")
			physical = Vector2i(int(dimensions[0]), int(dimensions[1]))
	root.size = physical
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	root.get_node("I18n").set_locale(locale)
	game.reset_game()
	var main: Control = load("res://src/ui/main.tscn").instantiate()
	root.add_child(main)
	await _settle()
	main.find_child("Navigation_industry", true, false).pressed.emit()
	await _settle()
	var workspace: Control = main.find_child("FactoryWorkspace", true, false)
	workspace.call("_set_active_subworkspace", "OVERVIEW")
	await _capture("01-new-game-overview")
	var power_a := _build("grid_solar_array", Vector2i(30, 12))
	var power_b := _build("grid_solar_array", Vector2i(46, 12))
	var power_c := _build("grid_solar_array", Vector2i(62, 12))
	var mine_a := _build("grid_surface_mine", Vector2i(36, 38))
	var mine_b := _build("grid_surface_mine", Vector2i(76, 38))
	var iron := _build("grid_engineering_works", Vector2i(38, 66), "grid_refine_iron")
	var copper := _build("grid_engineering_works", Vector2i(72, 66), "grid_refine_copper")
	game.advance_game_time(130_000.0)
	for source in [power_a, power_b, power_c]:
		_link("POWER", source, mine_a)
	for consumer in [mine_b, iron, copper]:
		_link("POWER", power_a, consumer)
	_link("CARGO", mine_a, iron, "iron_ore")
	_link("CARGO", mine_b, copper, "copper_ore")
	_link("CARGO", iron, "starter-depot", "iron_ingot")
	_link("CARGO", copper, "starter-depot", "copper_ingot")
	_link("CARGO", copper, "starter-depot", "industrial_waste")
	game.advance_game_time(12_000.0)
	_build("grid_arc_smelter", Vector2i(112, 72), "grid_refine_iron")
	_build("grid_bulk_depot", Vector2i(150, 32))
	workspace.apply_snapshot(game.factory_workspace_snapshot(WORLD))
	for view in ["OVERVIEW", "CANVAS", "PRODUCTION", "CONSTRUCTION"]:
		workspace.call("_set_active_subworkspace", view)
		if view == "CANVAS":
			await _settle()
			workspace.canvas().focus_operational_region()
		await _capture("02-" + str(view).to_lower())
		var scroll_name: String = {"OVERVIEW":"FactoryOperationsScroll", "PRODUCTION":"ProductionScroll", "CONSTRUCTION":"ConstructionScroll"}.get(view, "")
		var content_scroll := workspace.find_child(scroll_name, true, false) as ScrollContainer if not scroll_name.is_empty() else null
		if content_scroll != null and content_scroll.get_v_scroll_bar().max_value > content_scroll.size.y:
			content_scroll.scroll_vertical = int(content_scroll.get_v_scroll_bar().max_value)
			await _capture("05-" + str(view).to_lower() + "-bottom")
			content_scroll.scroll_vertical = 0
	workspace.call("_set_active_subworkspace", "CANVAS")
	var snapshot: Dictionary = game.factory_workspace_snapshot(WORLD)
	for entity in snapshot.get("entities", []):
		if str(entity.get("id", "")) == iron:
			workspace.call("_on_entity_selected", entity)
	await _capture("03-selected-machine")
	var orders: Array = snapshot.get("construction_orders", [])
	if not orders.is_empty():
		workspace.call("_on_construction_order_selected", orders[0])
	await _capture("04-selected-construction")
	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_OPERATIONS_CAPTURE_PASS: ", output_root)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _capture(id: String) -> void:
	await _settle()
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(output_root.path_join(id + ".png"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var picture := root.get_texture().get_image()
	# canvas_items/keep exposes the rendered content texture, without the
	# Window's letterbox/pillarbox pixels. Check that physical Window and
	# uniformly fitted content dimensions both obey the design contract.
	var factor := minf(float(physical.x) / 1920.0, float(physical.y) / 1080.0)
	var expected_content := Vector2(1920, 1080) * factor
	var content_error := Vector2(picture.get_size()) - expected_content
	if picture.save_png(path) != OK or root.size != physical or absf(content_error.x) > 1.0 or absf(content_error.y) > 1.0:
		failures.append("Capture failed or incorrect dimensions: " + path)
	else:
		print("CAPTURE: ", path, " content=", picture.get_size(), " window=", root.size)


func _settle() -> void:
	for frame in 6:
		await process_frame


func _command(kind: String, payload: Dictionary) -> Dictionary:
	serial += 1
	var world: Dictionary = game.state.factory_worlds[WORLD]
	var response: Dictionary = game.execute_factory_command({"protocol_version":1, "command_id":"operations-capture-%d" % serial, "kind":kind, "world_id":WORLD, "base_topology_revision":int(world.topology_revision), "payload":payload})
	if not bool(response.get("accepted", false)):
		failures.append("Capture setup command failed: %s %s" % [kind, response.get("reason_code", "")])
	return response.get("result", {})


func _build(definition: String, origin: Vector2i, recipe := "") -> String:
	return str(_command("QUEUE_CONSTRUCTION", {"definition_id":definition, "recipe_id":recipe, "origin":{"x":origin.x, "y":origin.y}, "funding_policy":"AUTO_SAME_LOCATION"}).get("entity_id", ""))


func _link(kind: String, source: String, target: String, item := "") -> void:
	_command("CONNECT_ENTITIES", {"link_kind":kind, "source_id":source, "target_id":target, "item_id":item, "capacity_per_second":1.0})
