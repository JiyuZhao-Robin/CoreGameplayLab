extends Node

const MainScene = preload("res://src/ui/main.tscn")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipDismantleModalScript = preload("res://src/ui/components/ship_dismantle_modal.gd")

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
	# The production acceptance viewport is fixed even under the 64×64 Dummy
	# headless root, so layout assertions exercise the real STEP 08 composition.
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1672.0, 941.0)
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
	_check(absf(measured_gap - 21.0) <= 1.0 and absf(browser_share - (34.1 / 98.0)) <= 0.01, "Ship Browser and Ship Inspector preserve the approximately 20 px gutter and normalized Golden Reference width ratio")
	_check(is_equal_approx(list_surface.size.y, inspector_surface.size.y) and list_surface.size.y > pioneer_list_item.size.y * 2.0, "both roster work surfaces expand through the remaining vertical workspace")
	print("SHIP_ROSTER_STEP04_GEOMETRY viewport=%dx%d body_x=%.1f browser=%.1f gap=%.1f inspector=%.1f height=%.1f" % [get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y, list_surface.global_position.x, list_surface.size.x, measured_gap, inspector_surface.size.x, list_surface.size.y])
	_check(ship_list.get_child_count() == 8 and pioneer_list_item != null and pioneer_hull_class != null and pioneer_hull_class.text == "护卫舰 · T1", "Ship Browser renders eight isolated fixture rows from real Hull Class and construction engineering tier data")
	var expected_roster_row_height := float(UiTokens.full_scale_px(61.0 / 1.5))
	_check(pioneer_list_item.text.is_empty() and absf(pioneer_list_item.size.y - expected_roster_row_height) <= 1.0 and pioneer_list_item.find_child("FleetRosterLeftInfo_%s" % pioneer_id, true, false) is VBoxContainer and pioneer_list_item.find_child("FleetRosterRightInfo_%s" % pioneer_id, true, false) is VBoxContainer, "ShipRow follows the canonical full-scale Golden density without an independent nested scale")
	_check(pioneer_selection_control != null and pioneer_selection_control.mouse_filter == Control.MOUSE_FILTER_STOP and pioneer_selection_control.focus_mode == Control.FOCUS_ALL and select_filtered != null and select_filtered.mouse_filter == Control.MOUSE_FILTER_STOP and select_filtered.focus_mode == Control.FOCUS_ALL, "STEP 10 activates the real row and filtered-result CheckBox controls for mouse and keyboard input")
	var pioneer_dot_style := pioneer_lifecycle_dot.get_theme_stylebox("panel") as StyleBoxFlat if pioneer_lifecycle_dot != null else null
	_check(pioneer_lifecycle_dot != null and pioneer_lifecycle_dot.custom_minimum_size == UiTokens.full_scale_vector(Vector2(8, 8) / 1.5) and pioneer_lifecycle != null and pioneer_lifecycle.text == "运行中" and not pioneer_lifecycle.text.contains("●") and pioneer_dot_style != null and pioneer_dot_style.bg_color.is_equal_approx(UiTokens.COLOR_RUNNING), "ACTIVE lifecycle uses a real 8 px UI circle at the 150% Golden calibration and muted semantic green rather than a Unicode dot")
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
	_check(selected_ship_ids.size() == 1 and selected_ship_ids.has(pioneer_id) and selected_row_style.border_color.is_equal_approx(UiTokens.COLOR_FOCUS) and normal_row_style != null and normal_row_style.border_color.is_equal_approx(UiTokens.COLOR_REGISTRY_SEPARATOR), "first visible ship is selected by default with a teal surface border distinct from normal rows")
	var selected_row_content_inside := _ship_row_content_inside(pioneer_list_item, [pioneer_selection_control, main.find_child("FleetRosterShipName_%s" % pioneer_id, true, false), pioneer_hull_class, pioneer_lifecycle, pioneer_formation])
	var horizon_id := String(horizon_ship.get("instance_id", ""))
	var normal_row_content_inside := _ship_row_content_inside(normal_row, [main.find_child("FleetRosterSelectionControl_%s" % horizon_id, true, false), main.find_child("FleetRosterShipName_%s" % horizon_id, true, false), horizon_hull_class, main.find_child("FleetRosterLifecycle_%s" % horizon_id, true, false), horizon_formation])
	_check(selected_row_content_inside and normal_row_content_inside, "selected and unselected ShipRows fully contain checkbox plus both left/right text lines at every tested UI scale")
	_check(absf((main.find_child("FleetRosterBrowserHeader", true, false) as Control).size.y - UiTokens.full_scale_px(46.0 / 1.5)) <= 1.0 and absf((main.find_child("FleetRosterBrowserFooter", true, false) as Control).size.y - UiTokens.full_scale_px(86.0 / 1.5)) <= 1.0, "Browser metadata, rows and footer share the canonical Golden full-scale path")
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
	var inspector_scale_ratio := UiTokens.ui_scale() / 1.5
	_check(inspector_status_dot != null and inspector_status_dot.custom_minimum_size.is_equal_approx(Vector2(8, 8) * inspector_scale_ratio) and inspector_dot_style != null and inspector_dot_style.bg_color.is_equal_approx(UiTokens.COLOR_RUNNING), "Inspector status reuses the scale-aware lifecycle primitive and semantic color")
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
		operational_icons_valid = operational_icons_valid and operational_icon != null and operational_atlas != null and operational_atlas.atlas != null and operational_icon.custom_minimum_size.is_equal_approx(Vector2(16, 16) * inspector_scale_ratio) and operational_atlas.atlas.resource_path == String(operational_icon_paths[field_id])
	_check(operational_icons_valid, "all five Operational Status rows use their approved scale-aware project-owned texture assets")
	_check(main.find_child("SetShipActive_%s" % pioneer_id, true, false) == null and main.find_child("SetShipReadyReserve_%s" % pioneer_id, true, false) == null and main.find_child("MothballShip_%s" % pioneer_id, true, false) == null and main.find_child("AssignStandby_%s" % pioneer_id, true, false) == null and main.find_child("AssignFormation_%s" % pioneer_id, true, false) == null and main.find_child("ShipCombatZone_%s_FRONT" % pioneer_id, true, false) == null and not _has_button_text(roster_box, I18n.core("ships.action.scrap")), "legacy lifecycle, formation, combat-position, and dismantle controls are no longer rendered")
	var inspector_host := main.find_child("FleetRosterInspectorHost", true, false) as Container
	var inspector_scroll := main.find_child("FleetRosterInspectorScroll", true, false) as ScrollContainer
	var lower_row := main.find_child("FleetRosterLowerInfoRow", true, false) as HBoxContainer
	var basic_panel := main.find_child("FleetRosterBasicInformationPanel", true, false) as PanelContainer
	var configuration_panel := main.find_child("FleetRosterConfigurationSummaryPanel", true, false) as PanelContainer
	var readiness_panel := main.find_child("FleetRosterReadinessPanel", true, false) as PanelContainer
	_check(inspector_host != null and inspector_scroll == null, "the fixed Inspector workspace uses its bounded non-scrolling Container host without horizontal or vertical scrollbars")
	_check(lower_row != null and lower_row.get_child_count() == 3 and basic_panel != null and configuration_panel != null and readiness_panel != null and is_equal_approx(basic_panel.size_flags_stretch_ratio, 1.0) and is_equal_approx(configuration_panel.size_flags_stretch_ratio, 1.2) and is_equal_approx(readiness_panel.size_flags_stretch_ratio, 1.8), "STEP 07 lower region contains exactly the 1.0/1.2/1.8 Basic, Configuration, and Readiness panels")
	var expected_lower_height := float(roundi(266.0 * inspector_scale_ratio))
	var expected_lower_gap := float(roundi(18.0 * inspector_scale_ratio))
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

	var action_asset_paths := [
		"res://assets/ui/ship_registry/actions/star_normal.png",
		"res://assets/ui/ship_registry/actions/star_hover.png",
		"res://assets/ui/ship_registry/actions/star_active.png",
		"res://assets/ui/ship_registry/actions/star_disabled.png",
		"res://assets/ui/ship_registry/actions/lock_normal.png",
		"res://assets/ui/ship_registry/actions/lock_hover.png",
		"res://assets/ui/ship_registry/actions/lock_active.png",
		"res://assets/ui/ship_registry/actions/lock_disabled.png",
		"res://assets/ui/ship_registry/actions/more_normal.png",
		"res://assets/ui/ship_registry/actions/more_hover.png",
		"res://assets/ui/ship_registry/actions/more_active.png",
		"res://assets/ui/ship_registry/actions/more_disabled.png"
	]
	var all_action_assets_valid := true
	for asset_path_value in action_asset_paths:
		var asset_path := String(asset_path_value)
		var texture := load(asset_path) as Texture2D if ResourceLoader.exists(asset_path) else null
		var source_image := Image.load_from_file(ProjectSettings.globalize_path(asset_path))
		var used_rect := source_image.get_used_rect()
		var import_text := FileAccess.get_file_as_string("%s.import" % asset_path)
		all_action_assets_valid = all_action_assets_valid and texture != null and texture.resource_path == asset_path and texture.get_width() == 64 and texture.get_height() == 64 and source_image.get_size() == Vector2i(64, 64) and maxi(used_rect.size.x, used_rect.size.y) >= 56 and import_text.contains("mipmaps/generate=false")
	_check(all_action_assets_valid, "all twelve supplied Ship Registry actions use crisp 64 px runtime derivatives with visible glyph area and mipmaps disabled")

	var header_actions := main.find_child("FleetRosterHeaderActions", true, false) as HBoxContainer
	var favorite_button := main.find_child("FleetRosterFavorite", true, false) as Button
	var lock_button := main.find_child("FleetRosterLock", true, false) as Button
	var more_button := main.find_child("FleetRosterMore", true, false) as Button
	var footer_actions := main.find_child("FleetRosterFooterActions", true, false) as HBoxContainer
	var dispatch_button := main.find_child("FleetRosterDispatch", true, false) as Button
	var details_button := main.find_child("FleetRosterViewDetails", true, false) as Button
	var dismantle_button := main.find_child("FleetRosterDismantle", true, false) as Button
	_check(header_actions != null and header_actions.get_child_count() == 3 and header_actions.get_child(0) == favorite_button and header_actions.get_child(1) == lock_button and header_actions.get_child(2) == more_button, "STEP 08 header action order is Favorite, Lock, More")
	_check(footer_actions != null and footer_actions.get_child_count() == 3 and footer_actions.get_child(0) == dispatch_button and footer_actions.get_child(1) == details_button and footer_actions.get_child(2) == dismantle_button, "STEP 08 footer action order is Dispatch, View Details, Dismantle Ship")
	_check(not favorite_button.text.contains("★") and not lock_button.text.contains("🔒") and not more_button.text.contains("…") and not more_button.text.contains("..."), "STEP 08 actions use supplied textures without Unicode or font-glyph icon fallbacks")
	var favorite_domain_connections := favorite_button.get_signal_connection_list("toggled").filter(func(connection): return (connection.get("callable") as Callable).get_method() == "_set_fleet_roster_ship_favorite").size()
	var lock_domain_connections := lock_button.get_signal_connection_list("toggled").filter(func(connection): return (connection.get("callable") as Callable).get_method() == "_set_fleet_roster_ship_locked").size()
	_check(favorite_domain_connections == 1 and lock_domain_connections == 1, "Favorite and Lock each retain exactly one domain mutation signal connection")
	var step08_inspector_host := main.find_child("FleetRosterInspectorHost", true, false) as Container
	var step08_inspector_surface := main.find_child("FleetRosterInspectorSurface", true, false) as PanelContainer
	var step08_identity := main.find_child("FleetRosterInspectorIdentityHeader", true, false) as HBoxContainer
	var step08_lower_inset := main.find_child("FleetRosterLowerInfoInset", true, false) as MarginContainer
	var step08_footer_inset := main.find_child("FleetRosterFooterInset", true, false) as MarginContainer
	var step08_footer_gap := details_button.global_position.x - dispatch_button.get_global_rect().end.x if dispatch_button != null and details_button != null else -1.0
	var step08_header_gap := lock_button.global_position.x - favorite_button.get_global_rect().end.x if favorite_button != null and lock_button != null else -1.0
	var inspector_content_visible := step08_inspector_host != null and step08_inspector_surface != null and step08_inspector_surface.get_global_rect().grow(3.0).encloses(footer_actions.get_global_rect())
	_check(inspector_content_visible, "STEP 08 keeps the complete Inspector and footer inside the fixed work surface without introducing an Inspector scrollbar")
	var expected_favorite_width := float(roundi(106.0 * inspector_scale_ratio))
	var expected_more_width := float(roundi(44.0 * inspector_scale_ratio))
	var expected_header_height := float(roundi(40.0 * inspector_scale_ratio))
	var expected_footer_height := float(roundi(44.0 * inspector_scale_ratio))
	_check(absf(favorite_button.size.x - expected_favorite_width) <= 1.0 and absf(lock_button.size.x - expected_favorite_width) <= 1.0 and absf(more_button.size.x - expected_more_width) <= 1.0 and absf(favorite_button.size.y - expected_header_height) <= 1.0 and absf(dispatch_button.size.y - expected_footer_height) <= 1.0, "STEP 08 header and footer actions derive from the canonical player-selected UI scale")
	_check(UiTokens.ui_scale_percent() != 150 or (absf(inspector_upper.size.y - 211.0) <= 1.0 and absf(lower_row.size.y - 266.0) <= 1.0 and absf(dispatch_button.size.y - 44.0) <= 1.0), "150% calibration preserves the Golden Inspector dimensions")
	print("SHIP_ROSTER_STEP08_ACTION_GEOMETRY scale=%d identity_h=%.1f header_h=%.1f header_gap=%.1f favorite_w=%.1f lock_w=%.1f more_w=%.1f upper_h=%.1f lower_inset_h=%.1f lower_h=%.1f lower_gap=%.1f footer_inset_h=%.1f footer_h=%.1f footer_gap=%.1f footer_widths=%.1f/%.1f/%.1f" % [UiTokens.ui_scale_percent(), step08_identity.size.y, favorite_button.size.y, step08_header_gap, favorite_button.size.x, lock_button.size.x, more_button.size.x, inspector_upper.size.y, step08_lower_inset.size.y, lower_row.size.y, actual_lower_gap, step08_footer_inset.size.y, dispatch_button.size.y, step08_footer_gap, dispatch_button.size.x, details_button.size.x, dismantle_button.size.x])
	_check(details_button != null and details_button.disabled and details_button.tooltip_text == I18n.core("ships.roster.tooltip.details_unavailable"), "View Details truthfully reports the missing independent destination instead of opening a placeholder")
	_check(favorite_button != null and lock_button != null and more_button != null and favorite_button.icon.resource_path.ends_with("star_normal.png") and lock_button.icon.resource_path.ends_with("lock_normal.png") and more_button.icon.resource_path.ends_with("more_normal.png"), "inactive header actions use the supplied normal Star, Lock, and More assets")
	if more_button != null:
		more_button.disabled = true
		main.call("_refresh_fleet_roster_action_icon", more_button)
		_check(String(more_button.get_meta("ship_registry_icon_state", "")) == "disabled" and more_button.icon.resource_path.ends_with("more_disabled.png"), "disabled header actions use the supplied disabled asset")
		more_button.disabled = false
		main.call("_set_fleet_roster_action_pointer_down", more_button, true)
		_check(String(more_button.get_meta("ship_registry_icon_state", "")) == "active" and more_button.icon.resource_path.ends_with("more_active.png"), "pointer-down header actions use the supplied active asset")
		main.call("_set_fleet_roster_action_pointer_down", more_button, false)
		if DisplayServer.get_name() != "headless":
			var hover_position := more_button.get_global_rect().get_center()
			Input.warp_mouse(hover_position)
			var hover_motion := InputEventMouseMotion.new()
			hover_motion.position = hover_position
			hover_motion.global_position = hover_position
			get_viewport().push_input(hover_motion)
			await _redraw()
			main.call("_refresh_fleet_roster_action_icon", more_button)
			_check(String(more_button.get_meta("ship_registry_icon_state", "")) == "hover" and more_button.icon.resource_path.ends_with("more_hover.png"), "hovered header actions use the supplied hover asset in the real window")
			Input.warp_mouse(Vector2.ZERO)
			await _redraw()

	if favorite_button != null:
		favorite_button.button_pressed = true
		favorite_button.toggled.emit(true)
	await _redraw()
	_check(bool(Game.state.ship_by_id(pioneer_id).get("favorite", false)), "Favorite toggles the selected canonical Ship")
	var horizon_row_for_favorite := main.find_child("FleetRosterShip_%s" % horizon_id, true, false) as Button
	if horizon_row_for_favorite != null:
		horizon_row_for_favorite.pressed.emit()
	await _redraw()
	var pioneer_row_for_favorite := main.find_child("FleetRosterShip_%s" % pioneer_id, true, false) as Button
	if pioneer_row_for_favorite != null:
		pioneer_row_for_favorite.pressed.emit()
	await _redraw()
	favorite_button = main.find_child("FleetRosterFavorite", true, false) as Button
	_check(favorite_button != null and favorite_button.button_pressed and favorite_button.icon.resource_path.ends_with("star_active.png"), "Favorite survives selection changes and restores the supplied active Star asset")

	lock_button = main.find_child("FleetRosterLock", true, false) as Button
	if lock_button != null:
		lock_button.button_pressed = true
		lock_button.toggled.emit(true)
	await _redraw()
	dismantle_button = main.find_child("FleetRosterDismantle", true, false) as Button
	var locked_ship_count := Game.state.ships.size()
	var locked_scrap_count := int(Game.state.statistics.get("ships_scrapped", 0))
	_check(bool(Game.state.ship_by_id(pioneer_id).get("locked", false)) and dismantle_button != null and dismantle_button.disabled and dismantle_button.tooltip_text == I18n.t("notice.scrap_ship_locked"), "Lock toggles canonical Ship protection and immediately disables Dismantle with its localized reason")
	_check(not Game.scrap_ship(pioneer_id) and Game.state.ships.size() == locked_ship_count and int(Game.state.statistics.get("ships_scrapped", 0)) == locked_scrap_count and not Game.state.ship_by_id(pioneer_id).is_empty(), "a locked Ship cannot bypass protection through direct domain invocation")
	await _redraw()
	var horizon_row_for_lock := main.find_child("FleetRosterShip_%s" % horizon_id, true, false) as Button
	if horizon_row_for_lock != null:
		horizon_row_for_lock.pressed.emit()
	await _redraw()
	var pioneer_row_for_lock := main.find_child("FleetRosterShip_%s" % pioneer_id, true, false) as Button
	if pioneer_row_for_lock != null:
		pioneer_row_for_lock.pressed.emit()
	await _redraw()
	lock_button = main.find_child("FleetRosterLock", true, false) as Button
	_check(lock_button != null and lock_button.button_pressed and lock_button.icon.resource_path.ends_with("lock_active.png"), "Lock survives selection changes and restores the supplied active Lock asset")

	var persistence_root := ProjectSettings.globalize_path("res://.audit-logs/helios-ui-persistence-audit-step08")
	DirAccess.make_dir_recursive_absolute(persistence_root)
	var step08_repository := LocalSaveRepository.new()
	var persistence_configured := step08_repository.configure_audit_root(persistence_root)
	step08_repository.delete_save()
	var persisted_source := SpaceGameState.from_dictionary(Game.state.to_dictionary(), Game.content.domains.keys(), Game.content.regions)
	var disk_saved := persistence_configured and step08_repository.save_state(persisted_source, Game.content.version, [Game.content.pack_metadata])
	var disk_payload := step08_repository.load_data() if disk_saved else {}
	var disk_restored := SpaceGameState.from_dictionary(disk_payload, Game.content.domains.keys(), Game.content.regions) if not disk_payload.is_empty() else null
	_check(disk_restored != null and bool(disk_restored.ship_by_id(pioneer_id).get("favorite", false)) and bool(disk_restored.ship_by_id(pioneer_id).get("locked", false)), "Favorite and Lock survive the canonical LocalSaveRepository save/load path")
	step08_repository.delete_save()
	var system_nav_for_reopen := main.find_child("Navigation_system_map", true, false) as Button
	if system_nav_for_reopen != null:
		system_nav_for_reopen.pressed.emit()
	await _redraw()
	fleet_nav = main.find_child("Navigation_ships", true, false) as Button
	if fleet_nav != null:
		fleet_nav.pressed.emit()
	await _redraw()
	favorite_button = main.find_child("FleetRosterFavorite", true, false) as Button
	lock_button = main.find_child("FleetRosterLock", true, false) as Button
	_check(favorite_button != null and favorite_button.button_pressed and lock_button != null and lock_button.button_pressed, "Favorite and Lock restore from canonical Ship state after closing and reopening the Ship Registry")

	lock_button = main.find_child("FleetRosterLock", true, false) as Button
	if lock_button != null:
		lock_button.button_pressed = false
		lock_button.toggled.emit(false)
	await _redraw()
	dismantle_button = main.find_child("FleetRosterDismantle", true, false) as Button
	_check(not bool(Game.state.ship_by_id(pioneer_id).get("locked", true)) and dismantle_button != null and not dismantle_button.disabled, "unlocking immediately restores valid Dismantle availability")

	more_button = main.find_child("FleetRosterMore", true, false) as Button
	if more_button != null:
		more_button.pressed.emit()
	await _redraw()
	var more_popup := main.find_child("FleetRosterMoreMenu", true, false) as PopupMenu
	var more_actions_real := more_popup != null and more_popup.item_count > 0
	if more_popup != null:
		for item_index in more_popup.item_count:
			more_actions_real = more_actions_real and String(more_popup.get_item_metadata(item_index)) in ["set_active", "set_ready_reserve", "mothball", "reactivate"]
	_check(more_actions_real, "More is a non-empty anchored menu containing only canonical lifecycle operations")
	var ready_reserve_index := _popup_item_index_by_metadata(more_popup, "set_ready_reserve")
	if ready_reserve_index >= 0:
		more_popup.id_pressed.emit(more_popup.get_item_id(ready_reserve_index))
	await _redraw()
	_check(String(Game.state.ship_by_id(pioneer_id).get("maintenance_state", "")) == "READY_RESERVE", "More invokes the real Ready Reserve lifecycle command for the selected Ship")
	more_button = main.find_child("FleetRosterMore", true, false) as Button
	if more_button != null:
		more_button.pressed.emit()
	await _redraw()
	more_popup = main.find_child("FleetRosterMoreMenu", true, false) as PopupMenu
	var set_active_index := _popup_item_index_by_metadata(more_popup, "set_active")
	if set_active_index >= 0:
		more_popup.id_pressed.emit(more_popup.get_item_id(set_active_index))
	await _redraw()
	_check(String(Game.state.ship_by_id(pioneer_id).get("maintenance_state", "")) == "ACTIVE", "More invokes the real Active lifecycle command and preserves the selected Ship identifier")

	dispatch_button = main.find_child("FleetRosterDispatch", true, false) as Button
	if dispatch_button != null:
		dispatch_button.pressed.emit()
	await _redraw()
	var dispatch_popup := main.find_child("FleetRosterDispatchMenu", true, false) as PopupMenu
	var formation_index := _popup_item_index_by_metadata(dispatch_popup, SpaceGameState.DEFAULT_FORMATION_ID)
	if formation_index >= 0:
		dispatch_popup.id_pressed.emit(dispatch_popup.get_item_id(formation_index))
	await _redraw()
	_check(Game.state.ship_formation_id(pioneer_id) == SpaceGameState.DEFAULT_FORMATION_ID, "Dispatch passes the selected canonical Ship identifier to the real formation-assignment service")
	dispatch_button = main.find_child("FleetRosterDispatch", true, false) as Button
	if dispatch_button != null:
		dispatch_button.pressed.emit()
	await _redraw()
	dispatch_popup = main.find_child("FleetRosterDispatchMenu", true, false) as PopupMenu
	var mid_zone_index := -1
	if dispatch_popup != null:
		for item_index in dispatch_popup.item_count:
			var metadata: Variant = dispatch_popup.get_item_metadata(item_index)
			if metadata is Dictionary and String((metadata as Dictionary).get("zone", "")) == "MID":
				mid_zone_index = item_index
				break
	if mid_zone_index >= 0:
		dispatch_popup.id_pressed.emit(dispatch_popup.get_item_id(mid_zone_index))
	await _redraw()
	var pioneer_logistics := Game.state.fleet_logistics_runtime(SpaceGameState.DEFAULT_FORMATION_ID)
	var dispatched_formation := pioneer_logistics.get("formation", {}) as Dictionary
	_check(String((dispatched_formation.get("ship_zones", {}) as Dictionary).get(pioneer_id, "")) == "MID", "Dispatch passes the selected canonical Ship identifier to the real tactical-position service")
	dispatch_button = main.find_child("FleetRosterDispatch", true, false) as Button
	if dispatch_button != null:
		dispatch_button.pressed.emit()
	await _redraw()
	dispatch_popup = main.find_child("FleetRosterDispatchMenu", true, false) as PopupMenu
	var standby_index := _popup_item_index_by_metadata(dispatch_popup, "")
	if standby_index >= 0:
		dispatch_popup.id_pressed.emit(dispatch_popup.get_item_id(standby_index))
	await _redraw()
	_check(Game.state.ship_formation_id(pioneer_id).is_empty(), "Dispatch can return the same selected Ship to canonical standby state")

	var dismantle_fixture := Game.state._create_ship_instance("patchwork_prospector", ["light_autocannon", "civilian_shield", "basic_drive", "sensor_array", "civilian_reactor_core"], "STEP 08 Dismantle Fixture")
	var dismantle_fixture_id := String(dismantle_fixture.get("instance_id", ""))
	main.call("_rebuild_active_page")
	await _redraw()
	var fixture_row := main.find_child("FleetRosterShip_%s" % dismantle_fixture_id, true, false) as Button
	if fixture_row != null:
		fixture_row.pressed.emit()
	await _redraw()
	var dismantle_availability := Game.ship_scrap_availability(dismantle_fixture_id)
	var expected_recovery := dismantle_availability.get("recovery", {}) as Dictionary
	var expected_recovery_text := "—" if expected_recovery.is_empty() else String(main.call("_resource_dictionary", expected_recovery))
	var before_cancel_ship_count := Game.state.ships.size()
	var before_cancel_scrap_count := int(Game.state.statistics.get("ships_scrapped", 0))
	var before_cancel_archive_count := Game.state.naval_archive.size()
	var before_cancel_inventory := Game.state.aggregate_inventory().duplicate(true)
	dismantle_button = main.find_child("FleetRosterDismantle", true, false) as Button
	if dismantle_button != null and not dismantle_button.disabled:
		dismantle_button.pressed.emit()
	await _redraw()
	var dismantle_dialog: Variant = main.find_child("FleetRosterDismantleConfirmation", true, false)
	_check(dismantle_dialog != null and not Game.state.ship_by_id(dismantle_fixture_id).is_empty() and dismantle_dialog.dialog_text.contains("STEP 08 Dismantle Fixture") and dismantle_dialog.dialog_text.contains(dismantle_fixture_id) and dismantle_dialog.dialog_text.contains(expected_recovery_text), "Dismantle opens confirmation without mutation and displays canonical recovery data")
	if dismantle_dialog != null:
		var modal_panel := dismantle_dialog.find_child("FleetRosterDismantlePanel", true, false) as Control
		var modal_scrim := dismantle_dialog.find_child("FleetRosterDismantleScrim", true, false) as ColorRect
		var confirm_button := dismantle_dialog.call("get_ok_button") as Button
		var cancel_button := dismantle_dialog.call("get_cancel_button") as Button
		var golden_ratio := UiTokens.ui_scale() / 1.5
		_check(not dismantle_dialog is Window and modal_scrim != null and modal_scrim.size == main.size and modal_panel != null and is_equal_approx(modal_panel.size.x, round(690.0 * golden_ratio)) and is_equal_approx(modal_panel.size.y, round(300.0 * golden_ratio)) and confirm_button.size.y == round(44.0 * golden_ratio) and cancel_button.size.y == round(44.0 * golden_ratio), "Dismantle uses a full-screen themed in-application modal with Golden-scale panel and actions")
		_check(get_viewport().gui_get_focus_owner() == cancel_button, "Dismantle modal starts on the non-destructive Cancel action")
		var tab_event := InputEventKey.new()
		tab_event.keycode = KEY_TAB
		tab_event.pressed = true
		dismantle_dialog.call("_input", tab_event)
		_check(get_viewport().gui_get_focus_owner() == confirm_button, "Dismantle modal traps forward keyboard focus inside its two actions")
		dismantle_dialog.call("_input", tab_event)
		_check(get_viewport().gui_get_focus_owner() == cancel_button, "Dismantle modal cycles keyboard focus back to Cancel")
	if dismantle_dialog != null:
		var escape_event := InputEventKey.new()
		escape_event.keycode = KEY_ESCAPE
		escape_event.pressed = true
		dismantle_dialog.call("_input", escape_event)
	await _redraw()
	_check(not is_instance_valid(dismantle_dialog) and not Game.state.ship_by_id(dismantle_fixture_id).is_empty() and Game.state.ships.size() == before_cancel_ship_count and int(Game.state.statistics.get("ships_scrapped", 0)) == before_cancel_scrap_count and Game.state.naval_archive.size() == before_cancel_archive_count and Game.state.aggregate_inventory() == before_cancel_inventory, "Escape closes the dismantle confirmation without mutating Ships, archive, counters, or inventory")

	dismantle_button = main.find_child("FleetRosterDismantle", true, false) as Button
	if dismantle_button != null and not dismantle_button.disabled:
		dismantle_button.pressed.emit()
	await _redraw()
	dismantle_dialog = main.find_child("FleetRosterDismantleConfirmation", true, false)
	Game.set_ship_locked(dismantle_fixture_id, true)
	if dismantle_dialog != null:
		dismantle_dialog.confirmed.emit()
	await _redraw()
	_check(not Game.state.ship_by_id(dismantle_fixture_id).is_empty() and bool(Game.state.ship_by_id(dismantle_fixture_id).get("locked", false)) and dismantle_dialog != null and dismantle_dialog.dialog_text.contains(I18n.t("notice.scrap_ship_locked")), "confirmation re-checks Lock and blocks a stale-dialog dismantle bypass")
	if dismantle_dialog != null:
		dismantle_dialog.canceled.emit()
	Game.set_ship_locked(dismantle_fixture_id, false)
	await _redraw()

	var inventory_before_dismantle := {}
	for item_id_value in expected_recovery.keys():
		var item_id := String(item_id_value)
		inventory_before_dismantle[item_id] = Game.state.item_quantity(item_id, String(dismantle_fixture.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)))
	var ships_before_dismantle := Game.state.ships.size()
	var scraps_before_dismantle := int(Game.state.statistics.get("ships_scrapped", 0))
	dismantle_button = main.find_child("FleetRosterDismantle", true, false) as Button
	if dismantle_button != null and not dismantle_button.disabled:
		dismantle_button.pressed.emit()
	await _redraw()
	dismantle_dialog = main.find_child("FleetRosterDismantleConfirmation", true, false)
	if dismantle_dialog != null:
		dismantle_dialog.confirmed.emit()
		dismantle_dialog.confirmed.emit()
	await _redraw()
	var exact_recovery_credited := true
	for item_id_value in expected_recovery.keys():
		var item_id := String(item_id_value)
		exact_recovery_credited = exact_recovery_credited and Game.state.item_quantity(item_id, String(dismantle_fixture.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))) - int(inventory_before_dismantle[item_id]) == int(expected_recovery[item_id])
	var dismantled_round_trip := SpaceGameState.from_dictionary(Game.state.to_dictionary(), Game.content.domains.keys(), Game.content.regions)
	_check(Game.state.ship_by_id(dismantle_fixture_id).is_empty() and Game.state.ships.size() == ships_before_dismantle - 1 and int(Game.state.statistics.get("ships_scrapped", 0)) == scraps_before_dismantle + 1 and exact_recovery_credited and dismantled_round_trip.ship_by_id(dismantle_fixture_id).is_empty(), "Confirm performs exactly one atomic transaction, credits exact recovery, updates counts, and persists removal")
	var selected_after_dismantle := main.get("_selected_roster_ship_ids") as Dictionary
	_check(selected_after_dismantle.size() == 1 and not selected_after_dismantle.has(dismantle_fixture_id) and main.find_child("FleetRosterHeaderCount", true, false).text == "8 艘舰船" and main.find_child("FleetRosterShip_%s" % dismantle_fixture_id, true, false) == null, "successful dismantling refreshes list, counters, Inspector selection, and the truthful next Ship")

	var en_catalog := JSON.parse_string(FileAccess.get_file_as_string("res://data/localization_en.json")) as Dictionary
	var zh_catalog := JSON.parse_string(FileAccess.get_file_as_string("res://data/localization_zh_CN.json")) as Dictionary
	var step08_core_keys := ["ships.roster.action.favorite", "ships.roster.action.remove_favorite", "ships.roster.action.lock", "ships.roster.action.unlock", "ships.roster.action.more", "ships.roster.action.dispatch", "ships.roster.action.view_details", "ships.roster.action.dismantle", "ships.roster.tooltip.dispatch_unavailable", "ships.roster.tooltip.details_unavailable", "ships.roster.dismantle.confirmation_title", "ships.roster.dismantle.warning", "ships.roster.dismantle.recoverable", "ships.roster.dismantle.confirm", "common.cancel"]
	var step08_ui_keys := ["notice.scrap_ship_locked", "notice.ship_favorited", "notice.ship_unfavorited", "notice.ship_locked", "notice.ship_unlocked"]
	var step08_localization_parity := true
	for key_value in step08_core_keys:
		step08_localization_parity = step08_localization_parity and en_catalog.get("core_ui", {}).has(key_value) and zh_catalog.get("core_ui", {}).has(key_value)
	for key_value in step08_ui_keys:
		step08_localization_parity = step08_localization_parity and en_catalog.get("ui", {}).has(key_value) and zh_catalog.get("ui", {}).has(key_value)
	_check(step08_localization_parity, "STEP 08 Chinese and English localization keys remain in parity")
	Game.set_ship_favorite(pioneer_id, false)
	await _redraw()
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
	var all_filter_style := all_filter.get_theme_stylebox("normal") as StyleBoxFlat if all_filter != null else null
	var active_filter_style := active_filter.get_theme_stylebox("normal") as StyleBoxFlat if active_filter != null else null
	_check(String(main.get("_fleet_roster_filter")) == "ALL" and all_filter_style != null and active_filter_style != null and all_filter_style.bg_color == UiTokens.COLOR_REGISTRY_CONTROL_ACTIVE and active_filter_style.bg_color == UiTokens.COLOR_REGISTRY_CONTROL, "All is the default filter and uses the centralized selected-button accent")
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
	_check(_has_exact_label(roster_box, "未找到符合当前条件的舰船") and main.find_child("FleetRosterHeaderCount", true, false).text == "8 艘舰船" and browser_summary.text == "8 艘 · 当前显示 0 艘" and result_range.text == "显示 0–0 / 8" and selected_ship_ids.is_empty() and not _has_label_containing(main.find_child("FleetRosterDetail", true, false), "ISS Pioneer"), "zero-result filter clears selection and stale detail while all real count surfaces remain correct")
	all_filter = main.find_child("FleetRosterFilter_ALL", true, false) as Button
	all_filter.pressed.emit()
	await _redraw()
	var overflow_ships: Array[Dictionary] = []
	var overflow_count := 12
	for overflow_index in overflow_count:
		overflow_ships.append(Game.state._create_ship_instance("lunar_pathfinder", refit_modules, "Overflow Ship %d" % (overflow_index + 1)))
	var overflow_target := overflow_ships.back() as Dictionary
	main.call("_rebuild_active_page")
	await _redraw()
	ship_list = main.find_child("FleetRosterShipList", true, false) as VBoxContainer
	detail = main.find_child("FleetRosterDetail", true, false) as VBoxContainer
	list_scroll = main.find_child("FleetRosterListScroll", true, false) as ScrollContainer
	var overflow_target_id := String(overflow_target.get("instance_id", ""))
	var overflow_target_item := main.find_child("FleetRosterShip_%s" % overflow_target_id, true, false) as Button
	_check(ship_list != null and ship_list.get_child_count() == 8 + overflow_count and overflow_target_item != null and list_scroll.get_v_scroll_bar().max_value > list_scroll.get_v_scroll_bar().page, "large real ship results remain inside the independently scrolling Browser viewport")
	overflow_target_item.pressed.emit()
	await _redraw()
	detail = main.find_child("FleetRosterDetail", true, false) as VBoxContainer
	selected_ship_ids = main.get("_selected_roster_ship_ids") as Dictionary
	_check(selected_ship_ids.size() == 1 and selected_ship_ids.has(overflow_target_id) and _has_label_containing(detail, "OVERFLOW SHIP %d" % overflow_count) and not _has_label_containing(detail, "ISS PIONEER"), "clicking a different list record switches the Inspector to that real ship")
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
	Game.state.ships.clear()
	main.set("_fleet_section", "roster")
	main.call("_rebuild_active_page")
	await _redraw()
	_check((main.get("_selected_roster_ship_ids") as Dictionary).is_empty() and main.find_child("FleetRosterHeaderCount", true, false).text == "0 艘舰船" and main.find_child("FleetRosterFavorite", true, false) == null and main.find_child("FleetRosterFooterActions", true, false) == null and _has_exact_label(main.find_child("FleetRosterDetail", true, false), I18n.core("ships.roster.select_ship")), "Ship Registry remains valid with no selected Ship and renders its truthful empty Inspector state")
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


func _popup_item_index_by_metadata(popup: PopupMenu, expected: String) -> int:
	if popup == null:
		return -1
	for item_index in popup.item_count:
		if String(popup.get_item_metadata(item_index)) == expected:
			return item_index
	return -1


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
