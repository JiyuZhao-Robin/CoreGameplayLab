extends SceneTree

## Focused protocol-v1 UI contract. This fixture creates only presentation
## objects; it never reaches through the workspace boundary to Game or state.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const ChunkIndexScript = preload("res://src/ui/workspaces/factory/factory_canvas_chunk_index.gd")
const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

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
	# The industrial workspace now opens directly on the authored canvas.  The
	# overview remains available as an explicit tab, but must not consume the
	# first construction interaction.
	await _settle()

	var intents: Array = []
	var refreshes: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	workspace.refresh_requested.connect(func(world_id: String) -> void: refreshes.append(world_id))

	_test_chunk_spatial_index()
	_test_initial_render(workspace)
	await _test_bottom_build_palette(workspace, intents)
	_test_finite_canvas_bounds(workspace)
	await _test_canvas_scale_contract(workspace)
	await _test_left_mouse_pan(workspace, intents)
	_test_factory_information_controls(workspace)
	_test_hover_deduplication(workspace)
	_test_construction_intent(workspace, intents)
	_test_recipe_change_intent(workspace, intents)
	_test_machine_configuration_clipboard(workspace, intents)
	_test_machine_configuration_target_isolation(workspace, intents)
	_test_canvas_configuration_gestures(workspace, intents)
	await _test_runtime_refresh_preserves_inspector_focus(workspace)
	_test_build_placement_cancel(workspace, intents)
	_test_connection_cancel(workspace, intents)
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
	var recipe_palette: Node = workspace.find_child("RecipePalette", true, false)
	var source_selector := workspace.find_child("ConnectionSource", true, false) as OptionButton
	var target_selector := workspace.find_child("ConnectionTarget", true, false) as OptionButton
	var canvas = workspace.canvas()
	_check(building_palette != null and building_palette.item_count == 4, "Factory workspace renders the versioned construction palette")
	_check(recipe_palette == null, "construction palette does not expose a global recipe selector")
	_check(source_selector != null and target_selector != null and source_selector.item_count == 4 and target_selector.item_count == 3, "Factory workspace renders deterministic port-filtered connection selectors")
	var exposes_resource_field := false
	for index in source_selector.item_count:
		if str(source_selector.get_item_metadata(index)) == "iron-field":
			exposes_resource_field = true
	_check(not exposes_resource_field, "resource fields never appear as connectable Factory endpoints")
	var scale_label := workspace.find_child("FactoryWorldScale", true, false) as Label
	var revision_info := workspace.find_child("FactoryRevisionInfo", true, false) as Label
	var command_feedback := workspace.find_child("FactoryCommandFeedback", true, false) as Label
	var connection_status := workspace.find_child("ConnectionStatus", true, false) as Label
	var snapshot: Dictionary = workspace.get("_snapshot") as Dictionary
	var expected_topology := "T%d" % int(snapshot.get("topology_revision", 0))
	var expected_runtime := "R%d" % int(snapshot.get("runtime_revision", 0))
	_check(
		scale_label != null and scale_label.tooltip_text.contains("256 × 160") and scale_label.tooltip_text.contains("4 × 3")
		and revision_info != null and revision_info.text == "ⓘ" and revision_info.tooltip_text.contains(expected_topology) and revision_info.tooltip_text.contains(expected_runtime)
		and command_feedback != null and command_feedback.get_parent().name == "FactoryToolbar" and not command_feedback.visible
		and connection_status != null and not connection_status.text.is_empty(),
		"Factory opens on the canvas with compact revision/idle feedback chrome while detailed telemetry remains available by tooltip"
	)
	_check(canvas != null and canvas.selected_node_id().is_empty() and canvas.selected_link_id().is_empty(), "Factory canvas starts with an empty presentation-only selection")
	_check(str(workspace.get("_active_subworkspace")) == "CANVAS" and canvas.visible, "Factory defaults to the construction canvas without hiding the other explicit workspaces")
	var bottom_palette := workspace.find_child("FactoryBuildPalette", true, false) as Control
	var center_column := workspace.find_child("FactoryCenterColumn", true, false) as VBoxContainer
	_check(bottom_palette != null and center_column != null and bottom_palette.get_parent() == center_column and canvas.get_parent() == center_column, "Factory canvas and building browser share the fixed center column")
	_check(bottom_palette != null and bottom_palette.position.y >= canvas.position.y + canvas.size.y - 0.5, "construction browser is docked below the canvas instead of consuming a left rail")
	_check(bottom_palette != null and center_column != null and bottom_palette.position.y + bottom_palette.size.y <= center_column.size.y + 0.5, "fixed construction dock remains fully visible inside the Factory center column")


func _test_bottom_build_palette(workspace, intents: Array) -> void:
	var palette = workspace.find_child("FactoryBuildPalette", true, false)
	_check(palette != null and palette.visible_building_ids() == ["grid_arc_smelter", "grid_solar_array", "grid_surface_mine"], "ALL filter exposes every unlocked buildable definition in deterministic snapshot order")
	var before_filter_intents := intents.size()
	var power_filter := workspace.find_child("FactoryBuildFilterPower", true, false) as Button
	if power_filter != null:
		power_filter.pressed.emit()
	_check(palette.active_filter_id() == "POWER" and palette.visible_building_ids() == ["grid_solar_array"] and intents.size() == before_filter_intents, "role filters change only the visible card projection and never issue gameplay commands")
	var all_filter := workspace.find_child("FactoryBuildFilterAll", true, false) as Button
	if all_filter != null:
		all_filter.pressed.emit()
	await _settle()
	var mine_card := workspace.find_child("FactoryBuildCardGridSurfaceMine", true, false) as Button
	var mine_icon := mine_card.find_child("FactoryBuildCardIcon", true, false) as TextureRect if mine_card != null else null
	var mine_label := mine_card.find_child("FactoryBuildCardName", true, false) as Label if mine_card != null else null
	var core_art = load("res://src/ui/workspaces/factory/factory_core_extractor_art.gd")
	_check(mine_icon != null and mine_icon.texture == core_art.icon_texture() and (mine_icon.texture as AtlasTexture).region.size == Vector2(256,256), "bottom-dock mine card uses the shared transparent Core Extractor representative frame")
	if mine_label != null:
		var label_click := mine_label.get_viewport().get_screen_transform() * mine_label.get_global_rect().get_center()
		Input.parse_input_event(_mouse_motion(label_click))
		await process_frame
		Input.parse_input_event(_left_button(label_click, true))
		await process_frame
		Input.parse_input_event(_left_button(label_click, false))
		await process_frame
	_check(
		mine_card != null and mine_label != null
		and mine_card.get_theme_stylebox("normal") == palette.get("_card_selected_style")
		and str(workspace.get("_selected_building_id")) == "grid_surface_mine"
		and str(workspace.get("_active_tool")) == "BUILD"
		and intents.size() == before_filter_intents,
		"a real click on a bottom-dock card label reaches its Button, keeps selection, and enters placement without bypassing the canvas command boundary"
	)
	workspace._on_placement_cancelled()
	var runtime_snapshot := _fixture_snapshot()
	runtime_snapshot["runtime_revision"] = int(runtime_snapshot.get("runtime_revision", 0)) + 1
	workspace.apply_snapshot(runtime_snapshot)
	_check(workspace.find_child("FactoryBuildCardGridSurfaceMine", true, false) == mine_card, "runtime-only snapshot refresh preserves building card instances and avoids palette reconstruction")
	var quick_filter := workspace.find_child("BuildingPalette", true, false) as OptionButton
	if power_filter != null:
		power_filter.pressed.emit()
	_select_metadata(quick_filter, "grid_arc_smelter")
	_check(palette.active_filter_id() == "ALL" and palette.visible_building_ids() == ["grid_arc_smelter"] and str(workspace.get("_selected_building_id")) == "grid_arc_smelter", "quick picker resets a prior role filter and isolates the selected building")
	workspace._on_placement_cancelled()
	var reduced_buildings: Array = ((workspace.get("_snapshot") as Dictionary).get("palette", {}) as Dictionary).get("buildings", []).duplicate(true)
	for index in range(reduced_buildings.size() - 1, -1, -1):
		if str((reduced_buildings[index] as Dictionary).get("id", "")) == "grid_arc_smelter":
			reduced_buildings.remove_at(index)
	palette.set_buildings(reduced_buildings, true, "")
	_check(palette.visible_building_ids() == ["grid_solar_array", "grid_surface_mine"] and quick_filter.selected == 0, "an unavailable single-building filter falls back to the remaining unlocked ALL projection")
	palette.set_buildings([
		{"id":"grid_cargo_splitter", "name":"Splitter", "kind":"ROUTER", "footprint":{"width":4, "height":4}},
		{"id":"grid_bulk_depot", "name":"Depot", "kind":"STORAGE", "footprint":{"width":20, "height":20}},
		{"id":"grid_research_complex", "name":"Research", "kind":"STORAGE", "footprint":{"width":18, "height":16}},
		{"id":"grid_construction_yard", "name":"Construction", "kind":"CONSTRUCTION", "footprint":{"width":24, "height":20}}
	], true, "")
	var logistics_filter := workspace.find_child("FactoryBuildFilterLogistics", true, false) as Button
	if logistics_filter != null:
		logistics_filter.pressed.emit()
	_check(palette.visible_building_ids() == ["grid_cargo_splitter", "grid_bulk_depot"], "logistics filter includes routers and canonical storage facilities")
	var support_filter := workspace.find_child("FactoryBuildFilterSupport", true, false) as Button
	if support_filter != null:
		support_filter.pressed.emit()
	_check(palette.visible_building_ids() == ["grid_research_complex", "grid_construction_yard"], "support filter keeps research/service STORAGE definitions out of logistics")
	if all_filter != null:
		all_filter.pressed.emit()
	palette.set_buildings([
		{"id":"grid_electronics_works", "name":"High-Energy Electronics Works", "kind":"MACHINE", "footprint":{"width":18, "height":14}},
		{"id":"grid_research_complex_ii", "name":"Research Complex Expansion II", "kind":"STORAGE", "footprint":{"width":22, "height":18}}
	], true, "")
	await _settle()
	var long_card := workspace.find_child("FactoryBuildCardGridElectronicsWorks", true, false) as Button
	var second_long_card := workspace.find_child("FactoryBuildCardGridResearchComplexIi", true, false) as Button
	var long_card_name := long_card.find_child("FactoryBuildCardName", true, false) as Label if long_card != null else null
	var second_long_card_name := second_long_card.find_child("FactoryBuildCardName", true, false) as Label if second_long_card != null else null
	var filter_scroll := workspace.find_child("BuildPaletteFiltersScroll", true, false) as ScrollContainer
	var center_column := workspace.find_child("FactoryCenterColumn", true, false) as Control
	var inspector_rail := workspace.find_child("FactoryInspectorRail", true, false) as Panel
	var inspector_scroll := workspace.find_child("InspectorScroll", true, false) as Control
	var workspace_rect: Rect2 = workspace.get_global_rect()
	var expected_inspector_width := float(UiTokens.layout_px(312))
	_check(
		long_card != null and second_long_card != null and long_card_name != null and second_long_card_name != null
		and long_card_name.text == "High-Energy Electronics Works" and second_long_card_name.text == "Research Complex Expansion II"
		and long_card_name.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and not long_card_name.clip_text
		and is_equal_approx(long_card.get_parent().size.x, second_long_card.get_parent().size.x)
		and center_column != null and inspector_rail != null and inspector_scroll != null
		and absf(inspector_rail.size.x - expected_inspector_width) < 1.1 and inspector_scroll.size.x < inspector_rail.size.x
		and palette.get_global_rect().end.x <= inspector_scroll.get_global_rect().position.x + 0.5
		and inspector_scroll.get_global_rect().end.x <= workspace_rect.end.x + 0.5
		and filter_scroll != null and filter_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO,
		"long building names remain fully present in equal-width two-line construction cards, while the inspector keeps a fixed narrow rail"
	)
	var dock_toggle := workspace.find_child("FactoryBuildPaletteToggle", true, false) as Button
	var canvas: Control = workspace.canvas()
	var expanded_canvas_height: float = canvas.size.y
	var collapsed_dock_height := float(UiTokens.layout_px(32))
	if dock_toggle != null:
		dock_toggle.pressed.emit()
	await _settle()
	_check(palette.is_collapsed() and palette.size.y <= collapsed_dock_height + 1.0 and canvas.size.y > expanded_canvas_height, "an explicit construction-dock toggle returns vertical area to the canvas without a window-size breakpoint")
	if dock_toggle != null:
		dock_toggle.pressed.emit()
	await _settle()
	_check(not palette.is_collapsed() and palette.size.y >= 100.0, "the same explicit control restores the authored construction dock")
	var road_snapshot := _fixture_snapshot()
	road_snapshot["logistics_mode"] = "PLANET_SHARED_ROADS"
	road_snapshot["roads"] = []
	road_snapshot["road_logistics"] = {"required":0, "capacity":0, "active_shipments":0, "utilization":0.0}
	workspace.apply_snapshot(road_snapshot)
	await _settle()
	var road_build := workspace.find_child("FactoryRoadTierOne", true, false) as Button
	if road_build != null:
		road_build.pressed.emit()
	_check(road_build != null and str(workspace.get("_active_tool")) == "ROAD_BUILD" and str(canvas.get("_road_tool_mode")) == "BUILD", "the visible road-build control activates the matching canvas road tool")
	var road_intent_count := intents.size()
	if dock_toggle != null:
		dock_toggle.pressed.emit()
	await _settle()
	_check(
		road_build != null and str(workspace.get("_active_tool")) != "ROAD_BUILD" and str(canvas.get("_road_tool_mode")) == "" and intents.size() == road_intent_count,
		"collapsing the dock exits an active road tool, clears its canvas mode, and cannot issue a hidden road command"
	)
	if dock_toggle != null:
		dock_toggle.pressed.emit()
	await _settle()
	workspace.apply_snapshot(_fixture_snapshot())
	if all_filter != null:
		all_filter.pressed.emit()


func _test_chunk_spatial_index() -> void:
	var index = ChunkIndexScript.new()
	index.rebuild({
		"chunk_size_tiles":64,
		"bounds":{"origin":{"x":100, "y":200}, "size":{"x":256, "y":160}},
		"resource_fields":[
			{"id":"z-resource", "footprint":{"origin":{"x":100, "y":200}, "size":{"x":8, "y":8}}},
			{"id":"a-edge-resource", "footprint":{"origin":{"x":348, "y":352}, "size":{"x":8, "y":8}}}
		],
		"entities":[
			{"id":"z-crossing", "footprint":{"origin":{"x":155, "y":220}, "size":{"x":16, "y":8}}},
			{"id":"a-near", "footprint":{"origin":{"x":150, "y":240}, "size":{"x":8, "y":8}}},
			{"id":"a-edge", "footprint":{"origin":{"x":348, "y":352}, "size":{"x":8, "y":8}}},
			{"id":"wide-source", "footprint":{"origin":{"x":140, "y":280}, "size":{"x":40, "y":8}}},
			{"id":"wide-target", "footprint":{"origin":{"x":105, "y":280}, "size":{"x":8, "y":8}}}
		],
		"construction_orders":[{"id":"z-order", "footprint":{"origin":{"x":155, "y":220}, "size":{"x":8, "y":8}}}],
		"links":[
			{"id":"cross-world-route", "source_id":"z-crossing", "target_id":"a-edge"},
			{"id":"port-cross-route", "source_id":"wide-source", "target_id":"wide-target"}
		]
	})
	var first_chunk: Dictionary = index.query(Rect2(150, 220, 4, 4))
	var crossing_chunk: Dictionary = index.query(Rect2(164, 220, 4, 4))
	var final_partial_chunk: Dictionary = index.query(Rect2(348, 352, 4, 4))
	var port_only_chunk: Dictionary = index.query(Rect2(170, 282, 2, 2))
	_check(
		index.chunk_size_tiles() == 64
		and first_chunk.get("chunk_keys", []) == ["0:0"]
		and first_chunk.get("entity_ids", []) == ["a-near", "z-crossing"]
		and crossing_chunk.get("entity_ids", []) == ["z-crossing"]
		and final_partial_chunk.get("chunk_keys", []) == ["3:2"]
		and final_partial_chunk.get("resource_ids", []) == ["a-edge-resource"]
		and final_partial_chunk.get("entity_ids", []) == ["a-edge"]
		and final_partial_chunk.get("link_ids", []) == ["cross-world-route"],
		"chunk index handles non-zero origins, sorted cross-chunk records, links, and Earth’s partial edge chunk"
	)
	_check(port_only_chunk.get("link_ids", []).has("port-cross-route"), "link indexing conservatively includes chunks reached by edge ports outside the endpoint-center path")


func _test_finite_canvas_bounds(workspace) -> void:
	var canvas = workspace.canvas()
	_check(canvas._chunk_boundary_offsets(160, 0, 2, 64) == [64, 128] and canvas._chunk_boundary_offsets(256, 0, 3, 64) == [64, 128, 192], "partial chunks draw only internal boundaries and never a full-chunk line beyond the planet edge")
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
	canvas.focus_tile(Vector2i(255, 159))
	canvas._move_keyboard_tile(Vector2i.RIGHT)
	canvas._move_keyboard_tile(Vector2i.DOWN)
	_check(canvas.get("_keyboard_tile") == Vector2i(255, 159), "keyboard navigation stops on the final in-bounds tile")
	canvas.focus_tile(Vector2i(-50, -50))
	_check(canvas.get("_keyboard_tile") == Vector2i.ZERO, "programmatic focus clamps to the finite canvas origin")
	var selected_tiles: Array = []
	canvas.tile_selected.connect(func(tile: Vector2i) -> void: selected_tiles.append(tile))
	canvas._select_tile(canvas._world_screen_rect().position - Vector2(8.0, 8.0))
	_check(selected_tiles.is_empty(), "clicking beyond the visible world boundary emits no placement tile")
	var shifted_snapshot := _fixture_snapshot()
	shifted_snapshot["bounds"] = {"origin":{"x":100, "y":200}, "size":{"x":256, "y":160}}
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


func _test_factory_information_controls(workspace) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_solar_array")
	var building_card: Node = workspace.find_child("BuildingSelectionCard", true, false)
	var placement_status := workspace.find_child("PlacementStatus", true, false) as Label
	var placement_hint := workspace.find_child("BuildingDeploymentHint", true, false) as Label
	var cancel_placement := workspace.find_child("CancelPlacement", true, false) as Button
	var inspector := workspace.find_child("FactoryInspector", true, false) as VBoxContainer
	_check(
		building_card == null and inspector != null and placement_status != null and placement_hint != null and inspector.is_ancestor_of(placement_status)
		and placement_status.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and not placement_status.clip_text
		and placement_hint.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and not placement_hint.clip_text
		and cancel_placement != null and cancel_placement.visible and cancel_placement.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART and not cancel_placement.clip_text,
		"the redundant construction card is removed; wrapped placement facts and an untruncated cancellation action live in the fixed right inspector"
	)
	if cancel_placement != null:
		cancel_placement.pressed.emit()
	_check(str(workspace.get("_active_tool")) != "BUILD", "construction-card cancellation leaves placement mode without a command")

	workspace._on_entity_selected(_snapshot_entity(workspace, "mine-a"))
	var entity_header := workspace.find_child("EntityInspectorHeader", true, false) as HBoxContainer
	var entity_status := workspace.find_child("EntityInspectorStatus", true, false) as Label
	var entity_telemetry := workspace.find_child("EntityInspectorTelemetry", true, false) as Label
	var mining_context := workspace.find_child("ExtractorMiningContext", true, false) as Label
	_check(
		entity_header != null and entity_status != null and entity_telemetry != null and entity_telemetry.text.contains("0.00/s") and entity_telemetry.text.contains("100%")
		and workspace.find_child("EntityPowerMeter", true, false) != null and workspace.find_child("ExtractorCoverageMeter", true, false) != null
		and mining_context != null and mining_context.get_index() > entity_header.get_index(),
		"extractor inspector prioritizes identity, status, rate and power before the circular mining range, coverage and grade"
	)
	workspace._on_resource_field_selected(_snapshot_resource(workspace, "iron-field"))
	var build_extractor := workspace.find_child("BuildExtractor", true, false) as Button
	_check(build_extractor != null, "resource inspector offers a compatible extractor placement action")
	if build_extractor != null:
		build_extractor.pressed.emit()
	_check(str(workspace.get("_active_tool")) == "BUILD" and str(workspace.get("_selected_building_id")) == "grid_surface_mine", "resource inspector starts an extractor placement preview without mutating factory state")
	workspace._on_placement_cancelled()


func _test_left_mouse_pan(workspace, intents: Array) -> void:
	var canvas = workspace.canvas()
	canvas.apply_snapshot(_fixture_snapshot())
	canvas.reset_camera()
	for _step in range(24):
		canvas._adjust_zoom(1.14)
	canvas.focus_tile(Vector2i(128, 80))
	await _force_canvas_draw(canvas)
	var start: Vector2 = canvas.size * 0.5 + Vector2.ONE * canvas._tile_scale() * 0.5
	_check(not canvas._point_has_interactive_hit(start), "left-pan fixture starts on empty canvas space")
	var before_camera: Vector2 = canvas.get("_camera")
	var before_intents := intents.size()
	var selected_tiles: Array[Vector2i] = []
	canvas.tile_selected.connect(func(tile: Vector2i) -> void: selected_tiles.append(tile))
	canvas._on_gui_input(_left_button(start, true))
	canvas._on_gui_input(_mouse_motion(start + Vector2(42, 26)))
	canvas._on_gui_input(_left_button(start + Vector2(42, 26), false))
	var after_camera: Vector2 = canvas.get("_camera")
	_check(after_camera.distance_to(before_camera) > 20.0 and selected_tiles.is_empty() and intents.size() == before_intents, "holding left mouse on empty space pans the finite canvas without selecting or issuing a command")
	var click_point: Vector2 = canvas.size * 0.5 + Vector2(70, 40)
	_check(not canvas._point_has_interactive_hit(click_point), "stationary-click fixture remains on empty canvas space after panning")
	canvas._on_gui_input(_left_button(click_point, true))
	canvas._on_gui_input(_mouse_motion(click_point + Vector2(3, 2)))
	canvas._on_gui_input(_left_button(click_point + Vector2(3, 2), false))
	_check(selected_tiles.size() == 1 and (canvas.get("_left_pointer") as Dictionary).is_empty(), "movement below the 8px screen threshold remains a normal tile click")
	canvas.reset_camera()


func _test_hover_deduplication(workspace) -> void:
	var canvas = workspace.canvas()
	canvas.focus_tile(Vector2i.ZERO)
	var hovered: Array[Vector2i] = []
	canvas.tile_hovered.connect(func(tile: Vector2i) -> void: hovered.append(tile))
	var first_point: Vector2 = canvas._world_to_screen(Vector2(5, 5)) + Vector2.ONE * canvas._tile_scale() * 0.5
	canvas._on_gui_input(_mouse_motion(first_point))
	canvas._on_gui_input(_mouse_motion(first_point + Vector2.ONE * 0.1))
	var adjacent_point: Vector2 = canvas._world_to_screen(Vector2(6, 5)) + Vector2.ONE * canvas._tile_scale() * 0.5
	canvas._on_gui_input(_mouse_motion(adjacent_point))
	_check(hovered == [Vector2i(5, 5), Vector2i(6, 5)], "repeated mouse motion inside one tile emits one placement-precheck signal")


func _test_canvas_scale_contract(workspace) -> void:
	var canvas = workspace.canvas()
	var earth_snapshot := _fixture_snapshot()
	earth_snapshot["world_id"] = "earth-canvas"
	earth_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":256, "y":160}}
	earth_snapshot["world_profile"] = {"profile_id":"earth", "scale_class":"HUB", "size_tiles":{"x":256, "y":160}}
	canvas.apply_snapshot(earth_snapshot)
	canvas.reset_camera()
	var earth_rect: Rect2 = canvas._world_screen_rect()
	var overview_zoom: float = float(canvas.get("_zoom"))

	var mars_snapshot := _fixture_snapshot()
	mars_snapshot["world_id"] = "mars-canvas"
	mars_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":384, "y":240}}
	mars_snapshot["world_profile"] = {"profile_id":"mars", "scale_class":"INDUSTRIAL", "size_tiles":{"x":384, "y":240}}
	canvas.apply_snapshot(mars_snapshot)
	canvas.reset_camera()
	var mars_rect: Rect2 = canvas._world_screen_rect()
	var large_snapshot := _fixture_snapshot()
	large_snapshot["world_id"] = "large-canvas"
	large_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":768, "y":480}}
	large_snapshot["world_profile"] = {"profile_id":"large", "scale_class":"CAPITAL", "size_tiles":{"x":768, "y":480}}
	canvas.apply_snapshot(large_snapshot)
	canvas.reset_camera()
	var large_rect: Rect2 = canvas._world_screen_rect()
	_check(
		is_equal_approx(mars_rect.size.x, earth_rect.size.x * 1.5)
		and is_equal_approx(mars_rect.size.y, earth_rect.size.y * 1.5)
		and is_equal_approx(large_rect.size.x, earth_rect.size.x * 3.0)
		and is_equal_approx(large_rect.size.y, earth_rect.size.y * 3.0)
		and is_equal_approx(float(canvas.get("_zoom")), overview_zoom),
		"Earth, Mars-size, and large planets retain proportional shared overview scale"
	)
	_check(
		large_rect.size.x > canvas.size.x
		and large_rect.size.y > canvas.size.y,
		"reset keeps a bounded local view instead of fitting the entire large planet"
	)
	_check(canvas.size.x * canvas.size.y / pow(canvas._tile_scale(), 2) <= float(CanvasScript.MAX_VISIBLE_CAMERA_TILES) + 1.0 and is_equal_approx(canvas._tile_scale(), 4.0 * float(canvas.get("_zoom"))), "zoom-out preserves the visible-tile budget without a hidden scale multiplier")

	var anchor: Vector2 = canvas.size * 0.5
	var anchor_world: Vector2 = canvas._screen_to_world(anchor)
	canvas._set_zoom_around(anchor, anchor_world, float(canvas.get("_zoom")) * 1.5)
	_check(canvas._screen_to_world(anchor).distance_to(anchor_world) < 0.001, "pointer zoom preserves the exact floating-point world anchor")
	var preserved_zoom: float = float(canvas.get("_zoom"))
	var preserved_camera: Vector2 = canvas.get("_camera")
	var chunk_index = canvas.get("_chunk_index")
	var rebuilds_before_runtime := int(chunk_index.rebuild_count())
	var chunk_signature_before_runtime := str(canvas.get("_chunk_index_signature"))
	large_snapshot["runtime_revision"] = int(large_snapshot.get("runtime_revision", 0)) + 1
	canvas.apply_snapshot(large_snapshot)
	var refreshed_camera: Vector2 = canvas.get("_camera")
	_check(is_equal_approx(float(canvas.get("_zoom")), preserved_zoom) and refreshed_camera.distance_to(preserved_camera) < 0.001 and int(chunk_index.rebuild_count()) == rebuilds_before_runtime and str(canvas.get("_chunk_index_signature")) == chunk_signature_before_runtime, "same-world runtime refresh preserves camera and reuses the topology chunk index")

	for _step in range(80):
		canvas._adjust_zoom(1.14)
	var detail_rect: Rect2 = canvas._world_screen_rect()
	var detail_cap := float(CanvasScript.MAX_DETAIL_TILE_PIXELS)
	_check(canvas._tile_scale() <= detail_cap + 0.001 and canvas._tile_scale() >= detail_cap - 0.01 and maxf(detail_rect.size.x, detail_rect.size.y) > 4096.0, "large planets keep the shared player-camera detail ceiling without shrinking the whole world")

	(large_snapshot["entities"] as Array).append(_entity("far-offscreen", "POWER", "Far Unit", Vector2i(700, 440), {"inputs":[], "outputs":[], "accepts_power":false, "provides_power":true}))
	large_snapshot["topology_revision"] = int(large_snapshot.get("topology_revision", 0)) + 1
	canvas.apply_snapshot(large_snapshot)
	_check(int(chunk_index.rebuild_count()) == rebuilds_before_runtime + 1 and str(canvas.get("_chunk_index_signature")) != chunk_signature_before_runtime, "topology revision rebuilds the spatial chunk index exactly once")
	canvas.focus_tile(Vector2i.ZERO)
	await _force_canvas_draw(canvas)
	canvas._ensure_hit_geometry()
	_check(not (canvas.get("_visible_records") as Dictionary).get("entity_ids", []).has("far-offscreen") and not (canvas.get("_node_rects") as Dictionary).has("far-offscreen"), "drawing and hit-testing query only the current viewport chunks")

	var malformed_snapshot := _fixture_snapshot()
	malformed_snapshot["world_id"] = "defensive-oversized-canvas"
	malformed_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":2560, "y":960}}
	malformed_snapshot["resource_fields"] = []
	malformed_snapshot["entities"] = []
	malformed_snapshot["construction_orders"] = []
	canvas.apply_snapshot(malformed_snapshot)
	canvas.reset_camera()
	var malformed_rect: Rect2 = canvas._world_screen_rect()
	_check(malformed_rect.size.x > canvas.size.x and canvas.size.x * canvas.size.y / pow(canvas._tile_scale(), 2) <= float(CanvasScript.MAX_VISIBLE_CAMERA_TILES) + 1.0, "oversized snapshot cannot force the camera outside its visible-tile budget")

	var normal_canvas_size: Vector2 = canvas.size
	var tiny_snapshot := _fixture_snapshot()
	tiny_snapshot["world_id"] = "tiny-canvas"
	tiny_snapshot["bounds"] = {"origin":{"x":0, "y":0}, "size":{"x":64, "y":64}}
	tiny_snapshot.erase("canvas_limits")
	canvas.size = Vector2(8192, 8192)
	canvas.apply_snapshot(tiny_snapshot)
	canvas.reset_camera()
	_check(canvas._tile_scale() <= detail_cap + 0.001, "tile-detail cap remains hard even in an oversized viewport")
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
	flowing_snapshot["topology_revision"] = int(flowing_snapshot.get("topology_revision", 0)) + 1
	flowing_snapshot["links"] = [{"id":"active-power", "kind":"POWER", "source_id":"power-a", "target_id":"mine-a", "status":"FLOWING", "last_flow":1.0, "utilization":0.5}]
	canvas.apply_snapshot(flowing_snapshot)
	canvas.reset_camera()
	while canvas._tile_scale() < 0.75:
		canvas._adjust_zoom(1.14)
	canvas.focus_tile(Vector2i(20, 20))
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
	dense_snapshot["topology_revision"] = int(dense_snapshot.get("topology_revision", 0)) + 1
	canvas.apply_snapshot(dense_snapshot)
	canvas.reset_camera()
	while canvas._tile_scale() < 0.75:
		canvas._adjust_zoom(1.14)
	canvas.focus_tile(Vector2i(20, 20))
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
		and str(intent.get("kind", "")) == "DEPLOY_BUILDING"
		and str(intent.get("world_id", "")) == "ui-grid"
		and int(intent.get("base_topology_revision", -1)) == 17
		and int(intent.get("base_runtime_revision", -1)) == 9
		and str(payload.get("definition_id", "")) == "grid_solar_array"
		and str(payload.get("recipe_id", "not-empty")) == ""
		and not payload.has("funding_policy")
		and int((payload.get("origin", {}) as Dictionary).get("x", -1)) == 100,
		"deployment intent preserves protocol, immutable revision, empty recipe and selected footprint origin without onsite funding"
	)


func _test_recipe_change_intent(workspace, intents: Array) -> void:
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	var selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	var apply_button := workspace.find_child("ApplyEntityRecipe", true, false) as Button
	_check(selector != null and apply_button == null, "machine inspector applies a recipe directly from the entity selector")
	if selector == null:
		return
	_select_metadata(selector, "grid_refine_copper")
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(str(intent.get("kind", "")) == "SET_RECIPE" and str(payload.get("entity_id", "")) == "smelter-a" and str(payload.get("recipe_id", "")) == "grid_refine_copper", "machine inspector emits only a versioned SET_RECIPE intent")


func _test_machine_configuration_clipboard(workspace, intents: Array) -> void:
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	var copy_button := workspace.find_child("CopyMachineConfiguration", true, false) as Button
	var paste_button := workspace.find_child("PasteMachineConfiguration", true, false) as Button
	_check(copy_button != null and paste_button != null, "machine Inspector exposes stable copy and paste configuration controls")
	if copy_button == null or paste_button == null:
		return
	copy_button.pressed.emit()
	var copied: Dictionary = workspace.get("_copied_machine_config")
	_check(str(copied.get("recipe_id", "")) == "grid_refine_iron" and not copied.has("inventory") and not copied.has("progress") and not copied.has("links"), "copy stores only safe recipe metadata and never runtime cargo or topology")
	var before_paste := intents.size()
	paste_button = workspace.find_child("PasteMachineConfiguration", true, false) as Button
	if paste_button != null:
		paste_button.pressed.emit()
	var pasted: Dictionary = intents.back() as Dictionary if intents.size() > before_paste else {}
	_check(intents.size() == before_paste + 1 and str(pasted.get("kind", "")) == "SET_RECIPE" and str((pasted.get("payload", {}) as Dictionary).get("entity_id", "")) == "smelter-a" and str((pasted.get("payload", {}) as Dictionary).get("recipe_id", "")) == "grid_refine_iron", "compatible paste reuses the existing SET_RECIPE intent")
	workspace._on_entity_selected(_snapshot_entity(workspace, "power-a"))
	var before_incompatible := intents.size()
	workspace._paste_machine_configuration()
	_check(intents.size() == before_incompatible and str((workspace.get("_feedback_label") as Label).text).contains("MACHINE_CONFIG_REQUIRES_MACHINE"), "incompatible paste is rejected locally without emitting a command")

	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	workspace.set("_copied_machine_config", {})
	var text_input := LineEdit.new()
	text_input.name = "MachineConfigShortcutTextInput"
	workspace.add_child(text_input)
	text_input.grab_focus()
	var blocked_copy := InputEventKey.new()
	blocked_copy.pressed = true
	blocked_copy.ctrl_pressed = true
	blocked_copy.keycode = KEY_C
	workspace._unhandled_key_input(blocked_copy)
	_check((workspace.get("_copied_machine_config") as Dictionary).is_empty(), "Ctrl/Cmd+C is not hijacked while a text input owns focus")
	text_input.release_focus()
	text_input.queue_free()
	workspace._on_placement_cancelled()
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	workspace.grab_focus()
	workspace._unhandled_key_input(blocked_copy)
	_check(not (workspace.get("_copied_machine_config") as Dictionary).is_empty(), "Ctrl/Cmd+C copies the selected machine configuration when workspace owns focus")
	var before_shortcut_paste := intents.size()
	var shortcut_paste := InputEventKey.new()
	shortcut_paste.pressed = true
	shortcut_paste.meta_pressed = true
	shortcut_paste.keycode = KEY_V
	workspace._unhandled_key_input(shortcut_paste)
	_check(intents.size() == before_shortcut_paste + 1 and str((intents.back() as Dictionary).get("kind", "")) == "SET_RECIPE", "Ctrl/Cmd+V pastes the copied recipe through the existing machine command")
	var building_palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(building_palette, "grid_solar_array")
	var before_build_shortcut := intents.size()
	workspace._unhandled_key_input(shortcut_paste)
	_check(intents.size() == before_build_shortcut, "machine configuration shortcuts do not fire while BUILD placement is active")
	workspace._on_placement_cancelled()
	workspace.set("_copied_machine_config", {})
	workspace._set_connection_mode("CARGO")
	workspace._unhandled_key_input(blocked_copy)
	_check((workspace.get("_copied_machine_config") as Dictionary).is_empty(), "machine configuration shortcuts do not fire while CONNECT routing is active")
	workspace._on_placement_cancelled()


func _test_canvas_configuration_gestures(workspace, intents: Array) -> void:
	workspace._on_placement_cancelled()
	var canvas = workspace.canvas()
	var machine := _snapshot_entity(workspace, "smelter-a")
	var point: Vector2 = canvas._footprint_rect(machine.get("footprint", {}), 4.0).get_center()
	var shift_copy := _right_click(point)
	shift_copy.shift_pressed = true
	canvas._on_gui_input(shift_copy)
	_check(str((workspace.get("_selection") as Dictionary).get("id", "")) == "smelter-a" and str((workspace.get("_feedback_label") as Label).text).contains("MACHINE_CONFIG_COPIED"), "Shift+right-click copies a visible machine recipe in neutral canvas mode")
	var before_paste := intents.size()
	var shift_paste := _left_click(point)
	shift_paste.shift_pressed = true
	canvas._on_gui_input(shift_paste)
	_check(intents.size() == before_paste + 1 and str((intents.back() as Dictionary).get("kind", "")) == "SET_RECIPE", "Shift+left-click pastes a compatible machine configuration through SET_RECIPE")
	workspace.set("_copied_machine_config", {})
	canvas._on_gui_input(_middle_button(point, true))
	canvas._on_gui_input(shift_copy)
	canvas._on_gui_input(_middle_button(point, false))
	_check((workspace.get("_copied_machine_config") as Dictionary).is_empty(), "middle-button panning keeps Shift machine-configuration gestures mutually exclusive")


func _test_machine_configuration_target_isolation(workspace, intents: Array) -> void:
	var multi_machine_snapshot := _fixture_snapshot()
	var target := _entity("smelter-b", "MACHINE", "Second Arc Smelter", Vector2i(90, 50), {"inputs":["copper_ore"], "outputs":["copper_ingot"], "accepts_power":true, "provides_power":false}, {"iron_ingot":3}, "grid_arc_smelter", "grid_refine_copper")
	target["inputs"] = {"copper_ore":7}
	target["outputs"] = {"copper_ingot":2}
	target["progress"] = 0.65
	var incompatible := _entity("engineering-a", "MACHINE", "Engineering Works", Vector2i(120, 50), {"inputs":["copper_ore"], "outputs":["copper_ingot"], "accepts_power":true, "provides_power":false}, {}, "grid_engineering_works", "grid_refine_copper")
	(multi_machine_snapshot.get("entities", []) as Array).append(target)
	(multi_machine_snapshot.get("entities", []) as Array).append(incompatible)
	(multi_machine_snapshot.get("palette", {}).get("buildings", []) as Array).append({"id":"grid_engineering_works", "name":"Engineering Works", "kind":"MACHINE", "footprint":{"width":12, "height":10}, "recipe_ids":["grid_refine_copper"]})
	workspace.apply_snapshot(multi_machine_snapshot)
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	workspace._copy_selected_machine_configuration()
	var copied: Dictionary = workspace.get("_copied_machine_config")
	_check(copied.size() == 4 and copied.has("schema_version") and copied.has("world_id") and copied.has("recipe_id") and copied.has("recipe_name"), "machine clipboard is a strict configuration whitelist without source entity state")

	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-b"))
	var target_before := JSON.stringify(_snapshot_entity(workspace, "smelter-b"))
	var before_target_paste := intents.size()
	workspace._paste_machine_configuration()
	var target_intent: Dictionary = intents.back() as Dictionary if intents.size() > before_target_paste else {}
	_check(
		intents.size() == before_target_paste + 1
		and str((target_intent.get("payload", {}) as Dictionary).get("entity_id", "")) == "smelter-b"
		and str((target_intent.get("payload", {}) as Dictionary).get("recipe_id", "")) == "grid_refine_iron"
		and JSON.stringify(_snapshot_entity(workspace, "smelter-b")) == target_before,
		"pasting to a second machine emits only its SET_RECIPE intent and cannot overwrite target buffers, inventory, progress, identity, or snapshot state"
	)

	workspace._on_entity_selected(_snapshot_entity(workspace, "engineering-a"))
	var before_incompatible := intents.size()
	workspace._paste_machine_configuration()
	_check(intents.size() == before_incompatible and str((workspace.get("_feedback_label") as Label).text).contains("MACHINE_CONFIG_INCOMPATIBLE"), "pasting onto an incompatible MACHINE is rejected locally without a command")
	workspace.apply_snapshot(_fixture_snapshot())
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))


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
	_check(revision_label != null and revision_label.text == "ⓘ" and revision_label.tooltip_text.contains("R11"), "deferred Inspector rebuild exposes the newest runtime revision")
	var focused_button := workspace.find_child("CopyMachineConfiguration", true, false) as Button
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
		"Escape cancels BUILD placement without emitting DEPLOY_BUILDING"
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
		"right-click cancels BUILD placement without emitting DEPLOY_BUILDING"
	)


func _test_connection_cancel(workspace, intents: Array) -> void:
	var intent_count_before := intents.size()
	workspace._set_connection_mode("CARGO")
	workspace.canvas()._on_gui_input(_right_click(Vector2.ZERO))
	_check(
		intents.size() == intent_count_before
		and str(workspace.get("_active_tool")) != "CONNECT"
		and str(workspace.get("_connection_source_id")).is_empty(),
		"right-click cancels CONNECT before endpoint selection without emitting a command"
	)
	workspace._set_connection_mode("POWER")
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	workspace.canvas()._on_gui_input(escape)
	_check(intents.size() == intent_count_before and str(workspace.get("_active_tool")) != "CONNECT", "Escape cancels CONNECT without emitting a command")


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
	workspace.apply_command_result({
		"accepted":true,
		"protocol_version":1,
		"world_id":"ui-grid",
		"command_kind":"CONNECT_ENTITIES",
		"result":{"link_id":"new-cargo"}
	})
	var connected_snapshot := _fixture_snapshot()
	connected_snapshot["topology_revision"] = 18
	connected_snapshot["links"] = [{"id":"new-cargo", "kind":"CARGO", "source_id":"mine-a", "target_id":"smelter-a", "item_id":"iron_ore", "status":"IDLE", "last_flow":0.0, "capacity_per_second":1.0}]
	workspace.apply_snapshot(connected_snapshot)
	_check(
		workspace.canvas().selected_link_id() == "new-cargo"
		and str((workspace.get("_selection") as Dictionary).get("kind", "")) == "LINK"
		and str((workspace.get("_selection") as Dictionary).get("id", "")) == "new-cargo",
		"accepted CONNECT selects the returned link after the fresh immutable snapshot arrives"
	)
	var intent_count_after_connect := intents.size()
	workspace._set_connection_mode("CARGO")
	workspace._on_entity_selected(_snapshot_entity(workspace, "mine-a"))
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	workspace._request_connection()
	_check(
		intents.size() == intent_count_after_connect
		and workspace._connection_validation_reason(_snapshot_entity(workspace, "mine-a"), _snapshot_entity(workspace, "smelter-a")) == "DUPLICATE_LINK",
		"duplicate cargo routes are explained and blocked before emitting an intent"
	)
	workspace._set_connection_mode("CARGO")
	workspace._on_entity_selected(_snapshot_entity(workspace, "storage-a"))
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	workspace._request_connection()
	_check(
		intents.size() == intent_count_after_connect
		and workspace._connection_validation_reason(_snapshot_entity(workspace, "storage-a"), _snapshot_entity(workspace, "smelter-a")) == "CARGO_INPUT_OCCUPIED",
		"occupied target item ports are explained and blocked before emitting an intent"
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
	_check(refreshes.size() == 2 and str(refreshes[0]) == "ui-grid" and str(refreshes[1]) == "ui-grid", "command results request a fresh immutable snapshot from the host")
	workspace.set_reduced_motion(true)
	_check(bool(workspace.canvas().get("_reduced_motion")), "reduced-motion setter propagates to the animated Factory canvas")


func _test_keyboard_canvas_action(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_solar_array")
	var canvas = workspace.canvas()
	canvas.focus_tile(Vector2i.ZERO)
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
		and str(intent.get("kind", "")) == "DEPLOY_BUILDING"
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
	# The 11×11 Core Extractor stays inside the ore field while ending immediately
	# before the existing ghost at (24, 24); this isolates preview-hit priority
	# from authoritative construction-overlap rejection.
	var extractor_tile := Vector2i(13, 13)
	var extractor_point: Vector2 = canvas._world_to_screen(Vector2(extractor_tile)) + Vector2.ONE * canvas._tile_scale() * 0.5
	canvas._on_gui_input(_mouse_motion(extractor_point))
	canvas._on_gui_input(_left_click(extractor_point))
	var extractor_intent: Dictionary = intents.back() as Dictionary
	var extractor_payload: Dictionary = extractor_intent.get("payload", {})
	_check(
		str(extractor_intent.get("kind", "")) == "DEPLOY_BUILDING"
		and Vector2i(int((extractor_payload.get("origin", {}) as Dictionary).get("x", -1)), int((extractor_payload.get("origin", {}) as Dictionary).get("y", -1))) == extractor_tile
		and str((workspace.get("_selection") as Dictionary).get("kind", "")) != "RESOURCE_FIELD",
		"a real mouse click on an extractor preview over a resource field emits construction instead of selecting the field"
	)
	workspace._on_placement_cancelled()
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
	return _left_button(point, true)


func _left_button(point: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = point
	return event


func _right_click(point: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_RIGHT
	event.pressed = true
	event.position = point
	return event


func _middle_button(point: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_MIDDLE
	event.pressed = pressed
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
		"canvas_limits":{"max_world_size_tiles":{"x":768, "y":480}},
		"world_profile":{"profile_id":"factory_earth_hub_v1", "scale_class":"HUB", "size_tiles":{"x":256, "y":160}},
		"chunk_size_tiles":64,
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":256, "y":160}},
		"resource_fields":[
			{"id":"iron-field", "resource_id":"iron_ore", "resource_category":"solid", "resource_color":"#B45F45", "grade":1.0, "potential_density":0.25, "mapped_potential_per_second":144.0, "footprint":{"origin":{"x":12, "y":12}, "size":{"x":24, "y":24}}, "ports":{"inputs":[], "outputs":[], "accepts_power":false}}
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
			{"id":"grid_solar_array", "name":"Surface Solar Array", "kind":"POWER", "footprint":{"width":8, "height":8}, "power_generation_kw":100.0, "construction_work":10.0, "construction_cost":[{"item":"scrap_metal", "quantity":2}], "recipe_ids":[]},
			{"id":"grid_surface_mine", "name":"Surface Mine", "kind":"EXTRACTOR", "footprint":{"width":11, "height":11}, "mining_radius_tiles":18.0, "power_demand_kw":50.0, "resource_categories":["solid"], "construction_work":20.0, "construction_cost":[{"item":"scrap_metal", "quantity":4}], "recipe_ids":[]},
			{"id":"grid_arc_smelter", "name":"Arc Smelter", "kind":"MACHINE", "footprint":{"width":16, "height":12}, "power_demand_kw":60.0, "construction_work":20.0, "construction_cost":[{"item":"scrap_metal", "quantity":4}], "recipe_ids":["grid_refine_iron", "grid_refine_copper"]}
		],
		"recipes":[
			{"id":"grid_refine_iron", "name":"Grid Iron Refining", "duration_seconds":2.0, "inputs":[{"item":"iron_ore", "quantity":1}], "outputs":[{"item":"iron_ingot", "quantity":1}]},
			{"id":"grid_refine_copper", "name":"Grid Copper Refining", "duration_seconds":6.0, "inputs":[{"item":"copper_ore", "quantity":1}], "outputs":[{"item":"copper_ingot", "quantity":1}]}
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
		"actual_rate":0.0,
		"resource_id":"iron_ore" if kind == "EXTRACTOR" else "",
		"coverage_efficiency":1.0 if kind == "EXTRACTOR" else 0.0,
		"average_grade":1.0 if kind == "EXTRACTOR" else 0.0,
		"sustainable_rate_per_second":2.25 if kind == "EXTRACTOR" else 0.0,
		"mining_radius_tiles":18.0 if kind == "EXTRACTOR" else 0.0,
		"mining_area_tiles":1009 if kind == "EXTRACTOR" else 0,
		"covered_resource_tiles":9 if kind == "EXTRACTOR" else 0,
		"footprint_tiles":9 if kind == "EXTRACTOR" else 0,
		"missing_resource_tiles":0
	}


func _snapshot_entity(workspace, entity_id: String) -> Dictionary:
	for entity_value in (workspace.get("_snapshot") as Dictionary).get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity.duplicate(true)
	return {}


func _snapshot_resource(workspace, field_id: String) -> Dictionary:
	for field_value in (workspace.get("_snapshot") as Dictionary).get("resource_fields", []):
		var field := field_value as Dictionary
		if str(field.get("id", "")) == field_id:
			return field.duplicate(true)
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
