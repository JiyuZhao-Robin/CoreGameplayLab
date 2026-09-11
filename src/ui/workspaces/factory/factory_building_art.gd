class_name FactoryBuildingArt
extends RefCounted

## A single presentation mapping for the Factory's authored building atlas.
## It deliberately has no content or simulation knowledge: unknown definitions
## resolve by visible node role so a newly unlocked building still has a useful
## silhouette before a bespoke cell is added to the atlas.

const ATLAS_PATH := "res://assets/ui/factory/generated/factory_building_icon_atlas_v1.png"
const CORE_PATH := "res://assets/ui/factory/core/generated/planetary_core_v1.png"
const DspArt = preload("res://src/ui/workspaces/factory/factory_dsp_art.gd")
const CoreExtractorArt = preload("res://src/ui/workspaces/factory/factory_core_extractor_art.gd")
const ArcFurnaceArt = preload("res://src/ui/workspaces/factory/factory_arc_furnace_art.gd")
const IndustryArt = preload("res://src/ui/workspaces/factory/factory_approved_industry_art.gd")
const INDUSTRY_FAMILIES := {
	"grid_engineering_works": "manufacturer",
	"grid_dsp_assembling_machine_mk1": "manufacturer",
	"grid_dsp_assembling_machine_mk2": "manufacturer",
	"grid_dsp_assembling_machine_mk3": "manufacturer",
	"grid_dsp_oil_refinery": "fuel-refinery",
	"grid_dsp_chemical_plant": "chemical-stager",
	"grid_dsp_quantum_chemical_plant": "chemical-stager",
	"grid_dsp_thermal_power_plant": "thermal-plant",
}
const ARC_FURNACE_IDS := ["grid_arc_smelter", "grid_dsp_arc_smelter"]
## Explicit visual family: pumps, orbital collectors and the development core
## retain their own art. IDs, footprints and building-item contracts stay intact.
const CORE_EXTRACTOR_IDS := [
	"grid_surface_mine", "grid_cryogenic_extractor", "grid_exotic_extractor",
	"grid_dsp_mining_machine"
]
const COLUMNS := 4
const ROWS := 3

const INDEX_BY_BUILDING := {
	"grid_surface_mine":0,
	"grid_cryogenic_extractor":0,
	"grid_exotic_extractor":0,
	"grid_cargo_splitter":1,
	"grid_cargo_merger":1,
	"grid_engineering_works":2,
	"grid_arc_smelter":3,
	"grid_electronics_works":4,
	"grid_assembly_array":5,
	"grid_bulk_depot":6,
	"grid_component_depot":6,
	"grid_fluid_tank":7,
	"grid_solar_array":8,
	"grid_research_complex":10,
	"grid_research_complex_ii":10,
	"grid_repair_dock":11,
	"grid_construction_yard":11
}

const INDEX_BY_KIND := {
	"POWER":8,
	"EXTRACTOR":0,
	"MACHINE":2,
	"ROUTER":1,
	"STORAGE":6,
	"CONSTRUCTION":11
}


static func atlas_texture() -> Texture2D:
	return load(ATLAS_PATH) as Texture2D if ResourceLoader.exists(ATLAS_PATH) else null


static func icon_index(definition_id: String, kind: String) -> int:
	return int(INDEX_BY_BUILDING.get(definition_id, INDEX_BY_KIND.get(kind.to_upper(), 2)))


static func atlas_region(texture: Texture2D, definition_id: String, kind: String) -> Rect2:
	if texture == null:
		return Rect2()
	var cell_width := float(texture.get_width()) / float(COLUMNS)
	var cell_height := float(texture.get_height()) / float(ROWS)
	if cell_width <= 0.0 or cell_height <= 0.0:
		return Rect2()
	var index := icon_index(definition_id, kind)
	return Rect2(
		Vector2(float(index % COLUMNS) * cell_width, float(floori(float(index) / float(COLUMNS))) * cell_height),
		Vector2(cell_width, cell_height)
	)


static func icon_texture(texture: Texture2D, definition_id: String, kind: String) -> AtlasTexture:
	var family := industry_family(definition_id)
	if not family.is_empty():
		return IndustryArt.icon_texture(family)
	if uses_arc_furnace(definition_id):
		return ArcFurnaceArt.icon_texture()
	if uses_core_extractor(definition_id):
		var miner := CoreExtractorArt.icon_texture()
		if miner != null:
			return miner
	if definition_id.begins_with("grid_dsp_"):
		var imported := DspArt.texture(definition_id)
		if imported != null:
			return imported
	if definition_id == "grid_planetary_core" and ResourceLoader.exists(CORE_PATH):
		var core_texture := load(CORE_PATH) as Texture2D
		var core_atlas := AtlasTexture.new()
		core_atlas.atlas = core_texture
		core_atlas.region = Rect2(Vector2.ZERO,core_texture.get_size())
		return core_atlas
	var region := atlas_region(texture, definition_id, kind)
	if texture == null or region.size.x <= 0.0 or region.size.y <= 0.0:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = region
	return atlas


static func uses_core_extractor(definition_id: String) -> bool:
	return definition_id in CORE_EXTRACTOR_IDS and CoreExtractorArt.is_available()


static func uses_arc_furnace(definition_id: String) -> bool:
	return definition_id in ARC_FURNACE_IDS and ArcFurnaceArt.is_available()


static func industry_family(definition_id: String) -> String:
	var family := str(INDUSTRY_FAMILIES.get(definition_id, ""))
	return family if not family.is_empty() and IndustryArt.is_available(family) else ""
