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
	_check(main.find_child("ShipAssemblyPalette", true, false) is TabContainer, "Shipyard exposes Ship and Parts palette tabs")
	_check(main.find_child("ShipPaletteHull_construct_lunar_pathfinder", true, false) is Button, "unlocked hull is a draggable palette item")
	_check(main.find_child("ShipPaletteHull_construct_ultimate_combat", true, false) == null, "locked and unavailable hulls are omitted from the Ship palette")
	var weapon_palette_item := main.find_child("ShipPalettePart_light_autocannon", true, false) as Button
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
	var inspector := main.find_child("ShipModuleInspector", true, false) as Control
	var ui_state = main.get("_ui_state")
	_check(inspector != null and not bool(ui_state.right_inspector_collapsed), "selecting the reactor opens the reusable right-side module inspector")
	_check(inspector != null and inspector.find_child("ModuleInspectorArtwork", true, false) is TextureRect and inspector.find_child("ModuleInspectorSection_COMPATIBILITY", true, false) != null, "reactor inspector integrates artwork and data-driven expandable property sections")
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
