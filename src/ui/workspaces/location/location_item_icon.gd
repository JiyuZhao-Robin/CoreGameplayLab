class_name LocationItemIcon
extends Control

## Generated material art, not placeholder geometry. All tiles share one
## imported texture; each cached AtlasTexture selects an immutable sprite.
const ATLAS_PATH := "res://assets/ui/location/generated/material_icons_v2/material_icons_atlas.png"
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const COLUMNS := 8
const ROWS := 4
const UNKNOWN_INDEX := 31
const INDEX_BY_ITEM := {
	"iron_ore":0, "copper_ore":1, "iron_ingot":2, "copper_ingot":3,
	"scrap_metal":4, "electronics":5, "data_core":6, "industrial_waste":7,
	"chemical_propellant":8, "kinetic_munitions":9, "repair_material":10,
	"repair_supplies":11, "basic_drive":12, "civilian_shield":13,
	"light_autocannon":14, "civilian_reactor_core":15,
	"structural_frame":16, "industrial_machine_tools":17, "titanium_ore":18,
	"cobalt_ore":19, "silicate_ore":20, "water_ice":21, "helium_3":22,
	"methane":23, "titanium_alloy":24, "superconducting_coil":25,
	"exotic_crystal":26, "dark_matter":27, "quantum_component":28,
	"construction_robotics":29, "blueprint_fragment":30,
	# Later-game materials share authored family art. Explicit IDs prevent
	# substring mistakes: data_core must never become an ore silhouette.
	"mixed_raw_ore":0, "mixed_raw_gas":23, "reactor_part":15,
	"cobalt_ingot":24, "silicate_ceramic":20, "thorium_fuel":22,
	"heavy_structural_section":16, "precision_actuator":17,
	"power_bus_component":25, "logistics_handling_equipment":29,
	"thermal_exchange_unit":17, "automated_control_core":6,
	"sensor_array":28, "pirate_cipher":6, "cargo_expansion":16,
	"bulk_freight_array":16, "cryogenic_hold_system":22,
	"mobile_repair_system":11, "deep_survey_system":28,
	"targeting_computer":5, "high_output_reactor_core":15,
	"radiation_shielding":10, "steel_composite":2, "superalloy":24,
	"antimatter_cell":27, "project_core":28, "advanced_drive":12,
	"plasma_cannon":14, "capital_shield":13, "stealth_array":28,
	"fusion_service_component":15, "superconducting_composite":25,
	"radiation_hardened_electronics":5, "propulsion_test_article":12,
	"material_test_article":24, "rare_earth_concentrate":19,
	"thorium_ore":18, "corsair_overcharged_laser":14
}

static var _atlas: Texture2D
static var _cells: Dictionary = {}
var _item_id := ""
var _texture: Texture2D


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if custom_minimum_size == Vector2.ZERO:
		custom_minimum_size = Vector2(48, 48)
	_texture = texture_for_item(_item_id)
	queue_redraw()


func configure_item(item_id: String, _category: String = "") -> void:
	var normalized := item_id.to_lower()
	if normalized == _item_id and _texture != null:
		return
	_item_id = normalized
	_texture = texture_for_item(_item_id)
	queue_redraw()


func art_texture() -> Texture2D:
	return _texture


func art_index() -> int:
	return icon_index(_item_id)


func _family() -> String:
	if _item_id.begins_with("building_grid_"):
		return "GENERATED_BUILDING"
	return "UNKNOWN" if art_index() == UNKNOWN_INDEX else "GENERATED_MATERIAL"


func _draw() -> void:
	if _texture == null:
		return
	var edge := minf(size.x, size.y)
	var rect := Rect2((size - Vector2.ONE * edge) * 0.5, Vector2.ONE * edge)
	draw_texture_rect(_texture, rect, false)


static func icon_index(item_id: String) -> int:
	return int(INDEX_BY_ITEM.get(item_id.to_lower(), UNKNOWN_INDEX))


static func atlas_texture() -> Texture2D:
	if _atlas == null and ResourceLoader.exists(ATLAS_PATH):
		_atlas = load(ATLAS_PATH) as Texture2D
	return _atlas


static func texture_for_item(item_id: String) -> Texture2D:
	if item_id.begins_with("building_grid_"):
		var family := BuildingArt.industry_family(item_id.trim_prefix("building_"))
		if not family.is_empty():
			return BuildingArt.IndustryArt.icon_texture(family)
	# A selected building family's production art takes precedence over the
	# original DSP item atlas, just as it does in the Factory palette.
	if item_id.begins_with("building_grid_") and BuildingArt.uses_arc_furnace(item_id.trim_prefix("building_")):
		return BuildingArt.ArcFurnaceArt.icon_texture()
	if item_id.begins_with("building_grid_") and BuildingArt.uses_core_extractor(item_id.trim_prefix("building_")):
		return BuildingArt.CoreExtractorArt.icon_texture()
	var imported := BuildingArt.DspArt.texture(item_id)
	if imported != null:
		return imported
	if item_id.begins_with("building_grid_"):
		if not _cells.has(item_id):
			_cells[item_id] = BuildingArt.icon_texture(BuildingArt.atlas_texture(), item_id.trim_prefix("building_"), "MACHINE")
		return _cells[item_id]
	var index := icon_index(item_id)
	if _cells.has(index):
		return _cells[index]
	var atlas := atlas_texture()
	if atlas == null:
		return null
	var cell_size := Vector2(atlas.get_size()) / Vector2(COLUMNS, ROWS)
	var texture := AtlasTexture.new()
	texture.atlas = atlas
	texture.region = Rect2(Vector2(index % COLUMNS, floori(float(index) / COLUMNS)) * cell_size, cell_size)
	texture.filter_clip = true
	_cells[index] = texture
	return texture
