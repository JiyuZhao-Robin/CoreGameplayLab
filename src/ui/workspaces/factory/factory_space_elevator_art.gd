class_name FactorySpaceElevatorArt
extends RefCounted

## Original model animation baked to project-local frames. Presentation only:
## this loop does not simulate trains, ships, inventory or production.
const PACK := "res://assets/ui/factory/space_elevator/"
static var _manifest: Dictionary = {}
static var _attempted := false
static var _textures: Dictionary = {}
static var _icon: AtlasTexture
static var _errors: Array[String] = []


static func is_available() -> bool:
	if _attempted:
		return not _manifest.is_empty()
	_attempted = true
	if not FileAccess.file_exists(PACK + "manifest.json"):
		_errors.append("Missing space elevator art manifest")
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PACK + "manifest.json"))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		_errors.append("Invalid space elevator art manifest")
		return false
	var frames: Variant = parsed.get("frames", [])
	var relative: Variant = parsed.get("body_rect_normalized", [])
	var count := int(parsed.get("frame_count", 0))
	var fps := float(parsed.get("fps", 0.0))
	if not frames is Array or count < 2 or frames.size() != count or not is_finite(fps) or fps <= 0.0:
		_errors.append("Incomplete space elevator animation")
		return false
	if not relative is Array or relative.size() != 4:
		_errors.append("Missing space elevator geometry")
		return false
	for value in relative:
		if not (value is float or value is int) or not is_finite(float(value)):
			_errors.append("Invalid space elevator geometry")
			return false
	if float(relative[2]) <= 0.0 or float(relative[3]) <= 0.0:
		_errors.append("Empty space elevator geometry")
		return false
	var reference: Variant = parsed.get("reference_footprint_tiles", [1, 1])
	if not reference is Array or reference.size() != 2 or float(reference[0]) <= 0.0 or float(reference[1]) <= 0.0:
		_errors.append("Invalid space elevator reference footprint")
		return false
	for value in frames:
		var path := str(value)
		if not path.begins_with(PACK + "frames/") or path.contains("..") or not ResourceLoader.exists(path):
			_errors.append("Missing or external space elevator frame: " + path)
			return false
	_manifest = parsed
	return true


static func frame_texture(frame: int) -> Texture2D:
	if not is_available():
		return null
	var path := str(_manifest["frames"][posmod(frame, frame_count())])
	if not _textures.has(path):
		var texture := ResourceLoader.load(path, "Texture2D") as Texture2D
		if texture == null:
			_errors.append("Unable to load space elevator frame: " + path)
			return null
		_textures[path] = texture
	return _textures[path] as Texture2D


static func shadow_texture() -> Texture2D:
	if not is_available():
		return null
	var path := str(_manifest.get("shadow", ""))
	if path.is_empty():
		return null
	if not path.begins_with(PACK) or path.contains("..") or not ResourceLoader.exists(path):
		var message := "Missing or external space elevator shadow: " + path
		if not _errors.has(message):
			_errors.append(message)
		return null
	if not _textures.has(path):
		var texture := ResourceLoader.load(path, "Texture2D") as Texture2D
		if texture == null:
			_errors.append("Unable to load space elevator shadow: " + path)
			return null
		_textures[path] = texture
	return _textures[path] as Texture2D


static func frame_count() -> int:
	return int(_manifest["frame_count"]) if is_available() else 1


static func cycle_seconds() -> float:
	return float(frame_count()) / float(_manifest["fps"]) if is_available() else 1.0


static func frame_index(seconds: float) -> int:
	if not is_available() or not is_finite(seconds):
		return 0
	return posmod(floori(seconds * float(_manifest["fps"]) + 0.0001), frame_count())


static func body_rect(footprint: Rect2) -> Rect2:
	if not is_available():
		return footprint
	var fitted := footprint
	if _manifest.has("reference_footprint_tiles"):
		var reference: Array = _manifest["reference_footprint_tiles"]
		var ground := Vector2(float(reference[0]), float(reference[1]))
		var scale := minf(footprint.size.x / ground.x, footprint.size.y / ground.y)
		fitted = Rect2(footprint.get_center() - ground * scale * 0.5, ground * scale)
	var relative: Array = _manifest["body_rect_normalized"]
	return Rect2(fitted.position + fitted.size * Vector2(float(relative[0]), float(relative[1])), fitted.size * Vector2(float(relative[2]), float(relative[3])))


static func icon_texture() -> AtlasTexture:
	if _icon == null:
		var texture := frame_texture(0)
		if texture == null:
			return null
		_icon = AtlasTexture.new()
		_icon.atlas = texture
		_icon.region = Rect2(Vector2.ZERO, texture.get_size())
		_icon.filter_clip = true
	return _icon


static func errors() -> Array[String]:
	return _errors.duplicate()


static func clear_cache() -> void:
	_icon = null
	_textures.clear()
	_manifest.clear()
	_errors.clear()
	_attempted = false
