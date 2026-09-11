extends SceneTree

## Offline derivative builder. Original Hurricane pixels remain in the pinned
## reference pack; production loads small, isolated frames rather than atlases.
const SOURCE := "res://assets/art_calibration/reference_miners/core/"
const OUTPUT := "res://assets/ui/factory/miner/core_extractor/"
const FRAME_SIZE := 256
const COUNT := 120
var failed := false


func _initialize() -> void:
	call_deferred("_build")


func _build() -> void:
	var game := root.get_node_or_null("Game")
	if game != null:
		game.set_process(false)
		game.persistence_enabled = false
	if not _validate_pinned_sources():
		quit(1)
		return
	var manifest := {
		"schema_version":1, "frame_count":COUNT, "fps":30,
		"frame_size":[FRAME_SIZE, FRAME_SIZE], "shadow_to_body_scale":1400.0 / 704.0,
		"layers":{"body":{"textures":[]}, "emission":{"textures":[]}, "working":{"textures":[]}},
		"files":{}, "provenance":{
			"artist":"Hurricane046", "license":"CC BY (version not specified in source metadata)",
			"selection":"res://assets/art_calibration/reference_miners/selection.json",
			"layout":"res://assets/art_calibration/reference_miners/evidence/core-layout-source.json",
			"attribution":"res://assets/ui/factory/miner/core_extractor/ATTRIBUTION.md",
			"generator":"res://tools/build_core_extractor_factory_art.gd",
			"generator_sha256":FileAccess.get_sha256("res://tools/build_core_extractor_factory_art.gd"),
			"processing":"704px frames cropped in source order (64+56), Lanczos reduced to 256px. Working RGB is alpha-weighted body + additive emission, clamped; body alpha is preserved because the source emission is opaque black outside the machine. Shadow reduced 1400px to 512px, with original 1400/704 spatial ratio. Independent mipmapped frames. No AI generation, recoloring, or gameplay footprint change.",
			"sources":{}
		}
	}
	for layer in ["body", "emission", "working"]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT + layer))
	var frame_index := 0
	for page in range(1, 3):
		var body_path := SOURCE + "core-extractor-hr-animation-%d.png" % page
		var glow_path := SOURCE + "core-extractor-hr-emission-%d.png" % page
		var body := Image.load_from_file(ProjectSettings.globalize_path(body_path))
		var glow := Image.load_from_file(ProjectSettings.globalize_path(glow_path))
		if body == null or glow == null:
			push_error("Missing pinned Core Extractor source page")
			quit(1)
			return
		manifest.provenance.sources[body_path] = FileAccess.get_sha256(body_path)
		manifest.provenance.sources[glow_path] = FileAccess.get_sha256(glow_path)
		for local_frame in range(64 if page == 1 else 56):
			var region := Rect2i((local_frame % 8) * 704, (local_frame / 8) * 704, 704, 704)
			var base := body.get_region(region)
			var emission := glow.get_region(region)
			base.resize(FRAME_SIZE, FRAME_SIZE, Image.INTERPOLATE_LANCZOS)
			emission.resize(FRAME_SIZE, FRAME_SIZE, Image.INTERPOLATE_LANCZOS)
			base.convert(Image.FORMAT_RGBA8)
			emission.convert(Image.FORMAT_RGBA8)
			var lit := _add_emission(base, emission)
			var images := {"body":base, "emission":emission, "working":lit}
			for layer in images:
				var path := OUTPUT + "%s/%04d.png" % [layer, frame_index]
				_write_image(images[layer], path, manifest)
				manifest.layers[layer].textures.append(path)
			frame_index += 1
		print("Core Extractor: prepared %d / 120 frames" % frame_index)
	var shadow_path := SOURCE + "core-extractor-hr-shadow.png"
	var shadow := Image.load_from_file(ProjectSettings.globalize_path(shadow_path))
	if shadow == null:
		quit(1)
		return
	manifest.provenance.sources[shadow_path] = FileAccess.get_sha256(shadow_path)
	shadow.resize(512, 512, Image.INTERPOLATE_LANCZOS)
	_write_image(shadow, OUTPUT + "shadow.png", manifest)
	manifest.layers["shadow"] = {"texture":OUTPUT + "shadow.png"}
	var file := FileAccess.open(OUTPUT + "manifest.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(manifest, "\t") + "\n")
	file.close()
	print("PASS: prepared Core Extractor production frames, shadow, hashes and provenance" if not failed else "FAIL: frame preparation")
	quit(1 if failed else 0)


func _validate_pinned_sources() -> bool:
	var selection: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://assets/art_calibration/reference_miners/selection.json"))
	if not selection is Dictionary:
		push_error("Missing pinned reference selection")
		return false
	var checked := 0
	for row in selection.get("files", []):
		var destination := str(row.get("destination", ""))
		if not destination.begins_with("core/"):
			continue
		var path := "res://assets/art_calibration/reference_miners/" + destination
		if FileAccess.get_sha256(path) != str(row.get("sha256", "")):
			push_error("Refusing to overwrite derivatives: pinned source mismatch " + path)
			return false
		var source := Image.load_from_file(ProjectSettings.globalize_path(path))
		var expected := Vector2i(1400,1400) if "shadow" in destination else Vector2i(5632,4928 if "-2.png" in destination else 5632)
		if source == null or source.get_size() != expected:
			push_error("Unexpected Core Extractor source sheet dimensions " + path)
			return false
		checked += 1
	return checked == 5


func _add_emission(base: Image, emission: Image) -> Image:
	var pixels := base.get_data()
	var glow := emission.get_data()
	for index in range(0, pixels.size(), 4):
		var base_alpha := float(pixels[index + 3]) / 255.0
		var glow_alpha := float(glow[index + 3]) / 255.0
		# Additive source sheets have opaque black backgrounds. Their alpha must
		# never turn the transparent machine into an opaque rectangular card.
		var alpha := base_alpha
		if alpha <= 0.0:
			continue
		for channel in range(3):
			pixels[index + channel] = mini(255, roundi((pixels[index + channel] * base_alpha + glow[index + channel] * glow_alpha) / alpha))
		pixels[index + 3] = roundi(alpha * 255.0)
	return Image.create_from_data(FRAME_SIZE, FRAME_SIZE, false, Image.FORMAT_RGBA8, pixels)


func _write_image(image: Image, path: String, manifest: Dictionary) -> void:
	if image.save_png(path) != OK:
		failed = true
		push_error("Could not write " + path)
		return
	manifest.files[path] = FileAccess.get_sha256(path)
	# Preseed importer settings so each standalone frame has its own mip chain.
	var import_config := ConfigFile.new()
	if FileAccess.file_exists(path + ".import"):
		import_config.load(path + ".import")
	import_config.set_value("remap", "importer", "texture")
	import_config.set_value("remap", "type", "CompressedTexture2D")
	import_config.set_value("deps", "source_file", path)
	import_config.set_value("params", "mipmaps/generate", true)
	import_config.set_value("params", "compress/mode", 0)
	import_config.save(path + ".import")
