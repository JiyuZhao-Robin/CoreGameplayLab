class_name FactoryApprovedIndustryArt
extends RefCounted

## Shared lazy frames; the original large candidate atlases never load here.
const PACK := "res://assets/ui/factory/approved_industry/"
const FAMILIES := ["manufacturer", "fuel-refinery", "chemical-stager", "thermal-plant"]
static var _families: Dictionary = {}
static var _attempted := false
static var _textures: Dictionary = {}
static var _icons: Dictionary = {}
static var _errors: Array[String] = []


static func is_available(family: String) -> bool:
	if not _attempted:
		_attempted = true
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PACK + "manifest.json"))
		if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
			_errors.append("Missing or invalid approved industry art manifest")
			return false
		for key in FAMILIES:
			var entry: Dictionary = parsed.get("families", {}).get(key, {})
			var count := int(entry.get("frame_count", 0))
			var layers: Dictionary = entry.get("layers", {})
			if count <= 0 or layers.get("body", {}).get("textures", []).size() != count or layers.get("working", {}).get("textures", []).size() != count:
				_errors.append("Incomplete approved industry frames: " + key)
				continue
			if entry.get("body_rect_normalized", []).size() != 4 or entry.get("shadow_rect_normalized", []).size() != 4 or entry.get("reference_footprint_tiles", []).size() != 2 or str(layers.get("shadow", {}).get("texture", "")).is_empty():
				_errors.append("Missing approved industry geometry: " + key)
				continue
			_families[key] = entry
	return _families.has(family)


static func icon_texture(family: String) -> AtlasTexture:
	if not _icons.has(family):
		var body := frame_texture(family, "body", 0)
		if body == null:
			return null
		var icon := AtlasTexture.new()
		icon.atlas = body
		icon.region = Rect2(Vector2.ZERO, body.get_size())
		icon.filter_clip = true
		_icons[family] = icon
	return _icons[family] as AtlasTexture


static func frame_texture(family: String, layer: String, frame: int) -> Texture2D:
	if not is_available(family) or layer not in ["body", "working", "shadow"]:
		return null
	var entry: Dictionary = _families[family]["layers"][layer]
	var path := str(entry.get("texture", "")) if layer == "shadow" else str(entry["textures"][posmod(frame, frame_count(family))])
	if _textures.has(path):
		return _textures[path] as Texture2D
	if not path.begins_with(PACK + family + "/") or not ResourceLoader.exists(path):
		var message := "Missing approved industry frame: " + path
		if not _errors.has(message):
			_errors.append(message)
		return null
	var texture := ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	if texture == null:
		_errors.append("Unable to load approved industry frame: " + path)
		return null
	var image := texture.get_image()
	if image != null and not image.has_mipmaps():
		if image.is_compressed():
			image.decompress()
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	_textures[path] = texture
	return texture


static func frame_count(family: String) -> int:
	return int(_families[family]["frame_count"]) if is_available(family) else 1


static func frame_index(family: String, seconds: float) -> int:
	if not is_available(family) or not is_finite(seconds):
		return 0
	return posmod(floori(seconds * float(_families[family]["fps"]) + 0.0001), frame_count(family))


static func body_rect(family: String, footprint_rect: Rect2) -> Rect2:
	if not is_available(family):
		return footprint_rect
	var tiles: Array = _families[family]["reference_footprint_tiles"]
	var ground := Vector2(tiles[0], tiles[1])
	var scale := minf(footprint_rect.size.x / ground.x, footprint_rect.size.y / ground.y)
	var fitted := Rect2(footprint_rect.get_center() - ground * scale * 0.5, ground * scale)
	var relative: Array = _families[family]["body_rect_normalized"]
	return Rect2(fitted.position + fitted.size * Vector2(relative[0], relative[1]), fitted.size * Vector2(relative[2], relative[3]))


static func shadow_rect(family: String, rendered_body_rect: Rect2) -> Rect2:
	if not is_available(family):
		return rendered_body_rect
	var relative: Array = _families[family]["shadow_rect_normalized"]
	return Rect2(rendered_body_rect.position + rendered_body_rect.size * Vector2(relative[0], relative[1]), rendered_body_rect.size * Vector2(relative[2], relative[3]))


static func clear_cache() -> void:
	_icons.clear()
	_textures.clear()
	_families.clear()
	_attempted = false
	_errors.clear()


static func errors() -> Array[String]:
	return _errors.duplicate()
