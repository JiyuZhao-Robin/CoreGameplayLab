class_name FactoryDroneArt
extends RefCounted

## Actual licensed sprite art; presentation only, with no inventory authority.
## rect is the footprint on the canvas, not the tall rendered image bounds.
const PACK := "res://assets/ui/factory/drone_tower/"
static var _textures: Dictionary = {}
static var _frames: Dictionary = {}


static func _texture(name: String) -> Texture2D:
	if not _textures.has(name):
		var texture := load(PACK + name) as Texture2D
		_textures[name] = texture
	return _textures[name] as Texture2D


static func _frame(name: String, region: Rect2) -> AtlasTexture:
	var key := name + str(region)
	if not _frames.has(key):
		var texture := AtlasTexture.new()
		texture.atlas = _texture(name)
		texture.region = region
		texture.filter_clip = true
		_frames[key] = texture
	return _frames[key] as AtlasTexture


static func icon_texture() -> AtlasTexture:
	return _frame("tower.png", Rect2(0, 0, 240, 300))


static func body_rect(rect: Rect2) -> Rect2:
	return _layer_rect(rect, Vector2(240, 300), Vector2(0, -0.1))


static func _layer_rect(footprint: Rect2, source_size: Vector2, shift: Vector2) -> Rect2:
	# Upstream uses a 2 x 2 tile selection box, and scale 0.25: 128 source px/tile.
	var tile := minf(footprint.size.x, footprint.size.y) * 0.5
	var size := source_size * tile / 128.0
	return Rect2(footprint.get_center() + shift * tile - size * 0.5, size)


static func draw_tower(canvas: CanvasItem, rect: Rect2, tint: Color = Color.WHITE) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	canvas.draw_texture_rect(_texture("tower-shadow.png"), _layer_rect(rect, Vector2(322, 166), Vector2(0.48, 0.43)), false, tint)
	canvas.draw_texture_rect(_texture("tower.png"), body_rect(rect), false, tint)
	var frame := posmod(int(Time.get_ticks_msec() / 1000.0 * 6.0), 8)
	var region := Rect2(frame * 110.0, 0, 110, 80)
	var target := _layer_rect(rect, Vector2(110, 80), Vector2(0, -0.92))
	canvas.draw_texture_rect(_frame("tower-idle.png", region), target, false, tint)
	# Cyan light is supplied by the original author, not a generated status proxy.
	canvas.draw_texture_rect(_frame("tower-light.png", region), target, false, Color(tint.r, tint.g, tint.b, tint.a * 0.6))


static func draw_drone(canvas: CanvasItem, position: Vector2, heading: float, scale_factor: float = 1.0) -> void:
	if scale_factor <= 0.0 or not is_finite(heading):
		return
	# Canvas heading: east=0, south=PI/2. OpenHV starts at north, clockwise.
	var direction := posmod(roundi((heading + PI * 0.5) / (PI * 0.25)), 8)
	var phase := posmod(int(Time.get_ticks_msec() / 125.0), 2)
	var frame := direction * 2 + phase
	var region := Rect2(posmod(frame, 4) * 12.0, floori(frame / 4.0) * 12.0, 12, 12)
	var texture := _frame("drone.png", region)
	var size := Vector2.ONE * 18.0 * scale_factor
	# Reuse the real silhouette as a translucent projected shadow.
	canvas.draw_texture_rect(texture, Rect2(position + Vector2(3, 5) * scale_factor - size * 0.5, size), false, Color(0, 0, 0, 0.3))
	canvas.draw_texture_rect(texture, Rect2(position - size * 0.5, size), false)
