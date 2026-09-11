class_name FactoryArcFurnaceArt
extends RefCounted

## Shared, lazy production frames. Full source atlases are never loaded here.
const PACK := "res://assets/ui/factory/arc_furnace/"
static var _manifest: Dictionary = {}
static var _attempted := false
static var _textures: Dictionary = {}
static var _icon: AtlasTexture
static var _errors: Array[String] = []


static func is_available() -> bool:
	if _attempted:
		return not _manifest.is_empty()
	_attempted = true
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PACK + "manifest.json"))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		_errors.append("Missing or invalid Arc Furnace art manifest")
		return false
	var layers: Dictionary = parsed.get("layers", {})
	for name in ["body", "working"]:
		if layers.get(name, {}).get("textures", []).size() != 50:
			_errors.append("Incomplete Arc Furnace %s frames" % name)
			return false
	if parsed.get("shadow_rect_normalized", []).size() != 4 or str(layers.get("shadow", {}).get("texture", "")).is_empty():
		_errors.append("Missing Arc Furnace shadow metadata")
		return false
	_manifest = parsed
	return true


static func icon_texture() -> AtlasTexture:
	if _icon == null:
		var body := frame_texture("body", 0)
		if body == null:
			return null
		_icon = AtlasTexture.new()
		_icon.atlas = body
		_icon.region = Rect2(Vector2.ZERO, body.get_size())
		_icon.filter_clip = true
	return _icon


static func frame_texture(layer: String, frame: int) -> Texture2D:
	if not is_available() or layer not in ["body", "working", "shadow"]:
		return null
	var entry: Dictionary = _manifest["layers"][layer]
	var path := str(entry.get("texture", "")) if layer == "shadow" else str(entry["textures"][posmod(frame, 50)])
	if _textures.has(path):
		return _textures[path] as Texture2D
	if not path.begins_with(PACK) or not ResourceLoader.exists(path):
		var message := "Missing Arc Furnace frame: " + path
		if not _errors.has(message):
			_errors.append(message)
		return null
	var texture := ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	if texture == null:
		_errors.append("Unable to load Arc Furnace frame: " + path)
		return null
	var image := texture.get_image()
	if image != null and not image.has_mipmaps():
		if image.is_compressed():
			image.decompress()
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	_textures[path] = texture
	return texture


static func frame_index(seconds: float) -> int:
	return posmod(floori(seconds * 30.0 + 0.0001), 50) if is_finite(seconds) else 0


static func shadow_rect(body_rect: Rect2) -> Rect2:
	if not is_available():
		return body_rect
	var relative: Array = _manifest["shadow_rect_normalized"]
	return Rect2(body_rect.position + body_rect.size * Vector2(relative[0], relative[1]), body_rect.size * Vector2(relative[2], relative[3]))


static func clear_cache() -> void:
	_icon = null
	_textures.clear()
	_manifest.clear()
	_attempted = false
	_errors.clear()


static func errors() -> Array[String]:
	return _errors.duplicate()
