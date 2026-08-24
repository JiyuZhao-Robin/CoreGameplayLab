extends Control

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
var _selected_location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
var _location_section := "overview"


func _ready() -> void:
	_build_theme()
	_build_shell()
	_connect_game_signals()
	if I18n.current_locale != "zh_CN":
		I18n.set_locale("zh_CN")
	_append_log("核心玩法实验室已启动。所有画面均由 Godot 控件生成，不使用 UI 图片。")
	_rebuild_all()
	if OS.get_cmdline_user_args().has("--capture-map") or OS.get_cmdline_user_args().has("--capture-location"):
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

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 335
	root_box.add_child(split)

	var sidebar := _panel()
	sidebar.custom_minimum_size = Vector2(315, 0)
	split.add_child(sidebar)
	var sidebar_margin := _margin(16, 14, 16, 14)
	sidebar.add_child(sidebar_margin)
	var sidebar_box := VBoxContainer.new()
	sidebar_box.add_theme_constant_override("separation", 10)
	sidebar_margin.add_child(sidebar_box)
	_pages["sidebar"] = sidebar_box

	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_constant_override("side_margin", 8)
	split.add_child(_tabs)

	_add_page("星系地图", "system_map")
	_add_page("地点", "location")
	_add_page("流程总览", "overview")
	_add_page("前线作业", "frontier")
	_add_page("工业建设", "industry")
	_add_page("科研", "research")
	_add_page("舰队", "fleet")
	_add_page("远征", "expedition")

	_notice_label = Label.new()
	_notice_label.custom_minimum_size.y = 28
	_notice_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_notice_label.add_theme_color_override("font_color", COLOR_MUTED)
	_notice_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root_box.add_child(_notice_label)


func _build_header() -> Control:
	var panel := _panel(COLOR_PANEL_ALT)
	var margin := _margin(16, 10, 12, 10)
	panel.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title_box)
	var title := _label("HELIOS · 核心玩法实验室", 22, COLOR_TEXT)
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
	row.add_child(_button("EN/中", _toggle_locale))
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
	_rebuild_research()
	_rebuild_fleet()
	_rebuild_expedition()
	_update_header()
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
	box.add_child(_page_title("System Map", "只显示真实发现、勘测、库存与连接状态；没有推测指标。"))
	for region_value in Game.content.regions.values():
		var region := region_value as Dictionary
		var location_id := String(region.get("id", ""))
		var location: Dictionary = Game.state.location_state(location_id)
		if location.is_empty() or String(location.get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED:
			continue
		var card := _card()
		card.add_child(_label(_location_name(location_id), 18, COLOR_TEXT))
		card.add_child(_label("%s · Survey %s" % [String(location.get("type", "UNKNOWN")), String(location.get("survey_state", "UNKNOWN"))], 13, COLOR_MUTED))
		card.add_child(_label("Inventory %d · Logistics %s" % [Game.state.total_inventory_units(location_id), String(location.get("logistics_summary", {}).get("status", "NOT_CONNECTED"))], 13, COLOR_MUTED))
		var open_button := _button("进入 Location", _open_location.bind(location_id))
		open_button.name = "Location_%s" % location_id
		card.add_child(open_button)
		box.add_child(_wrap_card(card))


func _open_location(location_id: String) -> void:
	if not Game.state.has_location(location_id):
		return
	_selected_location_id = location_id
	_location_section = "overview"
	var page: Control = _page_controls.get("location")
	if is_instance_valid(page):
		_tabs.current_tab = page.get_index()
	_rebuild_location()


func _select_location_section(section: String) -> void:
	_location_section = section
	_rebuild_location()


func _rebuild_location() -> void:
	var box: VBoxContainer = _pages["location"]
	_clear(box)
	var location: Dictionary = Game.state.location_state(_selected_location_id)
	if location.is_empty():
		box.add_child(_page_title("Location", "请先从 System Map 选择已知地点。"))
		return
	box.add_child(_page_title(_location_name(_selected_location_id), "%s · %s" % [String(location.get("type", "UNKNOWN")), String(location.get("system_id", "UNKNOWN"))]))
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	for section in ["overview", "resources", "industry", "logistics", "projects"]:
		var captions := {"overview":"Overview", "resources":"Resources", "industry":"Industry", "logistics":"Logistics", "projects":"Projects"}
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
	box.add_child(_section_title("Identity"))
	box.add_child(_card_text("ID %s\nType %s\nSystem %s\nDiscovery %s\nSurvey %s" % [_selected_location_id, location.get("type", "UNKNOWN"), location.get("system_id", "UNKNOWN"), location.get("discovery_state", "UNKNOWN"), location.get("survey_state", "UNKNOWN")], COLOR_TEXT))
	box.add_child(_section_title("Inventory"))
	var lines: Array[String] = []
	for item_value in Game.state.location_inventory(_selected_location_id).keys():
		var item_id := String(item_value)
		var quantity := Game.state.item_quantity(item_id, _selected_location_id)
		if quantity > 0:
			lines.append("%s × %d" % [_content_name(Game.content.items.get(item_id, {}), item_id), quantity])
	lines.sort()
	box.add_child(_card_text("\n".join(lines) if not lines.is_empty() else "EMPTY", COLOR_TEXT))
	var power: Dictionary = location.get("power", {})
	var power_text := String(power.get("status", "UNKNOWN"))
	if power.has("generation_capacity"):
		power_text = "Generation %.1f / Demand %.1f / Available %.1f" % [float(power.get("generation_capacity", 0.0)), float(power.get("current_demand", 0.0)), float(power.get("available_capacity", 0.0))]
	box.add_child(_section_title("Power"))
	box.add_child(_card_text(power_text, COLOR_TEXT))
	var industry: Dictionary = location.get("industry_summary", {})
	box.add_child(_section_title("Industry"))
	box.add_child(_card_text("%s · Facilities %s · Operations %s" % [industry.get("status", "UNKNOWN"), industry.get("active_facilities", "NOT AVAILABLE"), industry.get("active_operations", 0)], COLOR_TEXT))
	box.add_child(_section_title("Logistics / Projects / Fleet"))
	box.add_child(_card_text("Logistics %s\nActive Projects %d\nFleet Presence %d" % [location.get("logistics_summary", {}).get("status", "NOT_CONNECTED"), int(location.get("projects_summary", {}).get("active_count", 0)), location.get("fleet_presence", []).size()], COLOR_TEXT))


func _build_location_resources(box: VBoxContainer, _location: Dictionary) -> void:
	box.add_child(_section_title("Known Resource Sites"))
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
		box.add_child(_card_text("%s\nState %s · Resource %s · Density %.2f" % [_content_name(site, String(site.get("id", ""))), runtime.get("state", "UNKNOWN"), _content_name(Game.content.items.get(item_id, {}), item_id), float(mining_location.get("density", 0.0))], COLOR_TEXT))
	if not found:
		box.add_child(_card_text("NO KNOWN RESOURCE SITES", COLOR_MUTED))


func _build_location_industry(box: VBoxContainer, location: Dictionary) -> void:
	var summary: Dictionary = location.get("industry_summary", {})
	box.add_child(_card_text("Status %s · Active Facilities %s · Active Operations %s" % [summary.get("status", "NOT_AVAILABLE"), summary.get("active_facilities", "NOT AVAILABLE"), summary.get("active_operations", 0)], COLOR_TEXT))
	for operation_value in Game.state.industrial_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != _selected_location_id or String(operation.get("activity_id", "")).is_empty():
			continue
		var activity: Dictionary = Game.content.activities.get(String(operation.get("activity_id", "")), {})
		box.add_child(_card_text("%s · %s" % [_content_name(activity, String(operation.get("activity_id", ""))), operation.get("status", "UNKNOWN")], COLOR_MUTED))


func _build_location_logistics(box: VBoxContainer, location: Dictionary) -> void:
	box.add_child(_card_text(String(location.get("logistics_summary", {}).get("status", "NOT_CONNECTED")) + "\nShipment is intentionally not implemented in Phase 1.", COLOR_WARN))


func _build_location_projects(box: VBoxContainer, _location: Dictionary) -> void:
	var found := false
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != _selected_location_id or String(operation.get("activity_id", "")).is_empty():
			continue
		found = true
		var activity: Dictionary = Game.content.activities.get(String(operation.get("activity_id", "")), {})
		box.add_child(_card_text("Construction · %s · %s" % [_content_name(activity, String(operation.get("activity_id", ""))), operation.get("status", "UNKNOWN")], COLOR_TEXT))
	for order_value in Game.state.shipyard_queue:
		var order := order_value as Dictionary
		if String(order.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != _selected_location_id:
			continue
		found = true
		box.add_child(_card_text("Shipyard · %s · %s" % [order.get("plan_id", "UNKNOWN"), order.get("status", "UNKNOWN")], COLOR_TEXT))
	if not found:
		box.add_child(_card_text("NO ACTIVE PROJECTS", COLOR_MUTED))


func _location_name(location_id: String) -> String:
	var definition: Dictionary = Game.content.regions.get(location_id, {"id":location_id, "name":location_id})
	return _content_name(definition, location_id)


func _capture_requested_view() -> void:
	var args := OS.get_cmdline_user_args()
	var file_name := "lab_system_map.png"
	if args.has("--capture-location"):
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
	stats.add_child(_stat_card("文明等级", "Tier %d" % Game.state.progression_tier, COLOR_ACCENT))
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
			goal_box.add_child(_label("   %s %s" % ["✓" if step_done else "·", _content_name(step, "阶段")], 14, COLOR_GOOD if step_done else COLOR_MUTED))
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
		card.add_child(_label("状态：%s  ·  熟练度：%d" % [String(site_state.get("status", "PROSPECT")), int(site_state.get("mastery_level", 0))], 14, COLOR_MUTED))
		var operation := _mining_operation_for_site(site_id)
		if not operation.is_empty() and String(operation.get("status", "")) == "RUNNING":
			card.add_child(_operation_progress(operation, "采矿进行中"))
			card.add_child(_button("停止采矿", _command.bind("停止采矿", Game.stop_mining_operation.bind(int(operation.get("slot", 0)))), false, COLOR_WARN))
		else:
			var site_activity := _activity_for_mining_site(site_id)
			var reason := _activity_block_reason("mining", String(site_activity.get("id", "")))
			card.add_child(_button("开始采矿", _command.bind("开始采矿", Game.start_extraction_operation.bind(site_id)), not reason.is_empty()))
			if not reason.is_empty():
				card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))
	if not visible_site:
		box.add_child(_card_text("没有已发现的采集点。", COLOR_MUTED))


func _rebuild_industry() -> void:
	var box: VBoxContainer = _pages["industry"]
	_clear(box)
	box.add_child(_page_title("工业与建设", "工业配方占用对应设施；大型设施进入独立的建造队列。"))

	box.add_child(_section_title("生产配方"))
	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		if String(activity.get("domain", "")) != "industry":
			continue
		if Game.simulation.is_construction_activity(activity):
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
			card.add_child(_button("开始生产", _command.bind("开始生产", Game.start_industry_operation.bind(int(runtime.get("slot", 0)), activity_id)), disabled))
			if busy:
				card.add_child(_label("设施正在执行其他配方。", 13, COLOR_WARN))
			elif not reason.is_empty():
				card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))

	box.add_child(_section_title("设施建设"))
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")).is_empty():
			continue
		var definition := Game.content.activities.get(String(operation.get("activity_id", "")), {}) as Dictionary
		var active_card := _card()
		active_card.add_child(_label(_content_name(definition, "建造项目"), 16, COLOR_TEXT))
		active_card.add_child(_operation_progress(operation, "状态：" + String(operation.get("status", "QUEUED"))))
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
		card.add_child(_button("开始建造", _command.bind("开始建造", Game.start_construction_project.bind(activity_id)), not reason.is_empty()))
		if not reason.is_empty():
			card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))


func _rebuild_research() -> void:
	var box: VBoxContainer = _pages["research"]
	_clear(box)
	box.add_child(_page_title("科研", "建成研究设施并积累数据后，研究项目才会解锁。"))
	var current_id := String(Game.state.research.get("project_id", ""))
	if not current_id.is_empty():
		var current := Game.content.research_projects.get(current_id, {}) as Dictionary
		var card := _card()
		card.add_child(_label("当前项目 · " + _content_name(current, current_id), 17, COLOR_ACCENT))
		card.add_child(_operation_progress(Game.state.research, String(Game.state.research.get("status", "RUNNING"))))
		card.add_child(_button("停止研究", _command.bind("停止研究", Game.stop_research), false, COLOR_WARN))
		box.add_child(_wrap_card(card))

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
		card.add_child(_button("开始研究", _command.bind("开始研究", Game.start_research_project.bind(project_id)), not available or busy))
		if not available:
			card.add_child(_requirements_label(project.get("requirements", [])))
		box.add_child(_wrap_card(card))


func _rebuild_fleet() -> void:
	var box: VBoxContainer = _pages["fleet"]
	_clear(box)
	box.add_child(_page_title("舰队与改装", "飞船必须停靠后才能改装或调配。初始勘探船已经安装采矿激光。"))
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		var blueprint := Game.content.ships.get(String(ship.get("blueprint_id", "")), {}) as Dictionary
		var card := _card()
		card.add_child(_label("%s · %s" % [String(ship.get("name", ship_id)), _content_name(blueprint, String(ship.get("blueprint_id", "")))], 18, COLOR_TEXT))
		card.add_child(_label("状态：%s  ·  调配：%s" % [String(ship.get("status", "DOCKED")), _assignment_name(Game.state.ship_fleet_domain(ship_id))], 14, COLOR_MUTED))
		card.add_child(_label("模块：" + _ship_modules_text(ship), 13, COLOR_MUTED))

		var assignment_row := HBoxContainer.new()
		assignment_row.add_theme_constant_override("separation", 6)
		assignment_row.add_child(_button("待命", _command.bind("舰船待命", Game.set_ship_fleet_assignment.bind(ship_id, "")), String(ship.get("status", "DOCKED")) != "DOCKED"))
		assignment_row.add_child(_button("采矿舰队", _command.bind("调入采矿舰队", Game.set_ship_fleet_assignment.bind(ship_id, "mining")), String(ship.get("status", "DOCKED")) != "DOCKED"))
		assignment_row.add_child(_button("远征舰队", _command.bind("调入远征舰队", Game.set_ship_fleet_assignment.bind(ship_id, "expedition")), String(ship.get("status", "DOCKED")) != "DOCKED"))
		card.add_child(assignment_row)

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
		box.add_child(_wrap_card(card))

	box.add_child(_section_title("船坞建造队列"))
	for order_value in Game.state.shipyard_queue:
		var order := order_value as Dictionary
		box.add_child(_card_text("%s · %s · %.0f%%" % [String(order.get("plan_id", "订单")), String(order.get("status", "QUEUED")), float(order.get("progress", 0.0)) * 100.0], COLOR_MUTED))
	for plan_value in Game.content.ship_construction_projects.values():
		var plan := plan_value as Dictionary
		var plan_id := String(plan.get("id", ""))
		if not bool(Game.state.unlocked_ship_plans.get(plan_id, false)):
			continue
		var card := _card()
		card.add_child(_label(_content_name(plan, plan_id), 16, COLOR_TEXT))
		card.add_child(_label(_project_summary(plan), 13, COLOR_MUTED))
		card.add_child(_button("加入建造队列", _command.bind("加入造船队列", Game.enqueue_unlocked_ship_plan.bind(plan_id))))
		box.add_child(_wrap_card(card))


func _rebuild_expedition() -> void:
	var box: VBoxContainer = _pages["expedition"]
	_clear(box)
	box.add_child(_page_title("远征", "远征需要专门调配的舰船、补给计划以及满足路线需求的战斗与航行能力。"))

	var roster: Array[String] = []
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		if Game.state.ship_fleet_domain(String(ship.get("instance_id", ""))) == "expedition":
			roster.append(String(ship.get("name", ship.get("instance_id", "ship"))))
	box.add_child(_card_text("远征舰队：" + (", ".join(roster) if not roster.is_empty() else "尚未调配舰船"), COLOR_TEXT))
	box.add_child(_button("自动补给远征舰队", _command.bind("自动补给", Game.auto_resupply_fleet), roster.is_empty()))

	if not String(Game.state.active_expedition.get("route_id", "")).is_empty():
		var route_id := String(Game.state.active_expedition.get("route_id", ""))
		var route := Game.content.expedition_routes.get(route_id, {}) as Dictionary
		var active := _card()
		active.add_child(_label("当前远征 · " + _content_name(route, route_id), 17, COLOR_ACCENT))
		active.add_child(_label("阶段：%s  ·  节点：%d" % [String(Game.state.active_expedition.get("phase", "")), int(Game.state.active_expedition.get("node_index", 0)) + 1], 14, COLOR_MUTED))
		active.add_child(_operation_progress(Game.state.active_expedition, "航行进度"))
		box.add_child(_wrap_card(active))

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
		card.add_child(_button("开始远征", _command.bind("开始远征", Game.start_expedition_route.bind(route_id)), completed or not reason.is_empty() or roster.is_empty()))
		if not reason.is_empty():
			card.add_child(_label("尚不可用：" + reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))

	if not Game.state.expedition_reports.is_empty():
		box.add_child(_section_title("远征报告"))
		var report_lines: Array[String] = []
		for report_value in Game.state.expedition_reports.slice(maxi(0, Game.state.expedition_reports.size() - 5)):
			report_lines.append(str(report_value))
		box.add_child(_card_text("\n".join(report_lines), COLOR_MUTED))


func _next_flow_step() -> String:
	if not _ship_has_module("mining_laser"):
		return "初始采矿配置缺失。请点击“重开”生成新的采矿优先存档。"
	if _ships_with_assignment("mining").is_empty():
		return "1. 到“舰队”把初始勘探船调入采矿舰队。"
	if not _has_active_mining():
		return "2. 到“前线作业”启动近地永久采集点。\n\n提示：可用顶部 10× / 50× 加速。"
	if Game.state.item_quantity("iron_ingot", SpaceGameState.MAIN_BASE_LOCATION_ID) <= 0:
		return "3. 取得混合矿石后，在“工业建设”依次分选铁矿并精炼铁锭。"
	if int(Game.state.completed_activities.get("assemble_frame", 0)) <= 0:
		return "4. 继续生产铁锭并组装结构框架，解锁第一批大型建设。"
	if "orbital_foundry" not in Game.state.facilities:
		return "5. 使用创始库存中的再生金属和电子元件，建造轨道铸造厂。"
	if "research_complex" not in Game.state.facilities:
		return "6. 建设电子设施和研究中心，开启科研链路。"
	return "基础工业闭环已经建立。接下来完善科研、造船、补给与远征流程。"


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
	for new_id_value in Game.state.location_inventory(SpaceGameState.MAIN_BASE_LOCATION_ID).keys():
		var new_id := String(new_id_value)
		if Game.state.item_quantity(new_id, SpaceGameState.MAIN_BASE_LOCATION_ID) <= 0 or not Game.content.modules.has(new_id):
			continue
		var new_module := Game.content.modules[new_id] as Dictionary
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
	if not cost_text.is_empty():
		parts.append("消耗 " + cost_text)
	if not reward_text.is_empty():
		parts.append("产出 " + reward_text)
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
	_header_status.text = "第 %d 天  ·  %02d:%02d  ·  Tier %d" % [day, hour, minute, int(Game.state.progression_tier)]
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


func _separator() -> HSeparator:
	return HSeparator.new()


func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var value := MarginContainer.new()
	value.add_theme_constant_override("margin_left", left)
	value.add_theme_constant_override("margin_top", top)
	value.add_theme_constant_override("margin_right", right)
	value.add_theme_constant_override("margin_bottom", bottom)
	return value
