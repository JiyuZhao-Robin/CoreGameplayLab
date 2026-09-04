class_name ResponsiveUiPolicy
extends RefCounted

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const MODE_AUTO := "AUTO"
const MODE_MANUAL := "MANUAL"
const DEFAULT_MODE := MODE_AUTO

const PROFILE_COMPACT := "COMPACT"
const PROFILE_STANDARD := "STANDARD"
const PROFILE_EXPANDED := "EXPANDED"
const DEFAULT_PROFILE := PROFILE_STANDARD

const AUTO_SELECTOR_ID := 0
const SESSION_STATE_META := "core_gameplay_lab_responsive_ui_state"
const RESIZE_DEBOUNCE_SECONDS := 0.2
const SCALE_HYSTERESIS := 0.04

# AUTO estimates a comfortable scale from both dimensions of the actual Window.
# DPI is deliberately capped at one small candidate-boundary nudge; it can
# influence a recommendation, but it can never make an unsafe candidate valid.
const AUTO_REFERENCE_WINDOW := Vector2(1600.0, 900.0)
const AUTO_BASE_SCALE := 0.5
const AUTO_CAPACITY_WEIGHT := 0.75
const AUTO_DPI_WEIGHT := 0.04
const AUTO_DPI_BIAS_LIMIT := 0.04
const AUTO_MIN_SCALE := 0.9
const AUTO_MAX_SCALE := 2.0
# The active page lives inside the persistent rails and shell chrome. 640 logical
# pixels preserves the existing 1440x900 desktop baseline at 125% while still
# preventing AUTO from selecting a scale that collapses the workspace itself.
const AUTO_MIN_LOGICAL_PAGE := Vector2(640.0, 440.0)

# Profiles use the active page ScrollContainer viewport after effective scale is
# applied. They are presentation-only and intentionally require both dimensions.
const STANDARD_MIN_LOGICAL_SIZE := Vector2(1000.0, 600.0)
const EXPANDED_MIN_LOGICAL_SIZE := Vector2(1440.0, 840.0)
const COMPACT_TO_STANDARD_SIZE := Vector2(1040.0, 620.0)
const STANDARD_TO_COMPACT_SIZE := Vector2(960.0, 570.0)
const STANDARD_TO_EXPANDED_SIZE := Vector2(1500.0, 880.0)
const EXPANDED_TO_STANDARD_SIZE := Vector2(1380.0, 780.0)


static func normalize_mode(value: Variant) -> String:
	var normalized := String(value).strip_edges().to_upper()
	return normalized if normalized in [MODE_AUTO, MODE_MANUAL] else DEFAULT_MODE


static func mode_is_valid(value: Variant) -> bool:
	return String(value).strip_edges().to_upper() in [MODE_AUTO, MODE_MANUAL]


static func normalize_profile(value: Variant) -> String:
	var normalized := String(value).strip_edges().to_upper()
	return normalized if normalized in [PROFILE_COMPACT, PROFILE_STANDARD, PROFILE_EXPANDED] else DEFAULT_PROFILE


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
	var preferred_mode := normalize_mode(values.get("preferred_mode", DEFAULT_MODE)) if has_valid_mode else (MODE_MANUAL if has_legacy else DEFAULT_MODE)
	return {
		"preferred_mode":preferred_mode,
		"manual_scale":manual_scale,
		"source":"new" if has_valid_mode else ("legacy" if has_legacy else "default"),
		# A legacy shadow remains useful for rollback to older builds, so a valid
		# new-format preference without that shadow is also completed once.
		"migration_required":not has_valid_mode or not has_manual or not has_legacy
	}


static func dpi_hint(value: float) -> float:
	if is_nan(value) or is_inf(value) or value <= 0.0:
		return 1.0
	return clampf(value, 0.5, 4.0)


static func ideal_auto_scale(window_size: Vector2, dpi_value: float) -> float:
	if window_size.x <= 0.0 or window_size.y <= 0.0:
		return UiTokens.DEFAULT_UI_SCALE
	var capacity := minf(window_size.x / AUTO_REFERENCE_WINDOW.x, window_size.y / AUTO_REFERENCE_WINDOW.y)
	var dpi_bias := clampf((dpi_hint(dpi_value) - 1.0) * AUTO_DPI_WEIGHT, -AUTO_DPI_BIAS_LIMIT, AUTO_DPI_BIAS_LIMIT)
	return clampf(AUTO_BASE_SCALE + AUTO_CAPACITY_WEIGHT * capacity + dpi_bias, AUTO_MIN_SCALE, AUTO_MAX_SCALE)


static func logical_usable_size(usable_size: Vector2, scale_value: float) -> Vector2:
	var normalized_scale := maxf(AUTO_MIN_SCALE, UiTokens.sanitize_ui_scale(scale_value))
	return Vector2(maxf(0.0, usable_size.x), maxf(0.0, usable_size.y)) / normalized_scale


static func candidate_is_auto_safe(candidate: float, window_size: Vector2, usable_size: Vector2) -> bool:
	var viewport := Vector2i(maxi(0, roundi(window_size.x)), maxi(0, roundi(window_size.y)))
	if not UiTokens.ui_scale_supported_for_viewport(candidate, viewport):
		return false
	var logical_page := logical_usable_size(usable_size, candidate)
	return logical_page.x >= AUTO_MIN_LOGICAL_PAGE.x and logical_page.y >= AUTO_MIN_LOGICAL_PAGE.y


static func recommend_ui_scale(window_size: Vector2, usable_size: Vector2, dpi_value: float) -> float:
	var ideal := ideal_auto_scale(window_size, dpi_value)
	var closest := AUTO_MIN_SCALE
	var closest_distance := INF
	var found := false
	for candidate_value in UiTokens.SUPPORTED_UI_SCALES:
		var candidate := float(candidate_value)
		if not candidate_is_auto_safe(candidate, window_size, usable_size):
			continue
		var distance := absf(candidate - ideal)
		if not found or distance < closest_distance - 0.0001 or (is_equal_approx(distance, closest_distance) and candidate > closest):
			closest = candidate
			closest_distance = distance
			found = true
	if found:
		return closest
	return safe_manual_effective_scale(AUTO_MIN_SCALE, window_size)


static func stabilize_auto_scale(current_value: float, proposed_value: float, window_size: Vector2, usable_size: Vector2, dpi_value: float) -> float:
	var current := UiTokens.sanitize_ui_scale(current_value)
	var proposed := UiTokens.sanitize_ui_scale(proposed_value)
	if is_equal_approx(current, proposed):
		return current
	# Hard safety always wins over hysteresis.
	if not candidate_is_auto_safe(current, window_size, usable_size):
		return proposed
	var ideal := ideal_auto_scale(window_size, dpi_value)
	var midpoint := (current + proposed) * 0.5
	if proposed > current and ideal < midpoint + SCALE_HYSTERESIS:
		return current
	if proposed < current and ideal > midpoint - SCALE_HYSTERESIS:
		return current
	return proposed


static func safe_manual_effective_scale(manual_value: float, window_size: Vector2) -> float:
	var manual := UiTokens.sanitize_ui_scale(manual_value)
	var viewport := Vector2i(maxi(0, roundi(window_size.x)), maxi(0, roundi(window_size.y)))
	var fallback := float(UiTokens.SUPPORTED_UI_SCALES[0])
	for candidate_value in UiTokens.SUPPORTED_UI_SCALES:
		var candidate := float(candidate_value)
		if candidate <= manual + 0.0001 and UiTokens.ui_scale_supported_for_viewport(candidate, viewport):
			fallback = candidate
	return fallback


static func resolve_profile(logical_size: Vector2, current_profile := "") -> String:
	var current := normalize_profile(current_profile) if not current_profile.is_empty() else ""
	if current == PROFILE_COMPACT:
		if logical_size.x < COMPACT_TO_STANDARD_SIZE.x or logical_size.y < COMPACT_TO_STANDARD_SIZE.y:
			return PROFILE_COMPACT
		if logical_size.x >= STANDARD_TO_EXPANDED_SIZE.x and logical_size.y >= STANDARD_TO_EXPANDED_SIZE.y:
			return PROFILE_EXPANDED
		return PROFILE_STANDARD
	if current == PROFILE_EXPANDED:
		if logical_size.x >= EXPANDED_TO_STANDARD_SIZE.x and logical_size.y >= EXPANDED_TO_STANDARD_SIZE.y:
			return PROFILE_EXPANDED
		if logical_size.x < STANDARD_TO_COMPACT_SIZE.x or logical_size.y < STANDARD_TO_COMPACT_SIZE.y:
			return PROFILE_COMPACT
		return PROFILE_STANDARD
	if current == PROFILE_STANDARD:
		if logical_size.x < STANDARD_TO_COMPACT_SIZE.x or logical_size.y < STANDARD_TO_COMPACT_SIZE.y:
			return PROFILE_COMPACT
		if logical_size.x >= STANDARD_TO_EXPANDED_SIZE.x and logical_size.y >= STANDARD_TO_EXPANDED_SIZE.y:
			return PROFILE_EXPANDED
		return PROFILE_STANDARD
	if logical_size.x >= EXPANDED_MIN_LOGICAL_SIZE.x and logical_size.y >= EXPANDED_MIN_LOGICAL_SIZE.y:
		return PROFILE_EXPANDED
	if logical_size.x >= STANDARD_MIN_LOGICAL_SIZE.x and logical_size.y >= STANDARD_MIN_LOGICAL_SIZE.y:
		return PROFILE_STANDARD
	return PROFILE_COMPACT
