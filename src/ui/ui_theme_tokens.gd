class_name UiThemeTokens
extends RefCounted

# Semantic UI tokens. The base dark palette below directly maps the local
# D:\Projects\DSPONLINE\src\styles.css :root values into Godot names.
const COLOR_CANVAS := Color("090d0c")
const COLOR_PANEL := Color("111614")
const COLOR_RAISED := Color("171d1b")
const COLOR_SOFT := Color("1d2421")
const COLOR_INSET := Color("0d1311")
const COLOR_CONTROL := Color("151c19")
const COLOR_CONTROL_HOVER := Color("1b2723")
const COLOR_CONTROL_ACTIVE := Color("20332d")
const COLOR_BORDER := Color("2b3531")
const COLOR_BORDER_STRONG := Color("41504a")
const COLOR_TEXT := Color("e9eeeb")
const COLOR_TEXT_SECONDARY := Color("c1cac5")
const COLOR_TEXT_MUTED := Color("83918a")
const COLOR_FOCUS := Color("62b5ae")
const COLOR_RUNNING := Color("70bb85")
const COLOR_INFO := Color("64a8ca")
const COLOR_WARNING := Color("e1b452")
const COLOR_CRITICAL := Color("d87562")

# Orbital Industrial Operations Console semantics. These colors are shared by
# network nodes, ports, connections, diagnostics and the inspector.
const COLOR_MATERIAL := Color("65d6c1")
const COLOR_INFORMATION := Color("65a9d8")
const COLOR_ENERGY := Color("e3b35b")
const COLOR_RESEARCH := Color("9181d8")
const COLOR_INACTIVE := Color("60716a")
const COLOR_GHOST := Color("70827b")
const COLOR_GRID_MINOR := Color("17211f")
const COLOR_GRID_MAJOR := Color("22302c")
const COLOR_FACTORY_CANVAS := Color("0b100e")
const COLOR_FACTORY_GRID_DOT := Color("3c4743")
const COLOR_NODE_SURFACE := Color("131917")
const COLOR_NODE_HEADER := Color("171e1b")
const COLOR_SHIP_CANVAS := Color("08100e")
const COLOR_SHIP_GRID_MINOR := Color("18231f")
const COLOR_SHIP_GRID_MAJOR := Color("35443e")
const COLOR_SHIP_FRAME_INNER := Color("26342f")
const COLOR_SHIP_LINK_SHADOW := Color(0.0, 0.0, 0.0, 0.56)

const SPACING_XS := 4
const SPACING_SM := 8
const SPACING_MD := 12
const SPACING_LG := 16
const SPACING_XL := 24
const PANEL_PADDING := 12
const CARD_GAP := 8
const ROW_HEIGHT := 40
const RESOURCE_RAIL_WIDTH := 236
const NAV_WIDTH := RESOURCE_RAIL_WIDTH
const INSPECTOR_WIDTH := 306
const COLLAPSED_RAIL_WIDTH := 28
const COLLAPSE_BUTTON_HEIGHT := 28
const WORKSPACE_NAV_HEIGHT := 48
const TOP_BAR_HEIGHT := 68
const BOTTOM_BAR_HEIGHT := 108
const NETWORK_NODE_WIDTH := 252
const NETWORK_NODE_GAP_X := 96
const NETWORK_NODE_GAP_Y := 28
const NETWORK_GRID_MINOR_SIZE := 24
const NETWORK_GRID_MAJOR_EVERY := 5

# UI scale is deliberately separate from the project viewport and from every
# interactive graph/canvas zoom. Fonts follow the selected scale directly;
# shell geometry uses a moderated scale so the 1440x900 minimum layout remains
# operable while larger windows gain a more readable desktop UI.
const SUPPORTED_UI_SCALES := [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
const DEFAULT_UI_SCALE := 1.25
const UI_SCALE_SESSION_META := "core_gameplay_lab_ui_scale"
const SHIP_ASSEMBLY_FONT_MULTIPLIER := 1.5

static var _ui_scale := DEFAULT_UI_SCALE


static func sanitize_ui_scale(value: float) -> float:
	var normalized := value / 100.0 if value > 10.0 else value
	var closest := DEFAULT_UI_SCALE
	var closest_distance := INF
	for candidate_value in SUPPORTED_UI_SCALES:
		var candidate := float(candidate_value)
		var distance := absf(candidate - normalized)
		if distance < closest_distance:
			closest = candidate
			closest_distance = distance
	return closest


static func set_ui_scale(value: float) -> void:
	_ui_scale = sanitize_ui_scale(value)


static func ui_scale() -> float:
	return _ui_scale


static func ui_scale_percent() -> int:
	return int(round(_ui_scale * 100.0))


static func layout_scale() -> float:
	return lerpf(1.0, _ui_scale, 0.5)


static func font_size(base_size: int) -> int:
	return maxi(1, int(round(float(base_size) * _ui_scale)))


static func ship_assembly_font_size(base_size: int) -> int:
	return font_size(maxi(1, int(round(float(base_size) * SHIP_ASSEMBLY_FONT_MULTIPLIER))))


static func layout_px(base_size: float) -> int:
	return 0 if is_zero_approx(base_size) else int(round(base_size * layout_scale()))


static func layout_vector(base_size: Vector2) -> Vector2:
	return base_size * layout_scale()


static func workspace_navigation_height() -> int:
	# 100% and 125% fit one compact line once the decorative section label is
	# hidden; larger accessibility scales reserve two lines.
	return layout_px(84.0 if _ui_scale > 1.25 else float(WORKSPACE_NAV_HEIGHT))


static func panel_style(background: Color, border: Color = COLOR_BORDER, radius: int = 4) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(layout_px(radius) if radius > 0 else 0)
	return style


static func control_style(background: Color, border: Color, radius := 4) -> StyleBoxFlat:
	var style := panel_style(background, border, radius)
	style.content_margin_left = layout_px(9.0)
	style.content_margin_right = layout_px(9.0)
	style.content_margin_top = layout_px(6.0)
	style.content_margin_bottom = layout_px(6.0)
	return style


static func build_theme(scale_value: float = DEFAULT_UI_SCALE, exact_scale := false) -> Theme:
	# Production shell preferences snap to the supported manual steps. Focused
	# presentation surfaces may request an exact player-selected native scale.
	# Resolution never changes this value; fonts are rerasterized, not stretched.
	if exact_scale:
		_ui_scale = clampf(scale_value, 0.5, 4.0)
	else:
		set_ui_scale(scale_value)
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray([
		"Noto Sans CJK SC", "Microsoft YaHei UI", "Microsoft YaHei",
		"PingFang SC", "Segoe UI", "Arial Unicode MS"
	])
	var result := Theme.new()
	result.default_font = system_font
	result.default_font_size = font_size(15)
	result.set_color("font_color", "Label", COLOR_TEXT)
	result.set_color("font_color", "Button", COLOR_TEXT_SECONDARY)
	result.set_color("font_disabled_color", "Button", COLOR_TEXT_MUTED)
	result.set_color("font_focus_color", "Button", COLOR_TEXT)
	result.set_color("font_hover_color", "Button", COLOR_TEXT)
	result.set_color("font_pressed_color", "Button", COLOR_TEXT)
	result.set_stylebox("normal", "Button", control_style(COLOR_CONTROL, COLOR_BORDER))
	result.set_stylebox("hover", "Button", control_style(COLOR_CONTROL_HOVER, COLOR_BORDER_STRONG))
	result.set_stylebox("pressed", "Button", control_style(COLOR_CONTROL_ACTIVE, COLOR_FOCUS))
	result.set_stylebox("focus", "Button", control_style(COLOR_CONTROL_ACTIVE, COLOR_FOCUS))
	result.set_stylebox("disabled", "Button", control_style(COLOR_INSET, COLOR_BORDER))
	result.set_color("font_color", "LineEdit", COLOR_TEXT)
	result.set_color("caret_color", "LineEdit", COLOR_FOCUS)
	result.set_color("font_placeholder_color", "LineEdit", COLOR_TEXT_MUTED)
	result.set_stylebox("normal", "LineEdit", control_style(COLOR_CONTROL, COLOR_BORDER_STRONG))
	result.set_stylebox("focus", "LineEdit", control_style(COLOR_CONTROL_ACTIVE, COLOR_FOCUS))
	result.set_stylebox("panel", "PanelContainer", panel_style(COLOR_PANEL, COLOR_BORDER))
	result.set_color("font_color", "OptionButton", COLOR_TEXT_SECONDARY)
	result.set_stylebox("normal", "OptionButton", control_style(COLOR_CONTROL, COLOR_BORDER))
	result.set_stylebox("hover", "OptionButton", control_style(COLOR_CONTROL_HOVER, COLOR_BORDER_STRONG))
	result.set_stylebox("focus", "OptionButton", control_style(COLOR_CONTROL_ACTIVE, COLOR_FOCUS))
	result.set_stylebox("background", "ProgressBar", panel_style(COLOR_INSET, COLOR_BORDER, 2))
	result.set_stylebox("fill", "ProgressBar", panel_style(COLOR_FOCUS.darkened(0.35), COLOR_FOCUS, 2))
	var separator := StyleBoxLine.new()
	separator.color = COLOR_BORDER
	separator.thickness = 1
	result.set_stylebox("separator", "HSeparator", separator)
	result.set_constant("outline_size", "Button", 0)
	return result
