extends Control

const SystemMapViewScript = preload("res://src/ui/components/system_map_view.gd")

const COLOR_BG := Color("15191f")
const COLOR_PANEL := Color("20262e")
const COLOR_PANEL_ALT := Color("29323d")
const COLOR_BORDER := Color("465362")
const COLOR_TEXT := Color("e8edf2")
const COLOR_MUTED := Color("9aa8b6")
const COLOR_ACCENT := Color("66c6ff")
const COLOR_GOOD := Color("71d79b")
const COLOR_WARN := Color("f1bd62")
const COLOR_BAD := Color("ee7b78")

var _tabs: TabContainer
var _pages: Dictionary = {}
var _page_controls: Dictionary = {}
var _header_status: Label
var _notice_label: Label
var _event_log: Array[String] = []
var _dirty := true
var _last_refresh_ms := 0
var _last_header_ms := 0
var _speed_buttons: Dictionary = {}
var _nav_buttons: Dictionary = {}
var _selected_location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
var _location_section := "overview"
var _industry_section := "production"
var _fleet_section := "roster"
var _logistics_item_selection := {}


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if String(argument).begins_with("--fleet-section="):
			_fleet_section = String(argument).trim_prefix("--fleet-section=")
		elif String(argument).begins_with("--industry-section="):
			_industry_section = String(argument).trim_prefix("--industry-section=")
	_build_theme()
	_build_shell()
	_connect_game_signals()
	if I18n.current_locale != "zh_CN":
		I18n.set_locale("zh_CN")
	_append_log("核心玩法实验室已启动。所有画面均由 Godot 控件生成，不使用 UI 图片。")
	_rebuild_all()
	var capture_requested := OS.get_cmdline_user_args().has("--capture-map") or OS.get_cmdline_user_args().has("--capture-location")
	for argument in OS.get_cmdline_user_args():
		capture_requested = capture_requested or String(argument).begins_with("--capture-view=")
	if capture_requested:
		call_deferred("_capture_requested_view")


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_header_ms >= 200:
		_update_header()
		_last_header_ms = now
	if (_dirty and now - _last_refresh_ms >= 180) or now - _last_refresh_ms >= 1000:
		_rebuild_all()


func _build_theme() -> void:
	var system_font := SystemFont.new()
	system_font.font_names = PackedStringArray([
		"PingFang SC", "Noto Sans CJK SC", "Microsoft YaHei", "Arial Unicode MS"
	])
	var lab_theme := Theme.new()
	lab_theme.default_font = system_font
	lab_theme.default_font_size = 15
	theme = lab_theme


func _build_shell() -> void:
	var background := ColorRect.new()
	background.color = COLOR_BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var root_margin := MarginContainer.new()
	root_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_margin.add_theme_constant_override("margin_left", 18)
	root_margin.add_theme_constant_override("margin_top", 14)
	root_margin.add_theme_constant_override("margin_right", 18)
	root_margin.add_theme_constant_override("margin_bottom", 14)
	add_child(root_margin)

	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 10)
	root_margin.add_child(root_box)

	root_box.add_child(_build_header())

	var workspace := HBoxContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 10)
	root_box.add_child(workspace)
	workspace.add_child(_build_navigation_rail())

	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tabs_visible = false
	workspace.add_child(_tabs)

	_add_page("星系地图", "system_map")
	_add_page("地点", "location")
	_add_page("流程总览", "overview")
	_add_page("前线作业", "frontier")
	_add_page("工业建设", "industry")
	_add_page("文明工程", "megastructure")
	_add_page("科研", "research")
	_add_page("舰队", "fleet")
	_add_page("远征", "expedition")
	_tabs.current_tab = 0

	var sidebar := _panel()
	sidebar.custom_minimum_size = Vector2(285, 0)
	workspace.add_child(sidebar)
	var sidebar_margin := _margin(14, 14, 14, 14)
	sidebar.add_child(sidebar_margin)
	var sidebar_scroll := ScrollContainer.new()
	sidebar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidebar_margin.add_child(sidebar_scroll)
	var sidebar_box := VBoxContainer.new()
	sidebar_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar_box.add_theme_constant_override("separation", 10)
	sidebar_scroll.add_child(sidebar_box)
	_pages["sidebar"] = sidebar_box

	_notice_label = Label.new()
	_notice_label.custom_minimum_size.y = 28
	_notice_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_notice_label.add_theme_color_override("font_color", COLOR_MUTED)
	_notice_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root_box.add_child(_notice_label)


func _build_navigation_rail() -> Control:
	var panel := _panel(Color("101820"))
	panel.custom_minimum_size.x = 210
	var margin := _margin(10, 12, 10, 12)
	panel.add_child(margin)
	var rail := VBoxContainer.new()
	rail.add_theme_constant_override("separation", 5)
	margin.add_child(rail)
	rail.add_child(_label("运营控制", 12, COLOR_MUTED))
	var entries := [
		["overview", "运营总览"],
		["system_map", "星系地图"],
		["location", "地点管理"],
		["frontier", "资源开采"],
		["industry", "工业与建设"],
		["megastructure", "文明工程"],
		["research", "科研技术"],
		["fleet", "星港与舰队"],
		["expedition", "远征与战斗"]
	]
	for entry in entries:
		var key := String(entry[0])
		var button := _button(String(entry[1]), _switch_page.bind(key))
		button.name = "Navigation_%s" % key
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size = Vector2(188, 42)
		_nav_buttons[key] = button
		rail.add_child(button)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rail.add_child(spacer)
	var scope := _label("可玩核心闭环\n真实状态 · 存档 · 离线结算", 10, COLOR_MUTED)
	scope.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rail.add_child(scope)
	return panel


func _switch_page(key: String) -> void:
	var page: Control = _page_controls.get(key)
	if not is_instance_valid(page):
		return
	_tabs.current_tab = page.get_index()
	_update_navigation_state()


func _update_navigation_state() -> void:
	if not is_instance_valid(_tabs):
		return
	for key_value in _nav_buttons.keys():
		var key := String(key_value)
		var button := _nav_buttons[key] as Button
		var page: Control = _page_controls.get(key)
		var active := is_instance_valid(page) and page.get_index() == _tabs.current_tab
		button.add_theme_color_override("font_color", COLOR_ACCENT if active else COLOR_TEXT)
		button.add_theme_stylebox_override("normal", _button_style(Color("18303a") if active else Color("141c24"), COLOR_ACCENT if active else COLOR_BORDER))


func _build_header() -> Control:
	var panel := _panel(COLOR_PANEL_ALT)
	panel.custom_minimum_size.y = 76
	var margin := _margin(16, 10, 12, 10)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title_box)
	var title := _label("赫利俄斯 · 核心玩法实验室", 22, COLOR_TEXT)
	title_box.add_child(title)
	var subtitle := _label("独立项目 / 无图片依赖 / 直接验证玩法闭环", 13, COLOR_MUTED)
	title_box.add_child(subtitle)

	_header_status = _label("", 14, COLOR_MUTED)
	_header_status.custom_minimum_size.x = 260
	_header_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_header_status)

	for speed in [0.0, 1.0, 10.0, 50.0]:
		var text_value := "暂停" if speed == 0.0 else "%d×" % int(speed)
		var speed_button := _button(text_value, _set_speed.bind(speed))
		speed_button.custom_minimum_size.x = 56
		_speed_buttons[speed] = speed_button
		row.add_child(speed_button)

	row.add_child(_button("保存", _save_game))
	row.add_child(_button("重开", _reset_game, false, COLOR_BAD))
	return panel


func _add_page(title: String, key: String) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = key
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, title)
	var margin := _margin(14, 14, 14, 20)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)
	_pages[key] = content
	_page_controls[key] = scroll


func _connect_game_signals() -> void:
	Game.state_changed.connect(_on_state_changed)
	Game.domain_event.connect(_on_domain_event)
	Game.command_rejected.connect(_on_command_rejected)
	I18n.locale_changed.connect(_on_locale_changed)


func _rebuild_all() -> void:
	if not is_instance_valid(Game.state) or not is_instance_valid(Game.content):
		return
	_rebuild_sidebar()
	_rebuild_system_map()
	_rebuild_location()
	_rebuild_overview()
	_rebuild_frontier()
	_rebuild_industry()
	_rebuild_megastructure()
	_rebuild_research()
	_rebuild_fleet()
	_rebuild_expedition()
	_update_header()
	_update_navigation_state()
	_dirty = false
	_last_refresh_ms = Time.get_ticks_msec()


func _rebuild_sidebar() -> void:
	var box: VBoxContainer = _pages["sidebar"]
	_clear(box)
	box.add_child(_section_title("当前引导"))
	var next_step := _next_flow_step()
	var guide := _rich(next_step, COLOR_ACCENT)
	guide.fit_content = true
	box.add_child(guide)
	var next_page := _next_flow_page()
	if not next_page.is_empty():
		var next_button := _button("前往下一步 →", _open_next_flow_target, false, COLOR_GOOD)
		next_button.name = "NextStepCTA"
		box.add_child(next_button)
	box.add_child(_separator())

	box.add_child(_section_title("全局库存（只读汇总）"))
	var inventory_lines: Array[String] = []
	var aggregate_inventory := Game.state.aggregate_inventory()
	for item_id in aggregate_inventory.keys():
		var amount := int(aggregate_inventory[item_id])
		if amount <= 0:
			continue
		var item := Game.content.items.get(String(item_id), {}) as Dictionary
		var owners: Array[String] = []
		for row_value in Game.state.inventory_breakdown(String(item_id)):
			var row := row_value as Dictionary
			owners.append("%s %d" % [_location_name(String(row.get("location_id", ""))), int(row.get("quantity", 0))])
		inventory_lines.append("%s  × %d\n  %s" % [_content_name(item, String(item_id)), amount, " / ".join(owners)])
	inventory_lines.sort()
	box.add_child(_rich("\n".join(inventory_lines) if not inventory_lines.is_empty() else "库存为空", COLOR_TEXT))

	box.add_child(_separator())
	box.add_child(_section_title("已建成设施"))
	var facility_lines: Array[String] = []
	for facility_id in Game.state.facilities:
		var facility := Game.content.facilities.get(String(facility_id), {}) as Dictionary
		facility_lines.append("• " + _content_name(facility, String(facility_id)))
	box.add_child(_rich("\n".join(facility_lines), COLOR_MUTED))

	box.add_child(_separator())
	box.add_child(_section_title("最近事件"))
	var recent := _event_log.slice(maxi(0, _event_log.size() - 7))
	box.add_child(_rich("\n".join(recent) if not recent.is_empty() else "暂无", COLOR_MUTED))


func _rebuild_system_map() -> void:
	var box: VBoxContainer = _pages["system_map"]
	_clear(box)
	box.add_child(_page_title("太阳系前沿", "轨道节点来自真实地点状态；虚线表示内容定义的物流走廊，未知地点不可操作。"))
	var map_locations: Array[Dictionary] = []
	for definition_value in Game.content.regions.values():
		var definition := definition_value as Dictionary
		var location_id := String(definition.get("id", ""))
		var location: Dictionary = Game.state.location_state(location_id)
		var discovered := not location.is_empty() and String(location.get("discovery_state", LocationState.UNDISCOVERED)) == LocationState.DISCOVERED
		map_locations.append({
			"id":location_id,
			"name":_location_name(location_id),
			"discovered":discovered,
			"survey_state":String(location.get("survey_state", LocationState.UNSURVEYED))
		})
	var map_routes: Array[Dictionary] = []
	for route_value in Game.content.logistics_routes.values():
		var route := (route_value as Dictionary).duplicate(true)
		var from_location: Dictionary = Game.state.location_state(String(route.get("from", "")))
		var to_location: Dictionary = Game.state.location_state(String(route.get("to", "")))
		route["active"] = String(from_location.get("discovery_state", "")) == LocationState.DISCOVERED and String(to_location.get("discovery_state", "")) == LocationState.DISCOVERED
		map_routes.append(route)
	var map_view := SystemMapViewScript.new()
	map_view.name = "SystemMap2D"
	map_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_view.location_selected.connect(_open_location)
	box.add_child(map_view)
	map_view.configure(map_locations, map_routes, _selected_location_id)

	box.add_child(_section_title("系统生产与物流"))
	for system_id in Game.simulation.known_system_ids(Game.state):
		var production: Dictionary = Game.simulation.system_production_overview(Game.state, system_id)
		var logistics: Dictionary = Game.simulation.system_logistics_overview(Game.state, system_id)
		var system_card := _card()
		system_card.add_child(_label("%s · 系统生产与物流总览" % system_id.to_upper(), 18, COLOR_ACCENT))
		system_card.add_child(_label("地点 %d · 库存 %d · 生产作业 %d 运行 / %d 受阻" % [int(production.get("location_count", 0)), int(production.get("stock_units", 0)), int(production.get("running_operations", 0)), int(production.get("blocked_operations", 0))], 13, COLOR_TEXT))
		var shipment_counts: Dictionary = logistics.get("shipment_counts", {})
		var shipment_units: Dictionary = logistics.get("shipment_units", {})
		system_card.add_child(_label("航线 %d 条内部 / %d 条外部 · 货运能力 %d · 物流策略 %d" % [int(logistics.get("internal_routes", 0)), int(logistics.get("external_routes", 0)), int(logistics.get("freight_capacity", 0)), int(logistics.get("policy_count", 0))], 13, COLOR_MUTED))
		system_card.add_child(_label("运输批次 %d 内部 / %d 入站 / %d 出站 · 数量 %d / %d / %d" % [int(shipment_counts.get("internal", 0)), int(shipment_counts.get("inbound", 0)), int(shipment_counts.get("outbound", 0)), int(shipment_units.get("internal", 0)), int(shipment_units.get("inbound", 0)), int(shipment_units.get("outbound", 0))], 13, COLOR_MUTED))
		var flow_lines: Array[String] = []
		for flow_value in production.get("flows", []):
			var flow := flow_value as Dictionary
			if int(flow.get("stock", 0)) <= 0 and int(flow.get("incoming", 0)) <= 0 and absf(float(flow.get("net_per_hour", 0.0))) < 0.001:
				continue
			flow_lines.append("%s  库存 %d + 在途 %d · 净变化 %+.1f/小时" % [_content_name(Game.content.items.get(String(flow.get("item_id", "")), {}), String(flow.get("item_id", ""))), int(flow.get("stock", 0)), int(flow.get("incoming", 0)), float(flow.get("net_per_hour", 0.0))])
		if not flow_lines.is_empty():
			system_card.add_child(_rich("\n".join(flow_lines.slice(0, 8)), COLOR_MUTED))
		box.add_child(_wrap_card(system_card))


func _open_location(location_id: String) -> void:
	if not Game.state.has_location(location_id):
		return
	_selected_location_id = location_id
	_location_section = "overview"
	_switch_page("location")
	_rebuild_location()


func _select_location_section(section: String) -> void:
	_location_section = section
	_rebuild_location()


func _rebuild_location() -> void:
	var box: VBoxContainer = _pages["location"]
	_clear(box)
	var location: Dictionary = Game.state.location_state(_selected_location_id)
	if location.is_empty():
		box.add_child(_page_title("地点", "请先从星系地图选择已知地点。"))
		return
	box.add_child(_page_title(_location_name(_selected_location_id), "%s · %s" % [_status_text(String(location.get("type", "UNKNOWN"))), String(location.get("system_id", "UNKNOWN")).to_upper()]))
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	for section in ["overview", "resources", "industry", "logistics", "projects"]:
		var captions := {"overview":"总览", "resources":"资源", "industry":"工业", "logistics":"物流", "projects":"工程"}
		var tab_button := _button(String(captions[section]), _select_location_section.bind(section), section == _location_section, COLOR_ACCENT)
		tab_button.name = "LocationTab_%s" % section
		nav.add_child(tab_button)
	box.add_child(nav)
	match _location_section:
		"resources":
			_build_location_resources(box, location)
		"industry":
			_build_location_industry(box, location)
		"logistics":
			_build_location_logistics(box, location)
		"projects":
			_build_location_projects(box, location)
		_:
			_build_location_overview(box, location)


func _build_location_overview(box: VBoxContainer, location: Dictionary) -> void:
	box.add_child(_section_title("地点信息"))
	box.add_child(_card_text("编号 %s\n类型 %s\n所属系统 %s\n发现状态 %s\n勘测状态 %s" % [_selected_location_id, _status_text(String(location.get("type", "UNKNOWN"))), String(location.get("system_id", "UNKNOWN")).to_upper(), _status_text(String(location.get("discovery_state", "UNKNOWN"))), _status_text(String(location.get("survey_state", "UNKNOWN")))], COLOR_TEXT))
	box.add_child(_section_title("本地库存"))
	var lines: Array[String] = []
	for item_value in Game.state.location_inventory(_selected_location_id).keys():
		var item_id := String(item_value)
		var quantity := Game.state.item_quantity(item_id, _selected_location_id)
		if quantity > 0:
			lines.append("%s × %d" % [_content_name(Game.content.items.get(item_id, {}), item_id), quantity])
	lines.sort()
	box.add_child(_card_text("\n".join(lines) if not lines.is_empty() else "库存为空", COLOR_TEXT))
	var power: Dictionary = location.get("power", {})
	var power_text := _status_text(String(power.get("status", "UNKNOWN")))
	if power.has("generation_capacity"):
		power_text = "发电 %.1f / 负载 %.1f / 可用 %.1f" % [float(power.get("generation_capacity", 0.0)), float(power.get("current_demand", 0.0)), float(power.get("available_capacity", 0.0))]
	box.add_child(_section_title("能源"))
	box.add_child(_card_text(power_text, COLOR_TEXT))
	var industry: Dictionary = location.get("industry_summary", {})
	box.add_child(_section_title("工业"))
	box.add_child(_card_text("%s · 已启用设施 %s · 运行作业 %s" % [_status_text(String(industry.get("status", "UNKNOWN"))), industry.get("active_facilities", 0), industry.get("active_operations", 0)], COLOR_TEXT))
	box.add_child(_section_title("物流 / 工程 / 舰队"))
	box.add_child(_card_text("物流状态 %s\n进行中工程 %d\n驻留舰队 %d" % [_status_text(String(location.get("logistics_summary", {}).get("status", "NOT_CONNECTED"))), int(location.get("projects_summary", {}).get("active_count", 0)), location.get("fleet_presence", []).size()], COLOR_TEXT))


func _build_location_resources(box: VBoxContainer, _location: Dictionary) -> void:
	box.add_child(_section_title("已知资源点"))
	var found := false
	for site_value in Game.content.mining_sites.values():
		var site := site_value as Dictionary
		var resource_region: Dictionary = Game.content.resource_regions.get(String(site.get("resource_region", "")), {})
		if String(resource_region.get("region", "")) != _selected_location_id:
			continue
		var runtime: Dictionary = Game.state.mining_site_states.get(String(site.get("id", "")), {})
		if not bool(runtime.get("discovered", false)):
			continue
		found = true
		var mining_location: Dictionary = Game.content.mining_locations.get(String(site.get("location", "")), {})
		var item_id := String(mining_location.get("raw_material", ""))
		box.add_child(_card_text("%s\n状态 %s · 资源 %s · 品位 %.2f · 开采潜力 %.1f" % [_content_name(site, String(site.get("id", ""))), _status_text(String(runtime.get("state", "UNKNOWN"))), _content_name(Game.content.items.get(item_id, {}), item_id), float(mining_location.get("density", 0.0)), float(mining_location.get("extraction_potential", 0.0))], COLOR_TEXT))
	if not found:
		box.add_child(_card_text("没有已知资源点", COLOR_MUTED))


func _build_location_industry(box: VBoxContainer, location: Dictionary) -> void:
	var summary: Dictionary = location.get("industry_summary", {})
	box.add_child(_card_text("状态 %s · 已启用设施 %s · 运行作业 %s" % [_status_text(String(summary.get("status", "NOT_AVAILABLE"))), summary.get("active_facilities", 0), summary.get("active_operations", 0)], COLOR_TEXT))
	var local_logistics: Dictionary = summary.get("local_logistics", {})
	box.add_child(_card_text("本地物流 · %s · 需求 %.2f / 容量 %.2f 单位/秒 · 利用率 %.0f%%" % [_status_text(String(local_logistics.get("status", "NOT_AVAILABLE"))), float(local_logistics.get("required", 0.0)), float(local_logistics.get("capacity", 0.0)), float(local_logistics.get("utilization", 0.0)) * 100.0], COLOR_WARN if str(local_logistics.get("status", "")) == "CONSTRAINED" else COLOR_MUTED))
	var constraints: Dictionary = summary.get("constraints", {})
	box.add_child(_card_text("能源 %.1f / %.1f · 冷却%s %.1f / %.1f · 结构 %.1f / %.1f · 吞吐率 %.0f%%" % [float(constraints.get("power_demand", 0.0)), float(constraints.get("power_capacity", 0.0)), "需求" if bool(constraints.get("cooling_required", false)) else "（无需）", float(constraints.get("cooling_demand", 0.0)), float(constraints.get("cooling_capacity", 0.0)), float(constraints.get("structural_used", 0.0)), float(constraints.get("structural_capacity", 0.0)), float(constraints.get("throughput_multiplier", 0.0)) * 100.0], COLOR_WARN if str(constraints.get("status", "")) == "CONSTRAINED" else COLOR_MUTED))
	box.add_child(_section_title("工业模板"))
	var automation: Dictionary = location.get("automation", {})
	var current_template_id := String(automation.get("industrial_template_id", ""))
	var current_template: Dictionary = Game.content.industrial_templates.get(current_template_id, {})
	var template_card := _card()
	template_card.add_child(_label("当前 · %s · %s" % [_content_name(current_template, "手动模式"), _status_text(String(automation.get("status", "MANUAL")))], 16, COLOR_ACCENT if not current_template_id.is_empty() else COLOR_MUTED))
	var template_ids: Array = Game.content.industrial_templates.keys()
	template_ids.sort()
	var template_selector := OptionButton.new()
	for index in template_ids.size():
		var template_id := String(template_ids[index])
		template_selector.add_item(_content_name(Game.content.industrial_templates.get(template_id, {}), template_id))
		if template_id == current_template_id:
			template_selector.select(index)
	template_card.add_child(_labeled_control("模板", template_selector))
	var template_actions := HBoxContainer.new()
	template_actions.add_theme_constant_override("separation", 6)
	template_actions.add_child(_button("应用模板", _apply_selected_industrial_template.bind(template_selector, template_ids), template_ids.is_empty()))
	template_actions.add_child(_button("恢复手动模式", _command.bind("清除工业模板", Game.clear_location_industrial_template.bind(_selected_location_id)), current_template_id.is_empty(), COLOR_WARN))
	template_card.add_child(template_actions)
	if not current_template_id.is_empty() and not current_template.get("managed_facilities", []).is_empty():
		template_card.add_child(_label("自动扩建 · %s · 目标等级 %d · %s" % ["已开启" if bool(automation.get("auto_expand_enabled", false)) else "已暂停", int(automation.get("target_industry_level", 5)), _status_text(String(automation.get("last_blocked_reason", "READY"))) if not String(automation.get("last_blocked_reason", "")).is_empty() else "就绪"], 13, COLOR_MUTED))
		var expansion_actions := HBoxContainer.new()
		expansion_actions.add_theme_constant_override("separation", 6)
		for target_level in [5, 10, 20]:
			expansion_actions.add_child(_button("自动扩至 %d 级" % target_level, _command.bind("配置自动扩建", Game.configure_location_industrial_automation.bind(_selected_location_id, true, target_level)), bool(automation.get("auto_expand_enabled", false)) and int(automation.get("target_industry_level", 5)) == target_level, COLOR_ACCENT))
		expansion_actions.add_child(_button("暂停扩建", _command.bind("暂停自动扩建", Game.configure_location_industrial_automation.bind(_selected_location_id, false, int(automation.get("target_industry_level", 5)))), not bool(automation.get("auto_expand_enabled", false)), COLOR_WARN))
		template_card.add_child(expansion_actions)
	box.add_child(_wrap_card(template_card))
	box.add_child(_section_title("本地工业"))
	for facility_value in SpaceGameState.MANUFACTURING_FACILITY_IDS:
		var facility_id := String(facility_value)
		if not Game.simulation.facility_available(Game.state, facility_id):
			continue
		var facility: Dictionary = Game.content.facilities.get(facility_id, {})
		var local_industry: Dictionary = Game.state.location_industry(_selected_location_id, facility_id)
		var runtime: Dictionary = Game.state.industrial_operation_for(_selected_location_id, facility_id)
		var level := int(local_industry.get("level", 0))
		var card := _card()
		card.add_child(_label("%s · 工业等级 %d" % [_content_name(facility, facility_id), level], 16, COLOR_TEXT))
		if level > 0:
			var current_activity_id := String(runtime.get("activity_id", local_industry.get("production_method_id", "")))
			var mastery := Game.simulation.industry_mastery_profile(Game.state, _selected_location_id, facility_id, current_activity_id)
			card.add_child(_label("工艺 %s · 产品熟练度 %d · 工业经验 %d · 规模加成 +%.0f%%" % [_content_name(Game.content.activities.get(current_activity_id, {}), "空闲"), int(mastery.get("mastery_level", 0)), int(mastery.get("expertise_level", 0)), minf(0.30, float(maxi(0, level - 1)) * 0.02) * 100.0], 13, COLOR_MUTED))
			for activity_value in Game.content.activities.values():
				var activity := activity_value as Dictionary
				var activity_id := String(activity.get("id", ""))
				if String(activity.get("domain", "")) != "industry" or Game.simulation.is_construction_activity(activity) or Game.content.is_module_bom_activity(activity) or String(activity.get("facility", "")) != facility_id or not Game.simulation.definition_revealed(Game.state, activity):
					continue
				if current_activity_id == activity_id and String(runtime.get("status", "")) in ["RUNNING", "BLOCKED"]:
					card.add_child(_button("停止 · %s" % _content_name(activity, activity_id), _command.bind("停止本地工业", Game.stop_industry_operation.bind(int(runtime.get("slot", -1)))), false, COLOR_WARN))
				else:
					var busy := String(runtime.get("status", "")) in ["RUNNING", "BLOCKED"]
					card.add_child(_button("采用工艺 · %s" % _content_name(activity, activity_id), _command.bind("设置生产工艺", Game.start_industry_operation.bind(int(runtime.get("slot", -1)), activity_id)), busy or not Game.simulation.activity_available(Game.state, activity)))
		var expansion_row := HBoxContainer.new()
		expansion_row.add_theme_constant_override("separation", 6)
		for amount in [1, 5, 10]:
			expansion_row.add_child(_button("扩建 +%d" % amount, _command.bind("扩建本地工业", Game.expand_location_industry.bind(_selected_location_id, facility_id, amount))))
		card.add_child(expansion_row)
		box.add_child(_wrap_card(card))


func _apply_selected_industrial_template(selector: OptionButton, template_ids: Array) -> void:
	if selector.selected < 0 or selector.selected >= template_ids.size():
		return
	_command("应用工业模板", Game.apply_location_industrial_template.bind(_selected_location_id, String(template_ids[selector.selected])))


func _build_location_logistics(box: VBoxContainer, location: Dictionary) -> void:
	var summary: Dictionary = location.get("logistics_summary", {})
	var logistics: Dictionary = location.get("logistics", {})
	var logistics_technology: Dictionary = summary.get("technology_profile", Game.simulation.logistics.technology_profile(Game.state))
	box.add_child(_card_text("%s · 航线 %d · 入站 %d · 出站 %d\n库存 %d / %d · 枢纽单次吞吐 %d\n运输技术 %s · 运量 ×%.2f · 耗时 ×%.2f · 燃料 ×%.2f · 能耗 %.2f/单位/航线 · 装卸 %.0f 毫秒/单位/端点" % [
		_status_text(String(summary.get("status", "NOT_CONNECTED"))),
		int(summary.get("route_count", 0)),
		int(summary.get("inbound_shipments", 0)),
		int(summary.get("outbound_shipments", 0)),
		Game.state.total_inventory_units(_selected_location_id),
		int(logistics.get("storage_capacity", 0)),
		int(logistics.get("hub_throughput", 0)),
		_status_text(String(logistics_technology.get("name", "CHEMICAL_CARGO"))),
		float(logistics_technology.get("freight_capacity_multiplier", 1.0)),
		float(logistics_technology.get("transit_time_multiplier", 1.0)),
		float(logistics_technology.get("fuel_cost_multiplier", 1.0)),
		float(logistics_technology.get("energy_per_route_unit", 0.0)),
		float(logistics_technology.get("loading_time_ms_per_unit", 40.0))
	], COLOR_TEXT))
	var limits_card := _card()
	limits_card.add_child(_label("地点物流容量", 16, COLOR_ACCENT))
	var storage_input := _number_input(int(logistics.get("storage_capacity", 0)), 1, 1000000, 10)
	var throughput_input := _number_input(int(logistics.get("hub_throughput", 0)), 1, 1000000, 1)
	limits_card.add_child(_labeled_control("库存容量", storage_input))
	limits_card.add_child(_labeled_control("枢纽单次吞吐", throughput_input))
	var save_limits := _button("应用容量限制", _save_logistics_limits.bind(storage_input, throughput_input))
	save_limits.name = "SaveLogisticsLimits"
	limits_card.add_child(save_limits)
	box.add_child(_wrap_card(limits_card))

	box.add_child(_section_title("供给 / 需求策略"))
	var policy_ids: Array = logistics.get("policies", {}).keys()
	policy_ids.sort()
	if policy_ids.is_empty():
		box.add_child(_card_text("当前没有物流策略。可新增供给、需求目标或被动仓储策略。", COLOR_MUTED))
	for item_value in policy_ids:
		var item_id := String(item_value)
		var policy: Dictionary = logistics.get("policies", {}).get(item_id, {})
		box.add_child(_wrap_card(_logistics_policy_editor(item_id, policy)))

	var add_card := _card()
	add_card.add_child(_label("新增策略", 16, COLOR_ACCENT))
	var item_ids: Array = Game.content.items.keys()
	item_ids.sort_custom(func(a, b): return _content_name(Game.content.items.get(String(a), {}), String(a)) < _content_name(Game.content.items.get(String(b), {}), String(b)))
	var item_selector := OptionButton.new()
	item_selector.name = "LogisticsItemSelector"
	var selected_item := String(_logistics_item_selection.get(_selected_location_id, item_ids[0] if not item_ids.is_empty() else ""))
	for index in item_ids.size():
		var item_id := String(item_ids[index])
		item_selector.add_item(_content_name(Game.content.items.get(item_id, {}), item_id))
		if item_id == selected_item:
			item_selector.select(index)
	item_selector.item_selected.connect(_on_logistics_item_selected.bind(item_ids))
	add_card.add_child(item_selector)
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 6)
	add_row.add_child(_button("设为供给", _add_selected_logistics_policy.bind(LogisticsEngine.MODE_SUPPLY, item_selector, item_ids), item_ids.is_empty()))
	add_row.add_child(_button("设为需求", _add_selected_logistics_policy.bind(LogisticsEngine.MODE_DEMAND, item_selector, item_ids), item_ids.is_empty()))
	add_row.add_child(_button("设为仓储", _add_selected_logistics_policy.bind(LogisticsEngine.MODE_STORAGE, item_selector, item_ids), item_ids.is_empty(), COLOR_MUTED))
	add_card.add_child(add_row)
	box.add_child(_wrap_card(add_card))

	box.add_child(_section_title("在途运输"))
	var shipment_found := false
	for shipment_value in Game.state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if String(shipment.get("origin", "")) != _selected_location_id and String(shipment.get("destination", "")) != _selected_location_id:
			continue
		shipment_found = true
		var cargo_lines: Array[String] = []
		for item_value in shipment.get("cargo", {}).keys():
			var item_id := String(item_value)
			cargo_lines.append("%s × %d" % [_content_name(Game.content.items.get(item_id, {}), item_id), int(shipment.get("cargo", {}).get(item_id, 0))])
		box.add_child(_card_text("%s · %s → %s · 剩余 %.1f 秒（装卸 %.1f 秒）· %s · 能耗 %.1f\n%s" % [shipment.get("id", "运输批次"), _location_name(String(shipment.get("origin", ""))), _location_name(String(shipment.get("destination", ""))), float(shipment.get("remaining_ms", 0.0)) / 1000.0, float(shipment.get("handling_time_ms", 0.0)) / 1000.0, _status_text(String(shipment.get("logistics_technology_id", "chemical_cargo"))), float(shipment.get("energy_units", 0.0)), "、".join(cargo_lines)], COLOR_ACCENT))
	if not shipment_found:
		box.add_child(_card_text("当前没有在途运输", COLOR_MUTED))


func _logistics_policy_editor(item_id: String, policy: Dictionary) -> VBoxContainer:
	var card := _card()
	card.add_child(_label("%s · 本地 %d · 在途 %d" % [
		_content_name(Game.content.items.get(item_id, {}), item_id),
		Game.state.item_quantity(item_id, _selected_location_id),
		Game.simulation.logistics.incoming_quantity(Game.state, _selected_location_id, item_id)
	], 16, COLOR_TEXT))
	var mode_selector := OptionButton.new()
	var modes := [LogisticsEngine.MODE_SUPPLY, LogisticsEngine.MODE_DEMAND, LogisticsEngine.MODE_STORAGE]
	for index in modes.size():
		mode_selector.add_item(_logistics_mode_text(String(modes[index])))
		if String(policy.get("mode", LogisticsEngine.MODE_STORAGE)) == String(modes[index]):
			mode_selector.select(index)
	card.add_child(_labeled_control("模式", mode_selector))
	var reserve_input := _number_input(int(policy.get("reserve", 0)), 0, 1000000, 1)
	var target_input := _number_input(int(policy.get("target", 0)), 0, 1000000, 1)
	var priority_input := _number_input(int(policy.get("priority", 50)), 0, 100, 5)
	var threshold_input := _number_input(int(policy.get("dispatch_threshold", 1)), 1, 1000000, 1)
	card.add_child(_labeled_control("本地保留量", reserve_input))
	card.add_child(_labeled_control("目标库存", target_input))
	card.add_child(_labeled_control("优先级", priority_input))
	card.add_child(_labeled_control("发运阈值", threshold_input))
	var source_ids: Array[String] = [""]
	var source_selector := OptionButton.new()
	source_selector.add_item("自动选择来源")
	for location_value in Game.state.locations.keys():
		var source_id := String(location_value)
		if source_id == _selected_location_id or String(Game.state.location_state(source_id).get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED:
			continue
		source_ids.append(source_id)
		source_selector.add_item(_location_name(source_id))
		if source_id == String(policy.get("source_lock", "")):
			source_selector.select(source_ids.size() - 1)
	card.add_child(_labeled_control("来源", source_selector))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	actions.add_child(_button("保存策略", _save_logistics_policy.bind(item_id, mode_selector, modes, reserve_input, target_input, priority_input, threshold_input, source_selector, source_ids)))
	actions.add_child(_button("清除", _command.bind("清除物流策略", Game.clear_location_logistics_policy.bind(_selected_location_id, item_id)), false, COLOR_WARN))
	card.add_child(actions)
	return card


func _on_logistics_item_selected(index: int, item_ids: Array) -> void:
	if index >= 0 and index < item_ids.size():
		_logistics_item_selection[_selected_location_id] = String(item_ids[index])


func _add_selected_logistics_policy(mode: String, selector: OptionButton, item_ids: Array) -> void:
	var index := selector.selected
	if index < 0 or index >= item_ids.size():
		return
	var item_id := String(item_ids[index])
	_logistics_item_selection[_selected_location_id] = item_id
	var current := Game.state.item_quantity(item_id, _selected_location_id)
	var target := maxi(50, current) if mode == LogisticsEngine.MODE_DEMAND else 0
	_command("新增物流策略", Game.set_location_logistics_policy.bind(_selected_location_id, item_id, mode, 0, target, 50, 1, ""))


func _save_logistics_policy(item_id: String, mode_selector: OptionButton, modes: Array, reserve_input: SpinBox, target_input: SpinBox, priority_input: SpinBox, threshold_input: SpinBox, source_selector: OptionButton, source_ids: Array[String]) -> void:
	var mode_index := clampi(mode_selector.selected, 0, modes.size() - 1)
	var source_index := clampi(source_selector.selected, 0, source_ids.size() - 1)
	_command("保存物流策略", Game.set_location_logistics_policy.bind(
		_selected_location_id,
		item_id,
		String(modes[mode_index]),
		int(reserve_input.value),
		int(target_input.value),
		int(priority_input.value),
		int(threshold_input.value),
		String(source_ids[source_index])
	))


func _save_logistics_limits(storage_input: SpinBox, throughput_input: SpinBox) -> void:
	_command("保存物流容量", Game.set_location_logistics_limits.bind(_selected_location_id, int(storage_input.value), int(throughput_input.value)))


func _build_location_projects(box: VBoxContainer, _location: Dictionary) -> void:
	var found := false
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != _selected_location_id or String(operation.get("activity_id", "")).is_empty():
			continue
		found = true
		var activity: Dictionary = Game.content.activities.get(String(operation.get("activity_id", "")), {})
		var project: Dictionary = Game.state.megastructure_projects.get(String(operation.get("megastructure_id", "")), {})
		var stage_line := "\n文明工程 %d%% · %s · 物资流 %s" % [int(project.get("progress_percent", 0)), _status_text(String(project.get("stage_name", "PLANNED"))), _status_text(String(project.get("material_flow_status", "RECEIVING")))] if not project.is_empty() else ""
		box.add_child(_card_text("建造 · %s · %s%s" % [_content_name(activity, String(operation.get("activity_id", ""))), _status_text(String(operation.get("status", "UNKNOWN"))), stage_line], COLOR_TEXT))
	for order_value in Game.state.shipyard_queue:
		var order := order_value as Dictionary
		if String(order.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != _selected_location_id:
			continue
		found = true
		box.add_child(_card_text("船坞 · %s · %s" % [order.get("plan_id", "未知计划"), _status_text(String(order.get("status", "UNKNOWN")))], COLOR_TEXT))
	if not found:
		box.add_child(_card_text("当前没有进行中的工程", COLOR_MUTED))


func _location_name(location_id: String) -> String:
	var definition: Dictionary = Game.content.regions.get(location_id, {"id":location_id, "name":location_id})
	return _content_name(definition, location_id)


func _capture_requested_view() -> void:
	var args := OS.get_cmdline_user_args()
	var file_name := "lab_system_map.png"
	var requested_view := ""
	for argument in args:
		if String(argument).begins_with("--capture-view="):
			requested_view = String(argument).trim_prefix("--capture-view=")
	if not requested_view.is_empty() and _page_controls.has(requested_view):
		_switch_page(requested_view)
		file_name = "lab_%s.png" % requested_view
	elif args.has("--capture-location"):
		_open_location(SpaceGameState.MAIN_BASE_LOCATION_ID)
		file_name = "lab_location_overview.png"
	else:
		var page: Control = _page_controls.get("system_map")
		if is_instance_valid(page):
			_tabs.current_tab = page.get_index()
	await get_tree().process_frame
	await get_tree().process_frame
	RenderingServer.force_draw(false)
	await get_tree().process_frame
	var directory := ProjectSettings.globalize_path("res://artifacts/ui")
	DirAccess.make_dir_recursive_absolute(directory)
	var output_path := "res://artifacts/ui/%s" % file_name
	var error := get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(output_path))
	print("CAPTURE_SAVED: %s" % output_path if error == OK else "CAPTURE_FAILED: %s" % error_string(error))
	get_tree().quit(0 if error == OK else 1)


func _rebuild_overview() -> void:
	var box: VBoxContainer = _pages["overview"]
	_clear(box)
	box.add_child(_page_title("玩法流程总览", "从近地采矿开始，逐步建立可持续的地球工业与远征能力。"))

	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 10)
	stats.add_child(_stat_card("文明等级", "%d 级" % Game.state.progression_tier, COLOR_ACCENT))
	stats.add_child(_stat_card("飞船", str(Game.state.ships.size()), COLOR_TEXT))
	stats.add_child(_stat_card("设施", str(Game.state.facilities.size()), COLOR_TEXT))
	stats.add_child(_stat_card("已完成科研", str(Game.state.completed_projects.size()), COLOR_GOOD))
	box.add_child(stats)

	box.add_child(_section_title("阶段目标"))
	for goal_value in Game.content.goals.values():
		var goal := goal_value as Dictionary
		if not Game.simulation.definition_revealed(Game.state, goal):
			continue
		var complete := _requirements_complete(goal.get("requirements", []))
		var goal_box := _card()
		var title_text := ("✓ " if complete else "○ ") + _content_name(goal, String(goal.get("id", "goal")))
		goal_box.add_child(_label(title_text, 17, COLOR_GOOD if complete else COLOR_TEXT))
		var description := I18n.content(goal, "description")
		if not description.is_empty():
			goal_box.add_child(_rich(description, COLOR_MUTED))
		for step_value in goal.get("steps", []):
			var step := step_value as Dictionary
			var step_done := _requirements_complete(step.get("requirements", []))
			var step_id := String(step.get("id", "step"))
			var step_name := I18n.goal_step(step_id, step_id.replace("_", " ").capitalize())
			goal_box.add_child(_label("   %s %s" % ["✓" if step_done else "·", step_name], 14, COLOR_GOOD if step_done else COLOR_MUTED))
		box.add_child(_wrap_card(goal_box))

	box.add_child(_section_title("运行状态"))
	var operation_lines := _active_operation_lines()
	box.add_child(_card_text("\n".join(operation_lines) if not operation_lines.is_empty() else "当前没有正在运行的作业。", COLOR_MUTED))

	var power := Game.simulation.civilization_power_state(Game.state)
	if not power.is_empty():
		box.add_child(_section_title("能源"))
		box.add_child(_card_text("发电 %.1f / 负载 %.1f / 可用 %.1f" % [float(power.get("generation_capacity", 0.0)), float(power.get("current_demand", 0.0)), float(power.get("available_capacity", 0.0))], COLOR_TEXT))


func _rebuild_frontier() -> void:
	var box: VBoxContainer = _pages["frontier"]
	_clear(box)
	box.add_child(_page_title("前线作业", "将装备采矿模块的飞船编入采矿舰队，建立稳定原料来源。"))

	box.add_child(_section_title("资源采集点"))
	var visible_site := false
	for site_value in Game.content.mining_sites.values():
		var site := site_value as Dictionary
		var site_id := String(site.get("id", ""))
		var site_state := Game.state.mining_site_states.get(site_id, {}) as Dictionary
		if site_state.is_empty() or not bool(site_state.get("discovered", false)):
			continue
		visible_site = true
		var card := _card()
		card.add_child(_label(_content_name(site, site_id), 17, COLOR_TEXT))
		var mining_location := Game.content.mining_locations.get(String(site.get("location", "")), {}) as Dictionary
		card.add_child(_label("状态：%s · 品位 %d · 开采潜力 %.1f · 资源 %s" % [_status_text(String(site_state.get("status", "PROSPECT"))), int(mining_location.get("material_grade", 1)), float(mining_location.get("extraction_potential", 0.0)), _content_name(Game.content.items.get(String(mining_location.get("raw_material", "")), {}), String(mining_location.get("raw_material", "")))], 14, COLOR_MUTED))
		var integrated_network_id := String(site_state.get("integrated_network_id", ""))
		if not integrated_network_id.is_empty():
			card.add_child(_label("✓ 已接入 %s · 后台稳定产出" % _content_name(Game.content.extraction_networks.get(integrated_network_id, {}), integrated_network_id), 13, COLOR_GOOD))
		var operation := _mining_operation_for_site(site_id)
		if not operation.is_empty() and String(operation.get("status", "")) == "RUNNING":
			var hazard_profile := Game.simulation.mining_hazard_profile(Game.state, operation)
			card.add_child(_label("已安装开采力 %.1f / 潜力 %.1f · 工艺效率 ×%.2f · 风险可用率 %.0f%%" % [float(operation.get("installed_extraction_power", 0.0)), float(operation.get("site_extraction_potential", mining_location.get("extraction_potential", 0.0))), float(operation.get("method_efficiency", 1.0)), float(hazard_profile.get("uptime", 1.0)) * 100.0], 13, COLOR_ACCENT))
			card.add_child(_operation_progress(operation, "采矿进行中"))
			card.add_child(_button("停止采矿", _command.bind("停止采矿", Game.stop_mining_operation.bind(int(operation.get("slot", 0)))), false, COLOR_WARN))
		elif integrated_network_id.is_empty():
			var site_activity := _activity_for_mining_site(site_id)
			var reason := _activity_block_reason("mining", String(site_activity.get("id", "")))
			var start_mining_button := _button("开始采矿", _command.bind("开始采矿", Game.start_extraction_operation.bind(site_id)), not reason.is_empty())
			start_mining_button.name = "StartMining_%s" % site_id
			card.add_child(start_mining_button)
			if not reason.is_empty():
				card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		if integrated_network_id.is_empty():
			for network_value in Game.content.extraction_networks.values():
				var network := network_value as Dictionary
				if not network.get("site_ids", []).has(site_id):
					continue
				var network_id := String(network.get("id", ""))
				var eligibility := Game.simulation.mining_site_network_eligibility(Game.state, site_id, network_id)
				var network_button := _button("接入自动采掘网络 · %s" % _content_name(network, network_id), _command.bind("接入自动采掘网络", Game.integrate_mining_site.bind(site_id, network_id)), not bool(eligibility.get("eligible", false)), COLOR_GOOD)
				network_button.name = "IntegrateMining_%s" % site_id
				card.add_child(network_button)
				if not bool(eligibility.get("eligible", false)):
					card.add_child(_label("自动化尚未就绪：网络 %s · 开采技术 %d/%d · 场地训练 %d/%d" % ["已建成" if bool(eligibility.get("network_unlocked", false)) else "未建成", int(eligibility.get("technology_current", 0)), int(eligibility.get("technology_required", 0)), int(eligibility.get("mastery_current", 0)), int(eligibility.get("mastery_required", 0))], 12, COLOR_MUTED))
		box.add_child(_wrap_card(card))
	if not visible_site:
		box.add_child(_card_text("没有已发现的采集点。", COLOR_MUTED))


func _rebuild_industry() -> void:
	var box: VBoxContainer = _pages["industry"]
	_clear(box)
	box.add_child(_page_title("工业与建设", "工业配方占用对应设施；大型设施进入独立的建造队列。"))
	var section_tabs := HFlowContainer.new()
	section_tabs.add_theme_constant_override("h_separation", 6)
	section_tabs.add_theme_constant_override("v_separation", 6)
	for entry in [["production", "生产配方"], ["facilities", "设施与工艺"], ["construction", "设施建设"], ["automation", "后台自动化"]]:
		var section_id := String(entry[0])
		var section_button := _button(String(entry[1]), _select_industry_section.bind(section_id), section_id == _industry_section, COLOR_ACCENT)
		section_button.name = "IndustrySection_%s" % section_id
		section_tabs.add_child(section_button)
	box.add_child(section_tabs)
	match _industry_section:
		"facilities":
			_build_facility_management(box)
		"construction":
			_build_industry_construction(box)
		"automation":
			_build_background_economy_controls(box)
		_:
			_build_industry_production(box)


func _select_industry_section(section: String) -> void:
	_industry_section = section
	_rebuild_industry()


func _build_industry_production(box: VBoxContainer) -> void:
	box.add_child(_section_title("生产配方"))
	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		if String(activity.get("domain", "")) != "industry":
			continue
		if Game.simulation.is_construction_activity(activity):
			continue
		if Game.content.is_module_bom_activity(activity):
			continue
		if not Game.simulation.definition_revealed(Game.state, activity):
			continue
		var activity_id := String(activity.get("id", ""))
		var facility_id := String(activity.get("facility", ""))
		var runtime := _industrial_runtime_for_facility(facility_id)
		var card := _card()
		card.add_child(_label(_content_name(activity, activity_id), 16, COLOR_TEXT))
		card.add_child(_label(_activity_summary(activity), 13, COLOR_MUTED))
		if not runtime.is_empty() and String(runtime.get("activity_id", "")) == activity_id:
			card.add_child(_operation_progress(runtime, "生产中"))
			card.add_child(_button("停止", _command.bind("停止生产", Game.stop_industry_operation.bind(int(runtime.get("slot", 0)))), false, COLOR_WARN))
		else:
			var busy := not runtime.is_empty() and not String(runtime.get("activity_id", "")).is_empty()
			var reason := _activity_block_reason("industry", activity_id)
			var disabled := busy or not reason.is_empty()
			var start_industry_button := _button("开始生产", _command.bind("开始生产", Game.start_industry_operation.bind(int(runtime.get("slot", 0)), activity_id)), disabled)
			start_industry_button.name = "StartIndustry_%s" % activity_id
			card.add_child(start_industry_button)
			if busy:
				card.add_child(_label("设施正在执行其他配方。", 13, COLOR_WARN))
			elif not reason.is_empty():
				card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))


func _build_industry_construction(box: VBoxContainer) -> void:
	box.add_child(_section_title("设施建设"))
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")).is_empty():
			continue
		var definition := Game.content.activities.get(String(operation.get("activity_id", "")), {}) as Dictionary
		var active_card := _card()
		active_card.add_child(_label(_content_name(definition, "建造项目"), 16, COLOR_TEXT))
		active_card.add_child(_operation_progress(operation, "状态：" + _status_text(String(operation.get("status", "QUEUED")))))
		var megastructure_project: Dictionary = Game.state.megastructure_projects.get(String(operation.get("megastructure_id", "")), {})
		if not megastructure_project.is_empty():
			active_card.add_child(_label("阶段 %d%% · %s · 物资流 %s" % [int(megastructure_project.get("progress_percent", 0)), _status_text(String(megastructure_project.get("stage_name", "PLANNED"))), _status_text(String(megastructure_project.get("material_flow_status", "RECEIVING")))], 14, COLOR_ACCENT))
		active_card.add_child(_button("取消项目", _command.bind("取消建造", Game.stop_construction_project.bind(int(operation.get("slot", 0)))), false, COLOR_WARN))
		box.add_child(_wrap_card(active_card))

	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		if String(activity.get("domain", "")) != "industry" or not Game.simulation.is_construction_activity(activity):
			continue
		if not Game.simulation.definition_revealed(Game.state, activity):
			continue
		var activity_id := String(activity.get("id", ""))
		var card := _card()
		card.add_child(_label(_content_name(activity, activity_id), 16, COLOR_TEXT))
		card.add_child(_label(_activity_summary(activity), 13, COLOR_MUTED))
		var reason := _construction_block_reason(activity_id)
		var start_construction_button := _button("开始建造", _command.bind("开始建造", Game.start_construction_project.bind(activity_id)), not reason.is_empty())
		start_construction_button.name = "StartConstruction_%s" % activity_id
		card.add_child(start_construction_button)
		if not reason.is_empty():
			card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))


func _build_facility_management(box: VBoxContainer) -> void:
	box.add_child(_section_title("设施配置与工艺能力"))
	box.add_child(_card_text("设施模块直接消耗真实库存。制造设施运行时必须先停止生产，才能更换工艺模块或通用插件。", COLOR_MUTED))
	var facility_ids: Array = Game.state.facilities.keys()
	facility_ids.sort()
	for facility_id_value in facility_ids:
		var facility_id := String(facility_id_value)
		var definition := Game.content.facilities.get(facility_id, {}) as Dictionary
		if definition.is_empty():
			continue
		var runtime: Dictionary = Game.simulation.industry_runtime_for_facility(Game.state, facility_id)
		var runtime_busy := not runtime.is_empty() and String(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED"]
		var state_entry: Dictionary = Game.state.facilities.get(facility_id, {})
		var card := _card()
		card.add_child(_label("%s · %d 级" % [_content_name(definition, facility_id), int(state_entry.get("level", 1))], 17, COLOR_TEXT))
		if not runtime.is_empty():
			card.add_child(_label("生产状态：%s%s" % [_status_text(String(runtime.get("status", "IDLE"))), " · 需先停止生产才能改造" if runtime_busy else ""], 13, COLOR_WARN if runtime_busy else COLOR_MUTED))

		var advanced_demand := float(definition.get("advanced_power_demand", 0.0)) + float(definition.get("advanced_power_demand_per_level", 0.0)) * float(maxi(0, int(state_entry.get("level", 1)) - 1))
		if advanced_demand > 0.0 or definition.has("advanced_power_priority"):
			card.add_child(_label("高级能源优先级", 14, COLOR_ACCENT))
			var current_priority := String(Game.state.energy_system.get("advanced_priorities", {}).get(facility_id, definition.get("advanced_power_priority", "NORMAL")))
			var priority_row := HFlowContainer.new()
			priority_row.add_theme_constant_override("h_separation", 6)
			for priority in ["CRITICAL", "HIGH", "NORMAL", "LOW"]:
				priority_row.add_child(_button(_status_text(priority), _command.bind("设置能源优先级", Game.set_advanced_power_priority.bind(facility_id, priority)), current_priority == priority))
			card.add_child(priority_row)

		var installed_upgrades: Array = state_entry.get("installed_modules", [])
		if not definition.get("upgrade_modules", {}).is_empty():
			card.add_child(_label("基础设施模块 %d / %d" % [installed_upgrades.size(), int(definition.get("module_slots", 0))], 14, COLOR_ACCENT))
			for module_id_value in definition.get("upgrade_modules", {}).keys():
				var module_id := String(module_id_value)
				var module := definition.get("upgrade_modules", {}).get(module_id, {}) as Dictionary
				if installed_upgrades.has(module_id):
					card.add_child(_label("✓ %s" % _content_name(module, module_id), 13, COLOR_GOOD))
				else:
					var available := Game.simulation.facility_module_available(Game.state, facility_id, module_id)
					card.add_child(_button("安装 · %s · %s" % [_content_name(module, module_id), _resource_list(module.get("costs", []))], _command.bind("安装设施模块", Game.install_facility_module.bind(facility_id, module_id)), not available))

		if int(definition.get("manufacturing_generation", 0)) > 0:
			_add_manufacturing_module_controls(card, facility_id, definition, state_entry, "process", runtime_busy)
			_add_manufacturing_module_controls(card, facility_id, definition, state_entry, "plugin", runtime_busy)
		box.add_child(_wrap_card(card))


func _add_manufacturing_module_controls(card: VBoxContainer, facility_id: String, facility: Dictionary, state_entry: Dictionary, module_kind: String, runtime_busy: bool) -> void:
	var field := "installed_process_modules" if module_kind == "process" else "installed_plugins"
	var slot_field := "process_module_slots" if module_kind == "process" else "plugin_slots"
	var definitions: Dictionary = Game.content.process_modules if module_kind == "process" else Game.content.universal_industry_plugins
	var installed: Array = state_entry.get(field, [])
	card.add_child(_label("%s %d / %d" % ["工艺模块" if module_kind == "process" else "通用插件", installed.size(), int(facility.get(slot_field, 0))], 14, COLOR_ACCENT))
	for installed_id_value in installed:
		var installed_id := String(installed_id_value)
		var installed_definition := definitions.get(installed_id, {}) as Dictionary
		var installed_row := HFlowContainer.new()
		installed_row.add_theme_constant_override("h_separation", 6)
		installed_row.add_child(_label("✓ %s" % _content_name(installed_definition, installed_id), 13, COLOR_GOOD))
		installed_row.add_child(_button("卸下", _command.bind("卸下制造模块", Game.uninstall_manufacturing_module.bind(facility_id, installed_id, module_kind)), runtime_busy, COLOR_WARN))
		card.add_child(installed_row)
	for module_id_value in definitions.keys():
		var module_id := String(module_id_value)
		if installed.has(module_id):
			continue
		var module := definitions.get(module_id, {}) as Dictionary
		if not Game.simulation.definition_revealed(Game.state, module):
			continue
		var compatible: bool = facility_id in module.get("compatible_facilities", []) if module_kind == "process" else int(facility.get("manufacturing_generation", 0)) in module.get("compatible_generations", [])
		if not compatible:
			continue
		var available := Game.simulation.manufacturing_module_available(Game.state, facility_id, module_id, module_kind)
		var storage := int(Game.state.manufacturing_module_inventory.get(module_id, 0))
		card.add_child(_button("安装 · %s%s · %s" % [_content_name(module, module_id), "（库存 %d）" % storage if storage > 0 else "", _resource_list(module.get("costs", []))], _command.bind("安装制造模块", Game.install_manufacturing_module.bind(facility_id, module_id, module_kind)), runtime_busy or not available))


func _build_background_economy_controls(box: VBoxContainer) -> void:
	var managed_items: Array[String] = []
	for item_id_value in Game.state.resource_maturity.keys():
		var item_id := String(item_id_value)
		if Game.state.resource_maturity_state(item_id) in ["MANAGED", "BACKGROUND"]:
			managed_items.append(item_id)
	if managed_items.is_empty():
		return
	managed_items.sort()
	box.add_child(_section_title("后台工业目标"))
	for item_id in managed_items:
		var item := Game.content.items.get(item_id, {}) as Dictionary
		var target_input := _number_input(int(Game.state.background_economy.get("targets", {}).get(item_id, 0)), 0, 1000000, 1)
		var priority_input := _number_input(int(Game.state.background_economy.get("priorities", {}).get(item_id, 50)), 0, 100, 5)
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 6)
		var caption := _label("%s · %s" % [_content_name(item, item_id), _status_text(Game.state.resource_maturity_state(item_id))], 13, COLOR_TEXT)
		caption.custom_minimum_size.x = 210
		row.add_child(caption)
		row.add_child(_labeled_control("目标库存", target_input))
		row.add_child(_labeled_control("优先级", priority_input))
		row.add_child(_button("保存", _save_background_policy.bind(item_id, target_input, priority_input)))
		box.add_child(row)


func _save_background_policy(item_id: String, target_input: SpinBox, priority_input: SpinBox) -> void:
	if not Game.set_background_target(item_id, int(target_input.value)):
		return
	Game.set_background_priority(item_id, int(priority_input.value))
	_append_log("后台工业策略已保存 · %s" % item_id)


func _rebuild_megastructure() -> void:
	var box: VBoxContainer = _pages["megastructure"]
	_clear(box)
	box.add_child(_page_title("文明工程", "四项巨构是主线末段的真实建造项目：消耗物资、占用建造队列，并按里程碑逐段交付。"))
	var queue_used := Game.simulation.construction_queue_size(Game.state)
	var queue_capacity := Game.simulation.construction_queue_capacity(Game.state)
	var complete_count := 0
	for megastructure_id_value in Game.content.megastructures.keys():
		if bool(Game.state.megastructures.get(String(megastructure_id_value), false)):
			complete_count += 1
	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	summary.add_child(_stat_card("已完成", "%d / %d" % [complete_count, Game.content.megastructures.size()], COLOR_GOOD if complete_count == Game.content.megastructures.size() else COLOR_ACCENT))
	summary.add_child(_stat_card("建造队列", "%d / %d" % [queue_used, queue_capacity], COLOR_WARN if queue_used >= queue_capacity else COLOR_TEXT))
	summary.add_child(_stat_card("工程等级", str(Game.simulation.construction_engineering_level(Game.state)), COLOR_TEXT))
	box.add_child(summary)

	for definition_value in Game.content.megastructures.values():
		var definition := definition_value as Dictionary
		var megastructure_id := String(definition.get("id", ""))
		var activity_id := String(definition.get("construction_activity", ""))
		var activity := Game.content.activities.get(activity_id, {}) as Dictionary
		var project: Dictionary = Game.state.megastructure_projects.get(megastructure_id, {})
		var runtime := _construction_runtime_for_activity(activity_id)
		var complete := bool(Game.state.megastructures.get(megastructure_id, false))
		var card := _card()
		card.add_child(_label(("✓ " if complete else "") + _content_name(definition, megastructure_id), 18, COLOR_GOOD if complete else COLOR_TEXT))
		card.add_child(_label(_project_summary(activity), 13, COLOR_MUTED))
		var percent := 100 if complete else int(project.get("progress_percent", 0))
		var stage_index := int(project.get("stage_index", definition.get("stages", []).size() - 1 if complete else 0))
		var stages: Array = definition.get("stages", [])
		var stage_definition: Dictionary = stages[clampi(stage_index, 0, maxi(0, stages.size() - 1))] if not stages.is_empty() else {}
		var stage_percent := int(stage_definition.get("percent", percent))
		var stage_fallback := String(project.get("stage_name", stage_definition.get("name", "Operational" if complete else "Planned")))
		var stage_name := I18n.megastructure_stage(megastructure_id, stage_percent, stage_fallback)
		card.add_child(_megastructure_progress(percent, stage_name))
		card.add_child(_label("阶段里程碑 · " + _megastructure_stage_line(definition, percent), 12, COLOR_MUTED))
		if not project.is_empty():
			card.add_child(_label("物资流：%s · 已交付 %s" % [_status_text(String(project.get("material_flow_status", "RECEIVING"))), _quantity_map_text(project.get("delivered_materials", {}))], 13, COLOR_ACCENT if String(project.get("material_flow_status", "")) != "AWAITING_SHIPMENT" else COLOR_WARN))
		if complete:
			card.add_child(_label("已投入运行，其系统效果已写入实际文明状态。", 13, COLOR_GOOD))
		elif not runtime.is_empty():
			card.add_child(_label("队列 #%d · %s" % [int(runtime.get("slot", 0)) + 1, _status_text(String(runtime.get("status", "QUEUED")))], 13, COLOR_WARN if String(runtime.get("status", "")) == "BLOCKED" else COLOR_TEXT))
			var cancel_button := _button("取消巨构项目", _command.bind("取消巨构项目", Game.stop_construction_project.bind(int(runtime.get("slot", 0)))), false, COLOR_WARN)
			cancel_button.name = "CancelMegastructure_%s" % megastructure_id
			card.add_child(cancel_button)
		else:
			var reason := _construction_block_reason(activity_id)
			var start_button := _button("启动文明工程", _command.bind("启动文明工程", Game.start_construction_project.bind(activity_id)), not reason.is_empty(), COLOR_GOOD)
			start_button.name = "StartMegastructure_%s" % megastructure_id
			card.add_child(start_button)
			if not reason.is_empty():
				card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))


func _megastructure_progress(percent: int, stage_name: String) -> Control:
	var progress_box := VBoxContainer.new()
	progress_box.add_theme_constant_override("separation", 3)
	progress_box.add_child(_label("当前阶段 · %s · %d%%" % [stage_name, percent], 14, COLOR_ACCENT))
	var bar := ProgressBar.new()
	bar.max_value = 100.0
	bar.value = percent
	bar.show_percentage = false
	bar.custom_minimum_size.y = 10
	progress_box.add_child(bar)
	return progress_box


func _megastructure_stage_line(definition: Dictionary, current_percent: int) -> String:
	var parts: Array[String] = []
	var megastructure_id := String(definition.get("id", ""))
	for stage_value in definition.get("stages", []):
		var stage := stage_value as Dictionary
		var stage_percent := int(stage.get("percent", 0))
		var stage_name := I18n.megastructure_stage(megastructure_id, stage_percent, String(stage.get("name", "Stage")))
		parts.append("%s%d%% %s" % ["✓ " if stage_percent <= current_percent else "○ ", stage_percent, stage_name])
	return "  →  ".join(parts)


func _quantity_map_text(values: Dictionary) -> String:
	if values.is_empty():
		return "尚未交付"
	var parts: Array[String] = []
	for item_id_value in values.keys():
		var item_id := String(item_id_value)
		var item := Game.content.items.get(item_id, {}) as Dictionary
		parts.append("%s×%d" % [_content_name(item, item_id), int(values.get(item_id, 0))])
	parts.sort()
	return "、".join(parts)


func _construction_runtime_for_activity(activity_id: String) -> Dictionary:
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")) == activity_id and String(operation.get("status", "IDLE")) in ["RUNNING", "BLOCKED", "QUEUED"]:
			return operation
	return {}


func _rebuild_research() -> void:
	var box: VBoxContainer = _pages["research"]
	_clear(box)
	box.add_child(_page_title("科研", "建成研究设施并积累数据后，研究项目才会解锁。"))
	var research_summary := HBoxContainer.new()
	research_summary.add_theme_constant_override("separation", 8)
	research_summary.add_child(_stat_card("已完成项目", str(Game.state.completed_projects.size()), COLOR_GOOD))
	research_summary.add_child(_stat_card("已解锁技术", str(Game.state.technologies.size()), COLOR_ACCENT))
	research_summary.add_child(_stat_card("研究设施", "在线" if "research_complex" in Game.state.facilities else "离线", COLOR_GOOD if "research_complex" in Game.state.facilities else COLOR_WARN))
	box.add_child(research_summary)
	var current_id := String(Game.state.research.get("project_id", ""))
	if not current_id.is_empty():
		var current := Game.content.research_projects.get(current_id, {}) as Dictionary
		var card := _card()
		card.add_child(_label("当前项目 · " + _content_name(current, current_id), 17, COLOR_ACCENT))
		card.add_child(_operation_progress(Game.state.research, String(Game.state.research.get("status", "RUNNING"))))
		card.add_child(_button("停止研究", _command.bind("停止研究", Game.stop_research), false, COLOR_WARN))
		box.add_child(_wrap_card(card))

	box.add_child(_section_title("可见研究与舰体开发"))
	for project_value in Game.content.research_projects.values():
		var project := project_value as Dictionary
		var project_id := String(project.get("id", ""))
		if bool(Game.state.completed_projects.get(project_id, false)):
			continue
		if not Game.simulation.definition_revealed(Game.state, project):
			continue
		var card := _card()
		card.add_child(_label(_content_name(project, project_id), 16, COLOR_TEXT))
		card.add_child(_label(_project_summary(project), 13, COLOR_MUTED))
		var available := Game.simulation.research_project_available(Game.state, project)
		var busy := not current_id.is_empty() and current_id != project_id
		var start_button := _button("开始研究", _command.bind("开始研究", Game.start_research_project.bind(project_id)), not available or busy)
		start_button.name = "StartResearch_%s" % project_id
		card.add_child(start_button)
		if not available:
			card.add_child(_requirements_label(project.get("requirements", [])))
		box.add_child(_wrap_card(card))

	box.add_child(_section_title("已解锁科技"))
	var technology_lines: Array[String] = []
	for technology_id_value in Game.state.technologies.keys():
		if not bool(Game.state.technologies.get(technology_id_value, false)):
			continue
		var technology_id := String(technology_id_value)
		var technology := Game.content.technologies.get(technology_id, {}) as Dictionary
		technology_lines.append("✓ %s" % _content_name(technology, technology_id))
	technology_lines.sort()
	box.add_child(_card_text("\n".join(technology_lines) if not technology_lines.is_empty() else "尚未解锁技术。", COLOR_GOOD if not technology_lines.is_empty() else COLOR_MUTED))

	box.add_child(_section_title("已完成项目"))
	var completed_lines: Array[String] = []
	for completed_id_value in Game.state.completed_projects.keys():
		if not bool(Game.state.completed_projects.get(completed_id_value, false)):
			continue
		var completed_id := String(completed_id_value)
		var completed_project := Game.content.research_projects.get(completed_id, {}) as Dictionary
		completed_lines.append("✓ %s" % _content_name(completed_project, completed_id))
	completed_lines.sort()
	box.add_child(_card_text("\n".join(completed_lines) if not completed_lines.is_empty() else "尚未完成研究项目。", COLOR_GOOD if not completed_lines.is_empty() else COLOR_MUTED))


func _rebuild_fleet() -> void:
	var box: VBoxContainer = _pages["fleet"]
	_clear(box)
	box.add_child(_page_title("星港与舰队", "管理永久舰船实体、前列 / 中列 / 后列编队、补给、改装、建造和生命周期。"))
	var expedition_ids: Array = Game.state.fleet_ship_ids("expedition")
	var command_used := Game.simulation.fleet_command_usage(Game.state, expedition_ids)
	var command_capacity := Game.simulation.fleet_command_capacity(Game.state)
	var active_count := Game.state.ships.filter(func(ship): return String(ship.get("maintenance_state", "ACTIVE")) == "ACTIVE").size()
	var repair_count := Game.state.ships.filter(func(ship): return String(ship.get("status", "")) == "REPAIRING").size()
	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	summary.add_child(_stat_card("舰船实体", str(Game.state.ships.size()), COLOR_TEXT))
	summary.add_child(_stat_card("现役", str(active_count), COLOR_GOOD))
	summary.add_child(_stat_card("维修中", str(repair_count), COLOR_WARN if repair_count > 0 else COLOR_MUTED))
	summary.add_child(_stat_card("远征指挥", "%d / %d" % [command_used, command_capacity], COLOR_ACCENT))
	box.add_child(summary)

	var section_tabs := HFlowContainer.new()
	section_tabs.add_theme_constant_override("h_separation", 6)
	section_tabs.add_theme_constant_override("v_separation", 6)
	for entry in [["roster", "舰船名册"], ["readiness", "编队与补给"], ["shipyard", "造船与改装"], ["archive", "维修与档案"]]:
		var section_id := String(entry[0])
		var section_button := _button(String(entry[1]), _select_fleet_section.bind(section_id), section_id == _fleet_section, COLOR_ACCENT)
		section_button.name = "FleetSection_%s" % section_id
		section_tabs.add_child(section_button)
	box.add_child(section_tabs)
	match _fleet_section:
		"readiness":
			_build_fleet_readiness(box)
		"shipyard":
			_build_fleet_shipyard(box)
		"archive":
			_build_fleet_archive(box)
		_:
			_build_fleet_roster(box)


func _select_fleet_section(section: String) -> void:
	_fleet_section = section
	_rebuild_fleet()


func _build_fleet_readiness(box: VBoxContainer) -> void:
	var formation: Dictionary = Game.state.fleet_logistics_runtime("expedition").get("formation", {})
	var formation_card := _card()
	formation_card.add_child(_label("作战条令", 16, COLOR_ACCENT))
	var doctrine_row := HFlowContainer.new()
	doctrine_row.add_theme_constant_override("h_separation", 6)
	doctrine_row.add_theme_constant_override("v_separation", 6)
	for doctrine in ["HOLD_FORMATION", "AGGRESSIVE_PUSH", "MISSILE_SATURATION", "LONG_RANGE_ENGAGEMENT"]:
		doctrine_row.add_child(_button(_status_text(doctrine), _command.bind("设置作战条令", Game.set_fleet_doctrine.bind(doctrine)), String(formation.get("doctrine", "HOLD_FORMATION")) == doctrine, COLOR_ACCENT))
	formation_card.add_child(doctrine_row)
	var retreat_policy: Dictionary = formation.get("retreat_policy", {"mode":"HULL_THRESHOLD", "threshold":0.25})
	formation_card.add_child(_label("撤退策略", 16, COLOR_ACCENT))
	var retreat_row := HFlowContainer.new()
	retreat_row.add_theme_constant_override("h_separation", 6)
	retreat_row.add_theme_constant_override("v_separation", 6)
	for threshold in [0.15, 0.25, 0.40]:
		retreat_row.add_child(_button("船体 ≤ %.0f%%" % (threshold * 100.0), _command.bind("设置撤退策略", Game.set_fleet_retreat_policy.bind("HULL_THRESHOLD", threshold)), String(retreat_policy.get("mode", "")) == "HULL_THRESHOLD" and is_equal_approx(float(retreat_policy.get("threshold", 0.25)), threshold), COLOR_ACCENT))
	retreat_row.add_child(_button("永不撤退", _command.bind("禁用撤退", Game.set_fleet_retreat_policy.bind("NEVER", 0.25)), String(retreat_policy.get("mode", "")) == "NEVER", COLOR_WARN))
	formation_card.add_child(retreat_row)
	formation_card.add_child(_label("三线编队", 16, COLOR_ACCENT))
	var zone_columns := HBoxContainer.new()
	zone_columns.add_theme_constant_override("separation", 8)
	for zone in ["FRONT", "MID", "REAR"]:
		var names: Array[String] = []
		for ship_value in Game.state.ships:
			var ship := ship_value as Dictionary
			var ship_id := String(ship.get("instance_id", ""))
			if Game.state.ship_fleet_domain(ship_id) == "expedition" and String(formation.get("ship_zones", {}).get(ship_id, "FRONT")) == zone:
				names.append(String(ship.get("name", ship_id)))
		var zone_card := _stat_card(_zone_text(zone), "\n".join(names) if not names.is_empty() else "未配置", COLOR_TEXT if not names.is_empty() else COLOR_MUTED)
		zone_columns.add_child(zone_card)
	formation_card.add_child(zone_columns)
	box.add_child(_wrap_card(formation_card))

	box.add_child(_section_title("远征补给计划"))
	var logistics: Dictionary = Game.state.fleet_logistics_runtime("expedition")
	var plan: Dictionary = logistics.get("supply_plan", {})
	for item_id in ["kinetic_munitions", "chemical_propellant", "repair_supplies"]:
		var item := Game.content.items.get(item_id, {}) as Dictionary
		var input := _number_input(int(plan.get(item_id, 0)), 0, 100000, 1)
		var row := _labeled_control("%s · 当前携带 %d" % [_content_name(item, item_id), Game.state.fleet_supply_quantity(item_id)], input)
		row.add_child(_button("保存目标", _save_fleet_supply_plan.bind(item_id, input)))
		box.add_child(row)
	box.add_child(_button("按计划从主基地自动补给", _command.bind("自动补给远征舰队", Game.auto_resupply_fleet), Game.state.fleet_ship_ids("expedition").is_empty(), COLOR_GOOD))


func _save_fleet_supply_plan(item_id: String, input: SpinBox) -> void:
	_command("保存舰队补给计划", Game.set_fleet_supply_plan.bind(item_id, int(input.value), "expedition"))


func _build_fleet_roster(box: VBoxContainer) -> void:
	box.add_child(_section_title("永久舰船名册"))
	var formation: Dictionary = Game.state.fleet_logistics_runtime("expedition").get("formation", {})
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		var blueprint := Game.content.ships.get(String(ship.get("blueprint_id", "")), {}) as Dictionary
		var card := _card()
		card.add_child(_label("%s · %s" % [String(ship.get("name", ship_id)), _content_name(blueprint, String(ship.get("blueprint_id", "")))], 18, COLOR_TEXT))
		var status_color := COLOR_WARN if String(ship.get("status", "")) in ["REPAIRING", "REFITTING", "REACTIVATING"] else COLOR_GOOD
		card.add_child(_label("状态：%s  ·  调配：%s  ·  战位：%s" % [_status_text(String(ship.get("status", "DOCKED"))), _assignment_name(Game.state.ship_fleet_domain(ship_id)), _zone_text(String(Game.state.fleet_logistics_runtime("expedition").get("formation", {}).get("ship_zones", {}).get(ship_id, "FRONT")))], 14, status_color))
		card.add_child(_label("维护：%s · 覆盖 %.0f%% · 欠账 %.1f" % [_status_text(String(ship.get("maintenance_state", "ACTIVE"))), float(ship.get("maintenance_coverage", 1.0)) * 100.0, float(ship.get("maintenance_debt", 0.0))], 13, COLOR_MUTED))
		var service_record: Dictionary = ship.get("service_record", {})
		card.add_child(_label("服役记录：战斗 %d · %d胜/%d负 · 经验 %.1f · 伤害 %.1f" % [int(service_record.get("combat_deployments", 0)), int(service_record.get("victories", 0)), int(service_record.get("defeats", 0)), float(service_record.get("combat_experience", 0.0)), float(service_record.get("damage_dealt", 0.0))], 13, COLOR_MUTED))
		card.add_child(_label("模块：" + _ship_modules_text(ship), 13, COLOR_MUTED))
		card.add_child(_label("生命周期", 14, COLOR_ACCENT))
		var maintenance_row := HFlowContainer.new()
		maintenance_row.add_theme_constant_override("h_separation", 6)
		maintenance_row.add_theme_constant_override("v_separation", 6)
		var maintenance_state := String(ship.get("maintenance_state", "ACTIVE"))
		if maintenance_state == "MOTHBALLED":
			maintenance_row.add_child(_button("启动再服役工程", _command.bind("启动舰船再服役", Game.start_ship_reactivation.bind(ship_id)), String(ship.get("status", "")) != "DOCKED", COLOR_ACCENT))
		else:
			maintenance_row.add_child(_button("现役", _command.bind("设为现役", Game.set_ship_maintenance_state.bind(ship_id, "ACTIVE")), maintenance_state == "ACTIVE" or String(ship.get("status", "")) != "DOCKED"))
			maintenance_row.add_child(_button("战备储备", _command.bind("转入战备储备", Game.set_ship_maintenance_state.bind(ship_id, "READY_RESERVE")), maintenance_state == "READY_RESERVE" or String(ship.get("status", "")) != "DOCKED"))
			maintenance_row.add_child(_button("封存", _command.bind("封存舰船", Game.set_ship_maintenance_state.bind(ship_id, "MOTHBALLED")), String(ship.get("status", "")) != "DOCKED", COLOR_WARN))
		card.add_child(maintenance_row)

		card.add_child(_label("舰队调配", 14, COLOR_ACCENT))
		var assignment_row := HFlowContainer.new()
		assignment_row.add_theme_constant_override("h_separation", 6)
		assignment_row.add_theme_constant_override("v_separation", 6)
		var standby_button := _button("待命", _command.bind("舰船待命", Game.set_ship_fleet_assignment.bind(ship_id, "")), String(ship.get("status", "DOCKED")) != "DOCKED")
		standby_button.name = "AssignStandby_%s" % ship_id
		assignment_row.add_child(standby_button)
		var mining_button := _button("采矿舰队", _command.bind("调入采矿舰队", Game.set_ship_fleet_assignment.bind(ship_id, "mining")), String(ship.get("status", "DOCKED")) != "DOCKED")
		mining_button.name = "AssignMining_%s" % ship_id
		assignment_row.add_child(mining_button)
		var expedition_button := _button("远征舰队", _command.bind("调入远征舰队", Game.set_ship_fleet_assignment.bind(ship_id, "expedition")), String(ship.get("status", "DOCKED")) != "DOCKED")
		expedition_button.name = "AssignExpedition_%s" % ship_id
		assignment_row.add_child(expedition_button)
		card.add_child(assignment_row)
		card.add_child(_label("作战位置", 14, COLOR_ACCENT))
		var zone_row := HFlowContainer.new()
		zone_row.add_theme_constant_override("h_separation", 6)
		zone_row.add_theme_constant_override("v_separation", 6)
		var current_zone := String(formation.get("ship_zones", {}).get(ship_id, "FRONT"))
		for zone in ["FRONT", "MID", "REAR"]:
			zone_row.add_child(_button(_zone_text(zone), _command.bind("设置作战位置", Game.set_ship_combat_zone.bind(ship_id, zone)), current_zone == zone, COLOR_ACCENT))
		card.add_child(zone_row)
		card.add_child(_button("保存当前配置", _command.bind("保存舰船配置", Game.save_ship_loadout.bind(ship_id)), String(ship.get("status", "DOCKED")) != "DOCKED", COLOR_GOOD))
		var matching_loadouts: Array = Game.state.saved_loadouts.values().filter(func(loadout): return String(loadout.get("blueprint_id", "")) == String(ship.get("blueprint_id", "")))
		matching_loadouts.sort_custom(func(a, b): return String(a.get("name", a.get("id", ""))) < String(b.get("name", b.get("id", ""))))
		if not matching_loadouts.is_empty():
			card.add_child(_label("已保存配置", 14, COLOR_ACCENT))
		for loadout_value in matching_loadouts:
			var loadout := loadout_value as Dictionary
			var loadout_id := String(loadout.get("id", ""))
			var loadout_row := HFlowContainer.new()
			loadout_row.add_theme_constant_override("h_separation", 6)
			loadout_row.add_theme_constant_override("v_separation", 6)
			loadout_row.add_child(_label(String(loadout.get("name", loadout_id)), 13, COLOR_MUTED))
			loadout_row.add_child(_button("应用", _command.bind("应用舰船配置", Game.apply_ship_loadout.bind(ship_id, loadout_id)), String(ship.get("status", "DOCKED")) != "DOCKED"))
			loadout_row.add_child(_button("删除", _command.bind("删除舰船配置", Game.delete_ship_loadout.bind(loadout_id)), false, COLOR_WARN))
			card.add_child(loadout_row)

		var module_choices := _compatible_inventory_modules(ship)
		if not module_choices.is_empty():
			card.add_child(_label("可用改装", 14, COLOR_ACCENT))
			for choice_value in module_choices:
				var choice := choice_value as Dictionary
				var new_id := String(choice.get("new_id", ""))
				var old_id := String(choice.get("old_id", ""))
				var module_def := Game.content.modules.get(new_id, {}) as Dictionary
				var old_def := Game.content.modules.get(old_id, {}) as Dictionary
				var button_text := "将 %s 替换为 %s" % [_content_name(old_def, old_id), _content_name(module_def, new_id)]
				card.add_child(_button(button_text, _command.bind("开始改装", Game.replace_ship_module.bind(ship_id, old_id, new_id)), String(ship.get("status", "DOCKED")) != "DOCKED"))
		if String(ship.get("status", "")) == "DOCKED" and Game.state.ship_fleet_domain(ship_id).is_empty():
			card.add_child(_button("拆解并写入海军档案（回收 40%）", _command.bind("拆解舰船", Game.scrap_ship.bind(ship_id)), false, COLOR_WARN))
		box.add_child(_wrap_card(card))
	if Game.state.ships.is_empty():
		box.add_child(_card_text("当前没有舰船实体。前往“造船与改装”下达建造订单。", COLOR_WARN))


func _build_fleet_archive(box: VBoxContainer) -> void:
	if not Game.state.ship_service_projects.is_empty():
		box.add_child(_section_title("维修、改装与再服役工程"))
		for project_value in Game.state.ship_service_projects:
			var project := project_value as Dictionary
			box.add_child(_card_text("%s · %s · %.0f%%" % [_status_text(String(project.get("project_kind", "SERVICE"))), String(project.get("ship_id", "")), 100.0 * float(project.get("progress_ms", 0.0)) / maxf(1.0, float(project.get("duration_ms", 1.0)))], COLOR_MUTED))
	else:
		box.add_child(_card_text("当前没有船坞服务工程。战损舰会在返航后进入真实维修流程。", COLOR_MUTED))
	box.add_child(_section_title("海军档案"))
	if not Game.state.naval_archive.is_empty():
		for archive_value in Game.state.naval_archive:
			var archive := archive_value as Dictionary
			box.add_child(_card_text("%s · %s · 服役于 %d · 拆解于 %d" % [String(archive.get("name", archive.get("ship_id", ""))), String(archive.get("blueprint_id", "")), int(archive.get("commissioned_at_ms", 0)), int(archive.get("scrapped_at_ms", 0))], COLOR_MUTED))
	else:
		box.add_child(_card_text("档案为空。拆解的永久舰船实体会保留在这里。", COLOR_MUTED))


func _build_fleet_shipyard(box: VBoxContainer) -> void:
	box.add_child(_section_title("船坞建造队列"))
	for order_index in Game.state.shipyard_queue.size():
		var order_value = Game.state.shipyard_queue[order_index]
		var order := order_value as Dictionary
		var order_card := _card()
		order_card.add_child(_label("%s · %s" % [String(order.get("plan_id", "订单")), _status_text(String(order.get("status", "QUEUED")))], 16, COLOR_TEXT))
		order_card.add_child(_label("本舰 %.0f%% · 已完成 %d / %d · 剩余 %d" % [float(order.get("completed_segments", 0)), int(order.get("quantity_completed", 0)), int(order.get("quantity_total", 1)), int(order.get("quantity_remaining", 0))], 13, COLOR_MUTED))
		var queue_actions := HFlowContainer.new()
		queue_actions.add_theme_constant_override("h_separation", 6)
		queue_actions.add_child(_button("上移", _command.bind("调整造船顺序", Game.move_shipyard_project.bind(String(order.get("plan_id", "")), order_index - 1)), order_index <= 0))
		queue_actions.add_child(_button("下移", _command.bind("调整造船顺序", Game.move_shipyard_project.bind(String(order.get("plan_id", "")), order_index + 1)), order_index >= Game.state.shipyard_queue.size() - 1))
		order_card.add_child(queue_actions)
		box.add_child(_wrap_card(order_card))
	if Game.state.shipyard_queue.is_empty():
		box.add_child(_card_text("造船队列为空。批量订单会逐舰消耗物料清单，并生成独立舰船实体。", COLOR_MUTED))
	box.add_child(_section_title("已解锁舰体计划"))
	for plan_value in Game.content.ship_construction_projects.values():
		var plan := plan_value as Dictionary
		var plan_id := String(plan.get("id", ""))
		if not bool(Game.state.unlocked_ship_plans.get(plan_id, false)):
			continue
		var card := _card()
		card.add_child(_label(_content_name(plan, plan_id), 16, COLOR_TEXT))
		card.add_child(_label(_project_summary(plan), 13, COLOR_MUTED))
		var batch_row := HFlowContainer.new()
		batch_row.add_theme_constant_override("h_separation", 6)
		batch_row.add_theme_constant_override("v_separation", 6)
		for quantity in [1, 5, 20]:
			var build_button := _button("建造 ×%d" % quantity, _command.bind("加入造船队列", Game.enqueue_unlocked_ship_plan.bind(plan_id, quantity)))
			build_button.name = "BuildShip_%s_%d" % [plan_id, quantity]
			batch_row.add_child(build_button)
		card.add_child(batch_row)
		box.add_child(_wrap_card(card))


func _rebuild_expedition() -> void:
	var box: VBoxContainer = _pages["expedition"]
	_clear(box)
	box.add_child(_page_title("远征", "远征需要专门调配的舰船、补给计划以及满足路线需求的战斗与航行能力。"))

	var expedition_ids: Array = Game.state.fleet_ship_ids("expedition")
	var roster: Array[String] = []
	for ship_id_value in expedition_ids:
		var ship := Game.state.ship_by_id(String(ship_id_value))
		roster.append(String(ship.get("name", ship_id_value)))
	var command_used := Game.simulation.fleet_command_usage(Game.state, expedition_ids)
	var command_capacity := Game.simulation.fleet_command_capacity(Game.state)
	var cargo_used := Game.simulation.fleet_cargo_used(Game.state)
	var cargo_capacity := Game.simulation.fleet_cargo_capacity(Game.state, expedition_ids)
	var ready := Game.fleet_ready("expedition")
	box.add_child(_card_text("远征舰队 · %s\n舰船 %s\n指挥容量 %d / %d · 货舱 %d / %d" % ["就绪" if ready else "未就绪", "、".join(roster) if not roster.is_empty() else "尚未调配舰船", command_used, command_capacity, cargo_used, cargo_capacity], COLOR_GOOD if ready else COLOR_WARN))
	var fleet_actions := HFlowContainer.new()
	fleet_actions.add_theme_constant_override("h_separation", 6)
	fleet_actions.add_child(_button("自动补给远征舰队", _command.bind("自动补给", Game.auto_resupply_fleet), roster.is_empty()))
	fleet_actions.add_child(_button("打开编队与补给", _open_fleet_section.bind("readiness"), false, COLOR_GOOD))
	box.add_child(fleet_actions)

	if not String(Game.state.active_expedition.get("route_id", "")).is_empty():
		var route_id := String(Game.state.active_expedition.get("route_id", ""))
		var route := Game.content.expedition_routes.get(route_id, {}) as Dictionary
		var active := _card()
		active.add_child(_label("当前远征 · " + _content_name(route, route_id), 17, COLOR_ACCENT))
		active.add_child(_label("阶段：%s  ·  节点：%d" % [_status_text(String(Game.state.active_expedition.get("phase", ""))), int(Game.state.active_expedition.get("node_index", 0)) + 1], 14, COLOR_MUTED))
		active.add_child(_operation_progress(Game.state.active_expedition, "航行进度"))
		var combat_state: Dictionary = Game.state.active_expedition.get("combat_state", {})
		if not combat_state.is_empty():
			_add_combat_state_panel(active, combat_state)
		box.add_child(_wrap_card(active))
	var repeat_runtime: Dictionary = Game.runtime_for_domain("expedition")
	if not String(repeat_runtime.get("activity_id", "")).is_empty():
		var activity_id := String(repeat_runtime.get("activity_id", ""))
		var activity := Game.content.activities.get(activity_id, {}) as Dictionary
		var repeat_card := _card()
		repeat_card.add_child(_label("当前行动 · %s" % _content_name(activity, activity_id), 17, COLOR_ACCENT))
		repeat_card.add_child(_operation_progress(repeat_runtime, _status_text(String(repeat_runtime.get("status", "RUNNING")))))
		var repeat_combat_state: Dictionary = repeat_runtime.get("combat_state", {})
		if not repeat_combat_state.is_empty():
			_add_combat_state_panel(repeat_card, repeat_combat_state)
		repeat_card.add_child(_button("召回舰队", _command.bind("停止当前行动", Game.stop_activity.bind("expedition")), false, COLOR_WARN))
		box.add_child(_wrap_card(repeat_card))

	box.add_child(_section_title("可见路线"))
	for route_value in Game.content.expedition_routes.values():
		var route := route_value as Dictionary
		var route_id := String(route.get("id", ""))
		if not Game.simulation.definition_revealed(Game.state, route):
			continue
		var card := _card()
		var completed: bool = int(Game.state.completed_activities.get("route:%s" % route_id, 0)) > 0
		card.add_child(_label(("✓ " if completed else "") + _content_name(route, route_id), 16, COLOR_GOOD if completed else COLOR_TEXT))
		card.add_child(_label(_project_summary(route), 13, COLOR_MUTED))
		var reason := _activity_block_reason("expedition", route_id)
		var start_route_button := _button("开始远征", _command.bind("开始远征", Game.start_expedition_route.bind(route_id)), completed or not reason.is_empty() or roster.is_empty())
		start_route_button.name = "StartRoute_%s" % route_id
		card.add_child(start_route_button)
		if not reason.is_empty():
			card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))

	box.add_child(_section_title("可重复战斗行动"))
	var repeat_found := false
	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		if String(activity.get("domain", "")) != "expedition" or String(activity.get("encounter_type", "")) != "COMBAT" or not Game.simulation.definition_revealed(Game.state, activity):
			continue
		repeat_found = true
		var activity_id := String(activity.get("id", ""))
		var card := _card()
		card.add_child(_label(_content_name(activity, activity_id), 16, COLOR_TEXT))
		card.add_child(_label(_activity_summary(activity), 13, COLOR_MUTED))
		var reason := _direct_activity_block_reason("expedition", activity)
		var busy := not String(repeat_runtime.get("activity_id", "")).is_empty() or String(Game.state.active_expedition.get("status", "")) == "RUNNING"
		var start_combat_button := _button("开始战斗行动", _command.bind("开始战斗行动", Game.start_activity.bind("expedition", activity_id)), busy or not reason.is_empty() or roster.is_empty())
		start_combat_button.name = "StartCombat_%s" % activity_id
		card.add_child(start_combat_button)
		if not reason.is_empty():
			card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))
	if not repeat_found:
		box.add_child(_card_text("完成对应前线战役后会解锁可重复战斗行动。", COLOR_MUTED))

	if not Game.state.expedition_reports.is_empty():
		box.add_child(_section_title("远征报告"))
		var reports: Array = Game.state.expedition_reports.slice(maxi(0, Game.state.expedition_reports.size() - 5))
		reports.reverse()
		for report_value in reports:
			box.add_child(_wrap_card(_combat_report_card(report_value as Dictionary)))


func _open_fleet_section(section: String) -> void:
	_fleet_section = section
	_switch_page("fleet")
	_rebuild_fleet()


func _add_combat_state_panel(parent: VBoxContainer, combat_state: Dictionary) -> void:
	parent.add_child(_label("自动战斗 · %s · 阶段 %d / %d · 事件 %d" % [_status_text(String(combat_state.get("status", "RUNNING"))), int(combat_state.get("phase_index", 0)) + 1, int(combat_state.get("phase_count", 1)), int(combat_state.get("events", 0))], 15, COLOR_WARN))
	parent.add_child(_label("舰队船体 %.0f / %.0f · 护盾 %.0f / %.0f\n敌方船体 %.0f / %.0f · 护盾 %.0f / %.0f" % [float(combat_state.get("fleet_hull", 0.0)), float(combat_state.get("fleet_max_hull", 0.0)), float(combat_state.get("fleet_shield", 0.0)), float(combat_state.get("fleet_max_shield", 0.0)), float(combat_state.get("enemy_hull", 0.0)), float(combat_state.get("enemy_max_hull", 0.0)), float(combat_state.get("enemy_shield", 0.0)), float(combat_state.get("enemy_max_shield", 0.0))], 13, COLOR_TEXT))
	for actor_value in combat_state.get("actors", []):
		var actor := actor_value as Dictionary
		parent.add_child(_label("%s · %s · 船体 %.0f / %.0f · 护盾 %.0f / %.0f" % [String(actor.get("ship_id", "舰船")), _zone_text(String(actor.get("zone", "FRONT"))), float(actor.get("hull", 0.0)), float(actor.get("max_hull", 0.0)), float(actor.get("shield", 0.0)), float(actor.get("max_shield", 0.0))], 12, COLOR_GOOD if float(actor.get("hull", 0.0)) > 0.0 else COLOR_BAD))
	var recent_log: Array = combat_state.get("log", []).slice(maxi(0, combat_state.get("log", []).size() - 4))
	for event_value in recent_log:
		var event := event_value as Dictionary
		parent.add_child(_label(_combat_event_text(event), 11, COLOR_MUTED))


func _combat_report_card(report: Dictionary) -> VBoxContainer:
	var card := _card()
	var combat: Dictionary = report.get("combat", {})
	var result := String(report.get("result", "VICTORY" if bool(combat.get("victory", false)) else "DEFEAT"))
	var route_id := String(report.get("route_id", report.get("activity_id", "ACTION")))
	card.add_child(_label("%s · %s" % [route_id, _status_text(result)], 16, COLOR_GOOD if result in ["SUCCESS", "VICTORY"] or bool(combat.get("victory", false)) else COLOR_WARN))
	card.add_child(_label("原因 %s · 战斗事件 %d · 舰队船体 %.0f · 敌方船体 %.0f" % [_status_text(String(report.get("reason", combat.get("reason", "COMPLETE")))), int(combat.get("events", 0)), float(combat.get("fleet_hull_remaining", 0.0)), float(combat.get("enemy_hull_remaining", 0.0))], 13, COLOR_MUTED))
	for ship_result_value in combat.get("ship_results", []):
		var ship_result := ship_result_value as Dictionary
		card.add_child(_label("%s · %s · 造成 %.1f · 承受 %.1f · 剩余船体 %.1f" % [String(ship_result.get("ship_id", "舰船")), "失能" if bool(ship_result.get("disabled", false)) else "已回收", float(ship_result.get("damage_dealt", 0.0)), float(ship_result.get("damage_taken", 0.0)), float(ship_result.get("hull_remaining", 0.0))], 12, COLOR_BAD if bool(ship_result.get("disabled", false)) else COLOR_TEXT))
	return card


func _combat_event_text(event: Dictionary) -> String:
	if String(event.get("type", "")) == "ATTACK":
		return "%s · %s · %s · 伤害 %.1f" % [String(event.get("source", "")), String(event.get("skill_id", "attack")), "命中" if bool(event.get("hit", false)) else "未命中", float(event.get("damage", 0.0))]
	return _status_text(String(event.get("type", "EVENT")))


func _direct_activity_block_reason(domain_id: String, activity: Dictionary) -> String:
	if Game.can_start_activity(domain_id, activity):
		return ""
	var unmet := _unmet_requirements(activity.get("requirements", []))
	return unmet if not unmet.is_empty() else "舰队状态、能力、补给或当前行动冲突"


func _open_next_flow_target() -> void:
	var page := _next_flow_page()
	if page.is_empty():
		return
	if page == "industry":
		_industry_section = _next_flow_industry_section()
	_switch_page(page)
	if page == "industry":
		_rebuild_industry()


func _next_flow_industry_section() -> String:
	if int(Game.state.completed_activities.get("assemble_frame", 0)) <= 0:
		return "production"
	if "orbital_foundry" not in Game.state.facilities:
		var foundry_runtime := _construction_runtime_for_activity("build_orbital_foundry")
		if not foundry_runtime.is_empty():
			return "production" if String(foundry_runtime.get("status", "")) == "BLOCKED" else "construction"
		return "construction" if _activity_materials_available("build_orbital_foundry") else "production"
	if "electronics_facility" not in Game.state.facilities or "research_complex" not in Game.state.facilities:
		return "construction"
	for goal_value in Game.content.goals.values():
		var goal := goal_value as Dictionary
		if not Game.simulation.definition_revealed(Game.state, goal) or _requirements_complete(goal.get("requirements", [])):
			continue
		for step_value in goal.get("steps", []):
			var step := step_value as Dictionary
			if not _requirements_complete(step.get("requirements", [])) and String(step.get("view", "")) == "infrastructure":
				return "construction"
	return "production"


func _activity_materials_available(activity_id: String) -> bool:
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		if Game.state.item_quantity(String(cost.get("item", "")), SpaceGameState.MAIN_BASE_LOCATION_ID) < int(cost.get("quantity", 0)):
			return false
	return not activity.is_empty()


func _activity_material_progress(activity_id: String, runtime: Dictionary = {}) -> String:
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	var consumed: Dictionary = runtime.get("consumed", {})
	var parts: Array[String] = []
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := String(cost.get("item", ""))
		var required := int(cost.get("quantity", 0))
		var available := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
		var accounted := mini(required, int(consumed.get(item_id, 0)) + available)
		parts.append("%s %d/%d" % [_content_name(Game.content.items.get(item_id, {}), item_id), accounted, required])
	return "、".join(parts)


func _next_flow_step() -> String:
	if not _ship_has_module("mining_laser"):
		return "初始采矿配置缺失。请点击“重开”生成新的采矿优先存档。"
	if _ships_with_assignment("mining").is_empty():
		return "1. 到“舰队”把初始勘探船调入采矿舰队。"
	if not _has_active_mining():
		return "2. 到“前线作业”启动近地永久采集点。\n\n提示：可用顶部 10× / 50× 加速。"
	if int(Game.state.completed_activities.get("assemble_frame", 0)) <= 0:
		var frame_progress := _activity_material_progress("assemble_frame")
		if not _activity_materials_available("assemble_frame"):
			return "3. 为第一套结构框架准备 2 铁锭 + 1 铜锭。\n当前：%s\n\n工程制造中心一次只能运行一种配方；分离或精炼完成后先停止，再切换下一项。" % frame_progress
		return "4. 物料已齐：%s。到“生产配方”开始组装结构框架；完成一套后停止重复生产。" % frame_progress
	if "orbital_foundry" not in Game.state.facilities:
		var foundry_runtime := _construction_runtime_for_activity("build_orbital_foundry")
		var foundry_progress := _activity_material_progress("build_orbital_foundry", foundry_runtime)
		if not foundry_runtime.is_empty():
			return "5. 轨道铸造厂已进入建造队列（%s）。\n物料进度：%s\n\n若显示受阻，先到“生产配方”补齐缺口；建造会自动继续。" % [_status_text(String(foundry_runtime.get("status", "QUEUED"))), foundry_progress]
		if not _activity_materials_available("build_orbital_foundry"):
			return "5. 建设轨道铸造厂需要 1 结构框架 + 4 铁锭 + 2 电子元件。\n当前：%s\n\n保留刚做好的结构框架，停止框架重复生产，继续分离并精炼铁锭。" % foundry_progress
		return "5. 轨道铸造厂物料已齐：%s。点击“前往下一步”，将在“设施建设”中直接看到建造按钮。" % foundry_progress
	if "research_complex" not in Game.state.facilities:
		return "6. 建设电子设施和研究中心，开启科研链路。"
	for goal_value in Game.content.goals.values():
		var goal := goal_value as Dictionary
		if not Game.simulation.definition_revealed(Game.state, goal) or _requirements_complete(goal.get("requirements", [])):
			continue
		for step_value in goal.get("steps", []):
			var step := step_value as Dictionary
			if not _requirements_complete(step.get("requirements", [])):
				var step_id := String(step.get("id", "continue"))
				return "%s\n下一步：%s" % [_content_name(goal, String(goal.get("id", "目标"))), I18n.goal_step(step_id, step_id.replace("_", " ").capitalize())]
		return "%s\n需求：%s" % [_content_name(goal, String(goal.get("id", "目标"))), _unmet_requirements(goal.get("requirements", []))]
	return "主流程目标均已完成。可以继续优化自动化、舰队配置与物流策略。"


func _next_flow_page() -> String:
	if not _ship_has_module("mining_laser") or _ships_with_assignment("mining").is_empty():
		return "fleet"
	if not _has_active_mining():
		return "frontier"
	if Game.state.item_quantity("iron_ingot", SpaceGameState.MAIN_BASE_LOCATION_ID) <= 0 or Game.state.item_quantity("copper_ingot", SpaceGameState.MAIN_BASE_LOCATION_ID) <= 0 or int(Game.state.completed_activities.get("assemble_frame", 0)) <= 0:
		return "industry"
	if "orbital_foundry" not in Game.state.facilities or "research_complex" not in Game.state.facilities:
		return "industry"
	for goal_value in Game.content.goals.values():
		var goal := goal_value as Dictionary
		if not Game.simulation.definition_revealed(Game.state, goal) or _requirements_complete(goal.get("requirements", [])):
			continue
		for step_value in goal.get("steps", []):
			var step := step_value as Dictionary
			if _requirements_complete(step.get("requirements", [])):
				continue
			return _flow_view_to_page(String(step.get("view", "overview")))
		for requirement_value in goal.get("requirements", []):
			var requirement := requirement_value as Dictionary
			if Game.simulation.requirement_met(Game.state, requirement):
				continue
			match String(requirement.get("type", "")):
				"technology", "project_complete":
					return "research"
				"own_ship":
					return "fleet"
				"own_facility":
					return "industry"
				"megastructure":
					return "megastructure"
				_:
					return "expedition"
	return "overview"


func _flow_view_to_page(view: String) -> String:
	match view:
		"mining":
			return "frontier"
		"ships":
			return "fleet"
		"infrastructure":
			return "industry"
		"regions":
			return "system_map"
		"research", "industry", "megastructure", "expedition", "location":
			return view
		_:
			return "overview"


func _active_operation_lines() -> Array[String]:
	var lines: Array[String] = []
	for operation_value in Game.state.mining_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("status", "")) == "RUNNING":
			lines.append("• 采矿：%s" % String(operation.get("site_id", "")))
	for operation_value in Game.state.industrial_operations:
		var operation := operation_value as Dictionary
		if not String(operation.get("activity_id", "")).is_empty():
			lines.append("• 生产：%s" % String(operation.get("activity_id", "")))
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if not String(operation.get("activity_id", "")).is_empty():
			lines.append("• 建造：%s" % String(operation.get("activity_id", "")))
	if not String(Game.state.research.get("project_id", "")).is_empty():
		lines.append("• 科研：%s" % String(Game.state.research.get("project_id", "")))
	if String(Game.state.active_expedition.get("status", "")) == "RUNNING":
		lines.append("• 远征：%s" % String(Game.state.active_expedition.get("route_id", "")))
	return lines


func _compatible_inventory_modules(ship: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var installed: Array = Game.state.ship_module_definition_ids(ship)
	for new_id_value in Game.content.modules.keys():
		var new_id := String(new_id_value)
		var new_module := Game.content.modules.get(new_id, {}) as Dictionary
		if bool(new_module.get("special_equipment", false)):
			if Game.state.stored_equipment_ids(new_id).is_empty():
				continue
		elif not Game.simulation.module_design_available(Game.state, new_id):
			continue
		for old_id_value in installed:
			var old_id := String(old_id_value)
			if not Game.content.modules.has(old_id):
				continue
			var old_module := Game.content.modules[old_id] as Dictionary
			if String(old_module.get("slot", "")) == String(new_module.get("slot", "")) and old_id != new_id:
				result.append({"old_id": old_id, "new_id": new_id})
				break
	return result


func _ship_modules_text(ship: Dictionary) -> String:
	var names: Array[String] = []
	var installed: Array = Game.state.ship_module_definition_ids(ship)
	for module_id_value in installed:
		var module_id := String(module_id_value)
		var module := Game.content.modules.get(module_id, {}) as Dictionary
		names.append(_content_name(module, module_id))
	return " / ".join(names)


func _ship_has_module(module_id: String) -> bool:
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var installed: Array = Game.state.ship_module_definition_ids(ship)
		if module_id in installed:
			return true
	return false


func _ships_with_assignment(assignment: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		if Game.state.ship_fleet_domain(String(ship.get("instance_id", ""))) == assignment:
			result.append(ship)
	return result


func _has_active_mining() -> bool:
	for operation_value in Game.state.mining_operations:
		if String((operation_value as Dictionary).get("status", "")) == "RUNNING":
			return true
	return false


func _mining_operation_for_site(site_id: String) -> Dictionary:
	for operation_value in Game.state.mining_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("site_id", "")) == site_id:
			return operation
	return {}


func _industrial_runtime_for_facility(facility_id: String) -> Dictionary:
	for operation_value in Game.state.industrial_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("facility_id", "")) == facility_id:
			return operation
	return {}


func _activity_for_mining_site(site_id: String) -> Dictionary:
	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		if String(activity.get("domain", "")) == "mining" and String(activity.get("site", "")) == site_id:
			return activity
	return {}


func _activity_block_reason(domain_id: String, activity_id: String) -> String:
	if activity_id.is_empty():
		return "缺少活动定义"
	var activity := Game.content.activities.get(activity_id, {}) as Dictionary
	if domain_id == "expedition":
		activity = Game.content.expedition_routes.get(activity_id, {}) as Dictionary
	if not activity.is_empty() and Game.can_start_activity(domain_id, activity):
		return ""
	var unmet := _unmet_requirements(activity.get("requirements", []))
	if not unmet.is_empty():
		return unmet
	if domain_id == "mining":
		return "需要一艘已安装采矿模块、调入采矿舰队且处于停靠状态的飞船"
	if domain_id == "industry":
		return "资源、设施或工艺能力不足"
	if domain_id == "expedition":
		return "路线需求、舰队能力或补给不足"
	return "当前条件不足"


func _construction_block_reason(activity_id: String) -> String:
	var activity := Game.content.activities.get(activity_id, {}) as Dictionary
	if not activity.is_empty() and Game.can_start_construction_project(activity):
		return ""
	var sponsor_facility_id := String(activity.get("facility", ""))
	if not sponsor_facility_id.is_empty() and not Game.simulation.facility_available(Game.state, sponsor_facility_id):
		return "需要先建成承建设施：%s" % _content_name(Game.content.facilities.get(sponsor_facility_id, {}), sponsor_facility_id)
	var unmet := _unmet_requirements(activity.get("requirements", []))
	return unmet if not unmet.is_empty() else "资源、设施能力或建造队列不足"


func _unmet_requirements(requirements: Array) -> String:
	var lines: Array[String] = []
	for requirement_value in requirements:
		var requirement := requirement_value as Dictionary
		if not Game.simulation.requirement_met(Game.state, requirement):
			lines.append(Game.requirement_text(requirement))
	return "；".join(lines)


func _requirements_complete(requirements: Array) -> bool:
	for requirement_value in requirements:
		if not Game.simulation.requirement_met(Game.state, requirement_value as Dictionary):
			return false
	return true


func _requirements_label(requirements: Array) -> Label:
	var reason := _unmet_requirements(requirements)
	return _label("需求：" + (reason if not reason.is_empty() else "已满足"), 13, COLOR_WARN if not reason.is_empty() else COLOR_GOOD)


func _activity_summary(activity: Dictionary) -> String:
	var parts: Array[String] = []
	var cost_text := _resource_list(activity.get("costs", []))
	var reward_text := _resource_list(activity.get("rewards", []))
	var waste_text := _resource_list(activity.get("waste", []))
	if not cost_text.is_empty():
		parts.append("消耗 " + cost_text)
	if not reward_text.is_empty():
		parts.append("产出 " + reward_text)
	if not waste_text.is_empty():
		parts.append("废料 " + waste_text)
	if activity.has("production_energy_multiplier"):
		parts.append("能耗 ×%.2f" % float(activity.get("production_energy_multiplier", 1.0)))
	if activity.has("work_required"):
		parts.append("工作量 %.1f" % float(activity.get("work_required", 1.0)))
	var facility_id := String(activity.get("facility", ""))
	if not facility_id.is_empty():
		var facility := Game.content.facilities.get(facility_id, {}) as Dictionary
		parts.append("设施 " + _content_name(facility, facility_id))
	return "  ·  ".join(parts) if not parts.is_empty() else "无直接资源消耗"


func _project_summary(definition: Dictionary) -> String:
	var description := I18n.content(definition, "description")
	var costs := _resource_list(definition.get("costs", []))
	if costs.is_empty():
		costs = _resource_list(definition.get("cost", []))
	if not costs.is_empty():
		description += ("  ·  " if not description.is_empty() else "") + "消耗 " + costs
	return description if not description.is_empty() else "等待更多数据"


func _resource_list(entries: Array) -> String:
	var parts: Array[String] = []
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := String(entry.get("item", entry.get("item_id", "")))
		var amount := int(entry.get("quantity", entry.get("amount", 0)))
		var item := Game.content.items.get(item_id, {}) as Dictionary
		parts.append("%s×%d" % [_content_name(item, item_id), amount])
	return "、".join(parts)


func _operation_progress(operation: Dictionary, caption: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var duration := maxf(float(operation.get("duration_ms", operation.get("cycle_duration_ms", 1.0))), 1.0)
	var elapsed := float(operation.get("progress_ms", operation.get("cycle_progress_ms", operation.get("elapsed_ms", 0.0))))
	var progress := clampf(elapsed / duration, 0.0, 1.0)
	box.add_child(_label("%s · %.0f%%" % [caption, progress * 100.0], 13, COLOR_ACCENT))
	var bar := ProgressBar.new()
	bar.max_value = 1.0
	bar.value = progress
	bar.show_percentage = false
	bar.custom_minimum_size.y = 8
	box.add_child(bar)
	return box


func _content_name(definition: Dictionary, fallback: String) -> String:
	if definition.is_empty():
		return fallback
	var localized := I18n.content(definition)
	return localized if not localized.is_empty() else String(definition.get("name", fallback))


func _assignment_name(assignment: String) -> String:
	match assignment:
		"mining": return "采矿舰队"
		"expedition": return "远征舰队"
		_: return "待命"


func _zone_text(zone: String) -> String:
	match zone.to_upper():
		"FRONT": return "前列"
		"MID": return "中列"
		"REAR": return "后列"
		_: return "未配置"


func _logistics_mode_text(mode: String) -> String:
	match mode.to_upper():
		"SUPPLY": return "供给"
		"DEMAND": return "需求"
		"STORAGE": return "仓储"
		_: return "未设置"


func _status_text(status: String) -> String:
	var normalized := status.strip_edges().to_upper().replace(" ", "_")
	match normalized:
		"": return "无"
		"UNKNOWN": return "未知"
		"UNDISCOVERED": return "未发现"
		"DISCOVERED": return "已发现"
		"UNSURVEYED": return "未勘测"
		"SURVEYED": return "已勘测"
		"PROSPECT": return "勘探点"
		"MAIN_BASE": return "主基地"
		"CELESTIAL_BODY": return "天体"
		"ORBITAL_HABITAT": return "轨道居住地"
		"NOT_AVAILABLE": return "不可用"
		"NOT_CONNECTED": return "未接入"
		"AVAILABLE": return "可用"
		"ONLINE": return "在线"
		"OFFLINE": return "离线"
		"ACTIVE": return "现役"
		"INACTIVE": return "未启用"
		"IDLE": return "空闲"
		"RUNNING": return "运行中"
		"BLOCKED": return "受阻"
		"QUEUED": return "队列中"
		"COMPLETE", "COMPLETED": return "已完成"
		"READY": return "就绪"
		"PAUSED": return "已暂停"
		"MANUAL": return "手动模式"
		"CONSTRAINED": return "受限"
		"RECEIVING": return "接收物资中"
		"AWAITING_SHIPMENT": return "等待运输"
		"PLANNED": return "规划中"
		"FOUNDATION": return "基础施工"
		"STRUCTURE": return "主体结构"
		"SYSTEMS": return "系统安装"
		"COMMISSIONING": return "试运行"
		"OPERATIONAL": return "已投运"
		"DOCKED": return "已停泊"
		"REPAIRING", "REPAIR": return "维修中"
		"REFITTING", "REFIT": return "改装中"
		"REACTIVATING", "REACTIVATION": return "再服役中"
		"READY_RESERVE": return "战备储备"
		"MOTHBALLED": return "已封存"
		"SERVICE": return "船坞服务"
		"SUCCESS": return "成功"
		"VICTORY": return "胜利"
		"DEFEAT": return "失败"
		"FAILED": return "失败"
		"DISABLED": return "失能"
		"RECOVERED": return "已回收"
		"TRAVEL", "TRANSIT": return "航行中"
		"COMBAT": return "战斗中"
		"RETURN": return "返航中"
		"ATTACK": return "攻击"
		"EVENT": return "战斗事件"
		"HOLD_FORMATION": return "保持阵型"
		"AGGRESSIVE_PUSH": return "强攻推进"
		"MISSILE_SATURATION": return "导弹饱和"
		"LONG_RANGE_ENGAGEMENT": return "远程交战"
		"CRITICAL": return "关键"
		"HIGH": return "高"
		"NORMAL": return "普通"
		"LOW": return "低"
		"MANAGED": return "受控生产"
		"BACKGROUND": return "后台生产"
		"CHEMICAL_CARGO", "CHEMICAL_CARGO_LOGISTICS": return "化学推进货运"
		_: return "未知状态"


func _command(label_text: String, callable: Callable) -> void:
	var success: Variant = callable.call()
	if success is bool and not success:
		_append_log("失败 · %s · %s" % [label_text, Game.last_notice])
	else:
		_append_log("已执行 · " + label_text)
	_dirty = true


func _set_speed(speed: float) -> void:
	Engine.time_scale = speed
	_append_log("模拟速度：%s" % ("暂停" if speed == 0.0 else "%d×" % int(speed)))
	_update_header()


func _save_game() -> void:
	_command("保存进度", Game.save_game)


func _reset_game() -> void:
	Engine.time_scale = 1.0
	Game.reset_game()
	_event_log.clear()
	_append_log("已重置为全新的核心玩法存档。")
	_dirty = true


func _toggle_locale() -> void:
	I18n.toggle_locale()


func _update_header() -> void:
	if not is_instance_valid(_header_status) or not is_instance_valid(Game.state):
		return
	var total_minutes := int(Game.state.total_elapsed_ms / 60000.0)
	var day := total_minutes / (24 * 60) + 1
	var hour := (total_minutes / 60) % 24
	var minute := total_minutes % 60
	_header_status.text = "第 %d 天  ·  %02d:%02d  ·  文明 %d 级" % [day, hour, minute, int(Game.state.progression_tier)]
	for speed_value in _speed_buttons.keys():
		var button := _speed_buttons[speed_value] as Button
		button.modulate = COLOR_ACCENT if is_equal_approx(float(speed_value), Engine.time_scale) else Color.WHITE


func _append_log(text_value: String) -> void:
	var total_minutes := int(Game.state.total_elapsed_ms / 60000.0) if is_instance_valid(Game.state) else 0
	var stamp := "%02d:%02d" % [(total_minutes / 60) % 24, total_minutes % 60] if is_instance_valid(Game.state) else "--:--"
	_event_log.append("[%s] %s" % [stamp, text_value])
	if _event_log.size() > 40:
		_event_log.pop_front()
	if is_instance_valid(_notice_label):
		_notice_label.text = text_value
	_dirty = true


func _on_state_changed() -> void:
	_dirty = true


func _on_domain_event(event: Dictionary) -> void:
	var event_type := String(event.get("type", "event"))
	var event_id := String(event.get("activity_id", event.get("project_id", event.get("route_id", ""))))
	_append_log("事件 · %s%s" % [event_type, (" · " + event_id) if not event_id.is_empty() else ""])


func _on_command_rejected(reason: String) -> void:
	_append_log("操作被拒绝 · " + reason)


func _on_locale_changed(_locale: String) -> void:
	_dirty = true


func _clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _panel(color: Color = COLOR_PANEL) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = COLOR_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _card() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	return box


func _wrap_card(content: Control) -> PanelContainer:
	var panel := _panel()
	var margin := _margin(14, 12, 14, 12)
	panel.add_child(margin)
	margin.add_child(content)
	return panel


func _card_text(text_value: String, color: Color) -> PanelContainer:
	return _wrap_card(_rich(text_value, color))


func _stat_card(title: String, value: String, color: Color) -> PanelContainer:
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_label(title, 13, COLOR_MUTED))
	content.add_child(_label(value, 24, color))
	var card := _wrap_card(content)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return card


func _page_title(title: String, subtitle: String) -> Control:
	var box := VBoxContainer.new()
	box.add_child(_label(title, 24, COLOR_TEXT))
	box.add_child(_label(subtitle, 14, COLOR_MUTED))
	return box


func _section_title(text_value: String) -> Label:
	return _label(text_value, 17, COLOR_ACCENT)


func _label(text_value: String, size: int = 15, color: Color = COLOR_TEXT) -> Label:
	var value := Label.new()
	value.text = text_value
	value.add_theme_font_size_override("font_size", size)
	value.add_theme_color_override("font_color", color)
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return value


func _rich(text_value: String, color: Color = COLOR_TEXT) -> RichTextLabel:
	var value := RichTextLabel.new()
	value.bbcode_enabled = false
	value.text = text_value
	value.fit_content = true
	value.scroll_active = false
	value.add_theme_color_override("default_color", color)
	return value


func _button(text_value: String, callback: Callable, disabled := false, color: Color = COLOR_ACCENT) -> Button:
	var value := Button.new()
	value.text = text_value
	value.disabled = disabled
	value.custom_minimum_size.y = 34
	value.add_theme_color_override("font_color", color)
	value.add_theme_color_override("font_disabled_color", COLOR_MUTED.darkened(0.3))
	value.pressed.connect(callback)
	return value


func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	return style


func _number_input(value: int, minimum: int, maximum: int, step: int) -> SpinBox:
	var input := SpinBox.new()
	input.min_value = minimum
	input.max_value = maximum
	input.step = step
	input.value = value
	input.allow_greater = false
	input.allow_lesser = false
	input.custom_minimum_size.x = 180
	return input


func _labeled_control(caption: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var caption_label := _label(caption, 13, COLOR_MUTED)
	caption_label.custom_minimum_size.x = 150
	row.add_child(caption_label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _separator() -> HSeparator:
	return HSeparator.new()


func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var value := MarginContainer.new()
	value.add_theme_constant_override("margin_left", left)
	value.add_theme_constant_override("margin_top", top)
	value.add_theme_constant_override("margin_right", right)
	value.add_theme_constant_override("margin_bottom", bottom)
	return value
