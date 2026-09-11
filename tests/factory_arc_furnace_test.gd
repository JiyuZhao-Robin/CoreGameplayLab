extends SceneTree

const Art = preload("res://src/ui/workspaces/factory/factory_arc_furnace_art.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const ItemArt = preload("res://src/ui/workspaces/location/location_item_icon.gd")
const Workspace = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const WORLD := "earth-surface-grid"
var failures: Array[String] = []
var game: Node
var serial := 0
var canvas: Control
var running_id := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	game.reset_game()
	root.get_node("I18n").set_locale("zh_CN")
	root.size = Vector2i(3840,2160)
	_command("DEPLOY_BUILDING", {"definition_id":"grid_planetary_core", "origin":{"x":110,"y":32}})
	for x in [8,28,48]:
		_command("DEPLOY_BUILDING", {"definition_id":"grid_arc_smelter", "origin":{"x":x,"y":61}, "recipe_id":"grid_refine_iron"})
	var snapshot: Dictionary = game.factory_workspace_snapshot(WORLD).duplicate(true)
	# Controlled presentation states on a real deployment snapshot; no simulated
	# production is invented in the authoritative Game state.
	for entity in snapshot.entities:
		if entity.definition_id == "grid_arc_smelter":
			_check(entity.footprint.size == {"x":16,"y":12}, "existing production footprint stays 16x12")
			if entity.footprint.origin.x == 8:
				running_id = entity.id
				entity.status = "RUNNING"
				entity.actual_rate = 1.0
			else:
				entity.status = "NO_POWER"
				entity.actual_rate = 0.0
	_check(not running_id.is_empty() and snapshot.construction_orders.size() == 1, "real deployment yields two furnaces and one missing-kit ghost")
	var original_state := JSON.stringify(game.state.to_dictionary())
	var original_snapshot := JSON.stringify(snapshot)
	var host := Control.new()
	host.size = Vector2(1920,1080)
	root.add_child(host)
	var workspace := Workspace.new()
	host.add_child(workspace)
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	workspace.apply_snapshot(snapshot)
	workspace.call("_set_active_subworkspace", "CANVAS")
	canvas = workspace.canvas()
	canvas.set_process(false)
	await _settle()
	canvas.focus_tile(Vector2i(33,65))
	canvas.clear_placement_preview()
	await _settle()
	_check(JSON.stringify(snapshot) == original_snapshot, "workspace preserves the supplied presentation snapshot")
	_check(Art.is_available() and Art.errors().is_empty(), "production pack loads")
	for definition_id in ["grid_arc_smelter","grid_dsp_arc_smelter"]:
		_check(BuildingArt.icon_texture(BuildingArt.atlas_texture(),definition_id,"MACHINE") == Art.icon_texture(), "approved furnace mapping: " + definition_id)
		_check(ItemArt.texture_for_item("building_" + definition_id) == Art.icon_texture(), "finished building item uses approved art: " + definition_id)
	_check(not BuildingArt.uses_arc_furnace("grid_dsp_plane_smelter") and not BuildingArt.uses_arc_furnace("grid_engineering_works"), "unconfirmed building families retain their own art")
	var card := workspace.find_child("FactoryBuildCardGridArcSmelter",true,false)
	var icon := card.find_child("FactoryBuildCardIcon",true,false) as TextureRect if card != null else null
	_check(icon != null and icon.texture == Art.icon_texture(), "build palette uses approved furnace")
	_check(canvas.get("_visible_arc_furnaces").has(running_id), "visible furnace enters bounded animation set")
	var before := await _capture("01-working-start")
	canvas.call("_advance_arc_furnaces", 0.5)
	var after := await _capture("02-working-frame")
	_check(_frame() == 15, "working furnace uses 50-frame 30fps clock")
	_check(before.get_data() != after.get_data(), "actual furnace canvas pixels animate")
	canvas.set_reduced_motion(true)
	canvas.call("_advance_arc_furnaces", 0.5)
	_check(_frame() == 15, "reduced motion freezes current pose")
	canvas.set_reduced_motion(false)
	canvas.set("_runtime_snapshot_age", 5.0)
	canvas.call("_advance_arc_furnaces", 0.5)
	_check(_frame() == 15, "stale production snapshot cannot animate indefinitely")
	for entity in snapshot.entities:
		if entity.id == running_id:
			entity.status = "NO_POWER"
			entity.actual_rate = 0.0
	snapshot.runtime_revision = int(snapshot.runtime_revision) + 1
	workspace.apply_snapshot(snapshot)
	canvas.set_process(false)
	var stopped := await _capture("03-stopped")
	canvas.call("_advance_arc_furnaces", 0.5)
	var stopped_later := await _capture("")
	_check(_frame() == 15 and stopped.get_data() == stopped_later.get_data(), "no-power pose stays fixed with no fake production pulse")
	_check(stopped.get_data() != after.get_data(), "working light switches off when power is lost")
	workspace.call("_select_building_id", "grid_arc_smelter")
	workspace.set("_preview_tile", Vector2i(28,80))
	workspace.call("_update_placement_preview")
	await _capture("04-placement")
	_check(JSON.stringify(game.state.to_dictionary()) == original_state, "rendering and preview never alter economy")
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_ARC_FURNACE_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _frame() -> int:
	return Art.frame_index(float(canvas.get("_furnace_animation_seconds").get(running_id, 0.0)))

func _capture(label: String) -> Image:
	canvas.queue_redraw()
	await _settle()
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if not label.is_empty():
		var path := ProjectSettings.globalize_path("res://artifacts/ui/arc-furnace-factory/" + label + ".png")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_check(picture.save_png(path) == OK, "real 4K capture: " + label)
		var preview := picture.duplicate() as Image
		preview.resize(1920,1080,Image.INTERPOLATE_LANCZOS)
		_check(preview.save_jpg(path.trim_suffix(".png") + ".jpg",0.92) == OK, "review preview: " + label)
	return picture

func _settle() -> void:
	for index in 4:
		await process_frame

func _command(kind: String, payload: Dictionary) -> void:
	serial += 1
	var result: Dictionary = game.execute_factory_command({"protocol_version":1,"command_id":"arc-furnace-%d" % serial,"kind":kind,"world_id":WORLD,"base_topology_revision":int(game.state.factory_worlds[WORLD].topology_revision),"payload":payload})
	_check(result.get("accepted",false), "deployment command accepted: " + str(result))

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
