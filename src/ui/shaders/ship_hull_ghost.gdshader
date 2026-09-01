shader_type canvas_item;
render_mode unshaded;

uniform sampler2D base_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D noise_texture : filter_linear_mipmap;
uniform vec4 ship_uv_rect = vec4(0.03, 0.03, 0.94, 0.94);
uniform vec2 base_texel_size = vec2(0.001, 0.001);
uniform vec4 ghost_color : source_color = vec4(0.32, 0.82, 0.80, 1.0);
uniform float ghost_strength : hint_range(0.0, 0.1) = 0.032;
uniform float hover_amount : hint_range(0.0, 1.0) = 0.0;
uniform float selection_amount : hint_range(0.0, 1.0) = 0.0;
uniform float lod_amount : hint_range(0.0, 1.0) = 1.0;

float inside_uv(vec2 uv) {
	return step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
}

void fragment() {
	vec2 ship_uv = (UV - ship_uv_rect.xy) / ship_uv_rect.zw;
	vec2 noise_uv = fract(ship_uv * vec2(2.4, 5.8) + vec2(TIME * 0.0017, -TIME * 0.0011));
	float noise_value = texture(noise_texture, noise_uv).r - 0.5;
	vec2 distortion = vec2(noise_value, -noise_value * 0.35) * base_texel_size * 1.4 * lod_amount;
	vec2 sample_uv = ship_uv + distortion + base_texel_size * vec2(1.4, -0.7);
	float alpha = texture(base_texture, clamp(sample_uv, vec2(0.0), vec2(1.0))).a * inside_uv(sample_uv);
	float strength = ghost_strength * (0.72 + hover_amount * 0.24 + selection_amount * 0.34);
	COLOR = vec4(ghost_color.rgb, alpha * strength);
}
