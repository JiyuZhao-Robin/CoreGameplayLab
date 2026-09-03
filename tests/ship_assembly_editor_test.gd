extends Node

const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipModuleInspectorScript = preload("res://src/ui/components/ship_module_inspector.gd")
const ShipHullProfiles = preload("res://src/ui/components/ship_hull_profiles.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	await _audit_all_module_visuals()
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
	var installation_interfaces := Game.content.ship_installation_interface_layout(hull_id)
	_check(int(installation_interfaces.get("structure", 0)) == 2 and int(installation_interfaces.get("utility", 0)) == 1, "Lunar Pathfinder declares two interchangeable blue-square structure interfaces plus one special utility interface")
	_audit_interchangeable_structure_interfaces(plan_id, hull_id)
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
	for module_id in ["light_autocannon", "civilian_shield", "radiation_shielding", "cargo_expansion", "civilian_reactor_core", "sensor_array", "plasma_cannon"]:
		var module := (Game.content.modules[module_id] as Dictionary).duplicate(true)
		module["title"] = module_id
		module["assembly_mount"] = Game.ship_module_mount_role(module_id)
		modules[module_id] = module
	var view := ShipAssemblyMapViewScript.new()
	add_child(view)
	view.size = Vector2(1200.0, 800.0)
	view.configure({"plans":{plan_id:plan, large_plan_id:large_plan}, "hulls":{hull_id:hull, large_hull_id:large_hull}, "modules":modules, "slot_labels":{}, "socket_label_format":"%s %d", "module_label_format":"%s · %s", "hull_summary_format":"%s · %d sockets", "core_socket_format":"Energy Core %d"}, {})
	await get_tree().process_frame
	var toolbar_was_scaled := view.get_menu_hbox().has_theme_constant_override("separation")
	for toolbar_control in view.get_menu_hbox().find_children("*", "Control", true, false):
		toolbar_was_scaled = toolbar_was_scaled or bool(toolbar_control.get_meta("ship_toolbar_scaled", false))
	_check(not toolbar_was_scaled, "the canvas upper-left toolbar keeps its native text, icon, spacing and hit-target scale")
	var toolbar_children := view.get_menu_hbox().get_children()
	var readable_zoom_symbols := toolbar_children.size() >= 4
	for toolbar_index in range(1, mini(4, toolbar_children.size())):
		var zoom_button := toolbar_children[toolbar_index] as Button
		readable_zoom_symbols = readable_zoom_symbols and zoom_button != null and zoom_button.text == ["−", "1", "+"][toolbar_index - 1] and zoom_button.get_theme_font_size("font_size") >= UiTokens.ship_assembly_font_size(13)
	_check(readable_zoom_symbols, "native zoom actions use crisp font-scaled symbols instead of fixed-size bitmap icons")
	_check(not view.minimap_enabled and not view.show_minimap_button, "the redundant bottom-right overview and its toolbar toggle are removed from the assembly canvas")
	_check(view.draft_snapshot().get("nodes", []).is_empty(), "ship assembly canvas starts blank")
	view.call("_drop_data", Vector2(520.0, 220.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":plan_id, "definition_id":hull_id})
	await get_tree().process_frame
	var visual_backplane := view.get_node(NodePath("ship_design_hull")).find_child("ShipHullProjection", true, false) as Control
	var hull_visual := view.get_node(NodePath("ship_design_hull")).find_child("ShipHullVisual", true, false) as Control
	_check(visual_backplane != null and bool(visual_backplane.call("has_visual_asset")), "representative hull enables the passive high-detail visual through ShipHullBackplane")
	_check(_control_tree_ignores_mouse(hull_visual), "hull visual and all shader pass controls ignore mouse input")
	view.call("_drop_data", Vector2(80.0, 120.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	view.call("_drop_data", Vector2(80.0, 280.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"civilian_shield"})
	await get_tree().process_frame
	var draft := view.draft_snapshot()
	_check(draft.get("nodes", []).size() == 3, "hull and parts are created only by palette drops")
	_check(draft.get("connections", []).is_empty(), "dropping hull and parts never creates pre-wired links")
	var weapon_module := view.get_node(NodePath("ship_design_module_0001")) as GraphNode
	var shield_module := view.get_node(NodePath("ship_design_module_0002")) as GraphNode
	_check(weapon_module.title.is_empty() and weapon_module.custom_minimum_size == Vector2(328.0, 128.0), "every module uses the compact Reactor Core engineering chassis instead of a detached title bar")
	var module_card_surface := weapon_module.find_child("ModuleNodeVisual", true, false) as Control
	var module_connection_surface := weapon_module.find_child("VisualSocketBay", true, false) as Control
	var module_texture := weapon_module.find_child("ModuleArtwork", true, false) as TextureRect
	var module_name_label := weapon_module.find_child("ModuleName", true, false) as Label
	var module_metadata_label := weapon_module.find_child("ModuleMetadata", true, false) as Label
	_check(module_card_surface != null and module_texture != null and module_texture.texture != null and module_texture.size.x / module_card_surface.size.x >= 0.30 and module_connection_surface != null, "every module card gives its generated equipment artwork the same readable visual bay as Reactor Core")
	_check(shield_module.find_child("ModuleNodeVisual", true, false) is Control and shield_module.find_child("ModuleArtwork", true, false) is TextureRect, "non-reactor categories use the same reusable module visual component")
	_check(module_name_label.get_theme_font_size("font_size") == UiTokens.ship_assembly_font_size(11), "unified module-card typography keeps the approved 1.5x ship-assembly scale")
	_check(module_metadata_label != null and module_metadata_label.get_theme_font_size("font_size") == UiTokens.ship_assembly_font_size(9) and module_metadata_label.get_theme_color("font_color").a >= 0.70, "module technical metadata remains at a human-readable size and idle contrast")
	_check(module_card_surface.mouse_filter == Control.MOUSE_FILTER_IGNORE and module_connection_surface.mouse_filter == Control.MOUSE_FILTER_STOP, "only the connector symbol captures line gestures while the rest of the card remains a movement surface")
	_check(not weapon_module.draggable, "module movement uses the full card body instead of GraphNode's narrow title-only drag strip")
	_check(weapon_module.get_theme_icon("port").get_size() == Vector2.ONE, "the native GraphEdit port is visually inert while the inset socket owns the connection gesture")
	_check(view.get_theme_constant("port_hotzone_inner_extent") == 0 and view.get_theme_constant("port_hotzone_outer_extent") == 0, "the hidden native GraphEdit port cannot race the visible connector's authoritative drag gesture")
	_check(is_equal_approx(view.zoom_max, 5.0), "ship assembly supports inspection up to 500% zoom")
	var core_socket := view.get_node(NodePath("ship_design_socket_core_0")) as GraphNode
	var drive_socket := view.get_node(NodePath("ship_design_socket_drive_0")) as GraphNode
	var weapon_socket := view.get_node(NodePath("ship_design_socket_weapon_0")) as GraphNode
	var shield_socket := view.get_node(NodePath("ship_design_socket_shield_0")) as GraphNode
	var structural_socket := view.get_node(NodePath("ship_design_socket_utility_1")) as GraphNode
	var special_socket := view.get_node(NodePath("ship_design_socket_utility_0")) as GraphNode
	_check(int(view.call("_slot_port_type", "shield", "STRUCTURAL")) == int(view.call("_slot_port_type", "utility", "STRUCTURAL")), "shield, cargo and armor share one GraphEdit physical interface type")
	view.call("_on_connection_drag_started", StringName("ship_design_module_0002"), 0, true)
	_check(bool(view.call("_socket_matches_dragged_module", view.call("_hull_socket", "socket_shield_0"))) and bool(view.call("_socket_matches_dragged_module", view.call("_hull_socket", "socket_utility_1"))), "a civilian shield advertises both blue square sockets as compatible targets")
	view.call("_on_connection_drag_ended")
	var socket_glyphs := view.get("_socket_glyphs") as Dictionary
	var weapon_visual_socket := module_card_surface.call("visual_socket_center_local") as Vector2
	var weapon_route_port := module_card_surface.call("routing_port_local") as Vector2
	var socket_port_position := weapon_socket.get_input_port_position(0)
	var weapon_socket_glyph := weapon_socket.find_child("SocketGlyph_socket_weapon_0", true, false) as Control
	var socket_visual_center := weapon_socket.get_global_transform_with_canvas().affine_inverse() * weapon_socket_glyph.get_global_rect().get_center()
	_check(weapon_visual_socket.distance_to(weapon_route_port) >= 32.0 and weapon_visual_socket.distance_to(weapon_route_port) <= 52.0, "weapon module uses the same inset visual socket and short projected routing stub as Reactor Core")
	_check(socket_port_position.distance_to(socket_visual_center) <= 6.0, "native socket port is centered on the complete socket symbol (port=%s, symbol=%s)" % [socket_port_position, socket_visual_center])
	var position_before_body_drag := weapon_module.position_offset
	view.call("_begin_module_move", "ship_design_module_0001", weapon_module, Vector2(100.0, 100.0))
	view.call("_update_module_move", Vector2(148.0, 124.0))
	view.call("_finish_module_move")
	var expected_body_drag_delta := Vector2(48.0, 24.0) / view.zoom
	_check(weapon_module.position_offset.is_equal_approx(position_before_body_drag + expected_body_drag_delta), "dragging the card body moves the module instead of starting a connection")
	_check(weapon_socket.visible and weapon_socket.z_index > (view.get_node(NodePath("ship_design_hull")) as GraphNode).z_index, "visual artwork never hides or intercepts the socket hit target")
	_check(not bool(socket_glyphs["socket_weapon_0"].filled) and not bool(socket_glyphs["socket_utility_1"].filled), "all unconnected sockets start hollow")
	_check(String(socket_glyphs["socket_weapon_0"].shape) == "CIRCLE" and String(socket_glyphs["socket_utility_1"].shape) == "CIRCLE", "every installation family shares the same circular connector geometry")
	_check((socket_glyphs["socket_weapon_0"].tone as Color).is_equal_approx(UiTokens.COLOR_CRITICAL) and (socket_glyphs["socket_utility_1"].tone as Color).is_equal_approx(UiTokens.COLOR_INFORMATION), "idle sockets retain restrained family colors instead of shape-coded identities")
	var orthogonal_route := view.call("_orthogonal_connection_points", Vector2(0.0, 0.0), Vector2(100.0, 60.0)) as PackedVector2Array
	_check(orthogonal_route.size() == 6 and is_equal_approx(orthogonal_route[0].y, orthogonal_route[1].y) and is_equal_approx(orthogonal_route[1].x, orthogonal_route[2].x) and is_equal_approx(orthogonal_route[2].y, orthogonal_route[3].y) and is_equal_approx(orthogonal_route[3].x, orthogonal_route[4].x) and is_equal_approx(orthogonal_route[4].y, orthogonal_route[5].y), "connection routing retains DSPONLINE's orthogonal lead/rail/lead geometry")
	var rounded_line := view.call("_get_connection_line", Vector2(0.0, 0.0), Vector2(100.0, 60.0)) as PackedVector2Array
	_check(rounded_line.size() > orthogonal_route.size() and rounded_line[0].is_equal_approx(orthogonal_route[0]) and rounded_line[rounded_line.size() - 1].is_equal_approx(orthogonal_route[orthogonal_route.size() - 1]), "connection rendering rounds orthogonal corners without moving its endpoints")
	_check(drive_socket.position_offset.y < core_socket.position_offset.y, "drive socket is spatially embedded above the central core")
	_check(weapon_socket.position_offset.x < core_socket.position_offset.x and special_socket.position_offset.x > core_socket.position_offset.x, "special-plugin sockets are embedded on opposite hull flanks")
	_check(shield_socket.position_offset.y > core_socket.position_offset.y and structural_socket.position_offset.y > core_socket.position_offset.y, "shield and structural cabin sockets are embedded along the bottom of the hull backplane")
	view.call("_on_connection_drag_started", StringName("ship_design_module_0001"), 0, true)
	var incompatible_socket_screen := (shield_socket.position_offset + shield_socket.custom_minimum_size * 0.5) * view.zoom - view.scroll_offset
	_check(String(view.call("_socket_at_screen_position", incompatible_socket_screen, true)).is_empty(), "connection release never resolves an incompatible socket from an overlapping broad drop region")
	_check((socket_glyphs["socket_weapon_0"].tone as Color).is_equal_approx(UiTokens.COLOR_CRITICAL) and not bool(socket_glyphs["socket_weapon_0"].filled), "connection draft highlights only the compatible hollow socket")
	_check(String(socket_glyphs["socket_weapon_0"].visual_state) == "compatible" and String(socket_glyphs["socket_shield_0"].visual_state) == "muted", "connection draft exposes compatible and muted port visual states")
	_check((socket_glyphs["socket_shield_0"].tone as Color).is_equal_approx(UiTokens.COLOR_INFORMATION), "connection draft keeps the incompatible socket's family color while muting its state")
	var muted_fx := socket_glyphs["socket_shield_0"].call("fx_material") as ShaderMaterial
	_check(muted_fx != null and is_zero_approx(float(muted_fx.get_shader_parameter("active_amount"))), "incompatible and muted sockets stop all running sweep/core animation")
	view.call("_on_socket_hover_changed", "socket_weapon_0", true)
	view.call("_on_connection_drag_ended")
	await get_tree().process_frame
	_check(view.draft_snapshot().get("connections", []).size() == 1, "releasing a native drag after its preview snaps green always commits that accepted socket")
	view.call("_on_disconnection_request", StringName("ship_design_module_0001"), 0, StringName(weapon_socket.name), 0)
	view.call("_begin_module_card_connection", "ship_design_module_0001")
	var broad_socket_hit := (weapon_socket.position_offset + Vector2(weapon_socket.custom_minimum_size.x * 0.75, weapon_socket.custom_minimum_size.y * 0.25)) * view.zoom - view.scroll_offset
	view.call("_update_manual_connection_target", broad_socket_hit)
	var snapped_preview_route := view.call("_nearest_edge_connection_route", weapon_module, weapon_socket) as Dictionary
	_check((module_card_surface.call("facing_normal") as Vector2).is_equal_approx(snapped_preview_route.get("source_normal", Vector2.RIGHT) as Vector2), "drag preview and visible inset connector share the same authoritative source edge")
	view.call("_complete_module_card_connection", Vector2(-1000.0, -1000.0))
	_check(view.draft_snapshot().get("connections", []).size() == 1, "a green connector-symbol target stays locked through release jitter and connects without acquiring a tiny edge point")
	_check(bool(socket_glyphs["socket_weapon_0"].filled) and String(socket_glyphs["socket_weapon_0"].visual_state) == "connected", "connected socket becomes colored, filled and enters the connected visual state")
	view.call("_on_connection_drag_started", StringName("ship_design_module_0001"), 0, true)
	_check(not bool(view.call("_socket_matches_dragged_module", view.call("_hull_socket", "socket_weapon_0"))), "an occupied module or socket can never advertise a green accepted preview")
	view.call("_on_connection_drag_ended")
	await get_tree().process_frame
	_check(view.draft_snapshot().get("connections", []).size() == 1, "ending a non-green occupied drag does not duplicate or replace its existing connection")
	var installed_link := (view.get("_links") as Array)[0] as Dictionary
	var living_glyph = socket_glyphs["socket_weapon_0"]
	var living_fx_surface := living_glyph.find_child("ShipPortFx", true, false) as ColorRect
	var living_fx := living_glyph.call("fx_material") as ShaderMaterial
	_check(living_fx_surface != null and living_fx_surface.mouse_filter == Control.MOUSE_FILTER_IGNORE and living_fx != null and is_equal_approx(living_fx_surface.size.x, living_fx_surface.size.y), "connected socket owns a square passive shader surface that neither distorts the ring nor intercepts hit testing")
	_check(not living_glyph.is_processing() and living_fx.shader.code.find("TIME") >= 0 and living_fx.shader.code.find("value_noise") >= 0, "socket sweep and irregular core activity run in the CanvasItem shader without a GDScript frame loop")
	_check(is_equal_approx(float(living_fx.get_shader_parameter("active_amount")), 1.0) and float(living_fx.get_shader_parameter("sweep_period")) >= 6.0 and float(living_fx.get_shader_parameter("sweep_period")) <= 12.0, "idle connected socket enables a restrained 6–12 second ring sweep")
	view.call("_on_connection_packet_arrived", "socket_weapon_0")
	_check(float(living_glyph.get("_install_flash_remaining")) > 0.0 and is_equal_approx(float(living_fx.get_shader_parameter("arrival_strength")), 0.62), "ambient packet arrival triggers only the target socket's short restrained core/ring response")
	var live_hull := view.get_node(NodePath("ship_design_hull")) as GraphNode
	var socket_position_before_hull_drag := weapon_socket.position_offset
	var connection_layer := view.get("_visual_layer") as Control
	var packet_timing := connection_layer.call("_packet_timing", installed_link, false) as Dictionary
	var focused_packet_timing := connection_layer.call("_packet_timing", installed_link, true) as Dictionary
	_check(float(packet_timing.get("cycle_seconds", 0.0)) >= 4.0 and float(packet_timing.get("cycle_seconds", 0.0)) <= 8.0 and float(packet_timing.get("travel_seconds", 0.0)) >= 0.6 and float(packet_timing.get("travel_seconds", 0.0)) <= 1.2, "ambient connection packets use the required 4–8 second interval and 0.6–1.2 second travel time")
	_check(float(focused_packet_timing.get("cycle_seconds", INF)) <= float(packet_timing.get("cycle_seconds", 0.0)), "selected or hovered connections modestly increase packet frequency without becoming a stream")
	connection_layer.call("_cached_route", installed_link)
	_check(not (connection_layer.get("_route_cache") as Dictionary).is_empty(), "established connection route is cached before live hull movement")
	var live_hull_delta := Vector2(84.0, -46.0)
	live_hull.position_offset += live_hull_delta
	var weapon_path := view.call("_world_path_for_link", installed_link) as PackedVector2Array
	_check(weapon_socket.position_offset.is_equal_approx(socket_position_before_hull_drag + live_hull_delta), "hull position changes move every socket immediately without waiting for drag release")
	var moved_socket_center := view.call("_graph_node_center", weapon_socket) as Vector2
	var moved_socket_size := view.call("_graph_node_size", weapon_socket) as Vector2
	_check(_is_edge_center(weapon_path[weapon_path.size() - 1], moved_socket_center, moved_socket_size), "connected line endpoint follows the moved socket edge during the same hull movement frame")
	_check((connection_layer.get("_route_cache") as Dictionary).is_empty(), "live hull movement invalidates cached connection geometry immediately")
	var expected_module_center := view.call("_graph_node_center", weapon_module) as Vector2
	var expected_socket_center := view.call("_graph_node_center", weapon_socket) as Vector2
	var module_size := view.call("_graph_node_size", weapon_module) as Vector2
	var socket_size := view.call("_graph_node_size", weapon_socket) as Vector2
	var chosen_route := view.call("_nearest_edge_connection_route", weapon_module, weapon_socket) as Dictionary
	var chosen_source_normal := chosen_route.get("source_normal", Vector2.RIGHT) as Vector2
	var chosen_route_port := module_card_surface.call("routing_port_local_for_normal", chosen_source_normal) as Vector2
	var expected_visual_start := weapon_module.position_offset + module_card_surface.position + chosen_route_port
	_check(weapon_path[0].is_equal_approx(expected_visual_start) and _is_edge_center(weapon_path[weapon_path.size() - 1], expected_socket_center, socket_size), "connection geometry projects the inset visual socket to the selected card edge while retaining the hull-socket edge anchor")
	var rendered_start_screen := weapon_path[0] * view.zoom - view.scroll_offset
	var actual_edge_global := module_card_surface.get_global_transform_with_canvas() * chosen_route_port
	var actual_edge_screen := connection_layer.get_global_transform_with_canvas().affine_inverse() * actual_edge_global
	_check(rendered_start_screen.distance_to(actual_edge_screen) <= 0.5, "the rendered line touches the plugin entity's real visual edge without a GraphNode content-offset gap")
	var shortest_candidate_score := INF
	for source_normal_value in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var source_normal := source_normal_value as Vector2
		for target_normal_value in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			var target_normal := target_normal_value as Vector2
			var start_anchor := view.call("_edge_anchor", weapon_module, source_normal) as Vector2
			var finish_anchor := view.call("_edge_anchor", weapon_socket, target_normal) as Vector2
			var candidate := view.call("_best_orthogonal_connection_route", start_anchor, finish_anchor, source_normal, target_normal, weapon_module, weapon_socket) as Dictionary
			shortest_candidate_score = minf(shortest_candidate_score, float(candidate.get("score", INF)))
	_check(is_equal_approx(float(chosen_route.get("score", INF)), shortest_candidate_score), "all 16 source/target edge combinations participate in shortest orthogonal route selection")
	var reverse_path := view.call("_get_entity_connection_line", weapon_module, expected_module_center - Vector2(500.0, 80.0), null) as PackedVector2Array
	_check(reverse_path.size() > 2 and reverse_path[1].x < reverse_path[0].x and is_equal_approx(reverse_path[0].x, expected_module_center.x - module_size.x * 0.5), "a target on the left makes the preview emerge from the left edge")
	var downward_path := view.call("_get_entity_connection_line", weapon_module, expected_module_center + Vector2(4.0, 500.0), null) as PackedVector2Array
	var upward_path := view.call("_get_entity_connection_line", weapon_module, expected_module_center - Vector2(4.0, 500.0), null) as PackedVector2Array
	var centered_right_socket := module_card_surface.call("visual_socket_center_local_for_normal", Vector2.RIGHT) as Vector2
	var centered_up_socket := module_card_surface.call("visual_socket_center_local_for_normal", Vector2.UP) as Vector2
	var centered_down_socket := module_card_surface.call("visual_socket_center_local_for_normal", Vector2.DOWN) as Vector2
	_check(centered_right_socket.is_equal_approx(centered_up_socket) and centered_right_socket.is_equal_approx(centered_down_socket) and is_equal_approx(centered_right_socket.y, module_card_surface.size.y * 0.5), "right-side connector ball stays vertically centered while its stub can route upward or downward")
	var expected_down_port := weapon_module.position_offset + module_card_surface.position + (module_card_surface.call("routing_port_local_for_normal", Vector2.DOWN) as Vector2)
	var expected_up_port := weapon_module.position_offset + module_card_surface.position + (module_card_surface.call("routing_port_local_for_normal", Vector2.UP) as Vector2)
	_check(downward_path.size() > 2 and downward_path[0].is_equal_approx(expected_down_port) and downward_path[1].y > downward_path[0].y, "a target below projects the inset socket onto the bottom edge")
	_check(upward_path.size() > 2 and upward_path[0].is_equal_approx(expected_up_port) and upward_path[1].y < upward_path[0].y, "a target above projects the inset socket onto the top edge")
	var overhead_target := GraphNode.new()
	overhead_target.position_offset = weapon_module.position_offset + Vector2(248.0, -260.0)
	overhead_target.custom_minimum_size = Vector2(64.0, 64.0)
	var overhead_route := view.call("_nearest_edge_connection_route", weapon_module, overhead_target) as Dictionary
	_check((overhead_route.get("source_normal", Vector2.ZERO) as Vector2) == Vector2.UP and (overhead_route.get("start", Vector2.ZERO) as Vector2).is_equal_approx(expected_up_port), "an established target above the plugin remains eligible for a true top-edge route")
	overhead_target.free()
	var selection_point := weapon_path[weapon_path.size() / 2] * view.zoom - view.scroll_offset
	_check(bool(view.call("_select_connection_at", selection_point)) and not String(view.get("_selected_connection_key")).is_empty(), "custom connection hit testing selects the enhanced visual line")
	_check(is_equal_approx(float(living_fx.get_shader_parameter("selection_amount")), 1.0), "selected connection raises only its endpoint socket clarity")
	var interaction_snapshot := JSON.stringify(view.draft_snapshot())
	view.zoom = 5.0
	await get_tree().process_frame
	_check(is_equal_approx(view.zoom, 5.0), "the canvas reaches the full 500% inspection scale without clamping early")
	view.zoom = 0.74
	view.scroll_offset = Vector2(137.0, 89.0)
	await get_tree().process_frame
	_check(JSON.stringify(view.draft_snapshot()) == interaction_snapshot, "zoom and pan remain presentation-only and do not move saved design nodes or connections")
	view.request_module_connection("ship_design_module_0002", "socket_weapon_0")
	_check(view.draft_snapshot().get("connections", []).size() == 1, "shield/structural installation family cannot connect to a weapon-family socket")
	view.request_module_connection("ship_design_module_0002", "socket_shield_0")
	var missing_core := Game.ship_design_validation(plan_id, view.draft_snapshot().get("nodes", []), view.draft_snapshot().get("connections", []))
	_check(String(missing_core.get("reason_code", "")) == "CORE_REQUIRED", "a hull with an empty central energy-core socket cannot be saved for construction")
	view.call("_drop_data", Vector2(80.0, 440.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"civilian_reactor_core"})
	view.request_module_connection("ship_design_module_0003", "socket_core_0")
	await get_tree().process_frame
	var reactor_module := view.get_node(NodePath("ship_design_module_0003")) as GraphNode
	var reactor_visual := reactor_module.find_child("ModuleNodeVisual", true, false) as Control
	var reactor_artwork := reactor_module.find_child("ModuleArtwork", true, false) as TextureRect
	var reactor_socket_bay := reactor_module.find_child("VisualSocketBay", true, false) as Control
	var reactor_socket_glyph := reactor_module.find_child("VisualModuleSocket", true, false) as Control
	var reactor_metadata := reactor_module.find_child("ModuleMetadata", true, false) as Label
	_check(reactor_visual != null and reactor_module.custom_minimum_size.x >= 300.0 and reactor_module.custom_minimum_size.x <= 340.0 and reactor_module.custom_minimum_size.y >= 112.0 and reactor_module.custom_minimum_size.y <= 132.0, "reactor uses the shared 300–340 × 112–132 engineering chassis")
	_check(reactor_module.custom_minimum_size.x / reactor_module.custom_minimum_size.y >= 2.4 and reactor_module.custom_minimum_size.x / reactor_module.custom_minimum_size.y <= 2.8, "reactor chassis avoids the deprecated 4:1 flat card ratio")
	_check(reactor_artwork != null and reactor_artwork.texture != null and reactor_artwork.size.x / reactor_visual.size.x >= 0.30, "reactor artwork is readable and owns at least 30 percent of the card width")
	_check(reactor_socket_bay != null and reactor_socket_bay.size == Vector2(52.0, 52.0) and String(reactor_socket_glyph.get("shape")) == "CIRCLE", "reactor has a 52px hit bay around its shared circular, core-colored socket")
	_check(reactor_visual.mouse_filter == Control.MOUSE_FILTER_IGNORE and reactor_socket_bay.mouse_filter == Control.MOUSE_FILTER_STOP, "visual chassis cannot intercept card movement while only the explicit inset socket hit bay captures a connection gesture")
	_check(reactor_metadata != null and reactor_metadata.text.find("CIRCLE") < 0, "normal reactor metadata does not duplicate the socket shape in text")
	var reactor_facing := reactor_visual.call("facing_normal") as Vector2
	var reactor_visual_socket := reactor_visual.call("visual_socket_center_local") as Vector2
	var reactor_route_port := reactor_visual.call("routing_port_local") as Vector2
	var expected_reactor_stub_length := reactor_visual.size.y * 0.5 if not is_zero_approx(reactor_facing.y) else 44.0
	_check(is_equal_approx(reactor_visual_socket.distance_to(reactor_route_port), expected_reactor_stub_length), "visual reactor socket stays centered while its stub reaches the selected side or vertical edge")
	for edge_normal in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var expected_route_port := reactor_module.position_offset + reactor_visual.position + (reactor_visual.call("routing_port_local_for_normal", edge_normal) as Vector2)
		_check((view.call("_edge_anchor", reactor_module, edge_normal) as Vector2).is_equal_approx(expected_route_port), "reactor %s route starts at the projected visual port without changing the logical socket" % edge_normal)
	var reactor_link := (view.get("_links") as Array).filter(func(link: Dictionary) -> bool: return String(link.get("module_node_id", "")) == "ship_design_module_0003")[0] as Dictionary
	var reactor_route := view.call("_nearest_edge_connection_route", reactor_module, core_socket) as Dictionary
	var reactor_path := view.call("_world_path_for_link", reactor_link) as PackedVector2Array
	_check(reactor_path[0].is_equal_approx(reactor_module.position_offset + reactor_visual.position + (reactor_visual.call("routing_port_local_for_normal", reactor_route.get("source_normal", reactor_facing)) as Vector2)), "installed reactor line reuses the authoritative shortest route from its projected edge port")
	var reactor_snapshot := JSON.stringify(view.draft_snapshot())
	view.zoom = 0.44
	view.call("_on_zoom_changed", view.zoom)
	await get_tree().process_frame
	_check(String(reactor_visual.call("lod_level")) == "far" and not reactor_metadata.visible, "far zoom intentionally hides reactor micro-metadata")
	view.zoom = 1.20
	view.call("_on_zoom_changed", view.zoom)
	await get_tree().process_frame
	_check(String(reactor_visual.call("lod_level")) == "close" and reactor_metadata.visible, "close zoom restores reactor technical metadata")
	_check(JSON.stringify(view.draft_snapshot()) == reactor_snapshot, "reactor LOD changes are presentation-only and cannot alter saved node positions or links")
	view.call("_on_visual_node_hover_changed", reactor_module, true)
	reactor_module.selected = true
	view.call("_on_node_selected", reactor_module)
	_check(bool(reactor_visual.get("_hovered")) and bool(reactor_visual.get("_selected")), "reactor hover and selected states raise focus without changing its chassis")
	view.call("_begin_module_move", "ship_design_module_0003", reactor_module, Vector2.ZERO)
	_check(bool(reactor_visual.get("_dragging")) and reactor_module.z_index == 7, "dragging raises only the reactor card above connection rendering")
	view.call("_finish_module_move")
	view.call("_begin_module_card_connection", "ship_design_module_0003")
	view.call("_on_socket_hover_changed", "socket_shield_0", true)
	_check(bool(reactor_visual.get("_invalid")) and String(reactor_socket_glyph.get("visual_state")) == "incompatible", "reactor invalid target uses a local muted warning instead of painting the whole card red")
	view.call("_complete_module_card_connection", Vector2(-1000.0, -1000.0))
	_check(view.draft_snapshot().get("connections", []).size() == 3, "reactor presentation states cannot duplicate or replace an occupied logical connection")
	var inspector_module := (modules["civilian_reactor_core"] as Dictionary).duplicate(true)
	inspector_module["ui_properties"] = [{"id":"future_flux", "display_name":"Future flux", "value":17, "unit":"FU", "presentation_type":"NUMBER", "priority":100, "category":"ADVANCED"}]
	var module_inspector := ShipModuleInspectorScript.new()
	add_child(module_inspector)
	module_inspector.configure(inspector_module, {"display_name":"Civilian Reactor Core", "family_label":"Core", "art_path":ShipAssemblyMapViewScript.module_icon_path(inspector_module)})
	var inspector_properties := module_inspector.property_descriptors()
	_check(inspector_properties.any(func(property: Dictionary) -> bool: return String(property.get("id", "")) == "future_flux"), "module inspector accepts arbitrary future property descriptors without a module-specific layout")
	_check(module_inspector.find_child("ModuleInspectorSection_PERFORMANCE", true, false) != null and module_inspector.find_child("ModuleInspectorSection_COMPATIBILITY", true, false) != null, "module inspector separates progressive information into reusable collapsible sections")
	var inspector_toggle := module_inspector.find_child("ModuleInspectorSectionToggle_PERFORMANCE", true, false) as Button
	_check(inspector_toggle != null and (inspector_toggle.text.begins_with("▸") or inspector_toggle.text.begins_with("▾")) and inspector_toggle.custom_minimum_size.y >= float(UiTokens.layout_px(36.0)), "module inspector sections expose a weighted readable disclosure glyph and row target")
	module_inspector.queue_free()
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
	var expected_tight_hull_size := Vector2(44.0, 132.0) * ShipHullProfiles.WORLD_SCALE + Vector2.ONE * ShipHullProfiles.HULL_BOARD_PADDING * 2.0
	_check(small_hull_size.is_equal_approx(expected_tight_hull_size), "the draggable hull rectangle keeps only a 12 px crop margin around the physical hull bounds")
	_check((small_hull_node.find_child("ShipHullProjection", true, false) as Control) != null and int((socket_glyphs["socket_weapon_0"] as Control).get("tier")) == 2, "the small hull renders its orthographic projection and M/T2 sockets")
	_check(not (small_hull_node.find_child("ShipHullProjection", true, false) as Control).has_method("_draw_dimensions"), "hull artwork no longer renders width, length, tier or diameter annotations")
	var native_visual_texture := load("res://assets/ships/lunar_pathfinder/base_4k.png") as Texture2D
	_check(native_visual_texture != null and maxi(native_visual_texture.get_width(), native_visual_texture.get_height()) == 4096 and small_hull_size.y < native_visual_texture.get_height(), "logical Fit All bounds stay independent from the native 4K texture dimensions")
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
	var interaction_catalog := {"plans":{plan_id:plan}, "hulls":{hull_id:hull}, "modules":modules, "structural_label":"Structure", "slot_labels":{}, "socket_label_format":"%s %d", "module_label_format":"%s · %s", "hull_summary_format":"%s · %d sockets", "core_socket_format":"Energy Core %d"}
	await _audit_structure_interface_dragging(interaction_catalog)
	await _audit_module_removal_interactions(interaction_catalog)
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


func _audit_interchangeable_structure_interfaces(plan_id: String, hull_id: String) -> void:
	var common_modules := ["light_autocannon", "advanced_drive", "sensor_array", "civilian_reactor_core"]
	var common_sockets := ["socket_weapon_0", "socket_drive_0", "socket_utility_0", "socket_core_0"]
	var structure_pairs := [
		["civilian_shield", "civilian_shield"],
		["cargo_expansion", "cargo_expansion"],
		["radiation_shielding", "radiation_shielding"],
		["civilian_shield", "cargo_expansion"],
		["civilian_shield", "radiation_shielding"],
		["cargo_expansion", "radiation_shielding"]
	]
	for pair_value in structure_pairs:
		var pair := pair_value as Array
		var module_ids := common_modules.duplicate()
		module_ids.append_array(pair)
		var nodes: Array = [{"node_id":"test_hull", "kind":"hull", "definition_id":hull_id, "position":{"x":0.0, "y":0.0}}]
		var connections: Array = []
		for module_index in module_ids.size():
			var node_id := "test_module_%d" % module_index
			nodes.append({"node_id":node_id, "kind":"module", "definition_id":module_ids[module_index], "position":{"x":float(module_index * 40), "y":120.0}})
			var socket_id: String = str(common_sockets[module_index] if module_index < common_sockets.size() else ["socket_shield_0", "socket_utility_1"][module_index - common_sockets.size()])
			connections.append({"module_node_id":node_id, "socket_id":socket_id})
		var validation := Game.ship_design_validation(plan_id, nodes, connections)
		_check(bool(validation.get("allowed", false)), "structure pair %s + %s is accepted by the authoritative blueprint validator: %s" % [pair[0], pair[1], validation.get("reason", "")])
		_check(Game.content.ship_loadout_error(hull_id, module_ids).is_empty(), "structure pair %s + %s is accepted by the downstream shipyard loadout validator" % [pair[0], pair[1]])


func _audit_structure_interface_dragging(catalog: Dictionary) -> void:
	for module_id in ["civilian_shield", "cargo_expansion", "radiation_shielding"]:
		var structure_view := ShipAssemblyMapViewScript.new()
		add_child(structure_view)
		structure_view.size = Vector2(1200.0, 800.0)
		structure_view.configure(catalog, {})
		structure_view.call("_drop_data", Vector2(520.0, 220.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
		structure_view.call("_drop_data", Vector2(80.0, 120.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":module_id})
		structure_view.call("_drop_data", Vector2(80.0, 300.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":module_id})
		structure_view.request_module_connection("ship_design_module_0001", "socket_shield_0")
		structure_view.request_module_connection("ship_design_module_0002", "socket_utility_1")
		await get_tree().process_frame
		var links := structure_view.draft_snapshot().get("connections", []) as Array
		_check(links.size() == 2 and links.all(func(link: Dictionary) -> bool: return str(link.get("interface_family", "")) == "structure"), "two %s modules connect simultaneously to the two interchangeable blue-square sockets" % module_id)
		structure_view.queue_free()
		await get_tree().process_frame


func _audit_all_module_visuals() -> void:
	var definitions := {}
	for module_id_value in Game.content.modules.keys():
		var module_id := String(module_id_value)
		var module := (Game.content.modules[module_id] as Dictionary).duplicate(true)
		module["title"] = module_id.replace("_", " ").capitalize()
		module["assembly_mount"] = Game.ship_module_mount_role(module_id)
		definitions[module_id] = module
	var audit_view := ShipAssemblyMapViewScript.new()
	add_child(audit_view)
	audit_view.size = Vector2(1400.0, 900.0)
	audit_view.configure({
		"plans":{},
		"hulls":{},
		"modules":definitions,
		"slot_labels":{"weapon":"Weapon", "shield":"Shield", "drive":"Drive", "utility":"Utility", "core":"Core"},
		"socket_label_format":"%s %d",
		"module_label_format":"%s · %s",
		"hull_summary_format":"%s · %d sockets",
		"core_socket_format":"Energy Core %d"
	}, {})
	var module_index := 0
	for module_id_value in definitions.keys():
		audit_view.call("_drop_data", Vector2(40.0 + float(module_index % 4) * 350.0, 40.0 + float(module_index / 4) * 145.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":String(module_id_value)})
		module_index += 1
	await get_tree().process_frame
	_check((audit_view.get("_module_visuals") as Dictionary).size() == definitions.size(), "every content module is routed through the shared Reactor Core visual component")
	for child in audit_view.get_children():
		var module_node := child as GraphNode
		if module_node == null or String(module_node.get_meta("entity_kind", "")) != "module":
			continue
		var visual := module_node.find_child("ModuleNodeVisual", true, false) as Control
		var artwork := module_node.find_child("ModuleArtwork", true, false) as TextureRect
		var socket_bay := module_node.find_child("VisualSocketBay", true, false) as Control
		_check(visual != null and module_node.custom_minimum_size == Vector2(328.0, 128.0) and artwork != null and artwork.texture != null and maxi(artwork.texture.get_width(), artwork.texture.get_height()) == 4096 and socket_bay != null, "%s uses the unified chassis, 4K artwork bay and inset socket" % String(module_node.get_meta("entity_id", "")))
	audit_view.queue_free()
	await get_tree().process_frame


func _audit_module_removal_interactions(catalog: Dictionary) -> void:
	var removal_view := ShipAssemblyMapViewScript.new()
	add_child(removal_view)
	removal_view.size = Vector2(1200.0, 800.0)
	removal_view.configure(catalog, {})
	removal_view.call("_drop_data", Vector2(520.0, 220.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	removal_view.call("_drop_data", Vector2(80.0, 120.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	removal_view.request_module_connection("ship_design_module_0001", "socket_weapon_0")
	await get_tree().process_frame
	var dragged_module := removal_view.get_node(NodePath("ship_design_module_0001")) as GraphNode
	var trash_target := removal_view.get_node(NodePath("ShipAssemblyTrashDropTarget")) as Control
	removal_view.call("_begin_module_move", "ship_design_module_0001", dragged_module, Vector2(100.0, 100.0))
	removal_view.call("_set_trash_drop_target_visible", true, true)
	var trash_rect := trash_target.call("drop_rect") as Rect2
	_check(is_equal_approx(dragged_module.modulate.a, 0.48) and trash_target.visible and trash_target.mouse_filter == Control.MOUSE_FILTER_IGNORE, "dragging ghosts the module card while a passive trash target slides up above the canvas")
	_check(trash_rect.position.y >= 0.0 and trash_rect.end.y <= removal_view.size.y, "the revealed trash target remains fully inside the bottom of the assembly canvas")
	removal_view.call("_update_module_move", trash_rect.get_center())
	_check(bool(trash_target.get("drop_hovered")), "the trash target enters its warning state when the dragged module reaches the drop region")
	await _capture_removal_interaction()
	removal_view.call("_finish_module_move", trash_rect.get_center())
	_check(not removal_view.has_node(NodePath("ship_design_module_0001")) and removal_view.draft_snapshot().get("connections", []).is_empty(), "dropping a connected module into the trash removes both the module instance and its link")

	removal_view.call("_drop_data", Vector2(80.0, 120.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	await get_tree().process_frame
	var keyboard_module := removal_view.get_node(NodePath("ship_design_module_0002")) as GraphNode
	keyboard_module.selected = true
	removal_view.grab_focus()
	var forward_delete := InputEventKey.new()
	forward_delete.pressed = true
	forward_delete.keycode = KEY_DELETE
	removal_view.call("_handle_module_removal_key", forward_delete)
	_check(removal_view.has_node(NodePath("ship_design_module_0002")), "forward Delete is disabled and cannot remove a selected module")
	var backspace := InputEventKey.new()
	backspace.pressed = true
	backspace.keycode = KEY_BACKSPACE
	removal_view.call("_handle_module_removal_key", backspace)
	_check(not removal_view.has_node(NodePath("ship_design_module_0002")) and removal_view.has_node(NodePath("ship_design_hull")), "Backspace removes the selected module without deleting the hull")
	removal_view.queue_free()
	await get_tree().process_frame


func _capture_removal_interaction() -> void:
	if DisplayServer.get_name() == "headless":
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	_check(image != null and image.save_png("res://.audit-logs/ship_assembly_trash_drop.png") == OK, "trash-drop interaction audit screenshot saves")


func _is_edge_center(point: Vector2, center: Vector2, node_size: Vector2) -> bool:
	var horizontal_edge := is_equal_approx(point.y, center.y) and (is_equal_approx(point.x, center.x - node_size.x * 0.5) or is_equal_approx(point.x, center.x + node_size.x * 0.5))
	var vertical_edge := is_equal_approx(point.x, center.x) and (is_equal_approx(point.y, center.y - node_size.y * 0.5) or is_equal_approx(point.y, center.y + node_size.y * 0.5))
	return horizontal_edge or vertical_edge


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
