extends Node

const MainScene = preload("res://src/ui/main.tscn")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	Game.state.unlocked_ship_plans["construct_lunar_pathfinder"] = true
	Game.state.completed_activities["assemble_frame"] = 1
	var refit_modules := ["light_autocannon", "civilian_shield", "basic_drive", "cargo_expansion", "civilian_reactor_core"]
	var refit_ship := Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "Blueprint Refit Target")
	var refit_ship_id := String(refit_ship.get("instance_id", ""))
	var refit_bom := Game.simulation.loadout_fabrication_costs(refit_modules)
	for item_id_value in refit_bom.keys():
		var item_id := String(item_id_value)
		Game.state.add_item(item_id, int(refit_bom[item_id]))
	var main := MainScene.instantiate() as Control
	add_child(main)
	await _redraw()
	var fleet_nav := main.find_child("Navigation_ships", true, false) as Button
	_check(fleet_nav != null, "Fleet navigation exists")
	fleet_nav.pressed.emit()
	await _redraw()
	var shipyard_tab := main.find_child("FleetSection_shipyard", true, false) as Button
	_check(shipyard_tab != null, "Shipyard tab exists")
	shipyard_tab.pressed.emit()
	await _redraw()
	var map := main.find_child("ShipAssemblyMap", true, false) as GraphEdit
	_check(map != null, "Shipyard renders the interactive assembly canvas")
	_check(main.find_child("MainShipBlueprintEditor", true, false) is Control, "main game mounts the shared production blueprint editor")
	_check(main.find_child("AssemblyLibraryTabs", true, false) is TabContainer, "Shipyard exposes the shared Ships and Modules library tabs")
	_check(main.find_child("AssemblyShipCard_lunar_pathfinder", true, false) is Button, "hull plan is a draggable blueprint asset")
	_check(main.find_child("AssemblyShipCard_ultimate_combat", true, false) is Button, "production editor uses the complete hull design catalogue")
	var weapon_palette_item := main.find_child("AssemblyModuleCard_light_autocannon", true, false) as Button
	_check(weapon_palette_item != null, "revealed part is a draggable palette item")
	_check(weapon_palette_item.find_child("PaletteArtwork", true, false) is TextureRect, "parts palette fills its left frame with generated equipment artwork")
	var palette_title := weapon_palette_item.find_child("PaletteTitle", true, false) as Label
	_check(palette_title != null and palette_title.get_theme_font_size("font_size") == UiTokens.ship_assembly_font_size(13), "parts palette typography uses the 1.5x ship-assembly font scale")
	_check(_graph_node_count(map) == 0 and map.get_connection_list().is_empty(), "new ship design canvas is blank and contains no pre-wired links")
	map.call("_drop_data", Vector2(620.0, 260.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	map.call("_drop_data", Vector2(120.0, 160.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	_check(_graph_node_count(map) == 2 and map.get_connection_list().is_empty(), "UI drops create hull and part without pre-connecting them")
	var weapon := map.get_node_or_null(NodePath("ship_design_module_0001")) as GraphNode
	_check(weapon != null and weapon.find_child("ModuleNodeVisual", true, false) is Control, "all module categories use the approved Reactor Core component style")
	map.request_module_connection("ship_design_module_0001", "socket_weapon_0")
	_check(map.get_connection_list().size() == 1, "player-authored matching connection appears on the live canvas")
	map.call("_drop_data", Vector2(140.0, 360.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"civilian_reactor_core"})
	await _redraw()
	var reactor := map.get_node_or_null(NodePath("ship_design_module_0002")) as GraphNode
	_check(reactor != null and reactor.find_child("ModuleNodeVisual", true, false) is Control, "Civilian Reactor Core and other modules share one reusable module-card renderer")
	if reactor != null:
		reactor.selected = true
		map.call("_on_node_selected", reactor)
		await _redraw()
	var inspector := main.find_child("AssemblyModuleInspector", true, false) as Control
	var shell_left := main.find_child("ResourceRailSurface", true, false) as Control
	var shell_right := main.find_child("ContextInspectorSurface", true, false) as Control
	_check(inspector != null and shell_left != null and shell_right != null and not shell_left.visible and not shell_right.visible, "selecting the reactor opens the blueprint data inspector while duplicate shell sidebars stay hidden")
	_check(inspector != null and inspector.find_child("ModuleInspectorArtwork", true, false) is TextureRect and inspector.find_child("ModuleInspectorSection_COMPATIBILITY", true, false) != null, "reactor inspector integrates artwork and data-driven expandable property sections")
	map.request_module_connection("ship_design_module_0002", "socket_core_0")
	for fitting in [["civilian_shield", "socket_shield_0"], ["basic_drive", "socket_drive_0"], ["cargo_expansion", "socket_utility_1"]]:
		var next_index := _graph_node_count(map)
		map.call("_drop_data", Vector2(160.0 + float(next_index) * 36.0, 320.0 + float(next_index) * 26.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":String(fitting[0])})
		map.request_module_connection("ship_design_module_%04d" % next_index, String(fitting[1]))
	var save_button := main.find_child("SaveBlueprintButton", true, false) as Button
	var name_edit := main.find_child("BlueprintNameEdit", true, false) as LineEdit
	if name_edit != null:
		name_edit.text = "Main UI Refit Blueprint"
	_check(save_button != null and not save_button.disabled, "complete main-game blueprint enables the shared Save Blueprint action")
	if save_button != null and not save_button.disabled:
		save_button.pressed.emit()
	await _redraw()
	var design_id := Game.last_saved_ship_design_id
	_check(not design_id.is_empty() and Game.state.ship_designs.has(design_id), "main-game Save Blueprint persists the shared editor draft")
	var refit_button := main.find_child("RefitShipDesign_%s_%s" % [design_id, refit_ship_id], true, false) as Button
	_check(refit_button != null, "saved blueprint exposes a matching physical-hull refit handoff")
	_check(refit_button != null and not refit_button.disabled, "matching physical-hull refit handoff is enabled: %s" % String(Game.ship_design_refit_availability(design_id, refit_ship_id).get("reason", "missing control")))
	_check(main.find_child("SaveShipLoadout_%s" % refit_ship_id, true, false) == null and main.find_child("InstallModule_%s_sensor_array" % refit_ship_id, true, false) == null, "legacy loadout and direct plugin-adjustment controls are absent")
	if refit_button != null and not refit_button.disabled:
		refit_button.pressed.emit()
	await _redraw()
	_check(Game.state.refit_projects.any(func(project): return String((project as Dictionary).get("ship_id", "")) == refit_ship_id and String((project as Dictionary).get("target_loadout_id", "")) == design_id), "blueprint handoff starts the authoritative starport refit project")
	main.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("SHIP_ASSEMBLY_UI_TEST_PASS")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _redraw() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _graph_node_count(graph: GraphEdit) -> int:
	var count := 0
	for child in graph.get_children():
		if child is GraphNode and String(child.get_meta("entity_kind", "")) != "socket":
			count += 1
	return count


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
