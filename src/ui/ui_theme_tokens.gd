class_name UiThemeTokens
extends RefCounted

# Semantic UI tokens. Gameplay screens consume these names instead of
# inventing per-screen colors and dimensions.
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
const COLOR_NODE_SURFACE := Color("101715")
const COLOR_NODE_HEADER := Color("151d1a")

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


static func panel_style(background: Color, border: Color = COLOR_BORDER, radius: int = 4) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	return style


static func control_style(background: Color, border: Color, radius := 4) -> StyleBoxFlat:
	var style := panel_style(background, border, radius)
	style.content_margin_left = 9.0
	style.content_margin_right = 9.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	return style


static func build_theme() -> Theme:
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray([
		"Noto Sans CJK SC", "Microsoft YaHei UI", "Microsoft YaHei",
		"PingFang SC", "Segoe UI", "Arial Unicode MS"
	])
	var result := Theme.new()
	result.default_font = system_font
	result.default_font_size = 15
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
