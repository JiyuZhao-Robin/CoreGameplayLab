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
		# Materials and buildings now use several project-local art packs;
		# authored family aliases may intentionally share the same sprite.
		_check(texture != null and texture != MaterialArt.texture_for_item("unrecognized_mod_item"), "known content item %s has artwork instead of the unknown fallback" % item_id)
		if texture != null and texture.atlas != null:
			_check(texture.region.has_area() and Rect2(Vector2.ZERO, texture.atlas.get_size()).encloses(texture.region), "item %s stays inside its own art atlas" % item_id)
			if texture.atlas is ImageTexture:
				# Approved animation adapters may build mipmaps from local frames.
				var definition_id := str(item_id).trim_prefix("building_")
				var approved := MaterialArt.BuildingArt.uses_arc_furnace(definition_id) or not MaterialArt.BuildingArt.industry_family(definition_id).is_empty()
				_check(approved and texture.atlas.get_image().has_mipmaps(), "item %s uses the approved mipmapped frame" % item_id)
			else:
				_check(texture.atlas.resource_path.begins_with("res://"), "item %s uses project-local artwork" % item_id)
			_check(texture == MaterialArt.texture_for_item(str(item_id)), "item %s reuses its cached sprite" % item_id)
		else:
			_check(false, "item %s has a usable atlas" % item_id)
	_check(MaterialArt.icon_index("survey_unknown") == 31 and MaterialArt.icon_index("unrecognized_mod_item") == 31, "unknown resources use only the generic scanner sprite")
	_check(MaterialArt.texture_for_item("iron_ore") == MaterialArt.texture_for_item("iron_ore"), "repeated render refresh reuses cached sprite resources")
	var seen := {}
	for item_id in ["iron_ore", "copper_ore", "iron_ingot", "copper_ingot"]:
		var texture := MaterialArt.texture_for_item(item_id) as AtlasTexture
		if texture == null or texture.atlas == null:
			continue
		var sprite_key := "%s:%s" % [texture.atlas.resource_path, texture.region]
		_check(not seen.has(sprite_key), "basic material %s has a distinct visible sprite" % item_id)
		seen[sprite_key] = true
	for failure in failures:
		push_error(failure)
	print("LOCATION_MATERIAL_ART_PASS" if failures.is_empty() else "LOCATION_MATERIAL_ART_FAIL")
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
