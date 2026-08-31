extends Node

const MainScene = preload("res://src/ui/main.tscn")

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
	_check(main.find_child("ShipPalettePart_light_autocannon", true, false) is Button, "revealed part is a draggable palette item")
	_check(_graph_node_count(map) == 0 and map.get_connection_list().is_empty(), "new ship design canvas is blank and contains no pre-wired links")
	map.call("_drop_data", Vector2(620.0, 260.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	map.call("_drop_data", Vector2(120.0, 160.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	_check(_graph_node_count(map) == 2 and map.get_connection_list().is_empty(), "UI drops create hull and part without pre-connecting them")
	map.request_module_connection("ship_design_module_0001", "socket_weapon_0")
	_check(map.get_connection_list().size() == 1, "player-authored matching connection appears on the live canvas")
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
