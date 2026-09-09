extends SceneTree

## Render real production controls at the physical target. This is a bounded
## screenshot inventory, not a long progression/Journey test or mockup renderer.
var output_root := "res://artifacts/ui/4k-review/before"
var scenario := "fresh"
var locale := "zh_CN"
var target := Vector2i(3840, 2160)
var strict := false
var review_pages: PackedStringArray = []
var records: Array[Dictionary] = []
var failures: Array[String] = []
var main: Control
var game: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	for value in OS.get_cmdline_user_args():
		var arg := str(value)
		if arg.begins_with("--review-output="):
			output_root = arg.get_slice("=", 1)
		elif arg.begins_with("--review-scenario="):
			scenario = arg.get_slice("=", 1)
		elif arg.begins_with("--review-locale="):
			locale = arg.get_slice("=", 1)
		elif arg.begins_with("--review-pages="):
			review_pages = arg.get_slice("=", 1).split(",")
		elif arg == "--review-strict":
			strict = true
		elif arg.begins_with("--review-window="):
			var parts := arg.get_slice("=", 1).split("x")
			target = Vector2i(int(parts[0]), int(parts[1]))
	root.size = target
	root.position = Vector2i.ZERO
	root.gui_embed_subwindows = true
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	game.reset_game()
	root.get_node("I18n").set_locale(locale)
	if scenario != "fresh":
		var builder = load("res://tests/gameplay_scenario_builder.gd").new(game.content)
		if not builder.activate(scenario):
			push_error("Invalid recorded scenario: " + scenario)
			quit(2)
			return
	main = load("res://src/ui/main.tscn").instantiate()
	root.add_child(main)
	await _settle()
	for page in ["system_map", "location", "industry", "inventory", "logistics", "construction", "research", "fleet", "frontier", "expedition", "megastructure", "diagnostics"]:
		if not review_pages.is_empty() and not page in review_pages:
			continue
		main.call("_switch_page", page)
		await _settle()
		if page == "location":
			for section in ["overview", "resources", "industry"]:
				main.call("_select_location_section", section)
				main.call("_rebuild_active_page")
				await _capture("location-" + section)
		elif page == "fleet":
			for section in ["roster", "readiness", "shipyard", "archive"]:
				main.call("_select_fleet_section", section)
				main.call("_rebuild_active_page")
				await _capture("fleet-" + section)
				if section == "roster":
					var dispatch := main.find_child("FleetRosterDispatch", true, false) as Button
					if dispatch != null and not dispatch.disabled:
						dispatch.pressed.emit()
						await _capture("fleet-dispatch-menu")
						var popup := main.find_child("FleetRosterDispatchMenu", true, false) as PopupMenu
						_assert_capture(popup != null and popup.visible, "fleet-dispatch-menu rendered its real visible dispatch popup")
						if popup != null:
							popup.hide()
						await _clear_fleet_roster_capture_transients()
					for capture_value in [
						{"state":"step09_ship_type_open", "id":"fleet-roster-ship-type-dropdown", "node":"FleetRosterShipTypeFilter", "kind":"query_popup"},
						{"state":"step09_formation_open", "id":"fleet-roster-formation-dropdown", "node":"FleetRosterFormationFilter", "kind":"query_popup"},
						{"state":"step09_sort_open", "id":"fleet-roster-sort-dropdown", "node":"FleetRosterSort", "kind":"query_popup"},
						{"state":"step11_more_open", "id":"fleet-roster-more-menu", "node":"FleetRosterMoreMenu", "kind":"popup"},
						{"state":"step11_bulk_actions_open", "id":"fleet-roster-bulk-actions-menu", "node":"FleetRosterBulkActionsMenu", "kind":"popup"},
						{"state":"step11_dismantle_modal", "id":"fleet-roster-dismantle-confirmation", "node":"FleetRosterDismantleConfirmation", "kind":"dialog"},
						{"state":"step11_bulk_dismantle_modal", "id":"fleet-roster-bulk-dismantle-confirmation", "node":"FleetRosterBulkDismantleConfirmation", "kind":"dialog"}
					]:
						await _capture_fleet_roster_interaction(capture_value as Dictionary)
				elif section == "shipyard":
					var library_tabs := main.find_child("AssemblyLibraryTabs", true, false) as TabContainer
					library_tabs.current_tab = 1
					await _capture("fleet-shipyard-modules")
					var map := main.find_child("ShipAssemblyMap", true, false)
					map.call("_drop_data", Vector2(620, 260), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
					map.call("_drop_data", Vector2(120, 160), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
					map.call("request_module_connection", "ship_design_module_0001", "socket_weapon_0")
					await _capture("fleet-shipyard-assembly")
					var module := map.get_node_or_null("ship_design_module_0001")
					if module != null:
						map.call("_on_node_selected", module)
						await _capture("fleet-shipyard-module-inspector")
		elif page == "industry":
			var workspace := main.find_child("FactoryWorkspace", true, false)
			if workspace != null:
				for section in ["OVERVIEW", "CANVAS", "PRODUCTION", "CONSTRUCTION"]:
					workspace.call("_set_active_subworkspace", section)
					await _capture("industry-" + section.to_lower())
			else:
				await _capture("industry-unavailable")
		else:
			await _capture(page)
			if page == "logistics":
				main.call("_toggle_logistics_advanced")
				main.call("_rebuild_active_page")
				await _capture("logistics-advanced")
				main.call("_toggle_logistics_advanced")
			elif page == "research":
				main.call("_select_research_project", "research_industrial_coordination")
				await _capture("research-selected")
	main.call("_request_reset_game")
	await _capture("reset-confirmation")
	var reset_dialog := main.find_child("ResetConfirmation", true, false)
	if reset_dialog != null:
		reset_dialog.queue_free()
	var absolute := ProjectSettings.globalize_path(output_root.path_join("review-index.json"))
	var index := FileAccess.open(absolute, FileAccess.WRITE)
	index.store_string(JSON.stringify({"scenario":scenario, "locale":locale, "physical_window":_vector(target), "surfaces":records, "failures":failures}, "\t"))
	index.close()
	main.queue_free()
	await process_frame
	print("UI_4K_REVIEW_CAPTURE_%s: %d surfaces · %s" % ["PASS" if failures.is_empty() else "FAIL", records.size(), output_root])
	quit(0 if failures.is_empty() else 1)

func _capture(id: String) -> void:
	await _settle()
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	var path := ProjectSettings.globalize_path(output_root.path_join(id + ".png"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if picture.save_png(path) != OK:
		failures.append("Cannot save " + id)
	var active: Control = main.get("_page_controls").get(main.get("_active_page_key"))
	var outer_scroll := 0.0
	if active is ScrollContainer:
		outer_scroll = maxf(0.0, active.get_v_scroll_bar().max_value - active.get_v_scroll_bar().page)
	var viewport_bounds := Rect2(Vector2.ZERO, root.get_visible_rect().size)
	var record := {"id":id, "file":path, "pixels":_vector(picture.get_size()), "logical_viewport":_vector(root.get_visible_rect().size), "page_rect":_rect(active.get_global_rect()), "outer_scroll_overflow":outer_scroll, "scroll_regions":[]}
	_collect_scrolls(active, record["scroll_regions"])
	if strict and (outer_scroll > 1.0 or not viewport_bounds.grow(1).encloses(active.get_global_rect())):
		failures.append("Whole workspace overflow: " + id)
	var content: Control = main.get("_pages").get(main.get("_active_page_key"))
	if strict and not active.get_global_rect().grow(1).encloses(content.get_global_rect()):
		failures.append("Workspace content exceeds its authored host: " + id + " " + str(content.get_global_rect()))
	if strict:
		var minimum := content.get_combined_minimum_size()
		if minimum.x > content.size.x + 1 or minimum.y > content.size.y + 1:
			failures.append("Workspace minimum exceeds authored area: " + id + " " + str(minimum))
		_check_interactive_bounds(content, active.get_global_rect().grow(1), id)
	record["content_rect"] = _rect(content.get_global_rect())
	records.append(record)
	print("REVIEW_CAPTURE: %s pixels=%s outer_scroll=%.1f" % [id, picture.get_size(), outer_scroll])


func _capture_fleet_roster_interaction(capture: Dictionary) -> void:
	var state_name := String(capture.get("state", ""))
	var id := String(capture.get("id", "fleet-roster-unnamed-interaction"))
	var expected_node := String(capture.get("node", ""))
	var expected_kind := String(capture.get("kind", ""))
	# Main owns the hardened live-control setup (including the small, reversible
	# lock/bulk-selection fixture). The capture harness only asks for that state,
	# proves it rendered, captures it, then cancels/hides every transient.
	main.set("_capture_validation_error", "")
	await main.call("_prepare_fleet_roster_capture_state", state_name)
	var validation_error := String(main.get("_capture_validation_error"))
	var expected_visible := _fleet_roster_capture_transient_visible(expected_node, expected_kind)
	_assert_capture(validation_error.is_empty(), "%s helper completed without capture validation error: %s" % [id, validation_error])
	_assert_capture(expected_visible, "%s rendered its real visible %s: %s" % [id, expected_kind, expected_node])
	await _capture(id)
	_assert_capture(String(main.get("_capture_validation_error")).is_empty(), "%s capture completed without validation error" % id)
	await _clear_fleet_roster_capture_transients()


func _fleet_roster_capture_transient_visible(node_name: String, kind: String) -> bool:
	if not is_instance_valid(main):
		return false
	if kind == "query_popup":
		var menu_button := main.find_child(node_name, true, false) as MenuButton
		return is_instance_valid(menu_button) and is_instance_valid(menu_button.get_popup()) and menu_button.get_popup().visible
	if kind == "popup":
		var popup := main.find_child(node_name, true, false) as PopupMenu
		return is_instance_valid(popup) and popup.visible
	if kind == "dialog":
		var dialog := main.find_child(node_name, true, false) as Control
		return is_instance_valid(dialog) and dialog.is_visible_in_tree()
	return false


func _clear_fleet_roster_capture_transients() -> void:
	if not is_instance_valid(main):
		return
	# Query dropdowns own their PopupMenu, while roster action menus are transient
	# children of Main. Close both categories before the next fixture state.
	for control_name in ["FleetRosterShipTypeFilter", "FleetRosterFormationFilter", "FleetRosterSort"]:
		var menu_button := main.find_child(control_name, true, false) as MenuButton
		if is_instance_valid(menu_button) and is_instance_valid(menu_button.get_popup()) and menu_button.get_popup().visible:
			menu_button.get_popup().hide()
	for popup_value in main.find_children("*", "PopupMenu", true, false):
		var popup := popup_value as PopupMenu
		if is_instance_valid(popup) and popup.visible:
			popup.hide()
	# Never confirm a destructive dialog during a visual audit. Cancelling drives
	# the production callback, which also releases Main's transient reference.
	for dialog_name in ["FleetRosterDismantleConfirmation", "FleetRosterBulkDismantleConfirmation"]:
		var dialog := main.find_child(dialog_name, true, false)
		if is_instance_valid(dialog) and dialog.has_signal("canceled"):
			dialog.emit_signal("canceled")
	await _settle()
	for control_name in ["FleetRosterShipTypeFilter", "FleetRosterFormationFilter", "FleetRosterSort"]:
		var menu_button := main.find_child(control_name, true, false) as MenuButton
		_assert_capture(not is_instance_valid(menu_button) or not menu_button.get_popup().visible, "cleared query popup after fleet roster capture: %s" % control_name)
	for popup_value in main.find_children("*", "PopupMenu", true, false):
		var popup := popup_value as PopupMenu
		_assert_capture(not is_instance_valid(popup) or not popup.visible, "cleared action popup after fleet roster capture: %s" % popup.name)
	for dialog_name in ["FleetRosterDismantleConfirmation", "FleetRosterBulkDismantleConfirmation"]:
		var dialog := main.find_child(dialog_name, true, false) as Control
		_assert_capture(not is_instance_valid(dialog) or not dialog.is_visible_in_tree(), "cancelled destructive dialog after fleet roster capture: %s" % dialog_name)


func _assert_capture(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _check_interactive_bounds(node: Node, bounds: Rect2, id: String) -> void:
	if node is Control and not node.is_visible_in_tree():
		return
	# A named, bounded list or graph camera owns its own content clipping.
	# Its host must still fit the workspace; clipping never excuses a bad host.
	if node is ScrollContainer or node is GraphEdit:
		if not bounds.encloses(node.get_global_rect()):
			failures.append("Scrollable/camera host outside workspace: " + id + "/" + str(node.name))
		return
	if node is BaseButton or node is LineEdit or node is Range:
		if not bounds.encloses(node.get_global_rect()):
			failures.append("Interactive control clipped: " + id + "/" + str(node.name))
	for child in node.get_children():
		_check_interactive_bounds(child, bounds, id)


func _collect_scrolls(node: Node, result: Array) -> void:
	if node is Control and not node.is_visible_in_tree():
		return
	if node is ScrollContainer:
		result.append({"name":str(node.name), "rect":_rect(node.get_global_rect()), "vertical_overflow":maxf(0, node.get_v_scroll_bar().max_value - node.get_v_scroll_bar().page)})
	for child in node.get_children():
		_collect_scrolls(child, result)

func _settle() -> void:
	for frame in 8:
		await process_frame

func _vector(value: Vector2) -> Array:
	return [value.x, value.y]

func _rect(value: Rect2) -> Array:
	return [value.position.x, value.position.y, value.size.x, value.size.y]
