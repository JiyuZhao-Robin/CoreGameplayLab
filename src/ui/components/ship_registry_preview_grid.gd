extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const CELL_SIZE_AT_GOLDEN_SCALE := 22.0
const GOLDEN_SCALE := 1.5
const MAJOR_EVERY := 4


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var cell_size := float(UiTokens.full_scale_px(CELL_SIZE_AT_GOLDEN_SCALE / GOLDEN_SCALE))
	var minor_color := UiTokens.COLOR_GRID_MINOR.lerp(UiTokens.COLOR_SHIP_GRID_MINOR, 0.55)
	minor_color.a = 0.34
	var major_color := UiTokens.COLOR_GRID_MAJOR.lerp(UiTokens.COLOR_SHIP_GRID_MAJOR, 0.45)
	major_color.a = 0.42
	var vertical_count := ceili(size.x / cell_size)
	var horizontal_count := ceili(size.y / cell_size)
	for index in range(1, vertical_count):
		var x := float(index) * cell_size
		var color := major_color if index % MAJOR_EVERY == 0 else minor_color
		draw_line(Vector2(x, 0.0), Vector2(x, size.y), color, 1.0)
	for index in range(1, horizontal_count):
		var y := float(index) * cell_size
		var color := major_color if index % MAJOR_EVERY == 0 else minor_color
		draw_line(Vector2(0.0, y), Vector2(size.x, y), color, 1.0)
