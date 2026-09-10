class_name LocationOperationsWorkspace
extends PanelContainer

## A snapshot-only Location dashboard. The mounting host owns navigation and
## command execution; this workspace only renders immutable presentation data
## and emits versioned player intents.

signal action_requested(action: Dictionary)

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const ItemIcon = preload("res://src/ui/workspaces/location/location_item_icon.gd")

const NAVY := Color("0c141c")
const RAISED := Color("15222d")
const INSET := Color("0b151e")
const BORDER := Color("304652")
const CYAN := Color("65d9d1")
const AMBER := Color("e5b467")
const OFFWHITE := Color("e4ecef")
const MUTED := Color("96aab7")
const GREEN := Color("70bb85")
const CRITICAL := Color("ef867d")
const STOCK_TILE := 64
const STOCK_COLUMNS := 12
const STOCK_BACKGROUND := Color("223541")
const STOCK_INK := Color("d7e3e7")
const STOCK_BORDER := Color("3d5964")
const STOCK_GREEN := GREEN

var _snapshot: Dictionary = {}
var _selected_ship_id := ""
var _inventory_filter := "ALL"
var _pending_dynamic_refresh := false

var _title_label: Label
var _subtitle_label: Label
var _survey_ship_selector: OptionButton
var _survey_start_button: Button
var _assign_survey_ship_button: Button
var _factory_button: Button
var _logistics_button: Button
var _hero_art: TextureRect
var _resources_open_button: Button
var _industry_open_button: Button
var _tasks_open_button: Button
var _power_value: Label
var _power_bar: ProgressBar
var _industry_value: Label
var _storage_value: Label
var _storage_detail: Label
var _storage_bar: ProgressBar
var _tasks_value: Label
var _resources_rows: Container
var _inventory_rows: Container
var _industry_rows: Container
var _alert_rows: VBoxContainer
var _task_rows: Container
var _inventory_filter_selector: OptionButton
var _fleet_summary: Label
var _environment_summary: Label
var _environment_popup_rows: VBoxContainer
var _environment_popup: PopupPanel


func _ready() -> void:
	name = "LocationOperationsWorkspace"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_stylebox_override("panel", _panel_style(NAVY, BORDER, 4))
	_build_shell()
	_refresh_all()
	set_process(false)


func configure(snapshot: Dictionary) -> void:
	# Never retain caller-owned dictionaries: snapshot publishers may reuse their
	# backing model during a simulation tick.
	_snapshot = snapshot.duplicate(true)
	_update_static_values()
	if _dynamic_interaction_active():
		# Preserve a hovered control until its click completes, but never freeze
		# existing progress bars while the player is looking at that control.
		for task_value in _array(_snapshot.get("tasks")):
			var task: Dictionary = task_value as Dictionary
			var row := _task_rows.get_node_or_null(NodePath("TaskRow_%s" % str(task.get("id", "")).validate_node_name())) as Panel
			if row == null:
				continue
			(row.get_meta("progress") as ProgressBar).value = clampf(float(task.get("progress", 0.0)) * 100.0, 0.0, 100.0)
			(row.get_meta("remaining") as Label).text = _remaining_text(task)
			(row.get_meta("percent") as Label).text = "%d%%" % int(round(clampf(float(task.get("progress", 0.0)) * 100.0, 0.0, 100.0)))
			_update_status_badge(row.get_meta("status_badge") as PanelContainer, row.get_meta("status") as Label, str(task.get("status", "")))
		# Hovering a warehouse tile must not freeze the live stock height or its
		# surplus/consumption marker. Structural row changes still wait until the
		# interaction completes, but existing tiles update in place.
		_refresh_stock_tiles_in_place()
		_pending_dynamic_refresh = true
		set_process(true)
		return
	_refresh_dynamic_values()


func focus_section(section: String) -> void:
	var target_name := ""
	match section.to_upper():
		"RESOURCES": target_name = "LocationResourcesOpen"
		"INVENTORY": target_name = "LocationInventoryOpen"
		"INDUSTRY", "PRODUCTION", "FACTORY": target_name = "LocationOpenProduction"
		"TASKS", "PROJECTS": target_name = "LocationTasksOpen"
		"FLEET": target_name = "LocationOpenFleet"
		"ENVIRONMENT": target_name = "LocationEnvironmentDetailsButton"
		"SURVEY": target_name = "LocationStartSurvey"
		_: target_name = "LocationOperationsTitle"
	var target := find_child(target_name, true, false) as Control
	if target != null:
		target.call_deferred("grab_focus")


func _process(_delta: float) -> void:
	if not _pending_dynamic_refresh:
		set_process(false)
		return
	if _dynamic_interaction_active():
		return
	_pending_dynamic_refresh = false
	set_process(false)
	_refresh_dynamic_values()


func _build_shell() -> void:
	var margin := MarginContainer.new()
	margin.name = "LocationOperationsFrame"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", UiTokens.layout_px(12))
	margin.add_theme_constant_override("margin_top", UiTokens.layout_px(4))
	margin.add_theme_constant_override("margin_right", UiTokens.layout_px(12))
	margin.add_theme_constant_override("margin_bottom", UiTokens.layout_px(6))
	add_child(margin)

	var content := VBoxContainer.new()
	content.name = "LocationOperationsContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", UiTokens.layout_px(4))
	margin.add_child(content)
	content.add_child(_build_hero())
	content.add_child(_build_kpis())
	content.add_child(_build_dashboard())
	content.add_child(_build_environment_footer())


func _build_hero() -> Control:
	var hero := PanelContainer.new()
	hero.name = "LocationOperationsHero"
	hero.custom_minimum_size.y = UiTokens.layout_px(48)
	hero.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hero.add_theme_stylebox_override("panel", _panel_style(Color("0b1720"), Color(CYAN, 0.68), 4))
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(12))
	hero.add_child(body)

	var art_frame := PanelContainer.new()
	art_frame.name = "LocationOperationsHeroArt"
	art_frame.custom_minimum_size = UiTokens.layout_vector(Vector2(48, 48))
	art_frame.add_theme_stylebox_override("panel", _panel_style(Color("102a37"), Color(CYAN, 0.58), 40))
	body.add_child(art_frame)
	var art := TextureRect.new()
	art.name = "LocationOperationsFactoryArt"
	# Location operations starts at the selected planetary landing, not at an
	# implied research complex. Snapshot data supplies a real facility once one
	# exists; the development core remains the safe pre-landing fallback.
	art.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), "grid_planetary_core", "STORAGE")
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.modulate = Color(0.72, 0.98, 1.0, 0.96)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_frame.add_child(art)
	_hero_art = art

	var identity := VBoxContainer.new()
	identity.name = "LocationOperationsIdentity"
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	identity.add_theme_constant_override("separation", UiTokens.layout_px(3))
	body.add_child(identity)
	var eyebrow := _label(_t("location.operations.eyebrow", "LOCATION OPERATIONS"), 9, CYAN)
	eyebrow.name = "LocationOperationsEyebrow"
	var title_row := HBoxContainer.new()
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_theme_constant_override("separation", UiTokens.layout_px(12))
	identity.add_child(title_row)
	_title_label = _label(_t("location.select_known", "Select a known Location from the System map."), 16, OFFWHITE)
	_title_label.name = "LocationOperationsTitle"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.focus_mode = Control.FOCUS_ALL
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_row.add_child(_title_label)
	title_row.add_child(eyebrow)
	_subtitle_label = _label("", 10, MUTED)
	_subtitle_label.name = "LocationOperationsSubtitle"
	_subtitle_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	identity.add_child(_subtitle_label)

	var actions := VBoxContainer.new()
	actions.name = "LocationOperationsActions"
	actions.custom_minimum_size.x = UiTokens.layout_px(610)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	actions.add_theme_constant_override("separation", UiTokens.layout_px(5))
	body.add_child(actions)
	_survey_ship_selector = OptionButton.new()
	_survey_ship_selector.name = "LocationSurveyShip"
	_survey_ship_selector.tooltip_text = _t("location.operations.select_ship_tooltip", "Choose an eligible vessel for the next survey mission.")
	_survey_ship_selector.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	_style_selector(_survey_ship_selector, CYAN)
	_survey_ship_selector.item_selected.connect(_on_survey_ship_selected)
	actions.add_child(_survey_ship_selector)
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", UiTokens.layout_px(6))
	actions.add_child(action_row)
	_survey_start_button = _button("LocationStartSurvey", _t("location.operations.survey", "Survey"), CYAN)
	_survey_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_survey_start_button.pressed.connect(_on_survey_pressed)
	action_row.add_child(_survey_start_button)
	_assign_survey_ship_button = _button("LocationAssignSurveyShip", _t("location.operations.assign_survey_ship", "Assign to Survey Formation"), CYAN)
	_assign_survey_ship_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_assign_survey_ship_button.tooltip_text = _t("location.operations.assign_survey_ship_tooltip", "Assign this existing vessel to the Survey Formation; no vessel is created.")
	_assign_survey_ship_button.pressed.connect(_on_assign_survey_ship_pressed)
	_assign_survey_ship_button.visible = false
	action_row.add_child(_assign_survey_ship_button)
	_factory_button = _button("LocationOpenFactory", _t("location.operations.open_factory", "Open Factory"), AMBER)
	_factory_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_factory_button.pressed.connect(_on_factory_pressed)
	action_row.add_child(_factory_button)
	_logistics_button = _button("LocationOpenLogistics", _t("location.operations.logistics", "Arrange Logistics"), CYAN)
	_logistics_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_logistics_button.pressed.connect(func() -> void: _emit_action({"kind":"OPEN_LOGISTICS"}))
	action_row.add_child(_logistics_button)
	return hero


func _build_kpis() -> Control:
	var row := HBoxContainer.new()
	row.name = "LocationOperationsKpis"
	row.custom_minimum_size.y = UiTokens.layout_px(52)
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_theme_constant_override("separation", UiTokens.layout_px(8))
	var power := _kpi_card("LocationKpiPower", "ϟ", _t("location.operations.power", "Power / Load"), CYAN)
	_power_value = power.get_node("Body/Value") as Label
	_power_bar = power.get_node("Body/Progress") as ProgressBar
	row.add_child(power)
	var industry := _kpi_card("LocationKpiIndustry", "▥", _t("location.operations.industry", "Industrial Operations"), GREEN)
	_industry_value = industry.get_node("Body/Value") as Label
	row.add_child(industry)
	var storage := _kpi_card("LocationKpiStorage", "◇", _t("location.operations.storage", "Local Storage"), CYAN)
	_storage_value = storage.get_node("Body/Value") as Label
	_storage_detail = storage.get_node("Body/Heading/Detail") as Label
	_storage_bar = storage.get_node("Body/Progress") as ProgressBar
	row.add_child(storage)
	var tasks := _kpi_card("LocationKpiTasks", "▣", _t("location.operations.tasks_logistics", "Tasks / Logistics"), AMBER)
	_tasks_value = tasks.get_node("Body/Value") as Label
	row.add_child(tasks)
	return row


func _kpi_card(node_name: String, icon: String, caption: String, tone: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style(RAISED, Color(tone, 0.60), 4))
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiTokens.layout_px(1))
	panel.add_child(body)
	var heading := HBoxContainer.new()
	heading.name = "Heading"
	body.add_child(heading)
	heading.add_child(_label(icon, 12, tone))
	var title := _label(caption, 10, OFFWHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	heading.add_child(title)
	var value := _label("—", 12, tone)
	value.name = "Value"
	body.add_child(value)
	var detail := _label("", 9, MUTED)
	detail.name = "Detail"
	detail.visible = node_name == "LocationKpiStorage"
	heading.add_child(detail)
	var progress := ProgressBar.new()
	progress.name = "Progress"
	progress.custom_minimum_size.y = UiTokens.layout_px(8)
	progress.max_value = 100.0
	progress.show_percentage = false
	progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress.visible = node_name in ["LocationKpiPower", "LocationKpiStorage"]
	progress.add_theme_stylebox_override("background", _panel_style(INSET, BORDER, 2))
	progress.add_theme_stylebox_override("fill", _panel_style(tone.darkened(0.32), tone, 2))
	body.add_child(progress)
	return panel


func _build_dashboard() -> Control:
	var dashboard := HBoxContainer.new()
	dashboard.name = "LocationOperationsDashboard"
	dashboard.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dashboard.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dashboard.add_theme_constant_override("separation", UiTokens.layout_px(8))
	var left := VBoxContainer.new()
	left.name = "LocationOperationsLeftColumn"
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 0.55
	left.add_theme_constant_override("separation", UiTokens.layout_px(8))
	dashboard.add_child(left)
	var resources := _build_resources_board()
	resources.size_flags_vertical = Control.SIZE_EXPAND_FILL
	resources.size_flags_stretch_ratio = 0.48
	left.add_child(resources)
	var inventory := _build_inventory_board()
	inventory.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inventory.size_flags_stretch_ratio = 0.52
	left.add_child(inventory)
	var right := VBoxContainer.new()
	right.name = "LocationOperationsRightColumn"
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 0.45
	right.add_theme_constant_override("separation", UiTokens.layout_px(4))
	dashboard.add_child(right)
	var industry := _build_industry_board()
	industry.size_flags_vertical = Control.SIZE_EXPAND_FILL
	industry.size_flags_stretch_ratio = 0.47
	right.add_child(industry)
	var tasks := _build_tasks_board()
	tasks.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tasks.size_flags_stretch_ratio = 0.42
	right.add_child(tasks)
	var fleet := _build_fleet_strip()
	fleet.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fleet.size_flags_stretch_ratio = 0.11
	right.add_child(fleet)
	return dashboard


func _build_resources_board() -> PanelContainer:
	var panel := _board("LocationResources")
	var body := panel.get_node("Body") as VBoxContainer
	var heading := _board_heading("◒", _t("location.operations.resources", "Resource Intelligence"), _t("location.operations.view_factory", "View Factory →"), "LocationResourcesOpen", CYAN, _on_factory_pressed)
	_resources_open_button = heading.get_node_or_null("LocationResourcesOpen") as Button
	body.add_child(heading)
	var region := _card_grid_region("LocationResourcesListRegion", "LocationResourcesListScroll", "LocationResourcesRows", STOCK_COLUMNS, STOCK_TILE)
	region.custom_minimum_size.y = UiTokens.layout_px(STOCK_TILE)
	_resources_rows = region.get_node("LocationResourcesListScroll/LocationResourcesRows") as Container
	body.add_child(region)
	return panel


func _build_inventory_board() -> PanelContainer:
	var panel := _board("LocationInventory")
	var body := panel.get_node("Body") as VBoxContainer
	var header := HBoxContainer.new()
	body.add_child(header)
	header.add_child(_label("◇", 15, CYAN))
	var title := _label(_t("location.operations.inventory", "Local Inventory"), 12, OFFWHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_inventory_filter_selector = OptionButton.new()
	_inventory_filter_selector.name = "LocationInventoryFilter"
	_inventory_filter_selector.tooltip_text = _t("location.operations.inventory_filter_tooltip", "Filter visible local inventory by its authoritative category.")
	_inventory_filter_selector.custom_minimum_size.x = UiTokens.layout_px(126)
	_inventory_filter_selector.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	_style_selector(_inventory_filter_selector, CYAN)
	_inventory_filter_selector.item_selected.connect(_on_inventory_filter_selected)
	header.add_child(_inventory_filter_selector)
	var open := _button("LocationInventoryOpen", _t("location.operations.open_inventory", "Open Inventory"), CYAN)
	open.pressed.connect(func() -> void: _emit_action({"kind":"OPEN_INVENTORY"}))
	header.add_child(open)
	var region := _card_grid_region("LocationInventoryListRegion", "LocationInventoryListScroll", "LocationInventoryRows", STOCK_COLUMNS, STOCK_TILE)
	region.custom_minimum_size.y = UiTokens.layout_px(STOCK_TILE)
	_inventory_rows = region.get_node("LocationInventoryListScroll/LocationInventoryRows") as Container
	body.add_child(region)
	return panel


func _build_industry_board() -> PanelContainer:
	var panel := _board("LocationIndustry")
	var body := panel.get_node("Body") as VBoxContainer
	var heading := _board_heading("▥", _t("location.operations.industry", "Industrial Operations"), _t("location.operations.open_production", "Open Production →"), "LocationOpenProduction", GREEN, _open_industry_board)
	_industry_open_button = heading.get_node_or_null("LocationOpenProduction") as Button
	body.add_child(heading)
	var facility_region := _card_grid_region("LocationIndustryListRegion", "LocationIndustryListScroll", "LocationIndustryRows", 2)
	facility_region.custom_minimum_size.y = UiTokens.layout_px(62)
	facility_region.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_industry_rows = facility_region.get_node("LocationIndustryListScroll/LocationIndustryRows") as Container
	body.add_child(facility_region)
	# Alert rows already carry a colored status and message; a second heading
	# wastes a complete line and pushes the global command dock off-screen.
	var alert_region := _scroll_region("LocationIndustryAlertRegion", "LocationIndustryAlertScroll", "LocationIndustryAlertRows")
	alert_region.custom_minimum_size.y = UiTokens.layout_px(18)
	alert_region.size_flags_vertical = Control.SIZE_SHRINK_END
	_alert_rows = alert_region.get_node("LocationIndustryAlertScroll/LocationIndustryAlertRows") as VBoxContainer
	body.add_child(alert_region)
	return panel


func _build_tasks_board() -> PanelContainer:
	var panel := _board("LocationTasks")
	var body := panel.get_node("Body") as VBoxContainer
	var heading := _board_heading("▣", _t("location.operations.tasks", "Local Tasks"), _t("location.operations.open_factory", "Open Factory"), "LocationTasksOpen", AMBER, _open_task_empty_action)
	_tasks_open_button = heading.get_node_or_null("LocationTasksOpen") as Button
	body.add_child(heading)
	var region := _card_grid_region("LocationTasksListRegion", "LocationTasksListScroll", "LocationTasksRows", 1)
	region.custom_minimum_size.y = UiTokens.layout_px(60)
	_task_rows = region.get_node("LocationTasksListScroll/LocationTasksRows") as Container
	body.add_child(region)
	return panel


func _build_fleet_strip() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "LocationFleet"
	panel.add_theme_stylebox_override("panel", _panel_style(Color("10212d"), Color(CYAN, 0.58), 4))
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(7))
	panel.add_child(body)
	body.add_child(_label("▰", 14, CYAN))
	var title := _label(_t("location.operations.stationed_fleet", "Stationed Fleet"), 12, OFFWHITE)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	body.add_child(title)
	_fleet_summary = _label("—", 11, MUTED)
	_fleet_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fleet_summary.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_fleet_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	body.add_child(_fleet_summary)
	var open := _button("LocationOpenFleet", _t("location.operations.open_fleet", "View Fleet →"), CYAN)
	open.pressed.connect(func() -> void: _emit_action({"kind":"OPEN_FLEET"}))
	body.add_child(open)
	return panel


func _build_environment_footer() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "LocationEnvironment"
	panel.custom_minimum_size.y = UiTokens.layout_px(32)
	panel.size_flags_vertical = Control.SIZE_SHRINK_END
	panel.add_theme_stylebox_override("panel", _panel_style(Color("10212d"), Color(CYAN, 0.58), 4))
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(10))
	panel.add_child(body)
	body.add_child(_label("◒", 14, CYAN))
	var title := _label(_t("location.operations.environment", "Environmental Conditions"), 12, OFFWHITE)
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	body.add_child(title)
	var divider := VSeparator.new()
	divider.custom_minimum_size.x = UiTokens.layout_px(1)
	body.add_child(divider)
	_environment_summary = _label("", 10, MUTED)
	_environment_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_environment_summary.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_environment_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(_environment_summary)
	var detail := _button("LocationEnvironmentDetailsButton", _t("location.operations.environment_details", "Details →"), CYAN)
	detail.pressed.connect(_show_environment_popup)
	body.add_child(detail)
	_build_environment_popup()
	return panel


func _build_environment_popup() -> void:
	_environment_popup = PopupPanel.new()
	_environment_popup.name = "LocationEnvironmentPopup"
	_environment_popup.size = UiTokens.layout_vector(Vector2(500, 360))
	_environment_popup.add_theme_stylebox_override("panel", _panel_style(RAISED, CYAN, 4))
	add_child(_environment_popup)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", UiTokens.layout_px(12))
	margin.add_theme_constant_override("margin_top", UiTokens.layout_px(10))
	margin.add_theme_constant_override("margin_right", UiTokens.layout_px(12))
	margin.add_theme_constant_override("margin_bottom", UiTokens.layout_px(10))
	_environment_popup.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(6))
	margin.add_child(body)
	var header := HBoxContainer.new()
	body.add_child(header)
	var title := _label(_t("location.operations.environment_details", "Environmental Effects"), 16, OFFWHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close := _button("LocationEnvironmentClose", _t("location.operations.close", "Close"), CYAN)
	close.pressed.connect(func() -> void: _environment_popup.hide())
	header.add_child(close)
	var region := _scroll_region("LocationEnvironmentDetailsRegion", "LocationEnvironmentDetailsScroll", "LocationEnvironmentDetailsRows")
	_environment_popup_rows = region.get_node("LocationEnvironmentDetailsScroll/LocationEnvironmentDetailsRows") as VBoxContainer
	body.add_child(region)


func _board(node_name: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	panel.add_theme_stylebox_override("panel", _panel_style(NAVY, BORDER, 4))
	var body := VBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTokens.layout_px(2))
	panel.add_child(body)
	return panel


func _board_heading(icon: String, title_text: String, action_text: String, action_name: String, tone: Color, callback: Callable) -> HBoxContainer:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTokens.layout_px(6))
	header.add_child(_label(icon, 15, tone))
	var title := _label(title_text, 12, OFFWHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var action := _button(action_name, action_text, tone)
	action.pressed.connect(callback)
	header.add_child(action)
	return header


func _table_header(columns: Array[String], ratios: Array[float]) -> HBoxContainer:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTokens.layout_px(4))
	for index in columns.size():
		var label := _table_label(columns[index], ratios[index], MUTED)
		label.add_theme_font_size_override("font_size", UiTokens.font_size(9))
		header.add_child(label)
	return header


func _scroll_region(region_name: String, scroll_name: String, rows_name: String) -> Control:
	var region := Control.new()
	region.name = region_name
	region.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	region.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.name = scroll_name
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	region.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.name = rows_name
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", UiTokens.layout_px(3))
	scroll.add_child(rows)
	return region


func _card_grid_region(region_name: String, scroll_name: String, rows_name: String, columns: int, fixed_tile_size := 0) -> Control:
	var region := Control.new()
	region.name = region_name
	region.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	region.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var scroll := ScrollContainer.new()
	scroll.name = scroll_name
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	region.add_child(scroll)
	var cards := GridContainer.new()
	cards.name = rows_name
	cards.columns = columns
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var gap := UiTokens.layout_px(2 if fixed_tile_size > 0 else 4)
	cards.add_theme_constant_override("h_separation", gap)
	cards.add_theme_constant_override("v_separation", gap)
	scroll.add_child(cards)
	if fixed_tile_size > 0:
		# Twelve columns share the panel's DESIGN width. This is independent of
		# physical window dimensions and never changes the page's panel ratios.
		var fit := func() -> void:
			if bool(cards.get_meta("stock_fit_queued", false)):
				return
			cards.set_meta("stock_fit_queued", true)
			_fit_stock_grid.call_deferred(cards, scroll)
		scroll.resized.connect(fit)
		scroll.get_v_scroll_bar().visibility_changed.connect(fit)
		cards.child_entered_tree.connect(func(_child: Node) -> void: fit.call())
	return region


func _fit_stock_grid(cards: GridContainer, scroll: ScrollContainer) -> void:
	if not is_instance_valid(cards) or not is_instance_valid(scroll):
		return
	cards.set_meta("stock_fit_queued", false)
	if scroll.size.x <= 0.0:
		return
	var available := scroll.size.x
	var bar := scroll.get_v_scroll_bar()
	if bar.visible:
		available -= bar.size.x + scroll.get_theme_constant("h_separation")
	var gap := cards.get_theme_constant("h_separation")
	var edge := maxf(1.0, floorf((available - gap * (STOCK_COLUMNS - 1)) / STOCK_COLUMNS))
	for child in cards.get_children():
		var tile := child as Control
		tile.custom_minimum_size = Vector2.ONE * edge
		if tile.has_meta("quantity"):
			var quantity := tile.get_meta("quantity") as Label
			quantity.add_theme_font_size_override("font_size", maxi(10, floori(edge * 0.22)))
			var trend := tile.get_meta("trend") as Label
			trend.add_theme_font_size_override("font_size", maxi(9, floori(edge * 0.19)))


func _refresh_all() -> void:
	_update_static_values()
	_refresh_dynamic_values()


func _update_static_values() -> void:
	if _title_label == null:
		return
	var valid := bool(_snapshot.get("valid", false))
	var landing_required := _landing_required()
	_update_hero_art(landing_required)
	var location_name := str(_snapshot.get("name", ""))
	_title_label.text = location_name if valid and not location_name.is_empty() else _t("location.select_known", "Select a known Location from the System map.")
	_subtitle_label.text = "%s  ·  %s" % [str(_snapshot.get("system_name", _unknown())), _display_value(_snapshot.get("survey_state"))]
	var power: Dictionary = _dictionary(_snapshot.get("power"))
	var generation := float(power.get("generation_kw", 0.0))
	var demand := float(power.get("demand_kw", 0.0))
	_power_value.text = "%s / %s kW" % [_number(generation), _number(demand)] if valid else "—"
	_power_bar.value = clampf(100.0 * generation / maxf(1.0, demand), 0.0, 100.0) if valid else 0.0
	var industry: Dictionary = _dictionary(_snapshot.get("industry"))
	_industry_value.text = "%d %s  ·  %d %s" % [int(industry.get("running", 0)), _t("location.operations.running", "running"), int(industry.get("blocked", 0)), _t("location.operations.blocked", "blocked")] if valid else "—"
	var storage: Dictionary = _dictionary(_snapshot.get("storage"))
	var used := float(storage.get("used", 0.0))
	var capacity := float(storage.get("capacity", 0.0))
	if valid and str(storage.get("storage_mode", "")) == "PER_ITEM":
		var item_count := int(storage.get("item_count", 0))
		var stocked_count := int(storage.get("stocked_item_count", 0))
		var full_count := int(storage.get("full_item_count", 0))
		_storage_value.text = "%d / %d" % [stocked_count, item_count]
		_storage_detail.text = "%d %s  ·  %d %s" % [stocked_count, _t("location.operations.stocked", "stocked"), full_count, _t("location.operations.full", "full")]
		_storage_bar.value = clampf(100.0 * float(storage.get("max_utilization", 0.0)), 0.0, 100.0)
	elif valid and capacity > 0.0:
		_storage_value.text = "%s%%" % _number(100.0 * used / capacity)
		_storage_detail.text = "%s / %s" % [_number(used), _number(capacity)]
		_storage_bar.value = clampf(100.0 * used / capacity, 0.0, 100.0)
	else:
		_storage_value.text = _unknown()
		_storage_detail.text = _unknown()
		_storage_bar.value = 0.0
	var task_count := (_snapshot.get("tasks", []) as Array).size()
	_tasks_value.text = "%d %s  ·  %d %s" % [task_count, _t("location.operations.active", "active"), int(_snapshot.get("fleet_count", 0)), _t("location.operations.fleet_short", "fleet")] if valid else "—"
	_factory_button.disabled = not valid or (str(_snapshot.get("world_id", "")).is_empty() and not bool(_snapshot.get("can_initialize_factory", false)))
	_factory_button.text = _t("location.operations.deploy_core", "Deploy Development Core") if landing_required else _t("location.operations.open_factory", "Open Factory")
	_factory_button.tooltip_text = _t("location.operations.deploy_core_hint", "Choose a legal site for the Planetary Development Core.") if landing_required else _t("location.operations.open_factory", "Open Factory")
	if _resources_open_button != null:
		_resources_open_button.text = _t("location.operations.deploy_core", "Deploy Development Core") if landing_required else _t("location.operations.view_factory", "View Factory →")
		_resources_open_button.disabled = _factory_button.disabled
	if _industry_open_button != null:
		_industry_open_button.text = _t("location.operations.deploy_core", "Deploy Development Core") if landing_required else _t("location.operations.open_production", "Open Production →")
		_industry_open_button.disabled = _factory_button.disabled
	if _tasks_open_button != null:
		_tasks_open_button.text = _t("location.operations.deploy_core", "Deploy Development Core") if landing_required else _t("location.operations.open_factory", "Open Factory")
		_tasks_open_button.disabled = _factory_button.disabled
	_logistics_button.disabled = not valid
	_fleet_summary.text = "%d %s" % [int(_snapshot.get("fleet_count", 0)), _t("location.operations.vessels", "vessels")] if valid else "—"
	_environment_summary.text = _environment_summary_text()
	var environment_details := find_child("LocationEnvironmentDetailsButton", true, false) as Button
	if environment_details != null:
		environment_details.tooltip_text = _environment_effect_tooltip()


func _landing_required() -> bool:
	# A location without a Factory world is still at the same player-facing
	# landing stage when the host can initialize one. The action contract remains
	# authoritative; this helper only selects truthful copy and art.
	return bool(_snapshot.get("landing_required", false)) or (
		str(_snapshot.get("world_id", "")).is_empty()
		and bool(_snapshot.get("can_initialize_factory", false))
	)


func _update_hero_art(landing_required: bool) -> void:
	if _hero_art == null:
		return
	var definition_id := str(_snapshot.get("hero_definition_id", ""))
	if definition_id.is_empty() and not landing_required:
		for facility_value in _array(_snapshot.get("facilities")):
			if facility_value is Dictionary and not str((facility_value as Dictionary).get("definition_id", "")).is_empty():
				definition_id = str((facility_value as Dictionary).get("definition_id", ""))
				break
	if definition_id.is_empty():
		definition_id = "grid_planetary_core"
	_hero_art.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), definition_id, "STORAGE" if definition_id == "grid_planetary_core" else "MACHINE")


func _refresh_dynamic_values() -> void:
	_update_survey_controls()
	_update_inventory_filter()
	_sync_resource_rows(_array(_snapshot.get("resources")))
	_sync_inventory_rows(_filtered_inventory())
	_sync_facility_rows(_array(_snapshot.get("facilities")))
	_sync_alert_rows(_array(_snapshot.get("alerts")))
	_sync_task_rows(_array(_snapshot.get("tasks")))
	_sync_environment_rows()


func _refresh_stock_tiles_in_place() -> void:
	var resources := _array(_snapshot.get("resources"))
	for resource_index in resources.size():
		var resource_value = resources[resource_index]
		if not resource_value is Dictionary:
			continue
		var resource: Dictionary = resource_value as Dictionary
		var resource_id := str(resource.get("id", "resource_%d" % resource_index))
		var resource_row := _resources_rows.get_node_or_null(NodePath("ResourceRow_%s" % resource_id.validate_node_name())) as Panel
		if resource_row == null:
			continue
		_update_stock_visuals(resource_row, resource)
		var resource_action := resource_row.get_meta("action") as Button
		resource_action.disabled = _resource_action(resource).is_empty()
		resource_action.tooltip_text = _resource_card_tooltip(resource)
		resource_action.accessibility_name = resource_action.tooltip_text
		resource_row.tooltip_text = resource_action.tooltip_text
		resource_row.accessibility_name = resource_action.accessibility_name
	var inventory := _array(_snapshot.get("inventory"))
	for item_index in inventory.size():
		var item_value = inventory[item_index]
		if not item_value is Dictionary:
			continue
		var item: Dictionary = item_value as Dictionary
		var item_id := str(item.get("id", "item_%d" % item_index))
		var item_row := _inventory_rows.get_node_or_null(NodePath("InventoryRow_%s" % item_id.validate_node_name())) as Panel
		if item_row == null:
			continue
		_update_stock_visuals(item_row, item)
		var item_action := item_row.get_meta("action") as Button
		item_action.tooltip_text = _stock_card_tooltip(item)
		item_action.accessibility_name = item_action.tooltip_text
		item_row.tooltip_text = item_action.tooltip_text
		item_row.accessibility_name = item_action.accessibility_name


func _update_survey_controls() -> void:
	var survey: Dictionary = _dictionary(_snapshot.get("survey"))
	var ships := _array(survey.get("ships"))
	var eligible: Array = []
	var assignable: Array = []
	for ship_value in ships:
		if ship_value is Dictionary:
			var ship: Dictionary = ship_value as Dictionary
			if bool(ship.get("allowed", false)):
				eligible.append(ship)
			elif bool(ship.get("can_assign", false)):
				assignable.append(ship)
	var selected_valid := false
	for ship_value in ships:
		if not ship_value is Dictionary:
			continue
		var candidate: Dictionary = ship_value as Dictionary
		if not bool(candidate.get("allowed", false)) and not bool(candidate.get("can_assign", false)):
			continue
		if str((ship_value as Dictionary).get("id", "")) == _selected_ship_id:
			selected_valid = true
			break
	if not selected_valid:
		var selectable: Array = eligible if not eligible.is_empty() else assignable
		_selected_ship_id = str((selectable[0] as Dictionary).get("id", "")) if not selectable.is_empty() else ""
	_survey_ship_selector.clear()
	if ships.is_empty():
		_survey_ship_selector.add_item(_t("location.operations.no_survey_ship", "No survey vessels"))
		_survey_ship_selector.set_item_disabled(0, true)
	else:
		var selected_index := -1
		for index in ships.size():
			var ship: Dictionary = ships[index] as Dictionary
			var ship_id := str(ship.get("id", ""))
			_survey_ship_selector.add_item(str(ship.get("name", ship_id)))
			_survey_ship_selector.set_item_metadata(index, ship_id)
			_survey_ship_selector.set_item_disabled(index, not bool(ship.get("allowed", false)) and not bool(ship.get("can_assign", false)))
			_survey_ship_selector.set_item_tooltip(index, str(ship.get("reason", "")))
			if ship_id == _selected_ship_id:
				selected_index = index
		if selected_index >= 0:
			_survey_ship_selector.select(selected_index)
	_survey_ship_selector.disabled = ships.is_empty()
	var active := bool(survey.get("active", false))
	var can_start := bool(survey.get("can_start", false))
	var selected_can_assign := _selected_ship_can_assign()
	_assign_survey_ship_button.visible = not active and selected_can_assign
	_assign_survey_ship_button.disabled = not selected_can_assign
	if active:
		_survey_start_button.text = "%s · %.0f%%" % [_t("location.operations.survey_active", "Survey in progress"), 100.0 * float(survey.get("progress", 0.0))]
		_survey_start_button.tooltip_text = _survey_progress_text(survey)
		_survey_start_button.disabled = false
	elif str(survey.get("next_state", "")).is_empty():
		_survey_start_button.text = _t("location.operations.survey_complete", "Survey complete")
		_survey_start_button.tooltip_text = _t("location.operations.survey_complete", "Survey complete")
		_survey_start_button.disabled = true
	elif selected_can_assign:
		_survey_start_button.text = _t("location.operations.assign_before_survey", "Assign vessel before survey")
		_survey_start_button.tooltip_text = _t("location.operations.assign_survey_ship_tooltip", "Assign this existing vessel to the Survey Formation; no vessel is created.")
		_survey_start_button.disabled = true
	elif ships.is_empty():
		_survey_start_button.text = _t("location.operations.configure_survey_ship", "Configure Survey Ship")
		_survey_start_button.tooltip_text = _t("location.operations.no_eligible_ship", "No ship can perform the next survey.")
		_survey_start_button.disabled = false
	else:
		_survey_start_button.text = _t("location.operations.start_survey", "Start %s") % _display_value(survey.get("next_state"))
		var cost_text := str(survey.get("cost_text", ""))
		_survey_start_button.tooltip_text = "%s%s" % [str(survey.get("reason", "")), (" · " + cost_text) if not cost_text.is_empty() else ""]
		_survey_start_button.disabled = not can_start


func _update_inventory_filter() -> void:
	var categories: Array[String] = []
	for item_value in _array(_snapshot.get("inventory")):
		if not item_value is Dictionary:
			continue
		var category := str((item_value as Dictionary).get("category", ""))
		if not category.is_empty() and not categories.has(category):
			categories.append(category)
	categories.sort()
	if _inventory_filter != "ALL" and not categories.has(_inventory_filter):
		_inventory_filter = "ALL"
	_inventory_filter_selector.clear()
	_inventory_filter_selector.add_item(_t("location.operations.all_inventory", "All"))
	_inventory_filter_selector.set_item_metadata(0, "ALL")
	var selected_index := 0
	for category in categories:
		_inventory_filter_selector.add_item(_category_text(category))
		var index := _inventory_filter_selector.item_count - 1
		_inventory_filter_selector.set_item_metadata(index, category)
		if category == _inventory_filter:
			selected_index = index
	_inventory_filter_selector.select(selected_index)
	_inventory_filter_selector.disabled = categories.is_empty()


func _sync_resource_rows(resources: Array) -> void:
	var active: Dictionary = {}
	for index in resources.size():
		if not resources[index] is Dictionary:
			continue
		var resource: Dictionary = resources[index] as Dictionary
		var id := str(resource.get("id", "resource_%d" % index))
		var row_name := "ResourceRow_%s" % id.validate_node_name()
		active[row_name] = true
		var row := _resources_rows.get_node_or_null(NodePath(row_name)) as Panel
		if row == null:
			row = _resource_card(row_name, id)
			_resources_rows.add_child(row)
		_update_stock_visuals(row, resource)
		var action := row.get_meta("action") as Button
		action.disabled = _resource_action(resource).is_empty()
		action.tooltip_text = _resource_card_tooltip(resource)
		action.accessibility_name = action.tooltip_text
		row.tooltip_text = action.tooltip_text
		row.accessibility_name = action.accessibility_name
	_cleanup_rows(_resources_rows, active)
	_ensure_empty_stock_tile(_resources_rows, active.is_empty(), _t("location.operations.resources_empty", "No resource intelligence is currently revealed."))


func _sync_inventory_rows(items: Array) -> void:
	var active: Dictionary = {}
	for index in items.size():
		if not items[index] is Dictionary:
			continue
		var item: Dictionary = items[index] as Dictionary
		var id := str(item.get("id", "item_%d" % index))
		var row_name := "InventoryRow_%s" % id.validate_node_name()
		active[row_name] = true
		var row := _inventory_rows.get_node_or_null(NodePath(row_name)) as Panel
		if row == null:
			row = _inventory_card(row_name, id)
			_inventory_rows.add_child(row)
		_update_stock_visuals(row, item)
		var action := row.get_meta("action") as Button
		action.tooltip_text = _stock_card_tooltip(item)
		action.accessibility_name = action.tooltip_text
		row.tooltip_text = action.tooltip_text
		row.accessibility_name = action.accessibility_name
	_cleanup_rows(_inventory_rows, active)
	_ensure_empty_stock_tile(_inventory_rows, active.is_empty(), _t("location.operations.inventory_empty", "Local inventory is empty."))


func _sync_facility_rows(facilities: Array) -> void:
	# A single empty-state message spans the board; real facilities retain
	# the authored two-column card layout at every physical window size.
	(_industry_rows as GridContainer).columns = 1 if facilities.is_empty() else 2
	var active: Dictionary = {}
	for index in facilities.size():
		if not facilities[index] is Dictionary:
			continue
		var facility: Dictionary = facilities[index] as Dictionary
		var id := str(facility.get("id", "facility_%d" % index))
		var row_name := "FacilityRow_%s" % id.validate_node_name()
		active[row_name] = true
		var row := _industry_rows.get_node_or_null(NodePath(row_name)) as Panel
		if row == null:
			row = _facility_card(row_name, id)
			_industry_rows.add_child(row)
		(row.get_meta("name") as Label).text = str(facility.get("name", id))
		(row.get_meta("product") as Label).text = str(facility.get("product", _unknown()))
		(row.get_meta("rate") as Label).text = "%s/h" % _number(float(facility.get("rate_per_hour", 0.0)))
		_update_status_badge(row.get_meta("status_badge") as PanelContainer, row.get_meta("status") as Label, str(facility.get("status", "")))
		var power := float(facility.get("power_factor", 1.0))
		(row.get_meta("power") as Label).text = _t("location.operations.power_short", "Power") + " %s%%" % _number(100.0 * power)
		_update_building_art(row.get_meta("art") as TextureRect, str(facility.get("definition_id", "")), str(facility.get("kind", "MACHINE")))
		var action := row.get_meta("action") as Button
		action.tooltip_text = _facility_output_tooltip(facility)
		action.disabled = str(facility.get("world_id", _snapshot.get("world_id", ""))).is_empty()
	_cleanup_rows(_industry_rows, active)
	var landing_required := _landing_required()
	var empty_copy := _t("location.operations.core_required", "Deploy the Planetary Development Core before operating industry.") if landing_required else _t("location.operations.facilities_empty", "No deployed production buildings.")
	var empty_action_copy := _t("location.operations.deploy_core", "Deploy Development Core") if landing_required else _t("location.operations.manufacture_or_deploy", "Manufacture / deploy a building")
	_ensure_empty_action_card(_industry_rows, active.is_empty(), empty_copy, empty_action_copy, "LocationFacilityEmptyAction", func() -> void: _open_industry_empty_action(), "grid_planetary_core")


func _sync_alert_rows(alerts: Array) -> void:
	var active: Dictionary = {}
	for index in alerts.size():
		if not alerts[index] is Dictionary:
			continue
		var alert: Dictionary = alerts[index] as Dictionary
		var id := "%s_%d" % [str(alert.get("code", "alert")), index]
		var row_name := "AlertRow_%s" % id.validate_node_name()
		active[row_name] = true
		var row := _alert_rows.get_node_or_null(NodePath(row_name)) as PanelContainer
		if row == null:
			row = _data_row(row_name, [0.29, 0.60], "LocationAlert%s" % id.validate_node_name(), func() -> void: _open_alert(index))
			_alert_rows.add_child(row)
		var labels: Array = row.get_meta("labels") as Array
		labels[0].text = _display_value(alert.get("code"))
		labels[0].add_theme_color_override("font_color", AMBER)
		labels[1].text = str(alert.get("message", _unknown()))
		var action := row.get_meta("action") as Button
		action.disabled = str(alert.get("world_id", _snapshot.get("world_id", ""))).is_empty()
	_cleanup_rows(_alert_rows, active)
	_ensure_empty_row(_alert_rows, active.is_empty(), _t("location.operations.alerts_clear", "No active industrial alerts."))


func _sync_task_rows(tasks: Array) -> void:
	var active: Dictionary = {}
	for index in tasks.size():
		if not tasks[index] is Dictionary:
			continue
		var task: Dictionary = tasks[index] as Dictionary
		var id := str(task.get("id", "task_%d" % index))
		var row_name := "TaskRow_%s" % id.validate_node_name()
		active[row_name] = true
		var row := _task_rows.get_node_or_null(NodePath(row_name)) as Panel
		if row == null:
			row = _task_row(row_name, id)
			_task_rows.add_child(row)
		(row.get_meta("name") as Label).text = str(task.get("name", task.get("kind", id)))
		(row.get_meta("kind") as Label).text = _display_value(task.get("kind", ""))
		(row.get_meta("remaining") as Label).text = _remaining_text(task)
		(row.get_meta("percent") as Label).text = "%d%%" % int(round(clampf(float(task.get("progress", 0.0)) * 100.0, 0.0, 100.0)))
		_update_status_badge(row.get_meta("status_badge") as PanelContainer, row.get_meta("status") as Label, str(task.get("status", "")))
		var blocker := str(task.get("blocker", ""))
		var blocker_label := row.get_meta("blocker") as Label
		blocker_label.text = _display_value(blocker)
		blocker_label.visible = not blocker.is_empty()
		_update_task_art(row.get_meta("art") as TextureRect, task)
		var progress := row.get_meta("progress") as ProgressBar
		progress.value = clampf(100.0 * float(task.get("progress", 0.0)), 0.0, 100.0)
		var action := row.get_meta("action") as Button
		action.disabled = not (task.get("action") is Dictionary) or (task.get("action") as Dictionary).is_empty()
		action.tooltip_text = _task_card_tooltip(task)
	_cleanup_rows(_task_rows, active)
	var task_action_copy := _t("location.operations.deploy_core", "Deploy Development Core") if _landing_required() else _t("location.operations.open_factory", "Open Factory")
	_ensure_empty_action_card(_task_rows, active.is_empty(), _t("location.operations.tasks_empty", "No active local tasks."), task_action_copy, "LocationTaskEmptyAction", func() -> void: _open_task_empty_action(), "grid_planetary_core")


func _sync_environment_rows() -> void:
	var entries := _environment_entries()
	var active: Dictionary = {}
	for index in entries.size():
		var entry: Dictionary = entries[index] as Dictionary
		var row_name := "EnvironmentRow_%d" % index
		active[row_name] = true
		var row := _environment_popup_rows.get_node_or_null(NodePath(row_name)) as PanelContainer
		if row == null:
			row = PanelContainer.new()
			row.name = row_name
			row.add_theme_stylebox_override("panel", _panel_style(INSET, BORDER, 3))
			var body := HBoxContainer.new()
			row.add_child(body)
			var key := _table_label("", 0.38, OFFWHITE)
			var value := _table_label("", 0.62, CYAN)
			body.add_child(key)
			body.add_child(value)
			row.set_meta("labels", [key, value])
			_environment_popup_rows.add_child(row)
		var labels: Array = row.get_meta("labels") as Array
		labels[0].text = str(entry.get("label", ""))
		labels[1].text = str(entry.get("value", _unknown()))
	_cleanup_rows(_environment_popup_rows, active)
	_ensure_empty_row(_environment_popup_rows, active.is_empty(), _t("location.operations.environment_empty", "No environmental readings are revealed."))


func _data_row(row_name: String, ratios: Array[float], action_name: String, callback: Callable) -> PanelContainer:
	var row := PanelContainer.new()
	row.name = row_name
	row.add_theme_stylebox_override("panel", _panel_style(Color("101e28"), Color(BORDER, 0.72), 2))
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(4))
	row.add_child(body)
	var labels: Array = []
	for ratio in ratios:
		var label := _table_label("", float(ratio), OFFWHITE)
		labels.append(label)
		body.add_child(label)
	var action := _button(action_name, "→", CYAN)
	action.custom_minimum_size.x = UiTokens.layout_px(30)
	action.tooltip_text = _t("location.operations.open_detail", "Open the related operation.")
	action.pressed.connect(callback)
	body.add_child(action)
	row.set_meta("labels", labels)
	row.set_meta("action", action)
	return row


func _stock_card(row_name: String, item_id: String, action_name: String, callback: Callable, resource_card: bool) -> Panel:
	var row := Panel.new()
	row.name = row_name
	row.custom_minimum_size = Vector2.ONE
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.clip_contents = true
	row.add_theme_stylebox_override("panel", _panel_style(STOCK_BACKGROUND, STOCK_BORDER, 2))
	var track := ColorRect.new()
	track.name = "StorageTrack"
	track.color = Color("14232c")
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.anchor_left = 0.91
	track.anchor_right = 0.97
	track.anchor_top = 0.04
	track.anchor_bottom = 0.96
	row.add_child(track)
	var fill := ColorRect.new()
	fill.name = "StorageFill"
	fill.color = STOCK_GREEN
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.anchor_left = 0.0
	fill.anchor_top = 1.0
	fill.anchor_right = 1.0
	fill.anchor_bottom = 1.0
	fill.offset_left = 0.0
	fill.offset_top = 0.0
	fill.offset_right = 0.0
	fill.offset_bottom = 0.0
	track.add_child(fill)
	var icon := ItemIcon.new()
	icon.name = "ItemIcon"
	icon.custom_minimum_size = Vector2.ONE
	icon.anchor_left = 0.10
	icon.anchor_top = 0.02
	icon.anchor_right = 0.82
	icon.anchor_bottom = 0.74
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var quantity := _label("", 14, STOCK_INK)
	quantity.name = "StockQuantity"
	quantity.anchor_left = 0.06
	quantity.anchor_top = 0.72
	quantity.anchor_right = 0.71
	quantity.anchor_bottom = 0.98
	quantity.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	quantity.clip_text = true
	quantity.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(quantity)
	var trend := _label("—", 12, STOCK_INK)
	trend.name = "TrendSymbol"
	trend.anchor_left = 0.72
	trend.anchor_top = 0.73
	trend.anchor_right = 0.90
	trend.anchor_bottom = 0.98
	trend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	trend.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	trend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(trend)
	var action := Button.new()
	action.name = action_name
	action.flat = true
	action.text = ""
	action.focus_mode = Control.FOCUS_ALL
	action.tooltip_text = _t("location.operations.open_detail", "Open the related operation.")
	action.accessibility_name = action.tooltip_text
	action.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	action.add_theme_stylebox_override("focus", _control_style(Color(0.0, 0.0, 0.0, 0.0), CYAN, 2))
	action.pressed.connect(callback)
	row.add_child(action)
	row.set_meta("fill", fill)
	row.set_meta("icon", icon)
	row.set_meta("trend", trend)
	row.set_meta("quantity", quantity)
	row.set_meta("action", action)
	row.set_meta("resource_card", resource_card)
	return row


func _resource_card(row_name: String, resource_id: String) -> Panel:
	return _stock_card(row_name, resource_id, "LocationResource%s" % resource_id.validate_node_name(), func() -> void: _open_resource(resource_id), true)


func _inventory_card(row_name: String, item_id: String) -> Panel:
	return _stock_card(row_name, item_id, "LocationInventoryItem%s" % item_id.validate_node_name(), func() -> void: _emit_action({"kind":"OPEN_INVENTORY"}), false)


func _facility_card(row_name: String, facility_id: String) -> Panel:
	var row := Panel.new()
	row.name = row_name
	row.custom_minimum_size.y = UiTokens.layout_px(62)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("panel", _panel_style(Color("10212d"), Color(BORDER, 0.84), 3))
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", UiTokens.layout_px(5))
	margin.add_theme_constant_override("margin_right", UiTokens.layout_px(5))
	margin.add_theme_constant_override("margin_top", UiTokens.layout_px(4))
	margin.add_theme_constant_override("margin_bottom", UiTokens.layout_px(4))
	row.add_child(margin)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(6))
	margin.add_child(body)
	var art_frame := PanelContainer.new()
	art_frame.custom_minimum_size = UiTokens.layout_vector(Vector2(42, 42))
	art_frame.add_theme_stylebox_override("panel", _panel_style(Color("17313a"), Color(CYAN, 0.46), 3))
	body.add_child(art_frame)
	var art := TextureRect.new()
	art.name = "BuildingArt"
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.modulate = Color(0.78, 0.96, 1.0, 0.96)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_frame.add_child(art)
	var fallback := _label("▥", 18, CYAN)
	fallback.name = "BuildingFallback"
	fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_frame.add_child(fallback)
	var copy := VBoxContainer.new()
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.add_theme_constant_override("separation", 0)
	body.add_child(copy)
	var title_row := HBoxContainer.new()
	copy.add_child(title_row)
	var name_label := _label(facility_id, 10, OFFWHITE)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_row.add_child(name_label)
	var badge := PanelContainer.new()
	badge.name = "StatusBadge"
	title_row.add_child(badge)
	var status := _label("", 8, GREEN)
	status.name = "Status"
	badge.add_child(status)
	var product := _label("", 9, MUTED)
	product.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	copy.add_child(product)
	var bottom := HBoxContainer.new()
	copy.add_child(bottom)
	var rate := _label("", 9, GREEN)
	rate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(rate)
	var power := _label("", 8, MUTED)
	power.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bottom.add_child(power)
	var action := Button.new()
	action.name = "LocationFacility%s" % facility_id.validate_node_name()
	action.flat = true
	action.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	action.add_theme_stylebox_override("focus", _control_style(Color(0.0, 0.0, 0.0, 0.0), CYAN, 2))
	action.pressed.connect(func() -> void: _open_facility(facility_id))
	row.add_child(action)
	row.set_meta("art", art)
	row.set_meta("art_fallback", fallback)
	row.set_meta("name", name_label)
	row.set_meta("product", product)
	row.set_meta("rate", rate)
	row.set_meta("power", power)
	row.set_meta("status", status)
	row.set_meta("status_badge", badge)
	row.set_meta("action", action)
	return row


func _task_row(row_name: String, task_id: String) -> Panel:
	var row := Panel.new()
	row.name = row_name
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.custom_minimum_size.y = UiTokens.layout_px(60)
	row.add_theme_stylebox_override("panel", _panel_style(Color("10212d"), Color(AMBER, 0.54), 3))
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", UiTokens.layout_px(5))
	margin.add_theme_constant_override("margin_right", UiTokens.layout_px(5))
	margin.add_theme_constant_override("margin_top", UiTokens.layout_px(4))
	margin.add_theme_constant_override("margin_bottom", UiTokens.layout_px(4))
	row.add_child(margin)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(6))
	margin.add_child(body)
	var art_frame := PanelContainer.new()
	art_frame.custom_minimum_size = UiTokens.layout_vector(Vector2(40, 40))
	art_frame.add_theme_stylebox_override("panel", _panel_style(Color("312a1d"), Color(AMBER, 0.54), 3))
	body.add_child(art_frame)
	var art := TextureRect.new()
	art.name = "TaskArt"
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.modulate = Color(1.0, 0.86, 0.62, 0.96)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_frame.add_child(art)
	var fallback := _label("▣", 17, AMBER)
	fallback.name = "TaskFallback"
	fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_frame.add_child(fallback)
	var copy := VBoxContainer.new()
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.add_theme_constant_override("separation", 0)
	body.add_child(copy)
	var title_row := HBoxContainer.new()
	copy.add_child(title_row)
	var task := _label("", 10, OFFWHITE)
	task.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	task.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_row.add_child(task)
	var badge := PanelContainer.new()
	title_row.add_child(badge)
	var status := _label("", 8, AMBER)
	badge.add_child(status)
	var kind := _label("", 8, MUTED)
	kind.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	copy.add_child(kind)
	var progress := ProgressBar.new()
	progress.name = "LocationTaskProgress_%s" % task_id.validate_node_name()
	progress.custom_minimum_size.y = UiTokens.layout_px(8)
	progress.max_value = 100.0
	progress.show_percentage = false
	progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress.add_theme_stylebox_override("background", _panel_style(INSET, BORDER, 2))
	progress.add_theme_stylebox_override("fill", _panel_style(AMBER.darkened(0.28), AMBER, 2))
	copy.add_child(progress)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", UiTokens.layout_px(5))
	copy.add_child(bottom)
	var blocker := _label("", 8, CRITICAL)
	blocker.name = "Blocker"
	blocker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	blocker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bottom.add_child(blocker)
	var remaining := _label("", 8, MUTED)
	remaining.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bottom.add_child(remaining)
	var percent := _label("", 8, AMBER)
	percent.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bottom.add_child(percent)
	var action := Button.new()
	action.name = "LocationTask%s" % task_id.validate_node_name()
	action.flat = true
	action.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	action.add_theme_stylebox_override("focus", _control_style(Color(0.0, 0.0, 0.0, 0.0), AMBER, 2))
	action.pressed.connect(func() -> void: _open_task(task_id))
	row.add_child(action)
	row.set_meta("art", art)
	row.set_meta("art_fallback", fallback)
	row.set_meta("name", task)
	row.set_meta("kind", kind)
	row.set_meta("status", status)
	row.set_meta("status_badge", badge)
	row.set_meta("blocker", blocker)
	row.set_meta("remaining", remaining)
	row.set_meta("percent", percent)
	row.set_meta("progress", progress)
	row.set_meta("action", action)
	return row


func _update_stock_visuals(row: Panel, item: Dictionary) -> void:
	var concealed := bool(row.get_meta("resource_card", false)) and not bool(item.get("discovered", false))
	var fill_ratio := 0.0 if concealed else _stock_fill_ratio(item)
	var fill := row.get_meta("fill") as ColorRect
	fill.anchor_top = 1.0 - fill_ratio
	fill.color = STOCK_GREEN if not concealed and _stock_capacity_known(item) else Color.TRANSPARENT
	var quantity := row.get_meta("quantity") as Label
	quantity.text = _compact_stock_quantity(float(item.get("quantity", 0.0))) if not concealed and item.has("quantity") else ""
	quantity.visible = not quantity.text.is_empty()
	var trend := row.get_meta("trend") as Label
	var trend_data := _trend_text({}) if concealed else _trend_text(item)
	trend.text = str(trend_data.get("symbol", "—"))
	if not concealed and trend.text == "—":
		trend.text = "▶"
	trend.visible = not concealed
	var trend_tone := STOCK_GREEN if trend.text == "▲" else CRITICAL if trend.text == "▼" else MUTED
	trend.add_theme_color_override("font_color", trend_tone)
	var icon := row.get_meta("icon") as Control
	var item_id := str(item.get("item_id", item.get("id", "")))
	if bool(row.get_meta("resource_card", false)) and not bool(item.get("discovered", false)):
		# An unknown field cannot leak a hidden resource's canonical item ID through
		# its silhouette. The generic scan glyph carries no material information.
		item_id = "survey_unknown"
	if icon != null:
		icon.call("configure_item", item_id, str(item.get("category", "")))


func _compact_stock_quantity(value: float) -> String:
	# Short labels preserve the square's bottom row; exact values stay in hover.
	if absf(value) >= 1000000.0:
		return "%.1fM" % (value / 1000000.0)
	if absf(value) >= 10000.0:
		return "%.1fk" % (value / 1000.0)
	return _number(value)


func _stock_fill_ratio(item: Dictionary) -> float:
	if item.has("fill_ratio") and (item.get("fill_ratio") is float or item.get("fill_ratio") is int):
		return clampf(float(item.get("fill_ratio")), 0.0, 1.0)
	var capacity := float(item.get("capacity", 0.0))
	return clampf(float(item.get("quantity", 0.0)) / capacity, 0.0, 1.0) if capacity > 0.0 else 0.0


func _stock_capacity_known(item: Dictionary) -> bool:
	return (item.has("fill_ratio") and (item.get("fill_ratio") is float or item.get("fill_ratio") is int)) \
		or (item.has("capacity") and float(item.get("capacity", 0.0)) > 0.0)


func _stock_quantity_text(item: Dictionary) -> String:
	if not item.has("quantity"):
		return _unknown()
	var quantity := _number(float(item.get("quantity", 0.0)))
	if _stock_capacity_known(item) and item.has("capacity"):
		return "%s / %s" % [quantity, _number(float(item.get("capacity", 0.0)))]
	return quantity


func _trend_text(item: Dictionary) -> Dictionary:
	if not bool(item.get("trend_known", false)):
		return {"symbol":"—", "detail":_t("location.operations.trend_unknown", "No trend"), "tone":MUTED}
	var rate := float(item.get("net_rate_per_minute", 0.0))
	if rate > 0.0005:
		return {"symbol":"▲", "detail":"▲ +%s/m" % _number(rate), "tone":GREEN}
	if rate < -0.0005:
		return {"symbol":"▼", "detail":"▼ %s/m" % _number(rate), "tone":CRITICAL}
	return {"symbol":"—", "detail":_t("location.operations.balanced", "Balanced"), "tone":MUTED}


func _stock_card_tooltip(item: Dictionary) -> String:
	var capacity_text := _stock_quantity_text(item)
	var lines: Array[String] = ["%s\n%s: %s" % [str(item.get("name", item.get("id", _unknown()))), _t("location.operations.individual_storage", "Individual storage"), capacity_text]]
	if item.has("quantity") or item.has("incoming"):
		# Location owns one per-item inventory. A warehouse is a road access point,
		# never a second stock quantity to add or compare here.
		lines.append(_t("location.operations.location_custody", "Location-held %d · In transit %d") % [int(item.get("quantity", item.get("location_quantity", 0))), int(item.get("incoming", 0))])
	lines.append(str(_trend_text(item).get("detail", _t("location.operations.trend_unknown", "No trend"))))
	lines.append(_t("location.operations.trend_help", "Arrows measure recent Location-held stock changes in simulation time, not theoretical production. Transfers between shared-inventory access points are neutral."))
	return "\n".join(lines)


func _resource_card_tooltip(resource: Dictionary) -> String:
	if not bool(resource.get("discovered", false)):
		# DETECTED fields intentionally remain opaque. Do not leak a fixture's
		# provisional name, canonical item ID, potential, grade, or stock values
		# through hover text or assistive technology.
		return "%s · %s" % [_unknown(), _category_text(str(resource.get("category", "UNKNOWN")))]
	var lines: Array[String] = [str(resource.get("name", _unknown())), _resource_grade_text(resource), _resource_potential_text(resource)]
	if _stock_capacity_known(resource):
		lines.append("%s: %s" % [_t("location.operations.individual_storage", "Individual storage"), _stock_quantity_text(resource)])
	lines.append(str(_trend_text(resource).get("detail", _t("location.operations.trend_unknown", "No trend"))))
	return "\n".join(lines)


func _update_status_badge(badge: PanelContainer, label: Label, status_value: String) -> void:
	var tone := _status_tone(status_value)
	badge.add_theme_stylebox_override("panel", _panel_style(Color(tone, 0.15), Color(tone, 0.76), 2))
	label.text = _display_value(status_value)
	label.add_theme_color_override("font_color", tone)


func _update_building_art(art: TextureRect, definition_id: String, kind: String) -> void:
	if art == null:
		return
	art.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), definition_id, kind)
	var fallback := art.get_parent().get_node_or_null("BuildingFallback") as Label
	if fallback == null:
		fallback = art.get_parent().get_node_or_null("TaskFallback") as Label
	art.visible = art.texture != null
	if fallback != null:
		fallback.visible = not art.visible


func _update_task_art(art: TextureRect, task: Dictionary) -> void:
	var item_id := str(task.get("item_id", ""))
	if not item_id.is_empty():
		# Survey and transport snapshots provide the actual sensor/cargo item. Do
		# not substitute an unrelated constructed research building or depot.
		art.texture = ItemIcon.texture_for_item(item_id)
		var item_fallback := art.get_parent().get_node_or_null("TaskFallback") as Label
		art.visible = art.texture != null
		if item_fallback != null:
			item_fallback.visible = not art.visible
		return
	var definition_id := str(task.get("definition_id", ""))
	if definition_id.is_empty():
		art.texture = null
		art.visible = false
		var fallback := art.get_parent().get_node_or_null("TaskFallback") as Label
		if fallback != null:
			fallback.visible = true
		return
	_update_building_art(art, definition_id, "CONSTRUCTION")


func _task_card_tooltip(task: Dictionary) -> String:
	var details: Array[String] = [str(task.get("name", task.get("kind", _unknown()))), _display_value(task.get("status", "")), _remaining_text(task)]
	var blocker := str(task.get("blocker", ""))
	if not blocker.is_empty():
		details.append(blocker)
	return "\n".join(details)


func _cleanup_rows(container: Container, active: Dictionary) -> void:
	for child in container.get_children():
		if child.name.begins_with("Empty"):
			container.remove_child(child)
			child.queue_free()
		elif not active.has(child.name):
			container.remove_child(child)
			child.queue_free()


func _ensure_empty_stock_tile(container: Container, empty: bool, tooltip: String) -> void:
	if not empty:
		return
	var tile := Panel.new()
	tile.name = "EmptyStockTile"
	tile.custom_minimum_size = Vector2.ONE
	tile.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tile.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	tile.tooltip_text = tooltip
	tile.accessibility_name = tooltip
	tile.add_theme_stylebox_override("panel", _panel_style(STOCK_BACKGROUND, STOCK_BORDER, 2))
	var glyph := _label("◇", 24, STOCK_INK)
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(glyph)
	container.add_child(tile)


func _ensure_empty_row(container: Container, empty: bool, text: String) -> void:
	if not empty:
		return
	var row := PanelContainer.new()
	row.name = "EmptyState"
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("panel", _panel_style(INSET, BORDER, 2))
	var label := _label(text, 10, MUTED)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	container.add_child(row)


func _ensure_empty_action_card(container: Container, empty: bool, text: String, action_text: String, action_name: String, callback: Callable, art_definition_id := "grid_planetary_core") -> void:
	if not empty:
		return
	var row := PanelContainer.new()
	row.name = "EmptyActionState"
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.custom_minimum_size.y = UiTokens.layout_px(54)
	row.add_theme_stylebox_override("panel", _panel_style(INSET, BORDER, 3))
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(6))
	row.add_child(body)
	var art := TextureRect.new()
	art.name = "EmptyStateBuildingArt"
	art.custom_minimum_size = UiTokens.layout_vector(Vector2(44, 44))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), art_definition_id, "STORAGE")
	body.add_child(art)
	var label := _label(text, 9, MUTED)
	label.name = "EmptyStateDescription"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(label)
	var action := _button(action_name, action_text, CYAN)
	action.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	action.pressed.connect(callback)
	body.add_child(action)
	container.add_child(row)


func _on_survey_ship_selected(index: int) -> void:
	_selected_ship_id = str(_survey_ship_selector.get_item_metadata(index))
	_update_survey_controls()


func _on_inventory_filter_selected(index: int) -> void:
	_inventory_filter = str(_inventory_filter_selector.get_item_metadata(index))
	_sync_inventory_rows(_filtered_inventory())


func _on_survey_pressed() -> void:
	var survey: Dictionary = _dictionary(_snapshot.get("survey"))
	if bool(survey.get("active", false)):
		_emit_action({"kind":"OPEN_SURVEY", "location_id":str(survey.get("target_location_id", _snapshot.get("location_id", "")))})
		return
	if _selected_ship_id.is_empty():
		_emit_action({"kind":"OPEN_SURVEY_SHIPYARD"})
		return
	if bool(survey.get("can_start", false)):
		_emit_action({"kind":"START_SURVEY", "ship_id":_selected_ship_id, "next_state":str(survey.get("next_state", ""))})


func _on_assign_survey_ship_pressed() -> void:
	if _selected_ship_can_assign():
		_emit_action({"kind":"ASSIGN_SURVEY_SHIP", "ship_id":_selected_ship_id})


func _on_factory_pressed() -> void:
	var world_id := str(_snapshot.get("world_id", ""))
	if not world_id.is_empty():
		_open_factory("OVERVIEW")
	elif bool(_snapshot.get("can_initialize_factory", false)):
		_emit_action({"kind":"INITIALIZE_FACTORY"})


func _open_factory(section: String, entity_id := "", row_world_id := "") -> void:
	var world_id := row_world_id if not row_world_id.is_empty() else str(_snapshot.get("world_id", ""))
	if world_id.is_empty():
		return
	var action := {"kind":"OPEN_FACTORY", "world_id":world_id, "section":section}
	if not entity_id.is_empty():
		action["entity_id"] = entity_id
	_emit_action(action)


func _open_resource(resource_id: String) -> void:
	for resource_value in _array(_snapshot.get("resources")):
		if resource_value is Dictionary and str((resource_value as Dictionary).get("id", "")) == resource_id:
			_emit_action(_resource_action(resource_value as Dictionary))
			break


func _resource_action(resource: Dictionary) -> Dictionary:
	var explicit := _dictionary(resource.get("action"))
	if not explicit.is_empty():
		return explicit
	var world_id := str(resource.get("world_id", ""))
	if not world_id.is_empty():
		var action := {"kind":"OPEN_FACTORY", "world_id":world_id, "section":"CANVAS"}
		var entity_id := str(resource.get("entity_id", ""))
		if not entity_id.is_empty():
			action["entity_id"] = entity_id
		return action
	if bool(_snapshot.get("can_initialize_factory", false)):
		return {"kind":"INITIALIZE_FACTORY"}
	return {"kind":"OPEN_SURVEY", "location_id":str(_snapshot.get("location_id", ""))}


func _open_industry_empty_action() -> void:
	var action := _dictionary(_snapshot.get("industry_empty_action"))
	if action.is_empty():
		_on_factory_pressed()
		return
	_emit_action(action)


func _open_industry_board() -> void:
	if _array(_snapshot.get("facilities")).is_empty():
		_open_industry_empty_action()
		return
	_open_factory("PRODUCTION")


func _open_task_empty_action() -> void:
	var action := _dictionary(_snapshot.get("task_empty_action"))
	if action.is_empty():
		var world_id := str(_snapshot.get("world_id", ""))
		if not world_id.is_empty():
			action = {"kind":"OPEN_FACTORY", "world_id":world_id, "section":"CANVAS"}
		elif bool(_snapshot.get("can_initialize_factory", false)):
			action = {"kind":"INITIALIZE_FACTORY"}
		else:
			action = {"kind":"OPEN_SURVEY", "location_id":str(_snapshot.get("location_id", ""))}
	_emit_action(action)


func _open_facility(facility_id: String) -> void:
	for facility_value in _array(_snapshot.get("facilities")):
		if facility_value is Dictionary and str((facility_value as Dictionary).get("id", "")) == facility_id:
			var facility: Dictionary = facility_value as Dictionary
			_open_factory("PRODUCTION", facility_id, str(facility.get("world_id", "")))
			return


func _open_alert(index: int) -> void:
	var alerts := _array(_snapshot.get("alerts"))
	if index >= 0 and index < alerts.size() and alerts[index] is Dictionary:
		var alert: Dictionary = alerts[index] as Dictionary
		_open_factory("CANVAS", str(alert.get("entity_id", "")), str(alert.get("world_id", "")))


func _open_task(task_id: String) -> void:
	for task_value in _array(_snapshot.get("tasks")):
		if task_value is Dictionary and str((task_value as Dictionary).get("id", "")) == task_id:
			var action := _dictionary((task_value as Dictionary).get("action"))
			_emit_action(action)
			return


func _show_environment_popup() -> void:
	if _environment_popup == null:
		return
	var viewport_size := get_viewport_rect().size
	_environment_popup.position = Vector2i(
		maxi(0, int((viewport_size.x - _environment_popup.size.x) * 0.5)),
		maxi(0, int((viewport_size.y - _environment_popup.size.y) * 0.5))
	)
	_environment_popup.popup()


func _filtered_inventory() -> Array:
	var filtered: Array = []
	for item_value in _array(_snapshot.get("inventory")):
		if not item_value is Dictionary:
			continue
		var item: Dictionary = item_value as Dictionary
		if _inventory_filter == "ALL" or str(item.get("category", "")) == _inventory_filter:
			filtered.append(item)
	return filtered


func _resource_grade_text(resource: Dictionary) -> String:
	if not bool(resource.get("discovered", false)) or not resource.has("grade"):
		return _unknown()
	var grade = resource.get("grade")
	return _number(float(grade)) if grade is float or grade is int else _display_value(grade)


func _resource_potential_text(resource: Dictionary) -> String:
	if resource.has("potential_band"):
		return _display_value(resource.get("potential_band"))
	if bool(resource.get("discovered", false)) and resource.has("potential_per_hour"):
		return "%s/h" % _number(float(resource.get("potential_per_hour")))
	return _unknown()


func _resource_development_text(resource: Dictionary) -> String:
	if not bool(resource.get("discovered", false)):
		return _unknown()
	if bool(resource.get("exploited", false)):
		return _t("location.operations.exploited", "Developed")
	return _t("location.operations.available", "Available")


func _category_text(category: String) -> String:
	if category.is_empty():
		return _unknown()
	var i18n := get_node_or_null("/root/I18n")
	if i18n != null:
		var localized := str(i18n.call("category", category))
		if not localized.is_empty() and localized != category:
			return localized
	return _display_value(category)


func _facility_output_tooltip(facility: Dictionary) -> String:
	var outputs := _array(facility.get("outputs"))
	if outputs.is_empty():
		return _t("location.operations.open_detail", "Open the related operation.")
	var parts: Array[String] = []
	for output_value in outputs:
		if output_value is Dictionary:
			var output: Dictionary = output_value as Dictionary
			parts.append("%s %s/h" % [str(output.get("name", _unknown())), _number(float(output.get("rate_per_hour", 0.0)))])
	return "%s: %s" % [_t("location.operations.actual_outputs", "Actual outputs"), " · ".join(parts)]


func _environment_summary_text() -> String:
	var parts: Array[String] = []
	var effects: Dictionary = _dictionary(_snapshot.get("environment_effects"))
	if effects.has("solar_generation_multiplier"):
		parts.append("%s ×%s" % [_t("location.operations.solar_generation", "Solar generation"), _multiplier(float(effects.get("solar_generation_multiplier")))])
	if effects.has("power_demand_multiplier"):
		parts.append("%s ×%s" % [_t("location.operations.power_demand", "Power demand"), _multiplier(float(effects.get("power_demand_multiplier")))])
	return "   |   ".join(parts) if not parts.is_empty() else _t("location.operations.environment_empty", "No environmental readings are revealed.")


func _environment_effect_tooltip() -> String:
	var effects: Dictionary = _dictionary(_snapshot.get("environment_effects"))
	var labels := {
		"thermal_power_multiplier":_t("location.operations.thermal_power", "Thermal power"),
		"radiation_power_multiplier":_t("location.operations.radiation_power", "Radiation power"),
		"gravity_power_multiplier":_t("location.operations.gravity_power", "Gravity power"),
		"atmosphere_power_multiplier":_t("location.operations.atmosphere_power", "Atmosphere power")
	}
	var parts: Array[String] = []
	for key in labels.keys():
		if effects.has(key):
			parts.append("%s ×%s" % [labels[key], _multiplier(float(effects.get(key)))])
	return _t("location.operations.environment_details", "Environmental Effects") + ("\n" + " · ".join(parts) if not parts.is_empty() else "")


func _environment_entries() -> Array:
	var entries: Array = []
	var environment: Dictionary = _dictionary(_snapshot.get("environment"))
	var environment_labels := {
		"gravity":_t("location.operations.gravity", "Gravity"),
		"atmosphere":_t("location.operations.atmosphere", "Atmosphere"),
		"radiation":_t("location.operations.radiation", "Radiation"),
		"solar_flux":_t("location.operations.solar_flux", "Solar flux"),
		"thermal_environment":_t("location.operations.thermal", "Thermal environment"),
		"construction_difficulty":_t("location.operations.construction_difficulty", "Construction difficulty"),
		"transport_distance":_t("location.operations.transport_distance", "Transport distance"),
		"construction_difficulty_band":_t("location.operations.construction_difficulty", "Construction difficulty"),
		"transport_distance_band":_t("location.operations.transport_distance", "Transport distance")
	}
	for key in environment_labels.keys():
		if environment.has(key):
			var value = environment.get(key)
			entries.append({"label":environment_labels[key], "value":_number(float(value)) if value is float or value is int else _display_value(value)})
	var effects: Dictionary = _dictionary(_snapshot.get("environment_effects"))
	var effect_labels := {
		"solar_generation_multiplier":_t("location.operations.solar_generation", "Solar generation"),
		"power_demand_multiplier":_t("location.operations.power_demand", "Power demand"),
		"thermal_power_multiplier":_t("location.operations.thermal_power", "Thermal power"),
		"radiation_power_multiplier":_t("location.operations.radiation_power", "Radiation power"),
		"gravity_power_multiplier":_t("location.operations.gravity_power", "Gravity power"),
		"atmosphere_power_multiplier":_t("location.operations.atmosphere_power", "Atmosphere power")
	}
	for key in effect_labels.keys():
		if effects.has(key):
			entries.append({"label":effect_labels[key], "value":"×%s" % _multiplier(float(effects.get(key)))})
	var details = effects.get("details", {})
	if details is Dictionary:
		for key in (details as Dictionary).keys():
			var value = (details as Dictionary).get(key)
			entries.append({"label":_display_value(key), "value":_number(float(value)) if value is float or value is int else _display_value(value)})
	return entries


func _survey_progress_text(survey: Dictionary) -> String:
	return "%s  ·  %.0f%%  ·  %s" % [_display_value(survey.get("next_state")), 100.0 * float(survey.get("progress", 0.0)), _remaining_text(survey)]


func _selected_ship_can_assign() -> bool:
	var survey: Dictionary = _dictionary(_snapshot.get("survey"))
	for ship_value in _array(survey.get("ships")):
		if ship_value is Dictionary:
			var ship: Dictionary = ship_value as Dictionary
			if str(ship.get("id", "")) == _selected_ship_id:
				return bool(ship.get("can_assign", false)) and not bool(ship.get("allowed", false))
	return false


func _remaining_text(value: Dictionary) -> String:
	if not value.has("remaining_ms"):
		return _unknown()
	var remaining_ms := float(value.get("remaining_ms", 0.0))
	if remaining_ms < 0.0:
		return _unknown()
	var total_seconds := maxi(0, int(round(remaining_ms / 1000.0)))
	var hours := total_seconds / 3600
	var minutes := (total_seconds % 3600) / 60
	if hours > 0:
		return "%dh %02dm" % [hours, minutes]
	if minutes > 0:
		return "%dm" % minutes
	return "%ds" % total_seconds


func _dynamic_interaction_active() -> bool:
	if _survey_ship_selector != null and _survey_ship_selector.get_popup().visible:
		return true
	if _inventory_filter_selector != null and _inventory_filter_selector.get_popup().visible:
		return true
	for button_value in find_children("*", "BaseButton", true, false):
		var button := button_value as BaseButton
		if button != null and button.is_hovered():
			return true
	return false


func _emit_action(action: Dictionary) -> void:
	if not action.is_empty():
		action_requested.emit(action.duplicate(true))


func _button(node_name: String, text_value: String, tone: Color) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text_value
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	button.add_theme_stylebox_override("normal", _control_style(Color("142630"), Color(tone, 0.72), 3))
	button.add_theme_stylebox_override("hover", _control_style(Color("203b48"), tone, 3))
	button.add_theme_stylebox_override("pressed", _control_style(Color("21434e"), tone, 3))
	button.add_theme_stylebox_override("focus", _control_style(Color("21434e"), CYAN, 3))
	button.add_theme_stylebox_override("disabled", _control_style(Color("142630"), BORDER, 3))
	return button


func _style_selector(selector: OptionButton, tone: Color) -> void:
	selector.add_theme_stylebox_override("normal", _control_style(Color("142630"), Color(tone, 0.72), 3))
	selector.add_theme_stylebox_override("hover", _control_style(Color("203b48"), tone, 3))
	selector.add_theme_stylebox_override("focus", _control_style(Color("21434e"), CYAN, 3))
	selector.add_theme_stylebox_override("disabled", _control_style(Color("142630"), BORDER, 3))


func _label(value: String, size_px: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", UiTokens.font_size(size_px))
	label.add_theme_color_override("font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _table_label(value: String, ratio: float, color: Color) -> Label:
	var label := _label(value, 10, color)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_stretch_ratio = ratio
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


func _status_tone(status: String) -> Color:
	match status.to_upper():
		"RUNNING", "READY", "OPERATIONAL", "ACTIVE": return GREEN
		"BLOCKED", "OFFLINE", "INPUT_SHORTAGE", "OUTPUT_FULL": return AMBER
		"FAILED", "CRITICAL": return CRITICAL
		_: return MUTED


func _display_value(value: Variant) -> String:
	var text := str(value)
	var i18n := get_node_or_null("/root/I18n")
	if i18n != null and not text.is_empty():
		var translated := str(i18n.call("status", text))
		if translated != text:
			return translated
	return text.replace("_", " ").capitalize() if not text.is_empty() else _unknown()


func _panel_style(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := UiTokens.panel_style(background, border, radius)
	style.content_margin_left = UiTokens.layout_px(4)
	style.content_margin_right = UiTokens.layout_px(4)
	style.content_margin_top = UiTokens.layout_px(3)
	style.content_margin_bottom = UiTokens.layout_px(3)
	return style


func _control_style(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := UiTokens.control_style(background, border, radius)
	style.content_margin_top = UiTokens.layout_px(2)
	style.content_margin_bottom = UiTokens.layout_px(2)
	return style


func _number(value: float) -> String:
	return "%.1f" % value if absf(value - roundf(value)) > 0.001 else str(int(roundf(value)))


func _multiplier(value: float) -> String:
	return "%.2f" % value


func _signed_number(value: float) -> String:
	return ("+" if value > 0.0 else "") + _number(value)


func _unknown() -> String:
	return _t("location.operations.unknown", "Unknown")


func _dictionary(value: Variant) -> Dictionary:
	return value as Dictionary if value is Dictionary else {}


func _array(value: Variant) -> Array:
	return value as Array if value is Array else []


func _t(key: String, fallback: String) -> String:
	var i18n := get_node_or_null("/root/I18n")
	return str(i18n.call("core", key, fallback)) if i18n != null else fallback
