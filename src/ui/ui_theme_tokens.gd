class_name UiThemeTokens
extends RefCounted

# Semantic UI tokens. Gameplay screens consume these names instead of
# inventing per-screen colors and dimensions.
const COLOR_CANVAS := Color("090f14")
const COLOR_PANEL := Color("111a20")
const COLOR_RAISED := Color("18242c")
const COLOR_CONTROL := Color("1d2b34")
const COLOR_BORDER := Color("3d5360")
const COLOR_TEXT := Color("e8eef1")
const COLOR_TEXT_SECONDARY := Color("b7c4ca")
const COLOR_TEXT_MUTED := Color("83959e")
const COLOR_FOCUS := Color("65cbd0")
const COLOR_RUNNING := Color("72c990")
const COLOR_INFO := Color("69abd0")
const COLOR_WARNING := Color("e1b85c")
const COLOR_CRITICAL := Color("df7d6c")

const SPACING_XS := 4
const SPACING_SM := 8
const SPACING_MD := 12
const SPACING_LG := 16
const SPACING_XL := 24
const PANEL_PADDING := 12
const CARD_GAP := 8
const ROW_HEIGHT := 40
const NAV_WIDTH := 204
const INSPECTOR_WIDTH := 304
const TOP_BAR_HEIGHT := 72
const BOTTOM_BAR_HEIGHT := 64


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
	result.set_color("font_disabled_color", "Button", COLOR_TEXT_MUTED)
	result.set_color("font_focus_color", "Button", COLOR_TEXT)
	result.set_color("font_hover_color", "Button", COLOR_TEXT)
	result.set_color("font_pressed_color", "Button", COLOR_TEXT)
	result.set_color("font_color", "LineEdit", COLOR_TEXT)
	result.set_color("caret_color", "LineEdit", COLOR_FOCUS)
	result.set_color("font_placeholder_color", "LineEdit", COLOR_TEXT_MUTED)
	result.set_constant("outline_size", "Button", 0)
	return result
