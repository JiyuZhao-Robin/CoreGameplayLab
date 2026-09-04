extends Node

const MainScene := preload("res://src/ui/main.tscn")
const UiTokens := preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	var ships_before := Game.state.ships.duplicate(true)
	var formations_before := Game.state.fleet_formations.duplicate(true)
	var main := MainScene.instantiate() as Control
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1672, 941)
	add_child(main)
	await _settle()
	var ships_navigation := main.find_child("Navigation_ships", true, false) as Button
	ships_navigation.pressed.emit()
	await _settle()

	var scale := UiTokens.ui_scale()
	var top_bar := main.find_child("TopStatusBar", true, false) as Control
	var navigation := main.find_child("WorkspaceNavigationBar", true, false) as Control
	var filters := main.find_child("FleetRosterFilters", true, false) as Control
	var body := main.find_child("FleetRosterMasterDetail", true, false) as Control
	var browser := main.find_child("FleetRosterListSurface", true, false) as Control
	var inspector := main.find_child("FleetRosterInspectorSurface", true, false) as Control
	var row := main.find_child("FleetRosterShip_*", true, false) as Control
	var visual := main.find_child("FleetRosterShipVisualPanel", true, false) as Control
	var operational := main.find_child("FleetRosterOperationalStatusPanel", true, false) as Control
	var basic := main.find_child("FleetRosterBasicInformationPanel", true, false) as Control
	var configuration := main.find_child("FleetRosterConfigurationSummaryPanel", true, false) as Control
	var readiness := main.find_child("FleetRosterReadinessPanel", true, false) as Control
	var footer := main.find_child("FleetRosterFooterActions", true, false) as Control

	_check(main.scale.is_equal_approx(Vector2.ONE) and is_equal_approx(main.get_window().content_scale_factor, 1.0), "STEP 11 uses native layout and rerasterized fonts without Control/content transforms")
	var row_ship_id := String(Game.state.ships[0].get("instance_id", "")) if not Game.state.ships.is_empty() else ""
	var row_content_controls: Array = [
		main.find_child("FleetRosterSelectionControl_%s" % row_ship_id, true, false),
		main.find_child("FleetRosterShipName_%s" % row_ship_id, true, false),
		main.find_child("FleetRosterHullClass_%s" % row_ship_id, true, false),
		main.find_child("FleetRosterLifecycle_%s" % row_ship_id, true, false),
		main.find_child("FleetRosterFormation_%s" % row_ship_id, true, false)
	]
	_check(_inside(row, row_content_controls), "dense ShipRow contains its checkbox and both left/right information lines")
	_check(Game.state.ships == ships_before and Game.state.fleet_formations == formations_before, "visual polish does not mutate canonical ships or formations")
	if is_equal_approx(scale, 1.5):
		_check(_near(top_bar.size.y, 52.0, 1.0) and _near(navigation.size.y, 53.0, 1.0), "150% compact shell matches Golden 52/53 px bands")
		_check(_near(filters.global_position.y, 223.0, 2.0) and _near(filters.size.y, 36.0, 1.0), "150% lifecycle/query controls align to the Golden filter band")
		_check(_near(body.global_position.y, 272.0, 2.0) and _near(body.size.y, 640.0, 2.0), "150% Master–Detail workspace matches Golden vertical bounds")
		_check(_near(browser.size.x, 553.0, 2.0) and _near(inspector.size.x, 1039.0, 2.0) and _near(inspector.global_position.x - browser.get_global_rect().end.x, 21.0, 1.0), "accepted Master–Detail horizontal geometry remains intact")
		_check(_near(row.size.y, 61.0, 1.0), "150% ShipRow matches the Golden dense asset-entry height")
		_check(_same_size(visual, Vector2(547, 211)) and _same_size(operational, Vector2(440, 211)), "upper Inspector panels retain accepted Golden dimensions")
		_check(_same_size(basic, Vector2(242, 266)) and _same_size(configuration, Vector2(290, 266)) and _same_size(readiness, Vector2(437, 266)), "lower Inspector panels retain accepted Golden dimensions")
		_check(_near(footer.size.y, 44.0, 1.0), "Inspector footer retains the 44 px action height")
	else:
		_check(row.size.y >= UiTokens.full_scale_px(61.0 / 1.5), "100% dense row honors its full-scale minimum")
		_check(_inside(browser, [row]) and _inside(inspector, [visual, operational, basic, configuration, readiness, footer]), "100% Browser and Inspector remain unclipped and structurally equivalent")

	if failures.is_empty():
		print("SHIP_REGISTRY_STEP11_TEST_PASS scale=%d" % UiTokens.ui_scale_percent())
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _inside(parent: Control, controls: Array) -> bool:
	if not is_instance_valid(parent):
		return false
	var bounds := parent.get_global_rect().grow(1.0)
	for control_value in controls:
		var control := control_value as Control
		if is_instance_valid(control) and control.visible and not bounds.encloses(control.get_global_rect()):
			return false
	return true


func _near(actual: float, expected: float, tolerance: float) -> bool:
	return absf(actual - expected) <= tolerance


func _same_size(control: Control, expected: Vector2) -> bool:
	return is_instance_valid(control) and control.size.is_equal_approx(expected)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
