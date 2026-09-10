extends Node

const MainScene := preload("res://src/ui/main.tscn")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var main: Control = MainScene.instantiate()
	add_child(main)
	await _redraw()
	_check(Game.state != null and Game.state.item_quantity("kinetic_munitions", "earth_orbit") == 120, "formal Lab New Game owns real Main Base inventory")
	var earth_button := main.find_child("Location_earth_orbit", true, false) as Button
	_check(earth_button != null, "System Map exposes known Earth Orbit Location")
	if earth_button == null:
		_finish()
		return
	earth_button.pressed.emit()
	await _redraw()
	_check(main.get("_selected_location_id") == "earth_orbit", "clicking System Map enters Earth Orbit Location")
	_check(main.find_child("LocationOperationsWorkspace", true, false) != null, "Location opens the integrated operations dashboard")
	var snapshot: Dictionary = Game.location_operations_snapshot("earth_orbit")
	_check((snapshot.get("inventory", []) as Array).any(func(row): return row.get("id", "") == "kinetic_munitions" and int(row.get("quantity", 0)) == 120), "dashboard projects real starter inventory")
	for action in ["LocationResourcesOpen", "LocationOpenProduction", "LocationInventoryOpen", "LocationTasksOpen", "LocationOpenFleet", "LocationEnvironmentDetailsButton"]:
		_check(main.find_child(action, true, false) != null, "integrated action %s is reachable" % action)
	_check(main.find_child("LocationTab_resources", true, false) == null, "dashboard does not retain obsolete resource tabs")
	main.call("_on_location_operations_action", {"kind":"OPEN_LOGISTICS"})
	await _redraw()
	var advanced_policy_toggle := main.find_child("LogisticsPolicyAdvancedToggle", true, false) as Button
	_check(advanced_policy_toggle != null, "Logistics keeps per-product administration behind an explicit Advanced Policy Exceptions control")
	if advanced_policy_toggle != null:
		advanced_policy_toggle.pressed.emit()
		await _redraw()
	_check(main.find_child("LogisticsItemSelector", true, false) != null, "Logistics can add a policy for any content item")
	_check(not _has_text_fragment(main, "Shipment is intentionally not implemented"), "Logistics no longer renders the Phase 1 placeholder")
	main.call("_open_location_section", "earth_orbit", "tasks")
	await _redraw()
	_check(main.find_child("LocationTasksOpen", true, false) != null, "legacy projects route returns to integrated live tasks")
	_finish()


func _redraw() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.21).timeout
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	await get_tree().process_frame


func _has_text_fragment(node: Node, fragment: String) -> bool:
	if node is Label and fragment in str(node.text):
		return true
	if node is RichTextLabel and fragment in str(node.text):
		return true
	if node is Button and fragment in str(node.text):
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
		print("PASS: Lab System Map to Location Overview UI smoke")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
