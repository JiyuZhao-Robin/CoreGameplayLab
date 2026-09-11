shader_type canvas_item;
render_mode unshaded;

// Semantic masks come from FactoryTerrain, including a neighbour halo. The
// photographs use continuous world coordinates, independent of chunk and LOD.
uniform sampler2D terrain_mask : filter_linear, repeat_disable;
uniform bool earth_surface = false;
uniform sampler2D surface_fields : filter_linear, repeat_disable;
uniform sampler2D rock_field : filter_linear, repeat_disable;
uniform sampler2D soil_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D grass_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 chunk_origin;
uniform float cell_step = 1.0;
uniform float mask_edge = 18.0;
varying vec2 tile_position;
varying vec2 mask_uv;

void vertex() {
	tile_position = VERTEX + chunk_origin;
	mask_uv = (VERTEX / cell_step + vec2(1.0)) / mask_edge;
}

float hash_point(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float broad_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash_point(i), hash_point(i + vec2(1.0, 0.0)), f.x),
		mix(hash_point(i + vec2(0.0, 1.0)), hash_point(i + vec2(1.0)), f.x), f.y);
}

vec3 restrained(vec3 source, vec3 tone, float saturation, float exposure) {
	float luminance = dot(source, vec3(0.2126, 0.7152, 0.0722));
	return mix(vec3(luminance), source, saturation) * tone * exposure;
}

// Small rock-face bump lighting adds surface relief without moving the
// authoritative shoreline, mountain boundary or placement grid.
float stone_relief(vec2 p) {
	return broad_noise(p / 4.1) * 0.022 + broad_noise(p / 1.45) * 0.007;
}

vec3 earth_ground(vec2 p, vec4 semantic, vec3 soil, vec3 grass, vec3 sand, vec3 rock) {
	vec4 field = texture(surface_fields, mask_uv);
	float exposed_rock = texture(rock_field, mask_uv).r;
	float elevation = field.r;
	float moisture = field.g;
	float density = field.b;
	float depth = field.a;
	// Half-texel differences stay inside the halo on both sides of a seam.
	vec2 delta = vec2(0.5 / mask_edge, 0.0);
	float dx = (texture(surface_fields, mask_uv + delta).r - texture(surface_fields, mask_uv - delta).r) / cell_step;
	float dy = (texture(surface_fields, mask_uv + delta.yx).r - texture(surface_fields, mask_uv - delta.yx).r) / cell_step;
	float bump = smoothstep(0.18, 0.75, exposed_rock);
	dx += (stone_relief(p + vec2(0.5, 0.0)) - stone_relief(p - vec2(0.5, 0.0))) * bump;
	dy += (stone_relief(p + vec2(0.0, 0.5)) - stone_relief(p - vec2(0.0, 0.5))) * bump;
	float relief_scale = mix(28.0, 100.0, smoothstep(0.06, 0.55, exposed_rock));
	vec3 normal = normalize(vec3(-dx * relief_scale, -dy * relief_scale, 1.0));
	float illumination = 0.36 + max(0.0, dot(normal, normalize(vec3(-0.6, -0.8, 0.78)))) * 0.94;
	float meadow = broad_noise(p / 12.0) * 0.6 + broad_noise(p / 4.7) * 0.4;
	float detail = broad_noise(p * 1.8);
	float grass_luma = dot(grass, vec3(0.299, 0.587, 0.114));
	vec3 dry_meadow = mix(vec3(0.29, 0.31, 0.15), vec3(0.40, 0.39, 0.22), meadow);
	vec3 wet_meadow = mix(vec3(0.19, 0.29, 0.12), vec3(0.29, 0.37, 0.17), meadow);
	vec3 ground = mix(dry_meadow, wet_meadow, smoothstep(0.25, 0.75, moisture));
	ground *= 0.68 + grass_luma * 0.86 + detail * 0.08;
	vec3 earth = restrained(soil, vec3(1.06, 1.0, 0.80), 0.35, 0.82);
	ground = mix(ground, earth, smoothstep(0.72, 0.94, meadow) * 0.30);
	ground = mix(ground, ground * vec3(0.65, 0.75, 0.58), density * 0.48);
	vec3 gravel = restrained(rock, vec3(0.97, 1.0, 0.94), 0.24, 0.96);
	float crags = smoothstep(0.24, 0.78, exposed_rock + semantic.a * 0.35);
	float stone_detail = broad_noise(p / 1.7) * 0.08;
	vec3 stone = mix(gravel, vec3(0.38, 0.39, 0.355), 0.42) * (0.87 + stone_detail + broad_noise(p / 6.3) * 0.15);
	// Strata follow sampled height, so mountain form remains authoritative.
	stone *= 0.95 + smoothstep(0.25, 0.75, sin(elevation * 155.0 + broad_noise(p / 3.0) * 2.0) * 0.5 + 0.5) * 0.10;
	ground = mix(ground, stone, crags);
	vec3 beach = restrained(sand, vec3(1.10, 1.04, 0.87), 0.42, 1.0);
	ground = mix(ground, beach, smoothstep(0.08, 0.80, semantic.g));
	float water_cover = smoothstep(0.12, 0.82, semantic.b);
	float shore = smoothstep(0.015, 0.30, semantic.b) * (1.0 - smoothstep(0.40, 0.80, semantic.b));
	ground = mix(ground, mix(beach, gravel, 0.24), shore * 0.85);
	ground *= mix(illumination, 1.0, water_cover);
	vec3 water_color = mix(vec3(0.13, 0.32, 0.31), vec3(0.035, 0.11, 0.17), smoothstep(0.015, 0.48, depth));
	float ripple = sin(p.x * 1.2 + sin(p.y * 0.45) * 1.7) * sin(p.y * 0.52 + p.x * 0.18);
	water_color += ripple * 0.007 + broad_noise(p / 7.0) * 0.008;
	water_color = mix(water_color, beach * vec3(0.50, 0.65, 0.64), (1.0 - smoothstep(0.0, 0.035, depth)) * 0.28);
	return mix(ground, water_color, water_cover);
}

void fragment() {
	vec4 semantic = texture(terrain_mask, mask_uv);
	// Sharpen the middle of a blend, retaining a narrow, continuous shoreline.
	vec4 weights = smoothstep(vec4(0.05), vec4(0.95), semantic);
	float plain = max(0.0, 1.0 - dot(semantic, vec4(1.0)));
	float total = max(0.001, plain + dot(weights, vec4(1.0)));
	vec2 p = tile_position;
	vec3 soil = texture(soil_texture, p / 64.0).rgb;
	vec3 grass = texture(grass_texture, p / 83.0 + vec2(0.27, 0.13)).rgb;
	vec3 sand = texture(sand_texture, p / 57.0).rgb;
	vec3 rock = texture(rock_texture, p / 43.0).rgb;
	float macro = broad_noise(p / 31.0);
	// Two incommensurate material spans break the conspicuous mirrored carpet.
	vec3 plain_ground = mix(restrained(soil, vec3(1.04, 1.0, 0.92), 0.38, 0.79),
		restrained(grass, vec3(0.94, 1.0, 0.91), 0.46, 0.68), 0.15 + macro * 0.32);
	vec3 forest = restrained(grass, vec3(0.82, 0.96, 0.77), 0.58, 0.65);
	vec3 desert = restrained(sand, vec3(1.07, 1.0, 0.86), 0.55, 0.90);
	vec3 mountain = restrained(rock, vec3(0.88, 0.94, 0.97), 0.22, 0.79);
	// Water is intentionally calm: no TIME uniform, no hidden animation clock.
	float ripple = sin(p.x * 0.84 + sin(p.y * 0.30) * 2.0) * 0.008;
	vec3 water = mix(vec3(0.095, 0.19, 0.205), vec3(0.055, 0.125, 0.145),
		clamp(semantic.b * 0.77 + macro * 0.23, 0.0, 1.0)) + ripple;
	vec3 result = (plain_ground * plain + forest * weights.r + desert * weights.g
		+ water * weights.b + mountain * weights.a) / total;
	float shore = 4.0 * semantic.b * (1.0 - semantic.b);
	float cliff = 4.0 * semantic.a * (1.0 - semantic.a);
	result *= 1.0 - shore * 0.20 - cliff * 0.24;
	COLOR = vec4(result * (0.96 + macro * 0.08), 1.0);
	if (earth_surface) {
		COLOR = vec4(earth_ground(p, semantic, soil, grass, sand, rock), 1.0);
	}
}
