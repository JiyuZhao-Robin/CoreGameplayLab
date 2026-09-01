extends Node

const DemoScene = preload("res://src/ui/demos/ship_art_deployment_demo.tscn")
const ShipPortGlyphScript = preload("res://src/ui/components/ship_port_glyph.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	get_window().size = Vector2i(1600, 1000)
	var demo := DemoScene.instantiate()
	add_child(demo)
	for _frame in 4:
		await get_tree().process_frame
	var canvas := demo.find_child("ShipAssemblyMap", true, false) as GraphEdit
	_check(canvas != null, "demo exposes the real ship assembly deployment canvas")
	_check(demo.find_child("DemoAssemblyPalette", true, false) is TabContainer, "demo exposes separate Ship and Parts drag palettes")
	_check(demo.find_child("DemoPortLegend", true, false) is Control, "demo explains the meaning of each shaped socket")
	for module_id in ["light_autocannon", "civilian_shield", "advanced_drive", "sensor_array", "cargo_expansion", "civilian_reactor_core"]:
		_check(demo.find_child("DemoPartCard_%s" % module_id, true, false) is Button, "%s is exposed as a draggable demo part" % module_id)
	if canvas == null:
		_finish()
		return
	for ship_id in ["lunar_pathfinder"]:
		canvas.clear_draft(false)
		canvas.call("_reset_view")
		canvas.call("_drop_data", Vector2(620.0, 260.0), {
			"ship_assembly_palette":true,
			"kind":"hull",
			"plan_id":"construct_%s" % ship_id,
			"definition_id":ship_id
		})
		for _frame in 3:
			await get_tree().process_frame
		var hull := canvas.get_node_or_null(NodePath("ship_design_hull")) as GraphNode
		_check(hull != null, "%s deploys through ShipAssemblyMapView" % ship_id)
		if hull == null:
			continue
		var backplane := hull.find_child("ShipHullProjection", true, false) as Control
		var art := hull.find_child("ShipHullVisual", true, false) as Control
		_check(backplane != null and bool(backplane.call("has_visual_asset")), "%s keeps ShipHullBackplane as the visual host" % ship_id)
		_check(art != null and bool(art.call("asset_loaded")), "%s renders the registered transparent hull texture and mask" % ship_id)
		_check(_tree_ignores_mouse(art), "%s visual layer and all of its children ignore mouse input" % ship_id)
		_check(hull.title.is_empty() and hull.get_theme_stylebox("panel") is StyleBoxEmpty, "%s drops without a card frame or title" % ship_id)
		var expected_shapes := {
			"socket_weapon_0":"TRIANGLE",
			"socket_shield_0":"SQUARE",
			"socket_drive_0":"DIAMOND",
			"socket_utility_0":"PENTAGON",
			"socket_utility_1":"SQUARE",
			"socket_core_0":"CIRCLE"
		}
		for socket_id_value in expected_shapes.keys():
			var socket_id := String(socket_id_value)
			var socket := canvas.get_node_or_null(NodePath("ship_design_%s" % socket_id)) as GraphNode
			_check(socket != null, "%s exposes %s on its physical hull layout" % [ship_id, socket_id])
			if socket != null:
				var glyph := _find_ship_port_glyph(socket)
				_check(glyph != null and String(glyph.get("shape")) == String(expected_shapes[socket_id]), "%s uses its documented connector shape" % socket_id)
		var hull_center_screen := (hull.position_offset + hull.size * 0.5) * canvas.zoom - canvas.scroll_offset
		_check(hull_center_screen.distance_to(canvas.size * 0.5) <= 2.0, "%s automatically focuses after a real drop" % ship_id)
		var fittings := [
			["light_autocannon", "socket_weapon_0"],
			["civilian_shield", "socket_shield_0"],
			["advanced_drive", "socket_drive_0"],
			["sensor_array", "socket_utility_0"],
			["cargo_expansion", "socket_utility_1"],
			["civilian_reactor_core", "socket_core_0"]
		]
		for fitting_index in fittings.size():
			var fitting: Array = fittings[fitting_index]
			var drop_x := 70.0 if fitting_index % 2 == 0 else maxf(430.0, canvas.size.x - 330.0)
			canvas.call("_drop_data", Vector2(drop_x, 60.0 + float(fitting_index / 2) * 165.0), {
				"ship_assembly_palette":true,
				"kind":"module",
				"definition_id":String(fitting[0])
			})
			canvas.call("request_module_connection", "ship_design_module_%04d" % (fitting_index + 1), String(fitting[1]))
		var snapshot := canvas.call("draft_snapshot") as Dictionary
		_check((snapshot.get("nodes", []) as Array).size() == 7, "%s demo supports dragging six parts beside the hull" % ship_id)
		_check((snapshot.get("connections", []) as Array).size() == 6, "%s demo connects every part to its matching shaped socket" % ship_id)
		var representative_module := canvas.get_node_or_null(NodePath("ship_design_module_0001")) as GraphNode
		_check(representative_module != null and representative_module.custom_minimum_size.y >= 138.0 and representative_module.find_child("ModuleThumbnail", true, false) != null, "%s demo uses the taller integrated module card with a thumbnail bay" % ship_id)
		canvas.call("fit_design")
		for _frame in 3:
			await get_tree().process_frame
		var texture := load("res://assets/ships/lunar_pathfinder/base.png") as Texture2D
		var mask := load("res://assets/ships/lunar_pathfinder/fx_mask.png") as Texture2D
		if texture != null and mask != null:
			var image := texture.get_image()
			_check(image != null and image.get_pixel(0, 0).a <= 0.02 and maxi(image.get_width(), image.get_height()) == 2048, "%s is a tightly cropped 2K alpha silhouette" % ship_id)
			if image != null:
				var used := image.get_used_rect()
				var maximum_margin := maxi(used.position.x, maxi(used.position.y, maxi(image.get_width() - used.end.x, image.get_height() - used.end.y)))
				_check(maximum_margin <= 8, "%s alpha content stays within eight pixels of its trimmed texture edge" % ship_id)
			_check(mask.get_size() == texture.get_size(), "%s FX mask is tightly registered to the base texture" % ship_id)
		var viewport_texture := get_viewport().get_texture()
		if DisplayServer.get_name() != "headless" and viewport_texture != null:
			var output := viewport_texture.get_image()
			if output != null:
				var output_path := "res://.audit-logs/ship_art_demo_%s.png" % ship_id
				_check(output.save_png(output_path) == OK, "%s audit screenshot saves" % ship_id)
	demo.queue_free()
	await get_tree().process_frame
	_finish()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _tree_ignores_mouse(root: Control) -> bool:
	if root == null or root.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return false
	for child in root.get_children():
		if child is Control and not _tree_ignores_mouse(child as Control):
			return false
	return true


func _find_ship_port_glyph(root: Node) -> Node:
	for child in root.get_children():
		if child.get_script() == ShipPortGlyphScript:
			return child
		var nested := _find_ship_port_glyph(child)
		if nested != null:
			return nested
	return null


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_ART_DEPLOYMENT_DEMO_TEST_PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
