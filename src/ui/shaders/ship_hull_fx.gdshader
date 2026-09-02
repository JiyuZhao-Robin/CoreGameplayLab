shader_type canvas_item;
render_mode unshaded;

uniform sampler2D base_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D fx_mask : filter_linear_mipmap;
uniform sampler2D noise_texture : filter_linear_mipmap;
uniform vec4 ship_uv_rect = vec4(0.04, 0.04, 0.92, 0.92);
uniform vec2 base_texel_size = vec2(0.001, 0.001);
uniform vec4 glow_color : source_color = vec4(0.35, 0.78, 0.80, 1.0);
uniform float has_fx_mask : hint_range(0.0, 1.0) = 1.0;
uniform float flow_strength : hint_range(0.0, 0.5) = 0.075;
uniform float flow_speed : hint_range(0.0, 1.0) = 0.055;
uniform float flow_scale : hint_range(0.25, 4.0) = 1.0;
uniform float edge_strength : hint_range(0.0, 0.5) = 0.10;
uniform float emission_strength : hint_range(0.0, 0.5) = 0.13;
uniform float emission_variation : hint_range(0.0, 0.4) = 0.10;
uniform float scan_strength : hint_range(0.0, 0.2) = 0.028;
uniform float scan_speed : hint_range(0.0, 0.2) = 0.067;
uniform float halo_strength : hint_range(0.0, 0.5) = 0.12;
uniform float phase_seed : hint_range(0.0, 1.0) = 0.37;
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
	vec4 authored_mask = texture(fx_mask, clamp(ship_uv, vec2(0.0), vec2(1.0))) * bounded;
	float center_falloff = 1.0 - smoothstep(0.08, 0.48, distance(ship_uv, vec2(0.5, 0.58)));
	// Base-only ships retain a deliberately weak, silhouette-constrained signal.
	// A registered mask remains authoritative whenever one is available.
	vec4 generic_mask = vec4(base.a * (0.10 + center_falloff * 0.08), 0.0, base.a * center_falloff * 0.07, 0.0);
	vec4 mask = mix(generic_mask, authored_mask, has_fx_mask);

	vec2 near_radius = base_texel_size * 6.0;
	vec2 far_radius = base_texel_size * 18.0;
	vec2 wide_radius = base_texel_size * 52.0;
	float near_alpha = surrounding_alpha(ship_uv, near_radius);
	float far_alpha = surrounding_alpha(ship_uv, far_radius);
	float wide_alpha = surrounding_alpha(ship_uv, wide_radius);
	float near_halo = max(near_alpha - base.a, 0.0);
	float far_halo = max(far_alpha - base.a, 0.0);
	float wide_halo = max(wide_alpha - base.a, 0.0);

	vec2 flow_uv_a = fract(ship_uv * vec2(2.1, 4.7) * flow_scale + vec2(phase_seed, phase_seed * 0.41) + vec2(TIME * flow_speed * 0.11, -TIME * flow_speed * 0.19));
	vec2 flow_uv_b = fract(ship_uv * vec2(5.3, 2.4) * flow_scale + vec2(phase_seed * 0.23, phase_seed * 0.79) + vec2(-TIME * flow_speed * 0.07, TIME * flow_speed * 0.13));
	float noise_a = texture(noise_texture, flow_uv_a).r;
	float noise_b = texture(noise_texture, flow_uv_b).r;
	float slow_variation = smoothstep(0.34, 0.76, noise_a * 0.58 + noise_b * 0.42);
	vec2 gate_uv = fract(ship_uv * vec2(0.72, 1.34) + vec2(phase_seed * 0.67 + TIME * flow_speed * 0.58, phase_seed * 0.31 - TIME * flow_speed * 0.22));
	float regional_activity = texture(noise_texture, gate_uv).r;
	float activity_gate = smoothstep(0.44, 0.72, regional_activity * 0.62 + noise_b * 0.38);
	// This broad phase takes roughly 12–22 seconds to cross the authored
	// channels. The regional gate prevents it from reading as a global scanner.
	float progression = fract(ship_uv.y - TIME * flow_speed + phase_seed + (noise_a - 0.5) * 0.07);
	float structural_band = 1.0 - smoothstep(0.04, 0.20, abs(progression - 0.50));
	float intermittent_motion = activity_gate * mix(0.30, 1.0, structural_band);
	float flow = mask.r * slow_variation * intermittent_motion * flow_strength * lod_amount;

	vec2 emission_uv = fract(ship_uv * vec2(0.83, 1.17) + vec2(phase_seed * 0.91 + TIME * 0.019, phase_seed * 0.47 - TIME * 0.011));
	float emission_noise = texture(noise_texture, emission_uv).r;
	float irregular = 0.78 + (emission_noise - 0.5) * emission_variation * 2.0 + (noise_b - 0.5) * emission_variation * 0.55;
	float emission = mask.b * irregular * emission_strength * mix(0.55, 1.0, lod_amount);
	float reactor_noise = texture(noise_texture, fract(vec2(TIME * 0.023 + phase_seed, phase_seed * 0.63 + TIME * 0.007))).r;
	float reactor_activity = center_falloff * (mask.b * 0.24 + mask.r * 0.035) * (0.70 + reactor_noise * 0.30) * emission_strength * lod_amount;
	float scan_center = fract(TIME * scan_speed + 0.37);
	float scan_distance = abs(ship_uv.y - scan_center);
	float scan_band = (1.0 - smoothstep(0.0, 0.075, scan_distance)) * mask.a * scan_strength * lod_amount;
	float edge = mask.g * edge_strength * (0.72 + hover_amount * 0.18 + selection_amount * 0.24);
	float interaction = connection_activity * mask.g * 0.018;

	// The halo is not a static outline. Two unrelated, very slow noise fields
	// move through the expanded transparent area so the hull-colored light only
	// reveals itself after a few seconds instead of visibly "breathing".
	vec2 aura_uv_a = fract(ship_uv * vec2(1.35, 2.65) + vec2(TIME * flow_speed * 0.110, -TIME * flow_speed * 0.080));
	vec2 aura_uv_b = fract(ship_uv * vec2(3.70, 1.45) + vec2(-TIME * flow_speed * 0.060, TIME * flow_speed * 0.095));
	float aura_noise_a = texture(noise_texture, aura_uv_a).r;
	float aura_noise_b = texture(noise_texture, aura_uv_b).r;
	float aura_flow = 0.58 + smoothstep(0.24, 0.82, aura_noise_a * 0.62 + aura_noise_b * 0.38) * 0.54;
	aura_flow *= mix(0.82, 1.0, lod_amount);

	vec3 hull_rgb = base.rgb;
	hull_rgb += glow_color.rgb * base.a * (flow + edge + emission + reactor_activity + scan_band + interaction);
	hull_rgb += glow_color.rgb * base.a * (hover_amount * 0.010 + selection_amount * 0.015);
	float halo_alpha = (near_halo * 0.24 + far_halo * 0.085 + wide_halo * 0.032) * halo_strength * aura_flow * (1.0 + hover_amount * 0.20 + selection_amount * 0.25);
	vec3 aura_rgb = glow_color.rgb * (0.82 + aura_noise_b * 0.18);
	vec3 output_rgb = mix(aura_rgb, hull_rgb, base.a);
	COLOR = vec4(output_rgb, max(base.a, halo_alpha));
}
