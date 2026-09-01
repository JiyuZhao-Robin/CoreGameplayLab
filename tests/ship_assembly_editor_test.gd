extends Node

const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	var plan_id := "construct_lunar_pathfinder"
	Game.state.unlocked_ship_plans[plan_id] = true
	var plan := (Game.content.ship_construction_projects[plan_id] as Dictionary).duplicate(true)
	plan["title"] = "Lunar Pathfinder"
	plan["assembly_sockets"] = Game.ship_design_socket_schema(plan_id)
	var hull_id := String(plan.get("ship_id", ""))
	var hull := (Game.content.ships[hull_id] as Dictionary).duplicate(true)
	var large_plan_id := "construct_ultimate_combat"
	var large_plan := (Game.content.ship_construction_projects[large_plan_id] as Dictionary).duplicate(true)
	large_plan["title"] = "Solar Aegis"
	large_plan["assembly_sockets"] = Game.ship_design_socket_schema(large_plan_id)
	var large_hull_id := String(large_plan.get("ship_id", ""))
	var large_hull := (Game.content.ships[large_hull_id] as Dictionary).duplicate(true)
	var modules := {}
	for module_id in ["light_autocannon", "civilian_shield", "civilian_reactor_core", "sensor_array"]:
		var module := (Game.content.modules[module_id] as Dictionary).duplicate(true)
		module["title"] = module_id
		module["assembly_mount"] = Game.ship_module_mount_role(module_id)
		modules[module_id] = module
	var view := ShipAssemblyMapViewScript.new()
	add_child(view)
	view.size = Vector2(1200.0, 800.0)
	view.configure({"plans":{plan_id:plan, large_plan_id:large_plan}, "hulls":{hull_id:hull, large_hull_id:large_hull}, "modules":modules, "slot_labels":{}, "socket_label_format":"%s %d · %s", "module_label_format":"%s · %s · %s", "hull_summary_format":"%s · %d sockets", "core_socket_format":"Energy Core %d"}, {})
	await get_tree().process_frame
	_check(view.draft_snapshot().get("nodes", []).is_empty(), "ship assembly canvas starts blank")
	view.call("_drop_data", Vector2(520.0, 220.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":plan_id, "definition_id":hull_id})
	view.call("_drop_data", Vector2(80.0, 120.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	view.call("_drop_data", Vector2(80.0, 280.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"civilian_shield"})
	var draft := view.draft_snapshot()
	_check(draft.get("nodes", []).size() == 3, "hull and parts are created only by palette drops")
	_check(draft.get("connections", []).is_empty(), "dropping hull and parts never creates pre-wired links")
	var core_socket := view.get_node(NodePath("ship_design_socket_core_0")) as GraphNode
	var drive_socket := view.get_node(NodePath("ship_design_socket_drive_0")) as GraphNode
	var weapon_socket := view.get_node(NodePath("ship_design_socket_weapon_0")) as GraphNode
	var shield_socket := view.get_node(NodePath("ship_design_socket_shield_0")) as GraphNode
	var structural_socket := view.get_node(NodePath("ship_design_socket_utility_1")) as GraphNode
	var special_socket := view.get_node(NodePath("ship_design_socket_utility_0")) as GraphNode
	var socket_glyphs := view.get("_socket_glyphs") as Dictionary
	_check(not bool(socket_glyphs["socket_weapon_0"].filled) and not bool(socket_glyphs["socket_utility_1"].filled), "all unconnected sockets start gray and hollow")
	var orthogonal_route := view.call("_orthogonal_connection_points", Vector2(0.0, 0.0), Vector2(100.0, 60.0)) as PackedVector2Array
	_check(orthogonal_route.size() == 6 and is_equal_approx(orthogonal_route[0].y, orthogonal_route[1].y) and is_equal_approx(orthogonal_route[1].x, orthogonal_route[2].x) and is_equal_approx(orthogonal_route[2].y, orthogonal_route[3].y) and is_equal_approx(orthogonal_route[3].x, orthogonal_route[4].x) and is_equal_approx(orthogonal_route[4].y, orthogonal_route[5].y), "connection routing retains DSPONLINE's orthogonal lead/rail/lead geometry")
	var rounded_line := view.call("_get_connection_line", Vector2(0.0, 0.0), Vector2(100.0, 60.0)) as PackedVector2Array
	_check(rounded_line.size() > orthogonal_route.size() and rounded_line[0].is_equal_approx(orthogonal_route[0]) and rounded_line[rounded_line.size() - 1].is_equal_approx(orthogonal_route[orthogonal_route.size() - 1]), "connection rendering rounds orthogonal corners without moving its endpoints")
	_check(drive_socket.position_offset.y < core_socket.position_offset.y, "drive socket is spatially embedded above the central core")
	_check(weapon_socket.position_offset.x < core_socket.position_offset.x and special_socket.position_offset.x > core_socket.position_offset.x, "special-plugin sockets are embedded on opposite hull flanks")
	_check(shield_socket.position_offset.y > core_socket.position_offset.y and structural_socket.position_offset.y > core_socket.position_offset.y, "shield and structural cabin sockets are embedded along the bottom of the hull backplane")
	view.call("_on_connection_drag_started", StringName("ship_design_module_0001"), 0, true)
	_check((socket_glyphs["socket_weapon_0"].tone as Color).is_equal_approx(UiTokens.COLOR_CRITICAL) and not bool(socket_glyphs["socket_weapon_0"].filled), "connection draft highlights only the compatible hollow socket")
	_check(String(socket_glyphs["socket_weapon_0"].visual_state) == "compatible" and String(socket_glyphs["socket_shield_0"].visual_state) == "muted", "connection draft exposes compatible and muted port visual states")
	_check((socket_glyphs["socket_shield_0"].tone as Color).is_equal_approx(UiTokens.COLOR_BORDER_STRONG), "connection draft leaves incompatible sockets muted")
	view.call("_on_connection_drag_ended")
	view.request_module_connection("ship_design_module_0001", "socket_weapon_0")
	_check(view.draft_snapshot().get("connections", []).size() == 1, "matching triangular weapon interfaces connect")
	_check(bool(socket_glyphs["socket_weapon_0"].filled) and String(socket_glyphs["socket_weapon_0"].visual_state) == "connected", "connected socket becomes colored, filled and enters the connected visual state")
	var weapon_path := view.call("_world_path_for_link", (view.get("_links") as Array)[0]) as PackedVector2Array
	var selection_point := weapon_path[weapon_path.size() / 2] * view.zoom - view.scroll_offset
	_check(bool(view.call("_select_connection_at", selection_point)) and not String(view.get("_selected_connection_key")).is_empty(), "custom connection hit testing selects the enhanced visual line")
	view.request_module_connection("ship_design_module_0002", "socket_weapon_0")
	_check(view.draft_snapshot().get("connections", []).size() == 1, "square structural shield plug cannot connect to triangle weapon socket")
	view.request_module_connection("ship_design_module_0002", "socket_shield_0")
	var missing_core := Game.ship_design_validation(plan_id, view.draft_snapshot().get("nodes", []), view.draft_snapshot().get("connections", []))
	_check(String(missing_core.get("reason_code", "")) == "CORE_REQUIRED", "a hull with an empty central energy-core socket cannot be saved for construction")
	view.call("_drop_data", Vector2(80.0, 440.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"civilian_reactor_core"})
	view.request_module_connection("ship_design_module_0003", "socket_core_0")
	view.call("_drop_data", Vector2(300.0, 440.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"sensor_array"})
	view.request_module_connection("ship_design_module_0004", "socket_utility_1")
	_check(view.draft_snapshot().get("connections", []).size() == 3, "special sensor cannot enter a bottom structural square socket")
	view.request_module_connection("ship_design_module_0004", "socket_utility_0")
	draft = view.draft_snapshot()
	_check(draft.get("nodes", []).size() == 5, "energy core and special plugin are created only when the player drags them from the parts palette")
	_check(draft.get("connections", []).size() == 4, "matching structural, special and central energy-core interfaces connect")
	var validation := Game.ship_design_validation(plan_id, draft.get("nodes", []), draft.get("connections", []))
	_check(bool(validation.get("allowed", false)), "manually connected design validates through the domain")
	_check(Game.save_ship_design("", "Manual Socket Test", plan_id, draft.get("nodes", []), draft.get("connections", [])), "valid design saves into simulation state")
	var design_id := Game.last_saved_ship_design_id
	var restored := SpaceGameState.from_dictionary(Game.state.to_dictionary(), Game.content.domains.keys(), Game.content.regions)
	_check(restored.ship_designs.has(design_id) and restored.ship_designs[design_id].get("connections", []).size() == 4, "ship design nodes and links survive save serialization")
	_check(Game.enqueue_saved_ship_design(design_id, 1), "saved design enters the real shipyard queue")
	var runtime := Game.state.shipyard_queue.back() as Dictionary
	_check(runtime.get("custom_modules", []) == ["light_autocannon", "civilian_shield", "civilian_reactor_core", "sensor_array"], "shipyard runtime owns the player's selected module list")
	var effective_plan := Game.simulation.shipyard_runtime_plan(runtime)
	var costs := Game.simulation.ship_construction_material_totals(effective_plan)
	for fixed_value in effective_plan.get("fixed_costs", []):
		var fixed := fixed_value as Dictionary
		costs[String(fixed.get("item", ""))] = int(costs.get(String(fixed.get("item", "")), 0)) + int(fixed.get("quantity", 0))
	for item_id_value in costs.keys():
		Game.state.add_item(String(item_id_value), int(costs[item_id_value]) + 10)
	runtime["completed_segments"] = 99
	runtime["paid_cycles"] = 99
	runtime["cycle_progress"] = 1.0
	runtime["consumed"] = {}
	runtime["status"] = "RUNNING"
	Game.simulation.call("_settle_shipyard_cycle", Game.state, runtime)
	var built := {}
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		if String(ship.get("blueprint_id", "")) == hull_id:
			built = ship
	_check(not built.is_empty() and built.get("modules", []) == ["light_autocannon", "civilian_shield", "civilian_reactor_core", "sensor_array"], "completed construction creates a persistent ship with the manual canvas loadout")
	var small_hull_node := view.get_node(NodePath("ship_design_hull")) as GraphNode
	var small_hull_size := small_hull_node.custom_minimum_size
	_check(int(view.call("_hull_socket_port", "socket_weapon_1")) < 0, "small hull exposes only its blueprint-defined weapon sockets")
	view.clear_draft(false)
	view.call("_drop_data", Vector2(520.0, 220.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":large_plan_id, "definition_id":large_hull_id})
	var large_hull_node := view.get_node(NodePath("ship_design_hull")) as GraphNode
	_check(int(view.call("_hull_socket_port", "socket_weapon_3")) >= 0, "large hull exposes its additional blueprint-defined weapon sockets")
	_check(large_hull_node.custom_minimum_size.x > small_hull_size.x and large_hull_node.custom_minimum_size.y > small_hull_size.y, "large hull backplane grows visually with its greater socket count")
	view.call("_drop_data", Vector2(2100.0, 760.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	await get_tree().process_frame
	view.fit_design()
	var fitted_bounds := view.call("_design_bounds") as Rect2
	var fitted_left := (fitted_bounds.position.x - view.scroll_offset.x) * view.zoom
	var fitted_top := (fitted_bounds.position.y - view.scroll_offset.y) * view.zoom
	var fitted_right := (fitted_bounds.end.x - view.scroll_offset.x) * view.zoom
	var fitted_bottom := (fitted_bounds.end.y - view.scroll_offset.y) * view.zoom
	_check(fitted_left >= -1.0 and fitted_top >= -1.0 and fitted_right <= view.size.x + 1.0 and fitted_bottom <= view.size.y + 1.0, "Fit all includes the complete ship design instead of leaving a cropped partial canvas")
	view.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("SHIP_ASSEMBLY_EDITOR_TEST_PASS")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
