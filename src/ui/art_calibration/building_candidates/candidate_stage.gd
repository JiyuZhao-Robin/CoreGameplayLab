extends Control

# Preview calibration is separate from the pinned source-art manifest.
# Thermal Plant's tall chimney sits above the ground footprint; its base
# reaches below the sprite origin. Keep artwork scale independent of this box.
const FOOTPRINT_CALIBRATION := {
	"thermal-plant": {"tiles": Vector2(5, 6), "center_in_base": Vector2(0.5, 0.55)},
}

var candidate: Dictionary = {}
var textures: Dictionary = {}
var elapsed := 0.0
var playing := true
var zoom := 1.0
var show_footprint := true
var emission: Control
var ground: Texture2D
var font: Font

func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	ground = load("res://assets/ui/factory/natural/ground/soil.jpg")
	font = get_theme_default_font()
	emission = Control.new()
	emission.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var light := CanvasItemMaterial.new()
	light.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	emission.material = light
	add_child(emission)
	emission.draw.connect(_draw_emission)

func set_candidate(value: Dictionary, layers: Dictionary) -> void:
	candidate = value
	textures = layers
	elapsed = 0.0
	refresh()

func _process(delta: float) -> void:
	if playing and not candidate.is_empty():
		elapsed += minf(delta, 0.1)
		refresh()

func refresh() -> void:
	queue_redraw()
	if emission != null:
		emission.queue_redraw()

func layer(id: String) -> Dictionary:
	for entry in candidate.get("layers", []):
		if entry.id == id:
			return entry
	return {}

func frame_index(id: String, active: bool = true) -> int:
	var count := int(layer(id).get("frame_count", 1))
	return posmod(int(elapsed * float(candidate.get("fps", 30))), count) if active else 0

func _center(index: int) -> Vector2:
	return Vector2(size.x * (float(index) + 0.5) / 3.0, size.y * 0.54)

func layer_rect(id: String, index: int) -> Rect2:
	var entry := layer(id)
	var base := layer("base")
	var fit := float(candidate.footprint_tiles[0]) * 32.0 / (float(base.frame_size[0]) * float(base.source_scale))
	var factor := fit * 52.0 * zoom
	var extent := Vector2(entry.frame_size[0], entry.frame_size[1]) * float(entry.source_scale) * factor / 32.0
	var shift := Vector2(entry.shift_tiles[0], entry.shift_tiles[1]) * factor
	return Rect2(_center(index) + shift - extent * 0.5, extent)

func footprint_tiles() -> Vector2:
	var calibration: Dictionary = FOOTPRINT_CALIBRATION.get(str(candidate.get("id", "")), {})
	return calibration.get("tiles", Vector2(candidate.footprint_tiles[0], candidate.footprint_tiles[1]))

func footprint_rect(index: int) -> Rect2:
	var center := _center(index)
	var calibration: Dictionary = FOOTPRINT_CALIBRATION.get(str(candidate.get("id", "")), {})
	if calibration.has("center_in_base"):
		var base := layer_rect("base", index)
		center = base.position + base.size * Vector2(calibration.center_in_base)
	var extent := footprint_tiles() * 52.0 * zoom
	return Rect2(center - extent * 0.5, extent)

func _draw_layer(target: CanvasItem, id: String, index: int) -> void:
	if not textures.has(id):
		return
	var entry := layer(id)
	var frame := frame_index(id, index == 0)
	var extent := Vector2(entry.frame_size[0], entry.frame_size[1])
	var region := Rect2(Vector2(frame % int(entry.columns), floori(float(frame) / int(entry.columns))) * extent, extent)
	var tint := Color("c49352") if id == "mask" else Color.WHITE
	if id == "shadow":
		tint.a = 0.48
	if index == 2:
		tint = Color(0.4, 1.0, 0.78, 0.5)
	target.draw_texture_rect_region(textures[id], layer_rect(id, index), region, tint)

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("151e20"))
	if ground != null:
		draw_texture_rect(ground, Rect2(Vector2.ZERO, size), false, Color(0.43, 0.46, 0.45, 1))
	for divider in [1, 2]:
		draw_line(Vector2(size.x * divider / 3.0, 0), Vector2(size.x * divider / 3.0, size.y), Color(0.8, 0.9, 0.85, 0.12), 1)
	if candidate.is_empty():
		return
	for index in 3:
		var caption: String = ["运行 / 动画", "停机 / 静态", "部署 / 幽灵预览"][index]
		var color := Color("ead9b9") if index < 2 else Color("85dfb6")
		var label_width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 23).x
		draw_string(font, Vector2(_center(index).x - label_width * 0.5, 48), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 23, color)
		if index < 2:
			_draw_layer(self, "shadow", index)
		_draw_layer(self, "base", index)
		_draw_layer(self, "mask", index)
		if show_footprint or index == 2:
			draw_rect(footprint_rect(index), Color(0.45, 0.85, 0.7, 0.45), false, 1.5)
		var tiles := footprint_tiles()
		var note := "%d × %d 格 · 预览占地" % [int(tiles.x), int(tiles.y)]
		var width := font.get_string_size(note, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		draw_string(font, Vector2(_center(index).x - width * 0.5, size.y - 40), note, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("bdc8bb"))

func _draw_emission() -> void:
	if not candidate.is_empty():
		_draw_layer(emission, "emission", 0)
