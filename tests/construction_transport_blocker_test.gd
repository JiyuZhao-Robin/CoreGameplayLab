extends Node

const MainScene := preload("res://src/ui/main.tscn")
const GameplayScenarioBuilderScript := preload("res://tests/gameplay_scenario_builder.gd")
const DESTINATION := "asteroid_belt"
const ROUTE_ID := "lunar_belt_freight"
const ITEM_ID := "electronics"

var failures: Array[String] = []
var main: Control


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Engine.time_scale = 0.0
	I18n.set_locale("en")
	var builder = GameplayScenarioBuilderScript.new(Game.content)
	_check(builder.activate("reach_asteroid"), "a normal-command Golden checkpoint reaches the surveyed Asteroid Belt")
	if not failures.is_empty():
		_finish()
		return

	# This fixture creates valid owned assets and inventory, never a runtime status
	# or blocker. Construction and Logistics state are formed by public commands
	# and normal Simulation advancement below.
	var tug: Dictionary = Game.state._create_ship_instance("bulk_freighter", ["civilian_shield", "advanced_drive", "bulk_freight_array", "cargo_expansion", "cargo_expansion", "civilian_reactor_core"], "ISS Blocker Probe")
	var tug_id := String(tug.get("instance_id", ""))
	for item_id in ["electronics", "industrial_machine_tools", "heavy_structural_section"]:
		var required := 2
		var available := Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
		if available < required:
			Game.state.add_item(item_id, required - available, SpaceGameState.MAIN_BASE_LOCATION_ID)
	_check(Game.queue_site_development("belt_cobalt_frontier", "fixed_excavation", 90), "SITE_DEVELOPMENT enters shared Construction through the public command")
	for item_id in ["electronics", "industrial_machine_tools", "heavy_structural_section"]:
		_check(Game.set_location_logistics_policy(SpaceGameState.MAIN_BASE_LOCATION_ID, item_id, LogisticsEngine.MODE_SUPPLY, 0, 0, 90, 1), "Earth publishes %s through the public Logistics policy command" % item_id)
	_check(Game.configure_logistics_service(ROUTE_ID, "bulk_tug", [tug_id], "BULK_FIRST"), "the Belt corridor enters a legal ship-backed Bulk Tug service")
	var project := _site_project()
	_check(not project.is_empty(), "the committed Site Development project remains authoritative")
	var electronics_before := Game.state.aggregate_item_quantity(ITEM_ID)
	Game.advance_game_time(400001.0)
	project = _site_project()
	var blocker: Dictionary = Game.simulation.logistics.construction_transport_blocker(Game.state, project)
	_check(String(blocker.get("primary_reason", "")) == "TRANSPORT_MODE_UNAVAILABLE", "committed Construction exposes TRANSPORT_MODE_UNAVAILABLE instead of a silent INPUT_SHORTAGE")
	_check(String(blocker.get("item_id", "")) == ITEM_ID and String(blocker.get("freight_class", "")) == "PRECISION", "the authoritative blocker identifies the missing precision Item and Freight Class")
	_check(String(blocker.get("route_id", "")) == ROUTE_ID and String(blocker.get("transport_mode_id", "")) == "bulk_tug", "the authoritative blocker identifies the incompatible route and active Transport Mode")
	var blocker_info := Game.blocker_info(blocker)
	_check(String(blocker_info.get("freight_class", "")) == "PRECISION" and String(blocker_info.get("transport_mode_id", "")) == "bulk_tug" and String(blocker_info.get("navigation_target", {}).get("entity_id", "")) == ROUTE_ID, "BlockerInfo preserves Freight, mode and route navigation evidence")
	_check(Game.state.aggregate_item_quantity(ITEM_ID) + Game.simulation.logistics.incoming_quantity(Game.state, DESTINATION, ITEM_ID) == electronics_before, "unsupported committed freight is neither duplicated nor lost")

	# On-hand stock protected by a player reserve is not construction stock. The
	# transport diagnosis must continue to expose the incompatible route instead
	# of treating that protected unit as if this project could spend it.
	Game.state.add_item(ITEM_ID, 1, DESTINATION)
	_check(Game.set_inventory_reserve(ITEM_ID, 1, DESTINATION), "player reserve is established through the public Inventory command")
	var reserved_blocker: Dictionary = Game.simulation.logistics.construction_transport_blocker(Game.state, project)
	_check(String(reserved_blocker.get("primary_reason", "")) == "TRANSPORT_MODE_UNAVAILABLE", "player-reserved destination stock cannot hide the Construction transport blocker")
	_check(Game.set_inventory_reserve(ITEM_ID, 0, DESTINATION), "focused reserve fixture is released through the public Inventory command")
	Game.state.remove_item(ITEM_ID, 1, DESTINATION)

	main = MainScene.instantiate() as Control
	add_child(main)
	await _settle_ui()
	var diagnostics := main.find_child("Navigation_diagnostics", true, false) as Button
	_check(_button_usable(diagnostics), "Diagnostics is reachable through a visible enabled Control")
	if _button_usable(diagnostics):
		diagnostics.pressed.emit()
		await _settle_ui()
	var corpus := _visible_text(main)
	var upstream := main.find_child("BlockerUpstream_INPUT_SHORTAGE_%s" % ROUTE_ID, true, false) as Button
	_check(corpus.contains(I18n.status("TRANSPORT_MODE_UNAVAILABLE")), "Diagnostics explains the committed Construction shortage as Transport Mode incompatibility")
	_check(_button_usable(upstream), "the incompatible committed freight exposes a visible Why/root-cause navigation action")
	if _button_usable(upstream):
		upstream.pressed.emit()
		await _settle_ui()
	_check(String(main.get("_active_page_key")) == "logistics" and String(main.get("_logistics_route_focus_id")) == ROUTE_ID, "Why navigation opens Logistics focused on the incompatible route")
	var route_card := main.find_child("LogisticsRouteCard_%s" % ROUTE_ID, true, false)
	_check(route_card != null and (route_card as CanvasItem).is_visible_in_tree(), "the focused incompatible route card is visible")

	var general_button := main.find_child("TransportMode_%s_general_cargo" % ROUTE_ID, true, false) as Button
	_check(_button_usable(general_button), "General Cargo is a visible valid resolution")
	if _button_usable(general_button):
		general_button.pressed.emit()
		await _settle_ui()
	_check(Game.simulation.logistics.construction_transport_blocker(Game.state, project).is_empty(), "switching through the UI to compatible General Cargo clears the authoritative blocker")
	Game.advance_game_time(5001.0)
	_check(Game.simulation.logistics.incoming_quantity(Game.state, DESTINATION, ITEM_ID) > 0, "the resolved service dispatches the precision component through normal Logistics")
	_check(Game.state.aggregate_item_quantity(ITEM_ID) + Game.simulation.logistics.incoming_quantity(Game.state, DESTINATION, ITEM_ID) == electronics_before, "the resolved precision dispatch conserves assets")
	_finish()


func _site_project() -> Dictionary:
	for value in Game.state.construction_operations:
		var project := value as Dictionary
		if String(project.get("project_type", "")) == "SITE_DEVELOPMENT" and String(project.get("target_id", "")) == "belt_cobalt_frontier" and String(project.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			return project
	return {}


func _settle_ui() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.21, true, false, true).timeout
	await get_tree().process_frame


func _button_usable(button: Button) -> bool:
	return button != null and button.is_visible_in_tree() and not button.disabled


func _visible_text(root: Node) -> String:
	var parts: Array[String] = []
	_collect_visible_text(root, parts)
	return "\n".join(parts)


func _collect_visible_text(node: Node, parts: Array[String]) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	if node is Label:
		parts.append((node as Label).text)
	elif node is RichTextLabel:
		parts.append((node as RichTextLabel).get_parsed_text())
	elif node is Button:
		parts.append((node as Button).text)
	for child in node.get_children():
		_collect_visible_text(child, parts)


func _check(condition: bool, message: String) -> void:
	print(("PASS: " if condition else "FAIL: ") + message)
	if not condition:
		failures.append(message)


func _finish() -> void:
	if is_instance_valid(main):
		main.free()
		main = null
	print("CONSTRUCTION_TRANSPORT_BLOCKER_TEST: %s" % ("PASS" if failures.is_empty() else "FAIL (%d)" % failures.size()))
	get_tree().quit(0 if failures.is_empty() else 1)
