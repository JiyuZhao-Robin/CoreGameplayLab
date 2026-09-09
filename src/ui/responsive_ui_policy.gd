class_name ResponsiveUiPolicy
extends RefCounted

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const MODE_AUTO := "AUTO"
const MODE_MANUAL := "MANUAL"
const DEFAULT_MODE := MODE_MANUAL

const PROFILE_COMPACT := "COMPACT"
const PROFILE_STANDARD := "STANDARD"
const PROFILE_EXPANDED := "EXPANDED"
const DEFAULT_PROFILE := PROFILE_STANDARD

const AUTO_SELECTOR_ID := 0
const SESSION_STATE_META := "core_gameplay_lab_responsive_ui_state"

# All production UI is authored in this one logical coordinate system. The
# Window may scale and letterbox this surface, but it must never use its physical
# size to select another Theme scale or layout profile.
const DESIGN_VIEWPORT_SIZE := Vector2(1920.0, 1080.0)


static func normalize_mode(value: Variant) -> String:
	var normalized := String(value).strip_edges().to_upper()
	# AUTO is accepted as a legacy preference and migrated to the fixed MANUAL
	# contract. Keeping the symbol allows older config files and tools to load.
	return MODE_MANUAL if normalized in [MODE_AUTO, MODE_MANUAL] else DEFAULT_MODE


static func mode_is_valid(value: Variant) -> bool:
	return String(value).strip_edges().to_upper() in [MODE_AUTO, MODE_MANUAL]


static func normalize_profile(_value: Variant) -> String:
	return DEFAULT_PROFILE


static func scale_value_is_valid(value: Variant) -> bool:
	if value is int or value is float:
		var numeric := float(value)
		return not is_nan(numeric) and not is_inf(numeric)
	if value is String:
		return String(value).strip_edges().is_valid_float()
	return false


static func scale_from_variant(value: Variant, fallback := UiTokens.DEFAULT_UI_SCALE) -> float:
	if not scale_value_is_valid(value):
		return UiTokens.sanitize_ui_scale(fallback)
	return UiTokens.sanitize_ui_scale(float(value))


static func migrate_preference_state(values: Dictionary) -> Dictionary:
	var has_valid_mode := values.has("preferred_mode") and mode_is_valid(values.get("preferred_mode"))
	var has_manual := values.has("manual_scale") and scale_value_is_valid(values.get("manual_scale"))
	var has_legacy := values.has("legacy_scale") and scale_value_is_valid(values.get("legacy_scale"))
	var manual_scale := UiTokens.DEFAULT_UI_SCALE
	if has_manual:
		manual_scale = scale_from_variant(values.get("manual_scale"))
	elif has_legacy:
		manual_scale = scale_from_variant(values.get("legacy_scale"))
	var preferred_mode := MODE_MANUAL
	return {
		"preferred_mode":preferred_mode,
		"manual_scale":manual_scale,
		"source":"fixed_layout" if has_valid_mode else ("legacy" if has_legacy else "default"),
		# A legacy shadow remains useful for rollback to older builds, so a valid
		# new-format preference without that shadow is also completed once.
		"migration_required":not has_valid_mode or not has_manual or not has_legacy or String(values.get("preferred_mode", "")).strip_edges().to_upper() != MODE_MANUAL
	}


static func dpi_hint(value: float) -> float:
	if is_nan(value) or is_inf(value) or value <= 0.0:
		return 1.0
	return clampf(value, 0.5, 4.0)


static func ideal_auto_scale(_window_size: Vector2, _dpi_value: float) -> float:
	# Compatibility API: window and DPI no longer influence interface geometry.
	return UiTokens.DEFAULT_UI_SCALE


static func logical_usable_size(_usable_size: Vector2, _scale_value: float) -> Vector2:
	return DESIGN_VIEWPORT_SIZE


static func candidate_is_auto_safe(candidate: float, _window_size: Vector2, _usable_size: Vector2) -> bool:
	return candidate in UiTokens.SUPPORTED_UI_SCALES


static func recommend_ui_scale(_window_size: Vector2, _usable_size: Vector2, _dpi_value: float) -> float:
	return UiTokens.DEFAULT_UI_SCALE


static func stabilize_auto_scale(_current_value: float, _proposed_value: float, _window_size: Vector2, _usable_size: Vector2, _dpi_value: float) -> float:
	return UiTokens.DEFAULT_UI_SCALE


static func safe_manual_effective_scale(manual_value: float, _window_size: Vector2) -> float:
	# Accessibility scale is an explicit player choice. Resizing the Window must
	# not silently project it to a different effective value.
	return UiTokens.sanitize_ui_scale(manual_value)


static func resolve_profile(_logical_size: Vector2, _current_profile := "") -> String:
	return PROFILE_STANDARD


static func uniform_canvas_scale(window_size: Vector2) -> float:
	if window_size.x <= 0.0 or window_size.y <= 0.0:
		return 0.0
	return minf(window_size.x / DESIGN_VIEWPORT_SIZE.x, window_size.y / DESIGN_VIEWPORT_SIZE.y)


static func canvas_content_rect(window_size: Vector2) -> Rect2:
	var uniform_scale := uniform_canvas_scale(window_size)
	var content_size := DESIGN_VIEWPORT_SIZE * uniform_scale
	return Rect2((window_size - content_size) * 0.5, content_size)
