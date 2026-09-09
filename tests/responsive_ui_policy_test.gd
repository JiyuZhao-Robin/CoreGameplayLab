extends Node

const Policy := preload("res://src/ui/responsive_ui_policy.gd")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	_test_preference_migration()
	_test_fixed_canvas_matrix()
	_test_window_independent_theme_scale()
	_test_fixed_layout_profile()
	if failures.is_empty():
		print("RESPONSIVE_UI_POLICY_PASS")
		get_tree().quit(0)
	else:
		push_error("RESPONSIVE_UI_POLICY_FAIL\n%s" % "\n".join(failures))
		get_tree().quit(1)


func _test_preference_migration() -> void:
	_check(UiTokens.SUPPORTED_UI_SCALES == [0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0], "candidate set is exactly 90/100/110/125/150/175/200")
	var defaults := Policy.migrate_preference_state({})
	_check(String(defaults.get("preferred_mode", "")) == Policy.MODE_MANUAL and is_equal_approx(float(defaults.get("manual_scale", 0.0)), 1.25), "new installations use the fixed manual 125% preference")
	var legacy := Policy.migrate_preference_state({"legacy_scale":0.75})
	_check(String(legacy.get("preferred_mode", "")) == Policy.MODE_MANUAL and is_equal_approx(float(legacy.get("manual_scale", 0.0)), 0.9), "legacy 75% preferences migrate to MANUAL 90%")
	var legacy_percent := Policy.migrate_preference_state({"legacy_scale":"150"})
	_check(String(legacy_percent.get("preferred_mode", "")) == Policy.MODE_MANUAL and is_equal_approx(float(legacy_percent.get("manual_scale", 0.0)), 1.5), "legacy percentage-form values remain readable")
	var auto_with_shadow := Policy.migrate_preference_state({"preferred_mode":"auto", "legacy_scale":1.75})
	_check(String(auto_with_shadow.get("preferred_mode", "")) == Policy.MODE_MANUAL and is_equal_approx(float(auto_with_shadow.get("manual_scale", 0.0)), 1.75) and bool(auto_with_shadow.get("migration_required", false)), "legacy AUTO migrates once to fixed MANUAL without losing its scale")
	var complete_new := Policy.migrate_preference_state({"preferred_mode":"manual", "manual_scale":1.1, "legacy_scale":1.1})
	_check(not bool(complete_new.get("migration_required", true)), "complete new-format preferences do not rewrite the config")
	var missing_shadow := Policy.migrate_preference_state({"preferred_mode":"manual", "manual_scale":1.1})
	_check(bool(missing_shadow.get("migration_required", false)), "new-format preferences missing the rollback shadow are completed once")
	var malformed := Policy.migrate_preference_state({"preferred_mode":"not-a-mode", "manual_scale":"broken"})
	_check(String(malformed.get("preferred_mode", "")) == Policy.MODE_MANUAL and is_equal_approx(float(malformed.get("manual_scale", 0.0)), 1.25), "malformed new keys fall back to the fixed default without load failure")


func _test_fixed_canvas_matrix() -> void:
	var cases := [
		{"window":Vector2(1920, 1080), "scale":1.0, "offset":Vector2.ZERO},
		{"window":Vector2(3840, 2160), "scale":2.0, "offset":Vector2.ZERO},
		{"window":Vector2(2560, 1440), "scale":4.0 / 3.0, "offset":Vector2.ZERO},
		{"window":Vector2(3440, 1440), "scale":4.0 / 3.0, "offset":Vector2(440, 0)},
		{"window":Vector2(1440, 900), "scale":0.75, "offset":Vector2(0, 45)},
		{"window":Vector2(1366, 768), "scale":768.0 / 1080.0, "offset":Vector2((1366.0 - 1920.0 * 768.0 / 1080.0) * 0.5, 0)},
		{"window":Vector2(900, 1200), "scale":0.46875, "offset":Vector2(0, 346.875)}
	]
	for test_case in cases:
		var window_size: Vector2 = test_case.get("window", Vector2.ZERO)
		var expected_scale := float(test_case.get("scale", 0.0))
		var expected_offset: Vector2 = test_case.get("offset", Vector2.ZERO)
		var content_rect := Policy.canvas_content_rect(window_size)
		_check(is_equal_approx(Policy.uniform_canvas_scale(window_size), expected_scale), "%s uses one expected uniform canvas scale" % window_size)
		_check(content_rect.position.distance_to(expected_offset) < 0.001, "%s centers the fixed canvas with the expected letterbox offset (sub-pixel float tolerance)" % window_size)
		_check(content_rect.size.is_equal_approx(Policy.DESIGN_VIEWPORT_SIZE * expected_scale), "%s scales the complete 1920x1080 canvas as one surface" % window_size)
		_check((content_rect.position * 2.0 + content_rect.size).is_equal_approx(window_size), "%s distributes unused pixels symmetrically around the canvas" % window_size)
		_check(is_equal_approx(content_rect.size.aspect(), Policy.DESIGN_VIEWPORT_SIZE.aspect()), "%s preserves the 16:9 design aspect without distortion" % window_size)


func _test_window_independent_theme_scale() -> void:
	for window_size in [Vector2(1366, 768), Vector2(1440, 900), Vector2(1920, 1080), Vector2(2560, 1440), Vector2(3840, 2160)]:
		_check(is_equal_approx(Policy.recommend_ui_scale(window_size, window_size, 4.0), UiTokens.DEFAULT_UI_SCALE), "%s cannot change the fixed default Theme scale" % window_size)
		_check(is_equal_approx(Policy.safe_manual_effective_scale(2.0, window_size), 2.0), "%s cannot project the player's explicit 200%% preference" % window_size)
	_check(Policy.logical_usable_size(Vector2(1, 1), 2.0).is_equal_approx(Policy.DESIGN_VIEWPORT_SIZE), "logical usable size is always the 1920x1080 design canvas")


func _test_fixed_layout_profile() -> void:
	for logical_size in [Vector2(640, 360), Vector2(1920, 1080), Vector2(3840, 2160)]:
		_check(Policy.resolve_profile(logical_size, Policy.PROFILE_COMPACT) == Policy.PROFILE_STANDARD, "%s resolves the one authored STANDARD profile" % logical_size)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		failures.append(description)
		push_error("FAIL: %s" % description)
