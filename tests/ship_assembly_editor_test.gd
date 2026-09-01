extends Node

const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipHullProfiles = preload("res://src/ui/components/ship_hull_profiles.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	var audited_hulls := 0
	for construction_value in Game.content.ship_construction_projects.values():
		var construction := construction_value as Dictionary
		var audit_plan_id := String(construction.get("id", ""))
		var audit_hull_id := String(construction.get("ship_id", ""))
		var audit_hull := Game.content.ships.get(audit_hull_id, {}) as Dictionary
		var audit_spec := ShipHullProfiles.visual_spec(audit_hull)
		var audit_schema := Game.ship_design_socket_schema(audit_plan_id)
		var audit_positions := ShipHullProfiles.layout_sockets(audit_spec, audit_schema)
		var violations := ShipHullProfiles.layout_violations(audit_spec, audit_schema, audit_positions)
		_check(violations.is_empty(), "%s socket layout stays inside its hull without overlap: %s" % [audit_hull_id, ", ".join(violations)])
		_check(_outline_is_axially_symmetric(ShipHullProfiles.outline_meters(audit_spec), float(audit_spec.get("beam_m", 0.0))), "%s uses an axially symmetric hull outline" % audit_hull_id)
		audited_hulls += 1
	_check(audited_hulls == 14, "every constructible hull participates in the projection and socket-layout audit")
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
	large_hull["ui_visual"] = {
		"topdown_texture":"res://assets/ships/missing_visual/base.png",
		"fx_mask":"res://assets/ships/missing_visual/fx_mask.png"
	}
	var modules := {}
	for module_id in ["light_autocannon", "civilian_shield", "civilian_reactor_core", "sensor_array", "plasma_cannon"]:
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
	await get_tree().process_frame
	var visual_backplane := view.get_node(NodePath("ship_design_hull")).find_child("ShipHullProjection", true, false) as Control
	var hull_visual := view.get_node(NodePath("ship_design_hull")).find_child("ShipHullVisual", true, false) as Control
	_check(visual_backplane != null and bool(visual_backplane.call("has_visual_asset")), "representative hull enables the passive high-detail visual through ShipHullBackplane")
	_check(_control_tree_ignores_mouse(hull_visual), "hull visual and all shader pass controls ignore mouse input")
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
	_check(weapon_socket.visible and weapon_socket.z_index > (view.get_node(NodePath("ship_design_hull")) as GraphNode).z_index, "visual artwork never hides or intercepts the socket hit target")
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
	var interaction_snapshot := JSON.stringify(view.draft_snapshot())
	view.zoom = 0.74
	view.scroll_offset = Vector2(137.0, 89.0)
	await get_tree().process_frame
	_check(JSON.stringify(view.draft_snapshot()) == interaction_snapshot, "zoom and pan remain presentation-only and do not move saved design nodes or connections")
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
	var serialized_state := JSON.stringify(restored.to_dictionary())
	_check(serialized_state.find("ui_visual") < 0 and serialized_state.find("topdown_texture") < 0 and serialized_state.find("fx_mask") < 0, "presentation metadata never enters Save Schema 38")
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
	var size_notices: Array[String] = []
	view.notice_requested.connect(func(code: String) -> void: size_notices.append(code))
	view.call("_drop_data", Vector2(320.0, 600.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"plasma_cannon"})
	view.request_module_connection("ship_design_module_0005", "socket_weapon_0")
	_check(size_notices.has("PORT_SIZE_MISMATCH") and view.draft_snapshot().get("connections", []).size() == 4, "an L/22m module cannot enter the Lunar hull's M/11m socket")
	var oversized_validation := Game.ship_design_validation(plan_id, [
		{"node_id":"ship_design_hull", "kind":"hull", "definition_id":hull_id, "position":{"x":0.0, "y":0.0}},
		{"node_id":"oversized_weapon", "kind":"module", "definition_id":"plasma_cannon", "position":{"x":0.0, "y":0.0}}
	], [{"module_node_id":"oversized_weapon", "socket_id":"socket_weapon_0"}])
	_check(String(oversized_validation.get("reason_code", "")) == "SOCKET_SIZE_MISMATCH", "the domain rejects forged oversized module connections as well as the UI")
	var small_hull_node := view.get_node(NodePath("ship_design_hull")) as GraphNode
	var small_hull_size := small_hull_node.custom_minimum_size
	_check((small_hull_node.find_child("ShipHullProjection", true, false) as Control) != null and int((socket_glyphs["socket_weapon_0"] as Control).get("tier")) == 2, "the small hull renders its orthographic projection and M/T2 sockets")
	var native_visual_texture := load("res://assets/ships/lunar_pathfinder/base.png") as Texture2D
	_check(native_visual_texture != null and small_hull_size.y < native_visual_texture.get_height(), "logical Fit All bounds do not expand to the native 2K texture dimensions")
	_check(int(view.call("_hull_socket_port", "socket_weapon_1")) < 0, "small hull exposes only its blueprint-defined weapon sockets")
	view.clear_draft(false)
	view.call("_drop_data", Vector2(520.0, 220.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":large_plan_id, "definition_id":large_hull_id})
	var large_hull_node := view.get_node(NodePath("ship_design_hull")) as GraphNode
	var fallback_backplane := large_hull_node.find_child("ShipHullProjection", true, false) as Control
	_check(fallback_backplane != null and not bool(fallback_backplane.call("has_visual_asset")) and large_hull_node.find_child("ShipHullVisual", true, false) == null, "missing visual assets fall back to the procedural ShipHullBackplane")
	_check(int(view.call("_hull_socket_port", "socket_weapon_3")) >= 0, "large hull exposes its additional blueprint-defined weapon sockets")
	_check(large_hull_node.custom_minimum_size.x > small_hull_size.x and large_hull_node.custom_minimum_size.y > small_hull_size.y, "large hull backplane grows visually with its greater socket count")
	var large_weapon_socket := view.get_node(NodePath("ship_design_socket_weapon_0")) as GraphNode
	_check(int((socket_glyphs["socket_weapon_0"] as Control).get("tier")) == 5 and large_weapon_socket.custom_minimum_size.x > small_hull_size.x * 0.75, "the flagship's XXL/T5 socket is physically comparable to a low-tier hull instead of a uniform icon")
	view.call("_drop_data", Vector2(2100.0, 760.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	await get_tree().process_frame
	view.fit_design()
	var fitted_bounds := view.call("_design_bounds") as Rect2
	var fitted_left := fitted_bounds.position.x * view.zoom - view.scroll_offset.x
	var fitted_top := fitted_bounds.position.y * view.zoom - view.scroll_offset.y
	var fitted_right := fitted_bounds.end.x * view.zoom - view.scroll_offset.x
	var fitted_bottom := fitted_bounds.end.y * view.zoom - view.scroll_offset.y
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


func _outline_is_axially_symmetric(outline: PackedVector2Array, beam: float) -> bool:
	for point in outline:
		var mirror := Vector2(beam - point.x, point.y)
		var found := false
		for candidate in outline:
			if candidate.distance_to(mirror) <= 0.01:
				found = true
				break
		if not found:
			return false
	return true


func _control_tree_ignores_mouse(root: Control) -> bool:
	if root == null or root.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return false
	for child in root.get_children():
		if child is Control and not _control_tree_ignores_mouse(child as Control):
			return false
	return true
