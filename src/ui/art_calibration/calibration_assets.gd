extends RefCounted

## Display-only asset definitions. Each frame gets its own mip chain in memory;
## the original, unpadded upstream atlases remain byte-identical on disk.
const MANIFEST := "res://assets/art_calibration/manifest.json"
var manifest: Dictionary = {}
var frames: Dictionary = {}
var errors: Array[String] = []

func load_pack() -> void:
	frames.clear()
	errors.clear()
	if not FileAccess.file_exists(MANIFEST):
		errors.append("Missing calibration manifest")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		errors.append("Invalid calibration manifest schema")
		return
	manifest = parsed
	for layer in manifest.building.layers:
		_load_frames(layer.id, layer)
	_load_frames("smoke", manifest.smoke)
	for id in ["ground", "ore"]:
		var texture := load(str(manifest[id].texture)) as Texture2D
		if texture == null:
			errors.append("Missing texture: " + id)
		else:
			frames[id] = [texture]

func _load_frames(id: String, definition: Dictionary) -> void:
	if definition.has("textures"):
		var sequence: Array[Texture2D] = []
		for path in definition.textures:
			var source := load(str(path)) as Texture2D
			if source == null:
				errors.append("Missing frame: " + str(path))
				return
			var frame_image := source.get_image()
			if frame_image.is_compressed():
				frame_image.decompress()
			frame_image.generate_mipmaps()
			sequence.append(ImageTexture.create_from_image(frame_image))
		frames[id] = sequence
		return
	var texture := load(str(definition.texture)) as Texture2D
	if texture == null:
		errors.append("Missing atlas: " + id)
		return
	var atlas := texture.get_image()
	if atlas.is_compressed():
		atlas.decompress()
	var textures: Array[Texture2D] = []
	var frame_size := Vector2i(int(definition.frame_size[0]), int(definition.frame_size[1]))
	var columns := int(definition.columns)
	for index in int(definition.frame_count):
		var region := Rect2i(Vector2i(index % columns, index / columns) * frame_size, frame_size)
		if not Rect2i(Vector2i.ZERO, atlas.get_size()).encloses(region):
			errors.append("Out-of-bounds frame: %s/%d" % [id, index])
			return
		var frame := atlas.get_region(region)
		frame.generate_mipmaps()
		textures.append(ImageTexture.create_from_image(frame))
	frames[id] = textures

func frame_index(id: String, elapsed: float, active: bool = true) -> int:
	var definition: Dictionary = manifest.smoke if id == "smoke" else layer(id)
	if not active or int(definition.frame_count) <= 1:
		return 0
	return posmod(int(floor(elapsed * float(definition.fps))), int(definition.frame_count))

func texture(id: String, elapsed: float = 0.0, active: bool = true) -> Texture2D:
	if not frames.has(id):
		return null
	var index := frame_index(id, elapsed, active) if id not in ["ground", "ore"] else 0
	return frames[id][index]

func layer(id: String) -> Dictionary:
	for definition in manifest.building.layers:
		if definition.id == id:
			return definition
	return {}

func layer_rect(id: String, center: Vector2, tile_pixels: float) -> Rect2:
	var definition := layer(id)
	var fit := float(manifest.building.fit_multiplier)
	var pixels_per_tile := float(manifest.building.source_pixels_per_tile)
	var frame_size := Vector2(float(definition.frame_size[0]), float(definition.frame_size[1]))
	var shift := Vector2(float(definition.shift_tiles[0]), float(definition.shift_tiles[1]))
	var size := frame_size * float(definition.source_scale) * fit * tile_pixels / pixels_per_tile
	return Rect2(center + shift * fit * tile_pixels - size * 0.5, size)
