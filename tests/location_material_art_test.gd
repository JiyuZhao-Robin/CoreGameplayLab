extends SceneTree

const MaterialArt = preload("res://src/ui/workspaces/location/location_item_icon.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game: Node = root.get_node("Game")
	game.persistence_enabled = false
	game.reset_game()
	game.set_process(false)
	var atlas := MaterialArt.atlas_texture()
	_check(atlas != null and atlas.resource_path == MaterialArt.ATLAS_PATH, "runtime uses the generated project asset rather than placeholder shapes")
	var pixels := atlas.get_image() if atlas != null else null
	_check(pixels != null and not pixels.is_empty() and pixels.detect_alpha() != Image.ALPHA_NONE, "generated atlas preserves genuine alpha for the water level to show behind each sprite")
	if atlas != null and pixels != null:
		_check(is_equal_approx(float(pixels.get_width()) / pixels.get_height(), 2.0) and pixels.get_pixel(0, 0).a < 0.01, "transparent 8 by 4 atlas has square cells and no opaque background")
		var cell := atlas.get_size() / Vector2(8, 4)
		for index in 32:
			var occupied := 0
			for y in range(1, 7):
				for x in range(1, 7):
					var point := Vector2(index % 8, floori(float(index) / 8)) * cell + cell * Vector2(x, y) / 8.0
					if pixels.get_pixel(int(point.x), int(point.y)).a > 0.2:
						occupied += 1
			_check(occupied > 2, "generated atlas cell %d contains real material artwork" % index)
	for item_id in game.content.items:
		var texture := MaterialArt.texture_for_item(str(item_id)) as AtlasTexture
		_check(MaterialArt.icon_index(str(item_id)) != MaterialArt.UNKNOWN_INDEX and texture != null, "known content material %s has an explicit art mapping" % item_id)
		if texture != null:
			_check(texture.atlas == atlas and Rect2(Vector2.ZERO, atlas.get_size()).encloses(texture.region), "material sprite shares the single atlas and stays inside its bounds")
	_check(MaterialArt.icon_index("survey_unknown") == 31 and MaterialArt.icon_index("unrecognized_mod_item") == 31, "unknown resources use only the generic scanner sprite")
	_check(MaterialArt.texture_for_item("iron_ore") == MaterialArt.texture_for_item("iron_ore"), "repeated render refresh reuses cached sprite resources")
	var seen := {}
	for row in game.location_operations_snapshot("earth_orbit").get("inventory", []):
		var index := MaterialArt.icon_index(str(row["id"]))
		_check(not seen.has(index), "starter material %s has a distinct visible sprite" % row["id"])
		seen[index] = true
	for failure in failures:
		push_error(failure)
	print("LOCATION_MATERIAL_ART_PASS" if failures.is_empty() else "LOCATION_MATERIAL_ART_FAIL")
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
