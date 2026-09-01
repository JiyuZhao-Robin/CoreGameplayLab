extends Node

const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")

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
	_check(base_fx != null and base_fx.material is ShaderMaterial and ghost != null and ghost.material is ShaderMaterial, "base FX and technical ghost use shared CanvasItem shaders")
	_check((base_fx.material as ShaderMaterial).shader.code.find("TIME") >= 0 and (ghost.material as ShaderMaterial).shader.code.find("TIME") >= 0, "both restrained dynamic passes remain live after deployment")
	view.fit_design()
	await _capture("fit_all")
	_center_hull(hull, 0.92)
	await _capture("normal_zoom")
	_center_hull(hull, 1.36)
	await _capture("close_zoom")
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
	var glyph = (view.get("_socket_glyphs") as Dictionary).get("socket_weapon_0")
	_check(is_instance_valid(glyph) and float(glyph.get("_install_flash_remaining")) > 0.0, "successful install flashes only the target socket for a short interval")
	await _capture("connected_module")
	var links := view.get("_links") as Array
	if not links.is_empty():
		var path := view.call("_world_path_for_link", links[0]) as PackedVector2Array
		var selection_point := path[path.size() / 2] * view.zoom - view.scroll_offset
		view.call("_select_connection_at", selection_point)
	await _capture("selected_connection")
	_finish()


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
		"socket_label_format":"%s %d · %s",
		"module_label_format":"%s · %s · %s",
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
