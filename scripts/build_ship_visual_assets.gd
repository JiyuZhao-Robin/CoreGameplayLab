extends SceneTree


func _init() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() != 4:
		_fail("usage: -- INPUT BASE_PNG FX_MASK_PNG NOISE_PNG")
		return
	var source := Image.load_from_file(arguments[0])
	if source == null or source.is_empty():
		_fail("could not load %s" % arguments[0])
		return
	source.convert(Image.FORMAT_RGBA8)
	var base := _extract_alpha_and_trim(source, 2048)
	if base.is_empty():
		_fail("no foreground silhouette was detected")
		return
	for output_path in [arguments[1], arguments[2], arguments[3]]:
		DirAccess.make_dir_recursive_absolute(String(output_path).get_base_dir())
	if base.save_png(arguments[1]) != OK:
		_fail("could not save %s" % arguments[1])
		return
	var mask := _build_mask(base)
	if mask.save_png(arguments[2]) != OK:
		_fail("could not save %s" % arguments[2])
		return
	var noise := _build_noise(64)
	if noise.save_png(arguments[3]) != OK:
		_fail("could not save %s" % arguments[3])
		return
	print("SHIP_VISUAL_ASSETS_READY %dx%d" % [base.get_width(), base.get_height()])
	quit(0)


func _extract_alpha_and_trim(source: Image, long_edge: int) -> Image:
	var result := Image.create(source.get_width(), source.get_height(), false, Image.FORMAT_RGBA8)
	var minimum := Vector2i(source.get_width(), source.get_height())
	var maximum := Vector2i(-1, -1)
	for y in source.get_height():
		for x in source.get_width():
			var pixel := source.get_pixel(x, y)
			var low := minf(pixel.r, minf(pixel.g, pixel.b))
			var high := maxf(pixel.r, maxf(pixel.g, pixel.b))
			var chroma := high - low
			# The image generator can bake a transparency checker into RGB.
			# Neutral near-white pixels are certainly background; dark hull
			# mass and colored technical lines remain opaque.
			var alpha := maxf((0.961 - low) / 0.882, chroma / 0.322)
			if low > 0.878 and chroma < 0.051:
				alpha = 0.0
			alpha = clampf(alpha, 0.0, 1.0)
			if alpha < 0.025:
				alpha = 0.0
			var background := maxf(0.949, high)
			var foreground := Vector3(pixel.r, pixel.g, pixel.b)
			if alpha > 0.001 and alpha < 0.999:
				foreground = (foreground - Vector3.ONE * (1.0 - alpha) * background) / alpha
				foreground.x = clampf(foreground.x, 0.0, 1.0)
				foreground.y = clampf(foreground.y, 0.0, 1.0)
				foreground.z = clampf(foreground.z, 0.0, 1.0)
			result.set_pixel(x, y, Color(foreground.x, foreground.y, foreground.z, alpha))
			if alpha > 0.02:
				minimum.x = mini(minimum.x, x)
				minimum.y = mini(minimum.y, y)
				maximum.x = maxi(maximum.x, x)
				maximum.y = maxi(maximum.y, y)
	if maximum.x < minimum.x or maximum.y < minimum.y:
		return Image.new()
	var safety := 4
	minimum -= Vector2i.ONE * safety
	maximum += Vector2i.ONE * safety
	minimum.x = maxi(0, minimum.x)
	minimum.y = maxi(0, minimum.y)
	maximum.x = mini(result.get_width() - 1, maximum.x)
	maximum.y = mini(result.get_height() - 1, maximum.y)
	var cropped := result.get_region(Rect2i(minimum, maximum - minimum + Vector2i.ONE))
	var scale := float(long_edge) / float(maxi(cropped.get_width(), cropped.get_height()))
	var output_size := Vector2i(
		maxi(1, roundi(float(cropped.get_width()) * scale)),
		maxi(1, roundi(float(cropped.get_height()) * scale))
	)
	cropped.resize(output_size.x, output_size.y, Image.INTERPOLATE_LANCZOS)
	return cropped


func _build_mask(base: Image) -> Image:
	var mask := Image.create(base.get_width(), base.get_height(), false, Image.FORMAT_RGBA8)
	for y in base.get_height():
		for x in base.get_width():
			var pixel := base.get_pixel(x, y)
			if pixel.a <= 0.001:
				continue
			var luminance := pixel.get_luminance()
			var chroma := maxf(pixel.r, maxf(pixel.g, pixel.b)) - minf(pixel.r, minf(pixel.g, pixel.b))
			var neighbor_minimum := minf(
				_alpha_at(base, x - 5, y),
				minf(_alpha_at(base, x + 5, y), minf(_alpha_at(base, x, y - 5), _alpha_at(base, x, y + 5)))
			)
			var edge := maxf(0.0, pixel.a - neighbor_minimum)
			var cyan_bias := maxf(0.0, (pixel.g + pixel.b) * 0.5 - pixel.r) / 0.47
			var line_light := clampf((luminance - 0.071) / 0.353, 0.0, 1.0)
			var flow := pixel.a * minf(1.0, line_light * 0.62 + cyan_bias * 0.38)
			var structure := pixel.a * minf(1.0, edge * 0.94 + line_light * 0.22 + cyan_bias * 0.28)
			var emission := pixel.a * minf(1.0, maxf(0.0, (luminance - 0.212) / 0.455) * 0.52 + maxf(0.0, chroma - 0.11) / 0.47)
			var normalized_x := float(x) / maxf(1.0, float(base.get_width() - 1))
			var scan_region := pixel.a * (0.42 + 0.24 * (1.0 - absf(normalized_x * 2.0 - 1.0)))
			mask.set_pixel(x, y, Color(flow, structure, emission, clampf(scan_region, 0.0, 1.0)))
	return mask


func _alpha_at(image: Image, x: int, y: int) -> float:
	return image.get_pixel(clampi(x, 0, image.get_width() - 1), clampi(y, 0, image.get_height() - 1)).a


func _build_noise(side: int) -> Image:
	var noise := Image.create(side, side, false, Image.FORMAT_RGBA8)
	for y in side:
		for x in side:
			var wave := 0.50 \
				+ 0.19 * sin(float(x) * 0.29 + float(y) * 0.07) \
				+ 0.16 * sin(float(x) * 0.11 - float(y) * 0.23 + 1.7) \
				+ 0.10 * cos(float(x + y) * 0.37)
			var hash_value := float(((x * 73856093) ^ (y * 19349663) ^ ((x + y) * 83492791)) & 255) / 255.0
			var value := clampf(wave * 0.86 + hash_value * 0.14, 0.0, 1.0)
			noise.set_pixel(x, y, Color(value, value, value, 1.0))
	return noise


func _fail(message: String) -> void:
	push_error("SHIP_VISUAL_ASSET_ERROR: %s" % message)
	quit(1)
