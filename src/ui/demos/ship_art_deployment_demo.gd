extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipAssemblyLibraryScript = preload("res://src/ui/components/ship_assembly_library.gd")
const ShipAssemblyDataPanelScript = preload("res://src/ui/components/ship_assembly_data_panel.gd")

const DEMO_SHIPS: Array[Dictionary] = [
	{"id":"lunar_pathfinder", "plan_id":"construct_lunar_pathfinder", "english":"LUNAR PATHFINDER"}
]
const DEMO_PART_IDS: Array[String] = [
	"light_autocannon", "civilian_shield", "radiation_shielding", "advanced_drive", "sensor_array", "cargo_expansion", "civilian_reactor_core"
]
const FONT_SCALE_OPTIONS: Array[int] = [75, 100, 125, 150, 175, 200]
const DEFAULT_FONT_SCALE := 1.0
const FONT_SCALE_SESSION_META := "ship_assembly_demo_font_scale"

var _catalog: Dictionary = {}
var _assembly_view: ShipAssemblyMapView
var _library: PanelContainer
var _data_panel: PanelContainer
var _status_label: Label
var _measurement_label: Label
var _design_badge: Label
var _load_picker: OptionButton
var _load_button: Button
var _font_scale_picker: OptionButton
var _draft: Dictionary = {}
var _blueprint_name := "巡航护卫方案 A"
var _design_id := ""
var _draft_dirty := false
var _selection_kind := ""
var _selection_id := ""
var _previous_ui_scale := 1.0
var _user_font_scale := DEFAULT_FONT_SCALE
var _applied_font_scale := -1.0
var _interface_rebuild_queued := false
var _interface_rebuilding := false


func _ready() -> void:
	_previous_ui_scale = UiTokens.ui_scale()
	_user_font_scale = _sanitize_font_scale(float(get_tree().root.get_meta(FONT_SCALE_SESSION_META, DEFAULT_FONT_SCALE)))
	_configure_manual_scaling()
	_apply_native_theme()
	_catalog = _demo_catalog()
	_build_demo()
	_refresh_saved_designs()
	_refresh_engineering()


func _exit_tree() -> void:
	UiTokens.set_ui_scale(_previous_ui_scale)


func _configure_manual_scaling() -> void:
	# Resolution changes only alter the available workspace. Font and symbol size
	# are controlled exclusively by the percentage selector in the command bar.
	scale = Vector2.ONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _accessibility_layout_scale() -> float:
	return maxf(1.0, sqrt(_user_font_scale))


func _apply_native_theme() -> void:
	_applied_font_scale = _user_font_scale
	theme = UiTokens.build_theme(_applied_font_scale, true)


func _sanitize_font_scale(value: float) -> float:
	var normalized := value / 100.0 if value > 10.0 else value
	var closest := DEFAULT_FONT_SCALE
	var distance := INF
	for percent in FONT_SCALE_OPTIONS:
		var candidate := float(percent) / 100.0
		var candidate_distance := absf(candidate - normalized)
		if candidate_distance < distance:
			closest = candidate
			distance = candidate_distance
	return closest


func _queue_interface_rebuild() -> void:
	if _interface_rebuild_queued or _interface_rebuilding or not is_inside_tree():
		return
	_interface_rebuild_queued = true
	call_deferred("_rebuild_interface_for_manual_scale")


func _rebuild_interface_for_manual_scale() -> void:
	_interface_rebuild_queued = false
	if not is_inside_tree():
		return
	if is_equal_approx(_user_font_scale, _applied_font_scale):
		return
	_interface_rebuilding = true
	var selected_tab: int = _library.current_tab() if is_instance_valid(_library) else 0
	var preserved_status: String = _status_label.text if is_instance_valid(_status_label) else ""
	var preserved_canvas_zoom := 0.82
	var preserved_canvas_center := Vector2.ZERO
	if is_instance_valid(_assembly_view):
		preserved_canvas_zoom = _assembly_view.zoom
		preserved_canvas_center = (_assembly_view.scroll_offset + _assembly_view.size * 0.5) / maxf(_assembly_view.zoom, 0.01)
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_apply_native_theme()
	_build_demo()
	_refresh_saved_designs()
	if not _draft.is_empty():
		_assembly_view.configure(_catalog, _draft)
	call_deferred("_restore_canvas_view_after_native_rebuild", preserved_canvas_center, preserved_canvas_zoom)
	_library.select_tab(selected_tab)
	_refresh_engineering()
	if not preserved_status.is_empty():
		_status_label.text = preserved_status
	_interface_rebuilding = false


func _restore_canvas_view_after_native_rebuild(world_center: Vector2, zoom_value: float) -> void:
	# Nested containers report provisional sizes during their first layout pass,
	# especially when accessibility-sized resource cards are introduced. Wait for
	# the final canvas rectangle before restoring the same world-space center.
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_assembly_view):
		_assembly_view.restore_view_center(world_center, zoom_value)


func assembly_view() -> ShipAssemblyMapView:
	return _assembly_view


func library_panel() -> PanelContainer:
	return _library


func data_panel() -> PanelContainer:
	return _data_panel


func _build_demo() -> void:
	var background := ColorRect.new()
	background.color = Color("06100f")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var page := VBoxContainer.new()
	page.name = "BlueprintEditorFrame"
	add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.offset_left = 12.0
	page.offset_top = 12.0
	page.offset_right = -12.0
	page.offset_bottom = -12.0
	page.add_theme_constant_override("separation", 10)
	page.add_child(_build_header())
	var workspace := HBoxContainer.new()
	workspace.name = "BlueprintWorkspace"
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 10)
	page.add_child(workspace)
	_library = ShipAssemblyLibraryScript.new()
	_library.entity_selected.connect(_on_entity_selected)
	workspace.add_child(_library)
	_library.configure(_catalog, DEMO_SHIPS, DEMO_PART_IDS)
	_library.custom_minimum_size.x = 320.0 * _accessibility_layout_scale()
	workspace.add_child(_build_canvas())
	_data_panel = ShipAssemblyDataPanelScript.new()
	_data_panel.save_requested.connect(_save_blueprint)
	_data_panel.blueprint_name_changed.connect(_on_blueprint_name_changed)
	workspace.add_child(_data_panel)
	_data_panel.custom_minimum_size.x = 288.0 * _accessibility_layout_scale()


func _build_header() -> Control:
	var panel := PanelContainer.new()
	panel.name = "BlueprintCommandBar"
	panel.custom_minimum_size.y = 64.0
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("0a1918"), UiTokens.COLOR_BORDER_STRONG, 3))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)
	var high_text_scale := _applied_font_scale >= 1.5
	var primary_row := HBoxContainer.new()
	primary_row.add_theme_constant_override("separation", 10)
	var actions_row := primary_row
	if high_text_scale:
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 8)
		margin.add_child(stack)
		stack.add_child(primary_row)
		actions_row = HBoxContainer.new()
		actions_row.alignment = BoxContainer.ALIGNMENT_END
		actions_row.add_theme_constant_override("separation", 10)
		stack.add_child(actions_row)
	else:
		margin.add_child(primary_row)
	var brand := VBoxContainer.new()
	brand.custom_minimum_size.x = 290.0
	brand.add_theme_constant_override("separation", 1)
	var brand_name := _label("HELIOS CORE", 10, UiTokens.COLOR_FOCUS)
	brand_name.name = "BlueprintBrand"
	brand.add_child(brand_name)
	brand.add_child(_label("舰船装配实验室\nSHIP ASSEMBLY LAB", 14, UiTokens.COLOR_TEXT))
	primary_row.add_child(brand)
	var context := VBoxContainer.new()
	context.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	context.alignment = BoxContainer.ALIGNMENT_CENTER
	context.add_theme_constant_override("separation", 1)
	context.add_child(_label("当前设计  /  BLUEPRINT", 8, UiTokens.COLOR_TEXT_MUTED))
	_design_badge = _label("UNSAVED DESIGN", 9, UiTokens.COLOR_TEXT_SECONDARY)
	_design_badge.name = "CurrentBlueprintBadge"
	context.add_child(_design_badge)
	primary_row.add_child(context)
	_font_scale_picker = OptionButton.new()
	_font_scale_picker.name = "ShipAssemblyFontScale"
	_font_scale_picker.custom_minimum_size.x = 96.0
	_font_scale_picker.tooltip_text = "字体大小 / TEXT SIZE"
	_font_scale_picker.accessibility_name = "字体大小"
	for percent in FONT_SCALE_OPTIONS:
		_font_scale_picker.add_item("%d%%" % percent, percent)
	var selected_percent := int(round(_user_font_scale * 100.0))
	_font_scale_picker.select(_font_scale_picker.get_item_index(selected_percent))
	_font_scale_picker.item_selected.connect(_on_font_scale_selected)
	actions_row.add_child(_font_scale_picker)
	_load_picker = OptionButton.new()
	_load_picker.name = "SavedBlueprintPicker"
	_load_picker.custom_minimum_size.x = 208.0
	_load_picker.tooltip_text = "选择已经保存的舰船蓝图"
	_load_picker.item_selected.connect(_on_load_picker_selected)
	actions_row.add_child(_load_picker)
	_load_button = Button.new()
	_load_button.name = "LoadBlueprintButton"
	_load_button.text = "载入"
	_load_button.custom_minimum_size = Vector2(104.0, 40.0)
	_load_button.pressed.connect(_load_selected_blueprint)
	actions_row.add_child(_load_button)
	var new_button := Button.new()
	new_button.name = "NewBlueprintButton"
	new_button.text = "新建"
	new_button.custom_minimum_size = Vector2(126.0, 40.0)
	new_button.pressed.connect(_new_blueprint)
	actions_row.add_child(new_button)
	return panel


func _build_canvas() -> Control:
	var panel := PanelContainer.new()
	panel.name = "BlueprintCanvasRegion"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("081514"), UiTokens.COLOR_BORDER, 3))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	panel.add_child(column)
	var caption := HBoxContainer.new()
	caption.custom_minimum_size.y = 28.0
	caption.add_theme_constant_override("separation", 8)
	var canvas_title := _label("装配画布  /  ASSEMBLY CANVAS", 9, UiTokens.COLOR_TEXT_MUTED)
	canvas_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	caption.add_child(canvas_title)
	_measurement_label = _label("W —  ·  L —", 8, UiTokens.COLOR_TEXT_MUTED)
	_measurement_label.name = "BlueprintHullMeasurements"
	caption.add_child(_measurement_label)
	column.add_child(caption)
	_assembly_view = ShipAssemblyMapViewScript.new()
	_assembly_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_assembly_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_assembly_view.draft_changed.connect(_on_draft_changed)
	_assembly_view.entity_selected.connect(_on_entity_selected)
	_assembly_view.notice_requested.connect(_on_notice_requested)
	column.add_child(_assembly_view)
	_assembly_view.configure(_catalog, {})
	var status_bar := PanelContainer.new()
	status_bar.name = "BlueprintStatusBar"
	status_bar.custom_minimum_size.y = 30.0
	status_bar.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("071210"), UiTokens.COLOR_BORDER, 0))
	_status_label = _label("从左侧选择一艘舰船开始设计。", 8, UiTokens.COLOR_TEXT_SECONDARY)
	_status_label.name = "BlueprintStatusLabel"
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status_bar.add_child(_status_label)
	column.add_child(status_bar)
	return panel


func _demo_catalog() -> Dictionary:
	var plans := {}
	var hulls := {}
	for definition in DEMO_SHIPS:
		var ship_id := str(definition.get("id", ""))
		var plan_id := str(definition.get("plan_id", ""))
		var hull := (Game.content.ships.get(ship_id, {}) as Dictionary).duplicate(true)
		var plan := (Game.content.ship_construction_projects.get(plan_id, {}) as Dictionary).duplicate(true)
		if hull.is_empty() or plan.is_empty():
			continue
		hull["title"] = I18n.content(hull)
		plan["title"] = I18n.content(plan)
		plan["assembly_sockets"] = Game.ship_design_socket_schema(plan_id)
		hulls[ship_id] = hull
		plans[plan_id] = plan
	var modules := {}
	for module_id in DEMO_PART_IDS:
		var module := (Game.content.modules.get(module_id, {}) as Dictionary).duplicate(true)
		if module.is_empty():
			continue
		module["title"] = I18n.content(module)
		module["assembly_mount"] = Game.ship_module_mount_role(module_id)
		modules[module_id] = module
	return {
		"plans":plans,
		"hulls":hulls,
		"modules":modules,
		"slot_labels":{"weapon":"武器", "shield":"防御", "drive":"推进", "utility":"功能", "core":"核心"},
		"structural_label":"通用结构 / STRUCTURE",
		"socket_label_format":"%s %d",
		"module_label_format":"%s · %s",
		"hull_summary_format":"%s · %d sockets",
		"core_socket_format":"能源核心 %d",
		"functional_socket_shapes":true
	}


func _refresh_engineering() -> void:
	if not is_instance_valid(_data_panel):
		return
	var plan_id := str(_draft.get("plan_id", ""))
	if plan_id.is_empty() and not DEMO_SHIPS.is_empty():
		plan_id = str(DEMO_SHIPS[0].get("plan_id", ""))
	var nodes := _draft.get("nodes", []) as Array
	var connections := _draft.get("connections", []) as Array
	# The standalone replacement Demo may author design intent before the hull
	# development project is complete. Shipyard submission still enforces the
	# real unlock in Game.enqueue_saved_ship_design().
	var validation := Game.ship_design_validation(plan_id, nodes, connections, true)
	var summary := Game.ship_design_engineering_summary(plan_id, nodes, connections, true)
	var default_hull_id := str(Game.content.ship_construction_projects.get(plan_id, {}).get("ship_id", ""))
	var hull_id := str(_draft.get("hull_id", default_hull_id))
	_data_panel.configure({
		"blueprint_name":_blueprint_name,
		"design_id":_design_id,
		"draft":_draft,
		"validation":validation,
		"summary":summary,
		"plan":Game.content.ship_construction_projects.get(plan_id, {}),
		"hull":Game.content.ships.get(hull_id, {}),
		"selection_kind":_selection_kind,
		"selection_id":_selection_id
	})
	_refresh_design_badge()


func _on_draft_changed(snapshot: Dictionary) -> void:
	_draft = snapshot.duplicate(true)
	_draft_dirty = true
	_refresh_draft_chrome()
	_refresh_engineering()


func _refresh_draft_chrome(status_override: String = "") -> void:
	var hull_id := str(_draft.get("hull_id", ""))
	if hull_id.is_empty():
		_status_label.text = status_override if not status_override.is_empty() else "从左侧选择一艘舰船开始设计。"
		_measurement_label.text = "W —  ·  L —"
	else:
		var hull := Game.content.ships.get(hull_id, {}) as Dictionary
		var visual := hull.get("hull_visual", {}) as Dictionary
		var module_count := maxi(0, (_draft.get("nodes", []) as Array).size() - 1)
		var connection_count := (_draft.get("connections", []) as Array).size()
		_status_label.text = status_override if not status_override.is_empty() else "%s · 已放置 %d 个零件 · 已连接 %d 个插槽" % [I18n.content(hull), module_count, connection_count]
		_measurement_label.text = "W %.0fm  ·  L %.0fm" % [float(visual.get("beam_m", 0.0)), float(visual.get("length_m", 0.0))]


func _on_entity_selected(kind: String, entity_id: String) -> void:
	_selection_kind = kind
	_selection_id = entity_id
	_refresh_engineering()


func _on_blueprint_name_changed(value: String) -> void:
	_blueprint_name = value
	_draft_dirty = true
	_refresh_design_badge()


func _refresh_design_badge() -> void:
	if not is_instance_valid(_design_badge):
		return
	var state_label := "UNSAVED" if _design_id.is_empty() else ("MODIFIED" if _draft_dirty else "SAVED")
	_design_badge.text = "%s  ·  %s" % [_blueprint_name, state_label]


func _on_font_scale_selected(index: int) -> void:
	if not is_instance_valid(_font_scale_picker) or index < 0:
		return
	_user_font_scale = _sanitize_font_scale(float(_font_scale_picker.get_item_id(index)))
	get_tree().root.set_meta(FONT_SCALE_SESSION_META, _user_font_scale)
	_queue_interface_rebuild()


func _save_blueprint() -> void:
	var snapshot := _assembly_view.draft_snapshot() if is_instance_valid(_assembly_view) else _draft
	var plan_id := str(snapshot.get("plan_id", ""))
	if Game.save_ship_design(_design_id, _blueprint_name, plan_id, snapshot.get("nodes", []), snapshot.get("connections", []), true):
		_design_id = Game.last_saved_ship_design_id
		var saved_design := Game.state.ship_designs.get(_design_id, {}) as Dictionary
		_blueprint_name = str(saved_design.get("name", _blueprint_name))
		_draft = saved_design.duplicate(true)
		_draft_dirty = false
		var saved_notice := Game.last_notice
		var persisted := not Game.persistence_enabled or Game.save_game()
		var status := "%s；蓝图已保存，未启动建造或改装。" % saved_notice
		if not persisted:
			status = "%s；蓝图保留在当前会话，但本地存档写入失败。" % saved_notice
		_refresh_saved_designs(_design_id)
		_refresh_draft_chrome(status)
	else:
		_status_label.text = Game.last_notice
	_refresh_engineering()


func _new_blueprint() -> void:
	_design_id = ""
	_blueprint_name = "新舰船设定 %d" % (Game.state.ship_designs.size() + 1)
	_selection_kind = ""
	_selection_id = ""
	_draft = {}
	_draft_dirty = false
	_assembly_view.clear_draft(false)
	_assembly_view.call("_reset_view")
	_library.select_tab(0)
	_refresh_saved_designs()
	_refresh_draft_chrome("已创建空白蓝图；不会影响任何实体舰船。")
	_refresh_engineering()


func _refresh_saved_designs(preferred_design_id: String = "") -> void:
	if not is_instance_valid(_load_picker):
		return
	_load_picker.clear()
	_load_picker.add_item("暂无已保存蓝图")
	_load_picker.set_item_metadata(0, "")
	var design_ids: Array = Game.state.ship_designs.keys()
	design_ids.sort()
	for design_id_value in design_ids:
		var design_id := str(design_id_value)
		var design := Game.state.ship_designs.get(design_id, {}) as Dictionary
		if str(design.get("hull_id", "")) != "lunar_pathfinder":
			continue
		_load_picker.add_item(str(design.get("name", design_id)))
		_load_picker.set_item_metadata(_load_picker.item_count - 1, design_id)
	var target_design_id := preferred_design_id if not preferred_design_id.is_empty() else _design_id
	var selected_index := -1
	for item_index in range(1, _load_picker.item_count):
		if str(_load_picker.get_item_metadata(item_index)) == target_design_id:
			selected_index = item_index
			break
	if selected_index < 0 and _load_picker.item_count > 1:
		selected_index = 1
	if selected_index > 0:
		_load_picker.set_item_text(0, "选择已保存蓝图")
		_load_picker.select(selected_index)
	else:
		_load_picker.select(0)
	if is_instance_valid(_load_button):
		_load_button.disabled = selected_index <= 0


func _on_load_picker_selected(index: int) -> void:
	if is_instance_valid(_load_button):
		_load_button.disabled = index <= 0


func _load_selected_blueprint() -> void:
	if not is_instance_valid(_load_picker) or _load_picker.selected <= 0:
		_status_label.text = "请先选择一个已经保存的舰船蓝图。"
		return
	var design_id := str(_load_picker.get_item_metadata(_load_picker.selected))
	var design := Game.state.ship_designs.get(design_id, {}) as Dictionary
	if design.is_empty():
		_status_label.text = "找不到所选蓝图。"
		return
	if not (_catalog.get("plans", {}) as Dictionary).has(str(design.get("plan_id", ""))):
		_status_label.text = "所选蓝图不属于当前舰船装配 Demo。"
		return
	_design_id = design_id
	_blueprint_name = str(design.get("name", design_id))
	_selection_kind = ""
	_selection_id = ""
	_draft = design.duplicate(true)
	_draft_dirty = false
	_assembly_view.configure(_catalog, _draft)
	_refresh_draft_chrome("已载入 %s；修改仍只存在于当前蓝图草稿中。" % _blueprint_name)
	_refresh_engineering()


func _on_notice_requested(code: String) -> void:
	_status_label.text = {
		"HULL_ALREADY_PLACED":"当前蓝图已有舰体；一个蓝图只能使用一艘舰体。",
		"PORT_DIRECTION_INVALID":"请从零件的内嵌接口连接到舰体插槽。",
		"PORT_SHAPE_MISMATCH":"功能族或物理安装接口不匹配。",
		"PORT_SIZE_MISMATCH":"零件尺寸超过该舰体插槽的物理等级。",
		"PORT_ALREADY_OCCUPIED":"该零件或舰体插槽已经被占用。"
	}.get(code, "当前操作无法完成。")


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(font_size))
	label.add_theme_color_override("font_color", color)
	return label
