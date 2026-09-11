class_name HelixMinerAssets
extends RefCounted

## Display-only loader for the original Helix Miner bake.  The manifest keeps
## every source path and frame boundary explicit; this class never touches game
## content, inventory, or factory state.

const MANIFEST := "res://assets/models/helix_miner/manifest.json"

var manifest: Dictionary = {}
var frames: Dictionary = {}
var errors: Array[String] = []
var _texture_cache: Dictionary = {}


func load_pack() -> void:
	manifest.clear()
	frames.clear()
	errors.clear()
	_texture_cache.clear()
	if not FileAccess.file_exists(MANIFEST):
		errors.append("Missing Helix Miner manifest")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not (parsed is Dictionary) or int((parsed as Dictionary).get("schema_version", 0)) != 1:
		errors.append("Invalid Helix Miner manifest schema")
		return
	manifest = parsed as Dictionary
	var building := building_definition()
	for layer_value in building.get("layers", []):
		if layer_value is Dictionary:
			var layer_definition := layer_value as Dictionary
			_load_definition(str(layer_definition.get("id", "")), layer_definition)
	for clip_id in ["startup", "working", "shutdown"]:
		_load_definition(clip_id, clip(clip_id))
	for id in ["ground", "ore", "smoke"]:
		var definition: Dictionary = manifest.get(id, {}) as Dictionary
		_load_definition(id, definition)


func building_definition() -> Dictionary:
	return manifest.get("building", {}) as Dictionary


func layer(id: String) -> Dictionary:
	for layer_value in building_definition().get("layers", []):
		if layer_value is Dictionary:
			var definition := layer_value as Dictionary
			if str(definition.get("id", "")) == id:
				return definition
	return {}


func clip(id: String) -> Dictionary:
	var building := building_definition()
	var clips: Dictionary = building.get("clips", manifest.get("clips", {})) as Dictionary
	return clips.get(id, {}) as Dictionary


func definition(id: String) -> Dictionary:
	var layer_definition := layer(id)
	if not layer_definition.is_empty():
		return layer_definition
	var clip_definition := clip(id)
	if not clip_definition.is_empty():
		return clip_definition
	return manifest.get(id, {}) as Dictionary


func frame_count(id: String) -> int:
	if frames.has(id):
		return (frames.get(id, []) as Array).size()
	return maxi(0, int(definition(id).get("frame_count", 0)))


func fps(id: String) -> float:
	return maxf(0.0, float(definition(id).get("fps", 0.0)))


func frame_index(id: String, elapsed: float, active: bool = true, loop: bool = true) -> int:
	var count := frame_count(id)
	if count <= 1 or not active:
		return 0
	var index := maxi(0, floori(maxf(0.0, elapsed) * fps(id)))
	return posmod(index, count) if loop else mini(index, count - 1)


func frame_texture(id: String, index: int = 0) -> Texture2D:
	var sequence: Array = frames.get(id, []) as Array
	if sequence.is_empty():
		return null
	return sequence[clampi(index, 0, sequence.size() - 1)] as Texture2D


func texture(id: String, elapsed: float = 0.0, active: bool = true) -> Texture2D:
	return frame_texture(id, frame_index(id, elapsed, active))


func layer_rect(id: String, center: Vector2, tile_pixels: float) -> Rect2:
	var definition := layer(id)
	if definition.is_empty():
		definition = layer("base")
	var building := building_definition()
	var frame_size := _vector2(definition.get("frame_size", [512, 512]), Vector2(512, 512))
	var shift := _vector2(definition.get("shift_tiles", [0, 0]), Vector2.ZERO)
	var fit := float(building.get("fit_multiplier", 1.0))
	var source_pixels_per_tile := maxf(1.0, float(building.get("source_pixels_per_tile", 64.0)))
	var source_scale := float(definition.get("source_scale", 1.0))
	var draw_size := frame_size * source_scale * fit * tile_pixels / source_pixels_per_tile
	return Rect2(center + shift * fit * tile_pixels - draw_size * 0.5, draw_size)


func _load_definition(id: String, definition: Dictionary) -> void:
	if id.is_empty() or definition.is_empty():
		errors.append("Missing definition: %s" % id)
		return
	var textures: Array[Texture2D] = []
	if definition.has("textures"):
		for path_value in definition.get("textures", []):
			var frame := _load_texture(str(path_value))
			if frame == null:
				errors.append("Missing frame: %s" % str(path_value))
				return
			textures.append(frame)
		frames[id] = textures
		return
	var path := str(definition.get("texture", ""))
	var source := _load_texture(path)
	if source == null:
		errors.append("Missing texture: %s" % (path if not path.is_empty() else id))
		return
	if not definition.has("frame_size") or int(definition.get("frame_count", 1)) <= 1:
		frames[id] = [source]
		return
	var source_image := source.get_image()
	if source_image == null or source_image.is_empty():
		errors.append("Unreadable atlas: %s" % path)
		return
	if source_image.is_compressed():
		source_image.decompress()
	var frame_size := _vector2i(definition.get("frame_size", [512, 512]), Vector2i(512, 512))
	var columns := maxi(1, int(definition.get("columns", 1)))
	for index in range(maxi(1, int(definition.get("frame_count", 1)))):
		var region := Rect2i(Vector2i(index % columns, index / columns) * frame_size, frame_size)
		if not Rect2i(Vector2i.ZERO, source_image.get_size()).encloses(region):
			errors.append("Out-of-bounds frame: %s/%d" % [id, index])
			return
		var image := source_image.get_region(region)
		image.generate_mipmaps()
		textures.append(ImageTexture.create_from_image(image))
	frames[id] = textures


func _load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _texture_cache.has(path):
		return _texture_cache.get(path) as Texture2D
	var texture := load(path) as Texture2D
	if texture == null:
		return null
	var image := texture.get_image()
	if image == null or image.is_empty():
		_texture_cache[path] = texture
		return texture
	if image.is_compressed():
		image.decompress()
	image.generate_mipmaps()
	var prepared := ImageTexture.create_from_image(image)
	_texture_cache[path] = prepared
	return prepared


func _vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Array and (value as Array).size() >= 2:
		var array := value as Array
		return Vector2(float(array[0]), float(array[1]))
	return fallback


func _vector2i(value: Variant, fallback: Vector2i) -> Vector2i:
	var vector := _vector2(value, Vector2(float(fallback.x), float(fallback.y)))
	return Vector2i(maxi(1, roundi(vector.x)), maxi(1, roundi(vector.y)))
