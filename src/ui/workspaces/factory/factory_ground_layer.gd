extends Node2D

## One presentation layer behind the canvas. It inherits the canvas clip and
## transform; it never scales the application viewport or receives input.
var viewport_rect := Rect2()
var background := Color("151b1b")

func set_viewport_rect(value: Rect2) -> void:
	if viewport_rect != value:
		viewport_rect = value
		queue_redraw()

func _draw() -> void:
	draw_rect(viewport_rect, background)
