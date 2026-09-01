class_name ShipHullArtView
extends Control

const FLOW_GLOW_SHADER := """
shader_type canvas_item;
render_mode unshaded;

uniform vec4 glow_color : source_color = vec4(0.40, 0.76, 0.88, 1.0);
uniform float glow_strength : hint_range(0.0, 1.0) = 0.24;
uniform float flow_speed : hint_range(0.0, 2.0) = 0.18;
uniform sampler2D hull_texture : source_color, filter_linear_mipmap;
uniform vec2 hull_texel_size = vec2(0.001, 0.001);

float surrounding_alpha(vec2 uv, vec2 radius) {
	float value = 0.0;
	value = max(value, texture(hull_texture, uv + vec2(radius.x, 0.0)).a);
	value = max(value, texture(hull_texture, uv - vec2(radius.x, 0.0)).a);
	value = max(value, texture(hull_texture, uv + vec2(0.0, radius.y)).a);
	value = max(value, texture(hull_texture, uv - vec2(0.0, radius.y)).a);
	value = max(value, texture(hull_texture, uv + radius).a);
	value = max(value, texture(hull_texture, uv - radius).a);
	value = max(value, texture(hull_texture, uv + vec2(radius.x, -radius.y)).a);
	value = max(value, texture(hull_texture, uv + vec2(-radius.x, radius.y)).a);
	return value;
}

float inner_alpha(vec2 uv, vec2 radius) {
	float value = 1.0;
	value = min(value, texture(hull_texture, uv + vec2(radius.x, 0.0)).a);
	value = min(value, texture(hull_texture, uv - vec2(radius.x, 0.0)).a);
	value = min(value, texture(hull_texture, uv + vec2(0.0, radius.y)).a);
	value = min(value, texture(hull_texture, uv - vec2(0.0, radius.y)).a);
	return value;
}

void fragment() {
	vec4 hull = texture(hull_texture, UV);
	vec2 near_radius = hull_texel_size * 5.0;
	vec2 far_radius = hull_texel_size * 16.0;
	float near_alpha = surrounding_alpha(UV, near_radius);
	float far_alpha = surrounding_alpha(UV, far_radius);
	float outside_rim = max(near_alpha - hull.a, 0.0);
	float soft_halo = max(far_alpha - max(near_alpha, hull.a), 0.0);
	float inside_rim = hull.a * max(hull.a - inner_alpha(UV, near_radius), 0.0);
	float flow = 0.70 + 0.30 * sin(UV.y * 24.0 + UV.x * 7.0 - TIME * flow_speed * 6.2831853);
	vec3 lit_hull = hull.rgb + glow_color.rgb * inside_rim * glow_strength * flow;
	float halo_alpha = (outside_rim * 0.54 + soft_halo * 0.12) * glow_strength * flow;
	COLOR = vec4(lit_hull, max(hull.a, halo_alpha));
}
"""

var texture: Texture2D
var visual_spec: Dictionary = {}
var _glow_color := Color("68bdd2")
var _content_rect := Rect2()
static var _content_rect_cache := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false
	resized.connect(queue_redraw)


func configure(asset_path: String, glow_color: Color, spec: Dictionary) -> void:
	visual_spec = spec.duplicate(true)
	_glow_color = glow_color
	texture = load(asset_path) as Texture2D if not asset_path.is_empty() else null
	_content_rect = _alpha_content_rect(asset_path, texture, visual_spec.get("art_content_rect", []))
	var shader := Shader.new()
	shader.code = FLOW_GLOW_SHADER
	var shader_material := ShaderMaterial.new()
	shader_material.shader = shader
	shader_material.set_shader_parameter("hull_texture", texture)
	if texture != null:
		var texture_size := texture.get_size()
		shader_material.set_shader_parameter("hull_texel_size", Vector2(1.0 / maxf(texture_size.x, 1.0), 1.0 / maxf(texture_size.y, 1.0)))
	shader_material.set_shader_parameter("glow_color", _glow_color)
	shader_material.set_shader_parameter("glow_strength", float(visual_spec.get("glow_strength", 0.24)))
	shader_material.set_shader_parameter("flow_speed", float(visual_spec.get("flow_speed", 0.18)))
	material = shader_material
	queue_redraw()


func _draw() -> void:
	if texture == null or size.x <= 1.0 or size.y <= 1.0:
		return
	if _content_rect.size.x <= 0.0 or _content_rect.size.y <= 0.0:
		return
	var physical_size := Vector2(float(visual_spec.get("beam_m", 36.0)), float(visual_spec.get("length_m", 120.0))) * 4.0
	physical_size.x = minf(physical_size.x, maxf(1.0, size.x - 16.0))
	physical_size.y = minf(physical_size.y, maxf(1.0, size.y - 16.0))
	var scale := minf(physical_size.x / _content_rect.size.x, physical_size.y / _content_rect.size.y)
	var content_draw_size := _content_rect.size * scale
	var content_draw_position := (size - content_draw_size) * 0.5
	# Keep a transparent source gutter so the shader has pixels outside the hull
	# on which to render its weak halo, without letting authored PNG padding
	# shrink the declared physical hull dimensions.
	var texture_bounds := Rect2(Vector2.ZERO, texture.get_size())
	var source_region := _content_rect.grow(24.0).intersection(texture_bounds)
	var content_offset := (_content_rect.position - source_region.position) * scale
	var target_region := Rect2(content_draw_position - content_offset, source_region.size * scale)
	draw_texture_rect_region(texture, target_region, source_region)


static func _alpha_content_rect(asset_path: String, source_texture: Texture2D, declared_rect: Variant) -> Rect2:
	if _content_rect_cache.has(asset_path):
		return _content_rect_cache[asset_path] as Rect2
	var result := Rect2()
	if declared_rect is Array and declared_rect.size() >= 4:
		result = Rect2(float(declared_rect[0]), float(declared_rect[1]), float(declared_rect[2]), float(declared_rect[3]))
	if source_texture != null:
		if result.size.x <= 0.0 or result.size.y <= 0.0:
			var image := source_texture.get_image()
			if image != null:
				result = _threshold_alpha_rect(image, 8.0 / 255.0)
		if result.size.x <= 0.0 or result.size.y <= 0.0:
			result = Rect2(Vector2.ZERO, source_texture.get_size())
	_content_rect_cache[asset_path] = result
	return result


static func _threshold_alpha_rect(image: Image, threshold: float) -> Rect2:
	var minimum := Vector2i(image.get_width(), image.get_height())
	var maximum := Vector2i(-1, -1)
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a < threshold:
				continue
			minimum.x = mini(minimum.x, x)
			minimum.y = mini(minimum.y, y)
			maximum.x = maxi(maximum.x, x)
			maximum.y = maxi(maximum.y, y)
	if maximum.x < minimum.x or maximum.y < minimum.y:
		return Rect2()
	return Rect2(Vector2(minimum), Vector2(maximum - minimum + Vector2i.ONE))
