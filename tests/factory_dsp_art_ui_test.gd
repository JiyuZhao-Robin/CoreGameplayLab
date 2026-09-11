extends SceneTree

## Focused asset-to-Factory-UI contract. The test deliberately loads the
## merged content catalog and presentation adapter by explicit paths, so it
## cannot pass merely because a globally cached class happened to be present.

const ContentDatabaseScript = preload("res://src/core/content_database.gd")
const FactoryDspArtScript = preload("res://src/ui/workspaces/factory/factory_dsp_art.gd")
const FactoryBuildingArtScript = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

const DSP_CATALOG_PATH := "res://data/dsponline_industry.json"
const MATERIAL_REGIONS_PATH := "res://assets/ui/factory/dsponline/generated/materials_atlas_regions.json"
const MATERIAL_ATLAS_PATH := "res://assets/ui/factory/dsponline/generated/materials_atlas_v1.png"
const BUILDING_ATLAS_PATH := "res://assets/ui/factory/dsponline/generated/buildings_atlas_v1.png"
const CORE_ART_PATH := "res://assets/ui/factory/core/generated/planetary_core_v1.png"

var failures: Array[String] = []
var _building_rows: Array = []
var _material_rows: Array = []
var _material_regions: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := get_root().get_node_or_null("Game")
	if game != null:
		game.set_process(false)
	var database = ContentDatabaseScript.new()
	_check(database.load_from_file("res://data/content.json"), "the merged content catalog loads before visual mappings are exercised: %s" % str(database.errors))
	var source_catalog_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(DSP_CATALOG_PATH))
	var source_catalog: Dictionary = source_catalog_value if source_catalog_value is Dictionary else {}
	var regions_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(MATERIAL_REGIONS_PATH))
	var regions_document: Dictionary = regions_value if regions_value is Dictionary else {}
	_collect_source_rows(source_catalog)
	_collect_material_regions(regions_document)
	_test_asset_files_and_core_alpha()
	_test_merged_catalog(database)
	_test_authored_building_textures()
	_test_explicit_material_regions()
	await _test_real_workspace_uses_dsp_icons_and_building_recipe()
	_finish()


func _collect_source_rows(source_catalog: Dictionary) -> void:
	_building_rows.clear()
	_material_rows.clear()
	for building_value in source_catalog.get("factory_buildings", []):
		if building_value is Dictionary:
			_building_rows.append((building_value as Dictionary).duplicate(true))
	for item_value in source_catalog.get("items", []):
		if not item_value is Dictionary:
			continue
		var item := item_value as Dictionary
		var item_id := str(item.get("id", ""))
		var index := int(item.get("art_index", -1))
		if item_id.begins_with("building_") or index < 0 or index > 77:
			continue
		_material_rows.append(item.duplicate(true))
	_building_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("art_index", -1)) < int(b.get("art_index", -1)))
	_material_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("art_index", -1)) < int(b.get("art_index", -1)))
	_check(_building_rows.size() == 39 and _has_contiguous_indices(_building_rows, 39), "source catalog exposes exactly 39 authored Factory building art indices")
	_check(_material_rows.size() == 78 and _has_contiguous_indices(_material_rows, 78), "source catalog exposes exactly 78 authored material art indices")


func _collect_material_regions(regions_document: Dictionary) -> void:
	_material_regions.clear()
	for row_value in regions_document.get("items", []):
		if not row_value is Dictionary:
			continue
		var row := row_value as Dictionary
		var rect_value: Variant = row.get("rect_px", {})
		if not rect_value is Dictionary:
			continue
		_material_regions[int(row.get("art_index", -1))] = _rect_from_dictionary(rect_value as Dictionary)
	_check(_material_regions.size() == 78, "the explicit material region document covers all 78 source art indices")


func _test_asset_files_and_core_alpha() -> void:
	var material_atlas := load(MATERIAL_ATLAS_PATH) as Texture2D if ResourceLoader.exists(MATERIAL_ATLAS_PATH) else null
	var building_atlas := load(BUILDING_ATLAS_PATH) as Texture2D if ResourceLoader.exists(BUILDING_ATLAS_PATH) else null
	_check(material_atlas != null and material_atlas.get_width() > 0 and material_atlas.get_height() > 0, "the authored DSP material atlas is an importable texture")
	_check(building_atlas != null and building_atlas.get_width() > 0 and building_atlas.get_height() > 0, "the authored DSP building atlas is an importable texture")
	var core_image := Image.load_from_file(ProjectSettings.globalize_path(CORE_ART_PATH))
	_check(core_image != null and not core_image.is_empty() and core_image.get_pixel(0,0).a < 0.01, "the planetary core has a genuinely transparent pixel, not a baked checkerboard")
	var core_icon := FactoryBuildingArtScript.icon_texture(FactoryBuildingArtScript.atlas_texture(), "grid_planetary_core", "STORAGE") as AtlasTexture
	_check(core_icon != null and core_icon.atlas != null and core_icon.atlas.resource_path == CORE_ART_PATH and _rect_matches(core_icon.region, Rect2(Vector2.ZERO, core_icon.atlas.get_size())), "FactoryBuildingArt resolves the independent planetary-core texture as a complete icon")


func _test_merged_catalog(database) -> void:
	for building_value in _building_rows:
		var building := building_value as Dictionary
		var building_id := str(building.get("id", ""))
		_check(database.factory_buildings.has(building_id), "merged content preserves DSP building %s" % building_id)
	for item_value in _material_rows:
		var item := item_value as Dictionary
		var item_id := str(item.get("id", ""))
		_check(database.items.has(item_id), "merged content preserves DSP material %s" % item_id)


func _test_authored_building_textures() -> void:
	var atlas := load(BUILDING_ATLAS_PATH) as Texture2D if ResourceLoader.exists(BUILDING_ATLAS_PATH) else null
	if atlas == null:
		return
	var cell := atlas.get_size() / Vector2(8.0, 5.0)
	for building_value in _building_rows:
		var building := building_value as Dictionary
		var building_id := str(building.get("id", ""))
		var index := int(building.get("art_index", -1))
		var art := FactoryDspArtScript.texture(building_id) as AtlasTexture
		var expected := Rect2(Vector2(index % 8, floori(float(index) / 8.0)) * cell, cell)
		_check(
			art != null and art.atlas != null and art.atlas.resource_path == BUILDING_ATLAS_PATH and _rect_matches(art.region, expected),
			"DSP building %s resolves its authored atlas cell %d rather than a fallback" % [building_id, index]
		)


func _test_explicit_material_regions() -> void:
	for item_value in _material_rows:
		var item := item_value as Dictionary
		var item_id := str(item.get("id", ""))
		var index := int(item.get("art_index", -1))
		var art := FactoryDspArtScript.texture(item_id) as AtlasTexture
		var expected: Rect2 = _material_regions.get(index, Rect2()) as Rect2
		_check(
			art != null and art.atlas != null and art.atlas.resource_path == MATERIAL_ATLAS_PATH and expected.size.x > 0.0 and expected.size.y > 0.0 and _rect_matches(art.region, expected),
			"DSP material %s uses its explicit authored region for art index %d, never an inferred grid cell" % [item_id, index]
		)


func _test_real_workspace_uses_dsp_icons_and_building_recipe() -> void:
	var host := Control.new()
	host.name = "FactoryDspArtUiHost"
	host.size = Vector2(1920, 1080)
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.name = "FactoryDspArtWorkspace"
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	var intents: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	workspace.apply_snapshot(_workspace_fixture())
	await _settle()
	var card := workspace.find_child("FactoryBuildCardGridDspWindTurbine", true, false) as Button
	var icon_control := card.find_child("FactoryBuildCardIcon", true, false) as TextureRect if card != null else null
	var card_icon := icon_control.texture as AtlasTexture if icon_control != null else null
	var expected_building_icon := FactoryDspArtScript.texture("grid_dsp_wind_turbine") as AtlasTexture
	_check(
		workspace.size == Vector2(1920, 1080) and card_icon != null and expected_building_icon != null and _rect_matches(card_icon.region, expected_building_icon.region) and card_icon.atlas.resource_path == BUILDING_ATLAS_PATH,
		"the real 1920 logical Factory workspace renders the selectable DSP building with its authored atlas icon"
	)
	workspace.call("_on_entity_selected", _assembler_entity())
	await _settle()
	var selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	var recipe_index := _option_index(selector, "manufacture_grid_dsp_wind_turbine")
	var recipe_icon := selector.get_item_icon(recipe_index) as AtlasTexture if selector != null and recipe_index > 0 else null
	_check(
		selector != null and recipe_index > 0 and not selector.get_item_text(recipe_index).is_empty() and recipe_icon != null and recipe_icon.atlas != null and recipe_icon.atlas.resource_path == BUILDING_ATLAS_PATH,
		"machine configuration exposes a selectable finished-building recipe with the authored product icon"
	)
	if selector != null and recipe_index > 0:
		var before := intents.size()
		selector.select(recipe_index)
		selector.item_selected.emit(recipe_index)
		var intent: Dictionary = intents.back() as Dictionary if intents.size() > before else {}
		_check(intents.size() == before + 1 and str(intent.get("kind", "")) == "SET_RECIPE" and str((intent.get("payload", {}) as Dictionary).get("recipe_id", "")) == "manufacture_grid_dsp_wind_turbine", "selecting the authored building recipe stays on the existing SET_RECIPE command boundary")
	if OS.get_cmdline_user_args().has("--capture"):
		await _capture_gallery(host)
	workspace.queue_free()
	await process_frame
	host.queue_free()
	await process_frame


func _workspace_fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"dsp-art-ui-grid",
		"location_name":"Earth",
		"topology_revision":1,
		"runtime_revision":1,
		"logistics_mode":"PLANET_SHARED_ROADS",
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":128, "y":96}},
		"canvas_limits":{"max_world_size_tiles":{"x":128, "y":96}},
		"chunk_size_tiles":64,
		"roads":[],
		"road_logistics":{"capacity":0, "required":0, "utilization":0.0, "active_shipments":0},
		"shared_inventory":{"building_grid_dsp_wind_turbine":1},
		"location_inventory":{"building_grid_dsp_wind_turbine":1},
		"location_available_inventory":{"building_grid_dsp_wind_turbine":1},
		"item_names":{"building_grid_dsp_wind_turbine":"Wind Turbine", "iron_ingot":"Iron Ingot"},
		"entities":[_assembler_entity()],
		"links":[],
		"resource_fields":[],
		"construction_orders":[],
		"palette":{
			"buildings":[
				{"id":"grid_dsp_wind_turbine", "name":"Wind Turbine", "kind":"POWER", "footprint":{"width":10, "height":10}, "deployment_item_id":"building_grid_dsp_wind_turbine", "available_count":1, "recipe_ids":[]},
				{"id":"grid_dsp_assembling_machine_mk1", "name":"Assembling Machine Mk.I", "kind":"MACHINE", "footprint":{"width":12, "height":12}, "deployment_item_id":"building_grid_dsp_assembling_machine_mk1", "available_count":0, "recipe_ids":["manufacture_grid_dsp_wind_turbine"]}
			],
			"recipes":[
				{"id":"manufacture_grid_dsp_wind_turbine", "name":"Manufacture Wind Turbine", "building_definition_id":"grid_dsp_wind_turbine", "duration_seconds":1.0, "inputs":[{"item":"iron_ingot", "quantity":1}], "outputs":[{"item":"building_grid_dsp_wind_turbine", "quantity":1}]}
			]
		}
	}


func _assembler_entity() -> Dictionary:
	return {
		"id":"dsp-assembler", "definition_id":"grid_dsp_assembling_machine_mk1", "name":"Assembling Machine Mk.I", "node_kind":"MACHINE",
		"footprint":{"origin":{"x":32, "y":24}, "size":{"x":12, "y":12}}, "status":"READY", "power_factor":1.0,
		"actual_rate":0.0, "road_connected":true, "road_component_id":"roads-main", "recipe_id":"",
		"ports":{"inputs":[], "outputs":[], "accepts_power":false, "provides_power":false},
		"inputs":{}, "outputs":{}, "inventory":{}, "input_capacity":32, "output_capacity":32
	}


func _capture_gallery(host: Control) -> void:
	var gallery := GridContainer.new()
	gallery.name = "FactoryDspArtCaptureGallery"
	gallery.columns = 13
	gallery.position = Vector2(24, 24)
	gallery.size = Vector2(1872, 1032)
	gallery.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(gallery)
	for building_value in _building_rows:
		_add_gallery_icon(gallery, FactoryDspArtScript.texture(str((building_value as Dictionary).get("id", ""))))
	for item_value in _material_rows:
		_add_gallery_icon(gallery, FactoryDspArtScript.texture(str((item_value as Dictionary).get("id", ""))))
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	var result := image.save_png("/tmp/helios-dsp-art-ui.png")
	_check(result == OK, "optional DSP art gallery capture writes only /tmp/helios-dsp-art-ui.png")
	gallery.queue_free()


func _add_gallery_icon(gallery: GridContainer, texture: Texture2D) -> void:
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(72, 72)
	icon.texture = texture
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gallery.add_child(icon)


func _option_index(options: OptionButton, value: String) -> int:
	if options == null:
		return -1
	for index in options.item_count:
		if str(options.get_item_metadata(index)) == value:
			return index
	return -1


func _has_contiguous_indices(rows: Array, expected_count: int) -> bool:
	if rows.size() != expected_count:
		return false
	for index in expected_count:
		if int((rows[index] as Dictionary).get("art_index", -1)) != index:
			return false
	return true


func _rect_from_dictionary(rect: Dictionary) -> Rect2:
	return Rect2(float(rect.get("x", 0)), float(rect.get("y", 0)), float(rect.get("width", 0)), float(rect.get("height", 0)))


func _rect_matches(actual: Rect2, expected: Rect2) -> bool:
	return is_equal_approx(actual.position.x, expected.position.x) and is_equal_approx(actual.position.y, expected.position.y) and is_equal_approx(actual.size.x, expected.size.x) and is_equal_approx(actual.size.y, expected.size.y)


func _settle() -> void:
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_DSP_ART_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
