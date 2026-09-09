extends SceneTree

## The Fleet host gives the ship editor a 1880 x 650 logical region inside the
## 1920 x 1080 4K design viewport. This focused test keeps that region free of
## page-level overflow while preserving the independent GraphEdit camera.

var blueprint_editor_script: Script
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const HOST_SIZE := Vector2(1880.0, 650.0)
const EXPECTED_SCROLL_REGIONS := ["AssemblyShipsTab", "AssemblyModulesScroll", "AssemblyDataScroll"]

var failures: Array[String] = []
var _host: Control
var _editor: Control


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := root.get_node("Game")
	game.persistence_enabled = false
	game.reset_game()
	root.get_node("I18n").set_locale("en")
	blueprint_editor_script = load("res://src/ui/components/ship_assembly_blueprint_editor.gd")
	root.remove_meta("ship_assembly_demo_font_scale")
	root.size = Vector2i(1920, 1080)
	_host = Control.new()
	_host.name = "ShipEditorFitContractHost"
	_host.position = Vector2(20.0, 320.0)
	_host.size = HOST_SIZE
	root.add_child(_host)
	for scale_percent in [100, 125, 150]:
		UiTokens.set_ui_scale(float(scale_percent) / 100.0)
		_editor = blueprint_editor_script.new()
		_editor.name = "ShipEditorFitContractEditor"
		_editor.call("configure_for_main_game")
		_editor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_host.add_child(_editor)
		await _frames(5)
		_check(is_equal_approx(UiTokens.ui_scale(), float(scale_percent) / 100.0), "%d%% uses only the explicit player accessibility scale" % scale_percent)
		_assert_bounded_editor(scale_percent)
		_assert_workspace_columns(scale_percent)
		_assert_named_inner_scrollers(scale_percent)
		_assert_art_presentation(scale_percent)
		_assert_canvas_coordinate_contract(scale_percent)
		if scale_percent == 125:
			await _assert_session_restore(game)
		_editor.queue_free()
		await process_frame
	_host.queue_free()
	await process_frame
	UiTokens.set_ui_scale(UiTokens.DEFAULT_UI_SCALE)
	_finish()


func _assert_bounded_editor(scale_percent: int) -> void:
	var frame := _editor.find_child("BlueprintEditorFrame", true, false) as Control
	var command_bar := _editor.find_child("BlueprintCommandBar", true, false) as Control
	var library := _editor.find_child("ShipAssemblyLibrary", true, false) as Control
	var canvas_region := _editor.find_child("BlueprintCanvasRegion", true, false) as Control
	var data_panel := _editor.find_child("ShipAssemblyDataPanel", true, false) as Control
	var save_button := _editor.find_child("SaveBlueprintButton", true, false) as Button
	var new_button := _editor.find_child("NewBlueprintButton", true, false) as Button
	var host_rect := _host.get_global_rect()
	var required_controls: Array[Control] = [frame, command_bar, library, canvas_region, data_panel, save_button, new_button]
	var all_present_and_bounded := true
	for control in required_controls:
		all_present_and_bounded = all_present_and_bounded and control != null and control.is_visible_in_tree() and host_rect.grow(1.0).encloses(control.get_global_rect())
	_check(all_present_and_bounded, "%d%% keeps editor chrome, three regions and primary save/new actions inside the 1880 x 650 host" % scale_percent)
	_check(
		frame != null and frame.size.y <= HOST_SIZE.y and _editor.get_global_rect().size.is_equal_approx(HOST_SIZE),
		"%d%% does not inflate the complete shipyard editor beyond its assigned logical stage" % scale_percent
	)


func _assert_workspace_columns(scale_percent: int) -> void:
	var workspace := _editor.find_child("BlueprintWorkspace", true, false) as Control
	var library := _editor.find_child("ShipAssemblyLibrary", true, false) as Control
	var canvas_region := _editor.find_child("BlueprintCanvasRegion", true, false) as Control
	var data_panel := _editor.find_child("ShipAssemblyDataPanel", true, false) as Control
	if workspace == null or library == null or canvas_region == null or data_panel == null or workspace.size.x <= 0.0:
		_check(false, "%d%% exposes the deterministic three-column editor workspace" % scale_percent)
		return
	var library_ratio := library.size.x / workspace.size.x
	var canvas_ratio := canvas_region.size.x / workspace.size.x
	var data_ratio := data_panel.size.x / workspace.size.x
	var vertical_alignment := is_equal_approx(library.position.y, canvas_region.position.y) and is_equal_approx(canvas_region.position.y, data_panel.position.y) and is_equal_approx(library.size.y, workspace.size.y) and is_equal_approx(canvas_region.size.y, workspace.size.y) and is_equal_approx(data_panel.size.y, workspace.size.y)
	_check(
		library_ratio >= 0.22 and library_ratio <= 0.24
		and canvas_ratio >= 0.51 and canvas_ratio <= 0.53
		and data_ratio >= 0.24 and data_ratio <= 0.26
		and vertical_alignment,
		"%d%% retains 23 / 52 / 25 library-canvas-engineering bands without a vertical reflow" % scale_percent
	)


func _assert_named_inner_scrollers(scale_percent: int) -> void:
	var scroll_names: Array[String] = []
	_collect_scroll_names(_editor, scroll_names)
	scroll_names.sort()
	var expected := EXPECTED_SCROLL_REGIONS.duplicate()
	expected.sort()
	_check(scroll_names == expected, "%d%% limits scrolling to the three named bounded content regions" % scale_percent)


func _assert_art_presentation(scale_percent: int) -> void:
	var ship_card := _editor.find_child("AssemblyShipCard_lunar_pathfinder", true, false) as Control
	var artwork := ship_card.find_child("PaletteArtwork", true, false) as TextureRect if ship_card != null else null
	_check(
		_editor.scale.is_equal_approx(Vector2.ONE)
		and artwork != null
		and artwork.expand_mode == TextureRect.EXPAND_IGNORE_SIZE
		and artwork.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
		"%d%% keeps illustrated hull assets natively rendered and aspect-preserved" % scale_percent
	)


func _collect_scroll_names(node: Node, result: Array[String]) -> void:
	if node is ScrollContainer:
		result.append(str(node.name))
	for child in node.get_children():
		_collect_scroll_names(child, result)


func _assert_canvas_coordinate_contract(scale_percent: int) -> void:
	var canvas := _editor.find_child("ShipAssemblyMap", true, false) as GraphEdit
	var layer := _editor.find_child("ShipAssemblyConnectionLayer", true, false) as Control
	if canvas == null:
		_check(false, "%d%% keeps the independent design canvas available" % scale_percent)
		return
	canvas.zoom = 0.82
	canvas.scroll_offset = Vector2(157.0, 91.0)
	var world_point := Vector2(438.25, 216.75)
	var screen_point := canvas.call("world_to_canvas_screen", world_point) as Vector2
	var restored_world := canvas.call("canvas_screen_to_world", screen_point) as Vector2
	_check(
		restored_world.is_equal_approx(world_point)
		and layer != null
		and canvas.get_global_rect().grow(1.0).encloses(layer.get_global_rect()),
		"%d%% preserves one local world/screen transform for node, link and drag presentation" % scale_percent
	)


func _assert_session_restore(game: Node) -> void:
	var source := _editor
	var source_canvas := source.find_child("ShipAssemblyMap", true, false) as GraphEdit
	var source_library := source.find_child("ShipAssemblyLibrary", true, false)
	if source_canvas == null or source_library == null:
		_check(false, "session contract starts from a mounted assembly canvas and library")
		return
	source_library.call("select_tab", 1)
	source_canvas.call("_drop_data", Vector2(460.0, 260.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	source_canvas.call("_drop_data", Vector2(180.0, 150.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	source_canvas.call("request_module_connection", "ship_design_module_0001", "socket_weapon_0")
	await _frames(3)
	var module := source_canvas.get_node_or_null("ship_design_module_0001") as GraphNode
	if module != null:
		module.selected = true
		source_canvas.call("_on_node_selected", module)
	source_canvas.zoom = 0.71
	source_canvas.scroll_offset = Vector2(143.0, 97.0)
	source.call("_on_blueprint_name_changed", "Session-only patrol draft")
	source.set("_design_id", "session_only_design")
	source.set("_draft_dirty", true)
	await _frames(2)
	var expected: Dictionary = source.call("capture_session_state") as Dictionary
	var designs_before: int = game.state.ship_designs.size()
	source.queue_free()
	await process_frame
	_editor = blueprint_editor_script.new()
	_editor.name = "ShipEditorFitContractRestoredEditor"
	_editor.call("configure_for_main_game")
	var accepted: bool = _editor.call("restore_session_state", expected)
	_host.add_child(_editor)
	await _frames(7)
	var restored: Dictionary = _editor.call("capture_session_state") as Dictionary
	var restored_canvas := _editor.find_child("ShipAssemblyMap", true, false) as GraphEdit
	var restored_library := _editor.find_child("ShipAssemblyLibrary", true, false)
	var restored_center := restored.get("canvas_world_center", Vector2.ZERO) as Vector2
	var expected_center := expected.get("canvas_world_center", Vector2.ZERO) as Vector2
	_check(
		accepted
		and restored.get("draft", {}) == expected.get("draft", {})
		and str(restored.get("blueprint_name", "")) == str(expected.get("blueprint_name", ""))
		and str(restored.get("design_id", "")) == str(expected.get("design_id", ""))
		and bool(restored.get("draft_dirty", false)) == bool(expected.get("draft_dirty", false))
		and str(restored.get("selection_kind", "")) == str(expected.get("selection_kind", ""))
		and str(restored.get("selection_id", "")) == str(expected.get("selection_id", ""))
		and str(restored.get("selection_node_id", "")) == str(expected.get("selection_node_id", ""))
		and int(restored.get("library_tab", -1)) == int(expected.get("library_tab", -2))
		and restored_library != null
		and int(restored_library.call("current_tab")) == 1,
		"session restoration preserves the unsaved draft, identity, dirty state, selection and active asset tab"
	)
	_check(
		restored_canvas != null
		and is_equal_approx(float(restored.get("canvas_zoom", 0.0)), float(expected.get("canvas_zoom", -1.0)))
		and restored_center.distance_to(expected_center) < 0.01
		and restored_canvas.get_node_or_null("ship_design_module_0001") != null,
		"session restoration defers the shared canvas camera until layout settles and keeps stable module node IDs"
	)
	_check(game.state.ship_designs.size() == designs_before, "session capture and restoration never write a ship design to game state")


func _frames(count: int) -> void:
	for _frame in count:
		await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_EDITOR_FIT_CONTRACT_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
