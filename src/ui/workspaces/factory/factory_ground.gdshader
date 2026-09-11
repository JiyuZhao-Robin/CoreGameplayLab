shader_type canvas_item;
render_mode unshaded;

// Semantic masks come from FactoryTerrain, including a neighbour halo. The
// photographs use continuous world coordinates, independent of chunk and LOD.
uniform sampler2D terrain_mask : filter_linear, repeat_disable;
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
}
