extends SceneTree

## Real deployment and road commands, then deterministic presentation clocks.
## Backpressure uses a full-buffer state fixture; it never changes product code.
const Art = preload("res://src/ui/workspaces/factory/factory_core_extractor_art.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const ItemArt = preload("res://src/ui/workspaces/location/location_item_icon.gd")
const Workspace = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const ViewModel = preload("res://src/ui/view_models/factory/factory_workspace_view_model.gd")
const WORLD := "earth-surface-grid"
var failures: Array[String] = []
var game: Node
var serial := 0
var workspace: Control
var canvas: Control
var miner_id := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	game.reset_game()
	if DisplayServer.get_name() == "headless":
		push_error("Run this rendered integration test with the normal Compatibility renderer")
		quit(1)
		return
	root.size = Vector2i(3840,2160)
	_test_asset_adapter()
	# Render the real player path with a cold working-frame cache as well.
	Art.clear_cache()
	_command("DEPLOY_BUILDING", {"definition_id":"grid_planetary_core", "origin":{"x":110,"y":32}})
	_command("DEPLOY_BUILDING", {"definition_id":"grid_surface_mine", "origin":{"x":42,"y":42}})
	_command("DEPLOY_BUILDING", {"definition_id":"grid_surface_mine", "origin":{"x":82,"y":42}})
	_command("DEPLOY_BUILDING", {"definition_id":"grid_surface_mine", "origin":{"x":30,"y":45}})
	var initial: Dictionary = game.factory_workspace_snapshot(WORLD)
	for entity in initial.entities:
		if entity.definition_id == "grid_surface_mine" and int(entity.footprint.origin.x) == 42:
			miner_id = entity.id
	_check(not miner_id.is_empty(), "real finished-building deployment creates the selected mining family")
	_check(initial.construction_orders.size() == 1, "the third miner remains a missing-building ghost")
	var host := Control.new()
	host.size = Vector2(1920,1080)
	root.add_child(host)
	workspace = Workspace.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.apply_snapshot(initial)
	workspace.call("_set_active_subworkspace", "CANVAS")
	canvas = workspace.canvas()
	canvas.set_process(false)
	await _settle()
	canvas.set("_zoom",2.5)
	canvas.focus_tile(Vector2i(55,45))
	await _settle()
	var card := workspace.find_child("FactoryBuildCardGridSurfaceMine",true,false) as Button
	var card_icon := card.find_child("FactoryBuildCardIcon",true,false) as TextureRect if card != null else null
	_check(card_icon != null and card_icon.texture == Art.icon_texture(), "real construction palette shows the selected Core Extractor icon")
	_check(str(_entity().status) == "NO_POWER", "deployed miner is stopped until a built road supplies power")
	var tiles: Array = []
	for y in range(53,61):
		tiles.append({"x":42,"y":y})
	for x in range(43,110):
		tiles.append({"x":x,"y":60})
	for y in range(32,60):
		tiles.append({"x":109,"y":y})
	canvas.set("_runtime_snapshot_age",5.0)
	_command("BUILD_ROAD",{"tiles":tiles,"tier":1})
	await _apply()
	_check(_entity().status in ["RUNNING","PARTIAL_COVERAGE","POWER_LIMITED"] and float(_entity().actual_rate) > 0.0, "road command supplies authoritative running status and rate")
	_check(float(canvas.get("_runtime_snapshot_age")) < 0.1, "same-elapsed topology changes refresh a previously stale canvas")
	var economy_before: Dictionary = game.state.to_dictionary()
	var first := await _miner_pixels("01-running-frame-a")
	canvas.call("_advance_core_extractors",1.1)
	var second := await _miner_pixels("02-running-frame-b")
	_check(_frame() == 33, "visible working miner advances at the original 30 fps")
	_check(_pixels_differ(first,second), "real canvas renders different working frames")
	_check(game.state.to_dictionary() == economy_before, "presentation animation never advances economy or modifies a snapshot's owner")
	canvas.set_reduced_motion(true)
	canvas.call("_advance_core_extractors",0.5)
	_check(_frame() == 33, "Reduced Motion freezes the current mechanical pose")
	canvas.set_reduced_motion(false)
	var clocks_before_reset: Dictionary = canvas.get("_miner_animation_seconds").duplicate(true)
	canvas.set("_overview_mode",true)
	canvas.call("_advance_core_extractors",0.5)
	_check(_frame() == 48, "bounded local reset view keeps visible working miners animated")
	canvas.set("_miner_animation_seconds", clocks_before_reset)
	canvas.set("_overview_mode",false)
	canvas.set("_runtime_snapshot_age",5.0)
	canvas.call("_advance_core_extractors",0.5)
	_check(_frame() == 33, "stale snapshots cannot keep mechanical animation running indefinitely")
	_command("REMOVE_ROAD",{"tiles":[{"x":70,"y":60}]})
	await _apply()
	_check(_entity().status == "NO_POWER" and not canvas.call("_core_extractor_working",_entity()), "cut road stops mining and turns off the working light")
	var stopped := await _miner_pixels("03-no-power")
	canvas.call("_advance_core_extractors",0.8)
	var stopped_later := await _miner_pixels("")
	_check(_frame() == 33 and not _pixels_differ(stopped,stopped_later), "no-power miner retains its pose and exact rendered pixels")
	_check(_pixels_differ(second,stopped), "working emission disappears when power is lost at the same mechanical frame")
	canvas.set("_runtime_snapshot_age",5.0)
	_command("BUILD_ROAD",{"tiles":[{"x":70,"y":60}],"tier":1})
	await _apply()
	canvas.call("_advance_core_extractors",0.5)
	_check(_frame() == 48, "reconnecting the road resumes from the stopped pose without changing simulation time")
	var world: Dictionary = game.state.factory_worlds[WORLD]
	world.entities[miner_id].outputs = {"iron_ore":48}
	game.simulation.refresh_factory_runtime_views(game.state)
	await _apply()
	_check(_entity().status == "OUTPUT_FULL" and float(_entity().power_factor) > 0.0, "full-output fixture is stopped despite having power")
	var full := await _miner_pixels("04-output-full")
	canvas.call("_advance_core_extractors",0.6)
	_check(_frame() == 48 and not canvas.call("_core_extractor_working",_entity()), "backpressure freezes animation and disables working light")
	_check(not _pixels_differ(full,await _miner_pixels("")), "full-output pixels remain stable")
	for status in ["NO_RESOURCE","NO_POWER","OUTPUT_FULL","UNKNOWN"]:
		_check(not canvas.call("_core_extractor_working",{"status":status,"actual_rate":1.0}), "non-working state rejects animation even with inconsistent rate: " + status)
	for status in ["RUNNING","POWER_LIMITED","PARTIAL_COVERAGE"]:
		_check(canvas.call("_core_extractor_working",{"status":status,"actual_rate":0.5}), "producing state is eligible: " + status)
	_check(not canvas.call("_core_extractor_working",{"status":"RUNNING","actual_rate":0.0}), "zero actual rate cannot animate")
	var footprint: Rect2 = canvas.call("_footprint_rect",_entity().footprint)
	_check(footprint.size.is_equal_approx(Vector2.ONE * 11.0 * float(canvas.call("_tile_scale"))), "Core Extractor uses the approved 11 x 11 physical footprint")
	var geometry: Dictionary = canvas.call("_mining_range_geometry",_entity())
	_check(not geometry.is_empty() and is_equal_approx(float(geometry.get("radius",0.0)),18.0*float(canvas.call("_tile_scale"))), "selected machine shows the authoritative 18-tile circular reach")
	await RenderingServer.frame_post_draw
	var unselected_image := root.get_texture().get_image()
	canvas.call("_select_at",footprint.get_center())
	await _settle()
	await RenderingServer.frame_post_draw
	var selected_image := root.get_texture().get_image()
	var circle_point: Vector2 = canvas.get_global_transform_with_canvas() * (Vector2(geometry.center) + Vector2(float(geometry.radius),0))
	var circle_probe := Rect2i(Vector2i(circle_point*2.0)-Vector2i(3,3),Vector2i(7,7))
	_check(canvas.selected_node_id() == miner_id and _pixels_differ(unselected_image.get_region(circle_probe),selected_image.get_region(circle_probe)),"real canvas selection visibly draws the circular reach outside physical occupancy")
	var view_model := ViewModel.new()
	var building: Dictionary = game.content.factory_buildings["grid_surface_mine"]
	var preview := view_model.placement_preview(game.factory_workspace_snapshot(WORLD),building,Vector2i(30,45))
	_check(preview.mining_radius_tiles == 18.0 and preview.footprint.size == {"x":11,"y":11}, "validity-independent placement record carries physical footprint and circular radius separately")
	var other: Dictionary = game.factory_workspace_snapshot(WORLD).duplicate(true)
	other.world_id = "another-world-with-same-entity-id"
	canvas.set("_runtime_snapshot_age",5.0)
	canvas.apply_snapshot(other)
	_check(float(canvas.get("_runtime_snapshot_age")) == 0.0 and (canvas.get("_miner_animation_seconds") as Dictionary).is_empty(), "world switch clears prior entity clocks and stale age even at matching revisions")
	host.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("FACTORY_CORE_EXTRACTOR_PASS" if failures.is_empty() else "FACTORY_CORE_EXTRACTOR_FAIL")
	quit(0 if failures.is_empty() else 1)


func _test_asset_adapter() -> void:
	Art.clear_cache()
	_check(Art.is_available() and Art.cache_stats().textures == 0, "manifest availability does not eagerly decode the source sheets")
	var icon := Art.icon_texture()
	_check(icon != null and icon == Art.icon_texture() and Art.cache_stats().textures == 1, "palette icons reuse one cached 256px body frame")
	for id in BuildingArt.CORE_EXTRACTOR_IDS:
		_check(BuildingArt.icon_texture(null,id,"EXTRACTOR") == icon and ItemArt.texture_for_item("building_" + id) == icon, "building and finished-item art agree: " + id)
	for id in ["grid_planetary_core","grid_dsp_oil_extractor","grid_dsp_water_pump","grid_dsp_orbital_collector"]:
		_check(not BuildingArt.uses_core_extractor(id), "separate facility retains its art: " + id)
	var rect := Rect2(10,20,52,52)
	var shadow := Art.shadow_rect(rect)
	_check(shadow.get_center().is_equal_approx(rect.get_center()) and is_equal_approx(shadow.size.x/rect.size.x,1400.0/704.0), "independently resized shadow retains original center and spatial ratio")
	_check(Art.frame_index(4.0) == 0 and Art.frame_index(119.0/30.0) == 119 and Art.frame_index(64.0/30.0) == 64, "animation reaches both source sheets and wraps after 120 frames")
	for i in range(360):
		_check(Art.frame_texture("working",i) == Art.frame_texture("working",i%120), "animation loop shares frame " + str(i))
	_check(Art.cache_stats().textures == 121 and Art.frame_texture("unknown",0) == null and Art.errors().is_empty(), "three animation loops are bounded to 120 working textures plus one icon")
	_check(Art.frame_texture("working",64).get_image().has_mipmaps(), "independent frames have mipmaps without sampling adjacent source frames")


func _command(kind: String, payload: Dictionary) -> void:
	serial += 1
	var world: Dictionary = game.state.factory_worlds[WORLD]
	var response: Dictionary = game.execute_factory_command({"protocol_version":1,"command_id":"core-art-%d" % serial,"kind":kind,"world_id":WORLD,"base_topology_revision":int(world.topology_revision),"payload":payload})
	_check(bool(response.get("accepted",false)), "real command accepted: " + kind + " " + str(response.get("reason_code","")))


func _apply() -> void:
	workspace.apply_snapshot(game.factory_workspace_snapshot(WORLD))
	await _settle()


func _entity() -> Dictionary:
	for entity in game.factory_workspace_snapshot(WORLD).entities:
		if entity.id == miner_id:
			return entity
	return {}


func _frame() -> int:
	return Art.frame_index(float((canvas.get("_miner_animation_seconds") as Dictionary).get(miner_id,0.0)))


func _miner_pixels(label: String) -> Image:
	canvas.queue_redraw()
	await _settle()
	if DisplayServer.get_name() == "headless":
		return null
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if not label.is_empty():
		var path := ProjectSettings.globalize_path("res://artifacts/ui/core-extractor-factory/" + label + ".png")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_check(picture.save_png(path) == OK,"4K capture saved: " + label)
	var footprint: Rect2 = canvas.call("_footprint_rect",_entity().footprint)
	var rect: Rect2 = canvas.call("_entity_visible_icon_rect",footprint,"FULL")
	var screen := canvas.get_global_transform_with_canvas() * rect
	return picture.get_region(Rect2i(screen.position*2.0,screen.size*2.0))


func _pixels_differ(a: Image, b: Image) -> bool:
	if a == null or b == null:
		return false
	var changed := 0
	for y in range(a.get_height()):
		for x in range(a.get_width()):
			var left := a.get_pixel(x,y)
			var right := b.get_pixel(x,y)
			if maxf(absf(left.r-right.r),maxf(absf(left.g-right.g),absf(left.b-right.b))) > 2.0/255.0:
				changed += 1
	return float(changed) / float(a.get_width()*a.get_height()) > 0.005


func _settle() -> void:
	for i in range(4):
		await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
