class_name FactoryDspArt
extends RefCounted

## Presentation-only catalog index. No runtime entity or inventory ownership.
const ROOT := "res://assets/ui/factory/dsponline/generated/"
static var _indices := {}
static var _textures := {}
static var _loaded := false
static var _material_regions := {}


static func texture(id: String) -> AtlasTexture:
	if not _loaded:
		_loaded = true
		var regions = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "materials_atlas_regions.json")) if FileAccess.file_exists(ROOT + "materials_atlas_regions.json") else {}
		for row in regions.get("items", []):
			var rect: Dictionary = row.get("rect_px", {})
			_material_regions[int(row["art_index"])] = Rect2(float(rect.get("x",0)),float(rect.get("y",0)),float(rect.get("width",0)),float(rect.get("height",0)))
		var catalog = JSON.parse_string(FileAccess.get_file_as_string("res://data/dsponline_industry.json"))
		if catalog is Dictionary:
			for collection in ["items", "factory_buildings"]:
				for row in catalog.get(collection, []):
					if row.has("art_index"):
						_indices[str(row["id"])] = {"index":int(row["art_index"]), "building":collection == "factory_buildings" or str(row.get("id", "")).begins_with("building_")}
	if not _indices.has(id):
		return null
	if _textures.has(id):
		return _textures[id]
	var entry: Dictionary = _indices[id]
	var building := bool(entry["building"])
	var path := ROOT + ("buildings_atlas_v1.png" if building else "materials_atlas_v1.png")
	if not ResourceLoader.exists(path):
		return null
	var source := load(path) as Texture2D
	var columns := 8 if building else 10
	var rows := 5 if building else 8
	var index := int(entry["index"])
	var cell := source.get_size() / Vector2(columns, rows)
	var result := AtlasTexture.new()
	result.atlas = source
	result.region = Rect2(Vector2(index % columns, floori(float(index) / columns)) * cell, cell)
	if not building and _material_regions.has(index):
		result.region = _material_regions[index]
	result.filter_clip = true
	_textures[id] = result
	return result
