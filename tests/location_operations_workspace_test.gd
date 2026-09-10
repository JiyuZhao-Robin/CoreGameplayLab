extends SceneTree

## Presentation contract for the standalone Location operations board. The
## fixture exercises only immutable snapshot rendering and emitted intents.

const WorkspaceScript = preload("res://src/ui/workspaces/location/location_operations_workspace.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const LocalizationScript = preload("res://src/application/localization.gd")

var failures: Array[String] = []
var intents: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	UiTokens.set_ui_scale(1.0)
	var i18n := get_root().get_node_or_null("I18n")
	var owns_i18n := i18n == null
	if owns_i18n:
		i18n = LocalizationScript.new()
		i18n.name = "I18n"
		get_root().add_child(i18n)
		await process_frame
	i18n.call("set_locale", "en")
	var host := Control.new()
	host.name = "LocationOperationsWorkspaceTestHost"
	host.size = Vector2(1920, 1080)
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.action_requested.connect(func(action: Dictionary) -> void: intents.append(action.duplicate(true)))
	workspace.configure(_fixture())
	await process_frame
	await process_frame
	# Optional rendered evidence uses the explicit synthetic fixture, never
	# grants production goods to the real Game state or writes into the repo.
	for argument in OS.get_cmdline_user_args():
		if str(argument).begins_with("--stock-ui-capture="):
			root.size = Vector2i(1920, 1080)
			await process_frame
			await RenderingServer.frame_post_draw
			var path := str(argument).trim_prefix("--stock-ui-capture=")
			_check(root.get_texture().get_image().save_png(path) == OK, "populated UI fixture screenshot saves")

	_test_snapshot_rendering_and_commands(workspace)
	await _test_anno_warehouse_tiles(workspace)
	await _test_authoritative_empty_and_prospect_actions(workspace)
	_test_survey_selection_and_assignment(workspace)
	_test_live_progress_and_resource_visibility(workspace)
	_test_fixed_dashboard_layout(workspace)
	await _test_200_percent_compact_height()
	_test_chinese_catalog_rendering(workspace, i18n)

	host.queue_free()
	if owns_i18n:
		i18n.queue_free()
	await process_frame
	_finish()


func _test_snapshot_rendering_and_commands(workspace: Control) -> void:
	var title := workspace.find_child("LocationOperationsTitle", true, false) as Label
	var power := workspace.find_child("LocationKpiPower", true, false) as Control
	var factory := workspace.find_child("LocationOpenFactory", true, false) as Button
	var inventory := workspace.find_child("LocationInventoryOpen", true, false) as Button
	var resource := workspace.find_child("LocationResourceiron_ore", true, false) as Button
	var remote_resource := workspace.find_child("LocationResourcecopper_ore", true, false) as Button
	var facility := workspace.find_child("LocationFacilityiron_line", true, false) as Button
	var task := workspace.find_child("LocationTaskbuild_foundry", true, false) as Button
	var iron_card := workspace.find_child("InventoryRow_iron_ingot", true, false) as Panel
	var electronics_card := workspace.find_child("InventoryRow_electronics", true, false) as Panel
	var storage := workspace.find_child("LocationKpiStorage", true, false) as Control
	var before := intents.size()
	if factory != null:
		factory.pressed.emit()
	var factory_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if inventory != null:
		inventory.pressed.emit()
	var inventory_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if resource != null:
		resource.pressed.emit()
	var resource_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if remote_resource != null:
		remote_resource.pressed.emit()
	var remote_resource_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if task != null:
		task.pressed.emit()
	var task_action: Dictionary = intents.back() if intents.size() > before else {}
	_check(
		title != null and title.text == "Earth Orbit"
		and power != null and _descendant_text(power).contains("120 / 96 kW")
		and _action_is(factory_action, "OPEN_FACTORY") and str(factory_action.get("section", "")) == "OVERVIEW"
		and _action_is(inventory_action, "OPEN_INVENTORY")
		and _action_is(resource_action, "OPEN_FACTORY") and str(resource_action.get("section", "")) == "CANVAS"
		and str(resource_action.get("entity_id", "")) == "extractor_iron"
		and _action_is(remote_resource_action, "OPEN_FACTORY") and str(remote_resource_action.get("world_id", "")) == "lunar_grid"
		and facility != null and facility.tooltip_text.contains("Iron Ingot 240/h")
		and _action_is(task_action, "OPEN_FACTORY") and str(task_action.get("order_id", "")) == "order_foundry",
		"snapshot values render on stable nodes and every tested dashboard route emits its exact authoritative command payload"
	)
	var iron_fill := iron_card.get_meta("fill") as ColorRect if iron_card != null else null
	var iron_trend := iron_card.get_meta("trend") as Label if iron_card != null else null
	var electronics_trend := electronics_card.get_meta("trend") as Label if electronics_card != null else null
	var iron_track := iron_card.find_child("StorageTrack", true, false) as Control if iron_card != null else null
	var iron_quantity := iron_card.get_meta("quantity") as Label if iron_card != null else null
	_check(iron_card != null and iron_fill != null and iron_track != null and iron_fill.get_parent() == iron_track and is_equal_approx(iron_fill.anchor_top, 0.52), "the iron item card renders its 48% per-item capacity in the dedicated vertical storage track")
	_check(iron_trend != null and iron_trend.text.begins_with("▲"), "positive sampled net rate renders the green surplus triangle")
	_check(electronics_trend != null and electronics_trend.text.begins_with("▼"), "negative sampled net rate renders the red consumption triangle")
	_check(iron_quantity != null and iron_quantity.visible and iron_quantity.text.contains("2400"), "known inventory renders a compact quantity label without a material-name label")
	_check(storage != null and _descendant_text(storage).contains("2 / 3"), "the storage KPI reports stocked item slots rather than a shared aggregate warehouse quota")


func _test_anno_warehouse_tiles(workspace: Control) -> void:
	var fixture := _inventory_fixture_with_slots(13)
	fixture["inventory"][0]["quantity"] = 2500
	fixture["inventory"][0]["fill_ratio"] = 0.5
	workspace.configure(fixture)
	await process_frame
	await process_frame
	for container_name in ["LocationResourcesRows", "LocationInventoryRows"]:
		var grid := workspace.find_child(container_name, true, false) as GridContainer
		_check(grid != null and grid.columns == 12, "materials use the fixed twelve-column Anno warehouse grid")
		_check(_tile_width_for_grid(grid) > 0.0, "warehouse grid has a positive twelve-slot usable width")
		for tile_value in grid.get_children():
			var tile := tile_value as Control
			var expected_width := _tile_width_for_grid(grid)
			_check(tile != null and is_equal_approx(tile.size.x, tile.size.y) and is_equal_approx(tile.size.x, expected_width), "every warehouse slot is a square sized from the panel width divided by twelve")
			var icon := tile.get_meta("icon") as Control
			var quantity := tile.get_meta("quantity") as Label
			var trend := tile.get_meta("trend") as Label
			var track := tile.find_child("StorageTrack", true, false) as Control
			var fill := tile.get_meta("fill") as ColorRect
			_check(icon != null and icon.call("art_texture") is AtlasTexture and absf(icon.get_global_rect().get_center().x - tile.get_global_rect().get_center().x) <= tile.size.x * 0.08 and icon.get_global_rect().get_center().y <= tile.get_global_rect().position.y + tile.size.y * 0.42, "the generated material art is centered in the upper portion of every warehouse slot")
			var concealed_resource := tile.name == "ResourceRow_silicate"
			if concealed_resource:
				_check(quantity != null and not quantity.visible, "unrevealed resource slots do not expose a quantity label")
			else:
				_check(quantity != null and quantity.visible and quantity.get_global_rect().position.x <= tile.get_global_rect().position.x + tile.size.x * 0.35 and quantity.get_global_rect().end.y >= tile.get_global_rect().end.y - 2.0, "known stock quantity stays at the lower-left of the square without material-name text")
			if concealed_resource:
				_check(trend != null and trend.text == "—" and not trend.visible, "unrevealed resources retain no visible trend reading")
			else:
				_check(trend != null and trend.visible and trend.text in ["▲", "▼", "▶"] and trend.get_global_rect().position.x >= tile.get_global_rect().position.x + tile.size.x * 0.60 and trend.get_global_rect().end.y >= tile.get_global_rect().end.y - 2.0, "surplus, consumption, and stable markers occupy the lower-right of the square")
			_check(track != null and fill != null and fill.get_parent() == track and track.get_global_rect().position.x >= tile.get_global_rect().position.x + tile.size.x * 0.78 and _inside(track, tile), "each item has its own vertical capacity bar on the right rather than a full-card liquid fill")
			_check(tile.find_child("Name", true, false) == null and tile.find_child("Detail", true, false) == null and tile.find_child("Status", true, false) == null, "warehouse slots keep material identity out of permanent text labels")
			var action := tile.get_meta("action") as Button
			_check(action != null and action.text.is_empty() and action.focus_mode == Control.FOCUS_ALL and not action.accessibility_name.is_empty(), "icon-only warehouse tiles retain keyboard and accessibility identity")
	var inventory_grid := workspace.find_child("LocationInventoryRows", true, false) as GridContainer
	var inventory_tiles := inventory_grid.get_children()
	var first_slot := inventory_tiles[0] as Control
	var twelfth_slot := inventory_tiles[11] as Control
	var thirteenth_slot := inventory_tiles[12] as Control
	_check(twelfth_slot.get_global_rect().end.x >= inventory_grid.get_global_rect().end.x - UiTokens.layout_px(12), "the twelfth warehouse slot reaches the grid's right edge within one integer-slot remainder")
	_check(is_equal_approx(first_slot.get_global_rect().position.y, twelfth_slot.get_global_rect().position.y) and thirteenth_slot.get_global_rect().position.y > first_slot.get_global_rect().position.y + 2.0 and absf(thirteenth_slot.get_global_rect().position.x - inventory_grid.get_global_rect().position.x) <= 2.0, "the thirteenth item wraps to the first column of the next fixed twelve-slot row")
	for sample in [["iron_ingot", 0.5], ["electronics", 1.0], ["machine_components", 0.0]]:
		var tile := workspace.find_child("InventoryRow_" + str(sample[0]), true, false) as Panel
		var track := tile.find_child("StorageTrack", true, false) as Control
		var fill := tile.get_meta("fill") as ColorRect
		_check(tile.visible and fill.get_parent() == track and is_equal_approx(fill.anchor_top, 1.0 - float(sample[1])) and is_equal_approx(fill.size.x, track.size.x) and is_equal_approx(fill.position.y + fill.size.y, track.size.y) and is_equal_approx(fill.size.y, track.size.y * float(sample[1])), "0/50/100 percent stock changes only the dedicated vertical capacity bar")
	var iron := workspace.find_child("InventoryRow_iron_ingot", true, false) as Panel
	var original_id := iron.get_instance_id()
	var action := iron.get_meta("action") as Button
	var quantity := iron.get_meta("quantity") as Label
	var pointer := InputEventMouseMotion.new()
	pointer.position = action.get_global_rect().get_center()
	root.push_input(pointer, true)
	await process_frame
	_check(action.is_hovered(), "hover regression fixture really hovers the warehouse tile")
	fixture["inventory"][0]["quantity"] = 3750
	fixture["inventory"][0]["fill_ratio"] = 0.75
	fixture["inventory"][0]["net_rate_per_minute"] = -3.0
	workspace.configure(fixture)
	_check(iron.get_instance_id() == original_id and is_equal_approx((iron.get_meta("fill") as ColorRect).anchor_top, 0.25) and (iron.get_meta("trend") as Label).text == "▼" and quantity.text.contains("3750") and action.tooltip_text.contains("3750"), "hover cannot freeze capacity, trend, quantity, or tooltip and does not rebuild the selected tile")
	pointer = InputEventMouseMotion.new()
	pointer.position = Vector2(1919, 0)
	root.push_input(pointer, true)
	await process_frame
	action.grab_focus()
	var intent_count := intents.size()
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	root.push_input(key, true)
	key = InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = false
	root.push_input(key, true)
	_check(intents.size() == intent_count + 1 and _action_is(intents.back(), "OPEN_INVENTORY"), "keyboard Enter activates the focused icon-only inventory tile")
	# Even malformed presentation fixtures must not leak hidden readings through
	# art, quantity, capacity, trend, tooltip, or assistive text.
	fixture["resources"][1].merge({"item_id":"silicate_ore", "quantity":50, "capacity":50, "fill_ratio":1.0, "grade":0.87, "trend_known":true, "net_rate_per_minute":12}, true)
	workspace.configure(fixture)
	var unknown := workspace.find_child("ResourceRow_silicate", true, false) as Panel
	var unknown_quantity := unknown.get_meta("quantity") as Label
	var unknown_action := unknown.get_meta("action") as Button
	_check(not unknown_quantity.visible and is_equal_approx((unknown.get_meta("fill") as ColorRect).anchor_top, 1.0) and (unknown.get_meta("trend") as Label).text == "—" and int((unknown.get_meta("icon") as Control).call("art_index")) == 31 and not unknown_action.tooltip_text.contains("Silicate") and not unknown_action.accessibility_name.contains("Silicate"), "unrevealed resource art, quantity, capacity, trend, tooltip, and accessibility all stay opaque to hidden data")
	workspace.configure(_fixture())
	await process_frame


func _test_survey_selection_and_assignment(workspace: Control) -> void:
	var selector := workspace.find_child("LocationSurveyShip", true, false) as OptionButton
	var start := workspace.find_child("LocationStartSurvey", true, false) as Button
	var before := intents.size()
	if selector != null:
		selector.select(1)
		selector.item_selected.emit(1)
	var initial_first_disabled := selector != null and selector.is_item_disabled(0)
	var initial_second_enabled := selector != null and not selector.is_item_disabled(1)
	if start != null:
		start.pressed.emit()
	var start_action: Dictionary = intents.back() if intents.size() > before else {}
	var assignment_fixture := _fixture()
	assignment_fixture["survey"]["ships"] = [{"id":"iss_pioneer", "name":"ISS Pioneer", "allowed":false, "can_assign":true, "reason":"Not assigned to Survey Formation"}]
	workspace.configure(assignment_fixture)
	var assign := workspace.find_child("LocationAssignSurveyShip", true, false) as Button
	var assign_was_visible := assign != null and assign.visible
	before = intents.size()
	if assign != null:
		assign.pressed.emit()
	var assign_action: Dictionary = intents.back() if intents.size() > before else {}
	var no_capability_fixture := _fixture()
	no_capability_fixture["survey"]["ships"] = [{"id":"freighter", "name":"Freighter", "allowed":false, "can_assign":false, "reason":"No deep-survey capability"}]
	workspace.configure(no_capability_fixture)
	start = workspace.find_child("LocationStartSurvey", true, false) as Button
	before = intents.size()
	if start != null:
		start.pressed.emit()
	var shipyard_action: Dictionary = intents.back() if intents.size() > before else {}
	var blocked_fixture := _fixture()
	blocked_fixture["survey"]["ships"] = [{"id":"formed_sensor_ship", "name":"Formed Sensor Ship", "allowed":false, "can_assign":false, "reason":"Missing sensor charge"}]
	blocked_fixture["survey"]["can_start"] = false
	workspace.configure(blocked_fixture)
	var blocked_start := workspace.find_child("LocationStartSurvey", true, false) as Button
	var blocked_start_is_disabled := blocked_start != null and blocked_start.disabled
	var blocked_start_is_not_shipyard := blocked_start != null and blocked_start.text != "Configure Survey Ship"
	var complete_fixture := _fixture()
	complete_fixture["survey"]["next_state"] = ""
	complete_fixture["survey"]["ships"] = []
	complete_fixture["survey"]["can_start"] = false
	workspace.configure(complete_fixture)
	var complete_start := workspace.find_child("LocationStartSurvey", true, false) as Button
	var complete_start_is_disabled := complete_start != null and complete_start.disabled
	var complete_start_text := complete_start.text if complete_start != null else ""
	var active_fixture := _fixture()
	active_fixture["survey"]["active"] = true
	active_fixture["survey"]["target_location_id"] = "lunar_space"
	workspace.configure(active_fixture)
	var active_start := workspace.find_child("LocationStartSurvey", true, false) as Button
	before = intents.size()
	if active_start != null:
		active_start.pressed.emit()
	var active_action: Dictionary = intents.back() if intents.size() > before else {}
	_check(
		initial_first_disabled and initial_second_enabled
		and _action_is(start_action, "START_SURVEY") and str(start_action.get("ship_id", "")) == "surveyor_alpha" and str(start_action.get("next_state", "")) == "SURVEYED"
		and assign_was_visible and _action_is(assign_action, "ASSIGN_SURVEY_SHIP") and str(assign_action.get("ship_id", "")) == "iss_pioneer"
		and _action_is(shipyard_action, "OPEN_SURVEY_SHIPYARD")
		and blocked_start_is_disabled and blocked_start_is_not_shipyard
		and complete_start_is_disabled and complete_start_text == "Survey complete"
		and _action_is(active_action, "OPEN_SURVEY") and str(active_action.get("location_id", "")) == "lunar_space",
		"survey selection distinguishes no capability from material blockers and terminal survey completion while preserving assignment and shipyard actions"
	)


func _test_authoritative_empty_and_prospect_actions(workspace: Control) -> void:
	var fixture := _fixture()
	fixture["facilities"] = []
	fixture["tasks"] = []
	fixture["industry_empty_action"] = {"kind":"INITIALIZE_FACTORY"}
	fixture["task_empty_action"] = {"kind":"OPEN_FACTORY", "world_id":"earth_grid", "section":"CONSTRUCTION"}
	fixture["resources"][0]["world_id"] = ""
	fixture["resources"][0]["entity_id"] = ""
	fixture["resources"][0]["action"] = {"kind":"OPEN_SURVEY", "location_id":"earth_orbit"}
	workspace.configure(fixture)
	await process_frame
	await process_frame
	var industry_empty := workspace.find_child("LocationFacilityEmptyAction", true, false) as Button
	var task_empty := workspace.find_child("LocationTaskEmptyAction", true, false) as Button
	for button in [industry_empty, task_empty]:
		if button == null:
			continue
		var empty_card := button.get_parent().get_parent() as Control
		var description := empty_card.find_child("EmptyStateDescription", true, false) as Label
		_check(empty_card.size.x > 400 and description != null and description.size.x > 150 and _inside(button, empty_card), "empty production/task cards retain readable horizontal copy and an inside action")
	var prospect := workspace.find_child("LocationResourceiron_ore", true, false) as Button
	var before := intents.size()
	if industry_empty != null:
		industry_empty.pressed.emit()
	var industry_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if task_empty != null:
		task_empty.pressed.emit()
	var task_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if prospect != null:
		prospect.pressed.emit()
	var prospect_action: Dictionary = intents.back() if intents.size() > before else {}
	_check(
		industry_empty != null and _action_is(industry_action, "INITIALIZE_FACTORY")
		and task_empty != null and _action_is(task_action, "OPEN_FACTORY") and str(task_action.get("section", "")) == "CONSTRUCTION"
		and prospect != null and not prospect.disabled and _action_is(prospect_action, "OPEN_SURVEY"),
		"empty-state and prospective-resource cards emit the snapshot-owned intent instead of guessing a global destination or a nonexistent Factory world"
	)
	workspace.configure(_fixture())


func _test_live_progress_and_resource_visibility(workspace: Control) -> void:
	var fixture := _fixture()
	fixture["tasks"][0]["progress"] = 0.24
	fixture["tasks"][0]["remaining_ms"] = 7200000
	workspace.configure(fixture)
	var progress := workspace.find_child("LocationTaskProgress_build_foundry", true, false) as ProgressBar
	var progress_instance_id := progress.get_instance_id() if progress != null else 0
	var detected_row := workspace.find_child("ResourceRow_silicate", true, false) as Control
	var detected_text := _descendant_text(detected_row)
	var detected_icon := detected_row.get_meta("icon") as Control if detected_row != null else null
	var environment_popup := workspace.find_child("LocationEnvironmentPopup", true, false)
	var environment_text := _descendant_text(environment_popup)
	fixture["tasks"][0]["progress"] = 0.76
	fixture["tasks"][0]["remaining_ms"] = 900000
	workspace.configure(fixture)
	var updated_progress := workspace.find_child("LocationTaskProgress_build_foundry", true, false) as ProgressBar
	_check(progress != null and is_equal_approx(progress.value, 76.0), "runtime progress updates the task progress bar in place")
	_check(updated_progress != null and updated_progress.get_instance_id() == progress_instance_id, "runtime progress retains the existing task card instead of rebuilding the list")
	var detected_action := detected_row.get_meta("action") as Button
	_check(not detected_text.contains("Silicate") and detected_action.tooltip_text.contains("Unknown") and not detected_action.tooltip_text.contains("Silicate") and not detected_action.accessibility_name.contains("Silicate"), "unknown resource tile shows no readable material identity and its tooltip cannot leak the hidden material")
	_check(detected_icon != null and str(detected_icon.call("_family")) == "UNKNOWN", "an unrevealed resource resolves to the non-material scan icon")
	_check(str(workspace.call("_remaining_text", {"remaining_ms":-1})).contains("Unknown"), "unknown task duration remains explicitly unknown")
	_check(environment_text.contains("Construction difficulty") and environment_text.contains("Transport distance"), "the environment details retain both construction and transport readings")


func _test_200_percent_compact_height() -> void:
	UiTokens.set_ui_scale(2.0)
	var host := Control.new()
	host.name = "LocationOperationsAccessibilityHost"
	host.size = Vector2(1920, 700)
	get_root().add_child(host)
	var compact_workspace = WorkspaceScript.new()
	compact_workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(compact_workspace)
	var compact_fixture := _inventory_fixture_with_slots(13)
	compact_workspace.configure(compact_fixture)
	await process_frame
	await process_frame
	var resource_scroll := compact_workspace.find_child("LocationResourcesListScroll", true, false) as ScrollContainer
	var inventory_scroll := compact_workspace.find_child("LocationInventoryListScroll", true, false) as ScrollContainer
	var industry_scroll := compact_workspace.find_child("LocationIndustryListScroll", true, false) as ScrollContainer
	var tasks_scroll := compact_workspace.find_child("LocationTasksListScroll", true, false) as ScrollContainer
	var page_scroll := compact_workspace.find_child("LocationOperationsScroll", true, false)
	_check(page_scroll == null, "the compact 200% board does not introduce page-level scrolling")
	_check(resource_scroll != null and resource_scroll.size.y >= UiTokens.layout_px(54), "the 200% resource list keeps one full readable card row")
	_check(inventory_scroll != null and inventory_scroll.size.y >= UiTokens.layout_px(54), "the 200% inventory list keeps one full readable card row")
	var resource_grid := compact_workspace.find_child("LocationResourcesRows", true, false) as GridContainer
	var inventory_grid := compact_workspace.find_child("LocationInventoryRows", true, false) as GridContainer
	_check(resource_grid != null and inventory_grid != null and resource_grid.columns == 12 and inventory_grid.columns == 12, "200% accessibility preserves the fixed twelve-slot warehouse geometry")
	for tile_name in ["ResourceRow_iron_ore", "ResourceRow_copper_ore", "InventoryRow_iron_ingot", "InventoryRow_electronics", "InventoryRow_machine_components"]:
		var tile := compact_workspace.find_child(tile_name, true, false) as Control
		var scroll := resource_scroll if tile_name.begins_with("Resource") else inventory_scroll
		var grid := resource_grid if tile_name.begins_with("Resource") else inventory_grid
		var quantity := tile.get_meta("quantity") as Label if tile != null else null
		var trend := tile.get_meta("trend") as Label if tile != null else null
		var track := tile.find_child("StorageTrack", true, false) as Control if tile != null else null
		_check(tile != null and is_equal_approx(tile.size.x, tile.size.y) and is_equal_approx(tile.size.x, _tile_width_for_grid(grid)) and _inside(tile, scroll) and quantity != null and trend != null and track != null and _inside(track, tile), "200 percent material tiles remain readable twelve-column squares with their quantity, trend, and capacity bar inside the bounded list")
	var compact_slots := inventory_grid.get_children() if inventory_grid != null else []
	var compact_first := compact_slots[0] as Control if compact_slots.size() >= 13 else null
	var compact_twelfth := compact_slots[11] as Control if compact_slots.size() >= 13 else null
	var compact_thirteenth := compact_slots[12] as Control if compact_slots.size() >= 13 else null
	if inventory_scroll != null:
		inventory_scroll.scroll_vertical = int(inventory_scroll.get_v_scroll_bar().max_value)
		await process_frame
	_check(compact_first != null and compact_twelfth != null and compact_thirteenth != null and compact_twelfth.get_global_rect().end.x >= inventory_grid.get_global_rect().end.x - UiTokens.layout_px(12) and compact_thirteenth.get_global_rect().position.y > compact_first.get_global_rect().position.y + 2.0 and _inside(compact_thirteenth, inventory_scroll), "200% warehouse capacity keeps twelve complete slots across, a bounded right edge, and a readable thirteenth wrapped row")
	if inventory_scroll != null:
		inventory_scroll.scroll_vertical = 0
		await process_frame
	_check(industry_scroll != null and industry_scroll.size.y >= UiTokens.layout_px(54), "the 200% industry list keeps one full readable card row")
	_check(tasks_scroll != null and tasks_scroll.size.y >= UiTokens.layout_px(54), "the 200% task list keeps one full readable card row")
	var first_facility := industry_scroll.find_child("FacilityRow_iron_line", true, false) as Control
	var first_task := tasks_scroll.find_child("TaskRow_build_foundry", true, false) as Control
	_check(first_facility != null and first_facility.size.y <= industry_scroll.size.y + 0.5, "200% production list fits an actual complete facility card")
	_check(first_task != null and first_task.size.y <= tasks_scroll.size.y + 0.5 and first_task.size.x >= tasks_scroll.size.x - 25, "200% task row occupies the board width and fits a complete progress card")
	var environment := compact_workspace.find_child("LocationEnvironment", true, false) as Control
	_check(environment != null and _inside(environment, compact_workspace), "200% compact dashboard retains its environmental footer inside the authored surface")
	var empty_fixture := compact_fixture.duplicate(true)
	empty_fixture["facilities"] = []
	empty_fixture["tasks"] = []
	compact_workspace.configure(empty_fixture)
	await process_frame
	await process_frame
	for scroll in [industry_scroll, tasks_scroll]:
		var empty_card := scroll.find_child("EmptyActionState", true, false) as Control
		_check(empty_card != null and empty_card.size.x >= scroll.size.x - 25 and empty_card.size.y <= scroll.size.y + 0.5, "200% empty-state cards span the board and fit vertically without clipping their action")
	host.queue_free()
	UiTokens.set_ui_scale(1.0)
	await process_frame


func _test_fixed_dashboard_layout(workspace: Control) -> void:
	var content := workspace.find_child("LocationOperationsContent", true, false) as Control
	var hero := workspace.find_child("LocationOperationsHero", true, false) as Control
	var kpis := workspace.find_child("LocationOperationsKpis", true, false) as Control
	var dashboard := workspace.find_child("LocationOperationsDashboard", true, false) as Control
	var left := workspace.find_child("LocationOperationsLeftColumn", true, false) as Control
	var right := workspace.find_child("LocationOperationsRightColumn", true, false) as Control
	var environment := workspace.find_child("LocationEnvironment", true, false) as Control
	var page_scroll := workspace.find_child("LocationOperationsScroll", true, false)
	var resource_scroll := workspace.find_child("LocationResourcesListScroll", true, false) as ScrollContainer
	var inventory_scroll := workspace.find_child("LocationInventoryListScroll", true, false) as ScrollContainer
	var tasks_scroll := workspace.find_child("LocationTasksListScroll", true, false) as ScrollContainer
	var ratio := left.size.x / maxf(1.0, dashboard.size.x) if left != null and dashboard != null else 0.0
	_check(
		workspace.size.is_equal_approx(Vector2(1920, 1080)) and page_scroll == null
		and content != null and hero != null and kpis != null and dashboard != null and environment != null
		and _inside(hero, content) and _inside(kpis, content) and _inside(dashboard, content) and _inside(environment, content)
		and hero.get_global_rect().end.y <= kpis.get_global_rect().position.y + 0.5
		and kpis.get_global_rect().end.y <= dashboard.get_global_rect().position.y + 0.5
		and dashboard.get_global_rect().end.y <= environment.get_global_rect().position.y + 0.5
		and left != null and right != null and left.get_global_rect().end.x <= right.get_global_rect().position.x + 0.5
		and ratio >= 0.53 and ratio <= 0.57
		and resource_scroll != null and inventory_scroll != null and tasks_scroll != null,
		"the 1920 × 1080 board has no page scroll, keeps its 55/45 operations split, and confines scrolling to bounded data lists"
	)


func _test_chinese_catalog_rendering(workspace: Control, i18n: Node) -> void:
	i18n.call("set_locale", "zh_CN")
	var localized_workspace = WorkspaceScript.new()
	localized_workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	workspace.get_parent().add_child(localized_workspace)
	localized_workspace.configure(_fixture())
	var resources := localized_workspace.find_child("LocationResources", true, false)
	var environment := localized_workspace.find_child("LocationEnvironment", true, false)
	var filter := localized_workspace.find_child("LocationInventoryFilter", true, false) as OptionButton
	var footer_text := _descendant_text(environment)
	_check(str(i18n.call("core", "location.operations.resources")) == "资源情报", "zh-CN catalog resolves the Location resource heading from core_ui")
	_check(_descendant_text(resources).contains("资源情报"), "a freshly mounted zh-CN Location workspace renders the core_ui resource heading")
	_check(footer_text.contains("太阳能发电 ×1.00"), "zh-CN environment footer renders solar generation with two decimals")
	_check(footer_text.contains("电力需求 ×1.12"), "zh-CN environment footer renders power demand with two decimals")
	_check(not footer_text.contains("建设速度"), "finished-building deployment does not display a retired onsite construction-speed multiplier")
	_check(not footer_text.contains("建设工作量") and not footer_text.contains("热环境电力"), "environment footer keeps detailed modifiers out of the compact row")
	_check(filter != null and filter.get_item_text(1) == "工业部件", "zh-CN inventory filter localizes authoritative item categories")


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"location_id":"earth_orbit",
		"name":"Earth Orbit",
		"system_name":"Solar System",
		"survey_state":"SURVEYED",
		"environment":{"gravity":0.0, "atmosphere":"VACUUM", "radiation":"LOW", "solar_flux":1.0, "thermal_environment":"TEMPERATE", "construction_difficulty_band":"HIGH", "transport_distance_band":"NEAR"},
		"environment_effects":{"solar_generation_multiplier":1.0, "power_demand_multiplier":1.12, "construction_work_multiplier":1.25, "construction_speed_multiplier":0.9, "thermal_power_multiplier":1.03, "radiation_power_multiplier":1.02, "gravity_power_multiplier":1.0, "atmosphere_power_multiplier":1.0, "details":{"cooling":"Nominal"}},
		"world_id":"earth_grid",
		"can_initialize_factory":true,
		"power":{"generation_kw":120.0, "demand_kw":96.0},
		"storage":{"storage_mode":"PER_ITEM", "item_count":3, "stocked_item_count":2, "full_item_count":1, "max_utilization":1.0},
		"industry":{"running":18, "blocked":2, "building_count":20, "construction_count":3},
		"resources":[
			{"id":"iron_ore", "item_id":"iron_ore", "name":"Iron Ore", "category":"ORE", "grade":0.62, "potential_per_hour":12000.0, "discovered":true, "exploited":true, "entity_id":"extractor_iron", "world_id":"earth_grid", "quantity":1200.0, "capacity":5000.0, "fill_ratio":0.24, "trend_known":true, "net_rate_per_minute":4.0},
			{"id":"silicate", "name":"Silicate", "category":"ORE", "potential_band":"MEDIUM", "discovered":false, "exploited":false, "entity_id":"", "world_id":"earth_grid"},
			{"id":"copper_ore", "item_id":"copper_ore", "name":"Copper Ore", "category":"ORE", "grade":0.38, "potential_per_hour":4800.0, "discovered":true, "exploited":false, "entity_id":"extractor_copper", "world_id":"lunar_grid", "quantity":0.0, "capacity":5000.0, "fill_ratio":0.0, "trend_known":true, "net_rate_per_minute":0.0}
		],
		"inventory":[
			{"id":"iron_ingot", "name":"Iron Ingot", "quantity":2400.0, "capacity":5000.0, "fill_ratio":0.48, "net_rate_per_minute":6.0, "trend_known":true, "incoming":800.0, "category":"Raw Feedstock"},
			{"id":"electronics", "name":"Electronics", "quantity":1200.0, "capacity":1200.0, "fill_ratio":1.0, "net_rate_per_minute":-2.0, "trend_known":true, "incoming":0.0, "category":"Component"},
			{"id":"machine_components", "name":"Machine Components", "quantity":0.0, "capacity":800.0, "fill_ratio":0.0, "net_rate_per_minute":0.0, "trend_known":true, "incoming":0.0, "category":"Component"}
		],
		"facilities":[
			{"id":"iron_line", "definition_id":"grid_arc_smelter", "name":"Iron Refining", "product":"Iron Ingot", "rate_per_hour":240.0, "status":"RUNNING", "power_factor":1.0, "outputs":[{"name":"Iron Ingot", "rate_per_hour":240.0}]},
			{"id":"assembly_line", "definition_id":"grid_assembly_array", "name":"Assembly", "product":"Machine Components", "rate_per_hour":60.0, "status":"BLOCKED", "power_factor":0.72}
		],
		"alerts":[{"code":"POWER_SHORTAGE", "message":"Smelting district has reduced power.", "entity_id":"iron_line"}],
		"tasks":[{"id":"build_foundry", "definition_id":"grid_arc_smelter", "kind":"CONSTRUCTION", "name":"Build arc foundry", "status":"RUNNING", "progress":0.42, "remaining_ms":3600000, "action":{"kind":"OPEN_FACTORY", "world_id":"earth_grid", "section":"CANVAS", "order_id":"order_foundry"}}],
		"fleet_count":2,
		"survey":{"next_state":"SURVEYED", "active":false, "progress":0.0, "remaining_ms":0, "cost_text":"1 sensor charge", "ships":[{"id":"freighter", "name":"Freighter", "allowed":false, "can_assign":false, "reason":"No survey module"}, {"id":"surveyor_alpha", "name":"Surveyor Alpha", "allowed":true, "can_assign":false, "reason":"Requirements met"}], "reason":"Requirements met", "can_start":true}
	}


func _inventory_fixture_with_slots(slot_count: int) -> Dictionary:
	var fixture := _fixture()
	var inventory := fixture["inventory"] as Array
	while inventory.size() < slot_count:
		var index := inventory.size()
		inventory.append({
			"id":"warehouse_test_%02d" % index,
			"name":"Warehouse Test %02d" % index,
			"quantity":float((index * 375) % 5000),
			"capacity":5000.0,
			"fill_ratio":float(index % 5) / 4.0,
			"net_rate_per_minute":1.0 if index % 3 == 0 else (-1.0 if index % 3 == 1 else 0.0),
			"trend_known":true,
			"incoming":0.0,
			"category":"Component"
		})
	return fixture


func _tile_width_for_grid(grid: GridContainer) -> float:
	if grid == null or grid.columns != 12:
		return 0.0
	var scroll := grid.get_parent() as ScrollContainer
	var available := scroll.size.x if scroll != null else grid.size.x
	if scroll != null:
		var bar := scroll.get_v_scroll_bar()
		if bar.visible:
			available -= bar.size.x + scroll.get_theme_constant("h_separation")
	var gap := float(grid.get_theme_constant("h_separation"))
	return floorf((available - gap * float(grid.columns - 1)) / float(grid.columns))


func _action_is(action: Dictionary, kind: String) -> bool:
	return str(action.get("kind", "")) == kind


func _descendant_text(node: Node) -> String:
	if node == null:
		return ""
	var text := ""
	if node is Label:
		text += (node as Label).text
	elif node is Button:
		text += (node as Button).text
	for child in node.get_children():
		text += _descendant_text(child)
	return text


func _inside(child: Control, ancestor: Control) -> bool:
	var child_rect := child.get_global_rect()
	var ancestor_rect := ancestor.get_global_rect()
	return child_rect.position.x + 0.5 >= ancestor_rect.position.x \
		and child_rect.position.y + 0.5 >= ancestor_rect.position.y \
		and child_rect.end.x <= ancestor_rect.end.x + 0.5 \
		and child_rect.end.y <= ancestor_rect.end.y + 0.5


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("LOCATION_OPERATIONS_WORKSPACE_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
