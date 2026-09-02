extends Control

const SystemMapViewScript = preload("res://src/ui/components/system_map_view.gd")
const MegastructureProgressViewScript = preload("res://src/ui/components/megastructure_progress_view.gd")
const GameShellScript = preload("res://src/ui/components/game_shell.gd")
const UiNavigationStateScript = preload("res://src/ui/ui_navigation_state.gd")
const IndustrialNetworkProjectionScript = preload("res://src/ui/view_models/industrial_network_projection.gd")
const IndustrialNetworkViewScript = preload("res://src/ui/components/industrial_network_view.gd")
const ResearchTreeViewScript = preload("res://src/ui/components/research_tree_view.gd")
const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipAssemblyPaletteItemScript = preload("res://src/ui/components/ship_assembly_palette_item.gd")
const ShipModuleInspectorScript = preload("res://src/ui/components/ship_module_inspector.gd")
const ShipHullProfiles = preload("res://src/ui/components/ship_hull_profiles.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const COLOR_BG := UiTokens.COLOR_CANVAS
const COLOR_PANEL := UiTokens.COLOR_PANEL
const COLOR_PANEL_ALT := UiTokens.COLOR_RAISED
const COLOR_BORDER := UiTokens.COLOR_BORDER
const COLOR_TEXT := UiTokens.COLOR_TEXT
const COLOR_TEXT_SECONDARY := UiTokens.COLOR_TEXT_SECONDARY
const COLOR_MUTED := UiTokens.COLOR_TEXT_MUTED
const COLOR_ACCENT := UiTokens.COLOR_FOCUS
const COLOR_GOOD := UiTokens.COLOR_RUNNING
const COLOR_WARN := UiTokens.COLOR_WARNING
const COLOR_BAD := UiTokens.COLOR_CRITICAL
const UI_CONFIG_PATH := "user://core_gameplay_ui.cfg"
const INTERACTIVE_REFRESH_INTERVAL_MS := 250
const SIMULATION_REFRESH_INTERVAL_MS := 1000
const AUDIT_REFRESH_INTERVAL_MS := 20
const NAV_TRANSLATION_KEYS := {
	"system_map":"nav.system_map", "location":"nav.location", "industry":"nav.industry",
	"inventory":"nav.inventory", "logistics":"nav.logistics", "construction":"nav.construction",
	"research":"nav.research", "fleet":"nav.ships", "frontier":"nav.survey",
	"megastructure":"nav.megastructure", "diagnostics":"nav.diagnostics"
}

var _tabs: TabContainer
var _shell
var _ui_state = UiNavigationStateScript.new()
var _pages: Dictionary = {}
var _page_controls: Dictionary = {}
var _header_status: Label
var _notice_label: Label
var _dock_workspace_label: Label
var _dock_next_button: Button
var _event_log: Array[String] = []
var _dirty := true
var _immediate_refresh_requested := false
var _rebuild_in_progress := false
var _last_refresh_ms := 0
var _last_header_ms := 0
var _speed_buttons: Dictionary = {}
var _nav_buttons: Dictionary = {}
var _selected_location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
var _location_section := "overview"
var _industry_section := "production"
var _industry_view_mode := "network"
var _fleet_section := "roster"
var _selected_formation_id := SpaceGameState.DEFAULT_FORMATION_ID
var _logistics_item_selection := {}
var _logistics_advanced := false
var _planner_product_id := ""
var _planner_target_rate := 1.0
var _planner_result: Dictionary = {}
var _planner_target_label := ""
var _inventory_search_text := ""
var _logistics_route_focus_id := ""
var _active_page_key := "system_map"
var _developer_details := false
var _ui_config := ConfigFile.new()
var _alert_records := {}
var _active_blocker_cache: Array[Dictionary] = []
var _telemetry_events: Array[Dictionary] = []
var _seen_blocker_ids := {}
var _industrial_network_view: IndustrialNetworkView
var _industrial_network_projection: IndustrialNetworkProjection
var _industrial_network_preferences: Dictionary = {}
var _selected_industrial_network_node: Dictionary = {}
var _selected_research_project_id := ""
var _selected_shipyard_plan_id := ""
var _selected_shipyard_entity := {"kind":"hull", "id":""}
var _selected_ship_design_id := ""
var _ship_assembly_draft: Dictionary = {}
var _ship_assembly_view: ShipAssemblyMapView
var _ship_design_name_input: LineEdit
var _reduced_motion := false
var _ui_scale := UiTokens.DEFAULT_UI_SCALE
var _ui_scale_selector: OptionButton
var _network_preferences_save_due_ms := 0
var _audit_fast_refresh := false


func _ready() -> void:
	_load_ui_preferences()
	for argument in OS.get_cmdline_user_args():
		if String(argument).begins_with("--fleet-section="):
			_fleet_section = String(argument).trim_prefix("--fleet-section=")
		elif String(argument).begins_with("--industry-section="):
			_industry_section = String(argument).trim_prefix("--industry-section=")
		elif String(argument).begins_with("--industry-view="):
			_industry_view_mode = String(argument).trim_prefix("--industry-view=")
		elif String(argument).begins_with("--network-location="):
			_selected_location_id = String(argument).trim_prefix("--network-location=")
		elif String(argument) == "--reduced-motion":
			_reduced_motion = true
		elif String(argument).begins_with("--ui-scale="):
			_ui_scale = UiTokens.sanitize_ui_scale(float(String(argument).trim_prefix("--ui-scale=")))
		elif String(argument) == "--ui-audit-fast-refresh":
			# Test-only scheduling override. It changes neither simulation time nor
			# command behavior; it only removes the production UI's normal redraw
			# coalescing delay from long visible-control audits.
			_audit_fast_refresh = true
	_build_theme()
	_build_shell()
	resized.connect(_on_root_resized)
	_connect_game_signals()
	_append_log(I18n.core("timeline.lab_started"))
	_rebuild_all()
	call_deferred("_focus_active_navigation_if_empty")
	_record_telemetry("ScreenOpen", {"screen":_active_page_key, "initial":true})
	var capture_requested := OS.get_cmdline_user_args().has("--capture-map") or OS.get_cmdline_user_args().has("--capture-location")
	for argument in OS.get_cmdline_user_args():
		capture_requested = capture_requested or String(argument).begins_with("--capture-view=")
	if capture_requested:
		call_deferred("_capture_requested_view")


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _network_preferences_save_due_ms > 0 and now >= _network_preferences_save_due_ms:
		_network_preferences_save_due_ms = 0
		_save_ui_preferences()
	if now - _last_header_ms >= 200:
		_update_header()
		_last_header_ms = now
	var focused := get_viewport().gui_get_focus_owner()
	var editing_text := focused is LineEdit or focused is TextEdit
	var refresh_interval := AUDIT_REFRESH_INTERVAL_MS if _audit_fast_refresh else (SIMULATION_REFRESH_INTERVAL_MS if Engine.time_scale >= 5.0 else INTERACTIVE_REFRESH_INTERVAL_MS)
	var refresh_due := _immediate_refresh_requested or now - _last_refresh_ms >= refresh_interval
	if not editing_text and _dirty and refresh_due and not _rebuild_in_progress:
		_immediate_refresh_requested = false
		_rebuild_active_page()


func _request_active_page_refresh(immediate: bool) -> void:
	_dirty = true
	if immediate:
		# Rebuild on the next process frame, after the current Control signal has
		# returned. This keeps player actions responsive without destroying the
		# button tree from inside its own pressed callback.
		_immediate_refresh_requested = true


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_focus_next") and get_viewport().gui_get_focus_owner() == null:
		_focus_active_navigation_if_empty()
		get_viewport().set_input_as_handled()
		return
	if not event.is_action_pressed("ui_cancel"):
		return
	if is_instance_valid(_industrial_network_view) and _active_page_key == "industry" and _industry_section == "production" and _industry_view_mode == "network" and _industrial_network_view.clear_selection():
		_selected_industrial_network_node.clear()
		_ui_state.select_context("location", _selected_location_id)
		_rebuild_sidebar()
		get_viewport().set_input_as_handled()
		return
	var destination: String = String(_ui_state.back_target(_page_controls))
	if not destination.is_empty():
		_switch_page(destination, false)
		get_viewport().set_input_as_handled()


func _focus_active_navigation_if_empty() -> void:
	if get_viewport().gui_get_focus_owner() != null:
		return
	var button := _nav_buttons.get(_active_page_key) as Button
	if is_instance_valid(button) and button.is_visible_in_tree() and not button.disabled:
		button.grab_focus()


func _build_theme() -> void:
	theme = UiTokens.build_theme(_ui_scale)


func _build_shell() -> void:
	_shell = GameShellScript.new()
	add_child(_shell)
	_shell.build()
	_shell.left_rail_toggled.connect(_on_left_rail_toggled)
	_shell.right_inspector_toggled.connect(_on_right_inspector_toggled)
	if _requires_single_sidebar() and not _ui_state.left_rail_collapsed and not _ui_state.right_inspector_collapsed:
		_ui_state.right_inspector_collapsed = true
	_shell.set_left_collapsed(_ui_state.left_rail_collapsed)
	_shell.set_right_collapsed(_ui_state.right_inspector_collapsed)
	_shell.header_slot.add_child(_build_header())

	var resource_scroll := ScrollContainer.new()
	resource_scroll.name = "ResourceRail"
	resource_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resource_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	resource_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_shell.left_slot.add_child(resource_scroll)
	var resource_box := VBoxContainer.new()
	resource_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resource_box.add_theme_constant_override("separation", UiTokens.layout_px(UiTokens.SPACING_SM))
	resource_scroll.add_child(resource_box)
	_pages["resource_rail"] = resource_box

	_shell.center_slot.add_child(_build_navigation_rail())

	_tabs = TabContainer.new()
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tabs_visible = false
	_shell.center_slot.add_child(_tabs)

	_add_page(I18n.core("page.system_map"), "system_map")
	_add_page(I18n.core("page.location"), "location")
	_add_page(I18n.core("page.industry"), "industry")
	_add_page(I18n.core("page.inventory", "Inventory"), "inventory")
	_add_page(I18n.core("page.logistics", "Logistics"), "logistics")
	_add_page(I18n.core("page.construction", "Construction"), "construction")
	_add_page(I18n.core("page.research"), "research")
	_add_page(I18n.core("page.fleet"), "fleet")
	_add_page(I18n.core("page.frontier"), "frontier")
	_add_page(I18n.core("page.expedition"), "expedition")
	_add_page(I18n.core("page.megastructure"), "megastructure")
	_add_page(I18n.core("page.diagnostics", "Diagnostics"), "diagnostics")
	var restored_page: Control = _page_controls.get(_active_page_key)
	_tabs.current_tab = restored_page.get_index() if is_instance_valid(restored_page) else 0

	var sidebar_scroll := ScrollContainer.new()
	sidebar_scroll.name = "ContextInspector"
	sidebar_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sidebar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_shell.right_slot.add_child(sidebar_scroll)
	var sidebar_box := VBoxContainer.new()
	sidebar_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sidebar_box.add_theme_constant_override("separation", UiTokens.layout_px(UiTokens.SPACING_SM))
	sidebar_scroll.add_child(sidebar_box)
	_pages["sidebar"] = sidebar_box
	_shell.bottom_slot.add_child(_build_command_dock())


func _build_navigation_rail() -> Control:
	var panel := _panel(UiTokens.COLOR_RAISED)
	panel.name = "WorkspaceNavigationBar"
	panel.custom_minimum_size.y = UiTokens.workspace_navigation_height()
	var margin := _margin(8, 6, 8, 6)
	panel.add_child(margin)
	var rail := HFlowContainer.new()
	rail.name = "WorkspaceNavigationFlow"
	rail.add_theme_constant_override("h_separation", UiTokens.layout_px(4))
	rail.add_theme_constant_override("v_separation", UiTokens.layout_px(4))
	margin.add_child(rail)
	var operations_title := _label(I18n.core("shell.workspaces", "WORKSPACES"), 10, COLOR_MUTED)
	operations_title.name = "OperationsTitle"
	operations_title.custom_minimum_size.x = UiTokens.layout_px(78)
	operations_title.visible = _ui_scale <= 1.0
	operations_title.autowrap_mode = TextServer.AUTOWRAP_OFF
	operations_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	operations_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rail.add_child(operations_title)
	var entries := [
		["system_map", "nav.system_map"],
		["location", "nav.location"],
		["industry", "nav.industry"],
		["inventory", "nav.inventory"],
		["logistics", "nav.logistics"],
		["construction", "nav.construction"],
		["research", "nav.research"],
		["fleet", "nav.ships"],
		["frontier", "nav.survey"],
		["megastructure", "nav.megastructure"],
		["diagnostics", "nav.diagnostics"]
	]
	for entry in entries:
		var key := String(entry[0])
		var button := _button(I18n.core("nav.short.%s" % key, I18n.core(String(entry[1]))), _switch_page.bind(key))
		var public_key := "ships" if key == "fleet" else ("survey" if key == "frontier" else key)
		button.name = "Navigation_%s" % public_key
		button.tooltip_text = I18n.core(String(entry[1]))
		button.custom_minimum_size = UiTokens.layout_vector(Vector2(58, 34))
		button.add_theme_font_size_override("font_size", UiTokens.font_size(12))
		_nav_buttons[key] = button
		rail.add_child(button)
	return panel


func _switch_page(key: String, record_history: bool = true) -> void:
	var page: Control = _page_controls.get(key)
	if not is_instance_valid(page):
		return
	if not _ui_state.navigate(key, _page_controls, record_history):
		return
	_tabs.current_tab = page.get_index()
	_active_page_key = _ui_state.active_workspace
	_save_ui_preferences()
	_request_active_page_refresh(true)
	_update_navigation_state()
	_record_telemetry("ScreenOpen", {"screen":key})


func _update_navigation_state() -> void:
	if not is_instance_valid(_tabs):
		return
	for key_value in _nav_buttons.keys():
		var key := String(key_value)
		var button := _nav_buttons[key] as Button
		var page: Control = _page_controls.get(key)
		var active := is_instance_valid(page) and page.get_index() == _tabs.current_tab
		var availability: Dictionary = Game.ui_navigation_availability(key)
		var caption := I18n.core("nav.short.%s" % key, I18n.core(String(NAV_TRANSLATION_KEYS.get(key, "nav.%s" % key)), key.capitalize()))
		if not bool(availability.get("unlocked", true)):
			caption += " *"
		button.text = caption
		button.tooltip_text = I18n.core(String(NAV_TRANSLATION_KEYS.get(key, "nav.%s" % key)), key.capitalize()) if bool(availability.get("unlocked", true)) else I18n.core(String(availability.get("condition_key", "")), "Progression requirement not met")
		button.add_theme_color_override("font_color", COLOR_ACCENT if active else COLOR_TEXT)
		button.add_theme_stylebox_override("normal", _button_style(UiTokens.COLOR_CONTROL_ACTIVE if active else UiTokens.COLOR_CONTROL, COLOR_ACCENT if active else COLOR_BORDER))


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTokens.layout_px(6))

	var title_box := VBoxContainer.new()
	title_box.custom_minimum_size.x = UiTokens.layout_px(190)
	row.add_child(title_box)
	var title := _label(I18n.core("shell.brand_short", "HELIOS"), 18, COLOR_TEXT)
	title.name = "ShellTitle"
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_box.add_child(title)
	var subtitle := _label(I18n.core("shell.brand_subtitle", "INDUSTRIAL NETWORK"), 10, COLOR_MUTED)
	subtitle.name = "ShellSubtitle"
	subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_box.add_child(subtitle)

	_header_status = _label("", 12, COLOR_MUTED)
	_header_status.name = "HeaderStatus"
	_header_status.custom_minimum_size.x = UiTokens.layout_px(260)
	_header_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_status.visible = _ui_scale <= 1.25
	_header_status.autowrap_mode = TextServer.AUTOWRAP_OFF
	_header_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_header_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_header_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_header_status)

	for speed in [0.0, 1.0, 2.0, 5.0, 10.0, 100.0]:
		var text_value := I18n.core("shell.pause") if speed == 0.0 else "%d×" % int(speed)
		var speed_button := _button(text_value, _set_speed.bind(speed))
		speed_button.name = "SpeedPause" if speed == 0.0 else "Speed%d" % int(speed)
		speed_button.custom_minimum_size.x = UiTokens.layout_px(48 if speed >= 100.0 else 42)
		if speed >= 100.0:
			speed_button.tooltip_text = I18n.core("shell.speed_100_tooltip", "Fast-forward 100× through the normal deterministic simulation; all costs and blockers still apply.")
		_speed_buttons[speed] = speed_button
		row.add_child(speed_button)

	var locale_button := _button(I18n.core("shell.locale_toggle"), _toggle_locale)
	locale_button.name = "ToggleLocale"
	row.add_child(locale_button)
	_ui_scale_selector = OptionButton.new()
	_ui_scale_selector.name = "UIScaleSelector"
	_ui_scale_selector.custom_minimum_size.x = UiTokens.layout_px(92)
	_ui_scale_selector.tooltip_text = I18n.core("shell.ui_scale_tooltip", "Scale interface text and controls without changing map or canvas zoom.")
	_ui_scale_selector.accessibility_name = I18n.core("shell.ui_scale", "UI scale")
	for scale_value in UiTokens.SUPPORTED_UI_SCALES:
		var percent := int(round(float(scale_value) * 100.0))
		_ui_scale_selector.add_item("%d%%" % percent, percent)
	_ui_scale_selector.select(_ui_scale_selector.get_item_index(int(round(_ui_scale * 100.0))))
	_ui_scale_selector.item_selected.connect(_on_ui_scale_selected)
	row.add_child(_ui_scale_selector)
	var save_button := _button(I18n.core("shell.save"), _save_game)
	save_button.name = "SaveButton"
	row.add_child(save_button)
	var restart_button := _button(I18n.core("shell.restart"), _request_reset_game, false, COLOR_BAD)
	restart_button.name = "RestartButton"
	row.add_child(restart_button)
	return row


func _build_command_dock() -> Control:
	var row := HBoxContainer.new()
	row.name = "CommandDock"
	row.add_theme_constant_override("separation", UiTokens.layout_px(UiTokens.SPACING_MD))
	var identity := VBoxContainer.new()
	identity.custom_minimum_size.x = UiTokens.layout_px(148)
	var dock_title := _label(I18n.core("shell.command_dock", "COMMAND DOCK"), 10, COLOR_MUTED)
	dock_title.name = "CommandDockTitle"
	identity.add_child(dock_title)
	_dock_workspace_label = _label("", 15, COLOR_TEXT)
	_dock_workspace_label.name = "DockWorkspaceLabel"
	identity.add_child(_dock_workspace_label)
	row.add_child(identity)
	var separator := VSeparator.new()
	row.add_child(separator)
	_notice_label = Label.new()
	_notice_label.name = "AlertsTimelineTasks"
	_notice_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_notice_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_notice_label.add_theme_font_size_override("font_size", UiTokens.font_size(12))
	_notice_label.add_theme_color_override("font_color", COLOR_MUTED)
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice_label.max_lines_visible = 3
	_notice_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_notice_label)
	var actions := VBoxContainer.new()
	actions.custom_minimum_size.x = UiTokens.layout_px(142)
	actions.add_theme_constant_override("separation", UiTokens.layout_px(UiTokens.SPACING_XS))
	var back_button := _button(I18n.core("shell.back", "Back"), _navigate_back)
	back_button.name = "ShellBack"
	actions.add_child(back_button)
	_dock_next_button = _button(I18n.core("shell.next_action", "Next action"), _open_next_flow_target, false, COLOR_GOOD)
	_dock_next_button.name = "DockNextStep"
	actions.add_child(_dock_next_button)
	row.add_child(actions)
	return row


func _navigate_back() -> void:
	var destination: String = String(_ui_state.back_target(_page_controls))
	if not destination.is_empty():
		_switch_page(destination, false)


func _add_page(title: String, key: String) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = key
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, title)
	var margin := _margin(14, 14, 14, 20)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# A short page should still occupy the complete workspace.  This lets
	# full-canvas tools such as Ship Assembly consume the remaining height
	# instead of stopping at their minimum size and leaving a dead band below.
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	_refresh_alerts()
	_rebuild_resource_rail()
	_rebuild_sidebar()
	_rebuild_system_map()
	_rebuild_location()
	_rebuild_frontier()
	_rebuild_industry()
	_rebuild_inventory()
	_rebuild_logistics()
	_rebuild_construction()
	_rebuild_research()
	_rebuild_fleet()
	_rebuild_expedition()
	_rebuild_megastructure()
	_rebuild_diagnostics()
	_update_header()
	_update_bottom_bar()
	_update_navigation_state()
	_dirty = false
	_last_refresh_ms = Time.get_ticks_msec()


func _rebuild_active_page() -> void:
	if _rebuild_in_progress:
		_request_active_page_refresh(true)
		return
	if not is_instance_valid(Game.state) or not is_instance_valid(Game.content) or not is_instance_valid(_tabs):
		return
	_rebuild_in_progress = true
	var focused := get_viewport().gui_get_focus_owner()
	var focused_name := String(focused.name) if is_instance_valid(focused) and is_ancestor_of(focused) else ""
	var page_before: Control = _tabs.get_current_tab_control()
	var scroll_before := 0
	if page_before is ScrollContainer:
		scroll_before = (page_before as ScrollContainer).scroll_vertical
	_refresh_alerts()
	_rebuild_resource_rail()
	_rebuild_sidebar()
	var active_page: Control = _tabs.get_current_tab_control()
	var key: String = str(active_page.name) if is_instance_valid(active_page) else "system_map"
	match key:
		"system_map": _rebuild_system_map()
		"location": _rebuild_location()
		"frontier": _rebuild_frontier()
		"industry":
			if _industry_section == "production" and _industry_view_mode == "network" and is_instance_valid(_industrial_network_view):
				_refresh_industrial_network_view()
			else:
				_rebuild_industry()
		"inventory": _rebuild_inventory()
		"logistics": _rebuild_logistics()
		"construction": _rebuild_construction()
		"research": _rebuild_research()
		"fleet": _rebuild_fleet()
		"expedition": _rebuild_expedition()
		"megastructure": _rebuild_megastructure()
		"diagnostics": _rebuild_diagnostics()
	_update_header()
	_update_bottom_bar()
	_update_navigation_state()
	_dirty = false
	_last_refresh_ms = Time.get_ticks_msec()
	_rebuild_in_progress = false
	call_deferred("_restore_rebuilt_page_context", focused_name, key, scroll_before)


func _restore_rebuilt_page_context(focused_name: String, page_key: String, scroll_vertical: int) -> void:
	var page := _page_controls.get(page_key) as Control
	if page is ScrollContainer:
		(page as ScrollContainer).scroll_vertical = scroll_vertical
	if focused_name.is_empty():
		return
	var replacement := find_child(focused_name, true, false) as Control
	if not is_instance_valid(replacement) or not replacement.is_visible_in_tree() or replacement.focus_mode == Control.FOCUS_NONE:
		_focus_active_navigation_if_empty()
		return
	if replacement is BaseButton and (replacement as BaseButton).disabled:
		_focus_active_navigation_if_empty()
		return
	replacement.grab_focus()


func _rebuild_resource_rail() -> void:
	var box := _pages.get("resource_rail") as VBoxContainer
	if not is_instance_valid(box):
		return
	_clear(box)
	var location := Game.state.location_state(_selected_location_id)
	box.add_child(_label(I18n.core("resource_rail.title", "LOCATION RESOURCES"), 10, COLOR_MUTED))
	box.add_child(_label(_location_name(_selected_location_id), 18, COLOR_TEXT))
	var location_status := _status_text(String(location.get("survey_state", "UNKNOWN"))) if not location.is_empty() else I18n.core("status.UNKNOWN", "Unknown")
	box.add_child(_label(location_status, 11, COLOR_ACCENT))
	box.add_child(_separator())

	var storage := Game.simulation.location_storage_snapshot(Game.state, _selected_location_id)
	var storage_tone := COLOR_BAD if float(storage.get("utilization", 0.0)) >= 0.98 else (COLOR_WARN if float(storage.get("utilization", 0.0)) >= 0.85 else COLOR_TEXT)
	box.add_child(_label(I18n.core("resource_rail.storage", "STORAGE"), 10, COLOR_MUTED))
	box.add_child(_label(I18n.core("resource_rail.storage_value", "%d / %d units · %d%%") % [int(storage.get("used", 0.0)), int(storage.get("capacity", 0.0)), int(float(storage.get("utilization", 0.0)) * 100.0)], 13, storage_tone))
	var storage_bar := ProgressBar.new()
	storage_bar.max_value = 1.0
	storage_bar.value = float(storage.get("utilization", 0.0))
	storage_bar.show_percentage = false
	storage_bar.custom_minimum_size.y = UiTokens.layout_px(6)
	box.add_child(storage_bar)
	box.add_child(_label(I18n.core("resource_rail.inventory", "LOCAL INVENTORY"), 10, COLOR_MUTED))

	var inventory_rows: Array[Dictionary] = []
	for item_id_value in Game.state.location_inventory(_selected_location_id).keys():
		var item_id := String(item_id_value)
		var quantity := Game.state.item_quantity(item_id, _selected_location_id)
		if quantity <= 0:
			continue
		inventory_rows.append({"item_id":item_id, "quantity":quantity, "available":Game.state.available_item_quantity(item_id, _selected_location_id)})
	inventory_rows.sort_custom(func(a: Dictionary, b: Dictionary): return int(a.get("quantity", 0)) > int(b.get("quantity", 0)))
	if inventory_rows.is_empty():
		box.add_child(_label(I18n.core("sidebar.empty", "Inventory is empty"), 12, COLOR_MUTED))
	else:
		for index in mini(6, inventory_rows.size()):
			var row_data: Dictionary = inventory_rows[index]
			var row := HBoxContainer.new()
			var item_id := String(row_data.get("item_id", ""))
			var item_label := _label(_content_name(Game.content.items.get(item_id, {}), item_id), 12, COLOR_TEXT)
			item_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			item_label.custom_minimum_size.x = UiTokens.layout_px(116)
			item_label.autowrap_mode = TextServer.AUTOWRAP_OFF
			item_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			item_label.tooltip_text = item_label.text
			row.add_child(item_label)
			var quantity_label := _label("%d" % int(row_data.get("quantity", 0)), 12, COLOR_TEXT)
			quantity_label.custom_minimum_size.x = UiTokens.layout_px(42)
			quantity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			quantity_label.tooltip_text = I18n.core("resource_rail.available", "Available: %d") % int(row_data.get("available", 0))
			row.add_child(quantity_label)
			box.add_child(row)
	var open_inventory := _button(I18n.core("resource_rail.open_inventory", "Open inventory"), _switch_page.bind("inventory"), false, COLOR_ACCENT)
	open_inventory.name = "ResourceRailOpenInventory"
	box.add_child(open_inventory)
	box.add_child(_separator())

	box.add_child(_label(I18n.core("resource_rail.current_task", "CURRENT TASK"), 10, COLOR_MUTED))
	var guidance := Game.guidance_snapshot()
	var task_caption := String(guidance.get("message", guidance.get("reason", ""))).get_slice("\n", 0)
	box.add_child(_label(task_caption, 12, COLOR_TEXT_SECONDARY))
	var task_action := _button(I18n.core("resource_rail.locate_task", "Locate task"), _open_next_flow_target, false, COLOR_GOOD)
	task_action.name = "ResourceRailNextStep"
	task_action.tooltip_text = String(guidance.get("reason", ""))
	box.add_child(task_action)

	var scope := _label(I18n.core("shell.scope"), 10, COLOR_MUTED)
	scope.name = "ScopeLabel"
	scope.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scope.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	box.add_child(scope)


func _rebuild_sidebar() -> void:
	var box: VBoxContainer = _pages["sidebar"]
	_clear(box)
	box.add_child(_section_title(I18n.core("sidebar.context", "Context Inspector")))
	var selector := OptionButton.new()
	selector.name = "LocationSelector"
	var location_ids: Array[String] = []
	for location_id_value in Game.state.locations.keys():
		var location_id := String(location_id_value)
		var location := Game.state.location_state(location_id)
		if String(location.get("discovery_state", LocationState.UNDISCOVERED)) != LocationState.DISCOVERED:
			continue
		location_ids.append(location_id)
	location_ids.sort()
	for location_id in location_ids:
		selector.add_item(_location_name(location_id))
		if location_id == _selected_location_id:
			selector.select(selector.item_count - 1)
	selector.item_selected.connect(_on_context_location_selected.bind(location_ids))
	box.add_child(selector)
	var selected := Game.state.location_state(_selected_location_id)
	if _ui_state.selected_kind == "industrial_network" and not _selected_industrial_network_node.is_empty():
		_build_industrial_network_inspector(box, _selected_industrial_network_node)
		_build_sidebar_footer(box)
		return
	if _active_page_key == "research" and not _selected_research_project_id.is_empty():
		_build_research_project_inspector(box, _selected_research_project_id)
		_build_sidebar_footer(box)
		return
	if _active_page_key == "fleet" and _fleet_section == "shipyard":
		_build_shipyard_inspector(box, _ship_assembly_draft, _selected_shipyard_entity)
		_build_sidebar_footer(box)
		return
	_ui_state.select_context("location", _selected_location_id)
	if not selected.is_empty():
		var power: Dictionary = selected.get("power", {})
		var storage: Dictionary = Game.simulation.location_storage_snapshot(Game.state, _selected_location_id)
		var logistics: Dictionary = selected.get("logistics_summary", {})
		box.add_child(_card_text(I18n.core("sidebar.location_summary") % [
			_location_name(_selected_location_id),
			_status_text(String(selected.get("type", "UNKNOWN"))), _status_text(String(selected.get("survey_state", "UNKNOWN"))),
			I18n.core("header.power", "Power"), float(power.get("current_demand", 0.0)), float(power.get("generation_capacity", power.get("available_capacity", 0.0))),
			I18n.core("inventory.storage", "Storage"), float(storage.get("used", 0.0)), float(storage.get("capacity", 0.0)),
			I18n.core("page.logistics", "Logistics"), _status_text(String(logistics.get("status", "NOT_CONNECTED")))
		], COLOR_TEXT))
		var open_location := _button(I18n.core("sidebar.open_location", "Open Location"), _open_location.bind(_selected_location_id), false, COLOR_ACCENT)
		open_location.name = "ContextOpenLocation"
		box.add_child(open_location)

	var blockers: Array[Dictionary] = _current_blockers(_selected_location_id)
	box.add_child(_section_title(I18n.core("sidebar.blockers", "Active blockers")))
	if blockers.is_empty():
		box.add_child(_label(I18n.core("diagnostics.clear", "No critical blocker is active."), 12, COLOR_GOOD))
	else:
		for blocker_value in blockers.slice(0, 3):
			var blocker := blocker_value as Dictionary
			var inspect := _button(_blocker_text(blocker), _navigate_blocker.bind(blocker), false, COLOR_WARN)
			inspect.tooltip_text = I18n.core("diagnostics.open_resolution", "Open resolution")
			box.add_child(inspect)
	_build_sidebar_footer(box)


func _build_research_project_inspector(box: VBoxContainer, project_id: String) -> void:
	var project: Dictionary = Game.content.research_projects.get(project_id, {})
	if project.is_empty():
		_selected_research_project_id = ""
		return
	var completed := bool(Game.state.completed_projects.get(project_id, false))
	var current := String(Game.state.research.get("project_id", "")) == project_id
	var status_id := "COMPLETED" if completed else (String(Game.state.research.get("status", "RUNNING")) if current else ("AVAILABLE" if Game.simulation.research_project_available(Game.state, project) else "LOCKED"))
	var tone := COLOR_GOOD if status_id == "COMPLETED" else (COLOR_BAD if status_id == "BLOCKED" else (COLOR_WARN if status_id in ["LOCKED", "PAUSED"] else COLOR_ACCENT))
	box.add_child(_label(I18n.core("research.inspector.project", "RESEARCH PROJECT"), 10, COLOR_MUTED))
	box.add_child(_label(_content_name(project, project_id), 18, COLOR_TEXT))
	box.add_child(_label(_status_text(status_id), 13, tone))
	box.add_child(_label(_project_summary(project), 12, COLOR_TEXT_SECONDARY))
	box.add_child(_separator())
	box.add_child(_label(I18n.core("research.prerequisites", "PREREQUISITES"), 10, COLOR_MUTED))
	if project.get("requirements", []).is_empty():
		box.add_child(_label(I18n.core("research.no_prerequisites", "No additional prerequisites"), 12, COLOR_GOOD))
	else:
		box.add_child(_requirements_label(project.get("requirements", [])))
	box.add_child(_separator())
	box.add_child(_label(I18n.core("research.roadmap.title"), 10, COLOR_MUTED))
	box.add_child(_label(_research_roadmap_text(project, int(Game.state.research.get("stage_index", 0)) if current else -1), 11, COLOR_TEXT_SECONDARY))
	var close := _button(I18n.core("research.inspector.close", "Close project inspector"), _clear_research_project_selection, false, COLOR_MUTED)
	close.name = "ResearchInspectorClose"
	box.add_child(close)


func _build_shipyard_inspector(box: VBoxContainer, draft: Dictionary, entity: Dictionary) -> void:
	box.add_child(_label(I18n.core("ships.shipyard.inspector_title", "SHIP DESIGN INSPECTOR"), 10, COLOR_MUTED))
	var plan_id := String(draft.get("plan_id", ""))
	var plan := Game.content.ship_construction_projects.get(plan_id, {}) as Dictionary
	if plan.is_empty():
		box.add_child(_label(I18n.core("ships.shipyard.blank_title", "Blank assembly canvas"), 18, COLOR_TEXT))
		box.add_child(_label(I18n.core("ships.shipyard.blank_help", "Drag an unlocked hull from the Ship tab onto the canvas. Then drag parts and connect each color-coded interface yourself."), 12, COLOR_TEXT_SECONDARY))
		box.add_child(_separator())
		box.add_child(_ship_port_color_legend())
		return
	var hull_id := String(plan.get("ship_id", ""))
	var hull := Game.content.ships.get(hull_id, {}) as Dictionary
	box.add_child(_label(_content_name(plan, plan_id), 18, COLOR_TEXT))
	box.add_child(_label(I18n.core("ships.shipyard.canvas_hull") % [_content_name(hull, hull_id), String(hull.get("class", "Ship"))], 12, COLOR_TEXT_SECONDARY))
	box.add_child(_label(I18n.core("ships.shipyard.canvas_hull_metrics") % [int(hull.get("module_slots", 0)), int(hull.get("cargo_capacity", 0)), int(hull.get("command_cost", 0))], 12, COLOR_TEXT_SECONDARY))
	var validation := Game.ship_design_validation(plan_id, draft.get("nodes", []), draft.get("connections", []))
	box.add_child(_label(String(validation.get("reason", "")), 12, COLOR_GOOD if bool(validation.get("allowed", false)) else COLOR_WARN))
	box.add_child(_separator())
	var kind := String(entity.get("kind", "hull"))
	var entity_id := String(entity.get("id", hull_id))
	if kind == "module":
		var module := Game.content.modules.get(entity_id, {}) as Dictionary
		var slot := String(module.get("slot", "utility"))
		var tier := ShipHullProfiles.size_tier(String(module.get("size", "S")))
		var diameter_m := ShipHullProfiles.socket_diameter_m(String(module.get("size", "S")))
		var installed := false
		for node_value in draft.get("nodes", []):
			var module_node := node_value as Dictionary
			if String(module_node.get("kind", "")) != "module" or String(module_node.get("definition_id", "")) != entity_id:
				continue
			var module_node_id := String(module_node.get("node_id", ""))
			for connection_value in draft.get("connections", []):
				if String((connection_value as Dictionary).get("module_node_id", "")) == module_node_id:
					installed = true
					break
			if installed:
				break
		var inspector := ShipModuleInspectorScript.new()
		inspector.name = "ShipModuleInspector"
		inspector.configure(module, {
			"display_name":_content_name(module, entity_id),
			"family_label":I18n.core("ships.shipyard.slot.%s" % slot),
			"tier_label":"T%d" % tier,
			"diameter_label":"Ø%.0fm" % diameter_m,
			"mount_role":Game.ship_module_mount_role(entity_id),
			"installation_state":"INSTALLED" if installed else "AVAILABLE",
			"art_path":ShipAssemblyMapViewScript.module_icon_path(module),
			"tone":_ship_module_slot_tone(slot, Game.ship_module_mount_role(entity_id)),
			"description":_project_summary(module)
		})
		box.add_child(inspector)
	else:
		box.add_child(_label(I18n.core("ships.shipyard.inspector_hull"), 10, COLOR_MUTED))
		box.add_child(_label(_project_summary(plan), 12, COLOR_TEXT_SECONDARY))
	box.add_child(_separator())
	box.add_child(_label(I18n.core("ships.shipyard.inspector_bom"), 10, COLOR_MUTED))
	var effective_plan := plan.duplicate(true)
	if bool(validation.get("allowed", false)):
		effective_plan["starting_modules"] = validation.get("modules", []).duplicate()
	box.add_child(_label(_resource_dictionary(Game.simulation.ship_construction_material_totals(effective_plan)), 11, COLOR_TEXT_SECONDARY))


func _clear_research_project_selection() -> void:
	_selected_research_project_id = ""
	_ui_state.select_context("location", _selected_location_id)
	_rebuild_sidebar()


func _build_industrial_network_inspector(box: VBoxContainer, node: Dictionary) -> void:
	var kind := String(node.get("kind", "PRODUCTION"))
	var status := String(node.get("status", "PAUSED"))
	box.add_child(_label(I18n.core("industrial_network.inspector.entity", "%s ENTITY") % I18n.core("industrial_network.kind.%s" % kind.to_lower(), kind.capitalize()), 10, COLOR_MUTED))
	box.add_child(_label(String(node.get("title", node.get("id", ""))), 18, COLOR_TEXT))
	box.add_child(_label(String(node.get("subtitle", "")), 12, COLOR_TEXT_SECONDARY))
	var status_tone := COLOR_BAD if status in ["BLOCKED", "BLOCKED_INPUT", "BLOCKED_OUTPUT", "CRITICAL"] else (COLOR_WARN if status in ["POWER_LIMITED", "COOLING_LIMITED", "LOGISTICS_LIMITED", "CONGESTED", "SATURATED", "TIGHT", "STORAGE_FULL", "CONSTRAINED"] else COLOR_GOOD)
	box.add_child(_label(I18n.core("industrial_network.inspector.status", "Status: %s") % _status_text(status), 13, status_tone))
	var blocker: Dictionary = node.get("blocker", {}) if node.get("blocker", null) is Dictionary else {}
	if not blocker.is_empty():
		box.add_child(_label(I18n.core("blocker.primary") % _blocker_text(blocker), 13, COLOR_WARN))
	box.add_child(_separator())
	box.add_child(_label(I18n.core("industrial_network.inspector.behavior", "ACTUAL BEHAVIOR"), 10, COLOR_MUTED))
	box.add_child(_label(I18n.core("industrial_network.inspector.rate", "Actual %.2f/h · Theoretical %.2f/h · Utilization %d%%") % [float(node.get("actual_rate", 0.0)), float(node.get("theoretical_rate", 0.0)), int(float(node.get("utilization", 0.0)) * 100.0)], 12, COLOR_TEXT))
	var buffer: Dictionary = node.get("buffer", {}) if node.get("buffer", null) is Dictionary else {}
	if kind == "BUFFER":
		box.add_child(_label(I18n.core("industrial_network.inspector.buffer", "Available %d · Reserved %d · Inbound %.1f · Capacity %.0f") % [int(buffer.get("available", 0)), int(buffer.get("reserved", 0)), float(buffer.get("inbound", 0.0)), float(buffer.get("capacity", 0.0))], 12, COLOR_TEXT_SECONDARY))
		box.add_child(_label(I18n.core("industrial_network.inspector.net", "Net %.2f/h · Committed %.1f") % [float(buffer.get("net_rate", 0.0)), float(buffer.get("committed_demand", 0.0))], 12, COLOR_TEXT_SECONDARY))
	elif kind == "LOGISTICS":
		box.add_child(_label(I18n.core("industrial_network.inspector.logistics", "In transit %.1f · Capacity %.1f/h") % [float(buffer.get("in_transit", 0.0)), float(buffer.get("capacity", 0.0))], 12, COLOR_TEXT_SECONDARY))
	elif kind == "DEMAND":
		box.add_child(_label(I18n.core("industrial_network.inspector.demand", "Committed %.1f · Priority %d") % [float(buffer.get("backlog", buffer.get("quantity", 0.0))), int(buffer.get("priority", 50))], 12, COLOR_TEXT_SECONDARY))
	_add_network_port_inspector(box, I18n.core("industrial_network.inputs", "INPUTS"), node.get("inputs", []))
	_add_network_port_inspector(box, I18n.core("industrial_network.outputs", "OUTPUTS"), node.get("outputs", []))
	box.add_child(_separator())
	var open_button := _button(I18n.core("industrial_network.inspector.open", "Open detailed control"), _open_industrial_network_target.bind(node), false, COLOR_ACCENT)
	open_button.name = "IndustrialNetworkInspectorOpen"
	box.add_child(open_button)
	if kind == "PRODUCTION" and node.get("allowed_actions", []).has("STOP"):
		var slot := int(buffer.get("slot", -1))
		var stop_button := _button(I18n.core("common.stop"), _command.bind(I18n.core("command.stop_production"), Game.stop_industry_operation.bind(slot)), slot < 0, COLOR_WARN)
		stop_button.name = "IndustrialNetworkInspectorStop"
		stop_button.tooltip_text = I18n.core("industrial_network.inspector.stop_reason", "Stops this real production line through the command gateway")
		box.add_child(stop_button)
	var close_button := _button(I18n.core("industrial_network.inspector.close", "Close inspector"), _close_industrial_network_inspector, false, COLOR_MUTED)
	close_button.name = "IndustrialNetworkInspectorClose"
	box.add_child(close_button)


func _add_network_port_inspector(box: VBoxContainer, heading: String, ports_value) -> void:
	var ports: Array = ports_value if ports_value is Array else []
	if ports.is_empty():
		return
	box.add_child(_label(heading, 10, COLOR_MUTED))
	for port_value in ports:
		var port := port_value as Dictionary
		var item_id := String(port.get("item_id", ""))
		var title := String(port.get("title", _content_name(Game.content.items.get(item_id, {}), item_id)))
		box.add_child(_label(I18n.core("industrial_network.inspector.port_rate", "%s · %.2f/h") % [title, float(port.get("actual_rate", port.get("requested_rate", 0.0)))], 11, COLOR_TEXT_SECONDARY))


func _close_industrial_network_inspector() -> void:
	_selected_industrial_network_node.clear()
	_ui_state.select_context("location", _selected_location_id)
	if is_instance_valid(_industrial_network_view):
		_industrial_network_view.clear_selection()
	_rebuild_sidebar()


func _open_industrial_network_target(node: Dictionary) -> void:
	var target: Dictionary = node.get("navigation_target", {}) if node.get("navigation_target", null) is Dictionary else {}
	var page := String(target.get("page", "industry"))
	if target.has("location_id") and Game.state.has_location(String(target.get("location_id", ""))):
		_selected_location_id = String(target.get("location_id", _selected_location_id))
	if page == "industry":
		_industry_section = String(target.get("section", "production"))
		_industry_view_mode = String(target.get("view", "list"))
	elif page == "logistics" and target.has("route_id"):
		_logistics_route_focus_id = String(target.get("route_id", ""))
	_switch_page(page)


func _build_sidebar_footer(box: VBoxContainer) -> void:
	box.add_child(_separator())
	box.add_child(_section_title(I18n.core("sidebar.guide")))
	var guidance := Game.guidance_snapshot()
	var next_step := _next_flow_step()
	var guide := _rich(next_step, COLOR_ACCENT)
	guide.fit_content = true
	box.add_child(guide)
	var next_page := _next_flow_page()
	if not next_page.is_empty():
		var next_button := _button(I18n.core("sidebar.next"), _open_next_flow_target, false, COLOR_GOOD)
		next_button.name = "NextStepCTA"
		next_button.tooltip_text = String(guidance.get("reason", ""))
		box.add_child(next_button)
	box.add_child(_separator())
	if not Game.offline_report.is_empty():
		box.add_child(_section_title(I18n.core("sidebar.offline")))
		var report := Game.offline_report
		box.add_child(_rich(I18n.core("sidebar.offline_summary") % [_format_ms(int(report.get("simulated_ms", 0.0))), int(report.get("operations", 0)), _format_ms(int(report.get("unprocessed_ms", 0.0)))], COLOR_MUTED))
		box.add_child(_separator())
	var developer_toggle := _button(I18n.core("developer.hide", "Hide Developer Details") if _developer_details else I18n.core("developer.show", "Developer Details"), _toggle_developer_details, false, COLOR_MUTED)
	developer_toggle.name = "DeveloperDetailsToggle"
	box.add_child(developer_toggle)
	if _developer_details:
		box.add_child(_card_text(I18n.core("developer.snapshot") % [
			_selected_location_id, Game.state.total_elapsed_ms,
			String(guidance.get("goal_id", "")), String(guidance.get("step_id", "")),
			String(guidance.get("focus_entity_id", ""))
		], COLOR_MUTED))


func _rebuild_system_map() -> void:
	var box: VBoxContainer = _pages["system_map"]
	_clear(box)
	box.add_child(_page_title(I18n.core("system.title"), I18n.core("system.subtitle")))
	var map_locations: Array[Dictionary] = []
	for definition_value in Game.content.regions.values():
		var definition := definition_value as Dictionary
		var location_id := String(definition.get("id", ""))
		var location: Dictionary = Game.state.location_state(location_id)
		var discovered := not location.is_empty() and String(location.get("discovery_state", LocationState.UNDISCOVERED)) == LocationState.DISCOVERED
		var fleet_task_count := 0
		for ship_value in Game.state.ships:
			var ship := ship_value as Dictionary
			if String(ship.get("location_id", "")) == location_id and (not String(ship.get("fleet_assignment", "")).is_empty() or not (ship.get("assignment", {}) as Dictionary).is_empty()):
				fleet_task_count += 1
		var mega_here := false
		for project_value in Game.state.megastructure_projects.values():
			if String((project_value as Dictionary).get("site_id", "")) == location_id:
				mega_here = true
		map_locations.append({
			"id":location_id,
			"name":_location_name(location_id),
			"discovered":discovered,
			"survey_state":String(location.get("survey_state", LocationState.UNKNOWN)),
			"fleet_task_count":fleet_task_count,
			"megastructure":mega_here
		})
	var map_routes: Array[Dictionary] = []
	for route_value in Game.content.logistics_routes.values():
		var route := (route_value as Dictionary).duplicate(true)
		var from_location: Dictionary = Game.state.location_state(String(route.get("from", "")))
		var to_location: Dictionary = Game.state.location_state(String(route.get("to", "")))
		var route_id := String(route.get("id", ""))
		var service: Dictionary = Game.simulation.logistics.service_for_route(Game.state, route_id)
		var snapshot: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id)
		var endpoints_known := String(from_location.get("discovery_state", "")) == LocationState.DISCOVERED and String(to_location.get("discovery_state", "")) == LocationState.DISCOVERED
		route["active"] = endpoints_known and not service.is_empty() and float(snapshot.get("capacity_per_minute", 0.0)) > 0.0
		route["utilization"] = float(snapshot.get("utilization", 0.0))
		map_routes.append(route)
	var map_view := SystemMapViewScript.new()
	map_view.name = "SystemMap2D"
	map_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_view.location_selected.connect(_open_location)
	box.add_child(map_view)
	map_view.custom_minimum_size.y = 430.0 if get_window().size.y <= 800 else 560.0
	map_view.configure(map_locations, map_routes, _selected_location_id)

	box.add_child(_section_title(I18n.core("system.production_logistics")))
	for system_id in Game.simulation.known_system_ids(Game.state):
		var production: Dictionary = Game.simulation.system_production_overview(Game.state, system_id)
		var logistics: Dictionary = Game.simulation.system_logistics_overview(Game.state, system_id)
		var system_card := _card()
		system_card.add_child(_label(I18n.core("system.card_title") % system_id.to_upper(), 18, COLOR_ACCENT))
		system_card.add_child(_label(I18n.core("system.production_summary") % [int(production.get("location_count", 0)), int(production.get("stock_units", 0)), int(production.get("running_operations", 0)), int(production.get("blocked_operations", 0))], 13, COLOR_TEXT))
		var shipment_counts: Dictionary = logistics.get("shipment_counts", {})
		var shipment_units: Dictionary = logistics.get("shipment_units", {})
		system_card.add_child(_label(I18n.core("system.logistics_summary") % [int(logistics.get("internal_routes", 0)), int(logistics.get("external_routes", 0)), int(logistics.get("freight_capacity", 0)), int(logistics.get("policy_count", 0))], 13, COLOR_MUTED))
		system_card.add_child(_label(I18n.core("system.shipment_summary") % [int(shipment_counts.get("internal", 0)), int(shipment_counts.get("inbound", 0)), int(shipment_counts.get("outbound", 0)), int(shipment_units.get("internal", 0)), int(shipment_units.get("inbound", 0)), int(shipment_units.get("outbound", 0))], 13, COLOR_MUTED))
		var flow_lines: Array[String] = []
		for flow_value in production.get("flows", []):
			var flow := flow_value as Dictionary
			if int(flow.get("stock", 0)) <= 0 and int(flow.get("incoming", 0)) <= 0 and absf(float(flow.get("net_per_hour", 0.0))) < 0.001:
				continue
			flow_lines.append(I18n.core("system.flow_row") % [_content_name(Game.content.items.get(String(flow.get("item_id", "")), {}), String(flow.get("item_id", ""))), int(flow.get("stock", 0)), int(flow.get("incoming", 0)), float(flow.get("net_per_hour", 0.0))])
		if not flow_lines.is_empty():
			system_card.add_child(_rich("\n".join(flow_lines.slice(0, 8)), COLOR_MUTED))
		box.add_child(_wrap_card(system_card))


func _open_location(location_id: String) -> void:
	if not Game.state.has_location(location_id):
		return
	_selected_location_id = location_id
	_location_section = "overview"
	_save_ui_preferences()
	_switch_page("location")


func _open_location_section(location_id: String, section: String) -> void:
	if not Game.state.has_location(location_id):
		return
	_selected_location_id = location_id
	_location_section = section
	_save_ui_preferences()
	_switch_page("location")


func _select_location_section(section: String) -> void:
	_location_section = section
	_save_ui_preferences()
	_request_active_page_refresh(true)


func _rebuild_location() -> void:
	var box: VBoxContainer = _pages["location"]
	_clear(box)
	var location: Dictionary = Game.state.location_state(_selected_location_id)
	if location.is_empty():
		box.add_child(_page_title(I18n.core("location.title"), I18n.core("location.select_known")))
		return
	box.add_child(_page_title(_location_name(_selected_location_id), I18n.core("location.subtitle") % [_status_text(String(location.get("type", "UNKNOWN"))), _system_name(String(location.get("system_id", "UNKNOWN")))]))
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	for section in ["overview", "resources", "industry", "logistics", "projects"]:
		var captions := {"overview":I18n.core("location.tab.overview"), "resources":I18n.core("location.tab.resources"), "industry":I18n.core("location.tab.industry"), "logistics":I18n.core("location.tab.logistics"), "projects":I18n.core("location.tab.projects")}
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
	var intelligence: Dictionary = Game.simulation.location_intelligence(Game.state, _selected_location_id)
	var survey_state := String(intelligence.get("survey_state", LocationState.UNKNOWN))
	box.add_child(_section_title(I18n.core("location.info")))
	box.add_child(_card_text(I18n.core("location.identity_summary") % [_status_text(String(location.get("type", "UNKNOWN"))), _system_name(String(location.get("system_id", "UNKNOWN"))), _status_text(survey_state)], COLOR_TEXT))
	var next_states := {LocationState.UNKNOWN:LocationState.DETECTED, LocationState.DETECTED:LocationState.SURVEYED, LocationState.SURVEYED:LocationState.DEEP_SURVEYED}
	if next_states.has(survey_state):
		var next_state := String(next_states[survey_state])
		var costs: Dictionary = Game.simulation.survey_mission_costs(next_state)
		box.add_child(_label(I18n.core("survey.select_vessel", "Select a Survey Vessel") + " · " + _resource_dictionary(costs), 13, COLOR_ACCENT))
		var eligible_found := false
		for ship_value in Game.state.ships:
			var ship := ship_value as Dictionary
			var ship_id := String(ship.get("instance_id", ""))
			var availability: Dictionary = Game.survey_mission_availability(_selected_location_id, next_state, [ship_id])
			if (availability.get("blockers", []) as Array).any(func(blocker): return String((blocker as Dictionary).get("code", "")) in ["SURVEY_VESSEL_UNAVAILABLE", "SURVEY_VESSEL_REQUIRED"]):
				continue
			eligible_found = true
			var survey_button := _button(I18n.core("location.survey_action") % [String(ship.get("name", ship_id)), I18n.core("survey.start", "Start %s mission") % _status_text(next_state)], _command.bind(I18n.core("command.start_survey"), Game.start_survey_mission.bind(_selected_location_id, next_state, [ship_id])), not bool(availability.get("allowed", false)), COLOR_ACCENT)
			survey_button.name = "StartSurvey_%s_%s_%s" % [_selected_location_id, next_state, ship_id]
			survey_button.tooltip_text = _availability_reason(availability)
			box.add_child(survey_button)
		if not eligible_found:
			var availability: Dictionary = Game.survey_mission_availability(_selected_location_id, next_state)
			var missing_button := _button(I18n.core("survey.no_vessel", "No eligible Survey Vessel"), Callable(), true, COLOR_WARN)
			missing_button.tooltip_text = _availability_reason(availability)
			box.add_child(missing_button)
		if String(Game.state.survey_mission.get("status", "IDLE")) == "RUNNING":
			var mission: Dictionary = Game.state.survey_mission
			box.add_child(_label(I18n.core("location.survey_progress") % [mission.get("target", ""), _status_text(String(mission.get("target_state", ""))), 100.0 * float(mission.get("progress_ms", 0.0)) / maxf(1.0, float(mission.get("duration_ms", 1.0)))], 13, COLOR_WARN))
	var environment: Dictionary = intelligence.get("environment", {})
	if survey_state == LocationState.DETECTED:
		box.add_child(_section_title(I18n.core("location.environment.preliminary")))
		box.add_child(_card_text(I18n.core("location.environment.detected") % [_status_text(String(environment.get("radiation", "UNKNOWN"))), _status_text(String(environment.get("transport_distance_band", "UNKNOWN"))), _status_text(String(environment.get("construction_difficulty_band", "UNKNOWN")))], COLOR_MUTED))
	elif survey_state in [LocationState.SURVEYED, LocationState.DEEP_SURVEYED]:
		box.add_child(_section_title(I18n.core("location.environment.conditions")))
		box.add_child(_card_text(I18n.core("location.environment.surveyed") % [float(environment.get("gravity", 0.0)), I18n.core("location.environment.vacuum") if bool(environment.get("vacuum", false)) else I18n.core("location.environment.non_vacuum"), _status_text(String(environment.get("atmosphere", "UNKNOWN"))), float(environment.get("solar_flux", 0.0)), _status_text(String(environment.get("thermal_environment", "UNKNOWN"))), _status_text(String(environment.get("radiation", "UNKNOWN"))), float(environment.get("construction_difficulty", 1.0)), float(environment.get("transport_distance", 0.0))], COLOR_MUTED))
	if survey_state == LocationState.UNKNOWN:
		box.add_child(_card_text(I18n.core("location.intelligence_unknown"), COLOR_MUTED))
		return
	box.add_child(_section_title(I18n.core("location.local_inventory")))
	var lines: Array[String] = []
	for item_value in Game.state.location_inventory(_selected_location_id).keys():
		var item_id := String(item_value)
		var quantity := Game.state.item_quantity(item_id, _selected_location_id)
		if quantity > 0:
			lines.append(I18n.core("format.item_quantity") % [_content_name(Game.content.items.get(item_id, {}), item_id), quantity])
	lines.sort()
	box.add_child(_card_text("\n".join(lines) if not lines.is_empty() else I18n.core("location.inventory_empty"), COLOR_TEXT))
	var power: Dictionary = location.get("power", {})
	var power_text := _status_text(String(power.get("status", "UNKNOWN")))
	if power.has("generation_capacity"):
		power_text = I18n.core("location.power_summary") % [float(power.get("generation_capacity", 0.0)), float(power.get("current_demand", 0.0)), float(power.get("available_capacity", 0.0))]
	box.add_child(_section_title(I18n.core("location.energy")))
	box.add_child(_card_text(power_text, COLOR_TEXT))
	var industry: Dictionary = location.get("industry_summary", {})
	box.add_child(_section_title(I18n.core("location.industry")))
	box.add_child(_card_text(I18n.core("location.industry_summary") % [_status_text(String(industry.get("status", "UNKNOWN"))), industry.get("active_facilities", 0), industry.get("active_operations", 0)], COLOR_TEXT))
	box.add_child(_section_title(I18n.core("location.operations")))
	box.add_child(_card_text(I18n.core("location.operations_summary") % [_status_text(String(location.get("logistics_summary", {}).get("status", "NOT_CONNECTED"))), int(location.get("projects_summary", {}).get("active_count", 0)), location.get("fleet_presence", []).size()], COLOR_TEXT))


func _build_location_resources(box: VBoxContainer, _location: Dictionary) -> void:
	box.add_child(_section_title(I18n.core("location.resources.known_sites", "Mapped tile resource fields")))
	var intelligence: Dictionary = Game.simulation.location_intelligence(Game.state, _selected_location_id)
	var survey_state := String(intelligence.get("survey_state", LocationState.UNKNOWN))
	var resources: Array = intelligence.get("resources", [])
	if resources.is_empty():
		box.add_child(_card_text(I18n.core("location.resources.none_visible"), COLOR_MUTED))
		return
	for profile_value in resources:
		var profile := profile_value as Dictionary
		var card := _card()
		var resource_field_id := String(profile.get("resource_field_id", ""))
		var resource_id := String(profile.get("resource_type", ""))
		var title := I18n.category(String(profile.get("resource_category", "UNKNOWN"))) if resource_id.is_empty() else _content_name(Game.content.items.get(resource_id, {}), resource_id)
		card.add_child(_label(title, 16, COLOR_TEXT))
		if survey_state == LocationState.DETECTED:
			card.add_child(_label(I18n.core("location.resources.grid_detected", "Tile resource signal · %s · potential %s") % [I18n.category(String(profile.get("resource_category", "UNKNOWN"))), _status_text(String(profile.get("potential_band", "UNKNOWN")))], 13, COLOR_MUTED))
		else:
			card.add_child(_label(I18n.core("location.resources.grid_surveyed", "Resource field %s · grade %.2f · mapped potential %.1f/h") % [resource_field_id, float(profile.get("grade", 0.0)), float(profile.get("mapped_potential_per_hour", 0.0))], 13, COLOR_MUTED))
			if survey_state == LocationState.DEEP_SURVEYED:
				var footprint: Dictionary = profile.get("footprint", {}).get("size", {})
				card.add_child(_label(I18n.core("location.resources.grid_deep_surveyed", "Exact footprint %d × %d m · fixed world resource") % [int(footprint.get("x", 0)), int(footprint.get("y", 0))], 13, COLOR_ACCENT))
		box.add_child(_wrap_card(card))


func _build_location_industry(box: VBoxContainer, location: Dictionary) -> void:
	var summary: Dictionary = location.get("industry_summary", {})
	box.add_child(_card_text(I18n.core("location.industry.status_summary") % [_status_text(String(summary.get("status", "NOT_AVAILABLE"))), summary.get("active_facilities", 0), summary.get("active_operations", 0)], COLOR_TEXT))
	var local_logistics: Dictionary = summary.get("local_logistics", {})
	box.add_child(_card_text(I18n.core("location.industry.local_logistics") % [_status_text(String(local_logistics.get("status", "NOT_AVAILABLE"))), float(local_logistics.get("required", 0.0)), float(local_logistics.get("capacity", 0.0)), float(local_logistics.get("utilization", 0.0)) * 100.0], COLOR_WARN if str(local_logistics.get("status", "")) == "CONSTRAINED" else COLOR_MUTED))
	var constraints: Dictionary = summary.get("constraints", {})
	box.add_child(_card_text(I18n.core("location.industry.constraints") % [float(constraints.get("power_demand", 0.0)), float(constraints.get("power_capacity", 0.0)), I18n.core("location.industry.cooling_required") if bool(constraints.get("cooling_required", false)) else I18n.core("location.industry.cooling_not_required"), float(constraints.get("cooling_demand", 0.0)), float(constraints.get("cooling_capacity", 0.0)), float(constraints.get("structural_used", 0.0)), float(constraints.get("structural_capacity", 0.0)), float(constraints.get("throughput_multiplier", 0.0)) * 100.0], COLOR_WARN if str(constraints.get("status", "")) == "CONSTRAINED" else COLOR_MUTED))
	box.add_child(_card_text(I18n.core("location.industry.domain_contract"), COLOR_MUTED))
	box.add_child(_section_title(I18n.core("industry.templates", "Industrial policy templates")))
	var template_card := _card()
	var automation: Dictionary = location.get("automation", {})
	var active_template_id := String(automation.get("industrial_template_id", ""))
	template_card.add_child(_label(I18n.core("industry.template_current", "Current template") + " · " + (_content_name(Game.content.industrial_templates.get(active_template_id, {}), active_template_id) if not active_template_id.is_empty() else I18n.core("status.NONE", "None")), 13, COLOR_ACCENT if not active_template_id.is_empty() else COLOR_MUTED))
	var template_selector := OptionButton.new()
	template_selector.name = "IndustrialTemplateSelector"
	var template_ids: Array = Game.content.industrial_templates.keys()
	template_ids.sort()
	for template_id_value in template_ids:
		var template_id := String(template_id_value)
		var template: Dictionary = Game.content.industrial_templates.get(template_id, {})
		template_selector.add_item(_content_name(template, template_id))
		if template_id == active_template_id:
			template_selector.select(template_selector.item_count - 1)
	template_card.add_child(template_selector)
	var template_actions := HFlowContainer.new()
	template_actions.add_theme_constant_override("h_separation", 6)
	var apply_template := _button(I18n.core("industry.template_apply", "Apply template"), _apply_selected_industrial_template.bind(template_selector, template_ids), template_ids.is_empty(), COLOR_GOOD)
	apply_template.name = "ApplyIndustrialTemplate"
	template_actions.add_child(apply_template)
	var clear_template := _button(I18n.core("industry.template_clear", "Clear template"), _command.bind(I18n.core("command.clear_industrial_template"), Game.clear_location_industrial_template.bind(_selected_location_id)), active_template_id.is_empty(), COLOR_WARN)
	clear_template.name = "ClearIndustrialTemplate"
	template_actions.add_child(clear_template)
	if not active_template_id.is_empty():
		var target_level := int(automation.get("target_level", Game.content.industrial_templates.get(active_template_id, {}).get("auto_expand_target", 5)))
		var automation_enabled := bool(automation.get("enabled", false))
		template_actions.add_child(_button(I18n.core("industry.template_pause", "Pause managed expansion") if automation_enabled else I18n.core("industry.template_resume", "Resume managed expansion"), _command.bind(I18n.core("command.toggle_template_expansion"), Game.configure_location_industrial_automation.bind(_selected_location_id, not automation_enabled, target_level)), false, COLOR_ACCENT))
	template_card.add_child(template_actions)
	template_card.add_child(_label(I18n.core("industry.template_help", "Templates set explainable logistics policies and an authorized expansion target; they do not create materials or bypass Construction."), 12, COLOR_MUTED))
	box.add_child(_wrap_card(template_card))
	var developing_facilities: Array[Dictionary] = []
	for project_value in Game.state.construction_operations:
		var project := project_value as Dictionary
		if String(project.get("location_id", "")) != _selected_location_id or String(project.get("project_type", "")) not in ["FACILITY_BUILD", "FACILITY_EXPANSION", "SCALE_STAGE_UPGRADE"] or String(project.get("status", "")) not in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			continue
		developing_facilities.append(project)
	if not developing_facilities.is_empty():
		box.add_child(_section_title(I18n.core("industry.development.title", "Factories under Construction")))
		for project in developing_facilities:
			var project_id := String(project.get("project_id", "PROJECT"))
			var target_id := String(project.get("target_id", project.get("facility_id", "")))
			var development_card := _card()
			development_card.add_child(_label(I18n.core("industry.development.summary", "%s · %s") % [_content_name(Game.content.facilities.get(target_id, {}), target_id), _status_text("BUILDING")], 15, COLOR_ACCENT))
			development_card.add_child(_label(I18n.core("industry.development.project", "Project %s · %s") % [project_id, _construction_project_type_name(String(project.get("project_type", "FACILITY_BUILD")))], 12, COLOR_MUTED))
			development_card.add_child(_operation_progress(project, I18n.core("construction.status") % _status_text(Game.simulation.construction_gameplay_state(project))))
			development_card.add_child(_label(I18n.core("construction.materials") % [_resource_dictionary(project.get("material_plan", {})), _resource_dictionary(project.get("consumed", {})), _resource_dictionary(project.get("delivered_materials", {})), _resource_dictionary(project.get("in_transit_materials", {}))], 12, COLOR_MUTED))
			var open_project := _button(I18n.core("industry.development.open_construction", "Open Construction Project"), _open_production_construction.bind(project_id), false, COLOR_ACCENT)
			open_project.name = "OpenProductionConstruction_%s" % project_id
			development_card.add_child(open_project)
			box.add_child(_wrap_card(development_card))
	box.add_child(_section_title(I18n.core("location.industry.local")))
	for facility_value in SpaceGameState.MANUFACTURING_FACILITY_IDS:
		var facility_id := String(facility_value)
		if not Game.simulation.facility_available(Game.state, facility_id):
			continue
		var facility: Dictionary = Game.content.facilities.get(facility_id, {})
		var local_industry: Dictionary = Game.state.location_industry(_selected_location_id, facility_id)
		var level := int(local_industry.get("level", 0))
		var scale_stage := String(local_industry.get("scale_stage", "WORKSHOP"))
		var scale_names := {"WORKSHOP":I18n.core("industry.scale.WORKSHOP"), "FACTORY":I18n.core("industry.scale.FACTORY"), "INDUSTRIAL_COMPLEX":I18n.core("industry.scale.INDUSTRIAL_COMPLEX"), "AUTOMATED_DISTRICT":I18n.core("industry.scale.AUTOMATED_DISTRICT")}
		var lines := Game.state.production_lines_for(_selected_location_id, facility_id)
		var card := _card()
		card.add_child(_label(I18n.core("location.industry.facility_summary") % [_content_name(facility, facility_id), level, scale_names.get(scale_stage, scale_stage), Game.simulation.facility_manufacturing_throughput(Game.state, facility_id, _selected_location_id), lines.size(), Game.simulation.max_production_lines(Game.state, _selected_location_id, facility_id)], 16, COLOR_TEXT))
		if level > 0:
			for runtime_value in lines:
				var runtime := runtime_value as Dictionary
				var current_activity_id := String(runtime.get("activity_id", ""))
				if current_activity_id.is_empty():
					current_activity_id = String(runtime.get("method_id", ""))
				var mastery := Game.simulation.industry_mastery_profile(Game.state, _selected_location_id, facility_id, current_activity_id)
				var device_id := String(runtime.get("production_device_id", ""))
				var method_name := _content_name(Game.content.activities.get(current_activity_id, {}), I18n.core("status.NOT_CONFIGURED"))
				var status_id := Game.simulation.production_gameplay_state(Game.state, runtime)
				card.add_child(_label(I18n.core("location.industry.line_summary") % [String(runtime.get("line_id", "LINE")), _status_text(status_id), method_name, device_id if not device_id.is_empty() else I18n.core("status.NOT_INSTALLED"), _status_text(String(runtime.get("control_mode", "PINNED"))), int(runtime.get("priority", 50)), float(runtime.get("theoretical_rate", 0.0)), float(runtime.get("actual_rate", 0.0)), int(mastery.get("mastery_level", 0))], 13, COLOR_WARN if status_id.begins_with("BLOCKED") or status_id.ends_with("LIMITED") else COLOR_MUTED))
				_add_blocker_label(card, runtime)
				var control_row := HFlowContainer.new()
				control_row.add_theme_constant_override("h_separation", 6)
				var slot := int(runtime.get("slot", -1))
				var mode := String(runtime.get("control_mode", "PINNED"))
				var manual_lock := bool(runtime.get("manual_lock", true))
				var capability_disabled := status_id == "DISABLED"
				var run_pinned := _button(I18n.core("industry.line.run_pinned"), _command.bind(I18n.core("command.pin_production_method"), Game.set_production_line_control.bind(slot, "PINNED", manual_lock)), mode == "PINNED" or capability_disabled, COLOR_ACCENT)
				run_pinned.name = "RunProductionLine_%d" % slot
				if capability_disabled:
					run_pinned.tooltip_text = I18n.core("industry.line.disabled_tooltip", "Install the required production device or choose a compatible method.")
				control_row.add_child(run_pinned)
				control_row.add_child(_button(I18n.core("industry.line.turn_off"), _command.bind(I18n.core("command.stop_production_line"), Game.set_production_line_control.bind(slot, "OFF", manual_lock)), mode == "OFF", COLOR_WARN))
				control_row.add_child(_button(I18n.core("industry.line.manual_lock") % (I18n.core("common.yes") if manual_lock else I18n.core("common.no")), _command.bind(I18n.core("command.toggle_manual_lock"), Game.set_production_line_control.bind(slot, mode, not manual_lock)), false, COLOR_GOOD if manual_lock else COLOR_MUTED))
				control_row.add_child(_button(I18n.core("industry.line.high_priority"), _command.bind(I18n.core("command.raise_line_priority"), Game.configure_production_line.bind(slot, 100, 100)), int(runtime.get("priority", 50)) == 100, COLOR_ACCENT))
				control_row.add_child(_button(I18n.core("industry.line.normal_priority"), _command.bind(I18n.core("command.restore_line_priority"), Game.configure_production_line.bind(slot, 100, 50)), int(runtime.get("priority", 50)) == 50))
				if capability_disabled:
					var open_capability := _button(I18n.core("industry.line.open_capability", "Open Facility Configuration"), _open_production_capability.bind(_selected_location_id), false, COLOR_WARN)
					open_capability.name = "OpenProductionCapability_%d" % slot
					control_row.add_child(open_capability)
				card.add_child(control_row)
				# `production_gameplay_state()` intentionally projects an unused IDLE
				# runtime as PAUSED.  Configuration availability, however, belongs to
				# the authoritative raw runtime status; otherwise a legal empty line has
				# no player surface for choosing its first Production Method.
				if String(runtime.get("status", "IDLE")) == "IDLE" or current_activity_id.is_empty():
					for activity_value in Game.content.activities.values():
						var activity := activity_value as Dictionary
						var activity_id := String(activity.get("id", ""))
						if String(activity.get("domain", "")) != "industry" or Game.simulation.is_construction_activity(activity) or Game.content.is_module_bom_activity(activity) or String(activity.get("facility", "")) != facility_id or not Game.simulation.definition_revealed(Game.state, activity):
							continue
						var scale_blocked := not Game.simulation.production_method_available_at_scale(Game.state, _selected_location_id, facility_id, activity)
						var method_button := _button(I18n.core("industry.line.select_method") % [_content_name(activity, activity_id), I18n.core("industry.line.higher_scale_required") if scale_blocked else ""], _command.bind(I18n.core("command.set_production_method"), Game.start_industry_operation.bind(slot, activity_id)), scale_blocked or not Game.simulation.activity_available(Game.state, activity))
						method_button.name = "SelectProductionMethod_%d_%s" % [slot, activity_id]
						card.add_child(method_button)
			var line_capacity := Game.simulation.max_production_lines(Game.state, _selected_location_id, facility_id)
			var line_capacity_full := lines.size() >= line_capacity
			card.add_child(_label(I18n.core("industry.line.capacity_full", "Production-line capacity is full. Upgrade the Factory scale stage to add another line.") if line_capacity_full else I18n.core("industry.line.add_help"), 13, COLOR_WARN if line_capacity_full else COLOR_ACCENT))
			for activity_value in Game.content.activities.values():
				var activity := activity_value as Dictionary
				var activity_id := String(activity.get("id", ""))
				if String(activity.get("domain", "")) != "industry" or Game.simulation.is_construction_activity(activity) or Game.content.is_module_bom_activity(activity) or String(activity.get("facility", "")) != facility_id or not Game.simulation.definition_revealed(Game.state, activity):
					continue
				var activity_blocked := not Game.simulation.activity_available(Game.state, activity) or not Game.simulation.production_method_available_at_scale(Game.state, _selected_location_id, facility_id, activity)
				var add_line_button := _button(I18n.core("industry.line.add") % _content_name(activity, activity_id), _command.bind(I18n.core("command.add_production_line"), Game.add_production_line.bind(_selected_location_id, facility_id, activity_id, 50, 50)), line_capacity_full or activity_blocked)
				add_line_button.name = "AddProductionLine_%s_%s" % [facility_id, activity_id]
				if line_capacity_full:
					add_line_button.tooltip_text = I18n.core("industry.line.capacity_full", "Production-line capacity is full. Upgrade the Factory scale stage to add another line.")
				card.add_child(add_line_button)
		var expansion_row := HBoxContainer.new()
		expansion_row.add_theme_constant_override("separation", 6)
		var stage_definition: Dictionary = Game.simulation.industry_scale_stage_definition(scale_stage)
		var stage_max_level := int(stage_definition.get("max_level", 4))
		for amount in [1, 5, 10]:
			var expansion_button := _button(I18n.core("industry.expansion.queue") % amount, _command.bind(I18n.core("command.expand_local_industry"), Game.expand_location_industry.bind(_selected_location_id, facility_id, amount)), level + amount > stage_max_level)
			expansion_button.name = "ExpandIndustry_%s_%d" % [facility_id, amount]
			expansion_button.tooltip_text = I18n.core("construction.inputs") % _resource_dictionary(Game.simulation.industry_expansion_costs(Game.state, _selected_location_id, facility_id, amount))
			expansion_row.add_child(expansion_button)
		var next_stage := String(stage_definition.get("next_stage", ""))
		if level >= stage_max_level and not next_stage.is_empty():
			var scale_button := _button(I18n.core("industry.expansion.scale_transition") % scale_names.get(next_stage, next_stage), _command.bind(I18n.core("command.scale_stage_transition"), Game.queue_scale_stage_upgrade.bind(_selected_location_id, facility_id, 70)), Game.simulation.construction_queue_size(Game.state) >= Game.simulation.construction_queue_capacity(Game.state), COLOR_ACCENT)
			scale_button.name = "UpgradeScaleStage_%s_%s_%s" % [_selected_location_id, facility_id, next_stage]
			expansion_row.add_child(scale_button)
		card.add_child(expansion_row)
		box.add_child(_wrap_card(card))
	var mastered_transformations: Array[String] = []
	for transformation_id_value in Game.content.industry_rules.get("industrial_transformations", {}).keys():
		var transformation_id := String(transformation_id_value)
		if bool(Game.state.unlocked_industrial_transformations.get(transformation_id, false)):
			mastered_transformations.append(transformation_id)
	if not mastered_transformations.is_empty():
		box.add_child(_section_title(I18n.core("industry.transformation.title")))
		for transformation_id in mastered_transformations:
			var transformation: Dictionary = Game.content.industry_rules.get("industrial_transformations", {}).get(transformation_id, {})
			var transformation_card := _card()
			var adopted := bool(Game.state.adopted_industrial_transformations.get(transformation_id, false))
			var transformation_name := I18n.t("industrial_transformation.%s.name" % transformation_id, String(transformation.get("name", transformation_id)))
			var transformation_description := I18n.t("industrial_transformation.%s.description" % transformation_id, String(transformation.get("description", "")))
			transformation_card.add_child(_label(I18n.core("industry.transformation.status") % [transformation_name, I18n.core("industry.transformation.adopted") if adopted else I18n.core("industry.transformation.available")], 15, COLOR_GOOD if adopted else COLOR_ACCENT))
			transformation_card.add_child(_label(I18n.core("industry.transformation.details") % [transformation_description, _resource_list(transformation.get("costs", [])), float(transformation.get("downtime_multiplier", 0.5)) * 100.0], 12, COLOR_MUTED))
			var transformation_button := _button(I18n.core("industry.transformation.start"), _command.bind(I18n.core("command.start_industrial_transformation"), Game.queue_industrial_transformation.bind(transformation_id, 70)), adopted, COLOR_ACCENT)
			transformation_button.name = "AdoptIndustrialTransformation_%s" % transformation_id
			transformation_card.add_child(transformation_button)
			box.add_child(_wrap_card(transformation_card))
	box.add_child(_section_title(I18n.core("industry.capacity.title")))
	var capacity_card := _card()
	capacity_card.add_child(_label(I18n.core("industry.capacity.help"), 13, COLOR_MUTED))
	var storage_snapshot: Dictionary = Game.simulation.location_storage_snapshot(Game.state, _selected_location_id)
	var storage_classes: Dictionary = storage_snapshot.get("classes", {})
	var capacity_values := {
		"POWER_UPGRADE":int(location.get("industry", {}).get("power_capacity", 0)),
		"COOLING_UPGRADE":int(location.get("industry", {}).get("cooling_capacity", 0)),
		"STRUCTURE_UPGRADE":int(location.get("industry", {}).get("structural_capacity", 0)),
		"BULK_STORAGE_UPGRADE":int(storage_classes.get("BULK", {}).get("capacity", 0)),
		"COMPONENT_STORAGE_UPGRADE":int(storage_classes.get("COMPONENT", {}).get("capacity", 0)),
		"FLUID_STORAGE_UPGRADE":int(storage_classes.get("FLUID", {}).get("capacity", 0)),
		"SPECIAL_STORAGE_UPGRADE":int(storage_classes.get("SPECIAL", {}).get("capacity", 0)),
		"LOGISTICS_HUB_UPGRADE":int(location.get("logistics", {}).get("hub_throughput", 0))
	}
	var capacity_names := {"POWER_UPGRADE":I18n.core("industry.capacity.power"), "COOLING_UPGRADE":I18n.core("industry.capacity.cooling"), "STRUCTURE_UPGRADE":I18n.core("industry.capacity.structure"), "BULK_STORAGE_UPGRADE":I18n.core("industry.capacity.bulk_storage"), "COMPONENT_STORAGE_UPGRADE":I18n.core("industry.capacity.component_storage"), "FLUID_STORAGE_UPGRADE":I18n.core("industry.capacity.fluid_storage"), "SPECIAL_STORAGE_UPGRADE":I18n.core("industry.capacity.special_storage"), "LOGISTICS_HUB_UPGRADE":I18n.core("industry.capacity.logistics_hub")}
	var capacity_actions := HFlowContainer.new()
	capacity_actions.add_theme_constant_override("h_separation", 6)
	for project_type_value in capacity_values.keys():
		var project_type := String(project_type_value)
		# Domain owns both the legal increment and the strategic batch size. This
		# keeps large mature depots from requiring ten identical clicks without
		# teaching the UI any construction or economy formula.
		var target := Game.simulation.suggested_location_capacity_upgrade_target(Game.state, _selected_location_id, project_type)
		var queue_full := Game.simulation.construction_queue_size(Game.state) >= Game.simulation.construction_queue_capacity(Game.state)
		var capacity_button := _button(I18n.core("industry.capacity.target") % [capacity_names.get(project_type, project_type), target], _command.bind(I18n.core("command.queue_capacity_project"), Game.queue_location_capacity_upgrade.bind(_selected_location_id, project_type, target, 50)), queue_full)
		capacity_button.name = "UpgradeLocationCapacity_%s_%s_%d" % [_selected_location_id, project_type, target]
		if queue_full:
			capacity_button.tooltip_text = I18n.t("notice.construction_queue_full", "The construction queue is full")
		capacity_actions.add_child(capacity_button)
	capacity_card.add_child(capacity_actions)
	box.add_child(_wrap_card(capacity_card))


func _apply_selected_industrial_template(selector: OptionButton, template_ids: Array) -> void:
	if selector.selected < 0 or selector.selected >= template_ids.size():
		return
	_command(I18n.core("command.apply_industrial_template"), Game.apply_location_industrial_template.bind(_selected_location_id, String(template_ids[selector.selected])))


func _build_location_logistics(box: VBoxContainer, location: Dictionary) -> void:
	var summary: Dictionary = location.get("logistics_summary", {})
	var logistics: Dictionary = location.get("logistics", {})
	var logistics_technology: Dictionary = summary.get("technology_profile", Game.simulation.logistics.technology_profile(Game.state))
	var storage_snapshot: Dictionary = Game.simulation.location_storage_snapshot(Game.state, _selected_location_id)
	box.add_child(_card_text(I18n.core("location.logistics.summary") % [
		_status_text(String(summary.get("status", "NOT_CONNECTED"))),
		int(summary.get("route_count", 0)),
		int(summary.get("inbound_shipments", 0)),
		int(summary.get("outbound_shipments", 0)),
		float(storage_snapshot.get("used", 0.0)),
		float(storage_snapshot.get("capacity", 0.0)),
		int(logistics.get("hub_throughput", 0)),
		_status_text(String(logistics_technology.get("name", "CHEMICAL_CARGO"))),
		float(logistics_technology.get("freight_capacity_multiplier", 1.0)),
		float(logistics_technology.get("transit_time_multiplier", 1.0)),
		float(logistics_technology.get("fuel_cost_multiplier", 1.0)),
		float(logistics_technology.get("energy_per_route_unit", 0.0)),
		float(logistics_technology.get("loading_time_ms_per_unit", 40.0))
	], COLOR_TEXT))
	for storage_class in ["BULK", "COMPONENT", "FLUID", "SPECIAL"]:
		var class_row: Dictionary = storage_snapshot.get("classes", {}).get(storage_class, {})
		box.add_child(_label(I18n.core("location.logistics.storage_class") % [_status_text(storage_class), float(class_row.get("used", 0.0)), float(class_row.get("capacity", 0.0)), float(class_row.get("utilization", 0.0)) * 100.0], 12, COLOR_WARN if float(class_row.get("utilization", 0.0)) >= 0.9 else COLOR_MUTED))
	box.add_child(_card_text(I18n.core("location.logistics.capacity_help"), COLOR_MUTED))

	box.add_child(_section_title(I18n.core("location.logistics.route_services")))
	var connected_routes := _connected_logistics_routes(_selected_location_id)
	if connected_routes.is_empty():
		box.add_child(_card_text(I18n.core("location.logistics.no_routes"), COLOR_MUTED))
	for route_value in connected_routes:
		var route := route_value as Dictionary
		var route_id := String(route.get("id", ""))
		var service: Dictionary = Game.simulation.logistics.service_for_route(Game.state, route_id)
		var service_snapshot: Dictionary = Game.simulation.logistics.service_snapshot(Game.state, route_id)
		var current_mode: Dictionary = Game.content.transport_modes.get(String(service.get("transport_mode_id", "")), {})
		var service_card := _card()
		if route_id == _logistics_route_focus_id:
			service_card.add_child(_label(I18n.core("diagnostics.focused_route", "Focused route · %s") % _content_name(route, route_id), 12, COLOR_ACCENT))
		var service_status := String(service_snapshot.get("status", "ACTIVE"))
		var service_color := COLOR_BAD if service_status == "NO_TRANSPORT" else (COLOR_WARN if service_status == "SATURATED" else (COLOR_ACCENT if service_status == "ACTIVE" else COLOR_MUTED))
		service_card.add_child(_label(I18n.core("location.logistics.service_header") % [_content_name(route, route_id), _content_name(current_mode, String(service.get("transport_mode_id", ""))), _status_text(service_status)], 16, service_color))
		service_card.add_child(_label(I18n.core("location.logistics.service_summary") % [float(service_snapshot.get("capacity_per_dispatch", 0.0)), float(service_snapshot.get("capacity_per_minute", 0.0)), float(service_snapshot.get("utilization", 0.0)) * 100.0, int(service_snapshot.get("allocated_ships", 0)), I18n.core("location.logistics.infrastructure_capacity") if bool(current_mode.get("infrastructure_service", false)) else I18n.core("location.logistics.ship_public_capacity"), _logistics_priority_text(String(service.get("priority_strategy", "DEMAND_PRIORITY")))], 13, COLOR_MUTED))
		var service_paused := String(service.get("status", "ACTIVE")) == "PAUSED"
		var service_pause_button := _button(I18n.core("location.logistics.resume_route") if service_paused else I18n.core("location.logistics.pause_route"), _command.bind(I18n.core("command.resume_logistics_route") if service_paused else I18n.core("command.pause_logistics_route"), Game.set_logistics_service_paused.bind(route_id, not service_paused)), false, COLOR_ACCENT if service_paused else COLOR_WARN)
		service_pause_button.name = "%sLogisticsRoute_%s" % ["Resume" if service_paused else "Pause", route_id]
		service_card.add_child(service_pause_button)
		var supported_names: Array[String] = []
		for freight_class_value in current_mode.get("supported_freight_classes", []):
			supported_names.append(String(freight_class_value))
		service_card.add_child(_label(I18n.core("location.logistics.supported_classes") % I18n.core("format.slash_separator").join(supported_names), 12, COLOR_MUTED))
		var mode_actions := HFlowContainer.new()
		mode_actions.add_theme_constant_override("h_separation", 6)
		for mode_value in Game.content.transport_modes.values():
			var candidate_mode := mode_value as Dictionary
			var mode_id := String(candidate_mode.get("id", ""))
			var required_technology := String(candidate_mode.get("required_technology", ""))
			var unavailable := not required_technology.is_empty() and not bool(Game.state.technologies.get(required_technology, false))
			if not bool(candidate_mode.get("infrastructure_service", false)) and not bool(candidate_mode.get("public_base_capacity", false)):
				unavailable = unavailable or _eligible_logistics_ship_ids(candidate_mode, service).is_empty()
			var mode_button: Button = _button(_content_name(candidate_mode, mode_id), _configure_route_transport_mode.bind(route_id, mode_id), unavailable, COLOR_ACCENT if mode_id == String(service.get("transport_mode_id", "")) else COLOR_MUTED)
			mode_button.name = "TransportMode_%s_%s" % [route_id, mode_id]
			mode_button.tooltip_text = _transport_mode_requirement_text(candidate_mode)
			mode_actions.add_child(mode_button)
		service_card.add_child(mode_actions)
		if not bool(current_mode.get("infrastructure_service", false)):
			var eligible_current_ships := _eligible_logistics_ship_ids(current_mode, service)
			if eligible_current_ships.is_empty():
				service_card.add_child(_label(I18n.core("location.logistics.no_eligible_ship"), 12, COLOR_WARN))
			else:
				var ship_actions := HFlowContainer.new()
				ship_actions.add_theme_constant_override("h_separation", 6)
				for ship_id_value in eligible_current_ships:
					var ship_id := String(ship_id_value)
					var ship: Dictionary = Game.state.ship_by_id(ship_id)
					var is_assigned: bool = service.get("assigned_ship_ids", []).has(ship_id)
					var cannot_remove_last: bool = is_assigned and service.get("assigned_ship_ids", []).size() <= 1 and not bool(current_mode.get("public_base_capacity", false))
					var action_text := I18n.core("location.logistics.remove_ship") % String(ship.get("name", ship_id)) if is_assigned else I18n.core("location.logistics.assign_ship") % String(ship.get("name", ship_id))
					var ship_button := _button(action_text, _toggle_logistics_service_ship.bind(route_id, ship_id), cannot_remove_last, COLOR_WARN if is_assigned else COLOR_ACCENT)
					ship_button.name = "%sLogisticsShip_%s_%s" % ["Remove" if is_assigned else "Assign", route_id, ship_id]
					if cannot_remove_last:
						ship_button.tooltip_text = I18n.core("logistics.last_ship_required")
					ship_actions.add_child(ship_button)
				service_card.add_child(ship_actions)
		var priority_actions := HFlowContainer.new()
		priority_actions.add_theme_constant_override("h_separation", 6)
		var current_priority := String(service.get("priority_strategy", "DEMAND_PRIORITY"))
		for strategy in ["DEMAND_PRIORITY", "PRECISION_FIRST", "MAINTENANCE_FIRST", "BULK_FIRST"]:
			var selected_priority := String(strategy) == current_priority
			var priority_button := _button(_logistics_priority_text(String(strategy)), _configure_route_priority.bind(route_id, String(strategy)), selected_priority, COLOR_ACCENT if selected_priority else COLOR_MUTED)
			priority_button.name = "LogisticsPriority_%s_%s" % [route_id, String(strategy)]
			if selected_priority:
				priority_button.tooltip_text = I18n.core("location.logistics.priority_selected", "This route already uses this priority strategy.")
			priority_actions.add_child(priority_button)
		service_card.add_child(priority_actions)
		var wrapped_service_card := _wrap_card(service_card)
		wrapped_service_card.name = "LogisticsRouteCard_%s" % route_id
		box.add_child(wrapped_service_card)

	box.add_child(_section_title(I18n.core("location.logistics.policies")))
	var policy_ids: Array = logistics.get("policies", {}).keys()
	policy_ids.sort()
	if policy_ids.is_empty():
		box.add_child(_card_text(I18n.core("logistics.policy_empty", "No exception policy is active. Industrial templates can establish routine supply automatically."), COLOR_MUTED))
	for item_value in policy_ids:
		var item_id := String(item_value)
		var policy: Dictionary = logistics.get("policies", {}).get(item_id, {})
		if _logistics_advanced:
			box.add_child(_wrap_card(_logistics_policy_editor(item_id, policy)))
		else:
			var blocker: Dictionary = policy.get("blocker", {})
			var policy_status: String = Game.simulation.logistics.policy_gameplay_status(policy)
			var summary_card := _card()
			summary_card.add_child(_label(I18n.core("logistics.policy_summary") % [_content_name(Game.content.items.get(item_id, {}), item_id), _logistics_mode_text(String(policy.get("mode", LogisticsEngine.MODE_STORAGE))), _status_text(policy_status)], 14, COLOR_WARN if not blocker.is_empty() else COLOR_TEXT))
			if not blocker.is_empty():
				var blocker_info := Game.logistics_policy_blocker_info(blocker)
				summary_card.add_child(_label(I18n.core("location.logistics.blocked") % [_status_text(String(blocker.get("code", "LOGISTICS_BLOCKED"))), _blocker_text(blocker_info)], 12, COLOR_WARN))
				summary_card.add_child(_button(I18n.core("diagnostics.why", "Why?") + " → " + I18n.core("diagnostics.open_resolution", "Open resolution"), _navigate_blocker.bind(blocker_info), false, COLOR_WARN))
			box.add_child(_wrap_card(summary_card))
	var advanced_toggle := _button(I18n.core("logistics.policy_hide_advanced", "Hide Advanced Policies") if _logistics_advanced else I18n.core("logistics.policy_show_advanced", "Advanced Policy Exceptions"), _toggle_logistics_advanced, false, COLOR_MUTED)
	advanced_toggle.name = "LogisticsPolicyAdvancedToggle"
	box.add_child(advanced_toggle)
	if _logistics_advanced:
		box.add_child(_card_text(I18n.core("logistics.policy_advanced_help", "Use per-product controls only for strategic exceptions. Industrial templates remain the default for routine administration."), COLOR_MUTED))
		var add_card := _card()
		add_card.add_child(_label(I18n.core("location.logistics.add_policy"), 16, COLOR_ACCENT))
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
		for mode in [LogisticsEngine.MODE_SUPPLY, LogisticsEngine.MODE_DEMAND, LogisticsEngine.MODE_STORAGE]:
			var mode_text := I18n.core("location.logistics.set_supply") if mode == LogisticsEngine.MODE_SUPPLY else (I18n.core("location.logistics.set_demand") if mode == LogisticsEngine.MODE_DEMAND else I18n.core("location.logistics.set_storage"))
			var add_policy_button := _button(mode_text, _add_selected_logistics_policy.bind(mode, item_selector, item_ids), item_ids.is_empty(), COLOR_MUTED if mode == LogisticsEngine.MODE_STORAGE else COLOR_ACCENT)
			add_policy_button.name = "AddLogisticsPolicy_%s_%s" % [_selected_location_id, mode]
			add_row.add_child(add_policy_button)
		add_card.add_child(add_row)
		box.add_child(_wrap_card(add_card))

	box.add_child(_section_title(I18n.core("location.logistics.in_transit")))
	var shipment_found := false
	for shipment_value in Game.state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if String(shipment.get("origin", "")) != _selected_location_id and String(shipment.get("destination", "")) != _selected_location_id:
			continue
		shipment_found = true
		var cargo_lines: Array[String] = []
		for item_value in shipment.get("cargo", {}).keys():
			var item_id := String(item_value)
			cargo_lines.append(I18n.core("format.item_quantity") % [_content_name(Game.content.items.get(item_id, {}), item_id), int(shipment.get("cargo", {}).get(item_id, 0))])
		var shipment_card := _card()
		shipment_card.add_child(_label(I18n.core("location.logistics.shipment") % [shipment.get("id", I18n.core("location.logistics.shipment_fallback")), _location_name(String(shipment.get("origin", ""))), _location_name(String(shipment.get("destination", ""))), float(shipment.get("remaining_ms", 0.0)) / 1000.0, float(shipment.get("handling_time_ms", 0.0)) / 1000.0, _logistics_technology_name(String(shipment.get("logistics_technology_id", "chemical_cargo"))), _freight_class_text(String(shipment.get("freight_class", "STANDARD"))), float(shipment.get("cargo_mass", shipment.get("freight_units", 0.0))), float(shipment.get("cargo_volume", shipment.get("freight_units", 0.0))), float(shipment.get("energy_units", 0.0)), I18n.core("format.list_separator").join(cargo_lines)], 13, COLOR_ACCENT))
		var shipment_status: String = Game.simulation.logistics.shipment_gameplay_status(shipment)
		var shipment_blocker: Dictionary = shipment.get("blocker", {}) if shipment.get("blocker", null) is Dictionary else {}
		var shipment_detail := String(shipment_blocker.get("primary_reason", shipment.get("status", "IN_TRANSIT")))
		shipment_card.add_child(_label(I18n.core("location.logistics.shipment_status") % [_status_text(shipment_status), _status_text(shipment_detail)], 13, COLOR_WARN if shipment_status == "BLOCKED_DESTINATION" else COLOR_MUTED))
		if shipment_status == "BLOCKED_DESTINATION":
			shipment_card.add_child(_label(I18n.core("location.logistics.blocked") % [shipment_detail, _blocker_text(shipment_blocker)], 12, COLOR_WARN))
			var destination_id := String(shipment.get("destination", ""))
			var storage_button := _button(I18n.core("location.logistics.open_destination_storage"), _open_location_section.bind(destination_id, "industry"), not Game.state.has_location(destination_id), COLOR_WARN)
			storage_button.name = "ShipmentResolution_%s" % String(shipment.get("id", "SHIPMENT"))
			shipment_card.add_child(storage_button)
		box.add_child(_wrap_card(shipment_card))
	if not shipment_found:
		box.add_child(_card_text(I18n.core("location.logistics.no_shipments"), COLOR_MUTED))


func _logistics_policy_editor(item_id: String, policy: Dictionary) -> VBoxContainer:
	var card := _card()
	card.add_child(_label(I18n.core("location.logistics.policy_summary") % [
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
	card.add_child(_labeled_control(I18n.core("location.logistics.mode"), mode_selector))
	var reserve_input := _number_input(int(policy.get("reserve", 0)), 0, 1000000, 1)
	var target_input := _number_input(int(policy.get("target", 0)), 0, 1000000, 1)
	var priority_input := _number_input(int(policy.get("priority", 50)), 0, 100, 5)
	var threshold_input := _number_input(int(policy.get("dispatch_threshold", 1)), 1, 1000000, 1)
	card.add_child(_labeled_control(I18n.core("location.logistics.local_reserve"), reserve_input))
	card.add_child(_labeled_control(I18n.core("location.logistics.target_stock"), target_input))
	card.add_child(_labeled_control(I18n.core("location.logistics.priority"), priority_input))
	card.add_child(_labeled_control(I18n.core("location.logistics.dispatch_threshold"), threshold_input))
	var source_ids: Array[String] = [""]
	var source_selector := OptionButton.new()
	source_selector.add_item(I18n.core("location.logistics.auto_source"))
	for location_value in Game.state.locations.keys():
		var source_id := String(location_value)
		if source_id == _selected_location_id or String(Game.state.location_state(source_id).get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED:
			continue
		source_ids.append(source_id)
		source_selector.add_item(_location_name(source_id))
		if source_id == String(policy.get("source_lock", "")):
			source_selector.select(source_ids.size() - 1)
	card.add_child(_labeled_control(I18n.core("location.logistics.source"), source_selector))
	var route_ids: Array[String] = [""]
	var route_selector := OptionButton.new()
	route_selector.add_item(I18n.core("location.logistics.auto_route"))
	for route_value in Game.content.logistics_routes.values():
		var route := route_value as Dictionary
		var route_id := String(route.get("id", ""))
		route_ids.append(route_id)
		route_selector.add_item(_content_name(route, route_id))
		if route_id == String(policy.get("route_lock", "")):
			route_selector.select(route_ids.size() - 1)
	card.add_child(_labeled_control(I18n.core("location.logistics.route_lock"), route_selector))
	var blocker: Dictionary = policy.get("blocker", {})
	if not blocker.is_empty():
		var blocker_info := Game.logistics_policy_blocker_info(blocker)
		card.add_child(_label(I18n.core("location.logistics.blocked") % [_status_text(String(blocker.get("code", "LOGISTICS_BLOCKED"))), _blocker_text(blocker_info)], 12, COLOR_WARN))
		card.add_child(_button(I18n.core("diagnostics.why", "Why?") + " → " + I18n.core("diagnostics.open_resolution", "Open resolution"), _navigate_blocker.bind(blocker_info), false, COLOR_WARN))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	var save_policy_button := _button(I18n.core("location.logistics.save_policy"), _save_logistics_policy.bind(item_id, mode_selector, modes, reserve_input, target_input, priority_input, threshold_input, source_selector, source_ids, route_selector, route_ids))
	save_policy_button.name = "SetLogisticsPolicy_%s_%s" % [_selected_location_id, item_id]
	actions.add_child(save_policy_button)
	var clear_policy_button := _button(I18n.core("location.logistics.clear"), _command.bind(I18n.core("command.clear_logistics_policy"), Game.clear_location_logistics_policy.bind(_selected_location_id, item_id)), false, COLOR_WARN)
	clear_policy_button.name = "ClearLogisticsPolicy_%s_%s" % [_selected_location_id, item_id]
	actions.add_child(clear_policy_button)
	card.add_child(actions)
	return card


func _on_logistics_item_selected(index: int, item_ids: Array) -> void:
	if index >= 0 and index < item_ids.size():
		_logistics_item_selection[_selected_location_id] = String(item_ids[index])


func _toggle_logistics_advanced() -> void:
	_logistics_advanced = not _logistics_advanced
	_request_active_page_refresh(true)


func _add_selected_logistics_policy(mode: String, selector: OptionButton, item_ids: Array) -> void:
	var index := selector.selected
	if index < 0 or index >= item_ids.size():
		return
	var item_id := String(item_ids[index])
	_logistics_item_selection[_selected_location_id] = item_id
	var current := Game.state.item_quantity(item_id, _selected_location_id)
	var target := maxi(50, current) if mode == LogisticsEngine.MODE_DEMAND else 0
	_command(I18n.core("command.add_logistics_policy"), Game.set_location_logistics_policy.bind(_selected_location_id, item_id, mode, 0, target, 50, 1, ""))


func _save_logistics_policy(item_id: String, mode_selector: OptionButton, modes: Array, reserve_input: SpinBox, target_input: SpinBox, priority_input: SpinBox, threshold_input: SpinBox, source_selector: OptionButton, source_ids: Array[String], route_selector: OptionButton, route_ids: Array[String]) -> void:
	var mode_index := clampi(mode_selector.selected, 0, modes.size() - 1)
	var source_index := clampi(source_selector.selected, 0, source_ids.size() - 1)
	var route_index := clampi(route_selector.selected, 0, route_ids.size() - 1)
	_command(I18n.core("command.save_logistics_policy"), Game.set_location_logistics_policy.bind(
		_selected_location_id,
		item_id,
		String(modes[mode_index]),
		int(reserve_input.value),
		int(target_input.value),
		int(priority_input.value),
		int(threshold_input.value),
		String(source_ids[source_index]),
		String(route_ids[route_index])
	))


func _connected_logistics_routes(location_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for route_value in Game.content.logistics_routes.values():
		var route := route_value as Dictionary
		var from_id := String(route.get("from", ""))
		var to_id := String(route.get("to", ""))
		var peer_id := to_id if from_id == location_id else (from_id if to_id == location_id else "")
		if peer_id.is_empty() or not Game.state.has_location(peer_id) or String(Game.state.location_state(peer_id).get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED:
			continue
		result.append(route)
	result.sort_custom(func(a, b): return String(a.get("id", "")) < String(b.get("id", "")))
	return result


func _eligible_logistics_ship_ids(mode: Dictionary, service: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		var assignment: Dictionary = ship.get("assignment", {})
		var belongs_here := String(assignment.get("domain", "")) == "logistics" and String(assignment.get("service_id", "")) == String(service.get("id", ""))
		var lifecycle_ready := Game.state.ship_is_deployment_ready(ship_id) if not belongs_here else (
			String(ship.get("condition", "")) == "OPERATIONAL" \
			and String(ship.get("maintenance_state", "ACTIVE")) == "ACTIVE" \
			and float(ship.get("maintenance_coverage", 1.0)) > 0.0)
		if lifecycle_ready and (Game.state.ship_is_unassigned_docked(ship_id) or belongs_here) and Game.simulation.logistics.ship_eligible_for_mode(Game.state, ship_id, String(mode.get("id", ""))):
			result.append(ship_id)
	return result


func _transport_mode_requirement_text(mode: Dictionary) -> String:
	var lines: Array[String] = [I18n.content(mode, "description")]
	var technology_id := String(mode.get("required_technology", ""))
	if not technology_id.is_empty():
		lines.append(I18n.core("logistics.requirement.technology") % _content_name(Game.content.technologies.get(technology_id, {}), technology_id))
	var facility_id := String(mode.get("required_facility", ""))
	if not facility_id.is_empty():
		lines.append(I18n.core("logistics.requirement.facility") % _content_name(Game.content.facilities.get(facility_id, {}), facility_id))
	var capability_names := {"bulk_freight":I18n.core("logistics.capability.bulk_freight"), "insulated_cargo":I18n.core("logistics.capability.insulated_cargo"), "high_speed_freight":I18n.core("logistics.capability.high_speed_freight")}
	for capability_id_value in mode.get("required_ship_capabilities", []):
		var capability_id := String(capability_id_value)
		lines.append(I18n.core("logistics.requirement.ship_capability") % capability_names.get(capability_id, capability_id))
	var minimum_capacity := int(mode.get("minimum_ship_cargo_capacity", 0))
	var maximum_capacity := int(mode.get("maximum_ship_cargo_capacity", 0))
	if minimum_capacity > 0:
		lines.append(I18n.core("logistics.requirement.cargo_capacity") % [minimum_capacity, I18n.core("format.maximum_suffix") % maximum_capacity if maximum_capacity > 0 else I18n.core("format.or_more_suffix")])
	return "\n".join(lines)


func _configure_route_transport_mode(route_id: String, mode_id: String) -> void:
	var mode: Dictionary = Game.content.transport_modes.get(mode_id, {})
	var service: Dictionary = Game.simulation.logistics.service_for_route(Game.state, route_id)
	var ship_ids: Array = []
	if not bool(mode.get("infrastructure_service", false)) and not bool(mode.get("public_base_capacity", false)):
		var eligible := _eligible_logistics_ship_ids(mode, service)
		if not eligible.is_empty():
			ship_ids.append(eligible[0])
	_command(I18n.core("command.configure_route_service"), Game.configure_logistics_service.bind(route_id, mode_id, ship_ids, String(service.get("priority_strategy", "DEMAND_PRIORITY"))))


func _configure_route_priority(route_id: String, priority_strategy: String) -> void:
	var service: Dictionary = Game.simulation.logistics.service_for_route(Game.state, route_id)
	_command(I18n.core("command.change_route_priority"), Game.configure_logistics_service.bind(route_id, String(service.get("transport_mode_id", "general_cargo")), service.get("assigned_ship_ids", []).duplicate(), priority_strategy))


func _toggle_logistics_service_ship(route_id: String, ship_id: String) -> void:
	var service: Dictionary = Game.simulation.logistics.service_for_route(Game.state, route_id)
	var ship_ids: Array = service.get("assigned_ship_ids", []).duplicate()
	if ship_ids.has(ship_id):
		ship_ids.erase(ship_id)
	else:
		ship_ids.append(ship_id)
	_command(I18n.core("command.change_logistics_ship_assignment"), Game.configure_logistics_service.bind(route_id, String(service.get("transport_mode_id", "general_cargo")), ship_ids, String(service.get("priority_strategy", "DEMAND_PRIORITY"))))


func _build_location_projects(box: VBoxContainer, _location: Dictionary) -> void:
	var found := false
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != _selected_location_id or String(operation.get("activity_id", "")).is_empty():
			continue
		found = true
		var activity: Dictionary = Game.simulation.construction_activity_for_runtime(operation)
		var project: Dictionary = Game.state.megastructure_projects.get(String(operation.get("megastructure_id", "")), {})
		var stage_line := I18n.core("construction.megastructure_stage_suffix") % [int(project.get("progress_percent", 0)), _status_text(String(project.get("stage_name", "PLANNED"))), _status_text(String(project.get("material_flow_status", "RECEIVING")))] if not project.is_empty() else ""
		box.add_child(_card_text(I18n.core("construction.location_project") % [_construction_project_name(operation, activity), _status_text(String(operation.get("status", "UNKNOWN"))), stage_line], COLOR_TEXT))
	for order_value in Game.state.shipyard_queue:
		var order := order_value as Dictionary
		if String(order.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != _selected_location_id:
			continue
		found = true
		var plan_id := String(order.get("plan_id", ""))
		var plan_name := _content_name(Game.content.ship_plans.get(plan_id, {}), plan_id) if not plan_id.is_empty() else I18n.core("ships.unknown_plan")
		box.add_child(_card_text(I18n.core("construction.location_shipyard") % [plan_name, _status_text(String(order.get("status", "UNKNOWN")))], COLOR_TEXT))
	if not found:
		box.add_child(_card_text(I18n.core("construction.location_empty"), COLOR_MUTED))


func _location_name(location_id: String) -> String:
	var definition: Dictionary = Game.content.regions.get(location_id, {"id":location_id, "name":location_id})
	return _content_name(definition, location_id)


func _capture_requested_view() -> void:
	var args := OS.get_cmdline_user_args()
	var file_name := "lab_system_map.png"
	var requested_view := ""
	var requested_output := ""
	for argument in args:
		if String(argument).begins_with("--capture-view="):
			requested_view = String(argument).trim_prefix("--capture-view=")
		elif String(argument).begins_with("--capture-output="):
			requested_output = String(argument).trim_prefix("--capture-output=")
	var requested_page := "fleet" if requested_view == "ships" else ("frontier" if requested_view == "survey" else requested_view)
	if not requested_page.is_empty() and _page_controls.has(requested_page):
		_switch_page(requested_page)
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
	for argument in args:
		if String(argument).begins_with("--capture-ship-design-plan="):
			_build_capture_ship_design(String(argument).trim_prefix("--capture-ship-design-plan="))
			await get_tree().process_frame
			await get_tree().process_frame
	if args.has("--capture-scroll-bottom"):
		var captured_page := _page_controls.get(requested_page) as ScrollContainer
		if is_instance_valid(captured_page):
			captured_page.scroll_vertical = int(captured_page.get_v_scroll_bar().max_value)
			await get_tree().process_frame
			await get_tree().process_frame
	for argument in args:
		if String(argument).begins_with("--network-visual-phase=") and is_instance_valid(_industrial_network_view):
			_industrial_network_view.set_visual_phase_for_capture(float(String(argument).trim_prefix("--network-visual-phase=")))
		elif String(argument).begins_with("--network-focus-activity=") and is_instance_valid(_industrial_network_view):
			_industrial_network_view.focus_production_method(String(argument).trim_prefix("--network-focus-activity="), false)
	if args.has("--network-focus-bottleneck") and is_instance_valid(_industrial_network_view):
		_industrial_network_view.focus_bottleneck(false)
	RenderingServer.force_draw(false)
	await get_tree().process_frame
	var directory := ProjectSettings.globalize_path("res://artifacts/ui")
	DirAccess.make_dir_recursive_absolute(directory)
	var output_path := requested_output if not requested_output.is_empty() else "res://artifacts/ui/%s" % file_name
	if output_path.is_absolute_path():
		DirAccess.make_dir_recursive_absolute(output_path.get_base_dir())
	else:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_path.get_base_dir()))
	var error := get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(output_path))
	print("CAPTURE_SAVED: %s" % output_path if error == OK else "CAPTURE_FAILED: %s" % error_string(error))
	get_tree().quit(0 if error == OK else 1)


func _build_capture_ship_design(plan_id: String) -> void:
	if not is_instance_valid(_ship_assembly_view):
		return
	var plan := Game.content.ship_construction_projects.get(plan_id, {}) as Dictionary
	var hull_id := String(plan.get("ship_id", ""))
	var hull := Game.content.ships.get(hull_id, {}) as Dictionary
	if plan.is_empty() or hull.is_empty():
		return
	_ship_assembly_view.clear_draft(false)
	_ship_assembly_view.call("_drop_data", Vector2(690.0, 300.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":plan_id, "definition_id":hull_id})
	var slot_counts := {}
	for module_index in plan.get("starting_modules", []).size():
		var module_id := String(plan.get("starting_modules", [])[module_index])
		var slot := String(Game.content.modules.get(module_id, {}).get("slot", "utility"))
		var slot_index := int(slot_counts.get(slot, 0))
		slot_counts[slot] = slot_index + 1
		_ship_assembly_view.call("_drop_data", Vector2(90.0 + float(module_index % 2) * 290.0, 80.0 + float(module_index / 2) * 135.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":module_id})
		_ship_assembly_view.request_module_connection("ship_design_module_%04d" % (module_index + 1), "socket_%s_%d" % [slot, slot_index])
	_ship_assembly_view.fit_design()


func _rebuild_frontier() -> void:
	var box: VBoxContainer = _pages["frontier"]
	_clear(box)
	box.add_child(_page_title(I18n.core("survey.title"), I18n.core("survey.subtitle")))
	_add_unlock_banner(box, "frontier")
	box.add_child(_card_text(I18n.core("survey.factory_authority", "Survey fleets reveal resource intelligence. All extraction and processing is built on the factory grid; ships do not mine or provide production labor."), COLOR_ACCENT))
	box.add_child(_section_title(I18n.core("survey.resource_intelligence", "Resource Intelligence")))
	var visible_resource_field := false
	for location_id_value in Game.state.locations.keys():
		var location_id := String(location_id_value)
		var intelligence: Dictionary = Game.simulation.location_intelligence(Game.state, location_id)
		var survey_state := String(intelligence.get("survey_state", LocationState.UNKNOWN))
		for profile_value in intelligence.get("resources", []):
			var profile := profile_value as Dictionary
			visible_resource_field = true
			var resource_id := String(profile.get("resource_type", ""))
			var title := I18n.category(String(profile.get("resource_category", "UNKNOWN"))) if resource_id.is_empty() else _content_name(Game.content.items.get(resource_id, {}), resource_id)
			var card := _card()
			card.add_child(_label(title, 17, COLOR_TEXT))
			card.add_child(_label(I18n.core("survey.grid_deposit", "%s · %s · world %s · resource field %s") % [_location_name(location_id), _status_text(survey_state), String(profile.get("world_id", "")), String(profile.get("resource_field_id", ""))], 14, COLOR_MUTED))
			box.add_child(_wrap_card(card))
	if not visible_resource_field:
		box.add_child(_card_text(I18n.core("survey.no_sites"), COLOR_MUTED))


func _rebuild_inventory() -> void:
	var box: VBoxContainer = _pages["inventory"]
	_clear(box)
	box.add_child(_page_title(I18n.core("page.inventory", "Inventory"), I18n.core("inventory.subtitle", "Search stock, reservations, demand, supply and net flow at the selected Location.")))
	var search := LineEdit.new()
	search.name = "InventorySearch"
	search.placeholder_text = I18n.core("inventory.search", "Search products")
	search.text = _inventory_search_text
	search.text_changed.connect(_on_inventory_search_changed)
	box.add_child(search)
	var analysis: Dictionary = Game.simulation.current_economy_analysis(Game.state, _selected_location_id)
	var products: Array = analysis.get("products", [])
	var visible := 0
	for product_value in products:
		var product := product_value as Dictionary
		var product_id := String(product.get("product_id", ""))
		var product_name := _content_name(Game.content.items.get(product_id, {}), product_id)
		if not _inventory_search_text.is_empty() and not product_name.to_lower().contains(_inventory_search_text.to_lower()) and not product_id.to_lower().contains(_inventory_search_text.to_lower()):
			continue
		visible += 1
		var card := _card()
		var status := String(product.get("status", "STABLE"))
		var status_color := COLOR_BAD if status == "CRITICAL" else (COLOR_WARN if status in ["TIGHT", "STORAGE_FULL"] else COLOR_GOOD)
		var detail_button := _button(I18n.core("inventory.product_header") % [product_name, _status_text(status)], _open_product_diagnostics.bind(product_id), false, status_color)
		detail_button.name = "ProductDetails_%s" % product_id
		card.add_child(detail_button)
		card.add_child(_label("%d / %.0f · %s %d · %s %d\n+%.2f/h · -%.2f/h · %+.2f/h" % [int(product.get("on_hand", 0)), float(product.get("storage_capacity", 0.0)), I18n.core("inventory.available", "Available"), int(product.get("available", 0)), I18n.core("inventory.reserved", "Reserved"), int(product.get("reserved", 0)), float(product.get("production_rate", 0.0)) + float(product.get("import_rate", 0.0)), float(product.get("consumption_rate", 0.0)) + float(product.get("export_rate", 0.0)), float(product.get("net_rate", 0.0))], 13, COLOR_MUTED))
		if not product.get("demand_sources", []).is_empty():
			card.add_child(_label(I18n.core("inventory.demand_sources", "Demand sources") + " · %d" % product.get("demand_sources", []).size(), 12, COLOR_MUTED))
		if not product.get("blocked_sources", []).is_empty():
			card.add_child(_button(I18n.core("diagnostics.why", "Why?") + " · " + _status_text(status), _open_product_diagnostics.bind(product_id), false, COLOR_WARN))
		box.add_child(_wrap_card(card))
	if visible == 0:
		box.add_child(_card_text(I18n.core("inventory.empty_search", "No products match this search."), COLOR_MUTED))


func _on_inventory_search_changed(value: String) -> void:
	_inventory_search_text = value
	_request_active_page_refresh(true)


func _open_product_diagnostics(product_id: String) -> void:
	_planner_product_id = product_id
	_inventory_search_text = product_id
	_switch_page("diagnostics")


func _rebuild_logistics() -> void:
	var box: VBoxContainer = _pages["logistics"]
	_clear(box)
	box.add_child(_page_title(I18n.core("page.logistics", "Logistics"), I18n.core("logistics.subtitle", "Routes, transport assets, actual flow, utilization and project supply.")))
	_build_location_logistics(box, Game.state.location_state(_selected_location_id))


func _rebuild_construction() -> void:
	var box: VBoxContainer = _pages["construction"]
	_clear(box)
	box.add_child(_page_title(I18n.core("page.construction", "Construction"), I18n.core("construction.subtitle", "One material-backed queue for facilities, upgrades, remote sites and stellar engineering.")))
	_build_industry_construction(box)


func _rebuild_diagnostics() -> void:
	var box: VBoxContainer = _pages["diagnostics"]
	_clear(box)
	box.add_child(_page_title(I18n.core("page.diagnostics", "Diagnostics"), I18n.core("diagnostics.subtitle", "See what stopped, why it stopped, and where to resolve the root cause.")))
	var problems := _current_blockers()
	if problems.is_empty():
		box.add_child(_card_text(I18n.core("diagnostics.clear", "No critical blocker is active. Planner forecasts are available below."), COLOR_GOOD))
	for blocker in problems:
		var card := _card()
		var reason := String(blocker.get("code", blocker.get("primary_reason", "UNKNOWN")))
		var severity := String(blocker.get("severity", "CRITICAL"))
		var severity_color := COLOR_BAD if severity == "CRITICAL" else (COLOR_WARN if severity == "WARNING" else COLOR_ACCENT)
		card.add_child(_label(_status_text(severity) + " · " + _status_text(reason), 16, severity_color))
		card.add_child(_label(_blocker_text(blocker), 13, COLOR_MUTED))
		var upstream: Dictionary = blocker.get("upstream_cause", {})
		if not upstream.is_empty():
			card.add_child(_label(I18n.core("diagnostics.upstream", "Upstream cause") + " · " + _status_text(String(upstream.get("code", "UNKNOWN"))), 12, COLOR_WARN))
			var upstream_button := _button(I18n.core("diagnostics.open_upstream", "Open upstream cause"), _navigate_blocker.bind(upstream), false, COLOR_WARN)
			upstream_button.name = "BlockerUpstream_%s_%s" % [reason, String(upstream.get("route_id", "ROOT"))]
			card.add_child(upstream_button)
		var why_button := _button(I18n.core("diagnostics.why", "Why?") + " → " + I18n.core("diagnostics.open_resolution", "Open resolution"), _navigate_blocker.bind(blocker), false, COLOR_WARN)
		why_button.name = "BlockerWhy_%s" % reason
		card.add_child(why_button)
		box.add_child(_wrap_card(card))
	_build_background_economy_controls(box)


func _navigate_blocker(blocker: Dictionary) -> void:
	var info: Dictionary = blocker if blocker.has("navigation_target") else Game.blocker_info(blocker)
	var target: Dictionary = info.get("navigation_target", {})
	var location_id := String(target.get("location_id", ""))
	if not location_id.is_empty() and Game.state.has_location(location_id):
		_selected_location_id = location_id
	var item_id := String(target.get("item_id", ""))
	if not item_id.is_empty():
		_inventory_search_text = item_id
	var screen := String(target.get("screen", "industry"))
	if screen == "logistics":
		_logistics_route_focus_id = ""
		if not item_id.is_empty() and not location_id.is_empty():
			_logistics_item_selection[location_id] = item_id
		var route_id := String(target.get("entity_id", target.get("route_id", "")))
		if not route_id.is_empty() and Game.content.logistics_routes.has(route_id):
			_logistics_route_focus_id = route_id
	_switch_page(screen)


func _current_blockers(location_id: String = "") -> Array[Dictionary]:
	if location_id.is_empty():
		return _active_blocker_cache.duplicate(true)
	return _active_blocker_cache.filter(func(blocker): return String((blocker as Dictionary).get("location_id", "")) == location_id)


func _refresh_alerts() -> void:
	var current := Game.active_blockers()
	var now := int(Game.state.total_elapsed_ms)
	var active_ids := {}
	_active_blocker_cache.clear()
	for blocker_value in current:
		var blocker := blocker_value as Dictionary
		var source: Dictionary = blocker.get("source_entity", {})
		var missing: Dictionary = blocker.get("missing_requirement", {})
		var alert_id := "%s|%s|%s|%s" % [blocker.get("code", "UNKNOWN"), blocker.get("location_id", ""), source.get("id", ""), missing.get("item_id", "")]
		active_ids[alert_id] = true
		var record: Dictionary = _alert_records.get(alert_id, {
			"alert_id":alert_id, "timestamp":now, "resolved":false
		})
		record["source"] = source.duplicate(true)
		record["reason"] = blocker.get("code", "UNKNOWN")
		record["severity"] = blocker.get("severity", "INFO")
		record["affected_entity"] = source.duplicate(true)
		record["navigation_target"] = blocker.get("navigation_target", {}).duplicate(true)
		record["last_seen"] = now
		record["resolved"] = false
		_alert_records[alert_id] = record
		if not _seen_blocker_ids.has(alert_id):
			_seen_blocker_ids[alert_id] = true
			_record_telemetry("BlockerSeen", {
				"blocker_id":alert_id,
				"code":String(blocker.get("code", "UNKNOWN")),
				"navigation_target":blocker.get("navigation_target", {}).duplicate(true)
			})
		var enriched := blocker.duplicate(true)
		enriched["alert"] = record.duplicate(true)
		_active_blocker_cache.append(enriched)
	for alert_id_value in _alert_records.keys():
		var alert_id := String(alert_id_value)
		if active_ids.has(alert_id):
			continue
		var record: Dictionary = _alert_records[alert_id]
		if not bool(record.get("resolved", false)):
			record["resolved"] = true
			record["resolved_at"] = now


func _rebuild_industry() -> void:
	var box: VBoxContainer = _pages["industry"]
	var network_workspace := _industry_section == "production" and _industry_view_mode == "network"
	_configure_industry_workspace(network_workspace)
	_clear(box)
	if network_workspace:
		var compact_header := HBoxContainer.new()
		compact_header.name = "IndustryNetworkHeader"
		compact_header.add_theme_constant_override("separation", 10)
		var compact_title := Label.new()
		compact_title.text = I18n.core("industry.title")
		compact_title.add_theme_font_size_override("font_size", UiTokens.font_size(20))
		compact_title.add_theme_color_override("font_color", COLOR_TEXT)
		compact_header.add_child(compact_title)
		var compact_context := Label.new()
		compact_context.text = I18n.core("industrial_network.workspace_context", "Orbital industrial operations console")
		compact_context.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		compact_context.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		compact_context.add_theme_font_size_override("font_size", UiTokens.font_size(12))
		compact_context.add_theme_color_override("font_color", COLOR_MUTED)
		compact_context.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		compact_header.add_child(compact_context)
		box.add_child(compact_header)
	else:
		box.add_child(_page_title(I18n.core("industry.title"), I18n.core("industry.subtitle")))
	var section_tabs := HFlowContainer.new()
	section_tabs.add_theme_constant_override("h_separation", 6)
	section_tabs.add_theme_constant_override("v_separation", 6)
	for entry in [["production", I18n.core("industry.tab.production")], ["facilities", I18n.core("industry.tab.facilities")], ["construction", I18n.core("industry.tab.construction")], ["automation", I18n.core("industry.tab.diagnostics")]]:
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


func _configure_industry_workspace(network_workspace: bool) -> void:
	var scroll = _page_controls.get("industry") as ScrollContainer
	if not is_instance_valid(scroll):
		return
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if network_workspace else ScrollContainer.SCROLL_MODE_AUTO
	var margin := scroll.get_child(0) as MarginContainer if scroll.get_child_count() > 0 else null
	if is_instance_valid(margin):
		margin.size_flags_vertical = Control.SIZE_EXPAND_FILL if network_workspace else Control.SIZE_SHRINK_BEGIN
	var box = _pages.get("industry") as VBoxContainer
	if is_instance_valid(box):
		box.size_flags_vertical = Control.SIZE_EXPAND_FILL if network_workspace else Control.SIZE_SHRINK_BEGIN


func _select_industry_section(section: String) -> void:
	_industry_section = section
	_save_ui_preferences()
	_request_active_page_refresh(true)


func _open_production_construction(_project_id: String) -> void:
	_industry_section = "construction"
	_switch_page("construction")


func _open_production_capability(location_id: String) -> void:
	_selected_location_id = location_id
	_industry_section = "facilities"
	_switch_page("industry")


func _build_industry_production(box: VBoxContainer) -> void:
	var view_tabs := HBoxContainer.new()
	view_tabs.add_theme_constant_override("separation", 6)
	var network_button := _industrial_network_mode_button(I18n.core("industrial_network.view.network", "Network view"), "network")
	network_button.name = "IndustryProductionNetworkView"
	view_tabs.add_child(network_button)
	var list_button := _industrial_network_mode_button(I18n.core("industrial_network.view.list", "List / detailed view"), "list")
	list_button.name = "IndustryProductionListView"
	view_tabs.add_child(list_button)
	box.add_child(view_tabs)
	if _industry_view_mode == "network":
		_build_industry_network(box)
		return
	_build_industry_production_list(box)


func _industrial_network_mode_button(caption: String, mode: String) -> Button:
	var button := _button(caption, _select_industry_view_mode.bind(mode), false, COLOR_ACCENT)
	if mode == _industry_view_mode:
		button.add_theme_stylebox_override("normal", UiTokens.control_style(UiTokens.COLOR_CONTROL_ACTIVE, UiTokens.COLOR_FOCUS))
		button.add_theme_stylebox_override("hover", UiTokens.control_style(UiTokens.COLOR_CONTROL_ACTIVE.lightened(0.03), UiTokens.COLOR_FOCUS))
		button.add_theme_color_override("font_color", COLOR_TEXT)
		button.tooltip_text = I18n.core("industrial_network.view.active", "Current production view")
	return button


func _select_industry_view_mode(mode: String) -> void:
	if mode not in ["network", "list"]:
		return
	_industry_view_mode = mode
	if mode != "network":
		_industrial_network_view = null
	_save_ui_preferences()
	_request_active_page_refresh(true)


func _build_industry_network(box: VBoxContainer) -> void:
	if not is_instance_valid(_industrial_network_projection):
		_industrial_network_projection = IndustrialNetworkProjectionScript.new(Game.content)
	_industrial_network_view = IndustrialNetworkViewScript.new()
	_industrial_network_view.name = "IndustrialNetworkView"
	_industrial_network_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_industrial_network_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_industrial_network_view.build(_industrial_network_preferences, _reduced_motion)
	_industrial_network_view.entity_selected.connect(_on_industrial_network_entity_selected)
	_industrial_network_view.entity_activated.connect(_on_industrial_network_entity_activated)
	_industrial_network_view.preferences_changed.connect(_on_industrial_network_preferences_changed)
	_industrial_network_view.reduced_motion_changed.connect(_on_reduced_motion_changed)
	box.add_child(_industrial_network_view)
	_refresh_industrial_network_view()


func _refresh_industrial_network_view() -> void:
	if not is_instance_valid(_industrial_network_view):
		return
	if not is_instance_valid(_industrial_network_projection):
		_industrial_network_projection = IndustrialNetworkProjectionScript.new(Game.content)
	var snapshot := Game.simulation.industrial_network_snapshot(Game.state, _selected_location_id)
	var projection := _industrial_network_projection.build(snapshot)
	_industrial_network_view.apply_projection(projection)
	_industrial_network_view.set_reduced_motion(_reduced_motion)
	_industrial_network_view.set_simulation_paused(Engine.time_scale <= 0.0)
	if not _selected_industrial_network_node.is_empty():
		_industrial_network_view.select_entity(String(_selected_industrial_network_node.get("id", "")), false)
		var current := _industrial_network_view.selected_entity()
		if not current.is_empty():
			_selected_industrial_network_node = current
			_rebuild_sidebar()


func _on_industrial_network_entity_selected(node: Dictionary) -> void:
	if node.is_empty():
		return
	_selected_industrial_network_node = node.duplicate(true)
	_ui_state.select_context("industrial_network", String(node.get("id", "")))
	if _ui_state.right_inspector_collapsed:
		_ui_state.right_inspector_collapsed = false
		if is_instance_valid(_shell):
			_shell.set_right_collapsed(false)
	_rebuild_sidebar()
	_network_preferences_save_due_ms = Time.get_ticks_msec() + 500


func _on_industrial_network_entity_activated(node: Dictionary) -> void:
	_on_industrial_network_entity_selected(node)
	_open_industrial_network_target(node)


func _on_industrial_network_preferences_changed(preferences: Dictionary) -> void:
	_industrial_network_preferences = preferences.duplicate(true)
	_network_preferences_save_due_ms = Time.get_ticks_msec() + 500


func _on_reduced_motion_changed(enabled: bool) -> void:
	_reduced_motion = enabled
	_save_ui_preferences()


func _build_industry_production_list(box: VBoxContainer) -> void:
	box.add_child(_section_title(I18n.core("industry.production_methods")))
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
		var runtime_active := not runtime.is_empty() and String(runtime.get("status", "IDLE")) in ["RUNNING", "BLOCKED"]
		var card := _card()
		card.add_child(_label(_content_name(activity, activity_id), 16, COLOR_TEXT))
		card.add_child(_label(_activity_summary(activity), 13, COLOR_MUTED))
		if runtime_active and String(runtime.get("activity_id", "")) == activity_id:
			card.add_child(_operation_progress(runtime, I18n.core("industry.production_active")))
			_add_blocker_label(card, runtime)
			var stop_industry_button := _button(I18n.core("common.stop"), _command.bind(I18n.core("command.stop_production"), Game.stop_industry_operation.bind(int(runtime.get("slot", 0)))), false, COLOR_WARN)
			stop_industry_button.name = "StopIndustry_%s" % activity_id
			card.add_child(stop_industry_button)
		else:
			var busy := runtime_active
			var reason := _activity_block_reason("industry", activity_id)
			var disabled := busy or not reason.is_empty()
			var start_industry_button := _button(I18n.core("industry.start_production"), _command.bind(I18n.core("command.start_production"), Game.start_industry_operation.bind(int(runtime.get("slot", 0)), activity_id)), disabled)
			start_industry_button.name = "StartIndustry_%s" % activity_id
			card.add_child(start_industry_button)
			if busy:
				card.add_child(_label(I18n.core("industry.facility_busy"), 13, COLOR_WARN))
			elif not reason.is_empty():
				card.add_child(_label(I18n.core("expedition.unavailable") % reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))


func _build_industry_construction(box: VBoxContainer) -> void:
	box.add_child(_section_title(I18n.core("construction.facilities")))
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")).is_empty():
			continue
		var definition := Game.simulation.construction_activity_for_runtime(operation)
		var active_card := _card()
		active_card.add_child(_label(_construction_project_name(operation, definition), 16, COLOR_TEXT))
		active_card.add_child(_label(I18n.core("construction.project_header") % [String(operation.get("project_id", "PROJECT")), _construction_project_type_name(String(operation.get("project_type", "FACILITY_BUILD"))), _content_name(Game.content.regions.get(String(operation.get("location_id", "")), {"name":operation.get("location_id", "")}), String(operation.get("location_id", ""))), int(operation.get("priority", 50))], 13, COLOR_MUTED))
		active_card.add_child(_operation_progress(operation, I18n.core("construction.status") % _status_text(Game.simulation.construction_gameplay_state(operation))))
		_add_blocker_label(active_card, operation)
		active_card.add_child(_label(I18n.core("construction.materials") % [_resource_dictionary(operation.get("material_plan", {})), _resource_dictionary(operation.get("consumed", {})), _resource_dictionary(operation.get("delivered_materials", {})), _resource_dictionary(operation.get("in_transit_materials", {}))], 12, COLOR_MUTED))
		var priority_actions := HBoxContainer.new()
		priority_actions.add_theme_constant_override("separation", 6)
		for priority in [100, 50, 10]:
			var priority_button := _button(I18n.core("construction.priority") % priority, _command.bind(I18n.core("command.change_construction_priority"), Game.set_construction_project_priority.bind(String(operation.get("project_id", "")), priority)), int(operation.get("priority", 50)) == priority, COLOR_ACCENT)
			priority_button.name = "ConstructionPriority_%s_%d" % [String(operation.get("project_id", "PROJECT")), priority]
			priority_actions.add_child(priority_button)
		active_card.add_child(priority_actions)
		var paused := String(operation.get("status", "")) == "PAUSED"
		var pause_button := _button(I18n.core("construction.resume") if paused else I18n.core("construction.pause"), _command.bind(I18n.core("command.resume_construction") if paused else I18n.core("command.pause_construction"), Game.set_construction_project_paused.bind(String(operation.get("project_id", "")), not paused)), false, COLOR_ACCENT)
		pause_button.name = "%sConstruction_%s" % ["Resume" if paused else "Pause", String(operation.get("project_id", "PROJECT"))]
		active_card.add_child(pause_button)
		var megastructure_project: Dictionary = Game.state.megastructure_projects.get(String(operation.get("megastructure_id", "")), {})
		if not megastructure_project.is_empty():
			active_card.add_child(_label(I18n.core("construction.megastructure_phase") % [int(megastructure_project.get("progress_percent", 0)), _status_text(String(megastructure_project.get("stage_name", "PLANNED"))), _status_text(String(megastructure_project.get("material_flow_status", "RECEIVING")))], 14, COLOR_ACCENT))
		var cancel_button := _button(I18n.core("construction.cancel"), _command.bind(I18n.core("command.cancel_construction"), Game.stop_construction_project.bind(int(operation.get("slot", 0)))), false, COLOR_WARN)
		cancel_button.name = "CancelConstruction_%s" % String(operation.get("project_id", "PROJECT"))
		active_card.add_child(cancel_button)
		box.add_child(_wrap_card(active_card))

	if not Game.state.construction_history.is_empty():
		box.add_child(_section_title(I18n.core("construction.history.title")))
		var history_start := maxi(0, Game.state.construction_history.size() - 10)
		for history_index in range(Game.state.construction_history.size() - 1, history_start - 1, -1):
			var history := Game.state.construction_history[history_index] as Dictionary
			var history_definition := Game.content.activities.get(String(history.get("activity_id", "")), {}) as Dictionary
			var history_card := _card()
			history_card.add_child(_label(I18n.core("construction.history.header") % [_status_text(String(history.get("status", "COMPLETE"))), _construction_project_name(history, history_definition)], 16, COLOR_GOOD if String(history.get("status", "")) == "COMPLETE" else COLOR_WARN))
			history_card.add_child(_label(I18n.core("construction.history.summary") % [String(history.get("project_id", "PROJECT")), _construction_project_type_name(String(history.get("project_type", "FACILITY_BUILD"))), _location_name(String(history.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))), _format_ms(int(history.get("finished_at_ms", 0)))], 13, COLOR_MUTED))
			history_card.add_child(_label(I18n.core("construction.history.materials") % [_resource_dictionary(history.get("material_plan", {})), _resource_dictionary(history.get("consumed", {}))], 12, COLOR_MUTED))
			var cancellation: Dictionary = history.get("cancellation_result", {}) if history.get("cancellation_result", null) is Dictionary else {}
			if String(history.get("status", "")) == "CANCELLED":
				history_card.add_child(_label(I18n.core("construction.history.cancellation") % [_resource_dictionary(cancellation.get("delivered_released", {})), _resource_dictionary(cancellation.get("consumed_lost", {})), _location_name(String(cancellation.get("in_transit_destination", history.get("location_id", ""))))], 12, COLOR_WARN))
			var history_button := _button(I18n.core("construction.history.open_ledger"), _open_construction_history_target.bind(history), false, COLOR_ACCENT)
			history_button.name = "ConstructionHistory_%s" % String(history.get("project_id", "PROJECT"))
			history_card.add_child(history_button)
			box.add_child(_wrap_card(history_card))

	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		if String(activity.get("domain", "")) != "industry" or not Game.simulation.is_construction_activity(activity):
			continue
		if Game.simulation.construction_project_type_for_activity(activity) == "MEGASTRUCTURE":
			continue
		if not Game.simulation.definition_revealed(Game.state, activity):
			continue
		var activity_id := String(activity.get("id", ""))
		var card := _card()
		card.add_child(_label(_content_name(activity, activity_id), 16, COLOR_TEXT))
		card.add_child(_label(_activity_summary(activity), 13, COLOR_MUTED))
		var reason := _construction_block_reason(activity_id)
		var start_construction_button := _button(I18n.core("construction.start"), _command.bind(I18n.core("command.start_construction"), Game.start_construction_project.bind(activity_id)), not reason.is_empty())
		start_construction_button.name = "StartConstruction_%s" % activity_id
		if not reason.is_empty():
			start_construction_button.tooltip_text = reason
		card.add_child(start_construction_button)
		if not reason.is_empty():
			card.add_child(_label(I18n.core("expedition.unavailable") % reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))


func _open_construction_history_target(history: Dictionary) -> void:
	var location_id := String(history.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	_open_location_section(location_id, "industry")


func _build_facility_management(box: VBoxContainer) -> void:
	box.add_child(_section_title(I18n.core("facility.config_title", "Facility Configuration & Process Capability")))
	box.add_child(_card_text(I18n.core("facility.config_help", "Facility modules use real materials and the shared Construction queue. Stop a manufacturing facility before changing Process Modules or Universal Plugins."), COLOR_MUTED))
	var facility_ids: Array = Game.state.facilities.keys()
	facility_ids.sort()
	for facility_id_value in facility_ids:
		var facility_id := String(facility_id_value)
		var definition := Game.content.facilities.get(facility_id, {}) as Dictionary
		if definition.is_empty():
			continue
		var runtime: Dictionary = Game.simulation.industry_runtime_for_facility(Game.state, facility_id)
		var runtime_busy := Game.simulation.industry_facility_busy(Game.state, facility_id)
		var state_entry: Dictionary = Game.state.facilities.get(facility_id, {})
		var card := _card()
		card.add_child(_label(I18n.core("facility.level", "%s · Tier %d") % [_content_name(definition, facility_id), int(state_entry.get("level", 1))], 17, COLOR_TEXT))
		if not runtime.is_empty():
			card.add_child(_label(I18n.core("facility.production_status", "Production status: %s%s") % [_status_text(String(runtime.get("status", "IDLE"))), I18n.core("facility.stop_before_refit", " · Stop production before refitting") if runtime_busy else ""], 13, COLOR_WARN if runtime_busy else COLOR_MUTED))

		var advanced_demand := Game.simulation.facility_advanced_power_demand(Game.state, facility_id)
		if advanced_demand > 0.0 or definition.has("advanced_power_priority"):
			card.add_child(_label(I18n.core("facility.advanced_power_priority", "Advanced Power Priority · Actual demand %.1f") % advanced_demand, 14, COLOR_ACCENT))
			var current_priority := String(Game.state.energy_system.get("advanced_priorities", {}).get(facility_id, definition.get("advanced_power_priority", "NORMAL")))
			var priority_row := HFlowContainer.new()
			priority_row.add_theme_constant_override("h_separation", 6)
			for priority in ["CRITICAL", "HIGH", "NORMAL", "LOW"]:
				var power_priority_button := _button(_status_text(priority), _command.bind(I18n.core("command.set_power_priority", "Set Power Priority"), Game.set_advanced_power_priority.bind(facility_id, priority)), current_priority == priority)
				power_priority_button.name = "AdvancedPowerPriority_%s_%s" % [facility_id, priority]
				priority_row.add_child(power_priority_button)
			card.add_child(priority_row)

		var installed_upgrades: Array = state_entry.get("installed_modules", [])
		if not definition.get("upgrade_modules", {}).is_empty():
			card.add_child(_label(I18n.core("facility.infrastructure_modules", "Infrastructure Modules %d / %d") % [installed_upgrades.size(), int(definition.get("module_slots", 0))], 14, COLOR_ACCENT))
			for module_id_value in definition.get("upgrade_modules", {}).keys():
				var module_id := String(module_id_value)
				var module := definition.get("upgrade_modules", {}).get(module_id, {}) as Dictionary
				if installed_upgrades.has(module_id):
					card.add_child(_label(I18n.core("common.completed_item") % _content_name(module, module_id), 13, COLOR_GOOD))
				else:
					var available := Game.simulation.facility_module_available(Game.state, facility_id, module_id)
					var facility_module_button := _button(I18n.core("facility.queue_install", "Queue Installation · %s · %s") % [_content_name(module, module_id), _resource_list(module.get("costs", []))], _command.bind(I18n.core("command.queue_facility_module", "Queue Facility Module Installation"), Game.install_facility_module.bind(facility_id, module_id)), not available)
					facility_module_button.name = "InstallFacilityModule_%s_%s" % [facility_id, module_id]
					card.add_child(facility_module_button)

		if int(definition.get("manufacturing_generation", 0)) > 0:
			_add_manufacturing_module_controls(card, facility_id, definition, state_entry, "process", runtime_busy)
			_add_manufacturing_module_controls(card, facility_id, definition, state_entry, "plugin", runtime_busy)
		box.add_child(_wrap_card(card))


func _add_manufacturing_module_controls(card: VBoxContainer, facility_id: String, facility: Dictionary, state_entry: Dictionary, module_kind: String, runtime_busy: bool) -> void:
	var field := "installed_process_modules" if module_kind == "process" else "installed_plugins"
	var slot_field := "process_module_slots" if module_kind == "process" else "plugin_slots"
	var definitions: Dictionary = Game.content.process_modules if module_kind == "process" else Game.content.universal_industry_plugins
	var installed: Array = state_entry.get(field, [])
	card.add_child(_label(I18n.core("facility.manufacturing_modules") % [I18n.core("facility.process_modules") if module_kind == "process" else I18n.core("facility.universal_plugins"), installed.size(), int(facility.get(slot_field, 0))], 14, COLOR_ACCENT))
	for installed_id_value in installed:
		var installed_id := String(installed_id_value)
		var installed_definition := definitions.get(installed_id, {}) as Dictionary
		var installed_row := HFlowContainer.new()
		installed_row.add_theme_constant_override("h_separation", 6)
		installed_row.add_child(_label(I18n.core("common.completed_item") % _content_name(installed_definition, installed_id), 13, COLOR_GOOD))
		var uninstall_button := _button(I18n.core("facility.remove_module"), _command.bind(I18n.core("command.remove_manufacturing_module"), Game.uninstall_manufacturing_module.bind(facility_id, installed_id, module_kind)), runtime_busy, COLOR_WARN)
		uninstall_button.name = "UninstallManufacturingModule_%s_%s_%s" % [facility_id, installed_id, module_kind]
		installed_row.add_child(uninstall_button)
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
		var install_button := _button(I18n.core("facility.install_manufacturing_module") % [_content_name(module, module_id), I18n.core("facility.module_stock") % storage if storage > 0 else "", _resource_list(module.get("costs", []))], _command.bind(I18n.core("command.install_manufacturing_module"), Game.install_manufacturing_module.bind(facility_id, module_id, module_kind)), runtime_busy or not available)
		install_button.name = "InstallManufacturingModule_%s_%s_%s" % [facility_id, module_id, module_kind]
		card.add_child(install_button)


func _build_background_economy_controls(box: VBoxContainer) -> void:
	box.add_child(_section_title(I18n.core("diagnostics.economy.title")))
	box.add_child(_card_text(I18n.core("diagnostics.economy.help"), COLOR_MUTED))
	var analysis: Dictionary = Game.simulation.current_economy_analysis(Game.state, _selected_location_id)
	var storage: Dictionary = analysis.get("storage", {})
	var constraints: Dictionary = Game.simulation.location_industry_constraint_profile(Game.state, _selected_location_id)
	var local_logistics: Dictionary = Game.simulation.local_logistics_profile(Game.state, _selected_location_id)
	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	summary.add_child(_stat_card(I18n.core("diagnostics.economy.storage_utilization"), "%.0f%%" % (float(storage.get("utilization", 0.0)) * 100.0), COLOR_WARN if float(storage.get("utilization", 0.0)) >= 0.9 else COLOR_TEXT))
	summary.add_child(_stat_card(I18n.core("diagnostics.economy.power_margin"), "%.1f" % maxf(0.0, float(constraints.get("power_capacity", 0.0)) - float(constraints.get("power_demand", 0.0))), COLOR_WARN if float(constraints.get("power_coverage", 1.0)) < 1.0 else COLOR_TEXT))
	summary.add_child(_stat_card(I18n.core("diagnostics.economy.local_logistics"), "%.0f%%" % (float(local_logistics.get("utilization", 0.0)) * 100.0), COLOR_WARN if str(local_logistics.get("status", "")) == "CONSTRAINED" else COLOR_TEXT))
	box.add_child(summary)
	var products: Array = analysis.get("products", [])
	if products.is_empty():
		box.add_child(_card_text(I18n.core("diagnostics.economy.empty"), COLOR_MUTED))
	for product_value in products:
		var product := product_value as Dictionary
		var product_id := String(product.get("product_id", ""))
		var card := _card()
		var status := String(product.get("status", "STABLE"))
		var status_color := COLOR_BAD if status == "CRITICAL" else (COLOR_WARN if status in ["TIGHT", "STORAGE_FULL"] else (COLOR_GOOD if status == "STABLE" else COLOR_ACCENT))
		card.add_child(_label(I18n.core("diagnostics.economy.product_header") % [_content_name(Game.content.items.get(product_id, {}), product_id), _status_text(status), _status_text(String(product.get("storage_class", "BULK")))], 15, status_color))
		card.add_child(_label(I18n.core("diagnostics.economy.product_flow") % [int(product.get("on_hand", product.get("stock", 0))), int(product.get("available", 0)), int(product.get("reserved", 0)), float(product.get("storage_capacity", 0.0)), float(product.get("production_rate", 0.0)), float(product.get("consumption_rate", 0.0)), float(product.get("import_rate", 0.0)), float(product.get("export_rate", 0.0)), float(product.get("net_rate", 0.0)), float(product.get("committed_demand", 0.0))], 12, COLOR_MUTED))
		var demand_parts: Array[String] = []
		for demand_value in product.get("demand_sources", []):
			var demand := demand_value as Dictionary
			var amount := "%.2f/h" % float(demand.get("rate_per_hour", 0.0)) if String(demand.get("demand_kind", "")) == "CONTINUOUS" else "%.0f" % float(demand.get("quantity", 0.0))
			demand_parts.append(I18n.core("diagnostics.economy.demand_entry") % [_demand_source_text(String(demand.get("source_type", ""))), amount])
		if not demand_parts.is_empty():
			card.add_child(_label(I18n.core("diagnostics.economy.demand_sources") % I18n.core("format.dot_separator").join(demand_parts), 12, COLOR_MUTED))
		if not product.get("blocked_sources", []).is_empty() or status == "CRITICAL":
			var trace: Dictionary = Game.simulation.shortest_bottleneck_chain(Game.state, product_id, _selected_location_id)
			card.add_child(_label(I18n.core("planner.bottleneck_trace") % [_status_text(String(trace.get("primary_bottleneck", "UNKNOWN"))), _planner_chain_text(trace.get("shortest_chain", []))], 12, COLOR_WARN))
		box.add_child(_wrap_card(card))

	box.add_child(_section_title(I18n.core("planner.title")))
	box.add_child(_card_text(I18n.core("planner.help"), COLOR_MUTED))
	var product_ids: Array = Game.content.items.keys()
	product_ids.sort()
	var selector := OptionButton.new()
	for index in product_ids.size():
		var item_id := String(product_ids[index])
		selector.add_item(_content_name(Game.content.items.get(item_id, {}), item_id))
		if item_id == _planner_product_id:
			selector.select(index)
	var target_input := _number_input(int(maxf(1.0, _planner_target_rate)), 1, 1000000, 1)
	var planner_controls := HFlowContainer.new()
	planner_controls.add_theme_constant_override("h_separation", 6)
	planner_controls.add_child(_labeled_control(I18n.core("planner.target_product"), selector))
	planner_controls.add_child(_labeled_control(I18n.core("planner.units_per_hour"), target_input))
	planner_controls.add_child(_button(I18n.core("planner.calculate"), _run_read_only_plan.bind(selector, product_ids, target_input), product_ids.is_empty(), COLOR_ACCENT))
	box.add_child(planner_controls)

	var ship_plan_ids: Array = Game.content.ship_construction_projects.keys()
	ship_plan_ids.sort()
	var ship_selector := OptionButton.new()
	for ship_plan_id_value in ship_plan_ids:
		var ship_plan_id := String(ship_plan_id_value)
		ship_selector.add_item(_content_name(Game.content.ship_construction_projects.get(ship_plan_id, {}), ship_plan_id))
	var ship_rate := _number_input(1, 1, 1000, 1)
	var ship_controls := HFlowContainer.new()
	ship_controls.add_theme_constant_override("h_separation", 6)
	ship_controls.add_child(_labeled_control(I18n.core("planner.ship_model"), ship_selector))
	ship_controls.add_child(_labeled_control(I18n.core("planner.ships_per_month"), ship_rate))
	ship_controls.add_child(_button(I18n.core("planner.plan_ship_rate"), _run_ship_read_only_plan.bind(ship_selector, ship_plan_ids, ship_rate), ship_plan_ids.is_empty(), COLOR_ACCENT))
	box.add_child(ship_controls)

	var research_targets: Array = []
	var research_project_ids: Array = Game.content.research_projects.keys()
	research_project_ids.sort()
	var research_selector := OptionButton.new()
	for project_id_value in research_project_ids:
		var project_id := String(project_id_value)
		var project: Dictionary = Game.content.research_projects.get(project_id, {})
		if not Game.simulation.definition_revealed(Game.state, project):
			continue
		for stage_value in Game.simulation.research_stages(project):
			var stage := stage_value as Dictionary
			research_targets.append({"project_id":project_id, "phase_id":String(stage.get("id", ""))})
			research_selector.add_item(I18n.core("planner.target_label") % [_content_name(project, project_id), _content_name(stage, String(stage.get("id", "")))])
	var research_controls := HFlowContainer.new()
	research_controls.add_theme_constant_override("h_separation", 6)
	research_controls.add_child(_labeled_control(I18n.core("planner.research_stage"), research_selector))
	research_controls.add_child(_button(I18n.core("planner.plan_stage_materials"), _run_research_read_only_plan.bind(research_selector, research_targets), research_targets.is_empty(), COLOR_ACCENT))
	box.add_child(research_controls)

	var mega_targets: Array = []
	var mega_selector := OptionButton.new()
	for megastructure_value in Game.content.megastructures.values():
		var megastructure := megastructure_value as Dictionary
		for phase_value in megastructure.get("phases", []):
			var phase := phase_value as Dictionary
			mega_targets.append({"megastructure_id":String(megastructure.get("id", "")), "phase_id":String(phase.get("id", ""))})
			mega_selector.add_item(I18n.core("planner.target_label") % [_content_name(megastructure, String(megastructure.get("id", ""))), _content_name(phase, String(phase.get("id", "")))])
	var mega_controls := HFlowContainer.new()
	mega_controls.add_theme_constant_override("h_separation", 6)
	mega_controls.add_child(_labeled_control(I18n.core("planner.megastructure_phase"), mega_selector))
	mega_controls.add_child(_button(I18n.core("planner.plan_endgame_phase"), _run_mega_read_only_plan.bind(mega_selector, mega_targets), mega_targets.is_empty(), COLOR_ACCENT))
	box.add_child(mega_controls)
	if not _planner_result.is_empty():
		_build_read_only_plan_result(box, _planner_result)

	box.add_child(_section_title(I18n.core("automation.title")))
	box.add_child(_card_text(I18n.core("automation.help"), COLOR_MUTED))
	for rule_value in Game.state.automation_rules:
		var rule := rule_value as Dictionary
		var rule_card := _card()
		var condition: Dictionary = rule.get("condition", {})
		var action: Dictionary = rule.get("action", {})
		rule_card.add_child(_label(I18n.core("automation.rule_header") % [String(rule.get("rule_id", "AUTOMATION")), I18n.core("status.PAUSED") if bool(rule.get("paused", false)) else I18n.core("automation.authorized")], 14, COLOR_ACCENT))
		rule_card.add_child(_label(I18n.core("automation.rule_condition") % [_automation_term("condition", String(condition.get("type", "CONDITION"))), _automation_term("operator", String(condition.get("operator", "LT"))), float(condition.get("threshold", 0.0)), _automation_term("action", String(action.get("type", "ACTION"))), float(rule.get("cooldown_ms", 0.0)) / 1000.0, float(rule.get("hysteresis", 0.0))], 12, COLOR_MUTED))
		var rule_actions := HFlowContainer.new()
		rule_actions.add_child(_button(I18n.core("automation.resume_rule") if bool(rule.get("paused", false)) else I18n.core("automation.pause_rule"), _command.bind(I18n.core("command.toggle_automation_rule"), Game.set_automation_rule_paused.bind(String(rule.get("rule_id", "")), not bool(rule.get("paused", false)))), false, COLOR_WARN))
		rule_actions.add_child(_button(I18n.core("automation.revoke"), _command.bind(I18n.core("command.revoke_automation"), Game.revoke_automation_rule.bind(String(rule.get("rule_id", "")))), false, COLOR_BAD))
		rule_card.add_child(rule_actions)
		box.add_child(_wrap_card(rule_card))
	for runtime_value in Game.state.industrial_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("status", "")) not in ["RUNNING", "BLOCKED"] or not bool(runtime.get("manual_lock", true)):
			continue
		var slot := int(runtime.get("slot", -1))
		var facility_id := String(runtime.get("facility_id", ""))
		var location_id := String(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var guard_button := _button(I18n.core("automation.authorize_storage_guard") % _content_name(Game.content.facilities.get(facility_id, {}), facility_id), _command.bind(I18n.core("command.authorize_storage_automation"), _authorize_storage_guard.bind(slot, location_id)), false, COLOR_GOOD)
		guard_button.name = "AuthorizeStorageGuard_%d" % slot
		box.add_child(guard_button)


func _authorize_storage_guard(slot: int, location_id: String) -> bool:
	return Game.authorize_storage_guard(slot, location_id)


func _run_read_only_plan(selector: OptionButton, product_ids: Array, target_input: SpinBox) -> void:
	if selector.selected < 0 or selector.selected >= product_ids.size():
		return
	_planner_product_id = String(product_ids[selector.selected])
	_planner_target_rate = float(target_input.value)
	_planner_result = Game.simulation.target_throughput_plan(Game.state, {_planner_product_id:_planner_target_rate}, _selected_location_id)
	_planner_result["target_type"] = "PRODUCT_RATE"
	_planner_target_label = I18n.core("planner.product_rate_label") % [_content_name(Game.content.items.get(_planner_product_id, {}), _planner_product_id), _planner_target_rate]
	_request_active_page_refresh(true)


func _run_ship_read_only_plan(selector: OptionButton, ship_plan_ids: Array, target_input: SpinBox) -> void:
	if selector.selected < 0 or selector.selected >= ship_plan_ids.size():
		return
	var ship_plan_id := String(ship_plan_ids[selector.selected])
	_planner_target_label = I18n.core("planner.ship_rate_label") % [_content_name(Game.content.ship_construction_projects.get(ship_plan_id, {}), ship_plan_id), float(target_input.value)]
	_planner_result = Game.simulation.ship_per_month_plan(Game.state, ship_plan_id, float(target_input.value), _selected_location_id)
	_request_active_page_refresh(true)


func _run_research_read_only_plan(selector: OptionButton, research_targets: Array) -> void:
	if selector.selected < 0 or selector.selected >= research_targets.size():
		return
	var target := research_targets[selector.selected] as Dictionary
	var project_id := String(target.get("project_id", ""))
	var phase_id := String(target.get("phase_id", ""))
	_planner_target_label = I18n.core("planner.target_label") % [_content_name(Game.content.research_projects.get(project_id, {}), project_id), phase_id]
	_planner_result = Game.simulation.research_phase_plan(Game.state, project_id, phase_id, _selected_location_id)
	_request_active_page_refresh(true)


func _run_mega_read_only_plan(selector: OptionButton, mega_targets: Array) -> void:
	if selector.selected < 0 or selector.selected >= mega_targets.size():
		return
	var target := mega_targets[selector.selected] as Dictionary
	var megastructure_id := String(target.get("megastructure_id", ""))
	var phase_id := String(target.get("phase_id", ""))
	_planner_target_label = I18n.core("planner.target_label") % [_content_name(Game.content.megastructures.get(megastructure_id, {}), megastructure_id), phase_id]
	_planner_result = Game.simulation.megastructure_phase_plan(Game.state, megastructure_id, phase_id)
	_request_active_page_refresh(true)


func _build_read_only_plan_result(box: VBoxContainer, plan: Dictionary) -> void:
	var card := _card()
	var production_plan: Dictionary = plan.get("production_plan", plan)
	card.add_child(_label(I18n.core("planner.result_header") % (_planner_target_label if not _planner_target_label.is_empty() else String(plan.get("target_id", I18n.core("planner.target_fallback")))), 15, COLOR_ACCENT))
	var requirement_parts: Array[String] = []
	for item_id_value in production_plan.get("product_requirements", {}).keys():
		var item_id := String(item_id_value)
		requirement_parts.append(I18n.core("planner.requirement_entry") % [_content_name(Game.content.items.get(item_id, {}), item_id), float(production_plan.get("product_requirements", {}).get(item_id, 0.0))])
	card.add_child(_label(I18n.core("planner.product_requirements") % (I18n.core("format.dot_separator").join(requirement_parts) if not requirement_parts.is_empty() else I18n.core("status.NONE")), 12, COLOR_MUTED))
	for factory_value in production_plan.get("factory_requirements", []):
		var factory := factory_value as Dictionary
		var facility_id := String(factory.get("facility_id", ""))
		card.add_child(_label(I18n.core("planner.factory_requirement") % [_content_name(Game.content.facilities.get(facility_id, {}), facility_id), int(factory.get("current", 0)), int(factory.get("recommended", 0)), int(factory.get("shortage", 0)), I18n.core("format.list_separator").join(factory.get("production_device_requirements", [])), float(factory.get("utilization", 0.0)) * 100.0], 12, COLOR_TEXT))
	var infrastructure: Dictionary = production_plan.get("infrastructure_requirements", {})
	card.add_child(_label(I18n.core("planner.infrastructure") % [float(infrastructure.get("power", 0.0)), float(infrastructure.get("cooling", 0.0)), str(infrastructure.get("storage", {})), str(infrastructure.get("capital_goods", {}))], 12, COLOR_MUTED))
	for logistics_value in production_plan.get("logistics", []):
		var logistics := logistics_value as Dictionary
		card.add_child(_label(I18n.core("planner.logistics") % [_location_name(String(logistics.get("origin", ""))), _location_name(String(logistics.get("destination", ""))), float(logistics.get("cargo_mass_per_hour", 0.0)), float(logistics.get("cargo_volume_per_hour", 0.0)), I18n.core("format.chain_separator").join(logistics.get("route_ids", [])), float(logistics.get("lead_time_ms", 0.0)) / 1000.0], 12, COLOR_MUTED))
	for bottleneck_value in production_plan.get("bottlenecks", []):
		var bottleneck := bottleneck_value as Dictionary
		card.add_child(_label(I18n.core("planner.bottleneck_trace") % [_status_text(String(bottleneck.get("primary_bottleneck", "UNKNOWN"))), _planner_chain_text(bottleneck.get("shortest_chain", []))], 12, COLOR_WARN))
	box.add_child(_wrap_card(card))


func _planner_chain_text(chain: Array) -> String:
	var parts: Array[String] = []
	for node_value in chain:
		var node := node_value as Dictionary
		var node_id := String(node.get("id", ""))
		match String(node.get("kind", "")):
			"PRODUCT": parts.append(_content_name(Game.content.items.get(node_id, {}), node_id))
			"METHOD": parts.append(_content_name(Game.content.activities.get(node_id, {}), node_id))
			"FACTORY": parts.append(_content_name(Game.content.facilities.get(node_id, {}), node_id))
			"SITE", "RESOURCE_FIELD": parts.append(node_id)
			"ROUTE": parts.append(_content_name(Game.content.logistics_routes.get(node_id, {}), node_id))
			"HUB", "DESTINATION": parts.append(_location_name(node_id))
			_: parts.append(_status_text(node_id))
	return " → ".join(parts)


func _demand_source_text(source_type: String) -> String:
	match source_type:
		"maintenance": return I18n.core("inventory.demand.maintenance")
		"construction": return I18n.core("inventory.demand.construction")
		"research_project": return I18n.core("inventory.demand.research")
		"shipbuilding": return I18n.core("inventory.demand.shipbuilding")
		"fleet_operation": return I18n.core("inventory.demand.fleet")
		"logistics_export": return I18n.core("inventory.demand.export")
		"manual_order": return I18n.core("inventory.demand.manual")
		_: return source_type


func _rebuild_megastructure() -> void:
	var box: VBoxContainer = _pages["megastructure"]
	_clear(box)
	box.add_child(_page_title(I18n.core("megastructure.title"), I18n.core("megastructure.subtitle")))
	_add_unlock_banner(box, "megastructure")
	if Game.content.megastructures.is_empty():
		box.add_child(_label(I18n.core("megastructure.no_definition"), 14, COLOR_WARN))
		return
	var definition := Game.content.megastructures.values()[0] as Dictionary
	var megastructure_id := String(definition.get("id", "stellar_energy"))
	var phases: Array = definition.get("phases", [])
	var project: Dictionary = Game.state.megastructure_projects.get(megastructure_id, {})
	var queue_used := Game.simulation.construction_queue_size(Game.state)
	var queue_capacity := Game.simulation.construction_queue_capacity(Game.state)
	var complete := bool(Game.state.megastructures.get(megastructure_id, false))
	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	var megastructure_status := Game.simulation.megastructure_gameplay_state(Game.state, megastructure_id)
	summary.add_child(_stat_card(I18n.core("megastructure.stat.status"), _status_text(megastructure_status), COLOR_GOOD if complete else COLOR_ACCENT))
	summary.add_child(_stat_card(I18n.core("megastructure.stat.queue"), I18n.core("common.ratio") % [queue_used, queue_capacity], COLOR_WARN if queue_used >= queue_capacity else COLOR_TEXT))
	summary.add_child(_stat_card(I18n.core("megastructure.stat.phase"), I18n.core("common.ratio") % [int(project.get("phase_index", 0)), phases.size()], COLOR_TEXT))
	box.add_child(summary)
	var stage_visual := MegastructureProgressViewScript.new()
	stage_visual.configure(
		int(project.get("phase_index", 0)),
		phases.size(),
		complete,
		I18n.megastructure_stage(megastructure_id, int(project.get("phase_index", 0)), I18n.core("megastructure.stage_fallback"))
	)
	box.add_child(stage_visual)
	box.add_child(_megastructure_phase_visual(definition, int(project.get("phase_index", 0)), complete))
	if project.is_empty():
		var site_card := _card()
		site_card.add_child(_label(I18n.core("megastructure.phase_label", "Phase %d · %s") % [0, I18n.megastructure_stage(megastructure_id, 0, "Research & Site Selection")], 18, COLOR_ACCENT))
		site_card.add_child(_label(I18n.core("megastructure.site.instructions"), 13, COLOR_MUTED))
		for candidate_value in definition.get("site_candidates", []):
			var candidate_id := String(candidate_value)
			var candidate: Dictionary = Game.state.location_state(candidate_id)
			var intelligence: Dictionary = Game.simulation.location_intelligence(Game.state, candidate_id)
			var environment: Dictionary = intelligence.get("environment", {})
			var row := HBoxContainer.new()
			var candidate_state := String(intelligence.get("survey_state", LocationState.UNKNOWN))
			var intelligence_text := I18n.core("megastructure.site.unknown", "Data unknown")
			if candidate_state == LocationState.DETECTED:
				intelligence_text = I18n.core("megastructure.site.detected") % [_status_text(String(environment.get("transport_distance_band", "UNKNOWN"))), _status_text(String(environment.get("construction_difficulty_band", "UNKNOWN")))]
			elif candidate_state in [LocationState.SURVEYED, LocationState.DEEP_SURVEYED]:
				intelligence_text = I18n.core("megastructure.site.surveyed") % [float(environment.get("solar_flux", 0.0)), float(environment.get("transport_distance", 0.0)), float(environment.get("maintenance_severity", {}).get("electronics", 1.0))]
			row.add_child(_label(I18n.core("megastructure.site.candidate") % [_location_name(candidate_id), _status_text(candidate_state), intelligence_text], 13, COLOR_TEXT))
			var selectable := bool(Game.state.completed_projects.get("research_megastructures", false)) and String(candidate.get("survey_state", "")) == LocationState.DEEP_SURVEYED
			var select_button := _button(I18n.core("megastructure.site.select"), _command.bind(I18n.core("command.megastructure.select_site"), Game.select_megastructure_site.bind(megastructure_id, candidate_id)), not selectable, COLOR_GOOD)
			select_button.name = "SelectMegastructureSite_%s" % candidate_id
			row.add_child(select_button)
			site_card.add_child(row)
		box.add_child(_wrap_card(site_card))
		return
	var site_id := String(project.get("site_location_id", ""))
	var current_index := int(project.get("phase_index", 0))
	var current_phase: Dictionary = phases[clampi(current_index, 0, maxi(0, phases.size() - 1))] if not phases.is_empty() else {}
	var activity_id := String(current_phase.get("activity_id", ""))
	var activity := Game.content.activities.get(activity_id, {}) as Dictionary
	var runtime := _construction_runtime_for_activity(activity_id)
	var card := _card()
	card.add_child(_label(("✓ " if complete else "") + _content_name(definition, megastructure_id), 18, COLOR_GOOD if complete else COLOR_TEXT))
	card.add_child(_label(I18n.core("megastructure.gameplay_state") % _status_text(megastructure_status), 14, COLOR_GOOD if complete else (COLOR_WARN if megastructure_status == "WAITING_MATERIAL" else COLOR_ACCENT)))
	card.add_child(_label(I18n.core("megastructure.site.summary") % [_location_name(site_id), _status_text(String(project.get("material_flow_status", "AWAITING_NEXT_PHASE")))], 13, COLOR_ACCENT))
	var worksite_button := _button(I18n.core("megastructure.open_worksite"), _open_location_section.bind(site_id, "projects"), not Game.state.has_location(site_id), COLOR_ACCENT)
	worksite_button.name = "MegastructureOpenWorksite"
	card.add_child(worksite_button)
	card.add_child(_megastructure_progress(100 if complete else int(project.get("progress_percent", 0)), I18n.megastructure_stage(megastructure_id, current_index, String(current_phase.get("name", "Operational")))))
	if complete:
		card.add_child(_label(I18n.core("megastructure.completed"), 14, COLOR_GOOD))
		card.add_child(_label(I18n.core("megastructure.completion.statistics") % [_quantity_map_text(project.get("total_materials_consumed", {})), _quantity_map_text(project.get("total_capital_goods", {})), float(project.get("total_cargo_transported", 0.0)), float(project.get("peak_construction_throughput", 0.0)), float(project.get("peak_power_demand", 0.0)), _format_ms(maxi(0, int(project.get("completed_at_ms", 0)) - int(project.get("started_at_ms", 0)))), _supplier_map_text(project.get("supplier_locations", {}))], 13, COLOR_TEXT))
	elif not runtime.is_empty():
		card.add_child(_label(I18n.core("megastructure.phase.invested") % [_project_summary(activity), _quantity_map_text(project.get("delivered_materials", {}))], 13, COLOR_MUTED))
		_add_blocker_label(card, runtime)
		var cancel_button := _button(I18n.core("megastructure.phase.cancel"), _command.bind(I18n.core("command.megastructure.cancel_phase"), Game.stop_construction_project.bind(int(runtime.get("slot", 0)))), false, COLOR_WARN)
		cancel_button.name = "CancelMegastructure_%s" % megastructure_id
		card.add_child(cancel_button)
	else:
		card.add_child(_label(I18n.core("megastructure.phase.next_bom") % _project_summary(activity), 13, COLOR_MUTED))
		var blocker: Dictionary = Game.simulation.megastructure_site_requirement_blocker(Game.state, current_phase, site_id)
		var start_button := _button(I18n.core("megastructure.phase.start"), _command.bind(I18n.core("command.megastructure.start_phase"), Game.start_megastructure_phase.bind(megastructure_id, 90)), not blocker.is_empty(), COLOR_GOOD)
		start_button.name = "StartMegastructure_%s" % megastructure_id
		card.add_child(start_button)
		if not blocker.is_empty():
			card.add_child(_label(I18n.core("megastructure.site.blocked") % _blocker_text(blocker), 13, COLOR_WARN))
	box.add_child(_wrap_card(card))


func _megastructure_progress(percent: int, stage_name: String) -> Control:
	var progress_box := VBoxContainer.new()
	progress_box.add_theme_constant_override("separation", 3)
	progress_box.add_child(_label(I18n.core("megastructure.progress.current") % [stage_name, percent], 14, COLOR_ACCENT))
	var bar := ProgressBar.new()
	bar.max_value = 100.0
	bar.value = percent
	bar.show_percentage = false
	bar.custom_minimum_size.y = UiTokens.layout_px(10)
	progress_box.add_child(bar)
	return progress_box


func _megastructure_phase_visual(definition: Dictionary, current_phase: int, complete: bool) -> Control:
	var row := GridContainer.new()
	row.columns = 4
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	var megastructure_id := String(definition.get("id", ""))
	var phases: Array = definition.get("phases", [])
	for index in phases.size():
		var phase := phases[index] as Dictionary
		var achieved := complete or index < current_phase
		var active := not complete and index == current_phase
		var tile := _card()
		tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tile.add_child(_label(I18n.core("megastructure.phase.tile") % ["✓" if achieved else ("◆" if active else "○"), index], 14, COLOR_GOOD if achieved else (COLOR_ACCENT if active else COLOR_MUTED)))
		var stage_label := _label(I18n.megastructure_stage(megastructure_id, index, String(phase.get("name", "Phase"))), 12, COLOR_TEXT)
		stage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tile.add_child(stage_label)
		row.add_child(tile)
	return row


func _supplier_map_text(values: Dictionary) -> String:
	if values.is_empty():
		return I18n.core("megastructure.supplier.local")
	var parts: Array[String] = []
	for location_id_value in values.keys():
		parts.append(I18n.core("megastructure.supplier.entry") % [_location_name(String(location_id_value)), float(values[location_id_value])])
	parts.sort()
	return I18n.core("format.list_separator").join(parts)


func _format_ms(milliseconds: int) -> String:
	var seconds := maxi(0, milliseconds) / 1000
	if seconds < 60:
		return I18n.t("format.duration_seconds") % seconds
	var minutes := seconds / 60
	if minutes < 60:
		return I18n.t("format.duration_minutes") % [minutes, seconds % 60]
	return I18n.t("format.duration_hours") % [minutes / 60, minutes % 60]


func _quantity_map_text(values: Dictionary) -> String:
	if values.is_empty():
		return I18n.core("megastructure.materials.none_delivered")
	var parts: Array[String] = []
	for item_id_value in values.keys():
		var item_id := String(item_id_value)
		var item := Game.content.items.get(item_id, {}) as Dictionary
		parts.append(I18n.t("format.item_quantity") % [_content_name(item, item_id), int(values.get(item_id, 0))])
	parts.sort()
	return I18n.core("format.list_separator").join(parts)


func _construction_runtime_for_activity(activity_id: String) -> Dictionary:
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")) == activity_id and String(operation.get("status", "IDLE")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			return operation
	return {}


func _rebuild_research() -> void:
	var box: VBoxContainer = _pages["research"]
	_clear(box)
	box.add_child(_page_title(I18n.core("research.title"), I18n.core("research.subtitle")))
	_add_unlock_banner(box, "research")
	var research_summary := _label("%s  %d   ·   %s  %s   ·   %s  %.1f" % [I18n.core("research.stat.completed_programs"), Game.state.completed_projects.size(), I18n.core("research.stat.technologies_spillovers"), I18n.core("common.ratio") % [Game.state.technologies.size(), Game.state.technology_spillovers.size()], I18n.core("research.stat.capacity"), Game.simulation.research_capacity(Game.state)], 12, COLOR_ACCENT)
	research_summary.autowrap_mode = TextServer.AUTOWRAP_OFF
	research_summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_wrap_card(research_summary))
	var current_id := String(Game.state.research.get("project_id", ""))
	if not current_id.is_empty():
		var current := Game.content.research_projects.get(current_id, {}) as Dictionary
		var current_stage := Game.simulation.research_stage_definition(Game.state, current, int(Game.state.research.get("stage_index", 0)), String(Game.state.research.get("route_id", "")))
		var card := HBoxContainer.new()
		card.add_theme_constant_override("separation", UiTokens.SPACING_MD)
		var identity := VBoxContainer.new()
		identity.custom_minimum_size.x = UiTokens.layout_px(310.0)
		identity.add_child(_label(I18n.core("research.current_project") % _content_name(current, current_id), 16, COLOR_ACCENT))
		var current_route_id := String(Game.state.research.get("route_id", ""))
		var current_route_name := current_route_id
		for route_value in current.get("routes", []):
			var route := route_value as Dictionary
			if String(route.get("id", "")) == current_route_id:
				current_route_name = _research_route_name(route)
				break
		var current_stage_values := [int(Game.state.research.get("stage_index", 0)) + 1, Game.simulation.research_stages(current).size(), _research_stage_kind_name(String(current_stage.get("kind", "THEORY"))), _research_stage_name(current, current_stage)]
		var current_stage_caption := I18n.core("research.current_stage") % current_stage_values
		if not current_route_id.is_empty():
			current_stage_values.append(current_route_name)
			current_stage_caption = I18n.core("research.current_stage_route") % current_stage_values
		identity.add_child(_label(current_stage_caption, 12, COLOR_TEXT_SECONDARY))
		card.add_child(identity)
		var progress := _operation_progress(Game.state.research, I18n.core("research.gameplay_state") % _status_text(Game.simulation.research_gameplay_state(Game.state)))
		progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_child(progress)
		var blocker_guidance := _research_blocker_guidance(Game.state.research.get("blocker", {}))
		if not blocker_guidance.is_empty():
			var guidance := _label(I18n.core("research.guidance") % blocker_guidance, 11, COLOR_WARN)
			guidance.custom_minimum_size.x = UiTokens.layout_px(260.0)
			card.add_child(guidance)
		box.add_child(_wrap_card(card))

	var graph_model := _research_graph_model()
	box.add_child(_build_research_project_index(graph_model))
	var tree := ResearchTreeViewScript.new()
	tree.project_selected.connect(_select_research_project)
	tree.project_action.connect(_start_research_from_graph)
	tree.pause_requested.connect(_pause_research_from_graph)
	tree.unlock_guidance_requested.connect(_open_research_unlock_guidance)
	box.add_child(tree)
	tree.configure(graph_model)


func _build_research_project_index(model: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(COLOR_PANEL_ALT, COLOR_BORDER, 3))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	column.add_child(_label(I18n.core("research.graph.project_index"), 11, COLOR_MUTED))
	var scroll := ScrollContainer.new()
	scroll.name = "ResearchProjectIndex"
	scroll.custom_minimum_size.y = UiTokens.layout_px(40.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	for node_value in model.get("nodes", []):
		var data := node_value as Dictionary
		var project_id := String(data.get("id", ""))
		var title := String(data.get("title", project_id))
		var status_id := String(data.get("status_id", "LOCKED"))
		var mode := String(data.get("action_mode", "LOCKED"))
		var enabled := bool(data.get("action_enabled", false))
		var reason := String(data.get("reason", ""))
		var routes: Array = data.get("routes", [])
		if mode == "GUIDANCE":
			var guidance := _button("%s · %s · %s" % [_status_text(status_id), title, I18n.core("research.prerequisites")], _open_research_unlock_guidance.bind(project_id), false, COLOR_MUTED)
			guidance.name = "ResearchUnlockGuidance_%s" % project_id
			guidance.tooltip_text = reason
			actions.add_child(guidance)
		elif mode == "PAUSE":
			var pause := _button(I18n.core("research.graph.title_action") % [title, String(data.get("action_label", ""))], _pause_research_from_graph, false, COLOR_WARN)
			pause.name = "PauseResearch_%s" % project_id
			actions.add_child(pause)
		elif mode == "RESUME":
			var resume := _button(I18n.core("research.graph.title_action") % [title, String(data.get("action_label", ""))], _start_research_from_graph.bind(project_id, String(data.get("active_route_id", ""))), not enabled, COLOR_ACCENT)
			resume.name = "ResumeResearch_%s" % project_id
			resume.tooltip_text = reason
			actions.add_child(resume)
		elif not routes.is_empty():
			for route_value in routes:
				var route := route_value as Dictionary
				var route_id := String(route.get("id", ""))
				var route_button := _button(I18n.core("research.graph.status_title_route") % [_status_text(status_id), title, String(route.get("label", route_id))], _start_research_from_graph.bind(project_id, route_id), not bool(route.get("enabled", enabled)), COLOR_GOOD if status_id == "COMPLETED" else COLOR_ACCENT)
				route_button.name = "StartResearch_%s_%s" % [project_id, route_id]
				route_button.tooltip_text = reason if not bool(route.get("enabled", enabled)) else String(route.get("description", ""))
				actions.add_child(route_button)
		elif mode == "START":
			var start := _button(I18n.core("research.graph.status_title") % [_status_text(status_id), title], _start_research_from_graph.bind(project_id, ""), not enabled, COLOR_ACCENT)
			start.name = "StartResearch_%s" % project_id
			start.tooltip_text = reason
			actions.add_child(start)
		else:
			var ledger := _button(I18n.core("research.graph.status_title") % [_status_text(status_id), title], Callable(), true, COLOR_GOOD if status_id == "COMPLETED" else COLOR_MUTED)
			ledger.name = "ResearchLedger_%s" % project_id
			actions.add_child(ledger)
	scroll.add_child(actions)
	column.add_child(scroll)
	panel.add_child(column)
	return panel


func _research_graph_model() -> Dictionary:
	var grant_projects := {}
	for project_value in Game.content.research_projects.values():
		var project := project_value as Dictionary
		var granted_technology := String(project.get("grants_technology", ""))
		if not granted_technology.is_empty():
			grant_projects[granted_technology] = String(project.get("id", ""))
	var current_id := String(Game.state.research.get("project_id", ""))
	var runtime_status := String(Game.state.research.get("status", "IDLE"))
	var nodes: Array[Dictionary] = []
	for project_value in Game.content.research_projects.values():
		var project := project_value as Dictionary
		var project_id := String(project.get("id", ""))
		var completed := bool(Game.state.completed_projects.get(project_id, false))
		var current := current_id == project_id
		var revealed := Game.simulation.definition_revealed(Game.state, project)
		var available := Game.simulation.research_project_available(Game.state, project)
		var busy := not current_id.is_empty() and not current
		var status_id := "COMPLETED" if completed else (runtime_status if current and runtime_status in ["RUNNING", "PAUSED", "BLOCKED"] else ("AVAILABLE" if revealed and available else "LOCKED"))
		var action_mode := "COMPLETED" if completed else ("PAUSE" if current and runtime_status in ["RUNNING", "BLOCKED"] else ("RESUME" if current and runtime_status == "PAUSED" else ("GUIDANCE" if not revealed else "START")))
		var action_enabled := (current and runtime_status == "PAUSED" and available) or (not current and not completed and revealed and available and not busy)
		var action_label := I18n.core("research.action.start_program")
		if action_mode == "PAUSE":
			action_label = I18n.core("research.action.stop")
		elif action_mode == "RESUME":
			action_label = I18n.core("research.action.resume")
		elif action_mode == "GUIDANCE":
			action_label = I18n.core("research.open_progression_objectives")
		var reason := _unmet_requirements(project.get("requirements", []))
		if busy:
			reason = I18n.core("research.current_project") % _content_name(Game.content.research_projects.get(current_id, {}), current_id)
		elif not available and reason.is_empty() and not completed:
			reason = I18n.core("block_reason.default")
		var technology_requirements: Array[String] = []
		_collect_research_technology_requirements(project.get("requirements", []), technology_requirements)
		var dependencies: Array[String] = []
		for technology_id in technology_requirements:
			var dependency_id := String(grant_projects.get(technology_id, ""))
			if not dependency_id.is_empty() and dependency_id != project_id and not dependencies.has(dependency_id):
				dependencies.append(dependency_id)
		var routes: Array[Dictionary] = []
		for route_value in project.get("routes", []):
			var route := route_value as Dictionary
			var route_id := String(route.get("id", ""))
			if completed and bool(Game.state.completed_research_routes.get(project_id, {}).get(route_id, false)):
				continue
			var route_available := action_enabled if not completed else (current_id.is_empty() and Game.simulation.research_project_available(Game.state, project, route_id))
			routes.append({"id":route_id, "label":I18n.core("research.action.supplemental_route") % _research_route_name(route) if completed else I18n.core("research.action.select_route") % _research_route_name(route), "description":_research_route_description(route), "enabled":route_available})
		if completed and not routes.is_empty() and current_id.is_empty():
			action_mode = "START"
			action_enabled = true
		nodes.append({
			"id":project_id,
			"title":_content_name(project, project_id),
			"summary":_project_summary(project),
			"lane":"SHIP_DEVELOPMENT" if String(project.get("project_type", "TECHNOLOGY")) == "SHIP_DEVELOPMENT" else "TECHNOLOGY",
			"dependencies":dependencies,
			"status_id":status_id,
			"status":_status_text(status_id),
			"action_mode":action_mode,
			"action_enabled":action_enabled,
			"action_label":action_label,
			"active_route_id":String(Game.state.research.get("route_id", "")) if current else "",
			"reason":reason,
			"routes":routes
		})
	return {
		"core_title":I18n.core("research.graph.core_title", "RESEARCH CORE"),
		"core_subtitle":I18n.core("research.graph.core_subtitle", "PROGRAM CONTROL"),
		"core_summary":I18n.core("research.graph.core_summary", "%d real programs") % nodes.size(),
		"status_format":I18n.core("research.graph.node_status"),
		"nodes":nodes
	}


func _collect_research_technology_requirements(value, result: Array[String]) -> void:
	if value is Array:
		for child in value:
			_collect_research_technology_requirements(child, result)
		return
	if not value is Dictionary:
		return
	var requirement := value as Dictionary
	if String(requirement.get("type", "")) == "technology":
		var technology_id := String(requirement.get("id", ""))
		if not technology_id.is_empty() and not result.has(technology_id):
			result.append(technology_id)
	for child in requirement.get("children", []):
		_collect_research_technology_requirements(child, result)


func _select_research_project(project_id: String) -> void:
	_selected_research_project_id = project_id
	_ui_state.select_context("research_project", project_id)
	_rebuild_sidebar()


func _start_research_from_graph(project_id: String, route_id: String) -> void:
	var supplemental := bool(Game.state.completed_projects.get(project_id, false)) and not route_id.is_empty()
	var command_label := I18n.core("command.research.supplemental_route") if supplemental else (I18n.core("command.research.start_route") if not route_id.is_empty() else I18n.t("button.start_research"))
	_command(command_label, Game.start_research_project.bind(project_id, route_id))


func _pause_research_from_graph() -> void:
	_command(I18n.core("command.research.stop"), Game.stop_research)


func _open_research_unlock_guidance(project_id: String) -> void:
	_selected_research_project_id = project_id
	_switch_page("system_map")


func _research_stage_kind_name(kind: String) -> String:
	match kind:
		"THEORY": return I18n.core("research.stage_kind.THEORY")
		"EXPERIMENT": return I18n.core("research.stage_kind.EXPERIMENT")
		"ENGINEERING": return I18n.core("research.stage_kind.ENGINEERING")
		"PROTOTYPE": return I18n.core("research.stage_kind.PROTOTYPE")
		"FIELD_TEST": return I18n.core("research.stage_kind.FIELD_TEST")
		"INDUSTRIALIZATION": return I18n.core("research.stage_kind.INDUSTRIALIZATION")
		_: return kind


func _research_stage_name(project: Dictionary, stage: Dictionary) -> String:
	var project_id := String(project.get("id", ""))
	var stage_id := String(stage.get("id", "research"))
	var key := "research.stage_name.%s.%s" % [project_id, stage_id]
	var translated := I18n.core(key)
	if translated != key:
		return translated
	if stage_id == "research":
		return I18n.core("research.stage_name.integrated", "Integrated Research")
	return String(stage.get("name", stage_id.replace("_", " ").capitalize()))


func _research_route_name(route: Dictionary) -> String:
	var route_id := String(route.get("id", ""))
	return I18n.core("research.route_name.%s" % route_id, String(route.get("name", route_id)))


func _research_route_description(route: Dictionary) -> String:
	var route_id := String(route.get("id", ""))
	return I18n.core("research.route_description.%s" % route_id, String(route.get("description", "")))


func _research_roadmap_text(project: Dictionary, active_stage_index: int) -> String:
	var lines: Array[String] = [I18n.core("research.roadmap.title")]
	for index in Game.simulation.research_stages(project).size():
		var stage := Game.simulation.research_stages(project)[index] as Dictionary
		var demands: Array[String] = []
		if not stage.get("costs", []).is_empty():
			demands.append(I18n.core("research.roadmap.industrial_supply") % _resource_list(stage.get("costs", [])))
		for requirement_value in stage.get("requirements", []):
			demands.append(Game.requirement_text(requirement_value as Dictionary))
		for requirement_value in stage.get("operating_conditions", []):
			demands.append(Game.requirement_text(requirement_value as Dictionary))
		var marker := "▶" if index == active_stage_index else ("✓" if active_stage_index >= 0 and index < active_stage_index else "○")
		lines.append(I18n.core("research.roadmap.stage_demands") % [marker, _research_stage_kind_name(String(stage.get("kind", "THEORY"))), _research_stage_name(project, stage), I18n.core("format.requirement_separator").join(demands)] if not demands.is_empty() else I18n.core("research.roadmap.stage") % [marker, _research_stage_kind_name(String(stage.get("kind", "THEORY"))), _research_stage_name(project, stage)])
	return "\n".join(lines)


func _research_blocker_guidance(blocker: Dictionary) -> String:
	return Game.research_blocker_resolution(blocker)


func _rebuild_fleet() -> void:
	var box: VBoxContainer = _pages["fleet"]
	_clear(box)
	box.add_child(_page_title(I18n.core("ships.title"), I18n.core("ships.subtitle")))
	_add_unlock_banner(box, "fleet")
	_ensure_selected_formation()
	var formation_selector := HFlowContainer.new()
	formation_selector.add_theme_constant_override("h_separation", 6)
	for formation_id_value in Game.state.formation_ids():
		var formation_id := String(formation_id_value)
		var formation_name := _formation_name(formation_id)
		var formation_button := _button(formation_name, _select_formation.bind(formation_id), formation_id == _selected_formation_id, COLOR_ACCENT)
		formation_button.name = "SelectFormation_%s" % formation_id
		formation_selector.add_child(formation_button)
	var new_formation_name := LineEdit.new()
	new_formation_name.placeholder_text = I18n.core("ships.formation.new_name", "New task force name")
	new_formation_name.custom_minimum_size.x = 190.0
	formation_selector.add_child(new_formation_name)
	var create_formation_button := _button(I18n.core("ships.formation.create", "Create Formation"), _create_formation.bind(new_formation_name), false, COLOR_GOOD)
	create_formation_button.name = "CreateFormation"
	formation_selector.add_child(create_formation_button)
	if _selected_formation_id != SpaceGameState.DEFAULT_FORMATION_ID:
		var delete_formation_button := _button(I18n.core("ships.formation.delete", "Delete Empty Formation"), _delete_selected_formation, not Game.state.formation_ship_ids(_selected_formation_id).is_empty(), COLOR_WARN)
		delete_formation_button.name = "DeleteFormation_%s" % _selected_formation_id
		formation_selector.add_child(delete_formation_button)
	box.add_child(formation_selector)
	var formation_ship_ids: Array = Game.state.formation_ship_ids(_selected_formation_id)
	var command_used := Game.simulation.fleet_command_usage(Game.state, formation_ship_ids)
	var command_capacity := Game.simulation.fleet_command_capacity(Game.state, _selected_formation_id)
	var active_count := Game.state.ships.filter(func(ship): return String(ship.get("maintenance_state", "ACTIVE")) == "ACTIVE").size()
	var repair_count := Game.state.ships.filter(func(ship): return String(ship.get("status", "")) == "REPAIRING").size()
	var summary := HBoxContainer.new()
	summary.add_theme_constant_override("separation", 8)
	summary.add_child(_stat_card(I18n.core("ships.stat.entities"), str(Game.state.ships.size()), COLOR_TEXT))
	summary.add_child(_stat_card(I18n.core("status.ACTIVE"), str(active_count), COLOR_GOOD))
	summary.add_child(_stat_card(I18n.core("status.REPAIRING"), str(repair_count), COLOR_WARN if repair_count > 0 else COLOR_MUTED))
	summary.add_child(_stat_card(I18n.core("ships.stat.expedition_command"), I18n.core("common.ratio") % [command_used, command_capacity], COLOR_ACCENT))
	box.add_child(summary)

	var section_tabs := HFlowContainer.new()
	section_tabs.add_theme_constant_override("h_separation", 6)
	section_tabs.add_theme_constant_override("v_separation", 6)
	for entry in [["roster", I18n.core("ships.tab.roster")], ["readiness", I18n.core("ships.tab.readiness")], ["shipyard", I18n.core("ships.tab.shipyard")], ["archive", I18n.core("ships.tab.archive")]]:
		var section_id := String(entry[0])
		var section_button := _button(String(entry[1]), _select_fleet_section.bind(section_id), section_id == _fleet_section, COLOR_ACCENT)
		section_button.name = "FleetSection_%s" % section_id
		section_tabs.add_child(section_button)
	var missions_button := _button(I18n.core("ships.missions", "Missions"), _switch_page.bind("expedition"), false, COLOR_ACCENT)
	missions_button.name = "ShipsMissions"
	section_tabs.add_child(missions_button)
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
	_save_ui_preferences()
	_request_active_page_refresh(true)


func _ensure_selected_formation() -> void:
	if not Game.state.fleet_formations.has(_selected_formation_id):
		_selected_formation_id = SpaceGameState.DEFAULT_FORMATION_ID
		if not Game.state.fleet_formations.has(_selected_formation_id) and not Game.state.formation_ids().is_empty():
			_selected_formation_id = String(Game.state.formation_ids()[0])


func _select_formation(formation_id: String) -> void:
	if not Game.state.fleet_formations.has(formation_id):
		return
	_selected_formation_id = formation_id
	_save_ui_preferences()
	_request_active_page_refresh(true)


func _create_formation(name_input: LineEdit) -> void:
	if Game.create_fleet_formation(name_input.text):
		_selected_formation_id = Game.last_created_formation_id
		_save_ui_preferences()
	_request_active_page_refresh(true)


func _delete_selected_formation() -> void:
	if Game.delete_fleet_formation(_selected_formation_id):
		_selected_formation_id = SpaceGameState.DEFAULT_FORMATION_ID
		_save_ui_preferences()
	_request_active_page_refresh(true)


func _build_fleet_readiness(box: VBoxContainer) -> void:
	var formation_id := _selected_formation_id
	box.add_child(_section_title(_formation_name(formation_id)))
	var formation: Dictionary = Game.state.fleet_logistics_runtime(formation_id).get("formation", {})
	var formation_card := _card()
	formation_card.add_child(_label(I18n.core("ships.readiness.doctrine"), 16, COLOR_ACCENT))
	var doctrine_row := HFlowContainer.new()
	doctrine_row.add_theme_constant_override("h_separation", 6)
	doctrine_row.add_theme_constant_override("v_separation", 6)
	for doctrine in ["HOLD_FORMATION", "AGGRESSIVE_PUSH", "MISSILE_SATURATION", "LONG_RANGE_ENGAGEMENT"]:
		var doctrine_button := _button(_status_text(doctrine), _command.bind(I18n.core("command.ships.set_doctrine"), Game.set_fleet_doctrine.bind(doctrine, formation_id)), String(formation.get("doctrine", "HOLD_FORMATION")) == doctrine, COLOR_ACCENT)
		doctrine_button.name = "FleetDoctrine_%s" % doctrine
		doctrine_row.add_child(doctrine_button)
	formation_card.add_child(doctrine_row)
	var retreat_policy: Dictionary = formation.get("retreat_policy", {"mode":"HULL_THRESHOLD", "threshold":0.25})
	formation_card.add_child(_label(I18n.core("ships.readiness.retreat_policy"), 16, COLOR_ACCENT))
	var retreat_row := HFlowContainer.new()
	retreat_row.add_theme_constant_override("h_separation", 6)
	retreat_row.add_theme_constant_override("v_separation", 6)
	for threshold in [0.15, 0.25, 0.40]:
		var retreat_button := _button(I18n.core("ships.readiness.hull_threshold") % (threshold * 100.0), _command.bind(I18n.core("command.ships.set_retreat_policy"), Game.set_fleet_retreat_policy.bind("HULL_THRESHOLD", threshold, formation_id)), String(retreat_policy.get("mode", "")) == "HULL_THRESHOLD" and is_equal_approx(float(retreat_policy.get("threshold", 0.25)), threshold), COLOR_ACCENT)
		retreat_button.name = "FleetRetreatPolicy_HULL_THRESHOLD_%d" % int(round(threshold * 100.0))
		retreat_row.add_child(retreat_button)
	var never_retreat_button := _button(I18n.core("ships.readiness.never_retreat"), _command.bind(I18n.core("command.ships.disable_retreat"), Game.set_fleet_retreat_policy.bind("NEVER", 0.25, formation_id)), String(retreat_policy.get("mode", "")) == "NEVER", COLOR_WARN)
	never_retreat_button.name = "FleetRetreatPolicy_NEVER"
	retreat_row.add_child(never_retreat_button)
	formation_card.add_child(retreat_row)
	formation_card.add_child(_label(I18n.core("ships.readiness.formation"), 16, COLOR_ACCENT))
	var zone_columns := HBoxContainer.new()
	zone_columns.add_theme_constant_override("separation", 8)
	for zone in ["FRONT", "MID", "REAR"]:
		var names: Array[String] = []
		for ship_value in Game.state.ships:
			var ship := ship_value as Dictionary
			var ship_id := String(ship.get("instance_id", ""))
			if Game.state.ship_formation_id(ship_id) == formation_id and String(formation.get("ship_zones", {}).get(ship_id, "FRONT")) == zone:
				names.append(String(ship.get("name", ship_id)))
		var zone_card := _stat_card(_zone_text(zone), "\n".join(names) if not names.is_empty() else I18n.core("ships.readiness.unconfigured"), COLOR_TEXT if not names.is_empty() else COLOR_MUTED)
		zone_columns.add_child(zone_card)
	formation_card.add_child(zone_columns)
	box.add_child(_wrap_card(formation_card))

	box.add_child(_section_title(I18n.core("ships.readiness.supply_plan")))
	var logistics: Dictionary = Game.state.fleet_logistics_runtime(formation_id)
	var plan: Dictionary = logistics.get("supply_plan", {})
	for item_id in ["kinetic_munitions", "chemical_propellant", "repair_supplies"]:
		var item := Game.content.items.get(item_id, {}) as Dictionary
		var input := _number_input(int(plan.get(item_id, 0)), 0, 100000, 1)
		input.name = "FleetSupplyTarget_%s" % item_id
		var row := _labeled_control(I18n.core("ships.readiness.carried") % [_content_name(item, item_id), Game.state.fleet_supply_quantity(item_id, formation_id)], input)
		var save_supply_button := _button(I18n.core("ships.readiness.save_target"), _save_fleet_supply_plan.bind(item_id, input))
		save_supply_button.name = "SetFleetSupplyPlan_%s" % item_id
		row.add_child(save_supply_button)
		box.add_child(row)
	var formation_empty := Game.state.formation_ship_ids(formation_id).is_empty()
	var auto_resupply_button := _button(I18n.core("ships.readiness.auto_resupply"), _command.bind(I18n.core("command.ships.auto_resupply"), Game.auto_resupply_fleet.bind(formation_id)), formation_empty, COLOR_GOOD)
	auto_resupply_button.name = "AutoResupplyFleet"
	if formation_empty:
		auto_resupply_button.tooltip_text = I18n.t("notice.expedition_fleet_empty", "Assign ships to a tactical formation at Starport first")
	box.add_child(auto_resupply_button)


func _save_fleet_supply_plan(item_id: String, input: SpinBox) -> void:
	_command(I18n.core("command.ships.save_supply_plan"), Game.set_fleet_supply_plan.bind(item_id, int(input.value), _selected_formation_id))


func _build_fleet_roster(box: VBoxContainer) -> void:
	box.add_child(_section_title(I18n.core("ships.roster.title")))
	var formation_id := _selected_formation_id
	var formation: Dictionary = Game.state.fleet_logistics_runtime(formation_id).get("formation", {})
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		var blueprint := Game.content.ships.get(String(ship.get("blueprint_id", "")), {}) as Dictionary
		var card := _card()
		card.add_child(_label(I18n.core("ships.roster.identity") % [String(ship.get("name", ship_id)), _content_name(blueprint, String(ship.get("blueprint_id", "")))], 18, COLOR_TEXT))
		var status_color := COLOR_WARN if String(ship.get("status", "")) in ["REPAIRING", "REFITTING", "REACTIVATING"] else COLOR_GOOD
		card.add_child(_label(I18n.core("ships.roster.status") % [_status_text(String(ship.get("status", "DOCKED"))), _assignment_name(Game.state.ship_formation_id(ship_id)), _zone_text(String(formation.get("ship_zones", {}).get(ship_id, "FRONT")))], 14, status_color))
		card.add_child(_label(I18n.core("ships.roster.maintenance") % [_status_text(String(ship.get("maintenance_state", "ACTIVE"))), float(ship.get("maintenance_coverage", 1.0)) * 100.0, float(ship.get("maintenance_debt", 0.0))], 13, COLOR_MUTED))
		var service_record: Dictionary = ship.get("service_record", {})
		card.add_child(_label(I18n.core("ships.roster.service_record") % [int(service_record.get("combat_deployments", 0)), int(service_record.get("victories", 0)), int(service_record.get("defeats", 0)), float(service_record.get("combat_experience", 0.0)), float(service_record.get("damage_dealt", 0.0))], 13, COLOR_MUTED))
		card.add_child(_label(I18n.core("ships.roster.modules") % _ship_modules_text(ship), 13, COLOR_MUTED))
		card.add_child(_label(I18n.core("ships.roster.roles") % _ship_loadout_roles_text(ship), 13, COLOR_ACCENT))
		card.add_child(_label(I18n.core("ships.roster.lifecycle"), 14, COLOR_ACCENT))
		var maintenance_row := HFlowContainer.new()
		maintenance_row.add_theme_constant_override("h_separation", 6)
		maintenance_row.add_theme_constant_override("v_separation", 6)
		var maintenance_state := String(ship.get("maintenance_state", "ACTIVE"))
		if maintenance_state == "MOTHBALLED":
			var reactivate_button := _button(I18n.core("ships.action.reactivate"), _command.bind(I18n.core("command.ships.reactivate"), Game.start_ship_reactivation.bind(ship_id)), String(ship.get("status", "")) != "DOCKED", COLOR_ACCENT)
			reactivate_button.name = "ReactivateShip_%s" % ship_id
			maintenance_row.add_child(reactivate_button)
		else:
			var active_button := _button(I18n.core("status.ACTIVE"), _command.bind(I18n.core("command.ships.set_active"), Game.set_ship_maintenance_state.bind(ship_id, "ACTIVE")), maintenance_state == "ACTIVE" or String(ship.get("status", "")) != "DOCKED")
			active_button.name = "SetShipActive_%s" % ship_id
			maintenance_row.add_child(active_button)
			var reserve_button := _button(I18n.core("status.READY_RESERVE"), _command.bind(I18n.core("command.ships.set_ready_reserve"), Game.set_ship_maintenance_state.bind(ship_id, "READY_RESERVE")), maintenance_state == "READY_RESERVE" or String(ship.get("status", "")) != "DOCKED")
			reserve_button.name = "SetShipReadyReserve_%s" % ship_id
			maintenance_row.add_child(reserve_button)
			var mothball_button := _button(I18n.core("ships.action.mothball"), _command.bind(I18n.core("command.ships.mothball"), Game.set_ship_maintenance_state.bind(ship_id, "MOTHBALLED")), String(ship.get("status", "")) != "DOCKED", COLOR_WARN)
			mothball_button.name = "MothballShip_%s" % ship_id
			maintenance_row.add_child(mothball_button)
		card.add_child(maintenance_row)

		card.add_child(_label(I18n.core("ships.roster.assignment"), 14, COLOR_ACCENT))
		var assignment_row := HFlowContainer.new()
		assignment_row.add_theme_constant_override("h_separation", 6)
		assignment_row.add_theme_constant_override("v_separation", 6)
		var standby_availability := Game.ship_formation_assignment_availability(ship_id, "")
		var standby_button := _button(I18n.core("ships.assignment.standby"), _command.bind(I18n.core("command.ships.assign_standby"), Game.set_ship_formation_assignment.bind(ship_id, "")), not bool(standby_availability.get("allowed", false)))
		standby_button.name = "AssignStandby_%s" % ship_id
		if standby_button.disabled: standby_button.tooltip_text = String(standby_availability.get("reason", I18n.core("ships.disabled.must_be_docked")))
		assignment_row.add_child(standby_button)
		var formation_availability := Game.ship_formation_assignment_availability(ship_id, formation_id)
		var formation_name := _formation_name(formation_id)
		var formation_button := _button(I18n.core("ships.assignment.formation", "Join %s") % formation_name, _command.bind(I18n.core("command.ships.assign_formation", "Assign to tactical formation"), Game.set_ship_formation_assignment.bind(ship_id, formation_id)), not bool(formation_availability.get("allowed", false)))
		formation_button.name = "AssignFormation_%s" % ship_id
		if formation_button.disabled: formation_button.tooltip_text = String(formation_availability.get("reason", I18n.core("ships.disabled.must_be_docked")))
		assignment_row.add_child(formation_button)
		card.add_child(assignment_row)
		card.add_child(_label(I18n.core("ships.roster.combat_position"), 14, COLOR_ACCENT))
		var zone_row := HFlowContainer.new()
		zone_row.add_theme_constant_override("h_separation", 6)
		zone_row.add_theme_constant_override("v_separation", 6)
		var current_zone := String(formation.get("ship_zones", {}).get(ship_id, "FRONT"))
		for zone in ["FRONT", "MID", "REAR"]:
			var zone_button := _button(_zone_text(zone), _command.bind(I18n.core("command.ships.set_combat_position"), Game.set_ship_combat_zone.bind(ship_id, zone, formation_id)), Game.state.ship_formation_id(ship_id) != formation_id or current_zone == zone, COLOR_ACCENT)
			zone_button.name = "ShipCombatZone_%s_%s" % [ship_id, zone]
			zone_row.add_child(zone_button)
		card.add_child(zone_row)
		var save_loadout_button := _button(I18n.core("ships.action.save_configuration"), _command.bind(I18n.core("command.ships.save_configuration"), Game.save_ship_loadout.bind(ship_id)), String(ship.get("status", "DOCKED")) != "DOCKED", COLOR_GOOD)
		save_loadout_button.name = "SaveShipLoadout_%s" % ship_id
		card.add_child(save_loadout_button)
		var matching_loadouts: Array = Game.state.saved_loadouts.values().filter(func(loadout): return String(loadout.get("blueprint_id", "")) == String(ship.get("blueprint_id", "")))
		matching_loadouts.sort_custom(func(a, b): return String(a.get("name", a.get("id", ""))) < String(b.get("name", b.get("id", ""))))
		if not matching_loadouts.is_empty():
			card.add_child(_label(I18n.core("ships.saved_configuration"), 14, COLOR_ACCENT))
		for loadout_value in matching_loadouts:
			var loadout := loadout_value as Dictionary
			var loadout_id := String(loadout.get("id", ""))
			var loadout_modules: Array = loadout.get("modules", []).duplicate()
			var loadout_availability: Dictionary = Game.ship_loadout_availability(ship_id, loadout_modules)
			var loadout_row := HFlowContainer.new()
			loadout_row.add_theme_constant_override("h_separation", 6)
			loadout_row.add_theme_constant_override("v_separation", 6)
			loadout_row.add_child(_label(String(loadout.get("name", loadout_id)), 13, COLOR_MUTED))
			var apply_loadout_button := _button(I18n.core("common.apply"), _command.bind(I18n.core("command.ships.apply_configuration"), Game.apply_ship_loadout.bind(ship_id, loadout_id)), not bool(loadout_availability.get("allowed", false)))
			apply_loadout_button.name = "ApplyShipLoadout_%s_%s" % [ship_id, loadout_id]
			if apply_loadout_button.disabled:
				apply_loadout_button.tooltip_text = String(loadout_availability.get("reason", I18n.core("ships.disabled.must_be_docked")))
			loadout_row.add_child(apply_loadout_button)
			var delete_loadout_button := _button(I18n.core("ships.action.delete"), _command.bind(I18n.core("command.ships.delete_configuration"), Game.delete_ship_loadout.bind(loadout_id)), false, COLOR_WARN)
			delete_loadout_button.name = "DeleteShipLoadout_%s" % loadout_id
			loadout_row.add_child(delete_loadout_button)
			card.add_child(loadout_row)

		var module_choices := _compatible_loadout_modules(ship)
		if not module_choices.is_empty():
			card.add_child(_label(I18n.core("ships.roster.available_loadouts"), 14, COLOR_ACCENT))
			for choice_value in module_choices:
				var choice := choice_value as Dictionary
				var new_id := String(choice.get("new_id", ""))
				var old_id := String(choice.get("old_id", ""))
				var module_def := Game.content.modules.get(new_id, {}) as Dictionary
				var old_def := Game.content.modules.get(old_id, {}) as Dictionary
				var button_text := I18n.core("ships.action.replace_module") % [_content_name(old_def, old_id), _content_name(module_def, new_id)]
				var replacement_modules: Array = Game.state.ship_module_definition_ids(ship).duplicate()
				var replacement_index := replacement_modules.find(old_id)
				if replacement_index >= 0:
					replacement_modules[replacement_index] = new_id
				var replacement_availability: Dictionary = Game.ship_loadout_availability(ship_id, replacement_modules)
				var replace_button := _button(button_text, _command.bind(I18n.core("command.ships.start_refit"), Game.replace_ship_module.bind(ship_id, old_id, new_id)), not bool(replacement_availability.get("allowed", false)))
				replace_button.name = "ReplaceModule_%s_%s_%s" % [ship_id, old_id, new_id]
				if replace_button.disabled:
					replace_button.tooltip_text = String(replacement_availability.get("reason", I18n.core("ships.disabled.must_be_docked")))
				card.add_child(replace_button)
		var install_choices := _installable_loadout_modules(ship)
		if not install_choices.is_empty():
			card.add_child(_label(I18n.core("ships.install_module", "Install into an empty slot"), 14, COLOR_ACCENT))
			for module_id_value in install_choices:
				var module_id := String(module_id_value)
				var module_definition := Game.content.modules.get(module_id, {}) as Dictionary
				var desired_modules: Array = Game.state.ship_module_definition_ids(ship).duplicate()
				desired_modules.append(module_id)
				var availability: Dictionary = Game.ship_loadout_availability(ship_id, desired_modules)
				var install_button := _button(
					I18n.core("ships.install_module_action", "Install %s") % _content_name(module_definition, module_id),
					_command.bind(I18n.core("command.ships.install_module"), Game.install_ship_module.bind(ship_id, module_id)),
					not bool(availability.get("allowed", false))
				)
				install_button.name = "InstallModule_%s_%s" % [ship_id, module_id]
				if install_button.disabled:
					install_button.tooltip_text = String(availability.get("reason", I18n.core("ships.disabled.must_be_docked")))
				card.add_child(install_button)
		var installed_definitions: Array = Game.state.ship_module_definition_ids(ship)
		if not installed_definitions.is_empty():
			card.add_child(_label(I18n.core("ships.remove_module", "Remove an installed module"), 14, COLOR_ACCENT))
			for module_id_value in installed_definitions:
				var module_id := String(module_id_value)
				var module_definition := Game.content.modules.get(module_id, {}) as Dictionary
				var removal_modules: Array = installed_definitions.duplicate()
				var removal_index := removal_modules.find(module_id)
				if removal_index >= 0:
					removal_modules.remove_at(removal_index)
				var removal_availability: Dictionary = Game.ship_loadout_availability(ship_id, removal_modules)
				var remove_button := _button(
					I18n.core("ships.remove_module_action", "Remove %s") % _content_name(module_definition, module_id),
					_command.bind(I18n.core("command.ships.remove_module"), Game.remove_ship_module.bind(ship_id, module_id)),
					not bool(removal_availability.get("allowed", false)),
					COLOR_WARN
				)
				remove_button.name = "RemoveModule_%s_%s" % [ship_id, module_id]
				if remove_button.disabled:
					remove_button.tooltip_text = String(removal_availability.get("reason", I18n.core("ships.disabled.must_be_docked")))
				card.add_child(remove_button)
		if String(ship.get("status", "")) == "DOCKED" and Game.state.ship_formation_id(ship_id).is_empty():
			card.add_child(_button(I18n.core("ships.action.scrap"), _command.bind(I18n.core("command.ships.scrap"), Game.scrap_ship.bind(ship_id)), false, COLOR_WARN))
		box.add_child(_wrap_card(card))
	if Game.state.ships.is_empty():
		box.add_child(_card_text(I18n.core("ships.roster.empty"), COLOR_WARN))


func _ship_loadout_roles_text(ship: Dictionary) -> String:
	var roles: Array[String] = []
	var role_capabilities := {
		"bulk_freight":I18n.core("ships.role.bulk_freight"),
		"cryogenic_freight":I18n.core("ships.role.cryogenic_freight"),
		"repair_support":I18n.core("ships.role.repair_support"),
		"survey_support":I18n.core("ships.role.survey_support"),
		"armed":I18n.core("ships.role.armed")
	}
	for capability_id_value in role_capabilities.keys():
		var capability_id := String(capability_id_value)
		if Game.simulation.ship_loadout_capability_value(Game.state, ship, capability_id) > 0.0:
			roles.append(String(role_capabilities[capability_id]))
	return I18n.core("format.list_separator").join(roles) if not roles.is_empty() else I18n.core("ships.role.general")


func _build_fleet_archive(box: VBoxContainer) -> void:
	if not Game.state.refit_projects.is_empty():
		box.add_child(_section_title(I18n.core("ships.archive.refit_projects")))
		for project_value in Game.state.refit_projects:
			var project := project_value as Dictionary
			var project_card := _card()
			var refit_ship := Game.state.ship_by_id(String(project.get("ship_id", "")))
			project_card.add_child(_label(I18n.core("ships.archive.refit_progress") % [String(refit_ship.get("name", project.get("ship_id", ""))), float(project.get("completed_segments", 0)), _resource_dictionary(project.get("consumed_bom", {}))], 13, COLOR_MUTED))
			var cancel_refit_button := _button(I18n.core("ships.archive.cancel_refit"), _command.bind(I18n.core("command.ships.cancel_refit"), Game.cancel_ship_refit.bind(String(project.get("project_id", "")))), false, COLOR_WARN)
			cancel_refit_button.name = "CancelShipRefit_%s" % String(project.get("project_id", ""))
			project_card.add_child(cancel_refit_button)
			box.add_child(_wrap_card(project_card))
	if not Game.state.ship_service_projects.is_empty():
		box.add_child(_section_title(I18n.core("ships.archive.service_projects")))
		for project_value in Game.state.ship_service_projects:
			var project := project_value as Dictionary
			var service_ship := Game.state.ship_by_id(String(project.get("ship_id", "")))
			box.add_child(_card_text(I18n.core("ships.archive.service_progress") % [_status_text(String(project.get("project_kind", "SERVICE"))), String(service_ship.get("name", project.get("ship_id", ""))), 100.0 * float(project.get("progress_ms", 0.0)) / maxf(1.0, float(project.get("duration_ms", 1.0)))], COLOR_MUTED))
	else:
		box.add_child(_card_text(I18n.core("ships.archive.no_service_projects"), COLOR_MUTED))
	box.add_child(_section_title(I18n.core("ships.archive.title")))
	if not Game.state.naval_archive.is_empty():
		for archive_value in Game.state.naval_archive:
			var archive := archive_value as Dictionary
			var archived_blueprint := Game.content.ships.get(String(archive.get("blueprint_id", "")), {}) as Dictionary
			box.add_child(_card_text(I18n.core("ships.archive.entry") % [String(archive.get("name", archive.get("ship_id", ""))), _content_name(archived_blueprint, String(archive.get("blueprint_id", ""))), _format_ms(int(archive.get("commissioned_at_ms", 0))), _format_ms(int(archive.get("scrapped_at_ms", 0)))], COLOR_MUTED))
	else:
		box.add_child(_card_text(I18n.core("ships.archive.empty"), COLOR_MUTED))


func _build_fleet_shipyard(box: VBoxContainer) -> void:
	box.add_child(_section_title(I18n.core("ships.shipyard.queue")))
	for order_index in Game.state.shipyard_queue.size():
		var order_value = Game.state.shipyard_queue[order_index]
		var order := order_value as Dictionary
		var order_card := _card()
		var order_plan_id := String(order.get("plan_id", ""))
		var order_plan := Game.content.ship_construction_projects.get(order_plan_id, {}) as Dictionary
		var design := Game.state.ship_designs.get(String(order.get("design_id", "")), {}) as Dictionary
		var order_name := String(design.get("name", _content_name(order_plan, I18n.core("ships.shipyard.order"))))
		order_card.add_child(_label(I18n.core("ships.shipyard.order_header") % [order_name, _status_text(String(order.get("status", "QUEUED")))], 16, COLOR_TEXT))
		order_card.add_child(_label(I18n.core("ships.shipyard.order_progress") % [float(order.get("completed_segments", 0)), int(order.get("quantity_completed", 0)), int(order.get("quantity_total", 1)), int(order.get("quantity_remaining", 0))], 13, COLOR_MUTED))
		_add_blocker_label(order_card, order)
		var queue_actions := HFlowContainer.new()
		queue_actions.add_theme_constant_override("h_separation", 6)
		var order_project_id := String(order.get("project_id", ""))
		var move_up_button := _button(I18n.core("ships.shipyard.move_up"), _command.bind(I18n.core("command.ships.reorder_shipyard"), Game.move_shipyard_project.bind(String(order.get("plan_id", "")), order_index - 1)), order_index <= 0)
		move_up_button.name = "ReorderShipBuildUp_%s" % order_project_id
		queue_actions.add_child(move_up_button)
		var move_down_button := _button(I18n.core("ships.shipyard.move_down"), _command.bind(I18n.core("command.ships.reorder_shipyard"), Game.move_shipyard_project.bind(String(order.get("plan_id", "")), order_index + 1)), order_index >= Game.state.shipyard_queue.size() - 1)
		move_down_button.name = "ReorderShipBuildDown_%s" % order_project_id
		queue_actions.add_child(move_down_button)
		var cancel_order_button := _button(I18n.core("ships.shipyard.cancel_order"), _command.bind(I18n.core("command.ships.cancel_order"), Game.cancel_shipyard_project.bind(order_project_id)), false, COLOR_WARN)
		cancel_order_button.name = "CancelShipBuild_%s" % order_project_id
		queue_actions.add_child(cancel_order_button)
		order_card.add_child(queue_actions)
		box.add_child(_wrap_card(order_card))
	if Game.state.shipyard_queue.is_empty():
		box.add_child(_card_text(I18n.core("ships.shipyard.empty"), COLOR_MUTED))
	box.add_child(_section_title(I18n.core("ships.shipyard.saved_designs", "SAVED SHIP DESIGNS")))
	box.add_child(_build_ship_design_library())
	box.add_child(_section_title(I18n.core("ships.shipyard.canvas_title")))
	box.add_child(_card_text(I18n.core("ships.shipyard.canvas_help", "Start with an empty canvas. Drag a hull from the Ship tab, add parts from the Parts tab, then connect matching shapes yourself. Grid spacing is a physical scale: zoom out for capital ships and zoom in for small hulls. A part must also fit the socket tier and diameter."), COLOR_MUTED))
	box.add_child(_build_ship_assembly_palette())
	var controls := HFlowContainer.new()
	controls.add_theme_constant_override("h_separation", 6)
	_ship_design_name_input = LineEdit.new()
	_ship_design_name_input.name = "ShipDesignName"
	_ship_design_name_input.placeholder_text = I18n.core("ships.shipyard.design_name_placeholder", "Design name")
	_ship_design_name_input.custom_minimum_size.x = UiTokens.layout_px(260.0)
	if not _selected_ship_design_id.is_empty():
		_ship_design_name_input.text = String(Game.state.ship_designs.get(_selected_ship_design_id, {}).get("name", ""))
	controls.add_child(_ship_design_name_input)
	var validate := _button(I18n.core("ships.shipyard.validate_design", "VALIDATE"), _validate_ship_assembly_draft, false, COLOR_ACCENT)
	validate.name = "ValidateShipDesign"
	controls.add_child(validate)
	var save := _button(I18n.core("ships.shipyard.save_design", "SAVE DESIGN"), _save_ship_assembly_draft, false, COLOR_GOOD)
	save.name = "SaveShipDesign"
	controls.add_child(save)
	var clear := _button(I18n.core("ships.shipyard.clear_design", "CLEAR CANVAS"), _clear_ship_assembly_draft, false, COLOR_WARN)
	clear.name = "ClearShipDesign"
	controls.add_child(clear)
	box.add_child(controls)
	_ship_assembly_view = ShipAssemblyMapViewScript.new()
	_ship_assembly_view.draft_changed.connect(_on_ship_assembly_draft_changed)
	_ship_assembly_view.entity_selected.connect(_select_shipyard_entity)
	_ship_assembly_view.notice_requested.connect(_on_ship_assembly_notice)
	box.add_child(_ship_assembly_view)
	_ship_assembly_view.configure(_ship_assembly_catalog(), _ship_assembly_draft)


func _build_ship_design_library() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(COLOR_PANEL_ALT, COLOR_BORDER, 3))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	var design_ids: Array = Game.state.ship_designs.keys()
	design_ids.sort()
	if design_ids.is_empty():
		column.add_child(_label(I18n.core("ships.shipyard.no_saved_designs", "No saved design. Assemble and validate one on the canvas below."), 12, COLOR_MUTED))
	for design_id_value in design_ids:
		var design_id := String(design_id_value)
		var design := Game.state.ship_designs[design_id] as Dictionary
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 6)
		var load := _button(String(design.get("name", design_id)), _load_ship_design.bind(design_id), design_id == _selected_ship_design_id, COLOR_ACCENT)
		load.name = "LoadShipDesign_%s" % design_id
		load.custom_minimum_size.x = UiTokens.layout_px(260.0)
		row.add_child(load)
		for quantity in [1, 5, 20]:
			var build := _button(I18n.core("ships.shipyard.build_batch") % quantity, _enqueue_saved_ship_design.bind(design_id, quantity), false, COLOR_GOOD)
			build.name = "BuildShipDesign_%s_%d" % [design_id, quantity]
			row.add_child(build)
		var remove := _button(I18n.core("ships.shipyard.delete_design"), _delete_ship_design.bind(design_id), false, COLOR_WARN)
		remove.name = "DeleteShipDesign_%s" % design_id
		row.add_child(remove)
		column.add_child(row)
	panel.add_child(column)
	return panel


func _build_ship_assembly_palette() -> Control:
	var tabs := TabContainer.new()
	tabs.name = "ShipAssemblyPalette"
	# One compact shelf is enough; overflowing unlocked hulls/parts already have
	# their own scroll containers.  The saved height belongs to the canvas.
	tabs.custom_minimum_size.y = UiTokens.layout_px(158.0)
	var hull_scroll := ScrollContainer.new()
	hull_scroll.name = "Ships"
	hull_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	hull_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var hull_row := HBoxContainer.new()
	hull_row.add_theme_constant_override("separation", 6)
	var plans: Array[Dictionary] = []
	for plan_value in Game.content.ship_construction_projects.values():
		plans.append(plan_value as Dictionary)
	plans.sort_custom(func(a: Dictionary, b: Dictionary): return _content_name(a, String(a.get("id", ""))) < _content_name(b, String(b.get("id", ""))))
	for plan in plans:
		var plan_id := String(plan.get("id", ""))
		var hull_id := String(plan.get("ship_id", ""))
		var hull := Game.content.ships.get(hull_id, {}) as Dictionary
		var unlocked := bool(Game.state.unlocked_ship_plans.get(plan_id, false))
		# The palette is an inventory of hull models the player can actually
		# construct, not a catalogue of every hull definition in the database.
		if not unlocked:
			continue
		var item := ShipAssemblyPaletteItemScript.new()
		item.name = "ShipPaletteHull_%s" % plan_id
		var ui_visual := hull.get("ui_visual", {}) as Dictionary
		item.configure({"ship_assembly_palette":true, "kind":"hull", "plan_id":plan_id, "definition_id":hull_id}, "%s\n%s · %d slots" % [_content_name(hull, hull_id), String(hull.get("class", "Ship")), int(hull.get("module_slots", 0))], true, I18n.core("ships.shipyard.drag_hull", "Drag this hull onto the empty canvas"), String(ui_visual.get("topdown_texture", "")))
		hull_row.add_child(item)
	hull_scroll.add_child(hull_row)
	tabs.add_child(hull_scroll)
	var parts_scroll := ScrollContainer.new()
	parts_scroll.name = "Parts"
	parts_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	parts_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	var parts_flow := HFlowContainer.new()
	parts_flow.add_theme_constant_override("h_separation", 6)
	parts_flow.add_theme_constant_override("v_separation", 6)
	var module_ids: Array = Game.content.modules.keys()
	module_ids.sort()
	for module_id_value in module_ids:
		var module_id := String(module_id_value)
		var module := Game.content.modules[module_id] as Dictionary
		if not Game.simulation.definition_revealed(Game.state, module):
			continue
		var slot := String(module.get("slot", "utility"))
		var item := ShipAssemblyPaletteItemScript.new()
		item.name = "ShipPalettePart_%s" % module_id
		item.configure({"ship_assembly_palette":true, "kind":"module", "definition_id":module_id, "slot":slot, "mount_role":Game.ship_module_mount_role(module_id)}, "%s\n%s · %s" % [_content_name(module, module_id), String(module.get("size", "S")), I18n.core("ships.shipyard.slot.%s" % slot)], true, I18n.core("ships.shipyard.drag_part", "Drag this part onto the canvas, then connect its color-coded interface"), ShipAssemblyMapViewScript.module_icon_path(module))
		parts_flow.add_child(item)
	parts_scroll.add_child(parts_flow)
	tabs.add_child(parts_scroll)
	tabs.set_tab_title(0, I18n.core("ships.shipyard.palette_ships", "舰船"))
	tabs.set_tab_title(1, I18n.core("ships.shipyard.palette_parts", "零件"))
	return tabs


func _ship_assembly_catalog() -> Dictionary:
	var plans := {}
	for plan_id_value in Game.content.ship_construction_projects.keys():
		var plan_id := String(plan_id_value)
		var plan := (Game.content.ship_construction_projects[plan_id] as Dictionary).duplicate(true)
		plan["title"] = _content_name(plan, plan_id)
		plan["assembly_sockets"] = Game.ship_design_socket_schema(plan_id)
		plans[plan_id] = plan
	var hulls := {}
	for hull_id_value in Game.content.ships.keys():
		var hull_id := String(hull_id_value)
		var hull := (Game.content.ships[hull_id] as Dictionary).duplicate(true)
		hull["title"] = _content_name(hull, hull_id)
		hulls[hull_id] = hull
	var modules := {}
	for module_id_value in Game.content.modules.keys():
		var module_id := String(module_id_value)
		var module := (Game.content.modules[module_id] as Dictionary).duplicate(true)
		module["title"] = _content_name(module, module_id)
		module["assembly_mount"] = Game.ship_module_mount_role(module_id)
		modules[module_id] = module
	return {"plans":plans, "hulls":hulls, "modules":modules, "socket_label_format":I18n.core("ships.shipyard.socket_label"), "module_label_format":I18n.core("ships.shipyard.part_label"), "hull_summary_format":I18n.core("ships.shipyard.hull_backplane"), "core_socket_format":I18n.core("ships.shipyard.energy_core_socket"), "slot_labels":{
		"weapon":I18n.core("ships.shipyard.slot.weapon"), "shield":I18n.core("ships.shipyard.slot.shield"), "drive":I18n.core("ships.shipyard.slot.drive"), "utility":I18n.core("ships.shipyard.slot.utility"), "core":I18n.core("ships.shipyard.slot.core")
	}}


func _ship_port_color_legend() -> Control:
	var legend := HFlowContainer.new()
	legend.add_theme_constant_override("h_separation", 12)
	legend.add_theme_constant_override("v_separation", 4)
	for definition in [
		{"slot":"weapon", "label":I18n.core("ships.shipyard.slot.weapon")},
		{"slot":"drive", "label":I18n.core("ships.shipyard.slot.drive")},
		{"slot":"utility", "label":I18n.core("ships.shipyard.slot.utility")},
		{"slot":"shield", "label":I18n.core("ships.shipyard.slot.shield")},
		{"slot":"core", "label":I18n.core("ships.shipyard.slot.core")}
	]:
		var label := _label("● %s" % String(definition.get("label", "")), 12, _ship_module_slot_tone(String(definition.get("slot", "")), String(definition.get("mount_role", ""))))
		legend.add_child(label)
	return legend


func _on_ship_assembly_draft_changed(snapshot: Dictionary) -> void:
	_ship_assembly_draft = snapshot.duplicate(true)
	_selected_shipyard_plan_id = String(snapshot.get("plan_id", ""))
	if not _selected_shipyard_plan_id.is_empty():
		_ui_state.select_context("ship_assembly", _selected_shipyard_plan_id)
	_rebuild_sidebar()


func _on_ship_assembly_notice(code: String) -> void:
	var messages := {
		"HULL_ALREADY_PLACED":I18n.core("ships.shipyard.notice.hull_already_placed", "Only one hull can be placed. Clear or delete it before choosing another."),
		"PORT_DIRECTION_INVALID":I18n.core("ships.shipyard.notice.port_direction", "Connect a part plug to a hull socket."),
		"PORT_SHAPE_MISMATCH":I18n.core("ships.shipyard.notice.port_mismatch", "That part does not match the socket's connector and mount family."),
		"PORT_SIZE_MISMATCH":I18n.core("ships.shipyard.notice.port_size_mismatch", "That part is physically larger than this socket tier. Choose a larger socket or a smaller part."),
		"PORT_ALREADY_OCCUPIED":I18n.core("ships.shipyard.notice.port_occupied", "That part or socket is already connected.")
	}
	_append_log(String(messages.get(code, code)))


func _validate_ship_assembly_draft() -> void:
	var snapshot := _ship_assembly_view.draft_snapshot() if is_instance_valid(_ship_assembly_view) else _ship_assembly_draft
	var validation := Game.ship_design_validation(String(snapshot.get("plan_id", "")), snapshot.get("nodes", []), snapshot.get("connections", []))
	_append_log(String(validation.get("reason", I18n.t("notice.ship_design_invalid", "Ship design is invalid"))))
	_rebuild_sidebar()


func _save_ship_assembly_draft() -> void:
	var snapshot := _ship_assembly_view.draft_snapshot() if is_instance_valid(_ship_assembly_view) else _ship_assembly_draft
	var requested_name := _ship_design_name_input.text if is_instance_valid(_ship_design_name_input) else ""
	_command(I18n.core("command.ships.save_design", "Save ship design"), _commit_ship_design.bind(snapshot, requested_name))


func _commit_ship_design(snapshot: Dictionary, requested_name: String) -> bool:
	var success := Game.save_ship_design(_selected_ship_design_id, requested_name, String(snapshot.get("plan_id", "")), snapshot.get("nodes", []), snapshot.get("connections", []))
	if success:
		_selected_ship_design_id = Game.last_saved_ship_design_id
		_ship_assembly_draft = (Game.state.ship_designs.get(_selected_ship_design_id, {}) as Dictionary).duplicate(true)
	return success


func _clear_ship_assembly_draft() -> void:
	_selected_ship_design_id = ""
	_selected_shipyard_plan_id = ""
	_selected_shipyard_entity = {"kind":"hull", "id":""}
	_ship_assembly_draft = {}
	if is_instance_valid(_ship_design_name_input):
		_ship_design_name_input.text = ""
	if is_instance_valid(_ship_assembly_view):
		_ship_assembly_view.clear_draft(false)
	_rebuild_sidebar()


func _load_ship_design(design_id: String) -> void:
	var design := Game.state.ship_designs.get(design_id, {}) as Dictionary
	if design.is_empty():
		return
	_selected_ship_design_id = design_id
	_ship_assembly_draft = design.duplicate(true)
	_selected_shipyard_plan_id = String(design.get("plan_id", ""))
	_selected_shipyard_entity = {"kind":"hull", "id":String(design.get("hull_id", ""))}
	_request_active_page_refresh(true)


func _delete_ship_design(design_id: String) -> void:
	_command(I18n.core("command.ships.delete_design", "Delete ship design"), _commit_delete_ship_design.bind(design_id))


func _commit_delete_ship_design(design_id: String) -> bool:
	var success := Game.delete_ship_design(design_id)
	if success and _selected_ship_design_id == design_id:
		_selected_ship_design_id = ""
		_selected_shipyard_plan_id = ""
		_ship_assembly_draft = {}
	return success


func _enqueue_saved_ship_design(design_id: String, quantity: int) -> void:
	_command(I18n.core("command.ships.enqueue"), Game.enqueue_saved_ship_design.bind(design_id, quantity))


func _select_shipyard_entity(kind: String, entity_id: String) -> void:
	_selected_shipyard_entity = {"kind":kind, "id":entity_id}
	_ui_state.select_context("ship_assembly", entity_id)
	if _ui_state.right_inspector_collapsed:
		_ui_state.right_inspector_collapsed = false
		if is_instance_valid(_shell):
			_shell.set_right_collapsed(false)
	_rebuild_sidebar()


func _ship_module_slot_tone(slot: String, mount_role: String = "") -> Color:
	if mount_role == "STRUCTURAL":
		return COLOR_ACCENT.lerp(Color("78a8d8"), 0.55)
	match slot:
		"core": return COLOR_WARN
		"drive": return COLOR_ACCENT
		"weapon": return COLOR_BAD
		"shield": return COLOR_ACCENT.lerp(Color("78a8d8"), 0.55)
		_: return COLOR_GOOD


func _rebuild_expedition() -> void:
	var box: VBoxContainer = _pages["expedition"]
	_clear(box)
	box.add_child(_page_title(I18n.core("page.expedition"), I18n.core("expedition.subtitle")))

	_ensure_selected_formation()
	var expedition_ids: Array = Game.state.formation_ship_ids(_selected_formation_id)
	var roster: Array[String] = []
	for ship_id_value in expedition_ids:
		var ship := Game.state.ship_by_id(String(ship_id_value))
		roster.append(String(ship.get("name", ship_id_value)))
	var command_used := Game.simulation.fleet_command_usage(Game.state, expedition_ids)
	var command_capacity := Game.simulation.fleet_command_capacity(Game.state, _selected_formation_id)
	var cargo_used := Game.simulation.fleet_cargo_used(Game.state, _selected_formation_id)
	var cargo_capacity := Game.simulation.fleet_cargo_capacity(Game.state, expedition_ids)
	var ready := Game.formation_ready(_selected_formation_id)
	box.add_child(_card_text(I18n.core("expedition.fleet_summary") % [I18n.core("status.READY") if ready else I18n.core("status.NOT_READY"), I18n.core("format.list_separator").join(roster) if not roster.is_empty() else I18n.core("expedition.fleet.empty"), command_used, command_capacity, cargo_used, cargo_capacity], COLOR_GOOD if ready else COLOR_WARN))
	var fleet_actions := HFlowContainer.new()
	fleet_actions.add_theme_constant_override("h_separation", 6)
	var expedition_resupply_button := _button(I18n.core("expedition.action.auto_resupply"), _command.bind(I18n.core("command.expedition.auto_resupply"), Game.auto_resupply_fleet.bind(_selected_formation_id)), roster.is_empty())
	expedition_resupply_button.name = "AutoResupplyExpeditionFleet"
	fleet_actions.add_child(expedition_resupply_button)
	fleet_actions.add_child(_button(I18n.core("expedition.action.open_readiness"), _open_fleet_section.bind("readiness"), false, COLOR_GOOD))
	box.add_child(fleet_actions)

	if not String(Game.state.active_expedition.get("route_id", "")).is_empty():
		var route_id := String(Game.state.active_expedition.get("route_id", ""))
		var route := Game.content.expedition_routes.get(route_id, {}) as Dictionary
		var active := _card()
		active.add_child(_label(I18n.core("expedition.active_route") % _content_name(route, route_id), 17, COLOR_ACCENT))
		active.add_child(_label(I18n.core("expedition.route_progress") % [_status_text(String(Game.state.active_expedition.get("phase", ""))), int(Game.state.active_expedition.get("node_index", 0)) + 1], 14, COLOR_MUTED))
		active.add_child(_operation_progress(Game.state.active_expedition, I18n.core("expedition.travel_progress")))
		var combat_state: Dictionary = Game.state.active_expedition.get("combat_state", {})
		if not combat_state.is_empty():
			_add_combat_state_panel(active, combat_state)
		var recall_route := _button(I18n.core("expedition.action.recall"), _command.bind(I18n.core("command.expedition.stop_action"), Game.stop_activity.bind("expedition")), false, COLOR_WARN)
		recall_route.name = "RecallExpeditionRoute_%s" % route_id
		active.add_child(recall_route)
		box.add_child(_wrap_card(active))
	var repeat_runtime: Dictionary = Game.runtime_for_domain("expedition")
	if not String(repeat_runtime.get("activity_id", "")).is_empty():
		var activity_id := String(repeat_runtime.get("activity_id", ""))
		var activity := Game.content.activities.get(activity_id, {}) as Dictionary
		var repeat_card := _card()
		repeat_card.add_child(_label(I18n.core("expedition.active_action") % _content_name(activity, activity_id), 17, COLOR_ACCENT))
		repeat_card.add_child(_operation_progress(repeat_runtime, _status_text(String(repeat_runtime.get("status", "RUNNING")))))
		var repeat_combat_state: Dictionary = repeat_runtime.get("combat_state", {})
		if not repeat_combat_state.is_empty():
			_add_combat_state_panel(repeat_card, repeat_combat_state)
		var recall_action := _button(I18n.core("expedition.action.recall"), _command.bind(I18n.core("command.expedition.stop_action"), Game.stop_activity.bind("expedition")), false, COLOR_WARN)
		recall_action.name = "RecallExpeditionAction_%s" % activity_id
		repeat_card.add_child(recall_action)
		box.add_child(_wrap_card(repeat_card))

	box.add_child(_section_title(I18n.core("expedition.visible_routes")))
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
		var start_route_button := _button(I18n.core("expedition.action.start_route"), _command.bind(I18n.core("command.expedition.start_route"), Game.start_expedition_route.bind(route_id, [], _selected_formation_id)), completed or not reason.is_empty() or roster.is_empty())
		start_route_button.name = "StartRoute_%s" % route_id
		card.add_child(start_route_button)
		if not reason.is_empty():
			card.add_child(_label(I18n.core("expedition.unavailable") % reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))

	box.add_child(_section_title(I18n.core("expedition.repeatable_combat")))
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
		var start_combat_button := _button(I18n.core("expedition.action.start_combat"), _command.bind(I18n.core("command.expedition.start_combat"), Game.start_activity.bind("expedition", activity_id, _selected_formation_id)), busy or not reason.is_empty() or roster.is_empty())
		start_combat_button.name = "StartCombat_%s" % activity_id
		card.add_child(start_combat_button)
		if not reason.is_empty():
			card.add_child(_label(I18n.core("expedition.unavailable") % reason, 13, COLOR_WARN))
		box.add_child(_wrap_card(card))
	if not repeat_found:
		box.add_child(_card_text(I18n.core("expedition.repeatable_locked"), COLOR_MUTED))

	if not Game.state.expedition_reports.is_empty():
		box.add_child(_section_title(I18n.core("expedition.reports")))
		var reports: Array = Game.state.expedition_reports.slice(maxi(0, Game.state.expedition_reports.size() - 5))
		reports.reverse()
		for report_value in reports:
			box.add_child(_wrap_card(_combat_report_card(report_value as Dictionary)))


func _open_fleet_section(section: String) -> void:
	_fleet_section = section
	_switch_page("fleet")


func _add_combat_state_panel(parent: VBoxContainer, combat_state: Dictionary) -> void:
	parent.add_child(_label(I18n.core("combat.state.summary") % [_status_text(String(combat_state.get("status", "RUNNING"))), int(combat_state.get("phase_index", 0)) + 1, int(combat_state.get("phase_count", 1)), int(combat_state.get("events", 0))], 15, COLOR_WARN))
	parent.add_child(_label(I18n.core("combat.state.totals") % [float(combat_state.get("fleet_hull", 0.0)), float(combat_state.get("fleet_max_hull", 0.0)), float(combat_state.get("fleet_shield", 0.0)), float(combat_state.get("fleet_max_shield", 0.0)), float(combat_state.get("enemy_hull", 0.0)), float(combat_state.get("enemy_max_hull", 0.0)), float(combat_state.get("enemy_shield", 0.0)), float(combat_state.get("enemy_max_shield", 0.0))], 13, COLOR_TEXT))
	for actor_value in combat_state.get("actors", []):
		var actor := actor_value as Dictionary
		var actor_ship := Game.state.ship_by_id(String(actor.get("ship_id", "")))
		parent.add_child(_label(I18n.core("combat.state.actor") % [String(actor_ship.get("name", I18n.core("ships.entity.fallback"))), _zone_text(String(actor.get("zone", "FRONT"))), float(actor.get("hull", 0.0)), float(actor.get("max_hull", 0.0)), float(actor.get("shield", 0.0)), float(actor.get("max_shield", 0.0))], 12, COLOR_GOOD if float(actor.get("hull", 0.0)) > 0.0 else COLOR_BAD))
	var recent_log: Array = combat_state.get("log", []).slice(maxi(0, combat_state.get("log", []).size() - 4))
	for event_value in recent_log:
		var event := event_value as Dictionary
		parent.add_child(_label(_combat_event_text(event), 11, COLOR_MUTED))


func _combat_report_card(report: Dictionary) -> VBoxContainer:
	var card := _card()
	var combat: Dictionary = report.get("combat", {})
	var result := String(report.get("result", "VICTORY" if bool(combat.get("victory", false)) else "DEFEAT"))
	var route_id := String(report.get("route_id", report.get("activity_id", "ACTION")))
	var route_definition := Game.content.expedition_routes.get(route_id, Game.content.activities.get(route_id, {})) as Dictionary
	card.add_child(_label(I18n.core("combat.report.header") % [_content_name(route_definition, route_id), _status_text(result)], 16, COLOR_GOOD if result in ["SUCCESS", "VICTORY"] or bool(combat.get("victory", false)) else COLOR_WARN))
	card.add_child(_label(I18n.core("combat.report.summary") % [_status_text(String(report.get("reason", combat.get("reason", "COMPLETE")))), int(combat.get("events", 0)), float(combat.get("fleet_hull_remaining", 0.0)), float(combat.get("enemy_hull_remaining", 0.0))], 13, COLOR_MUTED))
	for ship_result_value in combat.get("ship_results", []):
		var ship_result := ship_result_value as Dictionary
		var result_ship := Game.state.ship_by_id(String(ship_result.get("ship_id", "")))
		card.add_child(_label(I18n.core("combat.report.ship_result") % [String(result_ship.get("name", I18n.core("ships.entity.fallback"))), I18n.core("status.DISABLED") if bool(ship_result.get("disabled", false)) else I18n.core("status.RECOVERED"), float(ship_result.get("damage_dealt", 0.0)), float(ship_result.get("damage_taken", 0.0)), float(ship_result.get("hull_remaining", 0.0))], 12, COLOR_BAD if bool(ship_result.get("disabled", false)) else COLOR_TEXT))
	return card


func _combat_event_text(event: Dictionary) -> String:
	if String(event.get("type", "")) == "ATTACK":
		var source_ship := Game.state.ship_by_id(String(event.get("source", "")))
		var skill_id := String(event.get("skill_id", "attack"))
		return I18n.core("combat.event.attack") % [String(source_ship.get("name", event.get("source", ""))), skill_id.replace("_", " ").capitalize(), I18n.core("combat.event.hit") if bool(event.get("hit", false)) else I18n.core("combat.event.miss"), float(event.get("damage", 0.0))]
	return _status_text(String(event.get("type", "EVENT")))


func _direct_activity_block_reason(domain_id: String, activity: Dictionary) -> String:
	if Game.can_start_activity(domain_id, activity, _selected_formation_id):
		return ""
	var unmet := _unmet_requirements(activity.get("requirements", []))
	return unmet if not unmet.is_empty() else I18n.core("expedition.blocker.fleet_conflict")


func _open_next_flow_target() -> void:
	var guidance: Dictionary = Game.guidance_snapshot()
	var page := String(guidance.get("page", ""))
	if page.is_empty():
		return
	_record_telemetry("GuidanceClicked", {
		"guidance_id":String(guidance.get("step_id", "")),
		"reason":String(guidance.get("reason", "")),
		"navigation_target":page
	})
	var location_id := str(guidance.get("location_id", ""))
	if not location_id.is_empty() and Game.state.has_location(location_id):
		_selected_location_id = location_id
	if page == "industry":
		_industry_section = String(guidance.get("section", "production"))
	_switch_page(page)


func _next_flow_step() -> String:
	var guidance: Dictionary = Game.guidance_snapshot()
	return String(guidance.get("message", guidance.get("reason", "")))


func _next_flow_page() -> String:
	return String(Game.guidance_snapshot().get("page", "system_map"))


func _compatible_loadout_modules(ship: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var installed: Array = Game.state.ship_module_definition_ids(ship)
	var blueprint_id := String(ship.get("blueprint_id", ""))
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
				var desired := installed.duplicate()
				desired[desired.find(old_id)] = new_id
				# Keep valid choices visible while unavailable. The card renderer asks
				# the authoritative Domain query for disabled state and explanation.
				if Game.content.ship_loadout_valid(blueprint_id, desired):
					result.append({"old_id": old_id, "new_id": new_id})
				break
	return result


func _installable_loadout_modules(ship: Dictionary) -> Array[String]:
	# Keep structurally valid, revealed module choices visible even when the
	# authoritative transaction is currently blocked by resources or ship state.
	# The renderer asks ship_loadout_availability for disabled state and reason;
	# fitting rules still remain in the Content Database / Domain query.
	var result: Array[String] = []
	var installed: Array = Game.state.ship_module_definition_ids(ship)
	var blueprint_id := String(ship.get("blueprint_id", ""))
	for module_id_value in Game.content.modules.keys():
		var module_id := String(module_id_value)
		var module_definition := Game.content.modules.get(module_id, {}) as Dictionary
		if bool(module_definition.get("retired", false)):
			continue
		if bool(module_definition.get("special_equipment", false)):
			if Game.state.stored_equipment_ids(module_id).is_empty():
				continue
		elif not Game.simulation.module_design_available(Game.state, module_id):
			continue
		var desired := installed.duplicate()
		desired.append(module_id)
		if Game.content.ship_loadout_valid(blueprint_id, desired):
			result.append(module_id)
	result.sort()
	return result


func _ship_modules_text(ship: Dictionary) -> String:
	var names: Array[String] = []
	var installed: Array = Game.state.ship_module_definition_ids(ship)
	for module_id_value in installed:
		var module_id := String(module_id_value)
		var module := Game.content.modules.get(module_id, {}) as Dictionary
		names.append(_content_name(module, module_id))
	return " / ".join(names)


func _industrial_runtime_for_facility(facility_id: String) -> Dictionary:
	for operation_value in Game.state.industrial_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("facility_id", "")) == facility_id \
			and String(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == _selected_location_id:
			return operation
	return {}


func _activity_block_reason(domain_id: String, activity_id: String) -> String:
	if activity_id.is_empty():
		return I18n.core("block_reason.missing_activity")
	var activity := Game.content.activities.get(activity_id, {}) as Dictionary
	if domain_id == "expedition":
		activity = Game.content.expedition_routes.get(activity_id, {}) as Dictionary
	if not activity.is_empty() and Game.can_start_activity(domain_id, activity, _selected_formation_id):
		return ""
	var unmet := _unmet_requirements(activity.get("requirements", []))
	if not unmet.is_empty():
		return unmet
	if domain_id == "industry":
		return I18n.core("block_reason.industry")
	if domain_id == "expedition":
		return I18n.core("block_reason.expedition")
	return I18n.core("block_reason.default")


func _construction_block_reason(activity_id: String) -> String:
	var activity := Game.content.activities.get(activity_id, {}) as Dictionary
	if not activity.is_empty() and Game.can_start_construction_project(activity):
		return ""
	var sponsor_facility_id := String(activity.get("facility", ""))
	if not sponsor_facility_id.is_empty() and not Game.simulation.facility_available(Game.state, sponsor_facility_id):
		return I18n.core("block_reason.sponsor_facility") % _content_name(Game.content.facilities.get(sponsor_facility_id, {}), sponsor_facility_id)
	var unmet := _unmet_requirements(activity.get("requirements", []))
	return unmet if not unmet.is_empty() else I18n.core("block_reason.construction")


func _unmet_requirements(requirements: Array) -> String:
	var lines: Array[String] = []
	for requirement_value in requirements:
		var requirement := requirement_value as Dictionary
		if not Game.simulation.requirement_met(Game.state, requirement):
			lines.append(Game.requirement_text(requirement))
	return I18n.core("format.requirement_separator").join(lines)


func _requirements_label(requirements: Array) -> Label:
	var reason := _unmet_requirements(requirements)
	return _label(I18n.core("requirements.summary") % (reason if not reason.is_empty() else I18n.core("requirements.met")), 13, COLOR_WARN if not reason.is_empty() else COLOR_GOOD)


func _activity_summary(activity: Dictionary) -> String:
	var parts: Array[String] = []
	var cost_text := _resource_list(activity.get("costs", []))
	var reward_text := _resource_list(activity.get("rewards", []))
	var waste_text := _resource_list(activity.get("waste", []))
	if not cost_text.is_empty():
		parts.append(I18n.core("activity.consumes") % cost_text)
	if not reward_text.is_empty():
		parts.append(I18n.core("activity.produces") % reward_text)
	if not waste_text.is_empty():
		parts.append(I18n.core("activity.waste") % waste_text)
	if activity.has("production_energy_multiplier"):
		parts.append(I18n.core("activity.energy_multiplier") % float(activity.get("production_energy_multiplier", 1.0)))
	if activity.has("work_required"):
		parts.append(I18n.core("activity.work_required") % float(activity.get("work_required", 1.0)))
	var facility_id := String(activity.get("facility", ""))
	if not facility_id.is_empty():
		var facility := Game.content.facilities.get(facility_id, {}) as Dictionary
		parts.append(I18n.core("activity.facility") % _content_name(facility, facility_id))
	return I18n.core("format.detail_separator").join(parts) if not parts.is_empty() else I18n.core("activity.no_direct_resources")


func _project_summary(definition: Dictionary) -> String:
	var description := I18n.content(definition, "description")
	# Major programs pay their exact materials stage by stage; their legacy
	# top-level cost summary is not an additional up-front charge.
	var costs := "" if bool(definition.get("major_program", false)) else _resource_list(definition.get("costs", []))
	if costs.is_empty():
		costs = _resource_list(definition.get("cost", []))
	if not costs.is_empty():
		description += (I18n.core("format.detail_separator") if not description.is_empty() else "") + I18n.core("activity.consumes") % costs
	var work_reduction := 1.0 - Game.simulation.research_knowledge_work_multiplier(Game.state, definition)
	if work_reduction > 0.001:
		description += (I18n.core("format.detail_separator") if not description.is_empty() else "") + I18n.core("research.knowledge_reduction") % (work_reduction * 100.0)
	return description if not description.is_empty() else I18n.core("research.awaiting_data")


func _resource_list(entries: Array) -> String:
	var parts: Array[String] = []
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := String(entry.get("item", entry.get("item_id", "")))
		var amount := int(entry.get("quantity", entry.get("amount", 0)))
		var item := Game.content.items.get(item_id, {}) as Dictionary
		parts.append(I18n.core("format.item_quantity") % [_content_name(item, item_id), amount])
	return I18n.core("format.list_separator").join(parts)


func _resource_dictionary(values: Dictionary) -> String:
	if values.is_empty():
		return I18n.core("status.NONE")
	var entries: Array = []
	var item_ids: Array = values.keys()
	item_ids.sort()
	for item_id_value in item_ids:
		entries.append({"item":str(item_id_value), "quantity":int(values[item_id_value])})
	return _resource_list(entries)


func _construction_project_type_name(project_type: String) -> String:
	var key := "construction.type.%s" % project_type
	var translated := I18n.core(key)
	return project_type.replace("_", " ").capitalize() if translated == key else translated


func _construction_project_name(operation: Dictionary, definition: Dictionary) -> String:
	if operation.get("project_definition", {}).is_empty():
		return _content_name(definition, String(operation.get("activity_id", I18n.core("construction.project_fallback"))))
	var project_type := String(operation.get("project_type", ""))
	var target_id := String(operation.get("target_id", ""))
	if project_type == "FACILITY_EXPANSION":
		return I18n.core("construction.facility_expansion_name") % [_content_name(Game.content.facilities.get(target_id, {}), target_id), int(operation.get("target_level", 0))]
	return I18n.core("construction.target_level_name") % [_construction_project_type_name(project_type), int(operation.get("target_level", 0))]


func _operation_progress(operation: Dictionary, caption: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var progress := 0.0
	if String(operation.get("domain", "")) == "construction":
		var total_work := maxf(1.0, float(operation.get("total_work", 100.0)))
		var partial_work := float(operation.get("cycle_progress", 0.0)) * total_work / 100.0
		progress = clampf((float(operation.get("completed_work", 0.0)) + partial_work) / total_work, 0.0, 1.0)
	else:
		var duration := maxf(float(operation.get("duration_ms", operation.get("cycle_duration_ms", 1.0))), 1.0)
		# Multi-stage R&D keeps cumulative program progress for history, while the
		# active progress bar must display only the current stage's work.
		var elapsed := float(operation.get("stage_progress_ms", operation.get("progress_ms", operation.get("cycle_progress_ms", operation.get("elapsed_ms", 0.0)))))
		progress = clampf(elapsed / duration, 0.0, 1.0)
	box.add_child(_label(I18n.core("common.progress_label") % [caption, progress * 100.0], 13, COLOR_ACCENT))
	var bar := ProgressBar.new()
	bar.max_value = 1.0
	bar.value = progress
	bar.show_percentage = false
	bar.custom_minimum_size.y = UiTokens.layout_px(8)
	box.add_child(bar)
	return box


func _content_name(definition: Dictionary, fallback: String) -> String:
	if definition.is_empty():
		return fallback
	var localized := I18n.content(definition)
	return localized if not localized.is_empty() else String(definition.get("name", fallback))


func _system_name(system_id: String) -> String:
	var key := "system.%s" % system_id.to_lower()
	var translated := I18n.core(key)
	return system_id.capitalize() if translated == key else translated


func _assignment_name(assignment: String) -> String:
	if assignment.is_empty():
		return I18n.core("ships.assignment.standby")
	return _formation_name(assignment)


func _formation_name(formation_id: String) -> String:
	if formation_id == SpaceGameState.DEFAULT_FORMATION_ID:
		return I18n.core("ships.formation.primary", "First Task Force")
	return String(Game.state.formation_runtime(formation_id).get("name", formation_id))


func _zone_text(zone: String) -> String:
	match zone.to_upper():
		"FRONT": return I18n.core("ships.zone.FRONT")
		"MID": return I18n.core("ships.zone.MID")
		"REAR": return I18n.core("ships.zone.REAR")
		_: return I18n.core("status.NOT_CONFIGURED")


func _logistics_mode_text(mode: String) -> String:
	match mode.to_upper():
		"SUPPLY": return I18n.core("logistics.mode.SUPPLY")
		"DEMAND": return I18n.core("logistics.mode.DEMAND")
		"STORAGE": return I18n.core("logistics.mode.STORAGE")
		_: return I18n.core("status.NOT_CONFIGURED")


func _logistics_priority_text(priority_id: String) -> String:
	match priority_id:
		"DEMAND_PRIORITY": return I18n.core("logistics.priority.DEMAND_PRIORITY")
		"PRECISION_FIRST": return I18n.core("logistics.priority.PRECISION_FIRST")
		"MAINTENANCE_FIRST": return I18n.core("logistics.priority.MAINTENANCE_FIRST")
		"BULK_FIRST": return I18n.core("logistics.priority.BULK_FIRST")
		_: return priority_id


func _freight_class_text(freight_class: String) -> String:
	var normalized := freight_class.strip_edges().to_upper()
	return I18n.t("freight_class.%s" % normalized, normalized.replace("_", " ").capitalize())


func _logistics_technology_name(technology_id: String) -> String:
	if technology_id == "chemical_cargo":
		return I18n.t("logistics_technology.chemical_cargo", "Chemical Cargo")
	return _content_name(Game.content.technologies.get(technology_id, {"id":technology_id, "name":technology_id.replace("_", " ").capitalize()}), technology_id)


func _automation_term(kind: String, term_id: String) -> String:
	var normalized := term_id.strip_edges().to_upper()
	return I18n.t("automation.%s.%s" % [kind, normalized], normalized.replace("_", " ").capitalize())


func _status_text(status: String) -> String:
	var normalized := status.strip_edges().to_upper().replace(" ", "_")
	if normalized.is_empty():
		return I18n.core("status.NONE")
	var translated := I18n.status(normalized)
	return normalized.replace("_", " ").capitalize() if translated == normalized else translated


func _add_blocker_label(parent: Control, runtime: Dictionary) -> void:
	var blocker: Dictionary = runtime.get("blocker", {})
	if blocker.is_empty() and (String(runtime.get("status", "")) in ["BLOCKED", "PAUSED"] or String(runtime.get("operating_state", "")) in ["POWER_LIMITED", "COOLING_LIMITED", "LOGISTICS_LIMITED"]):
		var domain_id := String(runtime.get("domain", ""))
		if domain_id.is_empty():
			domain_id = "shipyard" if runtime.has("plan_id") else ("research" if runtime.has("project_id") else "industry")
		blocker = Game.simulation.blocker_diagnostic(Game.state, domain_id, runtime)
	if not blocker.is_empty():
		parent.add_child(_label(I18n.core("blocker.primary") % _blocker_text(blocker), 13, COLOR_WARN))


func _blocker_text(blocker: Dictionary) -> String:
	if blocker.has("raw"):
		blocker = blocker.get("raw", {}) as Dictionary
	var reason := String(blocker.get("primary_reason", "BLOCKED"))
	var requirement: Dictionary = blocker.get("requirement", {})
	var item_id := String(blocker.get("item_id", ""))
	var item_name := _content_name(Game.content.items.get(item_id, {}), item_id) if not item_id.is_empty() else ""
	var shortage_name := item_name if not item_name.is_empty() else I18n.core("blocker.required_input")
	var requirement_text := Game.requirement_text(requirement)
	if String(requirement.get("type", "")) == "activity_complete":
		return I18n.core("blocker.activity_complete") % requirement_text
	match reason:
		"KNOWLEDGE_GATE", "OPERATING_CONDITION", "FIELD_TEST_REQUIRED":
			return I18n.core("blocker.%s" % reason) % requirement_text
		"RESEARCH_CAPACITY_SHORTAGE":
			return I18n.core("blocker.RESEARCH_CAPACITY_SHORTAGE") % [float(blocker.get("available", 0.0)), float(blocker.get("required", 1.0))]
		"MISSING_SCALE_STAGE":
			return I18n.core("blocker.MISSING_SCALE_STAGE") % [blocker.get("available", 0), blocker.get("required", 0)]
		"MISSING_CAPITAL_GOOD", "INPUT_SHORTAGE":
			return I18n.core("blocker.%s" % reason) % [shortage_name, blocker.get("available", 0), blocker.get("required", 0)]
		"INPUT_IN_TRANSIT":
			return I18n.core("blocker.INPUT_IN_TRANSIT") % [shortage_name, blocker.get("available", 0), blocker.get("required", 0), blocker.get("incoming", 0)]
		"MISSING_TECH", "MISSING_FACILITY", "PRODUCTION_DEVICE_UNAVAILABLE", "ROUTE_UNAVAILABLE", "TRANSPORT_MODE_UNAVAILABLE", "ROUTE_CONGESTED", "HANDLING_CONGESTED", "POWER_SHORTAGE", "COOLING_SHORTAGE", "STORAGE_FULL", "MAINTENANCE_SHORTAGE", "CONSTRUCTION_CAPACITY_FULL", "PROJECT_SLOT_FULL", "MANUALLY_PAUSED":
			return I18n.core("blocker.%s" % reason)
		_: return reason.replace("_", " ").capitalize()


func _availability_reason(availability: Dictionary) -> String:
	if bool(availability.get("allowed", false)):
		return I18n.core("availability.ready", "Requirements met")
	var reasons: Array[String] = []
	for blocker_value in availability.get("blockers", []):
		var blocker := blocker_value as Dictionary
		var code := String(blocker.get("code", "UNKNOWN"))
		if code == "INPUT_SHORTAGE":
			var item_id := String(blocker.get("item_id", ""))
			reasons.append(I18n.core("blocker.INPUT_SHORTAGE") % [_content_name(Game.content.items.get(item_id, {}), item_id), blocker.get("available", 0), blocker.get("required", 0)])
		else:
			reasons.append(I18n.core("availability.%s" % code, code.replace("_", " ").capitalize()))
	return "\n".join(reasons)


func _command(label_text: String, callable: Callable) -> void:
	var previous_notice := Game.last_notice
	var success: Variant = callable.call()
	if success is bool and not success:
		var reason := Game.last_notice
		if reason.is_empty() or reason == previous_notice:
			reason = I18n.core("command.failed_unknown", "The command could not be completed. Inspect the requirements and try again.")
		_append_log(I18n.core("command.failed") % [label_text, reason])
		_record_telemetry("PlayerAction", {"label":label_text, "screen":_active_page_key, "success":false, "reason":reason})
	else:
		_append_log(I18n.core("command.executed") % label_text)
		_record_telemetry("PlayerAction", {"label":label_text, "screen":_active_page_key, "success":true})
	_request_active_page_refresh(true)


func _set_speed(speed: float) -> void:
	Engine.time_scale = speed
	_append_log(I18n.core("command.speed") % (I18n.core("command.speed_paused") if speed == 0.0 else I18n.core("command.speed_multiplier") % int(speed)))
	_record_telemetry("PlayerAction", {"label":"SET_GAME_SPEED", "screen":_active_page_key, "success":true, "speed":speed})
	_update_header()


func _save_game() -> void:
	_command(I18n.core("command.save_progress"), Game.save_game)


func _request_reset_game() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.name = "ResetConfirmation"
	dialog.title = I18n.core("reset.title", "Start a new game?")
	dialog.dialog_text = I18n.core("reset.description", "This deletes the current local save and starts from a fresh organization. This cannot be undone.")
	dialog.ok_button_text = I18n.core("reset.confirm", "Delete save and restart")
	dialog.cancel_button_text = I18n.core("reset.cancel", "Keep current game")
	dialog.exclusive = true
	dialog.confirmed.connect(_confirm_reset_game.bind(dialog))
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered(Vector2i(520, 220))
	dialog.get_cancel_button().call_deferred("grab_focus")


func _confirm_reset_game(dialog: ConfirmationDialog) -> void:
	if is_instance_valid(dialog):
		dialog.queue_free()
	_reset_game()


func _reset_game() -> void:
	Engine.time_scale = 1.0
	Game.reset_game()
	_event_log.clear()
	_append_log(I18n.core("timeline.game_reset"))
	_request_active_page_refresh(true)


func _toggle_locale() -> void:
	I18n.toggle_locale()


func _update_header() -> void:
	if not is_instance_valid(_header_status) or not is_instance_valid(Game.state):
		return
	var total_minutes := int(Game.state.total_elapsed_ms / 60000.0)
	var day := total_minutes / (24 * 60) + 1
	var hour := (total_minutes / 60) % 24
	var minute := total_minutes % 60
	var power := Game.simulation.civilization_power_state(Game.state)
	# The header and bottom timeline describe the same active Alert collection.
	# A second severity filter here would give the two surfaces different counts.
	var blocked_count := _active_blocker_cache.size()
	var project_count := Game.simulation.construction_queue_size(Game.state)
	var research_status := _status_text(str(Game.state.research.get("status", "IDLE")))
	var mega_status := "LOCKED"
	if not Game.state.megastructure_projects.is_empty():
		mega_status = str(Game.state.megastructure_projects.values()[0].get("status", "PLANNED"))
	elif bool(Game.state.completed_projects.get("research_megastructures", false)):
		mega_status = "AVAILABLE"
	_header_status.text = "%s\n%s · %s %.0f/%.0f · %s %d · %s %d · %s %s · %s %s" % [I18n.core("header.clock") % [day, hour, minute, int(Game.state.progression_tier)], _location_name(_selected_location_id), I18n.core("header.power", "Power"), float(power.get("available_capacity", 0.0)), float(power.get("current_demand", 0.0)), I18n.core("header.alerts", "Alerts"), blocked_count, I18n.core("header.projects", "Projects"), project_count, I18n.core("header.research", "R&D"), research_status, I18n.core("header.megastructure", "Megastructure"), _status_text(mega_status)]
	for speed_value in _speed_buttons.keys():
		var button := _speed_buttons[speed_value] as Button
		button.modulate = COLOR_ACCENT if is_equal_approx(float(speed_value), Engine.time_scale) else Color.WHITE


func _append_log(text_value: String) -> void:
	var total_minutes := int(Game.state.total_elapsed_ms / 60000.0) if is_instance_valid(Game.state) else 0
	var stamp := "%02d:%02d" % [(total_minutes / 60) % 24, total_minutes % 60] if is_instance_valid(Game.state) else "--:--"
	_event_log.append(I18n.core("timeline.entry") % [stamp, text_value])
	if _event_log.size() > 40:
		_event_log.pop_front()
	if is_instance_valid(_notice_label):
		_notice_label.text = I18n.core("bottom.timeline", "Timeline") + " · " + text_value
	_request_active_page_refresh(false)


func telemetry_snapshot() -> Dictionary:
	var screens := {}
	var action_labels := {}
	var blockers: Array[String] = []
	var guidance: Array[String] = []
	for event_value in _telemetry_events:
		var event := event_value as Dictionary
		match String(event.get("type", "")):
			"ScreenOpen": screens[String(event.get("screen", ""))] = true
			"PlayerAction": action_labels[String(event.get("label", ""))] = true
			"BlockerSeen": blockers.append(String(event.get("code", "UNKNOWN")))
			"GuidanceClicked": guidance.append(String(event.get("guidance_id", "")))
	return {
		"events":_telemetry_events.duplicate(true),
		"screens_visited":screens.keys(),
		"actions_exercised":action_labels.keys(),
		"blockers_encountered":blockers,
		"guidance_paths_used":guidance
	}


func _record_telemetry(event_type: String, payload: Dictionary = {}) -> void:
	var event := payload.duplicate(true)
	event["type"] = event_type
	event["simulation_time_ms"] = int(Game.state.total_elapsed_ms) if is_instance_valid(Game.state) else 0
	event["sequence"] = _telemetry_events.size()
	_telemetry_events.append(event)


func _update_bottom_bar() -> void:
	if not is_instance_valid(_notice_label):
		return
	var alert_count := _active_blocker_cache.size()
	var latest := String(_event_log.back()) if not _event_log.is_empty() else I18n.core("sidebar.none", "None")
	var guidance := Game.guidance_snapshot()
	var task_caption := String(guidance.get("message", guidance.get("reason", ""))).get_slice("\n", 0)
	if is_instance_valid(_dock_workspace_label):
		_dock_workspace_label.text = I18n.core(String(NAV_TRANSLATION_KEYS.get(_active_page_key, "nav.%s" % _active_page_key)), _active_page_key.capitalize())
	if is_instance_valid(_dock_next_button):
		_dock_next_button.disabled = String(guidance.get("page", "")).is_empty()
		_dock_next_button.tooltip_text = String(guidance.get("reason", ""))
	_notice_label.text = I18n.core("bottom.summary") % [
		I18n.core("bottom.alerts", "Alerts"), alert_count,
		I18n.core("bottom.task", "Task"), task_caption,
		I18n.core("bottom.timeline", "Timeline"), latest
	]


func _on_state_changed() -> void:
	_request_active_page_refresh(false)


func _on_domain_event(event: Dictionary) -> void:
	var event_type := String(event.get("type", "event"))
	var event_id := String(event.get("activity_id", event.get("project_id", event.get("route_id", ""))))
	_append_log(I18n.core("timeline.domain_event") % [event_type, (I18n.core("format.inline_detail") % event_id) if not event_id.is_empty() else ""])
	_record_telemetry("DomainEvent", {"event_type":event_type, "entity_id":event_id})


func _on_command_rejected(reason: String) -> void:
	_append_log(I18n.core("timeline.command_rejected") % reason)


func _load_ui_preferences() -> void:
	var has_session_scale := get_tree().root.has_meta(UiTokens.UI_SCALE_SESSION_META)
	_ui_scale = UiTokens.sanitize_ui_scale(float(get_tree().root.get_meta(UiTokens.UI_SCALE_SESSION_META, UiTokens.DEFAULT_UI_SCALE)))
	if Game.persistence_enabled and _ui_config.load(_ui_config_path()) == OK:
		_active_page_key = String(_ui_config.get_value("navigation", "active_page", "system_map"))
		_selected_location_id = String(_ui_config.get_value("navigation", "selected_location", SpaceGameState.MAIN_BASE_LOCATION_ID))
		_location_section = String(_ui_config.get_value("navigation", "location_section", "overview"))
		_industry_section = String(_ui_config.get_value("navigation", "industry_section", "production"))
		_industry_view_mode = String(_ui_config.get_value("navigation", "industry_view_mode", "network"))
		_fleet_section = String(_ui_config.get_value("navigation", "fleet_section", "roster"))
		_selected_formation_id = String(_ui_config.get_value("navigation", "formation_id", SpaceGameState.DEFAULT_FORMATION_ID))
		_developer_details = bool(_ui_config.get_value("display", "developer_details", false))
		_reduced_motion = bool(_ui_config.get_value("display", "reduced_motion", false))
		if not has_session_scale:
			_ui_scale = UiTokens.sanitize_ui_scale(float(_ui_config.get_value("display", "ui_scale", _ui_scale)))
		_ui_state.left_rail_collapsed = bool(_ui_config.get_value("display", "resource_rail_collapsed", false))
		_ui_state.right_inspector_collapsed = bool(_ui_config.get_value("display", "context_inspector_collapsed", false))
		var network_preferences = _ui_config.get_value("industrial_network", "workspace", {})
		_industrial_network_preferences = network_preferences.duplicate(true) if network_preferences is Dictionary else {}
	if _active_page_key == "overview":
		_active_page_key = "system_map"
	elif _active_page_key == "ships":
		_active_page_key = "fleet"
	elif _active_page_key == "survey":
		_active_page_key = "frontier"
	if _industry_view_mode not in ["network", "list"]:
		_industry_view_mode = "network"
	if not Game.state.has_location(_selected_location_id):
		_selected_location_id = SpaceGameState.MAIN_BASE_LOCATION_ID
	_ui_state.restore_workspace(_active_page_key)
	_ui_state.select_context("location", _selected_location_id)


func _save_ui_preferences() -> void:
	if not Game.persistence_enabled:
		return
	if is_instance_valid(_industrial_network_view):
		_industrial_network_preferences = _industrial_network_view.export_preferences()
	_ui_config.set_value("navigation", "active_page", _active_page_key)
	_ui_config.set_value("navigation", "selected_location", _selected_location_id)
	_ui_config.set_value("navigation", "location_section", _location_section)
	_ui_config.set_value("navigation", "industry_section", _industry_section)
	_ui_config.set_value("navigation", "industry_view_mode", _industry_view_mode)
	_ui_config.set_value("navigation", "fleet_section", _fleet_section)
	_ui_config.set_value("navigation", "formation_id", _selected_formation_id)
	_ui_config.set_value("display", "developer_details", _developer_details)
	_ui_config.set_value("display", "reduced_motion", _reduced_motion)
	_ui_config.set_value("display", "ui_scale", _ui_scale)
	_ui_config.set_value("display", "resource_rail_collapsed", _ui_state.left_rail_collapsed)
	_ui_config.set_value("display", "context_inspector_collapsed", _ui_state.right_inspector_collapsed)
	_ui_config.set_value("industrial_network", "workspace", _industrial_network_preferences)
	_ui_config.save(_ui_config_path())


func _ui_config_path() -> String:
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--ui-persistence-root="):
			var candidate := argument.trim_prefix("--ui-persistence-root=").simplify_path()
			if candidate.is_absolute_path() and candidate.get_file().begins_with("helios-ui-persistence-audit-"):
				return candidate.path_join("core_gameplay_ui.cfg")
	return UI_CONFIG_PATH


func _on_context_location_selected(index: int, location_ids: Array[String]) -> void:
	if index < 0 or index >= location_ids.size():
		return
	_selected_location_id = location_ids[index]
	_selected_industrial_network_node.clear()
	_ui_state.select_context("location", _selected_location_id)
	_save_ui_preferences()
	_request_active_page_refresh(true)


func _on_left_rail_toggled(collapsed: bool) -> void:
	_ui_state.left_rail_collapsed = collapsed
	if not collapsed and _requires_single_sidebar() and not _ui_state.right_inspector_collapsed:
		_ui_state.right_inspector_collapsed = true
		_shell.set_right_collapsed(true)
	_save_ui_preferences()


func _on_right_inspector_toggled(collapsed: bool) -> void:
	_ui_state.right_inspector_collapsed = collapsed
	if not collapsed and _requires_single_sidebar() and not _ui_state.left_rail_collapsed:
		_ui_state.left_rail_collapsed = true
		_shell.set_left_collapsed(true)
	_save_ui_preferences()


func _requires_single_sidebar() -> bool:
	# System Map is the widest non-scaled gameplay canvas. Preserve its usable
	# width and switch the two sidebars to mutually exclusive drawers only when
	# the physical window cannot contain all three regions.
	var required_width := (
		UiTokens.layout_px(UiTokens.RESOURCE_RAIL_WIDTH)
		+ UiTokens.layout_px(UiTokens.INSPECTOR_WIDTH)
		+ 760
		+ UiTokens.layout_px(24)
	)
	return size.x < required_width


func _on_root_resized() -> void:
	if not is_instance_valid(_shell) or not _requires_single_sidebar():
		return
	if not _ui_state.left_rail_collapsed and not _ui_state.right_inspector_collapsed:
		_ui_state.right_inspector_collapsed = true
		_shell.set_right_collapsed(true)


func _on_ui_scale_selected(index: int) -> void:
	if not is_instance_valid(_ui_scale_selector) or index < 0:
		return
	var next_scale := UiTokens.sanitize_ui_scale(float(_ui_scale_selector.get_item_id(index)))
	if is_equal_approx(next_scale, _ui_scale):
		return
	_ui_scale = next_scale
	get_tree().root.set_meta(UiTokens.UI_SCALE_SESSION_META, _ui_scale)
	_save_ui_preferences()
	call_deferred("_reload_ui_for_scale")


func _reload_ui_for_scale() -> void:
	# Rebuilding the scene applies every token consistently while the Game
	# autoload keeps simulation/domain state alive. This is a UI-only reload.
	get_tree().reload_current_scene()


func _toggle_developer_details() -> void:
	_developer_details = not _developer_details
	_save_ui_preferences()
	_request_active_page_refresh(true)


func _on_locale_changed(_locale: String) -> void:
	_refresh_shell_locale()
	_industrial_network_view = null
	_industrial_network_projection = null
	_request_active_page_refresh(true)


func _refresh_shell_locale() -> void:
	if is_instance_valid(_shell):
		_shell.refresh_locale()
	var operations_title := find_child("OperationsTitle", true, false) as Label
	if is_instance_valid(operations_title):
		operations_title.text = I18n.core("shell.workspaces", "WORKSPACES")
	var scope := find_child("ScopeLabel", true, false) as Label
	if is_instance_valid(scope):
		scope.text = I18n.core("shell.scope")
	var title := find_child("ShellTitle", true, false) as Label
	if is_instance_valid(title):
		title.text = I18n.core("shell.brand_short", "HELIOS")
	var subtitle := find_child("ShellSubtitle", true, false) as Label
	if is_instance_valid(subtitle):
		subtitle.text = I18n.core("shell.brand_subtitle", "INDUSTRIAL NETWORK")
	var pause_button := find_child("SpeedPause", true, false) as Button
	if is_instance_valid(pause_button):
		pause_button.text = I18n.core("shell.pause")
	var fast_forward_button := find_child("Speed100", true, false) as Button
	if is_instance_valid(fast_forward_button):
		fast_forward_button.tooltip_text = I18n.core("shell.speed_100_tooltip", "Fast-forward 100× through the normal deterministic simulation; all costs and blockers still apply.")
	var save_button := find_child("SaveButton", true, false) as Button
	if is_instance_valid(save_button):
		save_button.text = I18n.core("shell.save")
	var restart_button := find_child("RestartButton", true, false) as Button
	if is_instance_valid(restart_button):
		restart_button.text = I18n.core("shell.restart")
	var locale_button := find_child("ToggleLocale", true, false) as Button
	if is_instance_valid(locale_button):
		locale_button.text = I18n.core("shell.locale_toggle")
	if is_instance_valid(_ui_scale_selector):
		_ui_scale_selector.tooltip_text = I18n.core("shell.ui_scale_tooltip", "Scale interface text and controls without changing map or canvas zoom.")
		_ui_scale_selector.accessibility_name = I18n.core("shell.ui_scale", "UI scale")
	var dock_title := find_child("CommandDockTitle", true, false) as Label
	if is_instance_valid(dock_title):
		dock_title.text = I18n.core("shell.command_dock", "COMMAND DOCK")
	var back_button := find_child("ShellBack", true, false) as Button
	if is_instance_valid(back_button):
		back_button.text = I18n.core("shell.back", "Back")
	if is_instance_valid(_dock_next_button):
		_dock_next_button.text = I18n.core("shell.next_action", "Next action")
	for key_value in _nav_buttons.keys():
		var key := String(key_value)
		var button := _nav_buttons[key] as Button
		var full_caption := I18n.core(String(NAV_TRANSLATION_KEYS.get(key, "nav.%s" % key)), key.capitalize())
		button.text = I18n.core("nav.short.%s" % key, full_caption)
		button.tooltip_text = full_caption
	_update_navigation_state()
	var page_order := ["system_map", "location", "frontier", "industry", "research", "fleet", "expedition", "megastructure"]
	for key_value in page_order:
		var key := String(key_value)
		var page := _page_controls.get(key) as Control
		if is_instance_valid(page):
			_tabs.set_tab_title(page.get_index(), I18n.core("page.%s" % key))
	_update_header()


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
	style.set_corner_radius_all(UiTokens.layout_px(6))
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _card() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UiTokens.layout_px(7))
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


func _add_unlock_banner(parent: VBoxContainer, page_id: String) -> void:
	var availability: Dictionary = Game.ui_navigation_availability(page_id)
	if bool(availability.get("unlocked", true)):
		return
	var banner := _card()
	banner.add_child(_label(I18n.core("nav.locked", "Locked"), 15, COLOR_WARN))
	banner.add_child(_label(I18n.core(String(availability.get("condition_key", "")), "Progression requirement not met"), 12, COLOR_MUTED))
	parent.add_child(_wrap_card(banner))


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
	value.add_theme_font_size_override("font_size", UiTokens.font_size(size))
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
	value.custom_minimum_size.y = UiTokens.layout_px(34)
	value.add_theme_color_override("font_color", color)
	value.add_theme_color_override("font_disabled_color", COLOR_MUTED.darkened(0.3))
	if disabled:
		value.tooltip_text = I18n.core("common.disabled_gameplay_action")
	if callback.is_valid():
		value.pressed.connect(callback)
	return value


func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(UiTokens.layout_px(3))
	style.content_margin_left = UiTokens.layout_px(10.0)
	style.content_margin_right = UiTokens.layout_px(10.0)
	style.content_margin_top = UiTokens.layout_px(7.0)
	style.content_margin_bottom = UiTokens.layout_px(7.0)
	return style


func _number_input(value: int, minimum: int, maximum: int, step: int) -> SpinBox:
	var input := SpinBox.new()
	input.min_value = minimum
	input.max_value = maximum
	input.step = step
	input.value = value
	input.allow_greater = false
	input.allow_lesser = false
	input.custom_minimum_size.x = UiTokens.layout_px(180)
	return input


func _labeled_control(caption: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTokens.layout_px(8))
	var caption_label := _label(caption, 13, COLOR_MUTED)
	caption_label.custom_minimum_size.x = UiTokens.layout_px(150)
	row.add_child(caption_label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _separator() -> HSeparator:
	return HSeparator.new()


func _margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var value := MarginContainer.new()
	value.add_theme_constant_override("margin_left", UiTokens.layout_px(left))
	value.add_theme_constant_override("margin_top", UiTokens.layout_px(top))
	value.add_theme_constant_override("margin_right", UiTokens.layout_px(right))
	value.add_theme_constant_override("margin_bottom", UiTokens.layout_px(bottom))
	return value
