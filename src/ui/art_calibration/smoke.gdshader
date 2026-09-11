shader_type canvas_item;
render_mode unshaded;

// Display calibration only: neutralize the source's blue/green effect tint.
// The original 30 PNGs and the source-color swatch remain unchanged.
varying vec4 vertex_color;
void vertex() {
	vertex_color = COLOR;
}
void fragment() {
	vec4 source = texture(TEXTURE, UV);
	float luminance = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
	COLOR = vec4(vec3(luminance), source.a) * vertex_color;
}
