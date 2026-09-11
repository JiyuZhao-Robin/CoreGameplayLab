class_name ReferenceMiningAssets
extends RefCounted

## Runtime-only source-frame loader for the two reference miners.  Frames stay
## separate ImageTextures so the preview can scrub them without modifying any
## source art or atlas layout.

const MANIFEST := "res://assets/art_calibration/reference_miners/manifest.json"

var manifest: Dictionary = {}
var frames: Dictionary = {}
var errors: Array[String] = []

var _layers_by_id: Dictionary = {}
var _source_textures: Dictionary = {}
var _source_images: Dictionary = {}
var _cropped_frames: Dictionary = {}


func load_pack() -> void:
	manifest.clear()
	frames.clear()
	errors.clear()
	_layers_by_id.clear()
	_source_textures.clear()
	_source_images.clear()
	_cropped_frames.clear()
	if not FileAccess.file_exists(MANIFEST):
		errors.append("Missing reference miner manifest")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if not (parsed is Dictionary) or int((parsed as Dictionary).get("schema_version", 0)) != 1:
		errors.append("Invalid reference miner manifest schema")
		return
	manifest = parsed as Dictionary
	_load_environment("ground")
	_load_environment("ore")
	var candidates: Dictionary = manifest.get("candidates", {}) as Dictionary
	for candidate_value in candidates.values():
		if not (candidate_value is Dictionary):
			errors.append("Invalid candidate definition")
			continue
		var candidate := candidate_value as Dictionary
		var directions: Dictionary = candidate.get("directions", {}) as Dictionary
		for direction_value in directions.values():
			if not (direction_value is Dictionary):
				errors.append("Invalid direction definition")
				continue
			var direction := direction_value as Dictionary
			var layer_values: Array = direction.get("layers", []) as Array
			for layer_value in layer_values:
				if layer_value is Dictionary:
					_load_layer(layer_value as Dictionary)
				else:
					errors.append("Invalid layer definition")


func candidate_definition(candidate_id: String) -> Dictionary:
	var candidates: Dictionary = manifest.get("candidates", {}) as Dictionary
	return candidates.get(candidate_id, {}) as Dictionary


func directions_for(candidate_id: String) -> Array[String]:
	var result: Array[String] = []
	var directions: Dictionary = candidate_definition(candidate_id).get("directions", {}) as Dictionary
	for key in directions.keys():
		result.append(str(key))
	return result


func default_direction(candidate_id: String) -> String:
	var candidate := candidate_definition(candidate_id)
	var requested := str(candidate.get("default_direction", ""))
	var available := directions_for(candidate_id)
	if requested in available:
		return requested
	return available[0] if not available.is_empty() else ""


func layers_for(candidate_id: String, selected_direction: String) -> Array[Dictionary]:
	var candidate := candidate_definition(candidate_id)
	var directions: Dictionary = candidate.get("directions", {}) as Dictionary
	var direction: Dictionary = directions.get(selected_direction, {}) as Dictionary
	if direction.is_empty():
		direction = directions.get(default_direction(candidate_id), {}) as Dictionary
	var layer_values: Array = direction.get("layers", []) as Array
	var result: Array[Dictionary] = []
	for value in layer_values:
		if value is Dictionary:
			result.append(value as Dictionary)
	return result


func layer_definition(layer_id: String) -> Dictionary:
	return _layers_by_id.get(layer_id, {}) as Dictionary


func frame_texture(layer_id: String, index: int) -> Texture2D:
	var sequence: Array = frames.get(layer_id, []) as Array
	if index < 0 or index >= sequence.size():
		return null
	return sequence[index] as Texture2D


func texture_frame(layer: Dictionary, elapsed_seconds: float) -> Texture2D:
	var layer_id := str(layer.get("id", ""))
	var sequence: Array = frames.get(layer_id, []) as Array
	if sequence.is_empty():
		return null
	var frame_sequence: Array = layer.get("frame_sequence", []) as Array
	var frame_count := frame_sequence.size() if not frame_sequence.is_empty() else maxi(1, mini(int(layer.get("frame_count", sequence.size())), sequence.size()))
	var fps := float(layer.get("fps", 0.0))
	var timeline_index := 0 if fps <= 0.0 or frame_count <= 1 else posmod(floori(elapsed_seconds * fps + 0.0001), frame_count)
	var source_index := int(frame_sequence[timeline_index]) if not frame_sequence.is_empty() else timeline_index
	return frame_texture(layer_id, source_index)


func texture(id: String, elapsed_seconds: float = 0.0) -> Texture2D:
	if id in ["ground", "ore"]:
		return frame_texture(id, 0)
	return texture_frame(layer_definition(id), elapsed_seconds)


func layer_rect(candidate_id: String, layer: Dictionary, center: Vector2, tile_pixels: float) -> Rect2:
	var candidate := candidate_definition(candidate_id)
	var frame_value: Array = layer.get("frame_size", [1, 1]) as Array
	var frame_size := Vector2(float(frame_value[0]), float(frame_value[1]))
	var shift_value: Array = layer.get("shift_tiles", [0, 0]) as Array
	var shift := Vector2(float(shift_value[0]), float(shift_value[1]))
	var fit := float(candidate.get("fit_multiplier", 1.0))
	var pixels_per_tile := maxf(1.0, float(candidate.get("source_pixels_per_tile", 32.0)))
	var source_scale := float(layer.get("source_scale", 1.0))
	var rendered_size := frame_size * source_scale * fit * tile_pixels / pixels_per_tile
	return Rect2(center + shift * fit * tile_pixels - rendered_size * 0.5, rendered_size)


func initial_zoom(candidate_id: String) -> float:
	return clampf(float(candidate_definition(candidate_id).get("initial_zoom", 1.0)), 0.5, 2.0)


func _load_environment(id: String) -> void:
	var definition: Dictionary = manifest.get(id, {}) as Dictionary
	var path := str(definition.get("texture", ""))
	var texture := _source_texture(path)
	if texture == null:
		errors.append("Missing %s texture: %s" % [id, path])
		return
	frames[id] = [texture]


func _load_layer(layer: Dictionary) -> void:
	var layer_id := str(layer.get("id", ""))
	if layer_id.is_empty():
		errors.append("Layer has no id")
		return
	if _layers_by_id.has(layer_id):
		return
	_layers_by_id[layer_id] = layer
	var frame_size_value: Array = layer.get("frame_size", []) as Array
	if frame_size_value.size() < 2 or int(layer.get("columns", 0)) <= 0:
		errors.append("Invalid frame geometry: " + layer_id)
		return
	var frame_size := Vector2i(int(frame_size_value[0]), int(frame_size_value[1]))
	var columns := int(layer.get("columns", 1))
	var expected_count := maxi(1, int(layer.get("frame_count", 1)))
	var source_frames: Array[Texture2D] = []
	var sheets: Array = layer.get("sheets", []) as Array
	if sheets.is_empty():
		errors.append("Layer has no sheets: " + layer_id)
		return
	for sheet_value in sheets:
		if not (sheet_value is Dictionary):
			errors.append("Invalid sheet: " + layer_id)
			return
		var sheet := sheet_value as Dictionary
		var path := str(sheet.get("texture", ""))
		var source := _source_texture(path)
		var image := _source_image(path)
		if source == null or image == null:
			errors.append("Missing sheet texture: " + path)
			return
		var sheet_count := maxi(0, int(sheet.get("frame_count", 0)))
		for local_index in sheet_count:
			var region := Rect2i(Vector2i(local_index % columns, local_index / columns) * frame_size, frame_size)
			if not Rect2i(Vector2i.ZERO, image.get_size()).encloses(region):
				errors.append("Out-of-bounds frame: %s/%d" % [layer_id, local_index])
				return
			var cache_key := "%s:%d:%d:%d:%d" % [path, frame_size.x, frame_size.y, columns, local_index]
			var frame := _cropped_frames.get(cache_key, null) as Texture2D
			if frame == null:
				var cropped := image.get_region(region)
				cropped.generate_mipmaps()
				frame = ImageTexture.create_from_image(cropped)
				_cropped_frames[cache_key] = frame
			source_frames.append(frame)
	var frame_sequence: Array = layer.get("frame_sequence", []) as Array
	if not frame_sequence.is_empty():
		for source_index_value in frame_sequence:
			var source_index := int(source_index_value)
			if source_index < 0 or source_index >= source_frames.size():
				errors.append("Invalid frame sequence index: %s/%d" % [layer_id, source_index])
				return
		frames[layer_id] = source_frames
		return
	if source_frames.size() < expected_count:
		errors.append("Insufficient frames: %s (%d/%d)" % [layer_id, source_frames.size(), expected_count])
		return
	var normalized: Array[Texture2D] = []
	for index in expected_count:
		normalized.append(source_frames[index])
	frames[layer_id] = normalized


func _source_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if _source_textures.has(path):
		return _source_textures[path] as Texture2D
	var source := load(path) as Texture2D
	_source_textures[path] = source
	return source


func _source_image(path: String) -> Image:
	if path.is_empty():
		return null
	if _source_images.has(path):
		return _source_images[path] as Image
	var source := _source_texture(path)
	if source == null:
		return null
	var image := source.get_image()
	if image != null and image.is_compressed():
		image.decompress()
	_source_images[path] = image
	return image
