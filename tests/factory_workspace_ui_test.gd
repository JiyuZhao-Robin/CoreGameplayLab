extends SceneTree

## Focused protocol-v1 UI contract. This fixture creates only presentation
## objects; it never reaches through the workspace boundary to Game or state.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node.new()
	host.name = "FactoryWorkspaceUiTestHost"
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.size = Vector2(1280, 720)
	host.add_child(workspace)
	var fixture := _fixture_snapshot()
	var original_fixture_signature := JSON.stringify(fixture)
	workspace.apply_snapshot(fixture)
	await _settle()

	var intents: Array = []
	var refreshes: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	workspace.refresh_requested.connect(func(world_id: String) -> void: refreshes.append(world_id))

	_test_initial_render(workspace)
	_test_finite_canvas_bounds(workspace)
	await _test_canvas_scale_contract(workspace)
	_test_construction_intent(workspace, intents)
	_test_recipe_change_intent(workspace, intents)
	await _test_runtime_refresh_preserves_inspector_focus(workspace)
	_test_build_placement_cancel(workspace, intents)
	_test_cargo_connection_intent(workspace, intents)
	_test_power_connection_intent(workspace, intents)
	_test_location_transfer_intents(workspace, intents)
	_test_result_feedback_and_reduced_motion(workspace, refreshes)
	_test_keyboard_canvas_action(workspace, intents)
	await _test_mouse_hit_priorities(workspace, intents)
	var first_instance_command_id := _emit_rebuild_probe(workspace, intents)
	_check(JSON.stringify(fixture) == original_fixture_signature, "Factory workspace never mutates its caller-owned snapshot fixture")

	workspace.queue_free()
	await process_frame
	await _test_rebuilt_workspace_command_id(host, first_instance_command_id)
	host.queue_free()
	await process_frame
	_finish()


func _test_initial_render(workspace) -> void:
	var building_palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	var source_selector := workspace.find_child("ConnectionSource", true, false) as OptionButton
	var target_selector := workspace.find_child("ConnectionTarget", true, false) as OptionButton
	var canvas = workspace.canvas()
	_check(building_palette != null and building_palette.item_count == 4, "Factory workspace renders the versioned construction palette")
	_check(source_selector != null and target_selector != null and source_selector.item_count == 5 and target_selector.item_count == 5, "Factory workspace renders deterministic entity connection selectors")
	var exposes_resource_field := false
	for index in source_selector.item_count:
		if str(source_selector.get_item_metadata(index)) == "iron-field":
			exposes_resource_field = true
	_check(not exposes_resource_field, "resource fields never appear as connectable Factory endpoints")
	_check(canvas != null and canvas.selected_node_id().is_empty() and canvas.selected_link_id().is_empty(), "Factory canvas starts with an empty presentation-only selection")


func _test_finite_canvas_bounds(workspace) -> void:
	var canvas = workspace.canvas()
	canvas.set("_camera", Vector2(100000.0, 100000.0))
	canvas._clamp_camera_to_bounds()
	var upper_left_rect: Rect2 = canvas._world_screen_rect()
	var upper_x_ok: bool = is_equal_approx(upper_left_rect.position.x, (canvas.size.x - upper_left_rect.size.x) * 0.5) if upper_left_rect.size.x <= canvas.size.x else upper_left_rect.position.x <= 0.001
	var upper_y_ok: bool = is_equal_approx(upper_left_rect.position.y, (canvas.size.y - upper_left_rect.size.y) * 0.5) if upper_left_rect.size.y <= canvas.size.y else upper_left_rect.position.y <= 0.001
	_check(upper_x_ok and upper_y_ok, "finite canvas camera cannot pan beyond the world's upper-left boundary")
	canvas.set("_camera", Vector2(-100000.0, -100000.0))
	canvas._clamp_camera_to_bounds()
	var lower_right_rect: Rect2 = canvas._world_screen_rect()
	var lower_x_ok: bool = is_equal_approx(lower_right_rect.position.x, (canvas.size.x - lower_right_rect.size.x) * 0.5) if lower_right_rect.size.x <= canvas.size.x else lower_right_rect.end.x + 0.001 >= canvas.size.x
	var lower_y_ok: bool = is_equal_approx(lower_right_rect.position.y, (canvas.size.y - lower_right_rect.size.y) * 0.5) if lower_right_rect.size.y <= canvas.size.y else lower_right_rect.end.y + 0.001 >= canvas.size.y
	_check(lower_x_ok and lower_y_ok, "finite canvas camera cannot pan beyond the world's lower-right boundary")
	canvas.focus_tile(Vector2i(255, 255))
	canvas._move_keyboard_tile(Vector2i.RIGHT)
	canvas._move_keyboard_tile(Vector2i.DOWN)
	_check(canvas.get("_keyboard_tile") == Vector2i(255, 255), "keyboard navigation stops on the final in-bounds tile")
	canvas.focus_tile(Vector2i(-50, -50))
	_check(canvas.get("_keyboard_tile") == Vector2i.ZERO, "programmatic focus clamps to the finite canvas origin")
	var selected_tiles: Array = []
	canvas.tile_selected.connect(func(tile: Vector2i) -> void: selected_tiles.append(tile))
	canvas._select_tile(canvas._world_screen_rect().position - Vector2(8.0, 8.0))
	_check(selected_tiles.is_empty(), "clicking beyond the visible world boundary emits no placement tile")
	var shifted_snapshot := _fixture_snapshot()
	shifted_snapshot["bounds"] = {"origin":{"x":100, "y":200}, "size":{"x":256, "y":256}}
	shifted_snapshot["resource_fields"] = []
	shifted_snapshot["entities"] = []
	shifted_snapshot["construction_orders"] = []
	canvas.apply_snapshot(shifted_snapshot)
	canvas.focus_tile(Vector2i(99, 199))
	_check(canvas.get("_keyboard_tile") == Vector2i(100, 200), "finite canvas clamping respects a non-zero world origin")
	selected_tiles.clear()
	canvas._select_tile(canvas._world_to_screen(Vector2(100, 200)) + Vector2.ONE * canvas._tile_scale() * 0.5)
	_check(selected_tiles == [Vector2i(100, 200)], "screen-to-tile selection resolves the first tile of a shifted finite world")
	canvas.apply_snapshot(_fixture_snapshot())
	canvas.reset_camera()


func _test_canvas_scale_contract(workspace) -> void:
	var canvas = workspace.canvas()
	var small_snapshot := _fixture_snapshot()
	small_snapshot["world_id"] = "small-canvas"
	small_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":256, "y":192}}
	canvas.apply_snapshot(small_snapshot)
	canvas.reset_camera()
	var small_rect: Rect2 = canvas._world_screen_rect()
	var small_zoom: float = float(canvas.get("_zoom"))

	var large_snapshot := _fixture_snapshot()
	large_snapshot["world_id"] = "large-canvas"
	large_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":512, "y":384}}
	canvas.apply_snapshot(large_snapshot)
	canvas.reset_camera()
	var large_rect: Rect2 = canvas._world_screen_rect()
	_check(
		is_equal_approx(large_rect.size.x, small_rect.size.x * 2.0)
		and is_equal_approx(large_rect.size.y, small_rect.size.y * 2.0)
		and is_equal_approx(float(canvas.get("_zoom")), small_zoom),
		"one shared overview scale makes larger planet bounds occupy proportionally more canvas area"
	)
	_check(
		large_rect.position.x >= 23.9
		and large_rect.position.y >= 23.9
		and large_rect.end.x <= canvas.size.x - 23.9
		and large_rect.end.y <= canvas.size.y - 23.9,
		"the authored maximum factory canvas fits inside the overview padding"
	)
	_check(canvas._tile_scale() < 2.0 and is_equal_approx(canvas._tile_scale(), 4.0 * float(canvas.get("_zoom"))), "overview zoom has no hidden two-pixel dead band")

	var anchor: Vector2 = canvas.size * 0.5
	var anchor_world: Vector2 = canvas._screen_to_world(anchor)
	canvas._set_zoom_around(anchor, anchor_world, float(canvas.get("_zoom")) * 1.5)
	_check(canvas._screen_to_world(anchor).distance_to(anchor_world) < 0.001, "pointer zoom preserves the exact floating-point world anchor")
	var preserved_zoom: float = float(canvas.get("_zoom"))
	var preserved_camera: Vector2 = canvas.get("_camera")
	large_snapshot["runtime_revision"] = int(large_snapshot.get("runtime_revision", 0)) + 1
	canvas.apply_snapshot(large_snapshot)
	var refreshed_camera: Vector2 = canvas.get("_camera")
	_check(is_equal_approx(float(canvas.get("_zoom")), preserved_zoom) and refreshed_camera.distance_to(preserved_camera) < 0.001, "same-world runtime refresh preserves the player's camera and zoom")

	for _step in range(80):
		canvas._adjust_zoom(1.14)
	var detail_rect: Rect2 = canvas._world_screen_rect()
	_check(maxf(detail_rect.size.x, detail_rect.size.y) <= 4096.01 and canvas._tile_scale() <= 10.001, "detail zoom caps the rendered world extent and tile scale")

	(large_snapshot["entities"] as Array).append(_entity("far-offscreen", "POWER", "Far Unit", Vector2i(500, 350), {"inputs":[], "outputs":[], "accepts_power":false, "provides_power":true}))
	canvas.apply_snapshot(large_snapshot)
	canvas.focus_tile(Vector2i.ZERO)
	await _force_canvas_draw(canvas)
	_check(not (canvas.get("_node_rects") as Dictionary).has("far-offscreen"), "drawing and hit-testing cull nodes outside the visible canvas")

	var malformed_snapshot := _fixture_snapshot()
	malformed_snapshot["world_id"] = "defensive-oversized-canvas"
	malformed_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":2560, "y":960}}
	malformed_snapshot["resource_fields"] = []
	malformed_snapshot["entities"] = []
	malformed_snapshot["construction_orders"] = []
	canvas.apply_snapshot(malformed_snapshot)
	canvas.reset_camera()
	var malformed_rect: Rect2 = canvas._world_screen_rect()
	_check(malformed_rect.position.x >= 23.9 and malformed_rect.position.y >= 23.9 and malformed_rect.end.x <= canvas.size.x - 23.9 and malformed_rect.end.y <= canvas.size.y - 23.9, "canvas defensively fits an oversized malformed snapshot even though the application boundary force-crops it")

	var normal_canvas_size: Vector2 = canvas.size
	var tiny_snapshot := _fixture_snapshot()
	tiny_snapshot["world_id"] = "tiny-canvas"
	tiny_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":64, "y":64}}
	tiny_snapshot.erase("canvas_limits")
	canvas.size = Vector2(8192, 8192)
	canvas.apply_snapshot(tiny_snapshot)
	canvas.reset_camera()
	_check(canvas._tile_scale() <= 10.001 and maxf(canvas._world_screen_rect().size.x, canvas._world_screen_rect().size.y) <= 4096.01, "tile and rendered-axis performance caps remain hard limits even in an oversized viewport")
	canvas.size = normal_canvas_size

	canvas.apply_snapshot(_fixture_snapshot())
	canvas.reset_camera()
	_check((canvas.get("_entities_by_id") as Dictionary).size() == 4 and (canvas.get("_resources_by_id") as Dictionary).has("iron-field"), "Canvas builds constant-time snapshot indexes once per payload")
	var storage_point: Vector2 = canvas._footprint_rect(_snapshot_entity(workspace, "storage-a").get("footprint", {}), 4.0).get_center()
	canvas._set_zoom_around(storage_point, canvas._screen_to_world(storage_point), float(canvas.get("_zoom")) * 1.14)
	var transformed_storage_point: Vector2 = canvas._footprint_rect(_snapshot_entity(workspace, "storage-a").get("footprint", {}), 4.0).get_center()
	canvas._select_at(transformed_storage_point)
	_check(canvas.selected_node_id() == "storage-a", "hit testing rebuilds immediately after a transform without waiting for a draw frame")

	var flowing_snapshot := _fixture_snapshot()
	flowing_snapshot["links"] = [{"id":"active-power", "kind":"POWER", "source_id":"power-a", "target_id":"mine-a", "status":"FLOWING", "last_flow":1.0, "utilization":0.5}]
	canvas.apply_snapshot(flowing_snapshot)
	canvas.reset_camera()
	while canvas._tile_scale() < 0.75:
		canvas._adjust_zoom(1.14)
	await _force_canvas_draw(canvas)
	canvas.set("_flow_redraw_elapsed", 0.0)
	var phase_before := float(canvas.get("_visual_phase"))
	canvas._process(0.02)
	canvas._process(0.02)
	_check(is_equal_approx(float(canvas.get("_visual_phase")), phase_before), "active-flow animation does not redraw before its 20 Hz budget interval")
	canvas._process(0.02)
	_check(float(canvas.get("_visual_phase")) > phase_before, "visible active-flow animation advances at the bounded redraw interval")
	canvas.set_reduced_motion(true)
	var reduced_phase := float(canvas.get("_visual_phase"))
	canvas._process(1.0)
	_check(is_equal_approx(float(canvas.get("_visual_phase")), reduced_phase), "reduced motion disables active-flow animation work")
	canvas.set_reduced_motion(false)
	canvas.apply_snapshot({"valid":false, "protocol_version":1})
	var invalid_phase := float(canvas.get("_visual_phase"))
	canvas._process(1.0)
	_check(not bool(canvas.get("_visible_active_flow")) and is_equal_approx(float(canvas.get("_visual_phase")), invalid_phase), "switching to an invalid snapshot cannot leave an empty canvas redrawing at 20 Hz")

	var dense_snapshot := flowing_snapshot.duplicate(true)
	for dense_index in range(510):
		(dense_snapshot["entities"] as Array).append(_entity("dense-%04d" % dense_index, "POWER", "Dense Unit", Vector2i(dense_index % 64, dense_index / 64), {"inputs":[], "outputs":[], "accepts_power":false, "provides_power":true}))
	canvas.apply_snapshot(dense_snapshot)
	canvas.reset_camera()
	while canvas._tile_scale() < 0.75:
		canvas._adjust_zoom(1.14)
	_check(not canvas._flow_animation_allowed(), "high-density snapshots disable whole-canvas flow animation redraws")
	canvas.apply_snapshot(_fixture_snapshot())
	canvas.reset_camera()


func _test_construction_intent(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_solar_array")
	workspace._on_tile_hovered(Vector2i(100, 80))
	workspace._on_tile_selected(Vector2i(100, 80))
	_check(not intents.is_empty(), "placing a preview footprint emits an intent instead of mutating Factory state")
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		int(intent.get("protocol_version", 0)) == 1
		and str(intent.get("kind", "")) == "QUEUE_CONSTRUCTION"
		and str(intent.get("world_id", "")) == "ui-grid"
		and int(intent.get("base_topology_revision", -1)) == 17
		and int(intent.get("base_runtime_revision", -1)) == 9
		and str(payload.get("definition_id", "")) == "grid_solar_array"
		and int((payload.get("origin", {}) as Dictionary).get("x", -1)) == 100,
		"construction intent preserves protocol, immutable revision, and selected footprint origin"
	)


func _test_recipe_change_intent(workspace, intents: Array) -> void:
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	var selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	var apply_button := workspace.find_child("ApplyEntityRecipe", true, false) as Button
	_check(selector != null and apply_button != null, "machine inspector exposes recipe reconfiguration controls")
	if selector == null or apply_button == null:
		return
	_select_metadata(selector, "grid_refine_copper")
	apply_button.pressed.emit()
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(str(intent.get("kind", "")) == "SET_RECIPE" and str(payload.get("entity_id", "")) == "smelter-a" and str(payload.get("recipe_id", "")) == "grid_refine_copper", "machine inspector emits only a versioned SET_RECIPE intent")


func _test_runtime_refresh_preserves_inspector_focus(workspace) -> void:
	var stable_selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	_check(stable_selector != null, "focus-stability fixture exposes the machine recipe selector")
	if stable_selector == null:
		return
	stable_selector.grab_focus()
	stable_selector.get_popup().popup()
	await process_frame
	var first_runtime_update := _fixture_snapshot()
	first_runtime_update["runtime_revision"] = 10
	for entity_value in first_runtime_update.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == "smelter-a":
			entity["recipe_id"] = "grid_refine_copper"
	workspace.apply_snapshot(first_runtime_update)
	var latest_runtime_update := _fixture_snapshot()
	latest_runtime_update["runtime_revision"] = 11
	workspace.apply_snapshot(latest_runtime_update)
	_check(bool(workspace.get("_pending_inspector_refresh")) and workspace.is_processing(), "focused Inspector schedules an eventual snapshot refresh")
	await process_frame
	_check(is_instance_valid(stable_selector) and workspace.find_child("EntityRecipeSelector", true, false) == stable_selector, "runtime refresh preserves the focused Inspector control instance")
	stable_selector.get_popup().hide()
	await _settle()
	_check(not bool(workspace.get("_pending_inspector_refresh")), "pending Inspector refresh settles after the selector popup closes")
	# The rebuilt controls replace their predecessors via queue_free(), which is
	# finalized after the process frame that performs the deferred render.
	await process_frame
	var refreshed_selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	var revision_label := workspace.get("_revision_label") as Label
	var inspector_child_names: Array[String] = []
	for child_value in (workspace.get("_inspector_body") as VBoxContainer).get_children():
		inspector_child_names.append(str((child_value as Node).name))
	_check(refreshed_selector != null and not is_instance_valid(stable_selector), "Inspector rebuilds after the focused interaction ends (selection=%s children=%s)" % [str(workspace.get("_selection")), str(inspector_child_names)])
	_check(refreshed_selector != null and str(refreshed_selector.get_item_metadata(refreshed_selector.selected)) == "grid_refine_iron", "deferred Inspector rebuild uses the newest snapshot payload (selected=%s)" % str(refreshed_selector.get_item_metadata(refreshed_selector.selected) if refreshed_selector != null else "missing"))
	_check(revision_label != null and revision_label.text.contains("11"), "deferred Inspector rebuild exposes the newest runtime revision")
	var focused_button := workspace.find_child("ApplyEntityRecipe", true, false) as Button
	if focused_button != null:
		focused_button.grab_focus()
	var button_runtime_update := _fixture_snapshot()
	button_runtime_update["runtime_revision"] = 12
	for entity_value in button_runtime_update.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == "smelter-a":
			entity["recipe_id"] = "grid_refine_copper"
	workspace.apply_snapshot(button_runtime_update)
	await _settle()
	await process_frame
	var button_refreshed_selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	_check(
		button_refreshed_selector != null
		and str(button_refreshed_selector.get_item_metadata(button_refreshed_selector.selected)) == "grid_refine_copper"
		and not bool(workspace.get("_pending_inspector_refresh")),
		"a focused Inspector button cannot indefinitely block the newest snapshot"
	)


func _test_build_placement_cancel(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	var canvas = workspace.canvas()
	var intent_count_before := intents.size()
	_select_metadata(palette, "grid_solar_array")
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	canvas._on_gui_input(escape)
	_check(
		str(workspace.get("_active_tool")) != "BUILD"
		and str(workspace.get("_selected_building_id")) == ""
		and (canvas.get("_placement_preview") as Dictionary).is_empty()
		and intents.size() == intent_count_before,
		"Escape cancels BUILD placement without emitting QUEUE_CONSTRUCTION"
	)
	_select_metadata(palette, "grid_solar_array")
	var right_click := InputEventMouseButton.new()
	right_click.button_index = MOUSE_BUTTON_RIGHT
	right_click.pressed = true
	canvas._on_gui_input(right_click)
	_check(
		str(workspace.get("_active_tool")) != "BUILD"
		and str(workspace.get("_selected_building_id")) == ""
		and (canvas.get("_placement_preview") as Dictionary).is_empty()
		and intents.size() == intent_count_before,
		"right-click cancels BUILD placement without emitting QUEUE_CONSTRUCTION"
	)


func _test_cargo_connection_intent(workspace, intents: Array) -> void:
	workspace._set_connection_mode("CARGO")
	var source_selector := workspace.find_child("ConnectionSource", true, false) as OptionButton
	var target_selector := workspace.find_child("ConnectionTarget", true, false) as OptionButton
	_select_metadata(source_selector, "mine-a")
	_select_metadata(target_selector, "smelter-a")
	var connect_button := workspace.find_child("CreateConnection", true, false) as Button
	var intent_count_before := intents.size()
	if connect_button != null:
		connect_button.pressed.emit()
	_check(connect_button != null and intents.size() == intent_count_before + 1, "real Create Connection press emits exactly one CARGO intent")
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		str(intent.get("kind", "")) == "CONNECT_ENTITIES"
		and str(payload.get("link_kind", "")) == "CARGO"
		and str(payload.get("source_id", "")) == "mine-a"
		and str(payload.get("target_id", "")) == "smelter-a"
		and str(payload.get("item_id", "")) == "iron_ore",
		"compatible entity ports produce a versioned CARGO connection intent"
	)


func _test_power_connection_intent(workspace, intents: Array) -> void:
	workspace._set_connection_mode("POWER")
	var source_selector := workspace.find_child("ConnectionSource", true, false) as OptionButton
	var target_selector := workspace.find_child("ConnectionTarget", true, false) as OptionButton
	_select_metadata(source_selector, "power-a")
	_select_metadata(target_selector, "mine-a")
	var connect_button := workspace.find_child("CreateConnection", true, false) as Button
	var intent_count_before := intents.size()
	if connect_button != null:
		connect_button.pressed.emit()
	_check(connect_button != null and intents.size() == intent_count_before + 1, "real Create Connection press emits exactly one POWER intent")
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		str(intent.get("kind", "")) == "CONNECT_ENTITIES"
		and str(payload.get("link_kind", "")) == "POWER"
		and str(payload.get("source_id", "")) == "power-a"
		and str(payload.get("target_id", "")) == "mine-a"
		and str(payload.get("item_id", "unexpected")) == "",
		"power producer and consumer ports produce a versioned POWER connection intent"
	)


func _test_location_transfer_intents(workspace, intents: Array) -> void:
	workspace._request_storage_transfer("EXPORT_TO_LOCATION", "storage-a", "iron_ingot", 3)
	var export_intent: Dictionary = intents.back() as Dictionary
	workspace._request_storage_transfer("IMPORT_FROM_LOCATION", "storage-a", "iron_ingot", 2)
	var import_intent: Dictionary = intents.back() as Dictionary
	_check(
		str(export_intent.get("kind", "")) == "EXPORT_TO_LOCATION"
		and str((export_intent.get("payload", {}) as Dictionary).get("storage_id", "")) == "storage-a"
		and int((export_intent.get("payload", {}) as Dictionary).get("quantity", 0)) == 3
		and str(import_intent.get("kind", "")) == "IMPORT_FROM_LOCATION"
		and int((import_intent.get("payload", {}) as Dictionary).get("quantity", 0)) == 2,
		"same-location transfer controls construct only versioned import/export intents"
	)


func _test_result_feedback_and_reduced_motion(workspace, refreshes: Array) -> void:
	workspace.apply_command_result({
		"accepted":false,
		"protocol_version":1,
		"world_id":"ui-grid",
		"reason_code":"STALE_TOPOLOGY",
		"message":"Factory layout changed; refresh before retrying."
	})
	var feedback := workspace.find_child("FactoryCommandFeedback", true, false) as Label
	var localization := get_root().get_node_or_null("I18n")
	var expected_rejection := str(localization.call("t", "factory.reason.stale_topology")) if localization != null else "Factory layout changed; refresh before retrying."
	_check(feedback != null and feedback.text.contains("[STALE_TOPOLOGY]") and feedback.text.contains(expected_rejection), "structured localized command rejection remains visible in Factory feedback")
	_check(refreshes.size() == 1 and str(refreshes[0]) == "ui-grid", "command results request a fresh immutable snapshot from the host")
	workspace.set_reduced_motion(true)
	_check(bool(workspace.canvas().get("_reduced_motion")), "reduced-motion setter propagates to the animated Factory canvas")


func _test_keyboard_canvas_action(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_solar_array")
	var canvas = workspace.canvas()
	var right := InputEventKey.new()
	right.pressed = true
	right.keycode = KEY_RIGHT
	canvas._on_gui_input(right)
	var confirm := InputEventKey.new()
	confirm.pressed = true
	confirm.keycode = KEY_ENTER
	canvas._on_gui_input(confirm)
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		canvas.get("_keyboard_tile") == Vector2i.RIGHT
		and str(intent.get("kind", "")) == "QUEUE_CONSTRUCTION"
		and int((payload.get("origin", {}) as Dictionary).get("x", -1)) == 1,
		"focused Factory canvas supports arrow-key tile movement and Enter placement"
	)


func _test_mouse_hit_priorities(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_surface_mine")
	var canvas = workspace.canvas()
	# The preceding keyboard case centers its tile. Mouse hit coordinates below
	# deliberately exercise world-space field/order rectangles at the origin.
	canvas.reset_camera()
	await _force_canvas_draw(canvas)
	var extractor_tile := Vector2i(16, 16)
	var extractor_point: Vector2 = canvas._world_to_screen(Vector2(extractor_tile)) + Vector2.ONE * canvas._tile_scale() * 0.5
	canvas._on_gui_input(_mouse_motion(extractor_point))
	canvas._on_gui_input(_left_click(extractor_point))
	var extractor_intent: Dictionary = intents.back() as Dictionary
	var extractor_payload: Dictionary = extractor_intent.get("payload", {})
	_check(
		str(extractor_intent.get("kind", "")) == "QUEUE_CONSTRUCTION"
		and Vector2i(int((extractor_payload.get("origin", {}) as Dictionary).get("x", -1)), int((extractor_payload.get("origin", {}) as Dictionary).get("y", -1))) == extractor_tile
		and str((workspace.get("_selection") as Dictionary).get("kind", "")) != "RESOURCE_FIELD",
		"a real mouse click on an extractor preview over a resource field emits construction instead of selecting the field"
	)
	var order_point: Vector2 = canvas._world_to_screen(Vector2(26, 26)) + Vector2.ONE * canvas._tile_scale() * 0.5
	canvas._on_gui_input(_mouse_motion(order_point))
	canvas._on_gui_input(_left_click(order_point))
	var selection: Dictionary = workspace.get("_selection") as Dictionary
	_check(
		str(selection.get("kind", "")) == "CONSTRUCTION_ORDER" and str(selection.get("id", "")) == "build-iron",
		"a real mouse click selects a construction order that overlays a resource field"
	)


func _emit_rebuild_probe(workspace, intents: Array) -> String:
	workspace._request_storage_transfer("IMPORT_FROM_LOCATION", "storage-a", "iron_ingot", 1)
	_check(not intents.is_empty(), "first workspace emits a receipt-bearing command before rebuild")
	return str((intents.back() as Dictionary).get("command_id", ""))


func _test_rebuilt_workspace_command_id(host: Node, first_command_id: String) -> void:
	var rebuilt = WorkspaceScript.new()
	rebuilt.size = Vector2(1280, 720)
	host.add_child(rebuilt)
	rebuilt.apply_snapshot(_fixture_snapshot())
	await _settle()
	var rebuilt_intents: Array = []
	rebuilt.command_requested.connect(func(intent: Dictionary) -> void: rebuilt_intents.append(intent.duplicate(true)))
	rebuilt._request_storage_transfer("IMPORT_FROM_LOCATION", "storage-a", "iron_ingot", 1)
	var rebuilt_command_id := str((rebuilt_intents.back() as Dictionary).get("command_id", "")) if not rebuilt_intents.is_empty() else ""
	_check(
		not first_command_id.is_empty() and not rebuilt_command_id.is_empty() and first_command_id != rebuilt_command_id,
		"command IDs remain process-unique after a workspace is destroyed and rebuilt"
	)
	rebuilt.queue_free()
	await process_frame


func _force_canvas_draw(canvas) -> void:
	canvas.queue_redraw()
	RenderingServer.force_draw(false)
	await process_frame


func _mouse_motion(point: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = point
	return event


func _left_click(point: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = point
	return event


func _select_metadata(options: OptionButton, value: String) -> void:
	var index := -1
	for candidate in range(options.item_count):
		if str(options.get_item_metadata(candidate)) == value:
			index = candidate
			break
	_check(index >= 0, "test fixture exposes selector metadata %s" % value)
	if index < 0:
		return
	options.select(index)
	options.item_selected.emit(index)


func _fixture_snapshot() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_schema_version":3,
		"world_id":"ui-grid",
		"location_id":"earth_orbit",
		"topology_revision":17,
		"runtime_revision":9,
		"canvas_limits":{"max_world_size_tiles":{"x":512, "y":384}},
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":256, "y":256}},
		"resource_fields":[
			{"id":"iron-field", "resource_id":"iron_ore", "resource_category":"solid", "resource_color":"#B45F45", "grade":1.0, "potential_density":0.25, "footprint":{"origin":{"x":12, "y":12}, "size":{"x":24, "y":24}}, "ports":{"inputs":[], "outputs":[], "accepts_power":false}}
		],
		"entities":[
			_entity("power-a", "POWER", "Solar Array", Vector2i(12, 48), {"inputs":[], "outputs":[], "accepts_power":false, "provides_power":true}),
			_entity("mine-a", "EXTRACTOR", "Surface Mine", Vector2i(40, 12), {"inputs":[], "outputs":["iron_ore"], "accepts_power":true, "provides_power":false}),
			_entity("smelter-a", "MACHINE", "Arc Smelter", Vector2i(70, 12), {"inputs":["iron_ore"], "outputs":["iron_ingot"], "accepts_power":true, "provides_power":false}, {}, "grid_arc_smelter", "grid_refine_iron"),
			_entity("storage-a", "STORAGE", "Bulk Depot", Vector2i(110, 12), {"inputs":["*"], "outputs":["*"], "accepts_power":false, "provides_power":false}, {"iron_ingot":5})
		],
		"links":[],
		"construction_orders":[
			{"id":"build-iron", "entity_id":"entity-build-iron", "definition_id":"grid_surface_mine", "recipe_id":"", "footprint":{"origin":{"x":24, "y":24}, "size":{"x":6, "y":6}}, "required_items":{"iron_ingot":2}, "delivered_items":{}, "work_required":5.0, "work_done":0.0, "progress":0.0, "priority":50, "status":"WAITING_MATERIALS"}
		],
		"location_inventory":{"items":{"iron_ingot":12}},
		"palette":{
			"buildings":[
				{"id":"grid_solar_array", "name":"Surface Solar Array", "kind":"POWER", "footprint":{"width":8, "height":8}, "recipe_ids":[]},
				{"id":"grid_surface_mine", "name":"Surface Mine", "kind":"EXTRACTOR", "footprint":{"width":3, "height":3}, "recipe_ids":[]},
				{"id":"grid_arc_smelter", "name":"Arc Smelter", "kind":"MACHINE", "footprint":{"width":16, "height":12}, "recipe_ids":["grid_refine_iron", "grid_refine_copper"]}
			],
			"recipes":[
				{"id":"grid_refine_iron", "name":"Grid Iron Refining", "duration_seconds":2.0, "inputs":[], "outputs":[]},
				{"id":"grid_refine_copper", "name":"Grid Copper Refining", "duration_seconds":6.0, "inputs":[], "outputs":[]}
			]
			}
	}


func _entity(entity_id: String, kind: String, title: String, origin: Vector2i, ports: Dictionary, inventory: Dictionary = {}, definition_id: String = "", recipe_id: String = "") -> Dictionary:
	return {
		"id":entity_id,
		"node_kind":kind,
		"name":title,
		"definition_id":definition_id if not definition_id.is_empty() else entity_id,
		"recipe_id":recipe_id,
		"footprint":{"origin":{"x":origin.x, "y":origin.y}, "size":{"x":8, "y":8}},
		"status":"READY",
		"ports":ports,
		"inputs":{},
		"outputs":{},
		"inventory":inventory,
		"power_factor":1.0,
		"actual_rate":0.0
	}


func _snapshot_entity(workspace, entity_id: String) -> Dictionary:
	for entity_value in (workspace.get("_snapshot") as Dictionary).get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity.duplicate(true)
	return {}


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
		print("FACTORY_WORKSPACE_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
