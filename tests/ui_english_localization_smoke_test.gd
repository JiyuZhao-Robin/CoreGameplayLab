extends Node

const MainScene := preload("res://src/ui/main.tscn")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("en")
	Game.reset_game()
	var main: Control = MainScene.instantiate()
	add_child(main)
	await _redraw()
	_check(_has_text_fragment(main, "Operations Overview"), "English navigation is rendered")
	_check(_has_text_fragment(main, "CURRENT GUIDANCE"), "English contextual guidance is rendered")
	_check(String(main.call("_status_text", "BLOCKED_OUTPUT")) == "Output Storage Full", "English runtime status is localized")
	var blocker_text := String(main.call("_blocker_text", {"primary_reason":"INPUT_SHORTAGE", "item_id":"iron_ingot", "available":1, "required":4}))
	_check("Insufficient Iron Ingots" in blocker_text and not _contains_cjk(blocker_text), "English structured blocker is localized")
	_scan_visible_page(main, "overview")

	_press(main.find_child("Navigation_system_map", true, false) as Button)
	await _redraw()
	_scan_visible_page(main, "system_map")
	var earth_button := main.find_child("Location_earth_orbit", true, false) as Button
	_press(earth_button)
	await _redraw()
	_scan_visible_page(main, "location overview")
	_press(main.find_child("LocationTab_resources", true, false) as Button)
	await _redraw()
	_scan_visible_page(main, "location resources")

	_press(main.find_child("Navigation_industry", true, false) as Button)
	await _redraw()
	_press(main.find_child("IndustrySection_automation", true, false) as Button)
	await _redraw()
	_check(_has_text_fragment(main, "CURRENT ECONOMY ANALYSIS"), "English diagnostics are rendered")
	_check(_has_text_fragment(main, "READ-ONLY THROUGHPUT PLANNER"), "English planner is rendered")
	_check(_has_text_fragment(main, "CONDITIONAL AUTOMATION"), "English automation is rendered")
	_scan_visible_page(main, "industry diagnostics")

	_press(main.find_child("Navigation_research", true, false) as Button)
	await _redraw()
	_scan_visible_page(main, "research")

	_press(main.find_child("Navigation_megastructure", true, false) as Button)
	await _redraw()
	_check(_has_text_fragment(main, "Stellar Energy Megastructure"), "English unique megastructure page is rendered")
	for phase_name in ["Research & Site Selection", "Forward Construction Base", "Foundation & Anchorage", "Primary Structural Frame", "Industrial & Energy Backbone", "Main Functional Systems", "System Integration", "Final Commissioning"]:
		_check(_has_text_fragment(main, phase_name), "English megastructure stage is visible: %s" % phase_name)
	_scan_visible_page(main, "megastructure")
	I18n.set_locale("zh_CN")
	_finish()


func _scan_visible_page(main: Control, page_name: String) -> void:
	var leaks: Array[String] = []
	_collect_visible_cjk(main, leaks)
	_check(leaks.is_empty(), "English %s has no visible CJK text%s" % [page_name, " (" + " | ".join(leaks.slice(0, 5)) + ")" if not leaks.is_empty() else ""])


func _collect_visible_cjk(node: Node, leaks: Array[String]) -> void:
	if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
		return
	var text_value := ""
	if node is Label or node is RichTextLabel or node is Button:
		text_value = str(node.get("text"))
	if not text_value.is_empty() and _contains_cjk(text_value):
		leaks.append("%s=%s" % [str(node.name), text_value.replace("\n", " ")])
	for child in node.get_children():
		_collect_visible_cjk(child, leaks)


func _contains_cjk(text_value: String) -> bool:
	for index in text_value.length():
		var code := text_value.unicode_at(index)
		if (code >= 0x3400 and code <= 0x9fff) or (code >= 0xf900 and code <= 0xfaff):
			return true
	return false


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
		print("PASS: English core UI localization smoke")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
