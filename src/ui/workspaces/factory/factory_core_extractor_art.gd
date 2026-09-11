class_name FactoryCoreExtractorArt
extends RefCounted

## Presentation-only texture adapter for the Factory Core Extractor.  The
## derived 256px source frames are imported assets; this module only opens the
## specific frames a renderer asks for and shares each resulting Texture2D.

const MANIFEST_PATH := "res://assets/ui/factory/miner/core_extractor/manifest.json"

static var _manifest: Dictionary = {}
static var _manifest_attempted := false
static var _manifest_valid := false
static var _texture_cache: Dictionary = {}
static var _frame_cache: Dictionary = {}
static var _icon: AtlasTexture
static var _errors: Array[String] = []
static var _error_codes: Dictionary = {}


static func is_available() -> bool:
	return _ensure_manifest()


static func icon_texture() -> AtlasTexture:
	var body := frame_texture("body", 0)
	if body == null:
		return null
	if _icon == null or _icon.atlas != body:
		_icon = AtlasTexture.new()
		_icon.atlas = body
		_icon.region = Rect2(Vector2.ZERO, body.get_size())
		_icon.filter_clip = true
	return _icon


static func frame_texture(layer: String, frame: int) -> Texture2D:
	if not _ensure_manifest():
		return null
	if layer == "shadow":
		var shadow_key := "shadow"
		if _frame_cache.has(shadow_key):
			return _frame_cache[shadow_key] as Texture2D
		var shadow_layers: Dictionary = _manifest.get("layers", {}) as Dictionary
		var shadow_definition: Dictionary = shadow_layers.get("shadow", {}) as Dictionary
		var shadow := _texture_for_path(str(shadow_definition.get("texture", "")))
		if shadow != null:
			_frame_cache[shadow_key] = shadow
		return shadow
	if layer not in ["body", "emission", "working"]:
		return null
	var layers: Dictionary = _manifest.get("layers", {}) as Dictionary
	var layer_definition: Dictionary = layers.get(layer, {}) as Dictionary
	var paths: Array = layer_definition.get("textures", []) as Array
	if paths.is_empty():
		return null
	var frame_index := posmod(frame, paths.size())
	var frame_key := "%s:%d" % [layer, frame_index]
	if _frame_cache.has(frame_key):
		return _frame_cache[frame_key] as Texture2D
	var texture := _texture_for_path(str(paths[frame_index]))
	if texture != null:
		_frame_cache[frame_key] = texture
	return texture


static func frame_index(elapsed_seconds: float) -> int:
	if not _ensure_manifest():
		return 0
	var count := maxi(1, int(_manifest.get("frame_count", 1)))
	var fps := maxf(1.0, float(_manifest.get("fps", 30.0)))
	return posmod(floori(elapsed_seconds * fps + 0.0001), count)


static func shadow_rect(body_rect: Rect2) -> Rect2:
	if not _ensure_manifest():
		return body_rect
	# This value describes the original 1400px shadow against the 704px body.
	# It intentionally does not infer scale from the 256px derived outputs.
	var ratio := float(_manifest.get("shadow_to_body_scale", 1400.0 / 704.0))
	var size := body_rect.size * ratio
	return Rect2(body_rect.get_center() - size * 0.5, size)


static func cache_stats() -> Dictionary:
	return {
		"manifest_loaded": _manifest_attempted,
		"available": _manifest_valid,
		"textures": _texture_cache.size(),
		"frames": _frame_cache.size(),
		"icon_cached": _icon != null,
		"errors": _errors.size()
	}


static func errors() -> Array[String]:
	return _errors.duplicate()


## Test-only reset hook. Production rendering never needs to discard this small,
## shared cache during a session.
static func clear_cache() -> void:
	_manifest.clear()
	_manifest_attempted = false
	_manifest_valid = false
	_texture_cache.clear()
	_frame_cache.clear()
	_icon = null
	_errors.clear()
	_error_codes.clear()


static func _ensure_manifest() -> bool:
	if _manifest_attempted:
		return _manifest_valid
	_manifest_attempted = true
	if not FileAccess.file_exists(MANIFEST_PATH):
		_add_error("manifest_missing", "Missing Core Extractor art manifest")
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not (parsed is Dictionary):
		_add_error("manifest_json", "Invalid Core Extractor art manifest JSON")
		return false
	var candidate := parsed as Dictionary
	if int(candidate.get("schema_version", 0)) != 1:
		_add_error("manifest_schema", "Unsupported Core Extractor art manifest schema")
		return false
	var count := int(candidate.get("frame_count", 0))
	var fps := float(candidate.get("fps", 0.0))
	var frame_size: Array = candidate.get("frame_size", []) as Array
	var layers: Dictionary = candidate.get("layers", {}) as Dictionary
	if count <= 0 or fps <= 0.0 or frame_size.size() < 2 or int(frame_size[0]) <= 0 or int(frame_size[1]) <= 0:
		_add_error("manifest_timing", "Invalid Core Extractor frame metadata")
		return false
	if float(candidate.get("shadow_to_body_scale", 0.0)) <= 0.0:
		_add_error("manifest_shadow_scale", "Missing Core Extractor original shadow/body ratio")
		return false
	for id in ["body", "emission"]:
		var layer: Dictionary = layers.get(id, {}) as Dictionary
		var paths: Array = layer.get("textures", []) as Array
		if paths.size() < count:
			_add_error("manifest_%s" % id, "Core Extractor %s frame list is incomplete" % id)
			return false
	if layers.has("working"):
		var working: Dictionary = layers.get("working", {}) as Dictionary
		var working_paths: Array = working.get("textures", []) as Array
		if working_paths.size() < count:
			_add_error("manifest_working", "Core Extractor working frame list is incomplete")
			return false
	var shadow: Dictionary = layers.get("shadow", {}) as Dictionary
	if str(shadow.get("texture", "")).is_empty():
		_add_error("manifest_shadow", "Core Extractor shadow texture is missing")
		return false
	_manifest = candidate
	_manifest_valid = true
	return true


static func _texture_for_path(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _texture_cache.has(path):
		return _texture_cache[path] as Texture2D
	if not ResourceLoader.exists(path):
		_add_error("texture:" + path, "Missing Core Extractor texture: " + path)
		return null
	var texture := load(path) as Texture2D
	if texture == null:
		_add_error("texture_load:" + path, "Unable to load Core Extractor texture: " + path)
		return null
	var image := texture.get_image()
	if image != null and not image.has_mipmaps():
		if image.is_compressed():
			image.decompress()
		image.generate_mipmaps()
		texture = ImageTexture.create_from_image(image)
	_texture_cache[path] = texture
	return texture


static func _add_error(code: String, message: String) -> void:
	if _error_codes.has(code):
		return
	_error_codes[code] = true
	_errors.append(message)
