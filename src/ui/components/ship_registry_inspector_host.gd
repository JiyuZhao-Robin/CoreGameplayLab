extends ScrollContainer


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO


func _get_minimum_size() -> Vector2:
	# The Ship Registry lives inside the application's page ScrollContainer. Keep
	# its rich Inspector minimum local: compact viewports scroll this host while
	# the canonical and wide layouts remain a fixed, scrollbar-free workspace.
	return Vector2.ZERO
