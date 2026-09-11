extends SceneTree

## Actual Compatibility-renderer coverage. The three machine rates below are
## presentation fixtures; thermal power comes from an isolated real coal/road
## simulation. Neither fixture is installed into the player's Game state.
const Art = preload("res://src/ui/workspaces/factory/factory_approved_industry_art.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const ItemArt = preload("res://src/ui/workspaces/location/location_item_icon.gd")
const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const MAPPINGS := {
	"grid_engineering_works":"manufacturer",
	"grid_dsp_assembling_machine_mk1":"manufacturer",
	"grid_dsp_assembling_machine_mk2":"manufacturer",
	"grid_dsp_assembling_machine_mk3":"manufacturer",
	"grid_dsp_oil_refinery":"fuel-refinery",
	"grid_dsp_chemical_plant":"chemical-stager",
	"grid_dsp_quantum_chemical_plant":"chemical-stager",
	"grid_dsp_thermal_power_plant":"thermal-plant",
}
const REPRESENTATIVES := ["grid_engineering_works", "grid_dsp_oil_refinery", "grid_dsp_chemical_plant", "grid_dsp_thermal_power_plant"]
var failures: Array[String] = []
var canvas: Control
var grid: FactoryGridSimulation
var world: Dictionary
var database: ContentDatabase

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game := root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var original_state := JSON.stringify(game.state.to_dictionary())
	root.get_node("I18n").set_locale("zh_CN")
	root.size = Vector2i(3840,2160)
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "current merged catalog loads")
	_test_mapping_and_geometry()
	_create_world()
	var snapshot := _presentation_snapshot()
	var thermal := _entity(snapshot, "thermal-plant")
	_check(thermal.status == "RUNNING" and float(thermal.generation_kw) > 0.0 and float(thermal.actual_rate) == 0.0, "real coal generator supplies road power while recipe actual_rate stays zero")
	var supplied_snapshot := JSON.stringify(snapshot)
	var authoritative_world := JSON.stringify(world)
	var host := Control.new()
	host.size = Vector2(1920,1080)
	root.add_child(host)
	canvas = CanvasScript.new()
	canvas.size = host.size
	host.add_child(canvas)
	canvas.set_road_logistics_mode(true)
	canvas.set_process(false)
	canvas.apply_snapshot(snapshot)
	canvas.set("_zoom", 4.0)
	canvas.focus_tile(Vector2i(58,43))
	var working_start := await _capture("01-working-start")
	_check(working_start.get_size() == Vector2i(3840,2160), "captures use the actual 4K production render target")
	for family in Art.FAMILIES:
		_check(canvas.get("_visible_industry_buildings").has(family), "visible animation membership: " + family)
	canvas.call("_advance_industry_buildings", 0.5)
	var working := await _capture("02-working-frame")
	for family in Art.FAMILIES:
		_check(_frame(family) == 15, "30fps clock advances visible production: " + family)
		_check(_crop(working_start, _art_rect(snapshot,family)).get_data() != _crop(working, _art_rect(snapshot,family)).get_data(), "actual building pixels animate: " + family)
	var clocks: Dictionary = canvas.get("_industry_animation_seconds").duplicate(true)
	canvas.set_reduced_motion(true)
	canvas.call("_advance_industry_buildings", 0.5)
	_check(canvas.get("_industry_animation_seconds") == clocks, "reduced motion freezes every approved family")
	canvas.set_reduced_motion(false)
	canvas.set("_runtime_snapshot_age", 5.0)
	canvas.call("_advance_industry_buildings", 0.5)
	_check(canvas.get("_industry_animation_seconds") == clocks, "stale runtime snapshots cannot drive animation")
	canvas.set("_runtime_snapshot_age", 0.0)
	canvas.focus_tile(Vector2i(230,130))
	await _capture("")
	_check(canvas.get("_visible_industry_buildings").is_empty(), "offscreen buildings leave the bounded animation set")
	canvas.call("_advance_industry_buildings", 0.5)
	_check(canvas.get("_industry_animation_seconds") == clocks, "offscreen buildings consume no animation clock work")
	canvas.focus_tile(Vector2i(58,43))
	_check(JSON.stringify(world) == authoritative_world and JSON.stringify(snapshot) == supplied_snapshot, "rendering preserves the isolated simulation and supplied snapshot")

	# This step actually exhausts the coal; no synthetic generator rate/status.
	grid.advance_world(world, 10000.0)
	var stopped_snapshot := _presentation_snapshot(false)
	thermal = _entity(stopped_snapshot, "thermal-plant")
	_check(float(thermal.generation_kw) == 0.0 and thermal.status == "MISSING_FUEL", "finite coal exhaustion ends actual thermal generation")
	_check(int(world.statistics.consumed.get("dsp_coal",0)) == 1, "exactly one coal unit was consumed by real power allocation")
	canvas.apply_snapshot(stopped_snapshot)
	var stopped := await _capture("03-stopped")
	canvas.call("_advance_industry_buildings", 0.5)
	var stopped_later := await _capture("")
	_check(stopped.get_data() == stopped_later.get_data() and canvas.get("_industry_animation_seconds") == clocks, "stopped machinery and exhausted generator retain their poses without work effects")
	for family in Art.FAMILIES:
		_check(_crop(working, _art_rect(snapshot,family)).get_data() != _crop(stopped, _art_rect(stopped_snapshot,family)).get_data(), "production lighting switches off: " + family)

	# Ghosts use actual definition footprints, but intentionally no economy/order
	# mutation: this test checks the production renderer's snapshot boundary.
	var ghost_snapshot := stopped_snapshot.duplicate(true)
	ghost_snapshot.topology_revision = int(ghost_snapshot.topology_revision) + 1
	for index in REPRESENTATIVES.size():
		var definition_id: String = REPRESENTATIVES[index]
		var family: String = MAPPINGS[definition_id]
		var footprint: Dictionary = _entity(snapshot,family).footprint.duplicate(true)
		footprint.origin.y = 56
		ghost_snapshot.construction_orders.append({"id":"ghost-" + family,"definition_id":definition_id,"footprint":footprint,"status":"WAITING_BUILDING"})
	canvas.apply_snapshot(ghost_snapshot)
	var ghosts := await _capture("04-ghosts")
	for order in ghost_snapshot.construction_orders:
		var rect: Rect2 = canvas.call("_footprint_rect",order.footprint)
		var family: String = MAPPINGS[order.definition_id]
		var body := Art.body_rect(family,rect)
		_check(_crop(stopped,body).get_data() != _crop(ghosts,body).get_data(), "missing-building ghost is visibly rendered: " + family)
		canvas.apply_snapshot(stopped_snapshot)
		canvas.set_placement_preview({"definition_id":order.definition_id,"node_kind":"POWER" if family == "thermal-plant" else "MACHINE","valid":true,"footprint":order.footprint})
		var preview := await _capture("05-preview-" + family)
		_check(_crop(stopped,body).get_data() != _crop(preview,body).get_data(), "placement preview displays selected family: " + family)
		canvas.clear_placement_preview()
	_check(JSON.stringify(game.state.to_dictionary()) == original_state, "all presentation paths leave the player's economy untouched")
	_check(Art.errors().is_empty(), "all requested frames resolve locally: " + str(Art.errors()))
	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_APPROVED_INDUSTRY_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _test_mapping_and_geometry() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Art.PACK + "manifest.json"))
	for family in Art.FAMILIES:
		for layer in ["body","working","shadow"]:
			var entry: Dictionary = manifest.families[family].layers[layer]
			var path := str(entry.texture) if layer == "shadow" else str(entry.textures[0])
			# Inspect the raw imported asset, not the adapter's fallback texture.
			var imported := ResourceLoader.load(path,"Texture2D",ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
			_check(imported != null and imported.get_image().has_mipmaps(), "checked-in import enables real mipmaps: " + family + "/" + layer)
	for definition_id in MAPPINGS:
		var family: String = MAPPINGS[definition_id]
		_check(Art.is_available(family), "approved pack exists: " + family)
		_check(BuildingArt.industry_family(definition_id) == family, "approved definition mapping: " + definition_id)
		var icon := Art.icon_texture(family)
		_check(icon != null and BuildingArt.icon_texture(BuildingArt.atlas_texture(),definition_id,"MACHINE") == icon, "entity/build-palette icon routes to approved family: " + definition_id)
		var item_icon := ItemArt.texture_for_item("building_" + definition_id)
		_check(item_icon == icon and ItemArt.texture_for_item("building_" + definition_id) == item_icon, "finished building icon shares the cached family texture: " + definition_id)
		var definition: Dictionary = database.factory_buildings[definition_id]
		var expected := Vector2(10,10) if family == "thermal-plant" else Vector2(12,10)
		_check(Vector2(definition.footprint.width,definition.footprint.height) == expected, "art replacement preserves gameplay footprint: " + definition_id)
		for scale in [0.65,1.0,1.25]:
			var ground := Rect2(Vector2(71,43), expected * 16.0 * scale)
			var body := Art.body_rect(family,ground)
			var native: Array = manifest.families[family].source_body_rect
			_check(is_equal_approx(body.size.x / body.size.y,float(native[2]) / float(native[3])), "source aspect ratio is preserved: " + family)
			if family == "thermal-plant":
				# Pinned original base frame:315x409, shifted(+5.5,+0.5)
				# in source pixels. Lower84% is the accepted ground silhouette;
				# the chimney is intentionally allowed above the footprint.
				var original_base := Rect2(Vector2(-152,-204),Vector2(315,409))
				var native_body := Rect2(Vector2(native[0],native[1]),Vector2(native[2],native[3]))
				var factor := body.size.x / native_body.size.x
				var base := Rect2(body.position + (original_base.position - native_body.position) * factor, original_base.size * factor)
				var ground_base := Rect2(base.position + Vector2(0,base.size.y * 0.16),base.size * Vector2(1,0.84))
				_check(ground.grow(0.01).encloses(ground_base), "thermal base stays inside the real10x10 footprint at scale " + str(scale))
	_check(BuildingArt.industry_family("grid_dsp_plane_smelter").is_empty() and BuildingArt.industry_family("grid_dsp_miniature_particle_collider").is_empty(), "unrelated building families retain their artwork")

func _create_world() -> void:
	var definitions := database.factory_buildings.duplicate(true)
	definitions["test_load"] = {"kind":"MACHINE","footprint":{"width":1,"height":1},"power_demand_kw":1000,"input_capacity":1,"output_capacity":1,"recipe_ids":[]}
	grid = FactoryGridSimulation.new(definitions,database.factory_recipes,database.factory_grid_rules)
	world = grid.create_world("approved-industry-art","",Vector2i(256,160))
	for index in REPRESENTATIVES.size():
		var definition_id: String = REPRESENTATIVES[index]
		_check(grid.place_entity_immediate(world,definition_id,Vector2i(10 + index * 22,30),"",MAPPINGS[definition_id]).get("ok",false), "isolated real entity creation: " + definition_id)
	_check(grid.place_entity_immediate(world,"test_load",Vector2i(100,30),"","load").get("ok",false), "isolated road power demand exists")
	var roads: Array = []
	for x in range(76,101):
		roads.append({"x":x,"y":29})
	grid.edit_roads(world,roads)
	world.entities["thermal-plant"].inputs["dsp_coal"] = 1
	grid.advance_world(world,1000.0)

func _presentation_snapshot(running: bool = true) -> Dictionary:
	# Mirror SimulationEngine.refresh_factory_runtime_views before presenting
	# a tick: advance_world settles power, while this zero-time pass refreshes
	# POWER status and the remaining generation capacity without burning fuel.
	grid.refresh_derived_state(world)
	var snapshot := grid.workspace_snapshot(world)
	for row in snapshot.entities:
		if row.id in ["manufacturer","fuel-refinery","chemical-stager"]:
			row.status = "RUNNING" if running else "NO_POWER"
			row.actual_rate = 1.0 if running else 0.0
	return snapshot

func _entity(snapshot: Dictionary, family: String) -> Dictionary:
	for row in snapshot.entities:
		if row.id == family:
			return row
	return {}

func _art_rect(snapshot: Dictionary, family: String) -> Rect2:
	var footprint: Rect2 = canvas.call("_footprint_rect", _entity(snapshot,family).footprint)
	return Art.body_rect(family,footprint)

func _frame(family: String) -> int:
	return Art.frame_index(family,float(canvas.get("_industry_animation_seconds").get(family,0.0)))

func _crop(picture: Image, logical_rect: Rect2) -> Image:
	var rect := Rect2i(logical_rect.position * 2.0,logical_rect.size * 2.0).intersection(Rect2i(Vector2i.ZERO,picture.get_size()))
	_check(rect.has_area(), "pixel assertion region is actually visible")
	return picture.get_region(rect)

func _capture(label: String) -> Image:
	canvas.queue_redraw()
	for index in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if not label.is_empty():
		var path := ProjectSettings.globalize_path("res://artifacts/ui/approved-industry/" + label + ".png")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_check(picture.save_png(path) == OK, "real4K capture: " + label)
		var preview := picture.duplicate() as Image
		preview.resize(1920,1080,Image.INTERPOLATE_LANCZOS)
		_check(preview.save_jpg(path.trim_suffix(".png") + ".jpg",0.92) == OK, "review preview: " + label)
	return picture

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
