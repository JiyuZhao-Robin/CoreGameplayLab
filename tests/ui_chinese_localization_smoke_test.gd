extends Node

const MainScene := preload("res://src/ui/main.tscn")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("zh_CN")
	Game.reset_game()
	var main: Control = MainScene.instantiate()
	add_child(main)
	await _redraw()
	_check(_has_text_fragment(main, "运营总览"), "Chinese navigation is rendered")
	_check(_has_text_fragment(main, "当前引导"), "Chinese contextual guidance is rendered")
	_check(String(main.call("_status_text", "BLOCKED_OUTPUT")) == "满仓停机", "Chinese runtime status is localized")
	_check("铁锭不足" in String(main.call("_blocker_text", {"primary_reason":"INPUT_SHORTAGE", "item_id":"iron_ingot", "available":1, "required":4})), "Chinese structured blocker is localized")
	_press(main.find_child("Location_earth_orbit", true, false) as Button)
	await _redraw()
	_press(main.find_child("LocationTab_resources", true, false) as Button)
	await _redraw()
	var page_index := int(main.get("_tabs").current_tab)
	var selected_location := String(main.get("_selected_location_id"))
	var selected_section := String(main.get("_location_section"))
	_press(main.find_child("ToggleLocale", true, false) as Button)
	await _redraw()
	_check(I18n.current_locale == "en", "locale toggle switches to English")
	_check(int(main.get("_tabs").current_tab) == page_index, "locale switch preserves current page")
	_check(String(main.get("_selected_location_id")) == selected_location, "locale switch preserves selected location")
	_check(String(main.get("_location_section")) == selected_section, "locale switch preserves location sub-page")
	_check(_has_text_fragment(main, "KNOWN RESOURCE SITES"), "active page is rebuilt in English")
	_press(main.find_child("ToggleLocale", true, false) as Button)
	await _redraw()
	_check(I18n.current_locale == "zh_CN" and _has_text_fragment(main, "已知资源点"), "locale toggle restores Chinese without losing state")
	_finish()


func _press(button: Button) -> void:
	_check(button != null, "required UI button exists")
	if button != null:
		button.pressed.emit()


func _redraw() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	await get_tree().process_frame


func _has_text_fragment(node: Node, fragment: String) -> bool:
	if (node is Label or node is RichTextLabel or node is Button) and fragment in str(node.get("text")):
		return true
	for child in node.get_children():
		if _has_text_fragment(child, fragment):
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Chinese UI localization and state-preserving toggle smoke")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
