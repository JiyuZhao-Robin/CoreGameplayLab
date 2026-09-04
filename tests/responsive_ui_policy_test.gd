extends Node

const Policy := preload("res://src/ui/responsive_ui_policy.gd")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	_test_preference_migration()
	_test_auto_recommendation_matrix()
	_test_dpi_is_bounded_input()
	_test_manual_safety_projection()
	_test_scale_hysteresis()
	_test_profile_boundaries_and_hysteresis()
	if failures.is_empty():
		print("RESPONSIVE_UI_POLICY_PASS")
		get_tree().quit(0)
	else:
		push_error("RESPONSIVE_UI_POLICY_FAIL\n%s" % "\n".join(failures))
		get_tree().quit(1)


func _test_preference_migration() -> void:
	_check(UiTokens.SUPPORTED_UI_SCALES == [0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0], "candidate set is exactly 90/100/110/125/150/175/200")
	var defaults := Policy.migrate_preference_state({})
	_check(String(defaults.get("preferred_mode", "")) == Policy.MODE_AUTO and is_equal_approx(float(defaults.get("manual_scale", 0.0)), 1.25), "new installations use AUTO while retaining a 125% manual preference")
	var legacy := Policy.migrate_preference_state({"legacy_scale":0.75})
	_check(String(legacy.get("preferred_mode", "")) == Policy.MODE_MANUAL and is_equal_approx(float(legacy.get("manual_scale", 0.0)), 0.9), "legacy 75% preferences migrate to MANUAL 90%")
	var legacy_percent := Policy.migrate_preference_state({"legacy_scale":"150"})
	_check(String(legacy_percent.get("preferred_mode", "")) == Policy.MODE_MANUAL and is_equal_approx(float(legacy_percent.get("manual_scale", 0.0)), 1.5), "legacy percentage-form values remain readable")
	var auto_with_shadow := Policy.migrate_preference_state({"preferred_mode":"auto", "legacy_scale":1.75})
	_check(String(auto_with_shadow.get("preferred_mode", "")) == Policy.MODE_AUTO and is_equal_approx(float(auto_with_shadow.get("manual_scale", 0.0)), 1.75), "AUTO can migrate a legacy scale into the dormant manual preference")
	var complete_new := Policy.migrate_preference_state({"preferred_mode":"manual", "manual_scale":1.1, "legacy_scale":1.1})
	_check(not bool(complete_new.get("migration_required", true)), "complete new-format preferences do not rewrite the config")
	var missing_shadow := Policy.migrate_preference_state({"preferred_mode":"manual", "manual_scale":1.1})
	_check(bool(missing_shadow.get("migration_required", false)), "new-format preferences missing the rollback shadow are completed once")
	var malformed := Policy.migrate_preference_state({"preferred_mode":"not-a-mode", "manual_scale":"broken"})
	_check(String(malformed.get("preferred_mode", "")) == Policy.MODE_AUTO and is_equal_approx(float(malformed.get("manual_scale", 0.0)), 1.25), "malformed new keys fall back without load failure")


func _test_auto_recommendation_matrix() -> void:
	var cases := [
		{"window":Vector2(1280, 720), "expected":1.1},
		{"window":Vector2(1600, 900), "expected":1.25},
		{"window":Vector2(1920, 1080), "expected":1.5},
		{"window":Vector2(2560, 1440), "expected":1.75},
		{"window":Vector2(3440, 1440), "expected":1.75},
		{"window":Vector2(3840, 2160), "expected":2.0}
	]
	for test_case in cases:
		var window_size: Vector2 = test_case.get("window", Vector2.ZERO)
		var recommended := Policy.recommend_ui_scale(window_size, window_size, 1.0)
		var expected := float(test_case.get("expected", 0.0))
		_check(is_equal_approx(recommended, expected), "%dx%d recommends %d%% from width and height capacity" % [int(window_size.x), int(window_size.y), int(expected * 100.0)])
		print("RESPONSIVE_MATRIX window=%dx%d dpi=1.00 recommended=%d" % [int(window_size.x), int(window_size.y), int(recommended * 100.0)])
	_check(is_equal_approx(Policy.recommend_ui_scale(Vector2(3440, 1440), Vector2(3440, 1440), 1.0), 1.75), "3440x1440 does not inherit the 4K recommendation from width alone")
	_check(is_equal_approx(Policy.recommend_ui_scale(Vector2(3840, 2160), Vector2(1200, 760), 1.0), 1.5), "a constrained active-page usable rect caps an otherwise 4K recommendation")


func _test_dpi_is_bounded_input() -> void:
	var window_size := Vector2(1387, 780)
	var low_dpi := Policy.recommend_ui_scale(window_size, window_size, 1.0)
	var high_dpi := Policy.recommend_ui_scale(window_size, window_size, 3.0)
	_check(is_equal_approx(low_dpi, 1.1) and is_equal_approx(high_dpi, 1.25), "DPI can nudge a recommendation across one nearby candidate boundary")
	_check(Policy.ideal_auto_scale(Vector2(3840, 2160), 0.5) <= 2.0 and Policy.ideal_auto_scale(Vector2(3840, 2160), 4.0) <= 2.0, "DPI never bypasses the candidate maximum")
	_check(not Policy.candidate_is_auto_safe(2.0, Vector2(1280, 720), Vector2(1280, 720)), "DPI cannot make an unsafe 200% candidate valid at 1280x720")


func _test_manual_safety_projection() -> void:
	var cases := [
		{"window":Vector2(1280, 720), "effective":1.25},
		{"window":Vector2(1600, 900), "effective":1.5},
		{"window":Vector2(1920, 1080), "effective":1.75},
		{"window":Vector2(2560, 1440), "effective":2.0}
	]
	for test_case in cases:
		var effective := Policy.safe_manual_effective_scale(2.0, test_case.get("window", Vector2.ZERO))
		_check(is_equal_approx(effective, float(test_case.get("effective", 0.0))), "Manual 200%% safely projects to %d%% at %s without changing the preference" % [int(effective * 100.0), test_case.get("window")])


func _test_scale_hysteresis() -> void:
	var window_size := Vector2(1920, 1080)
	var usable_size := Vector2(1920, 1080)
	var held := Policy.stabilize_auto_scale(1.25, 1.5, window_size, usable_size, 1.0)
	var crossed := Policy.stabilize_auto_scale(1.25, 1.5, window_size, usable_size, 2.0)
	_check(is_equal_approx(held, 1.25), "AUTO scale hysteresis holds inside the upward deadband")
	_check(is_equal_approx(crossed, 1.5), "AUTO scale changes after the upward deadband is crossed")
	var unsafe_bypass := Policy.stabilize_auto_scale(2.0, 1.1, Vector2(1280, 720), Vector2(1280, 720), 1.0)
	_check(is_equal_approx(unsafe_bypass, 1.1), "hard safety bypasses scale hysteresis immediately")
	_check(is_equal_approx(Policy.RESIZE_DEBOUNCE_SECONDS, 0.2), "resize debounce is 200ms")


func _test_profile_boundaries_and_hysteresis() -> void:
	_check(Policy.resolve_profile(Vector2(999, 700)) == Policy.PROFILE_COMPACT, "cold profile selection requires both Standard dimensions")
	_check(Policy.resolve_profile(Vector2(1200, 599)) == Policy.PROFILE_COMPACT, "large width alone cannot select Standard")
	_check(Policy.resolve_profile(Vector2(1200, 700)) == Policy.PROFILE_STANDARD, "cold profile selection resolves Standard from logical usable size")
	_check(Policy.resolve_profile(Vector2(1600, 900)) == Policy.PROFILE_EXPANDED, "cold profile selection resolves Expanded when both dimensions fit")
	_check(Policy.resolve_profile(Vector2(1020, 610), Policy.PROFILE_COMPACT) == Policy.PROFILE_COMPACT, "Compact holds inside its profile hysteresis band")
	_check(Policy.resolve_profile(Vector2(1040, 620), Policy.PROFILE_COMPACT) == Policy.PROFILE_STANDARD, "Compact enters Standard only across the upper threshold")
	_check(Policy.resolve_profile(Vector2(980, 590), Policy.PROFILE_STANDARD) == Policy.PROFILE_STANDARD, "Standard holds inside its lower hysteresis band")
	_check(Policy.resolve_profile(Vector2(959, 590), Policy.PROFILE_STANDARD) == Policy.PROFILE_COMPACT, "Standard exits to Compact when either lower bound is crossed")
	_check(Policy.resolve_profile(Vector2(1490, 900), Policy.PROFILE_STANDARD) == Policy.PROFILE_STANDARD, "ultrawide width cannot enter Expanded without the full upper threshold")
	_check(Policy.resolve_profile(Vector2(1500, 880), Policy.PROFILE_STANDARD) == Policy.PROFILE_EXPANDED, "Standard enters Expanded only when both upper bounds are crossed")
	_check(Policy.resolve_profile(Vector2(1400, 800), Policy.PROFILE_EXPANDED) == Policy.PROFILE_EXPANDED, "Expanded holds inside its lower hysteresis band")
	_check(Policy.resolve_profile(Vector2(1500, 779), Policy.PROFILE_EXPANDED) == Policy.PROFILE_STANDARD, "Expanded exits when height becomes constrained despite wide width")


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		failures.append(description)
		push_error("FAIL: %s" % description)
