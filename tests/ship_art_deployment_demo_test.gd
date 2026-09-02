extends Node

const DemoScene = preload("res://src/ui/demos/ship_art_deployment_demo.tscn")
const ShipPortGlyphScript = preload("res://src/ui/components/ship_port_glyph.gd")

const PLAN_ID := "construct_lunar_pathfinder"
const HULL_ID := "lunar_pathfinder"
const FITTINGS: Array[Array] = [
	["light_autocannon", "socket_weapon_0"],
	["civilian_shield", "socket_shield_0"],
	["advanced_drive", "socket_drive_0"],
	["sensor_array", "socket_utility_0"],
	["cargo_expansion", "socket_utility_1"],
	["civilian_reactor_core", "socket_core_0"]
]

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	Game.state.unlocked_ship_plans[PLAN_ID] = true
	get_tree().root.remove_meta("ship_assembly_demo_font_scale")
	get_window().size = Vector2i(1600, 1000)
	var demo := DemoScene.instantiate()
	add_child(demo)
	await _frames(5)
	var canvas := demo.find_child("ShipAssemblyMap", true, false) as GraphEdit
	var library := demo.find_child("ShipAssemblyLibrary", true, false) as PanelContainer
	var data_panel := demo.find_child("ShipAssemblyDataPanel", true, false) as PanelContainer
	var command_bar := demo.find_child("BlueprintCommandBar", true, false) as PanelContainer
	var canvas_region := demo.find_child("BlueprintCanvasRegion", true, false) as PanelContainer
	_check(canvas != null and library != null and data_panel != null and command_bar != null and canvas_region != null, "production demo exposes command bar, library, real canvas and engineering data panel")
	if canvas == null or library == null or data_panel == null:
		_finish()
		return
	_check(demo.scale.is_equal_approx(Vector2.ONE), "Demo keeps native CanvasItem scale so enlarged text is rerasterized instead of interpolated and blurred")
	_check(is_equal_approx(float(demo.call("effective_font_scale_for_output", Vector2(2880.0, 1800.0), 1.0)), 2.0), "a doubled output resolution doubles native font rasterization size")
	var library_eyebrow := demo.find_child("AssemblyLibraryEyebrow", true, false) as Label
	_check(library_eyebrow != null and library_eyebrow.get_theme_font_size("font_size") >= 15, "the 1600×1000 test window natively rerasterizes text above the 1440×900 baseline")
	var font_scale_picker := demo.find_child("ShipAssemblyFontScale", true, false) as OptionButton
	_check(font_scale_picker != null and font_scale_picker.item_count == 6, "font-size control exposes exactly 75, 100, 125, 150, 175 and 200 percent")
	if font_scale_picker != null:
		var scale_ids: Array[int] = []
		for scale_index in font_scale_picker.item_count:
			scale_ids.append(font_scale_picker.get_item_id(scale_index))
		_check(scale_ids == [75, 100, 125, 150, 175, 200] and font_scale_picker.get_item_id(font_scale_picker.selected) == 100, "font-size options follow the requested order and default to 100 percent")
	var select_tool := demo.find_child("ShipAssemblySelectTool", true, false) as Button
	var pan_tool := demo.find_child("ShipAssemblyPanTool", true, false) as Button
	_check(select_tool != null and pan_tool != null and select_tool.custom_minimum_size.x >= 51.0 and pan_tool.custom_minimum_size.x >= 51.0, "small canvas tool symbols and their hit areas are enlarged by at least 150 percent")
	var window_width := float(get_window().size.x)
	var library_output_width := library.get_global_rect().size.x
	var data_output_width := data_panel.get_global_rect().size.x
	_check(library_output_width / window_width >= 0.20 and library_output_width / window_width <= 0.24, "left library occupies the required 20–24 percent desktop band")
	_check(data_output_width / window_width >= 0.18 and data_output_width / window_width <= 0.22, "right engineering panel occupies the required 18–22 percent desktop band (actual=%s)" % data_output_width)
	_check(canvas_region.size.x > library.size.x * 2.3 and canvas_region.size.x > data_panel.size.x * 2.5, "center assembly canvas remains the dominant workspace (left=%s center=%s right=%s)" % [library.size.x, canvas_region.size.x, data_panel.size.x])
	_check(not canvas.minimap_enabled and not canvas.show_minimap_button, "redundant lower-right canvas overview remains removed")
	_check(is_equal_approx(canvas.zoom_max, 5.0), "canvas retains the full 500 percent inspection zoom")
	_check(demo.find_child("ShipAssemblySelectTool", true, false) is Button and demo.find_child("ShipAssemblyPanTool", true, false) is Button, "canvas toolbar exposes compact real selection and pan tools")
	canvas.call("set_canvas_tool", "PAN")
	_check(str(canvas.call("canvas_tool")) == "PAN", "pan toolbar control switches the real canvas interaction mode")
	canvas.call("set_canvas_tool", "SELECT")
	_check(str(canvas.call("canvas_tool")) == "SELECT", "selection toolbar control restores connection and object selection mode")
	var tabs := demo.find_child("AssemblyLibraryTabs", true, false) as TabContainer
	_check(tabs != null and tabs.get_tab_count() == 2 and tabs.get_tab_title(0) == "舰船" and tabs.get_tab_title(1) == "零件", "left library has exactly the authoritative SHIPS and MODULES tabs with readable locale-primary labels")
	_check(demo.find_child("DemoPortLegend", true, false) == null, "socket legend is no longer a permanent block competing with the asset library")
	_check(demo.find_child("SaveBlueprintButton", true, false) is Button and demo.find_child("BlueprintNameEdit", true, false) is LineEdit, "right action region owns blueprint naming and the prominent Save Blueprint action")
	_check(not _tree_text_contains(demo, "Paint") and not _tree_text_contains(demo, "Livery") and not _tree_text_contains(demo, "VALIDATION PASSED"), "demo introduces no paint, livery or validation-as-primary-action modes")
	_check((canvas.call("draft_snapshot") as Dictionary).get("nodes", []).is_empty(), "production blueprint editor starts with an intentional empty canvas")
	_check((demo.find_child("SaveBlueprintButton", true, false) as Button).disabled, "empty blueprint correctly disables save through authoritative validation")
	await _capture("01_full_blueprint_editor")
	await _capture("02_ships_tab")
	await _capture("04_empty_canvas")

	tabs.current_tab = 1
	await _frames(2)
	for fitting in FITTINGS:
		_check(demo.find_child("AssemblyModuleCard_%s" % str(fitting[0]), true, false) is Button, "%s is exposed as a draggable production module" % str(fitting[0]))
	var search := demo.find_child("AssemblyModuleSearch", true, false) as LineEdit
	var category := demo.find_child("AssemblyModuleCategory", true, false) as OptionButton
	_check(search != null and category != null and category.item_count == 7, "module library provides search plus compact functional category filtering")
	search.text = "reactor"
	search.text_changed.emit(search.text)
	await _frames(2)
	var module_cards := demo.find_child("AssemblyModuleCards", true, false) as VBoxContainer
	_check(module_cards != null and module_cards.get_child_count() == 1 and module_cards.get_child(0).name == "AssemblyModuleCard_civilian_reactor_core", "module search filters the real catalog without a parallel inventory")
	search.text = ""
	search.text_changed.emit(search.text)
	await _frames(2)
	await _capture("03_modules_tab")

	canvas.call("_drop_data", Vector2(canvas.size.x * 0.5, canvas.size.y * 0.34), {"ship_assembly_palette":true, "kind":"hull", "plan_id":PLAN_ID, "definition_id":HULL_ID})
	await _frames(4)
	var hull_node := canvas.get_node_or_null(NodePath("ship_design_hull")) as GraphNode
	_check(hull_node != null and hull_node.find_child("ShipHullVisual", true, false) != null, "Lunar Pathfinder uses the registered high-detail transparent hull visual")
	var measurements := demo.find_child("BlueprintHullMeasurements", true, false) as Label
	_check(measurements != null and measurements.text == "W 44m  ·  L 132m" and measurements.text.find("MAX T2") < 0, "canvas reports W 44m and L 132m without the removed MAX T2 text")
	if hull_node != null:
		canvas.call("_on_node_selected", hull_node)
	await _frames(2)
	_check(demo.find_child("AssemblyHullInspectorArtwork", true, false) is TextureRect, "selecting the hull opens the read-only engineering hull inspector")
	await _capture("07_selected_hull")

	for fitting_index in FITTINGS.size():
		var fitting := FITTINGS[fitting_index]
		var drop_x := 80.0 if fitting_index % 2 == 0 else maxf(430.0, canvas.size.x - 330.0)
		canvas.call("_drop_data", Vector2(drop_x, 64.0 + float(fitting_index / 2) * 165.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":str(fitting[0])})
		canvas.call("request_module_connection", "ship_design_module_%04d" % (fitting_index + 1), str(fitting[1]))
	await _frames(5)
	var populated := canvas.call("draft_snapshot") as Dictionary
	_check((populated.get("nodes", []) as Array).size() == 7 and (populated.get("connections", []) as Array).size() == 6, "real canvas places and connects the complete six-module blueprint")
	var expected_shapes := {"socket_weapon_0":"TRIANGLE", "socket_shield_0":"SQUARE", "socket_drive_0":"DIAMOND", "socket_utility_0":"PENTAGON", "socket_utility_1":"SQUARE", "socket_core_0":"CIRCLE"}
	for socket_id_value in expected_shapes.keys():
		var socket_id := str(socket_id_value)
		var socket_node := canvas.get_node_or_null(NodePath("ship_design_%s" % socket_id)) as GraphNode
		var glyph := _find_ship_port_glyph(socket_node)
		_check(glyph != null and str(glyph.get("shape")) == str(expected_shapes[socket_id]), "%s keeps its canonical functional socket geometry" % socket_id)
	var summary := Game.ship_design_engineering_summary(PLAN_ID, populated.get("nodes", []), populated.get("connections", []))
	_check(int(summary.get("module_count", 0)) == 6 and int(summary.get("connected_count", 0)) == 6, "right-panel module and connection counts come from the real draft summary")
	_check(float(summary.get("engineering", {}).get("totals", {}).get("mass", 0.0)) == 63.0, "right-panel total mass uses the shared content engineering calculation")
	_check(not (summary.get("construction_costs", {}) as Dictionary).is_empty() and not (summary.get("refit_costs", {}) as Dictionary).is_empty(), "build and refit estimates use real simulation BOM APIs")
	_check(str(summary.get("handoff_mode", "")) in ["REFIT", "BUILD_HULL"], "summary explicitly reports the downstream starport handoff path")
	var save_button := demo.find_child("SaveBlueprintButton", true, false) as Button
	_check(not save_button.disabled, "valid connected blueprint enables Save Blueprint")
	await _capture("05_populated_blueprint")
	demo.call("_on_entity_selected", "", "")
	await _frames(2)
	await _capture("13_blueprint_summary")
	await _capture("15_save_enabled")

	var module_node := canvas.get_node_or_null(NodePath("ship_design_module_0001")) as GraphNode
	if module_node != null:
		canvas.call("_on_node_selected", module_node)
	await _frames(2)
	_check(demo.find_child("AssemblyModuleInspector", true, false) != null, "selecting a canvas module opens the reusable data-driven module inspector")
	await _capture("06_selected_module")
	await _capture("14_module_inspector")

	var active_link := (canvas.get("_links") as Array)[0] as Dictionary
	var active_path := canvas.call("_world_path_for_link", active_link) as PackedVector2Array
	var active_point := active_path[active_path.size() / 2] * canvas.zoom - canvas.scroll_offset
	canvas.call("_select_connection_at", active_point)
	await _frames(2)
	await _capture("08_active_connection")
	if module_node != null:
		canvas.call("_begin_module_move", "ship_design_module_0001", module_node, Vector2(120.0, 120.0))
		canvas.call("_update_module_move", Vector2(174.0, 146.0))
	await _frames(2)
	var trash := demo.find_child("ShipAssemblyTrashDropTarget", true, false) as Control
	_check(module_node != null and module_node.modulate.a < 0.6 and trash != null and trash.visible, "dragging ghosts the module and reveals the bottom trash target")
	await _capture("09_module_dragging")
	canvas.call("_finish_module_move", Vector2(280.0, 280.0))

	canvas.zoom = 0.28
	canvas.call("_on_zoom_changed", canvas.zoom)
	await _frames(3)
	var far_name := module_node.find_child("ModuleName", true, false) as Label if module_node != null else null
	_check(far_name != null and not far_name.visible, "very-far LOD hides unreadable module text instead of shrinking it into noise")
	await _capture("10_far_zoom")
	canvas.zoom = 0.82
	canvas.call("_on_zoom_changed", canvas.zoom)
	await _frames(3)
	await _capture("11_normal_zoom")
	canvas.zoom = 1.40
	canvas.call("_on_zoom_changed", canvas.zoom)
	await _frames(3)
	await _capture("12_close_zoom")
	canvas.fit_design()
	await _frames(3)

	var ships_before := Game.state.ships.size()
	var refits_before := Game.state.refit_projects.size()
	var queue_before := Game.state.shipyard_queue.size()
	var inventory_before := JSON.stringify(Game.state.inventory)
	demo.call("_save_blueprint")
	await _frames(3)
	var design_id := Game.last_saved_ship_design_id
	var saved := Game.state.ship_designs.get(design_id, {}) as Dictionary
	_check(not design_id.is_empty() and saved.get("nodes", []).size() == 7 and saved.get("connections", []).size() == 6, "Save Blueprint persists hull, modules, positions and logical connections")
	_check(Game.state.ships.size() == ships_before and Game.state.refit_projects.size() == refits_before and Game.state.shipyard_queue.size() == queue_before and JSON.stringify(Game.state.inventory) == inventory_before, "saving design intent does not construct, refit, queue or consume physical resources")
	_check(str(saved.get("name", "")) == "巡航护卫方案 A", "blueprint display name persists with the real design record")
	var saved_nodes_json := JSON.stringify(saved.get("nodes", []))
	demo.call("_new_blueprint")
	await _frames(2)
	_check((canvas.call("draft_snapshot") as Dictionary).get("nodes", []).is_empty(), "New Blueprint creates a clean draft without deleting the saved design")
	var picker := demo.find_child("SavedBlueprintPicker", true, false) as OptionButton
	var saved_index := -1
	for item_index in picker.item_count:
		if str(picker.get_item_metadata(item_index)) == design_id:
			saved_index = item_index
			break
	if saved_index >= 0:
		picker.select(saved_index)
		demo.call("_load_selected_blueprint")
		await _frames(4)
	var loaded := canvas.call("draft_snapshot") as Dictionary
	_check(saved_index >= 0 and JSON.stringify(loaded.get("nodes", [])) == saved_nodes_json and (loaded.get("connections", []) as Array).size() == 6, "Load Blueprint restores persisted node positions and logical connections")

	var first_link := (canvas.call("draft_snapshot") as Dictionary).get("connections", [])[0] as Dictionary
	var target_node := canvas.get_node_or_null(NodePath("ship_design_%s" % str(first_link.get("socket_id", "")))) as GraphNode
	if target_node != null:
		canvas.call("_on_disconnection_request", StringName(str(first_link.get("module_node_id", ""))), 0, target_node.name, 0)
	await _frames(3)
	_check(save_button.disabled, "disconnecting a required module returns Save Blueprint to the authoritative invalid state")
	await _capture("16_save_disabled_invalid")

	var previous_font_size := 0
	var preserved_accessibility_zoom := canvas.zoom
	var preserved_accessibility_center := (canvas.scroll_offset + canvas.size * 0.5) / maxf(canvas.zoom, 0.01)
	for percent in [75, 100, 125, 150, 175, 200]:
		font_scale_picker = demo.find_child("ShipAssemblyFontScale", true, false) as OptionButton
		var percent_index := font_scale_picker.get_item_index(percent) if font_scale_picker != null else -1
		if percent_index >= 0:
			font_scale_picker.select(percent_index)
			demo.call("_on_font_scale_selected", percent_index)
		await _frames(4)
		library_eyebrow = demo.find_child("AssemblyLibraryEyebrow", true, false) as Label
		var rendered_font_size := library_eyebrow.get_theme_font_size("font_size") if library_eyebrow != null else 0
		_check(rendered_font_size > previous_font_size or percent == 75, "%d percent produces a strictly larger native font step than the previous option" % percent)
		previous_font_size = rendered_font_size
		var scaled_command_bar := demo.find_child("BlueprintCommandBar", true, false) as Control
		var scaled_data_panel := demo.find_child("ShipAssemblyDataPanel", true, false) as Control
		canvas = demo.find_child("ShipAssemblyMap", true, false) as GraphEdit
		var scaled_ship_card := demo.find_child("AssemblyShipCard_lunar_pathfinder", true, false) as Button
		var scaled_ship_detail := scaled_ship_card.find_child("PaletteDetail", true, false) as Label if scaled_ship_card != null else null
		var scaled_module_node := canvas.get_node_or_null(NodePath("ship_design_module_0001")) as GraphNode if canvas != null else null
		var scaled_module_name := scaled_module_node.find_child("ModuleName", true, false) as Label if scaled_module_node != null else null
		var scaled_module_family := scaled_module_node.find_child("ModuleFamily", true, false) as Label if scaled_module_node != null else null
		_check(demo.scale.is_equal_approx(Vector2.ONE), "%d percent never falls back to blurry root-node scaling" % percent)
		_check(scaled_command_bar != null and scaled_data_panel != null and demo.get_global_rect().grow(1.0).encloses(scaled_command_bar.get_global_rect()) and demo.get_global_rect().grow(1.0).encloses(scaled_data_panel.get_global_rect()), "%d percent keeps primary UI regions inside the native window" % percent)
		_check(canvas != null and is_equal_approx(canvas.zoom, preserved_accessibility_zoom), "%d percent preserves the independent canvas zoom instead of silently shrinking sockets through Fit All" % percent)
		var current_canvas_center := (canvas.scroll_offset + canvas.size * 0.5) / maxf(canvas.zoom, 0.01) if canvas != null else Vector2.INF
		_check(current_canvas_center.distance_to(preserved_accessibility_center) < 1.0, "%d percent preserves the world point centered on the canvas after layout reflow" % percent)
		_check(scaled_ship_card != null and scaled_ship_detail != null and scaled_ship_card.get_global_rect().grow(1.0).encloses(scaled_ship_detail.get_global_rect()) and scaled_ship_detail.get_line_count() >= 2, "%d percent grows resource cards so every ship metadata line remains visible" % percent)
		if percent >= 150:
			_check(scaled_module_name != null and scaled_module_name.max_lines_visible == 2 and scaled_module_family != null and not scaled_module_family.visible, "%d percent switches canvas nodes to a readable name-first accessibility LOD instead of overlapping tiny metadata" % percent)
		await _capture("font_scale_%d" % percent)
	font_scale_picker = demo.find_child("ShipAssemblyFontScale", true, false) as OptionButton
	if font_scale_picker != null:
		var default_index := font_scale_picker.get_item_index(100)
		font_scale_picker.select(default_index)
		demo.call("_on_font_scale_selected", default_index)
		await _frames(4)

	demo.queue_free()
	await get_tree().process_frame
	_finish()


func _capture(capture_name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await _frames(2)
	await RenderingServer.frame_post_draw
	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		failures.append("%s screenshot viewport exists" % capture_name)
		return
	var image := viewport_texture.get_image()
	var path := "res://.audit-logs/blueprint_demo_%s.png" % capture_name
	_check(image != null and image.save_png(path) == OK, "%s audit screenshot saves" % capture_name)


func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame


func _tree_text_contains(root: Node, needle: String) -> bool:
	if root is Label and (root as Label).text.find(needle) >= 0:
		return true
	if root is Button and (root as Button).text.find(needle) >= 0:
		return true
	for child in root.get_children():
		if _tree_text_contains(child, needle):
			return true
	return false


func _find_ship_port_glyph(root: Node) -> Node:
	if root == null:
		return null
	for child in root.get_children():
		if child.get_script() == ShipPortGlyphScript:
			return child
		var nested := _find_ship_port_glyph(child)
		if nested != null:
			return nested
	return null


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_ART_DEPLOYMENT_DEMO_TEST_PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
