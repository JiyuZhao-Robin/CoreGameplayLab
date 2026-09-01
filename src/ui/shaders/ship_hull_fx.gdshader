shader_type canvas_item;
render_mode unshaded;

uniform sampler2D base_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D fx_mask : filter_linear_mipmap;
uniform sampler2D noise_texture : filter_linear_mipmap;
uniform vec4 ship_uv_rect = vec4(0.04, 0.04, 0.92, 0.92);
uniform vec2 base_texel_size = vec2(0.001, 0.001);
uniform vec4 glow_color : source_color = vec4(0.35, 0.78, 0.80, 1.0);
uniform float flow_strength : hint_range(0.0, 0.5) = 0.075;
uniform float flow_speed : hint_range(0.0, 1.0) = 0.055;
uniform float edge_strength : hint_range(0.0, 0.5) = 0.10;
uniform float emission_strength : hint_range(0.0, 0.5) = 0.13;
uniform float scan_strength : hint_range(0.0, 0.2) = 0.028;
uniform float scan_speed : hint_range(0.0, 0.2) = 0.067;
uniform float halo_strength : hint_range(0.0, 0.5) = 0.12;
uniform float hover_amount : hint_range(0.0, 1.0) = 0.0;
uniform float selection_amount : hint_range(0.0, 1.0) = 0.0;
uniform float connection_activity : hint_range(0.0, 1.0) = 0.0;
uniform float lod_amount : hint_range(0.0, 1.0) = 1.0;

float inside_uv(vec2 uv) {
	return step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
}

vec4 base_at(vec2 uv) {
	return texture(base_texture, clamp(uv, vec2(0.0), vec2(1.0))) * inside_uv(uv);
}

float alpha_at(vec2 uv) {
	return base_at(uv).a;
}

float surrounding_alpha(vec2 uv, vec2 radius) {
	float value = 0.0;
	value = max(value, alpha_at(uv + vec2(radius.x, 0.0)));
	value = max(value, alpha_at(uv - vec2(radius.x, 0.0)));
	value = max(value, alpha_at(uv + vec2(0.0, radius.y)));
	value = max(value, alpha_at(uv - vec2(0.0, radius.y)));
	value = max(value, alpha_at(uv + radius));
	value = max(value, alpha_at(uv - radius));
	value = max(value, alpha_at(uv + vec2(radius.x, -radius.y)));
	value = max(value, alpha_at(uv + vec2(-radius.x, radius.y)));
	return value;
}

void fragment() {
	vec2 ship_uv = (UV - ship_uv_rect.xy) / ship_uv_rect.zw;
	float bounded = inside_uv(ship_uv);
	vec4 base = base_at(ship_uv);
	vec4 mask = texture(fx_mask, clamp(ship_uv, vec2(0.0), vec2(1.0))) * bounded;

	vec2 near_radius = base_texel_size * 6.0;
	vec2 far_radius = base_texel_size * 18.0;
	float near_alpha = surrounding_alpha(ship_uv, near_radius);
	float far_alpha = surrounding_alpha(ship_uv, far_radius);
	float near_halo = max(near_alpha - base.a, 0.0);
	float far_halo = max(far_alpha - max(near_alpha, base.a), 0.0);

	vec2 flow_uv_a = fract(ship_uv * vec2(2.1, 4.7) + vec2(TIME * flow_speed * 0.013, -TIME * flow_speed * 0.021));
	vec2 flow_uv_b = fract(ship_uv * vec2(5.3, 2.4) + vec2(-TIME * flow_speed * 0.009, TIME * flow_speed * 0.017));
	float noise_a = texture(noise_texture, flow_uv_a).r;
	float noise_b = texture(noise_texture, flow_uv_b).r;
	float slow_variation = smoothstep(0.30, 0.78, noise_a * 0.58 + noise_b * 0.42);
	float vertical_drift = 0.72 + 0.28 * sin((ship_uv.y * 5.0 + noise_b * 0.85) - TIME * flow_speed * 0.37);
	float flow = mask.r * slow_variation * vertical_drift * flow_strength * lod_amount;

	float irregular = 0.68 + noise_a * 0.18 + noise_b * 0.10 + sin(TIME * 0.41 + noise_a * 7.0) * 0.04;
	float emission = mask.b * irregular * emission_strength * mix(0.55, 1.0, lod_amount);
	float scan_center = fract(TIME * scan_speed + 0.37);
	float scan_distance = abs(ship_uv.y - scan_center);
	float scan_band = (1.0 - smoothstep(0.0, 0.075, scan_distance)) * mask.a * scan_strength * lod_amount;
	float edge = mask.g * edge_strength * (0.72 + hover_amount * 0.18 + selection_amount * 0.24);
	float interaction = connection_activity * mask.g * 0.018;

	vec3 hull_rgb = base.rgb;
	hull_rgb += glow_color.rgb * base.a * (flow + edge + emission + scan_band + interaction);
	hull_rgb += glow_color.rgb * base.a * (hover_amount * 0.010 + selection_amount * 0.015);
	float halo_alpha = (near_halo * 0.085 + far_halo * 0.025) * halo_strength * (1.0 + hover_amount * 0.20 + selection_amount * 0.25);
	vec3 output_rgb = mix(glow_color.rgb, hull_rgb, base.a);
	COLOR = vec4(output_rgb, max(base.a, halo_alpha));
}
