extends Node

const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipHullVisualScript = preload("res://src/ui/components/ship_hull_visual.gd")

var failures: Array[String] = []
var view: ShipAssemblyMapView


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	get_window().size = Vector2i(1600, 1000)
	var background := ColorRect.new()
	background.color = Color("050b0a")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	view = ShipAssemblyMapViewScript.new()
	add_child(view)
	view.position = Vector2(24.0, 24.0)
	view.size = Vector2(1552.0, 952.0)
	view.configure(_catalog(), {})
	await _frames(3)
	view.call("_drop_data", view.size * 0.5, {
		"ship_assembly_palette":true,
		"kind":"hull",
		"plan_id":"construct_lunar_pathfinder",
		"definition_id":"lunar_pathfinder"
	})
	await _frames(4)
	var hull := view.get_node_or_null(NodePath("ship_design_hull")) as GraphNode
	var visual := hull.find_child("ShipHullVisual", true, false) as Control if hull != null else null
	_check(hull != null and visual != null, "representative high-detail hull deploys on the existing assembly canvas")
	if hull == null or visual == null:
		_finish()
		return
	_check(not visual.is_processing(), "hull flow animation uses shader TIME without a GDScript frame loop")
	var base_fx := visual.find_child("ShipHullBaseFx", true, false) as ColorRect
	var ghost := visual.find_child("ShipHullGhost", true, false) as ColorRect
	var micro_lights := visual.find_child("ShipHullMicroLights", true, false) as Control
	var hull_texture := load("res://assets/ships/lunar_pathfinder/base_4k.png") as Texture2D
	var hull_mask := load("res://assets/ships/lunar_pathfinder/fx_mask_4k.png") as Texture2D
	_check(hull_texture != null and hull_mask != null and hull_texture.get_size() == hull_mask.get_size() and maxi(hull_texture.get_width(), hull_texture.get_height()) == 4096, "authored hull base and FX mask are registered matching 4K textures")
	_check(base_fx != null and base_fx.material is ShaderMaterial and ghost != null and ghost.material is ShaderMaterial, "base FX and technical ghost use shared CanvasItem shaders")
	_check((base_fx.material as ShaderMaterial).shader.code.find("TIME") >= 0 and (ghost.material as ShaderMaterial).shader.code.find("TIME") >= 0, "both restrained dynamic passes remain live after deployment")
	_check((base_fx.material as ShaderMaterial).shader.code.find("wide_halo") >= 0 and (base_fx.material as ShaderMaterial).shader.code.find("aura_flow") >= 0 and float((base_fx.material as ShaderMaterial).get_shader_parameter("halo_strength")) >= 0.30, "hull-colored soft light uses a wide animated aura instead of a static hard outline")
	_check(micro_lights != null and micro_lights.mouse_filter == Control.MOUSE_FILTER_IGNORE and not micro_lights.is_processing(), "normalized structural traveling lights are a passive event-driven presentation layer")
	_check(micro_lights != null and (micro_lights.get("_paths") as Array).size() >= 4, "representative 132m hull provides multiple registered structural light paths")
	_test_base_only_fallback()
	view.fit_design()
	await _capture("fit_all")
	_center_hull(hull, 0.92)
	view.call("_sync_hull_presentation")
	await _capture("idle_hull")
	await _capture("normal_zoom")
	hull.selected = true
	view.call("_on_node_selected", hull)
	await _capture("selected_hull")
	hull.selected = false
	view.call("_on_node_deselected", hull)
	if OS.get_environment("SHIP_HULL_AMBIENT_AUDIT") == "1":
		await _capture_ambient_sequence(micro_lights)
	_center_hull(hull, 0.38)
	view.call("_sync_hull_presentation")
	await _capture("far_zoom")
	_check(not micro_lights.visible and int(micro_lights.call("active_light_count")) == 0, "far zoom disables sub-pixel traveling lights instead of leaving shimmer")
	_center_hull(hull, 1.36)
	view.call("_sync_hull_presentation")
	await _capture("close_zoom")
	micro_lights.call("force_event_for_test", 0)
	await get_tree().create_timer(0.22).timeout
	_check(int(micro_lights.call("active_light_count")) == 1, "close/normal LOD can run one sparse structure-bound traveling highlight")
	_center_hull(hull, 0.92)
	view.call("_sync_hull_presentation")
	view.call("_drop_data", Vector2(150.0, 180.0), {
		"ship_assembly_palette":true,
		"kind":"module",
		"definition_id":"light_autocannon"
	})
	view.call("_on_connection_drag_started", StringName("ship_design_module_0001"), 0, true)
	view.call("_on_socket_hover_changed", "socket_weapon_0", true)
	await _capture("module_dragging")
	view.call("_on_connection_drag_ended")
	view.request_module_connection("ship_design_module_0001", "socket_weapon_0")
	await get_tree().create_timer(0.48).timeout
	var glyph = (view.get("_socket_glyphs") as Dictionary).get("socket_weapon_0")
	_check(is_instance_valid(glyph) and float(glyph.get("_install_flash_remaining")) > 0.0, "installation packet reaches the target before only that socket performs its short soft flash")
	await _capture("connected_module")
	var module_node := view.get_node_or_null(NodePath("ship_design_module_0001")) as GraphNode
	var socket_node := view.get_node_or_null(NodePath("ship_design_socket_weapon_0")) as GraphNode
	if module_node != null and socket_node != null:
		var module_visual := module_node.find_child("ModuleNodeVisual", true, false) as Control
		var socket_center := socket_node.position_offset + socket_node.size * 0.5
		module_node.position_offset = Vector2(socket_center.x - module_node.size.x * 0.5, socket_node.position_offset.y - module_node.size.y - 84.0)
		view.call("_on_node_move_finished")
		var selected_route := view.call("_nearest_edge_connection_route", module_node, socket_node) as Dictionary
		var vertical_path := view.call("_world_path_for_link", (view.get("_links") as Array)[0]) as PackedVector2Array
		var source_normal := selected_route.get("source_normal", Vector2.RIGHT) as Vector2
		var expected_route_port := module_node.position_offset + module_visual.position + (module_visual.call("routing_port_local_for_normal", source_normal) as Vector2)
		_check(module_visual != null and vertical_path[0].is_equal_approx(expected_route_port), "an obstruction-aware route projects the inset module interface onto whichever of all four card edges the authoritative router selects")
		await _capture("vertical_connection")
	var links := view.get("_links") as Array
	if not links.is_empty():
		var path := view.call("_world_path_for_link", links[0]) as PackedVector2Array
		var selection_point := path[path.size() / 2] * view.zoom - view.scroll_offset
		view.call("_select_connection_at", selection_point)
	await _capture("selected_connection")
	_finish()


func _test_base_only_fallback() -> void:
	var base_only := ShipHullVisualScript.new()
	base_only.name = "BaseOnlyFallbackAudit"
	base_only.size = Vector2(240.0, 560.0)
	base_only.visible = false
	add_child(base_only)
	var loaded := base_only.configure({
		"topdown_texture":"res://assets/ships/lunar_pathfinder/base_4k.png",
		"fx_mask":"res://assets/ships/lunar_pathfinder/missing_fx_mask.png",
		"fx_profile":"base_only_test"
	}, {
		"profile":"p01",
		"length_m":132.0,
		"beam_m":44.0
	})
	var base_surface := base_only.find_child("ShipHullBaseFx", true, false) as ColorRect
	var material := base_surface.material as ShaderMaterial if base_surface != null else null
	_check(loaded and material != null and is_zero_approx(float(material.get_shader_parameter("has_fx_mask"))), "base texture without an FX mask retains the authored silhouette and restrained generic fallback")
	_check(base_only.mouse_filter == Control.MOUSE_FILTER_IGNORE and base_surface != null and base_surface.mouse_filter == Control.MOUSE_FILTER_IGNORE, "all authored and fallback hull visual surfaces ignore mouse input")
	base_only.queue_free()


func _capture_ambient_sequence(micro_lights: Control) -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_move_to_foreground()
	var starting_events := int(micro_lights.call("events_started"))
	for sample in 6:
		var elapsed_seconds := sample * 4
		await _capture("ambient_%02d" % elapsed_seconds)
		if elapsed_seconds < 20:
			await _wait_wall_clock_seconds(4.0)
	_check(int(micro_lights.call("events_started")) - starting_events >= 2, "20-second real-canvas audit contains multiple sparse, unsynchronized structural light events")


func _wait_wall_clock_seconds(duration: float) -> void:
	var deadline := Time.get_ticks_msec() + int(duration * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _catalog() -> Dictionary:
	var plan_id := "construct_lunar_pathfinder"
	var plan := (Game.content.ship_construction_projects[plan_id] as Dictionary).duplicate(true)
	plan["title"] = "Lunar Pathfinder"
	plan["assembly_sockets"] = Game.ship_design_socket_schema(plan_id)
	var hull_id := String(plan.get("ship_id", ""))
	var hull := (Game.content.ships[hull_id] as Dictionary).duplicate(true)
	var module := (Game.content.modules["light_autocannon"] as Dictionary).duplicate(true)
	module["title"] = "Light Autocannon"
	module["assembly_mount"] = Game.ship_module_mount_role("light_autocannon")
	return {
		"plans":{plan_id:plan},
		"hulls":{hull_id:hull},
		"modules":{"light_autocannon":module},
		"slot_labels":{},
		"socket_label_format":"%s %d",
		"module_label_format":"%s · %s",
		"hull_summary_format":"%s · %d sockets",
		"core_socket_format":"Energy Core %d"
	}


func _center_hull(hull: GraphNode, target_zoom: float) -> void:
	view.zoom = target_zoom
	view.scroll_offset = (hull.position_offset + hull.size * 0.5) * view.zoom - view.size * 0.5


func _capture(label: String) -> void:
	await _frames(2)
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		failures.append("%s screenshot viewport is available" % label)
		return
	var output := viewport_texture.get_image()
	if output == null:
		failures.append("%s screenshot image is available" % label)
		return
	_check(output.save_png("res://.audit-logs/ship_hull_visual_%s.png" % label) == OK, "%s audit screenshot saves" % label)


func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_HULL_VISUAL_TEST_PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
