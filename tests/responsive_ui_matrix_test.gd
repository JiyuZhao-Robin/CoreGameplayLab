extends Node

const MainScene := preload("res://src/ui/main.tscn")
const Policy := preload("res://src/ui/responsive_ui_policy.gd")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Engine.time_scale = 0.0
	Game.reset_game()
	var cases := [
		{"window":Vector2(1280, 720), "scale":1.1, "profile":Policy.PROFILE_COMPACT},
		{"window":Vector2(1600, 900), "scale":1.25, "profile":Policy.PROFILE_COMPACT},
		{"window":Vector2(1920, 1080), "scale":1.5, "profile":Policy.PROFILE_COMPACT},
		{"window":Vector2(2560, 1440), "scale":1.75, "profile":Policy.PROFILE_STANDARD},
		{"window":Vector2(3440, 1440), "scale":1.75, "profile":Policy.PROFILE_STANDARD},
		{"window":Vector2(3840, 2160), "scale":2.0, "profile":Policy.PROFILE_EXPANDED}
	]
	for test_case in cases:
		await _audit_case(test_case)
	_clear_scale_session()
	UiTokens.set_ui_scale(UiTokens.DEFAULT_UI_SCALE)
	Engine.time_scale = 1.0
	if failures.is_empty():
		print("RESPONSIVE_UI_MATRIX_PASS")
		get_tree().quit(0)
	else:
		push_error("RESPONSIVE_UI_MATRIX_FAIL\n%s" % "\n".join(failures))
		get_tree().quit(1)


func _audit_case(test_case: Dictionary) -> void:
	_clear_scale_session()
	var window_size: Vector2 = test_case.get("window", Vector2.ZERO)
	var expected_scale := float(test_case.get("scale", 0.0))
	# Build the real shell with a fresh AUTO preference. The initial Window pass
	# and post-layout active-page pass must converge on the same effective scale.
	var main: Control = MainScene.instantiate()
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = window_size
	add_child(main)
	await get_tree().process_frame
	await get_tree().create_timer(0.24, true, false, true).timeout
	await get_tree().process_frame
	var snapshot: Dictionary = main.call("ui_responsive_snapshot")
	var usable_size: Vector2 = snapshot.get("usable_size", Vector2.ZERO)
	var logical_size: Vector2 = snapshot.get("logical_usable_size", Vector2.ZERO)
	var recommended := float(snapshot.get("recommended_scale", 0.0))
	var effective := float(snapshot.get("effective_scale", 0.0))
	var profile := String(snapshot.get("layout_profile", ""))
	_check(String(snapshot.get("preferred_mode", "")) == Policy.MODE_AUTO and is_equal_approx(recommended, expected_scale) and is_equal_approx(effective, expected_scale), "%dx%d AUTO recommendation/effective scale converges on %d%% after measuring the real active page" % [int(window_size.x), int(window_size.y), int(expected_scale * 100.0)])
	_check(profile == String(test_case.get("profile", "")), "%dx%d resolves the expected presentation profile from both logical dimensions" % [int(window_size.x), int(window_size.y)])
	_check(main.scale.is_equal_approx(Vector2.ONE) and is_equal_approx(float(get_tree().root.content_scale_factor), 1.0), "%dx%d keeps root and viewport transforms native" % [int(window_size.x), int(window_size.y)])
	print("RESPONSIVE_ACTUAL_MATRIX window=%dx%d usable=%dx%d logical=%dx%d recommended=%d profile=%s" % [
		int(window_size.x), int(window_size.y),
		int(round(usable_size.x)), int(round(usable_size.y)),
		int(round(logical_size.x)), int(round(logical_size.y)),
		int(round(recommended * 100.0)), profile
	])
	main.queue_free()
	await get_tree().process_frame


func _clear_scale_session() -> void:
	get_tree().root.remove_meta(UiTokens.UI_SCALE_SESSION_META)
	get_tree().root.remove_meta(Policy.SESSION_STATE_META)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		failures.append(description)
		push_error("FAIL: %s" % description)
