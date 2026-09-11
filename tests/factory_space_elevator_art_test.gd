extends SceneTree

## Uses the shipped render frames and the real Factory canvas; the fixture is
## detached from Game state. Run with a renderer for animation screenshots.
const Art = preload("res://src/ui/workspaces/factory/factory_space_elevator_art.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var before := JSON.stringify(game.state.to_dictionary())
	_check(Art.is_available(), "project-local elevator pack is complete: " + str(Art.errors()))
	if not Art.is_available():
		_finish()
		return
	_test_frames()
	_test_geometry()
	var core := {"id":"core", "definition_id":"grid_planetary_core", "node_kind":"POWER", "status":"RUNNING", "footprint":{"origin":{"x":100,"y":100},"size":{"x":12,"y":12}}}
	var snapshot := {"protocol_version":1,"valid":true,"world_id":"elevator-art-fixture","topology_revision":1,"runtime_revision":1,"elapsed_ms":1000,"chunk_size_tiles":8,"bounds":{"origin":{"x":0,"y":0},"size":{"x":256,"y":256}},"entities":[core],"construction_orders":[],"resource_fields":[],"links":[],"palette":{"buildings":[],"recipes":[]}}
	var supplied := JSON.stringify(snapshot)
	var canvas := CanvasScript.new()
	canvas.size = Vector2(1920,1080)
	root.add_child(canvas)
	canvas.set_process(false)
	canvas.set_drone_logistics_mode(true)
	canvas.apply_snapshot(snapshot)
	canvas.set("_zoom", 2.0)
	canvas.focus_tile(Vector2i(106,100))
	await _settle()
	var ground: Rect2 = canvas.call("_footprint_rect", core.footprint)
	var body := Art.body_rect(ground)
	_check(canvas.call("_building_art_rect", "grid_planetary_core", Art.icon_texture(), ground, "COMPACT") == body, "all detail levels retain authored ground anchor")
	var top_point := Vector2(body.get_center().x, lerpf(body.position.y, ground.position.y, 0.5))
	_check(str((canvas.call("_visible_entity_icon_at", top_point) as Dictionary).get("id", "")) == "core", "tower above the footprint can be selected")
	var visible := ["core"] as Array[String]
	canvas.set("_visible_space_elevators", visible)
	canvas.set("_runtime_snapshot_age", 0.0)
	canvas.call("_advance_space_elevators", Art.cycle_seconds() * 0.25)
	var clocks: Dictionary = canvas.get("_elevator_animation_seconds").duplicate(true)
	_check(Art.frame_index(float(clocks.get("core", 0.0))) > 0, "visible deployed core advances real baked frames")
	canvas.set_reduced_motion(true)
	canvas.call("_advance_space_elevators", 0.5)
	_check(canvas.get("_elevator_animation_seconds") == clocks, "reduced motion freezes mechanical animation")
	canvas.set_reduced_motion(false)
	canvas.set("_runtime_snapshot_age", 5.0)
	canvas.call("_advance_space_elevators", 0.5)
	_check(canvas.get("_elevator_animation_seconds") == clocks, "stale simulation snapshots freeze animation")
	canvas.set("_runtime_snapshot_age", 0.0)
	canvas.set("_visible_space_elevators", [] as Array[String])
	canvas.call("_advance_space_elevators", 0.5)
	_check(canvas.get("_elevator_animation_seconds") == clocks, "offscreen cores consume no animation work")
	# Place the base below the actual viewport while retaining the upper tower.
	var shift := Vector2(0, canvas.size.y + 60.0 - ground.position.y)
	canvas.set("_camera", (canvas.get("_camera") as Vector2) + shift)
	canvas.set("_visible_records", {})
	var moved_ground: Rect2 = canvas.call("_footprint_rect", core.footprint)
	var viewport: Rect2 = canvas.call("_visible_draw_rect")
	_check(not moved_ground.intersects(viewport), "culling fixture puts the base below the viewport")
	if Art.body_rect(moved_ground).intersects(viewport):
		var records: Dictionary = canvas.call("_query_visible_records")
		_check(records.entity_ids.has("core"), "tall silhouette survives ground-chunk culling")
	else:
		_check(false, "authored tower extends far enough above its base for visibility regression")
	canvas.focus_tile(Vector2i(106,100))
	canvas.set("_elevator_animation_seconds", {})
	await _capture(canvas, "01-original-frame")
	canvas.set("_elevator_animation_seconds", {"core":Art.cycle_seconds() * 0.25})
	await _capture(canvas, "02-mechanical-frame")
	var ghost := snapshot.duplicate(true)
	ghost.entities = []
	ghost.construction_orders = [{"id":"ghost-core","definition_id":"grid_planetary_core","footprint":core.footprint.duplicate(true),"status":"WAITING_BUILDING"}]
	ghost.topology_revision = 2
	canvas.apply_snapshot(ghost)
	await _settle()
	_check((canvas.get("_elevator_animation_seconds") as Dictionary).is_empty(), "replaced or removed core clocks are discarded")
	_check((canvas.get("_visible_space_elevators") as Array).is_empty(), "construction ghost never enters deployed animation set")
	await _capture(canvas, "03-static-ghost")
	_check(JSON.stringify(snapshot) == supplied and JSON.stringify(game.state.to_dictionary()) == before, "art and animation leave supplied data and player state unchanged")
	_check(Art.errors().is_empty(), "all used textures resolve without errors")
	canvas.queue_free()
	await process_frame
	_finish()


func _test_frames() -> void:
	var first := Art.frame_texture(0)
	_check(first != null, "frame zero loads")
	if first == null:
		return
	var dimensions := first.get_size()
	var shadow := Art.shadow_texture()
	_check(shadow != null, "baked ground-contact shadow loads")
	if shadow != null:
		_check(shadow.get_size() == dimensions, "contact shadow shares the frame camera rectangle")
		_check(Art.shadow_texture() == shadow, "shadow texture is shared across frames")
	var unique: Dictionary = {}
	for index in Art.frame_count():
		var texture := Art.frame_texture(index)
		_check(texture != null, "frame %d loads" % index)
		if texture == null:
			continue
		_check(texture.get_size() == dimensions, "frame %d preserves canvas geometry" % index)
		var image := texture.get_image()
		_check(image != null, "frame %d has image data" % index)
		if image != null:
			var hash_context := HashingContext.new()
			hash_context.start(HashingContext.HASH_SHA256)
			hash_context.update(image.get_data())
			unique[hash_context.finish().hex_encode()] = true
	_check(unique.size() > 1, "baked mechanical animation contains different pixels")
	_check(BuildingArt.icon_texture(null, "grid_planetary_core", "POWER") == Art.icon_texture(), "core palette and inspector use original-model icon")
	_check(Art.icon_texture().atlas == first, "icon is the static first frame")
	_check(Art.frame_index(Art.cycle_seconds()) == 0, "animation wraps to frame zero")
	_check(Art.frame_index(INF) == 0, "invalid animation time has safe frame")


func _test_geometry() -> void:
	var footprint := Rect2(100,200,120,120)
	var rect := Art.body_rect(footprint)
	_check(rect.has_area() and rect.position.y < footprint.position.y, "tower silhouette extends above its unchanged ground footprint")
	for factor in [0.5,1.0,2.0]:
		var scaled := Art.body_rect(Rect2(footprint.position * factor, footprint.size * factor))
		_check(scaled.position.is_equal_approx(rect.position * factor) and scaled.size.is_equal_approx(rect.size * factor), "tower scales uniformly around its footprint")


func _settle() -> void:
	for index in 3:
		await process_frame


func _capture(canvas: Control, label: String) -> void:
	if DisplayServer.get_name() == "headless" or not OS.get_cmdline_user_args().has("--capture-elevator"):
		return
	root.size = Vector2i(3840,2160)
	canvas.queue_redraw()
	await _settle()
	await RenderingServer.frame_post_draw
	var directory := "res://artifacts/ui/space-elevator"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var image := root.get_texture().get_image()
	_check(image.save_png(directory + "/" + label + ".png") == OK, "4K capture saved: " + label)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_SPACE_ELEVATOR_ART_PASS")
	quit(0 if failures.is_empty() else 1)
