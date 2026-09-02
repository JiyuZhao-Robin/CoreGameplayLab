shader_type canvas_item;
render_mode unshaded;

uniform vec4 interface_color : source_color = vec4(0.28, 0.78, 0.76, 1.0);
uniform float active_amount : hint_range(0.0, 1.0) = 0.0;
uniform float filled_amount : hint_range(0.0, 1.0) = 0.0;
uniform float hover_amount : hint_range(0.0, 1.0) = 0.0;
uniform float selection_amount : hint_range(0.0, 1.0) = 0.0;
uniform float phase_offset : hint_range(0.0, 1.0) = 0.0;
uniform float sweep_period : hint_range(6.0, 12.0) = 8.5;
uniform float arrival_amount : hint_range(0.0, 1.0) = 0.0;
uniform float arrival_strength : hint_range(0.0, 1.0) = 0.0;

float hash11(float value) {
	return fract(sin(value * 127.17 + 31.73) * 43758.5453);
}

float value_noise(float value) {
	float base = floor(value);
	float blend = fract(value);
	blend = blend * blend * (3.0 - 2.0 * blend);
	return mix(hash11(base), hash11(base + 1.0), blend);
}

float ring_mask(float radius, float target, float width, float antialias) {
	return 1.0 - smoothstep(width, width + antialias, abs(radius - target));
}

void fragment() {
	vec2 point = UV - vec2(0.5);
	float radius = length(point);
	float antialias = max(fwidth(radius) * 1.35, 0.0025);
	float focus = 1.0 + hover_amount * 0.15 + selection_amount * 0.22;

	// A narrow highlight segment makes one restrained circuit every 6–12s.
	float outer_ring = ring_mask(radius, 0.365, 0.012, antialias);
	float angle = fract(atan(point.y, point.x) / 6.28318530718 + 0.5);
	float sweep_position = fract(TIME / max(sweep_period, 0.01) + phase_offset);
	float angular_distance = abs(fract(angle - sweep_position + 0.5) - 0.5);
	float sweep_segment = 1.0 - smoothstep(0.018, 0.060, angular_distance);
	float sweep_alpha = outer_ring * sweep_segment * active_amount * 0.24 * focus;
	float live_ring_alpha = outer_ring * active_amount * (0.018 + selection_amount * 0.020);

	// Two incommensurate, interpolated noise bands create a 5–12% irregular
	// core fluctuation without the visual signature of a breathing sine wave.
	float slow_noise = value_noise(TIME * 0.27 + phase_offset * 19.0);
	float detail_noise = value_noise(TIME * 0.43 + phase_offset * 37.0 + 11.0);
	float irregular = clamp(slow_noise * 0.68 + detail_noise * 0.32, 0.0, 1.0);
	float core_mask = 1.0 - smoothstep(0.245 - antialias, 0.265 + antialias, radius);
	float core_activity = core_mask * filled_amount * active_amount;
	float core_alpha = core_activity * mix(0.048, 0.112, irregular) * focus;
	float data_kernel = (1.0 - smoothstep(0.055, 0.095, radius)) * core_activity * (0.025 + irregular * 0.035);

	// Packet/install arrival is a single short response, never a repeating pulse.
	float arrival_progress = 1.0 - arrival_amount;
	float ripple_radius = mix(0.285, 0.445, arrival_progress);
	float ripple = ring_mask(radius, ripple_radius, 0.010, antialias);
	float ripple_envelope = sin(arrival_progress * 3.14159265359) * arrival_strength;
	float ripple_alpha = ripple * ripple_envelope * 0.23;
	float arrival_core = core_mask * arrival_amount * arrival_strength * 0.18;

	float alpha = clamp(live_ring_alpha + sweep_alpha + core_alpha + data_kernel + ripple_alpha + arrival_core, 0.0, 0.42);
	vec3 light_color = mix(interface_color.rgb, vec3(1.0), 0.18 + selection_amount * 0.06);
	COLOR = vec4(light_color, alpha * interface_color.a);
}
