extends Node

const DemoScene = preload("res://src/ui/demos/ship_art_deployment_demo.tscn")

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
	if canvas == null:
		_finish()
		return
	for ship_id in ["lunar_pathfinder"]:
		canvas.clear_draft(false)
		canvas.call("_reset_view")
		canvas.call("_drop_data", Vector2(620.0, 260.0), {
			"ship_assembly_palette":true,
			"kind":"hull",
			"plan_id":"demo_construct_%s" % ship_id,
			"definition_id":"demo_%s" % ship_id
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
		var hull_center_screen := (hull.position_offset + hull.size * 0.5) * canvas.zoom - canvas.scroll_offset
		_check(hull_center_screen.distance_to(canvas.size * 0.5) <= 2.0, "%s automatically focuses after a real drop" % ship_id)
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


func _finish() -> void:
	if failures.is_empty():
		print("SHIP_ART_DEPLOYMENT_DEMO_TEST_PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
