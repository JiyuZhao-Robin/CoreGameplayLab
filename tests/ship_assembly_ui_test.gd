extends Node

const MainScene = preload("res://src/ui/main.tscn")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	Game.state.unlocked_ship_plans["construct_lunar_pathfinder"] = true
	Game.state.technologies["advanced_propulsion"] = true
	Game.state.completed_activities["assemble_frame"] = 1
	var refit_modules := ["light_autocannon", "civilian_shield", "advanced_drive", "cargo_expansion", "civilian_reactor_core"]
	var refit_ship := Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "Blueprint Refit Target")
	var refit_ship_id := String(refit_ship.get("instance_id", ""))
	var reserve_ship := Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "Reserve Filter Fixture")
	reserve_ship["maintenance_state"] = "READY_RESERVE"
	var mothballed_ship := Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "Mothballed Filter Fixture")
	mothballed_ship["maintenance_state"] = "MOTHBALLED"
	var cruiser_modules := ["light_autocannon", "civilian_shield", "advanced_drive", "targeting_computer", "civilian_reactor_core"]
	var horizon_ship := Game.state._create_ship_instance("belt_cruiser", cruiser_modules, "ISS Horizon")
	var venture_ship := Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "ISS Venture")
	venture_ship["maintenance_state"] = "READY_RESERVE"
	var ranger_ship := Game.state._create_ship_instance("belt_cruiser", cruiser_modules, "ISS Ranger")
	ranger_ship["maintenance_state"] = "MOTHBALLED"
	Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "ISS Explorer")
	Game.state.set_formation_ship_ids(SpaceGameState.DEFAULT_FORMATION_ID, [String(horizon_ship.get("instance_id", ""))])
	var refit_bom := Game.simulation.loadout_fabrication_costs(refit_modules)
	for item_id_value in refit_bom.keys():
		var item_id := String(item_id_value)
		Game.state.add_item(item_id, int(refit_bom[item_id]))
	var main := MainScene.instantiate() as Control
	add_child(main)
	await _redraw()
	var formations_before_roster := Game.state.fleet_formations.duplicate(true)
	var ships_before_roster := Game.state.ships.duplicate(true)
	var fleet_nav := main.find_child("Navigation_ships", true, false) as Button
	_check(fleet_nav != null, "Fleet navigation exists")
	fleet_nav.pressed.emit()
	await _redraw()
	var roster_tab := main.find_child("FleetSection_roster", true, false) as Button
	var roster_tabs := roster_tab.get_parent() if roster_tab != null else null
	var roster_box := roster_tabs.get_parent() if roster_tabs != null else null
	_check(roster_tab != null and roster_tabs != null and roster_tabs.get_index() == 0, "Ship roster starts with the unchanged internal Ship tabs")
	_check(roster_box != null and roster_box.get_child_count() == 4, "roster tabs, compact header, filters, and master-detail body have no empty top placeholders")
	var roster_header := main.find_child("FleetRosterHeader", true, false) as HBoxContainer
	var roster_header_title := main.find_child("FleetRosterHeaderTitle", true, false) as Label
	var roster_header_count := main.find_child("FleetRosterHeaderCount", true, false) as Label
	_check(roster_box != null and roster_box.get_child(1) == roster_header, "compact Ship Roster header follows immediately after the internal tabs")
	_check(roster_header_title != null and roster_header_title.text == "舰船名册" and not _has_label_containing(roster_box, "永久舰船名册"), "the old Persistent Ship Roster title is completely replaced")
	_check(roster_header_count != null and roster_header_count.text == "%d 艘舰船" % Game.state.ships.size() and Game.state.ships.size() == 8, "header count reads the real permanent ship collection")
	_check(roster_header_title != null and roster_header_count != null and roster_header_title.size_flags_horizontal == Control.SIZE_EXPAND_FILL and roster_header_count.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT, "responsive HBox keeps title left and ship count right")
	_check(main.find_child("CreateFormation", true, false) == null and _named_child_count(main, "SelectFormation_") == 0, "task-force management controls are not rendered in Ship Roster")
	_check(not _has_exact_label(roster_box, I18n.core("ships.title")) and not _has_exact_label(roster_box, I18n.core("ships.subtitle")) and not _has_exact_label(roster_box, I18n.core("ships.stat.entities")) and not _has_exact_label(roster_box, I18n.core("ships.stat.expedition_command")), "roster introduction and four large summary cards are absent")
	var pioneer := Game.state.ships.filter(func(ship): return String(ship.get("name", "")) == "ISS Pioneer").front() as Dictionary
	var pioneer_id := String(pioneer.get("instance_id", ""))
	var body_margin := main.find_child("FleetRosterBodyMargin", true, false) as MarginContainer
	var master_detail := main.find_child("FleetRosterMasterDetail", true, false) as HBoxContainer
	var list_surface := main.find_child("FleetRosterListSurface", true, false) as PanelContainer
	var list_scroll := main.find_child("FleetRosterListScroll", true, false) as ScrollContainer
	var ship_list := main.find_child("FleetRosterShipList", true, false) as VBoxContainer
	var inspector_surface := main.find_child("FleetRosterInspectorSurface", true, false) as PanelContainer
	var detail := main.find_child("FleetRosterDetail", true, false) as VBoxContainer
	var pioneer_list_item := main.find_child("FleetRosterShip_%s" % pioneer_id, true, false) as Button
	var pioneer_hull_class := main.find_child("FleetRosterHullClass_%s" % pioneer_id, true, false) as Label
	var pioneer_lifecycle_dot := main.find_child("FleetRosterLifecycleDot_%s" % pioneer_id, true, false) as PanelContainer
	var pioneer_lifecycle := main.find_child("FleetRosterLifecycle_%s" % pioneer_id, true, false) as Label
	var pioneer_formation := main.find_child("FleetRosterFormation_%s" % pioneer_id, true, false) as Label
	var pioneer_selection_control := main.find_child("FleetRosterSelectionControl_%s" % pioneer_id, true, false) as CheckBox
	var browser_summary := main.find_child("FleetRosterBrowserSummary", true, false) as Label
	var select_filtered := main.find_child("FleetRosterSelectFiltered", true, false) as CheckBox
	var result_range := main.find_child("FleetRosterResultRange", true, false) as Label
	_check(body_margin != null and master_detail != null and list_surface != null and list_scroll != null and ship_list != null and inspector_surface != null and detail != null, "roster body uses independent Ship Browser and Ship Inspector surfaces with a scrolling list host")
	_check(is_equal_approx(list_surface.size_flags_stretch_ratio, 0.341) and is_equal_approx(inspector_surface.size_flags_stretch_ratio, 0.639), "master-detail body uses the Golden Reference 34/64 responsive width weights")
	var measured_gap := inspector_surface.position.x - (list_surface.position.x + list_surface.size.x)
	var browser_share := list_surface.size.x / maxf(1.0, list_surface.size.x + inspector_surface.size.x)
	_check(absf(measured_gap - float(UiTokens.layout_px(21))) <= 1.0 and absf(browser_share - (34.1 / 98.0)) <= 0.01, "Ship Browser and Ship Inspector preserve the approximately 20 px gutter and normalized Golden Reference width ratio")
	_check(is_equal_approx(list_surface.size.y, inspector_surface.size.y) and list_surface.size.y > pioneer_list_item.size.y * 2.0, "both roster work surfaces expand through the remaining vertical workspace")
	print("SHIP_ROSTER_STEP04_GEOMETRY viewport=%dx%d body_x=%.1f browser=%.1f gap=%.1f inspector=%.1f height=%.1f" % [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y, list_surface.global_position.x, list_surface.size.x, measured_gap, inspector_surface.size.x, list_surface.size.y])
	_check(ship_list.get_child_count() == 8 and pioneer_list_item != null and pioneer_hull_class != null and pioneer_hull_class.text == "护卫舰 · T1", "Ship Browser renders eight isolated fixture rows from real Hull Class and construction engineering tier data")
	var expected_roster_row_height := float(maxi(UiTokens.layout_px(61), int(round(61.0 * UiTokens.ui_scale()))))
	_check(pioneer_list_item.text.is_empty() and absf(pioneer_list_item.size.y - expected_roster_row_height) <= 1.0 and pioneer_list_item.find_child("FleetRosterLeftInfo_%s" % pioneer_id, true, false) is VBoxContainer and pioneer_list_item.find_child("FleetRosterRightInfo_%s" % pioneer_id, true, false) is VBoxContainer, "ShipRow follows the larger of the accepted layout scale and full typography scale")
	_check(pioneer_selection_control != null and pioneer_selection_control.mouse_filter == Control.MOUSE_FILTER_IGNORE and select_filtered != null and select_filtered.mouse_filter == Control.MOUSE_FILTER_IGNORE, "real CheckBox controls reserve row and filtered-result selection structure without enabling STEP 10 behavior")
	var pioneer_dot_style := pioneer_lifecycle_dot.get_theme_stylebox("panel") as StyleBoxFlat if pioneer_lifecycle_dot != null else null
	_check(pioneer_lifecycle_dot != null and pioneer_lifecycle_dot.custom_minimum_size == UiTokens.layout_vector(Vector2(8, 8)) and pioneer_lifecycle != null and pioneer_lifecycle.text == "运行中" and not pioneer_lifecycle.text.contains("●") and pioneer_dot_style != null and pioneer_dot_style.bg_color.is_equal_approx(UiTokens.COLOR_RUNNING), "ACTIVE lifecycle uses a real 8 px UI circle at the 100% Golden pixel calibration and muted semantic green rather than a Unicode dot")
	var reserve_dot := main.find_child("FleetRosterLifecycleDot_%s" % String(reserve_ship.get("instance_id", "")), true, false) as PanelContainer
	var mothballed_dot := main.find_child("FleetRosterLifecycleDot_%s" % String(mothballed_ship.get("instance_id", "")), true, false) as PanelContainer
	var reserve_dot_style := reserve_dot.get_theme_stylebox("panel") as StyleBoxFlat if reserve_dot != null else null
	var mothballed_dot_style := mothballed_dot.get_theme_stylebox("panel") as StyleBoxFlat if mothballed_dot != null else null
	var mothballed_lifecycle := main.find_child("FleetRosterLifecycle_%s" % String(mothballed_ship.get("instance_id", "")), true, false) as Label
	_check(reserve_dot_style != null and reserve_dot_style.bg_color.is_equal_approx(UiTokens.COLOR_WARNING) and mothballed_dot_style != null and mothballed_dot_style.bg_color.is_equal_approx(UiTokens.COLOR_GHOST) and mothballed_lifecycle != null and mothballed_lifecycle.text == "封存", "reserve and mothballed rows use the centralized muted amber/gray colors and locked lifecycle copy")
	_check(pioneer_formation != null and pioneer_formation.text == "—", "an unassigned ship displays the locked em dash instead of UI-only assignment data")
	var horizon_formation := main.find_child("FleetRosterFormation_%s" % String(horizon_ship.get("instance_id", "")), true, false) as Label
	var horizon_hull_class := main.find_child("FleetRosterHullClass_%s" % String(horizon_ship.get("instance_id", "")), true, false) as Label
	_check(horizon_formation != null and horizon_formation.text == I18n.core("ships.formation.primary") and horizon_hull_class != null and horizon_hull_class.text == "巡洋舰 · T2", "fleet membership plus Frigate/Cruiser and T1/T2 copy come from real domain definitions")
	_check(browser_summary != null and browser_summary.text == "8 艘 · 当前显示 8 艘" and result_range != null and result_range.text == "显示 1–8 / 8", "Ship Browser header and footer ranges are calculated from total and filtered collections")
	_check(list_scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO and list_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "Ship Browser owns an independent vertical scrolling region")
	print("SHIP_ROSTER_STEP05_BROWSER row=%.1f header=%.1f footer=%.1f visible_rows=%d" % [pioneer_list_item.size.y, (main.find_child("FleetRosterBrowserHeader", true, false) as Control).size.y, (main.find_child("FleetRosterBrowserFooter", true, false) as Control).size.y, ship_list.get_child_count()])
	var selected_ship_ids := main.get("_selected_roster_ship_ids") as Dictionary
	var selected_row_style := pioneer_list_item.get_theme_stylebox("normal") as StyleBoxFlat
	var normal_row := main.find_child("FleetRosterShip_%s" % String(horizon_ship.get("instance_id", "")), true, false) as Button
	var normal_row_style := normal_row.get_theme_stylebox("normal") as StyleBoxFlat if normal_row != null else null
	_check(selected_ship_ids.size() == 1 and selected_ship_ids.has(pioneer_id) and selected_row_style.border_color.is_equal_approx(UiTokens.COLOR_FOCUS) and normal_row_style != null and normal_row_style.border_color.is_equal_approx(UiTokens.COLOR_BORDER), "first visible ship is selected by default with a teal surface border distinct from normal rows")
	var selected_row_content_inside := _ship_row_content_inside(pioneer_list_item, [pioneer_selection_control, main.find_child("FleetRosterShipName_%s" % pioneer_id, true, false), pioneer_hull_class, pioneer_lifecycle, pioneer_formation])
	var horizon_id := String(horizon_ship.get("instance_id", ""))
	var normal_row_content_inside := _ship_row_content_inside(normal_row, [main.find_child("FleetRosterSelectionControl_%s" % horizon_id, true, false), main.find_child("FleetRosterShipName_%s" % horizon_id, true, false), horizon_hull_class, main.find_child("FleetRosterLifecycle_%s" % horizon_id, true, false), horizon_formation])
	_check(selected_row_content_inside and normal_row_content_inside, "selected and unselected ShipRows fully contain checkbox plus both left/right text lines at every tested UI scale")
	_check((main.find_child("FleetRosterBrowserHeader", true, false) as Control).size.y == UiTokens.layout_px(46) and (main.find_child("FleetRosterBrowserFooter", true, false) as Control).size.y == UiTokens.layout_px(86), "ShipRow scaling leaves Browser metadata and footer geometry unchanged")
	normal_row.pressed.emit()
	await _redraw()
	_check(_operational_value(main, "formation") == I18n.core("ships.formation.primary") and _operational_value(main, "combat_position") == I18n.core("ships.zone.FRONT") and (main.find_child("FleetRosterInspectorShipName", true, false) as Label).text == "ISS HORIZON", "Inspector follows the selected real ship and reads formation plus the existing default FRONT combat-position fallback")
	pioneer_list_item = main.find_child("FleetRosterShip_%s" % pioneer_id, true, false) as Button
	pioneer_list_item.pressed.emit()
	await _redraw()
	var roster_shell_left := main.find_child("ResourceRailSurface", true, false) as Control
	var roster_shell_right := main.find_child("ContextInspectorSurface", true, false) as Control
	var roster_shell_bottom := main.find_child("CommandDockSurface", true, false) as Control
	_check(roster_shell_left != null and roster_shell_right != null and roster_shell_bottom != null and not roster_shell_left.visible and not roster_shell_right.visible and not roster_shell_bottom.visible, "Ship Roster reuses the full-width shell workspace while preserving the global top bars")
	_check(_has_label_containing(roster_box, "ISS Pioneer"), "ISS Pioneer remains visible with its existing roster information")
	var inspector_identity := main.find_child("FleetRosterInspectorIdentityHeader", true, false) as HBoxContainer
	var inspector_name := main.find_child("FleetRosterInspectorShipName", true, false) as Label
	var inspector_hull_class := main.find_child("FleetRosterInspectorHullClass", true, false) as Label
	var inspector_upper := main.find_child("FleetRosterInspectorUpperContent", true, false) as HBoxContainer
	var ship_visual_panel := main.find_child("FleetRosterShipVisualPanel", true, false) as PanelContainer
	var operational_panel := main.find_child("FleetRosterOperationalStatusPanel", true, false) as PanelContainer
	var inspector_status_dot := main.find_child("FleetRosterInspectorLifecycleDot", true, false) as PanelContainer
	_check(inspector_identity != null and inspector_name != null and inspector_name.text == "ISS PIONEER" and inspector_hull_class != null and inspector_hull_class.text == "护卫舰 · T1", "STEP 06 Inspector identity uses the real selected ship plus Hull Class and Tier")
	_check(inspector_upper != null and ship_visual_panel != null and operational_panel != null and inspector_upper.get_child_count() == 2 and is_equal_approx(ship_visual_panel.size_flags_stretch_ratio, 0.555) and is_equal_approx(operational_panel.size_flags_stretch_ratio, 0.445), "STEP 06 upper Inspector is the isolated Ship Visual and Operational Status pair")
	_check(main.find_children("FleetRosterOperationalRow_*", "HBoxContainer", true, false).size() == 5 and _operational_value(main, "status") == "运行中" and _operational_value(main, "location") == "地球轨道" and _operational_value(main, "formation") == "—" and _operational_value(main, "role") == "—" and _operational_value(main, "combat_position") == "—", "Operational Status exposes exactly five structured fields from canonical state while unavailable role/position stay neutral")
	var operational_value_x := (main.find_child("FleetRosterOperationalValue_status", true, false) as Label).global_position.x
	var operational_values_aligned := true
	for field_id in ["location", "formation", "role", "combat_position"]:
		operational_values_aligned = operational_values_aligned and absf((main.find_child("FleetRosterOperationalValue_%s" % field_id, true, false) as Label).global_position.x - operational_value_x) <= 1.0
	_check(operational_values_aligned, "all five Operational Status values share one aligned value column")
	var inspector_dot_style := inspector_status_dot.get_theme_stylebox("panel") as StyleBoxFlat if inspector_status_dot != null else null
	_check(inspector_status_dot != null and inspector_status_dot.custom_minimum_size == UiTokens.layout_vector(Vector2(8, 8)) and inspector_dot_style != null and inspector_dot_style.bg_color.is_equal_approx(UiTokens.COLOR_RUNNING), "Inspector status reuses the accepted real 8 px lifecycle primitive and semantic color")
	var inspector_ship_art := main.find_child("FleetRosterShipVisual", true, false) as TextureRect
	_check(inspector_ship_art != null and inspector_ship_art.texture != null and inspector_ship_art.texture.resource_path == "res://assets/ui/ship_registry/ships/patchwork_prospector_ship.png" and inspector_ship_art.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "patchwork_prospector Inspector uses only its approved aspect-preserving project-owned artwork")
	var operational_icon_paths := {
		"status":"res://assets/ui/ship_registry/icons/status.png",
		"location":"res://assets/ui/ship_registry/icons/location.png",
		"formation":"res://assets/ui/ship_registry/icons/fleet.png",
		"role":"res://assets/ui/ship_registry/icons/current_role.png",
		"combat_position":"res://assets/ui/ship_registry/icons/tactical_position.png"
	}
	var operational_icons_valid := true
	for field_id_value in operational_icon_paths:
		var field_id := String(field_id_value)
		var operational_icon := main.find_child("FleetRosterOperationalIcon_%s" % field_id, true, false) as TextureRect
		var operational_atlas := operational_icon.texture as AtlasTexture if operational_icon != null else null
		operational_icons_valid = operational_icons_valid and operational_icon != null and operational_atlas != null and operational_atlas.atlas != null and operational_icon.custom_minimum_size == UiTokens.layout_vector(Vector2(16, 16)) and operational_atlas.atlas.resource_path == String(operational_icon_paths[field_id])
	_check(operational_icons_valid, "all five Operational Status rows use their approved 16 px project-owned texture assets")
	_check(main.find_child("SetShipActive_%s" % pioneer_id, true, false) == null and main.find_child("SetShipReadyReserve_%s" % pioneer_id, true, false) == null and main.find_child("MothballShip_%s" % pioneer_id, true, false) == null and main.find_child("AssignStandby_%s" % pioneer_id, true, false) == null and main.find_child("AssignFormation_%s" % pioneer_id, true, false) == null and main.find_child("ShipCombatZone_%s_FRONT" % pioneer_id, true, false) == null and not _has_button_text(roster_box, I18n.core("ships.action.scrap")), "legacy lifecycle, formation, combat-position, and dismantle controls are no longer rendered")
	var inspector_scroll := main.find_child("FleetRosterInspectorScroll", true, false) as ScrollContainer
	var lower_row := main.find_child("FleetRosterLowerInfoRow", true, false) as HBoxContainer
	var basic_panel := main.find_child("FleetRosterBasicInformationPanel", true, false) as PanelContainer
	var configuration_panel := main.find_child("FleetRosterConfigurationSummaryPanel", true, false) as PanelContainer
	var readiness_panel := main.find_child("FleetRosterReadinessPanel", true, false) as PanelContainer
	_check(inspector_scroll != null and inspector_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED and inspector_scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO, "the Inspector owns a vertical accessibility viewport while preserving the fixed Master–Detail work surface")
	_check(lower_row != null and lower_row.get_child_count() == 3 and basic_panel != null and configuration_panel != null and readiness_panel != null and is_equal_approx(basic_panel.size_flags_stretch_ratio, 1.0) and is_equal_approx(configuration_panel.size_flags_stretch_ratio, 1.2) and is_equal_approx(readiness_panel.size_flags_stretch_ratio, 1.8), "STEP 07 lower region contains exactly the 1.0/1.2/1.8 Basic, Configuration, and Readiness panels")
	var expected_lower_height := float(UiTokens.layout_px(238))
	var expected_lower_gap := float(UiTokens.layout_px(18))
	var actual_lower_gap := lower_row.global_position.y - inspector_upper.get_global_rect().end.y
	_check(absf(lower_row.size.y - expected_lower_height) <= 1.0 and absf(configuration_panel.global_position.x - basic_panel.get_global_rect().end.x - expected_lower_gap) <= 1.0 and absf(readiness_panel.global_position.x - configuration_panel.get_global_rect().end.x - expected_lower_gap) <= 1.0 and absf(actual_lower_gap - expected_lower_gap) <= 1.0, "lower panels preserve their Golden height and 18 px vertical/horizontal rhythm")
	_check((main.find_child("FleetRosterBasicValue_ship_id", true, false) as Label).text == pioneer_id and (main.find_child("FleetRosterBasicValue_registry_code", true, false) as Label).text == "—" and (main.find_child("FleetRosterBasicValue_tonnage", true, false) as Label).text == "—" and (main.find_child("FleetRosterBasicValue_crew", true, false) as Label).text == "—" and (main.find_child("FleetRosterBasicValue_ship_class", true, false) as Label).text == "护卫舰 · T1" and (main.find_child("FleetRosterBasicValue_manufacturer", true, false) as Label).text == "—" and not (main.find_child("FleetRosterBasicValue_built_at", true, false) as Label).text.is_empty(), "Basic Information binds canonical identity/class/build time and exposes missing model concepts honestly")
	_check((main.find_child("FleetRosterConfigurationValue_weapon", true, false) as Label).text == "轻型机关炮" and (main.find_child("FleetRosterConfigurationValue_propulsion", true, false) as Label).text == "基础推进器" and (main.find_child("FleetRosterConfigurationValue_reactor", true, false) as Label).text == "民用反应堆核心" and (main.find_child("FleetRosterConfigurationValue_sensor", true, false) as Label).text == "传感器阵列" and (main.find_child("FleetRosterConfigurationValue_special", true, false) as Label).text == "民用护盾", "Configuration Summary is projected from the real installed module definitions and capabilities")
	var hull_readiness_bar := main.find_child("FleetRosterReadinessBar_hull_integrity", true, false) as ProgressBar
	var readiness_available := hull_readiness_bar != null and bool(hull_readiness_bar.get_meta("canonical_value_available", false)) and is_equal_approx(hull_readiness_bar.value, 100.0) and (main.find_child("FleetRosterReadinessValue_hull_integrity", true, false) as Label).text == "100%"
	var damaged_pioneer := pioneer.duplicate(true)
	damaged_pioneer["damage_taken"] = 125.0
	var damaged_readiness := main.call("_fleet_roster_readiness_values", damaged_pioneer) as Dictionary
	var damaged_hull := damaged_readiness.get("hull_integrity", {}) as Dictionary
	readiness_available = readiness_available and bool(damaged_hull.get("available", false)) and is_equal_approx(float(damaged_hull.get("value", -1.0)), 75.0)
	var unavailable_readiness_valid := true
	for field_id in ["weapon_system", "propulsion_system", "sensor_system"]:
		var readiness_bar := main.find_child("FleetRosterReadinessBar_%s" % field_id, true, false) as ProgressBar
		var readiness_value := main.find_child("FleetRosterReadinessValue_%s" % field_id, true, false) as Label
		unavailable_readiness_valid = unavailable_readiness_valid and readiness_bar != null and not bool(readiness_bar.get_meta("canonical_value_available", true)) and is_zero_approx(readiness_bar.value) and readiness_value != null and readiness_value.text == "—"
	_check(readiness_available and unavailable_readiness_valid, "Readiness uses canonical combat totals plus persisted damage for real hull percentages while missing subsystem health remains neutral")
	_check(String(main.call("_fleet_roster_compact_module_names", ["重复模块", "重复模块", "不同模块"])) == "重复模块 ×2%s不同模块" % I18n.core("format.list_separator"), "Configuration Summary compresses repeated real module definitions without duplicating rows")
	_check(_controls_inside(basic_panel, main.find_children("FleetRosterBasicValue_*", "Label", true, false)) and _controls_inside(configuration_panel, main.find_children("FleetRosterConfigurationValue_*", "Label", true, false)) and _controls_inside(readiness_panel, main.find_children("FleetRosterReadinessValue_*", "Label", true, false)) and _controls_inside(readiness_panel, main.find_children("FleetRosterReadinessBar_*", "ProgressBar", true, false)), "all STEP 07 values and ProgressBars remain inside their panels at every tested UI scale")
	_check(Game.state.fleet_formations == formations_before_roster and Game.state.ships == ships_before_roster, "roster layout cleanup does not mutate ship, task-force, formation, or save data")
	if OS.get_cmdline_user_args().has("--capture-roster-step05-fixture"):
		RenderingServer.force_draw(false)
		await get_tree().process_frame
		var fixture_output := "res://.audit-logs/ship_roster_step05_eight_rows.png"
		var fixture_error := get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(fixture_output))
		print("CAPTURE_SAVED: %s" % fixture_output if fixture_error == OK else "CAPTURE_FAILED: %s" % error_string(fixture_error))
		main.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if fixture_error == OK and failures.is_empty() else 1)
		return
	var all_filter := main.find_child("FleetRosterFilter_ALL", true, false) as Button
	var active_filter := main.find_child("FleetRosterFilter_ACTIVE", true, false) as Button
	var reserve_filter := main.find_child("FleetRosterFilter_READY_RESERVE", true, false) as Button
	var mothballed_filter := main.find_child("FleetRosterFilter_MOTHBALLED", true, false) as Button
	_check(all_filter != null and active_filter != null and reserve_filter != null and mothballed_filter != null and all_filter.text == "全部 8" and active_filter.text == "运行中 4" and reserve_filter.text == "战备储备 2" and mothballed_filter.text == "封存 2", "lifecycle filter counts are calculated from the eight-ship test fixture")
	_check(String(main.get("_fleet_roster_filter")) == "ALL" and all_filter.has_theme_stylebox_override("normal") and not active_filter.has_theme_stylebox_override("normal"), "All is the default filter and uses the existing selected-button accent")
	reserve_filter.pressed.emit()
	await _redraw()
	roster_box = _current_roster_box(main)
	browser_summary = main.find_child("FleetRosterBrowserSummary", true, false) as Label
	result_range = main.find_child("FleetRosterResultRange", true, false) as Label
	_check(_has_label_containing(roster_box, "Reserve Filter Fixture") and _has_label_containing(roster_box, "ISS Venture") and not _has_label_containing(roster_box, "ISS Pioneer") and not _has_label_containing(roster_box, "Mothballed Filter Fixture") and browser_summary.text == "8 艘 · 当前显示 2 艘" and result_range.text == "显示 1–2 / 8", "Ready Reserve filter drives rows plus real browser-header and footer counts")
	mothballed_filter = main.find_child("FleetRosterFilter_MOTHBALLED", true, false) as Button
	mothballed_filter.pressed.emit()
	await _redraw()
	roster_box = _current_roster_box(main)
	_check(_has_label_containing(roster_box, "Mothballed Filter Fixture") and not _has_label_containing(roster_box, "Reserve Filter Fixture"), "Mothballed filter shows only MOTHBALLED ships")
	active_filter = main.find_child("FleetRosterFilter_ACTIVE", true, false) as Button
	active_filter.pressed.emit()
	await _redraw()
	roster_box = _current_roster_box(main)
	_check(main.find_child("FleetRosterShip_%s" % pioneer_id, true, false) is Button and main.find_child("FleetRosterShip_%s" % refit_ship_id, true, false) is Button and main.find_child("FleetRosterShip_%s" % String(reserve_ship.get("instance_id", "")), true, false) == null, "Active filter shows only ACTIVE ships in the master list")
	reserve_ship = Game.state.ship_by_id(String(reserve_ship.get("instance_id", "")))
	reserve_ship["maintenance_state"] = "ACTIVE"
	venture_ship = Game.state.ship_by_id(String(venture_ship.get("instance_id", "")))
	venture_ship["maintenance_state"] = "ACTIVE"
	main.call("_rebuild_active_page")
	await _redraw()
	reserve_filter = main.find_child("FleetRosterFilter_READY_RESERVE", true, false) as Button
	_check(reserve_filter != null and reserve_filter.text == "战备储备 0", "filter counts recompute from live ship data after a lifecycle change")
	reserve_filter.pressed.emit()
	await _redraw()
	roster_box = _current_roster_box(main)
	selected_ship_ids = main.get("_selected_roster_ship_ids") as Dictionary
	browser_summary = main.find_child("FleetRosterBrowserSummary", true, false) as Label
	result_range = main.find_child("FleetRosterResultRange", true, false) as Label
	_check(_has_exact_label(roster_box, "当前没有符合条件的舰船") and main.find_child("FleetRosterHeaderCount", true, false).text == "8 艘舰船" and browser_summary.text == "8 艘 · 当前显示 0 艘" and result_range.text == "显示 0–0 / 8" and selected_ship_ids.is_empty() and not _has_label_containing(main.find_child("FleetRosterDetail", true, false), "ISS Pioneer"), "zero-result filter clears selection and stale detail while all real count surfaces remain correct")
	all_filter = main.find_child("FleetRosterFilter_ALL", true, false) as Button
	all_filter.pressed.emit()
	await _redraw()
	var overflow_ships: Array[Dictionary] = []
	for overflow_index in 5:
		overflow_ships.append(Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "Overflow Ship %d" % (overflow_index + 1)))
	var overflow_target := overflow_ships.back() as Dictionary
	main.call("_rebuild_active_page")
	await _redraw()
	ship_list = main.find_child("FleetRosterShipList", true, false) as VBoxContainer
	detail = main.find_child("FleetRosterDetail", true, false) as VBoxContainer
	list_scroll = main.find_child("FleetRosterListScroll", true, false) as ScrollContainer
	var overflow_target_id := String(overflow_target.get("instance_id", ""))
	var overflow_target_item := main.find_child("FleetRosterShip_%s" % overflow_target_id, true, false) as Button
	_check(ship_list != null and ship_list.get_child_count() == 13 and overflow_target_item != null and list_scroll.get_v_scroll_bar().max_value > list_scroll.get_v_scroll_bar().page, "large real ship results remain inside the independently scrolling Browser viewport")
	overflow_target_item.pressed.emit()
	await _redraw()
	detail = main.find_child("FleetRosterDetail", true, false) as VBoxContainer
	selected_ship_ids = main.get("_selected_roster_ship_ids") as Dictionary
	_check(selected_ship_ids.size() == 1 and selected_ship_ids.has(overflow_target_id) and _has_label_containing(detail, "OVERFLOW SHIP 5") and not _has_label_containing(detail, "ISS PIONEER"), "clicking a different list record switches the Inspector to that real ship")
	mothballed_filter = main.find_child("FleetRosterFilter_MOTHBALLED", true, false) as Button
	mothballed_filter.pressed.emit()
	await _redraw()
	ship_list = main.find_child("FleetRosterShipList", true, false) as VBoxContainer
	detail = main.find_child("FleetRosterDetail", true, false) as VBoxContainer
	selected_ship_ids = main.get("_selected_roster_ship_ids") as Dictionary
	_check(ship_list.get_child_count() == 2 and selected_ship_ids.size() == 1 and selected_ship_ids.has(String(mothballed_ship.get("instance_id", ""))) and _has_label_containing(detail, "MOTHBALLED FILTER FIXTURE"), "filter controls the master list and automatically replaces a filtered-out Inspector selection")
	all_filter = main.find_child("FleetRosterFilter_ALL", true, false) as Button
	all_filter.pressed.emit()
	await _redraw()
	var readiness_tab := main.find_child("FleetSection_readiness", true, false) as Button
	readiness_tab.pressed.emit()
	await _redraw()
	_check(main.find_child("CreateFormation", true, false) is Button and main.find_child("FleetDoctrine_HOLD_FORMATION", true, false) is Button and roster_shell_left.visible and roster_shell_right.visible and roster_shell_bottom.visible, "formation management, readiness UI, and normal shell chrome remain unchanged on the existing Readiness page")
	roster_tab = main.find_child("FleetSection_roster", true, false) as Button
	roster_tab.pressed.emit()
	await _redraw()
	var shipyard_tab := main.find_child("FleetSection_shipyard", true, false) as Button
	_check(shipyard_tab != null, "Shipyard tab exists")
	shipyard_tab.pressed.emit()
	await _redraw()
	_check(main.find_child("FleetSection_roster", true, false) is Button and main.find_child("FleetSection_readiness", true, false) is Button and main.find_child("FleetSection_archive", true, false) is Button and main.find_child("ShipsMissions", true, false) is Button, "content cleanup retains every Ship tab navigation and UI workspace")
	var map := main.find_child("ShipAssemblyMap", true, false) as GraphEdit
	_check(map != null, "Shipyard renders the interactive assembly canvas")
	_check(main.find_child("MainShipBlueprintEditor", true, false) is Control, "main game mounts the shared production blueprint editor")
	_check(main.find_child("AssemblyLibraryTabs", true, false) is TabContainer, "Shipyard exposes the shared Ships and Modules library tabs")
	_check(main.find_child("AssemblyShipCard_lunar_pathfinder", true, false) is Button, "hull plan is a draggable blueprint asset")
	_check(main.find_child("AssemblyShipCard_ultimate_combat", true, false) == null, "Ship tab content is scoped to the approved migrated Demo hull")
	_check(main.find_child("AssemblyModuleCard_plasma_cannon", true, false) == null, "unreviewed module entities are not injected into the retained library UI")
	_check(_named_child_count(main, "AssemblyShipCard_") == 1 and _named_child_count(main, "AssemblyModuleCard_") == 7, "Ship tab retains its complete UI while showing only the migrated Demo entities")
	var hull_palette_item := main.find_child("AssemblyShipCard_lunar_pathfinder", true, false) as Button
	var hull_palette_artwork := hull_palette_item.find_child("PaletteArtwork", true, false) as TextureRect
	_check(hull_palette_artwork != null and hull_palette_artwork.texture != null and not hull_palette_artwork.texture.resource_path.contains("_4k"), "hull library uses a lightweight preview while the canvas keeps the 4K hull")
	var weapon_palette_item := main.find_child("AssemblyModuleCard_light_autocannon", true, false) as Button
	_check(weapon_palette_item != null, "revealed part is a draggable palette item")
	var palette_artwork := weapon_palette_item.find_child("PaletteArtwork", true, false) as TextureRect
	_check(palette_artwork != null, "parts palette fills its left frame with generated equipment artwork")
	_check(palette_artwork != null and palette_artwork.texture != null and not palette_artwork.texture.resource_path.contains("_4k"), "asset library uses lightweight thumbnails instead of synchronously decoding 4K canvas art")
	var palette_title := weapon_palette_item.find_child("PaletteTitle", true, false) as Label
	_check(palette_title != null and palette_title.get_theme_font_size("font_size") == UiTokens.ship_assembly_font_size(13) and UiTokens.ship_assembly_font_size(13) == UiTokens.font_size(13), "Ship workspace typography uses the same player-selected font scale as the other main-game tabs")
	_check(UiTokens.ship_assembly_font_size(7) == UiTokens.ship_assembly_font_size(10), "Ship workspace microcopy shares one readable technical-text floor")
	_check(_graph_node_count(map) == 0 and map.get_connection_list().is_empty(), "new ship design canvas is blank and contains no pre-wired links")
	map.call("_drop_data", Vector2(620.0, 260.0), {"ship_assembly_palette":true, "kind":"hull", "plan_id":"construct_lunar_pathfinder", "definition_id":"lunar_pathfinder"})
	map.call("_drop_data", Vector2(120.0, 160.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"light_autocannon"})
	_check(_graph_node_count(map) == 2 and map.get_connection_list().is_empty(), "UI drops create hull and part without pre-connecting them")
	var editor_before_refresh := main.find_child("MainShipBlueprintEditor", true, false) as Control
	var map_before_refresh_id := map.get_instance_id()
	main.call("_rebuild_active_page")
	await _redraw()
	map = main.find_child("ShipAssemblyMap", true, false) as GraphEdit
	_check(main.find_child("MainShipBlueprintEditor", true, false) == editor_before_refresh and map.get_instance_id() == map_before_refresh_id and _graph_node_count(map) == 2, "domain refresh retains the live editor, its draft, and its canvas instead of rebuilding 4K entities")
	_check(main.find_child("ShipyardHandoffContent", true, false) is VBoxContainer, "targeted refresh retains the Shipyard handoff UI below the editor")
	var weapon := map.get_node_or_null(NodePath("ship_design_module_0001")) as GraphNode
	_check(weapon != null and weapon.find_child("ModuleNodeVisual", true, false) is Control, "all module categories use the approved Reactor Core component style")
	var canvas_artwork := weapon.find_child("ModuleArtwork", true, false) as TextureRect if weapon != null else null
	_check(canvas_artwork != null and canvas_artwork.texture != null and canvas_artwork.texture.resource_path.contains("_4k"), "placed canvas entities retain 4K artwork for close zoom")
	map.request_module_connection("ship_design_module_0001", "socket_weapon_0")
	_check(map.get_connection_list().size() == 1, "player-authored matching connection appears on the live canvas")
	map.call("_drop_data", Vector2(140.0, 360.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":"civilian_reactor_core"})
	await _redraw()
	var reactor := map.get_node_or_null(NodePath("ship_design_module_0002")) as GraphNode
	_check(reactor != null and reactor.find_child("ModuleNodeVisual", true, false) is Control, "Civilian Reactor Core and other modules share one reusable module-card renderer")
	if reactor != null:
		reactor.selected = true
		map.call("_on_node_selected", reactor)
		await _redraw()
	var inspector := main.find_child("AssemblyModuleInspector", true, false) as Control
	var shell_left := main.find_child("ResourceRailSurface", true, false) as Control
	var shell_right := main.find_child("ContextInspectorSurface", true, false) as Control
	_check(inspector != null and shell_left != null and shell_right != null and not shell_left.visible and not shell_right.visible, "selecting the reactor opens the blueprint data inspector while duplicate shell sidebars stay hidden")
	_check(inspector != null and inspector.find_child("ModuleInspectorArtwork", true, false) is TextureRect and inspector.find_child("ModuleInspectorSection_COMPATIBILITY", true, false) != null, "reactor inspector integrates artwork and data-driven expandable property sections")
	map.request_module_connection("ship_design_module_0002", "socket_core_0")
	for fitting in [["civilian_shield", "socket_shield_0"], ["advanced_drive", "socket_drive_0"], ["cargo_expansion", "socket_utility_1"]]:
		var next_index := _graph_node_count(map)
		map.call("_drop_data", Vector2(160.0 + float(next_index) * 36.0, 320.0 + float(next_index) * 26.0), {"ship_assembly_palette":true, "kind":"module", "definition_id":String(fitting[0])})
		map.request_module_connection("ship_design_module_%04d" % next_index, String(fitting[1]))
	var save_button := main.find_child("SaveBlueprintButton", true, false) as Button
	var name_edit := main.find_child("BlueprintNameEdit", true, false) as LineEdit
	if name_edit != null:
		name_edit.text = "Main UI Refit Blueprint"
	_check(save_button != null and not save_button.disabled, "complete main-game blueprint enables the shared Save Blueprint action")
	if save_button != null and not save_button.disabled:
		save_button.pressed.emit()
	await _redraw()
	var design_id := Game.last_saved_ship_design_id
	_check(not design_id.is_empty() and Game.state.ship_designs.has(design_id), "main-game Save Blueprint persists the shared editor draft")
	var refit_button := main.find_child("RefitShipDesign_%s_%s" % [design_id, refit_ship_id], true, false) as Button
	_check(refit_button != null, "saved blueprint exposes a matching physical-hull refit handoff")
	_check(refit_button != null and not refit_button.disabled, "matching physical-hull refit handoff is enabled: %s" % String(Game.ship_design_refit_availability(design_id, refit_ship_id).get("reason", "missing control")))
	_check(main.find_child("SaveShipLoadout_%s" % refit_ship_id, true, false) == null and main.find_child("InstallModule_%s_sensor_array" % refit_ship_id, true, false) == null, "legacy loadout and direct plugin-adjustment controls are absent")
	if refit_button != null and not refit_button.disabled:
		refit_button.pressed.emit()
	await _redraw()
	_check(Game.state.refit_projects.any(func(project): return String((project as Dictionary).get("ship_id", "")) == refit_ship_id and String((project as Dictionary).get("target_loadout_id", "")) == design_id), "blueprint handoff starts the authoritative starport refit project")
	main.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("SHIP_ASSEMBLY_UI_TEST_PASS")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _redraw() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _graph_node_count(graph: GraphEdit) -> int:
	var count := 0
	for child in graph.get_children():
		if child is GraphNode and String(child.get_meta("entity_kind", "")) != "socket":
			count += 1
	return count


func _named_child_count(root: Node, prefix: String) -> int:
	var count := 0
	for child in root.find_children("%s*" % prefix, "", true, false):
		if String(child.name).begins_with(prefix):
			count += 1
	return count


func _current_roster_box(root: Node) -> Node:
	var all_filter := root.find_child("FleetRosterFilter_ALL", true, false)
	return all_filter.get_parent().get_parent() if all_filter != null else null


func _has_exact_label(root: Node, expected_text: String) -> bool:
	if root == null:
		return false
	for child in root.find_children("*", "Label", true, false):
		if (child as Label).text == expected_text:
			return true
	return false


func _has_label_containing(root: Node, fragment: String) -> bool:
	if root == null:
		return false
	for child in root.find_children("*", "Label", true, false):
		if (child as Label).text.contains(fragment):
			return true
	return false


func _operational_value(root: Node, field_id: String) -> String:
	var value := root.find_child("FleetRosterOperationalValue_%s" % field_id, true, false) as Label
	return value.text if value != null else ""


func _ship_row_content_inside(row: Control, controls: Array) -> bool:
	if row == null:
		return false
	var row_top := row.global_position.y
	var row_bottom := row_top + row.size.y
	for control_value in controls:
		var control := control_value as Control
		if control == null or control.global_position.y < row_top - 0.5 or control.global_position.y + control.size.y > row_bottom + 0.5:
			return false
	return true


func _controls_inside(container: Control, controls: Array) -> bool:
	if container == null:
		return false
	var bounds := container.get_global_rect().grow(0.5)
	for control_value in controls:
		var control := control_value as Control
		if control == null or not bounds.encloses(control.get_global_rect()):
			return false
	return true


func _has_button_text(root: Node, expected_text: String) -> bool:
	if root == null:
		return false
	for child in root.find_children("*", "Button", true, false):
		if (child as Button).text == expected_text:
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
