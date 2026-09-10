class_name FactoryOperationsOverview
extends PanelContainer

## The Operations page is a read-only interpretation of the Factory snapshot.
## Its controls emit only the v1 focus/tab/building routes, which FactoryWorkspace
## translates locally. No Game reference or simulation mutation is reachable.

signal action_requested(action: Dictionary)

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const OperationsPresenter = preload("res://src/ui/view_models/factory/factory_operations_presenter.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const PANORAMA_PATH := "res://assets/ui/factory/operations_art/foundry_panorama.png"
const NAVY := Color("0c141c")
const RAISED := Color("15222d")
const BORDER := Color("304652")
const CYAN := Color("65d9d1")
const AMBER := Color("e5b467")
const OFFWHITE := Color("e4ecef")
const MUTED := Color("96aab7")
const CRITICAL := Color("ef867d")

var _presenter := OperationsPresenter.new()
var _snapshot: Dictionary = {}
var _operations: Dictionary = {}
var _content: VBoxContainer
var _selected_plan_id := ""
var _pending_rebuild := false


func _ready() -> void:
	name = "FactoryOperationsOverview"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_stylebox_override("panel", UiTokens.panel_style(NAVY, BORDER, 4))
	_build_shell()
	_rebuild()
	set_process(false)


func configure(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	_operations = _presenter.build(_snapshot)
	if is_node_ready():
		# An operations refresh is common while a player is comparing build
		# targets. Do not replace the OptionButton while its native popup owns
		# focus; apply the immutable update immediately after it closes.
		if _planner_selector_open():
			_pending_rebuild = true
			set_process(true)
		else:
			_pending_rebuild = false
			set_process(false)
			_rebuild()


func _process(_delta: float) -> void:
	if not _pending_rebuild:
		set_process(false)
		return
	if _planner_selector_open():
		return
	_pending_rebuild = false
	set_process(false)
	_rebuild()


func operation_snapshot() -> Dictionary:
	return _operations.duplicate(true)


func _build_shell() -> void:
	var margin := MarginContainer.new()
	margin.name = "FactoryOperationsFrame"
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", UiTokens.layout_px(12))
	margin.add_theme_constant_override("margin_top", UiTokens.layout_px(10))
	margin.add_theme_constant_override("margin_right", UiTokens.layout_px(12))
	margin.add_theme_constant_override("margin_bottom", UiTokens.layout_px(10))
	add_child(margin)
	_content = VBoxContainer.new()
	_content.name = "FactoryOperationsContent"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", UiTokens.layout_px(7))
	margin.add_child(_content)


func _rebuild() -> void:
	if _content == null:
		return
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	_content.add_child(_build_hero())
	_content.add_child(_build_kpis())
	_content.add_child(_build_stage_chain())
	var boards := HBoxContainer.new()
	boards.name = "FactoryOperationsBoards"
	boards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	boards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	boards.add_theme_constant_override("separation", UiTokens.layout_px(8))
	var alert_board := _build_alert_board()
	alert_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	alert_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	alert_board.size_flags_stretch_ratio = 0.43
	boards.add_child(alert_board)
	var planner := _build_planner_board()
	planner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	planner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	planner.size_flags_stretch_ratio = 0.57
	boards.add_child(planner)
	_content.add_child(boards)


func _planner_selector_open() -> bool:
	var selector := find_child("FactoryOperationsBuildTarget", true, false) as OptionButton
	return selector != null and selector.get_popup().visible


func _build_hero() -> Control:
	var hero := PanelContainer.new()
	hero.name = "FactoryOperationsHero"
	hero.custom_minimum_size.y = UiTokens.layout_px(108)
	hero.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hero.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("0b1720"), Color(CYAN, 0.62), 4))
	var frame := Control.new()
	hero.add_child(frame)
	var backdrop := TextureRect.new()
	backdrop.name = "FactoryOperationsPanorama"
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.modulate = Color(0.82, 0.93, 1.0, 0.94)
	if ResourceLoader.exists(PANORAMA_PATH):
		backdrop.texture = load(PANORAMA_PATH) as Texture2D
	frame.add_child(backdrop)
	var shade := Panel.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade_style := StyleBoxFlat.new()
	shade_style.bg_color = Color("071018", 0.20)
	shade.add_theme_stylebox_override("panel", shade_style)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(shade)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", UiTokens.layout_px(14))
	margin.add_theme_constant_override("margin_top", UiTokens.layout_px(10))
	margin.add_theme_constant_override("margin_right", UiTokens.layout_px(14))
	margin.add_theme_constant_override("margin_bottom", UiTokens.layout_px(10))
	frame.add_child(margin)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(3))
	margin.add_child(body)
	var eyebrow := _label(_t("factory.operations.eyebrow", "HELIOS INDUSTRIAL AUTHORITY"), 9, OFFWHITE)
	eyebrow.name = "FactoryOperationsEyebrow"
	body.add_child(eyebrow)
	var heading := HBoxContainer.new()
	body.add_child(heading)
	var title := _label(_t("factory.operations.hero_title", "INDUSTRIAL COMMAND"), 22, OFFWHITE)
	title.name = "FactoryOperationsTitle"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var telemetry := _label(_telemetry_text(), 10, OFFWHITE)
	telemetry.name = "FactoryOperationsTelemetry"
	telemetry.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	heading.add_child(telemetry)
	var detail := _label(_t("factory.operations.subtitle", "From this foundation, forge the stars."), 13, OFFWHITE)
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(detail)
	return hero


func _build_kpis() -> Control:
	var row := HBoxContainer.new()
	row.name = "FactoryOperationsKpis"
	row.add_theme_constant_override("separation", UiTokens.layout_px(8))
	var metrics: Dictionary = _operations.get("metrics", {}) as Dictionary
	var power_supply := float(metrics.get("power_supply_kw", 0.0))
	var power_demand := float(metrics.get("power_demand_kw", 0.0))
	var cards := [
		["Extractors", "◆", str(int(metrics.get("extractors", 0))), _t("factory.operations.kpi.extractors", "collection units"), CYAN, _t("factory.operations.kpi_title.extractors", "Collection")],
		["Running", "▥", str(int(metrics.get("running_machines", 0))), _t("factory.operations.kpi.running", "active machines"), Color("9eb8cc"), _t("factory.operations.kpi_title.running", "Active machines")],
		["Power", "ϟ", "%.0f / %.0f" % [power_supply, power_demand], _t("factory.operations.kpi.power", "supply / demand kW"), AMBER, _t("factory.operations.kpi_title.power", "Power balance")],
		["Orders", "⌂", "%d / %d" % [int(metrics.get("active_orders", 0)), int(metrics.get("waiting_orders", 0))], _t("factory.operations.kpi.orders", "building / waiting"), Color("a5c5d8"), _t("factory.operations.kpi_title.orders", "Construction queue")]
	]
	for card_value in cards:
		var card: Array = card_value as Array
		var panel := PanelContainer.new()
		panel.name = "FactoryOperationsKpi%s" % str(card[0])
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.custom_minimum_size.y = UiTokens.layout_px(64)
		panel.add_theme_stylebox_override("panel", UiTokens.panel_style(RAISED, Color(card[4], 0.62), 4))
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", UiTokens.layout_px(2))
		panel.add_child(body)
		var upper := HBoxContainer.new()
		body.add_child(upper)
		upper.add_child(_label(str(card[1]), 18, card[4]))
		var caption := _label(str(card[5]), 12, OFFWHITE)
		caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		upper.add_child(caption)
		body.add_child(_label(str(card[2]), 20, card[4]))
		body.add_child(_label(str(card[3]), 9, MUTED))
		row.add_child(panel)
	return row


func _build_stage_chain() -> Control:
	var panel := PanelContainer.new()
	panel.name = "FactoryOperationsChain"
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(NAVY, BORDER, 4))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(4))
	panel.add_child(body)
	var header := HBoxContainer.new()
	body.add_child(header)
	var title := _label(_t("factory.operations.chain_title", "Physical expansion chain"), 12, OFFWHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var availability := _label(_t("factory.operations.live_extension", "LIVE PROJECTION") if bool(_operations.get("available", false)) else _t("factory.operations.snapshot_fallback", "SNAPSHOT VIEW"), 9, MUTED)
	header.add_child(availability)
	var chain := HBoxContainer.new()
	chain.name = "FactoryOperationsStages"
	chain.add_theme_constant_override("separation", UiTokens.layout_px(6))
	body.add_child(chain)
	var stages: Array = _operations.get("stages", []) as Array
	for index in stages.size():
		var stage_value = stages[index]
		if not stage_value is Dictionary:
			continue
		var stage := stage_value as Dictionary
		var stage_id := str(stage.get("id", "UNKNOWN"))
		var state := str(stage.get("state", "MISSING"))
		var button := Button.new()
		button.name = "FactoryOperationsStage%s" % stage_id.capitalize()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size.y = UiTokens.layout_px(60)
		button.add_theme_font_size_override("font_size", UiTokens.font_size(11))
		button.text = "%02d  %s\n●  %s\n%s" % [index + 1, _stage_label(stage_id), _state_label(state), _t("factory.operations.stage_count", "%d units") % int(stage.get("count", 0))]
		button.tooltip_text = _t("factory.operations.stage_action", "Open this operational surface.")
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.icon = BuildingArt.icon_texture(BuildingArt.atlas_texture(), _stage_art_definition(stage_id), "MACHINE")
		button.expand_icon = true
		button.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		button.add_theme_constant_override("icon_max_width", UiTokens.layout_px(48))
		var tone := _state_tone(state)
		button.add_theme_stylebox_override("normal", UiTokens.control_style(RAISED, Color(tone, 0.72), 3))
		button.add_theme_stylebox_override("hover", UiTokens.control_style(Color("1a2c38"), tone, 3))
		button.pressed.connect(_emit_action.bind(stage.get("action", {}) as Dictionary))
		chain.add_child(button)
		if index < stages.size() - 1:
			var arrow := _label("→", 26, CYAN)
			arrow.name = "FactoryOperationsStageArrow%d" % index
			arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			chain.add_child(arrow)
	return panel


func _build_alert_board() -> Control:
	var panel := PanelContainer.new()
	panel.name = "FactoryOperationsAlerts"
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(NAVY, BORDER, 4))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(4))
	panel.add_child(body)
	var heading := HBoxContainer.new()
	body.add_child(heading)
	heading.add_child(_label("▲", 22, CRITICAL))
	var heading_text := _label(_t("factory.operations.alerts", "Attention queue"), 15, OFFWHITE)
	heading_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(heading_text)
	heading.add_child(_label(_t("factory.operations.alerts_hint", "Live constraints on this world."), 9, MUTED))
	var alert_region := Control.new()
	alert_region.name = "FactoryOperationsAlertListRegion"
	alert_region.custom_minimum_size.y = UiTokens.layout_px(96)
	alert_region.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(alert_region)
	var alert_scroll := ScrollContainer.new()
	alert_scroll.name = "FactoryOperationsAlertListScroll"
	alert_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	alert_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	alert_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	alert_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	alert_region.add_child(alert_scroll)
	var alert_rows := VBoxContainer.new()
	alert_rows.name = "FactoryOperationsAlertRows"
	alert_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	alert_rows.add_theme_constant_override("separation", UiTokens.layout_px(4))
	alert_scroll.add_child(alert_rows)
	var alerts: Array = _operations.get("alerts", []) as Array
	if alerts.is_empty():
		var ready := _label(_t("factory.operations.alerts_clear", "No active blockers reported by current telemetry."), 13, CYAN)
		ready.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		alert_rows.add_child(ready)
	else:
		for alert_value in alerts.slice(0, 2):
			if not alert_value is Dictionary:
				continue
			var alert := alert_value as Dictionary
			var button := Button.new()
			button.name = "FactoryOperationsAlert%s" % str(alert.get("id", "alert")).validate_node_name()
			button.text = "●  " + _status_label(str(alert.get("code", "BLOCKED"))) + "\n" + _alert_detail(alert)
			button.tooltip_text = _t("factory.operations.alert_action", "Focus the affected order or factory entity.")
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.custom_minimum_size.y = UiTokens.layout_px(42)
			button.add_theme_font_size_override("font_size", UiTokens.font_size(11))
			button.add_theme_stylebox_override("normal", UiTokens.control_style(Color("1b1d26"), Color(CRITICAL, 0.65), 3))
			button.add_theme_stylebox_override("hover", UiTokens.control_style(Color("2a2028"), CRITICAL, 3))
			button.pressed.connect(_emit_action.bind(alert.get("action", {}) as Dictionary))
			alert_rows.add_child(button)
		if alerts.size() > 2:
			var all_reports := Button.new()
			all_reports.name = "FactoryOperationsAllReports"
			all_reports.text = _t("factory.operations.all_reports", "Production diagnostics") + " →"
			all_reports.tooltip_text = _t("factory.operations.all_reports_tooltip", "Inspect live machine status and material throughput.")
			all_reports.add_theme_stylebox_override("normal", UiTokens.control_style(Color("172a34"), Color(CRITICAL, 0.46), 2))
			all_reports.add_theme_stylebox_override("hover", UiTokens.control_style(Color("2a2028"), CRITICAL, 2))
			all_reports.pressed.connect(_emit_action.bind({"kind":"OPEN_TAB", "tab":"PRODUCTION"}))
			alert_rows.add_child(all_reports)
	return panel


func _build_planner_board() -> Control:
	var panel := PanelContainer.new()
	panel.name = "FactoryOperationsPlanner"
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(NAVY, BORDER, 4))
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UiTokens.layout_px(4))
	panel.add_child(body)
	var heading := HBoxContainer.new()
	body.add_child(heading)
	var title := _label(_t("factory.operations.planner", "Build target planner"), 15, OFFWHITE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	heading.add_child(_label(_t("factory.operations.planner_hint", "materials, deficits, dependencies"), 9, MUTED))
	var plans: Array = _operations.get("build_plans", []) as Array
	if (not plans.is_empty()) and _plan_by_id(_selected_plan_id).is_empty():
		_selected_plan_id = str((plans[0] as Dictionary).get("definition_id", ""))
	var selector := OptionButton.new()
	selector.name = "FactoryOperationsBuildTarget"
	selector.tooltip_text = _t("factory.operations.select_plan", "Material and dependency briefing for this target.")
	selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selector.add_theme_stylebox_override("normal", UiTokens.control_style(RAISED, Color(CYAN, 0.70), 3))
	selector.add_theme_stylebox_override("hover", UiTokens.control_style(Color("1a2d39"), CYAN, 3))
	selector.add_theme_stylebox_override("focus", UiTokens.control_style(RAISED, CYAN, 3))
	var selected_index := 0
	for plan_value in plans:
		if not plan_value is Dictionary:
			continue
		var plan := plan_value as Dictionary
		var definition_id := str(plan.get("definition_id", ""))
		selector.add_item(_building_name(definition_id) + "  ·  " + (_t("factory.operations.affordable", "READY") if bool(plan.get("affordable", false)) else _t("factory.operations.deficit", "MISSING")))
		selector.set_item_metadata(selector.item_count - 1, definition_id)
		if definition_id == _selected_plan_id:
			selected_index = selector.item_count - 1
	if selector.item_count > 0:
		selector.select(selected_index)
		selector.item_selected.connect(func(index: int) -> void:
			_select_plan(str(selector.get_item_metadata(index)))
		)
	body.add_child(selector)
	var planner_region := Control.new()
	planner_region.name = "FactoryOperationsPlannerDetailsRegion"
	planner_region.custom_minimum_size.y = UiTokens.layout_px(156)
	planner_region.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(planner_region)
	var planner_scroll := ScrollContainer.new()
	planner_scroll.name = "FactoryOperationsPlannerDetailsScroll"
	planner_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	planner_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	planner_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	planner_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	planner_region.add_child(planner_scroll)
	var planner_details := VBoxContainer.new()
	planner_details.name = "FactoryOperationsPlannerDetails"
	planner_details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	planner_details.add_theme_constant_override("separation", UiTokens.layout_px(4))
	planner_scroll.add_child(planner_details)
	if plans.is_empty():
		planner_details.add_child(_label(_t("factory.operations.no_plans", "No unlocked building plan is available in this snapshot."), 12, MUTED))
	else:
		var plan := _plan_by_id(_selected_plan_id)
		planner_details.add_child(_plan_detail(plan))
	planner_details.add_child(_materials_ledger())
	return panel


func _plan_detail(plan: Dictionary) -> Control:
	var detail := HBoxContainer.new()
	detail.name = "FactoryOperationsPlanDetail"
	detail.add_theme_constant_override("separation", UiTokens.layout_px(8))
	var plan_id := str(plan.get("definition_id", ""))
	var art_panel := PanelContainer.new()
	art_panel.name = "FactoryOperationsPlanArtwork"
	art_panel.custom_minimum_size = UiTokens.layout_vector(Vector2(92, 76))
	art_panel.add_theme_stylebox_override("panel", UiTokens.panel_style(RAISED, Color(CYAN, 0.46), 3))
	var artwork := TextureRect.new()
	artwork.name = "FactoryOperationsPlanArtworkTexture"
	artwork.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), plan_id, "MACHINE")
	artwork.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	artwork.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	artwork.modulate = Color(0.82, 0.94, 1.0, 0.92)
	art_panel.add_child(artwork)
	detail.add_child(art_panel)
	var plan_body := VBoxContainer.new()
	plan_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plan_body.add_theme_constant_override("separation", UiTokens.layout_px(3))
	detail.add_child(plan_body)
	var top := HBoxContainer.new()
	plan_body.add_child(top)
	var plan_title := _label(_building_name(plan_id), 13, OFFWHITE)
	plan_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(plan_title)
	var focus := Button.new()
	focus.name = "FactoryOperationsBuild%s" % plan_id.to_pascal_case()
	focus.text = _t("factory.operations.open_build", "Open build") + "  →"
	focus.tooltip_text = _t("factory.operations.open_build_tooltip", "Open this target in the physical Factory construction palette.")
	focus.add_theme_font_size_override("font_size", UiTokens.font_size(11))
	focus.add_theme_stylebox_override("normal", UiTokens.control_style(Color("173740"), CYAN, 3))
	focus.add_theme_stylebox_override("hover", UiTokens.control_style(Color("20515b"), CYAN, 3))
	focus.add_theme_color_override("font_color", OFFWHITE)
	focus.pressed.connect(_emit_action.bind({"kind":"SELECT_BUILDING", "target_id":plan_id}))
	top.add_child(focus)
	var table_header := HBoxContainer.new()
	table_header.name = "FactoryOperationsPlanMaterialHeader"
	table_header.add_child(_table_label(_t("factory.operations.material", "Material"), 0.46, MUTED))
	table_header.add_child(_table_label(_t("factory.operations.available", "Available"), 0.18, MUTED))
	table_header.add_child(_table_label(_t("factory.operations.required", "Required"), 0.18, MUTED))
	table_header.add_child(_table_label(_t("factory.operations.missing", "Missing"), 0.18, MUTED))
	plan_body.add_child(table_header)
	for material_value in plan.get("materials", []):
		if not material_value is Dictionary:
			continue
		var material := material_value as Dictionary
		var missing := int(material.get("missing", 0))
		var tone := CYAN if missing <= 0 else AMBER
		var row := HBoxContainer.new()
		row.name = "FactoryOperationsPlanMaterial%s" % str(material.get("item_id", "")).to_pascal_case()
		row.add_child(_table_label(_item_name(str(material.get("item_id", ""))), 0.46, OFFWHITE))
		row.add_child(_table_label(str(int(material.get("available", 0))), 0.18, OFFWHITE))
		row.add_child(_table_label(str(int(material.get("required", 0))), 0.18, OFFWHITE))
		row.add_child(_table_label(str(missing), 0.18, tone))
		plan_body.add_child(row)
	var dependencies: Array = plan.get("dependencies", []) as Array
	if not dependencies.is_empty():
		var dependency_routes := HFlowContainer.new()
		dependency_routes.name = "FactoryOperationsDependencyRoutes"
		dependency_routes.add_theme_constant_override("separation", UiTokens.layout_px(4))
		dependency_routes.add_child(_label(_t("factory.operations.dependencies", "Dependencies: %s") % "", 10, MUTED))
		for dependency_value in dependencies:
			var dependency := dependency_value as Dictionary
			var building_id := str(dependency.get("building_id", ""))
			var dependency_name := _item_name(str(dependency.get("item_id", "")))
			if not building_id.is_empty():
				dependency_name += " → " + _building_name(building_id)
			var action: Dictionary = dependency.get("action", {}) as Dictionary if dependency.get("action", {}) is Dictionary else {}
			if action.is_empty():
				dependency_routes.add_child(_label(dependency_name, 10, MUTED))
			else:
				var route := Button.new()
				route.name = "FactoryOperationsDependency%s" % str(dependency.get("item_id", "")).to_pascal_case()
				route.text = dependency_name
				route.tooltip_text = _t("factory.operations.dependency_action", "Open this physical dependency.")
				route.add_theme_font_size_override("font_size", UiTokens.font_size(10))
				route.add_theme_stylebox_override("normal", UiTokens.control_style(Color("172a34"), Color(CYAN, 0.55), 2))
				route.add_theme_stylebox_override("hover", UiTokens.control_style(Color("1c3c46"), CYAN, 2))
				route.pressed.connect(_emit_action.bind(action))
				dependency_routes.add_child(route)
		plan_body.add_child(dependency_routes)
	return detail


func _materials_ledger() -> Control:
	var ledger := VBoxContainer.new()
	ledger.name = "FactoryOperationsMaterials"
	ledger.add_theme_constant_override("separation", UiTokens.layout_px(2))
	ledger.add_child(HSeparator.new())
	var warehouse_heading := HBoxContainer.new()
	warehouse_heading.name = "FactoryOperationsWarehouseLedger"
	warehouse_heading.add_theme_constant_override("separation", UiTokens.layout_px(5))
	var warehouse_thumbnail := TextureRect.new()
	warehouse_thumbnail.name = "FactoryOperationsWarehouseThumbnail"
	warehouse_thumbnail.custom_minimum_size = UiTokens.layout_vector(Vector2(28, 28))
	# The ledger describes the one Location-owned planetary inventory. It is not
	# an implied preplaced bulk depot or a second Factory-side store.
	warehouse_thumbnail.texture = BuildingArt.icon_texture(BuildingArt.atlas_texture(), "grid_planetary_core", "STORAGE")
	warehouse_thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	warehouse_thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	warehouse_thumbnail.modulate = Color(0.74, 0.90, 0.98, 0.86)
	warehouse_heading.add_child(warehouse_thumbnail)
	var warehouse_title := _label(_t("factory.operations.planetary_inventory", "Planetary inventory"), 11, MUTED)
	warehouse_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	warehouse_heading.add_child(warehouse_title)
	ledger.add_child(warehouse_heading)
	var materials: Array = _operations.get("materials", []) as Array
	if materials.is_empty():
		ledger.add_child(_label(_t("factory.operations.no_materials", "No stored material telemetry is available."), 10, MUTED))
		return ledger
	for material_value in materials.slice(0, 3):
		if not material_value is Dictionary:
			continue
		var material := material_value as Dictionary
		var missing := int(material.get("missing", 0))
		var rate := float(material.get("production_per_second", 0.0)) - float(material.get("consumption_per_second", 0.0))
		var rate_text := "  %+0.2f/s" % rate if not is_zero_approx(rate) else ""
		var tone := AMBER if missing > 0 else OFFWHITE
		ledger.add_child(_label("%s  %d%s" % [_item_name(str(material.get("item_id", ""))), int(material.get("available", material.get("stored", 0))), rate_text], 10, tone))
	return ledger


func _select_plan(definition_id: String) -> void:
	_selected_plan_id = definition_id
	_rebuild()


func _emit_action(action: Dictionary) -> void:
	if not action.is_empty():
		action_requested.emit(action.duplicate(true))


func _plan_by_id(definition_id: String) -> Dictionary:
	for plan_value in _operations.get("build_plans", []):
		var plan := plan_value as Dictionary
		if str(plan.get("definition_id", "")) == definition_id:
			return plan
	return {}


func _telemetry_text() -> String:
	var world_id := str(_snapshot.get("location_name", _snapshot.get("world_id", "")))
	var report_count := (_operations.get("alerts", []) as Array).size()
	return "%s  ·  %s" % [world_id, _t("factory.operations.report_count", "%d exception reports") % report_count]


func _stage_label(stage_id: String) -> String:
	return _t("factory.operations.stage.%s" % stage_id.to_lower(), stage_id.capitalize())


func _state_label(state: String) -> String:
	return _t("factory.operations.state.%s" % state.to_lower(), state.capitalize())


func _state_tone(state: String) -> Color:
	match state.to_upper():
		"ACTIVE", "READY": return CYAN
		"BLOCKED": return CRITICAL
		_: return AMBER


func _stage_art_definition(stage_id: String) -> String:
	match stage_id:
		"COLLECTION": return "grid_surface_mine"
		"PRODUCTION": return "grid_arc_smelter"
		"CONSTRUCTION": return "grid_construction_yard"
		"EXPANSION": return "grid_engineering_works"
	return "grid_engineering_works"


func _alert_detail(alert: Dictionary) -> String:
	var entity_id := str(alert.get("entity_id", ""))
	var order_id := str(alert.get("order_id", ""))
	if not entity_id.is_empty():
		var entity: Dictionary = _entity_by_id(entity_id)
		return _t("factory.operations.alert_entity", "Factory unit: %s") % str(entity.get("name", entity_id))
	if not order_id.is_empty():
		return _t("factory.operations.alert_order", "Construction order: %s") % order_id
	var item_id := str(alert.get("item_id", ""))
	if not item_id.is_empty():
		return _t("factory.operations.alert_material", "%s short by %d") % [_item_name(item_id), int(alert.get("amount", 0))]
	return _t("factory.operations.alert_route", "Open the affected physical operation.")


func _entity_by_id(entity_id: String) -> Dictionary:
	for entity_value in _snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity
	return {}


func _table_label(value: String, stretch_ratio: float, color: Color) -> Label:
	var label := _label(value, 10, color)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_stretch_ratio = stretch_ratio
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return label


func _status_label(status: String) -> String:
	match status.to_upper():
		"MATERIAL_SHORTAGE", "MISSING_MATERIALS": return _t("factory.operations.status.material_shortage", "Material shortage")
	var i18n := get_node_or_null("/root/I18n")
	return str(i18n.call("status", status)) if i18n != null else status.replace("_", " ").capitalize()


func _item_name(item_id: String) -> String:
	var names: Dictionary = _snapshot.get("item_names", {}) as Dictionary if _snapshot.get("item_names", {}) is Dictionary else {}
	return str(names.get(item_id, item_id.replace("_", " ").capitalize()))


func _building_name(definition_id: String) -> String:
	var palette: Dictionary = _snapshot.get("palette", {}) as Dictionary if _snapshot.get("palette", {}) is Dictionary else {}
	for building_value in palette.get("buildings", []):
		var building := building_value as Dictionary
		if str(building.get("id", "")) == definition_id:
			return str(building.get("name", definition_id))
	return definition_id.replace("_", " ").capitalize()


func _label(value: String, size_px: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", UiTokens.font_size(size_px))
	label.add_theme_color_override("font_color", color)
	return label


func _t(key: String, fallback: String) -> String:
	var i18n := get_node_or_null("/root/I18n")
	return str(i18n.call("t", key, fallback)) if i18n != null else fallback
