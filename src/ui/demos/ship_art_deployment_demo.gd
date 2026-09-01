extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipAssemblyPaletteItemScript = preload("res://src/ui/components/ship_assembly_palette_item.gd")
const ShipPortGlyphScript = preload("res://src/ui/components/ship_port_glyph.gd")

const DEMO_SHIPS: Array[Dictionary] = [
	{
		"id":"lunar_pathfinder",
		"plan_id":"construct_lunar_pathfinder",
		"english":"LUNAR PATHFINDER"
	}
]
const DEMO_PART_IDS: Array[String] = [
	"light_autocannon",
	"civilian_shield",
	"advanced_drive",
	"sensor_array",
	"cargo_expansion",
	"civilian_reactor_core"
]
const PORT_LEGEND: Array[Dictionary] = [
	{"shape":"TRIANGLE", "label":"武器接口", "detail":"武器模块", "tone":"d46b62"},
	{"shape":"SQUARE", "label":"结构接口", "detail":"护盾 / 舱段", "tone":"69a9c8"},
	{"shape":"DIAMOND", "label":"推进接口", "detail":"引擎模块", "tone":"62c8cc"},
	{"shape":"PENTAGON", "label":"特殊接口", "detail":"传感器 / 插件", "tone":"69b987"},
	{"shape":"CIRCLE", "label":"核心接口", "detail":"能源核心", "tone":"d5ad61"}
]

var _assembly_view: GraphEdit
var _status_label: Label
var _ship_names := {}


func _ready() -> void:
	theme = UiTokens.build_theme(1.0)
	_build_demo()


func _build_demo() -> void:
	var background := ColorRect.new()
	background.color = Color("050b0a")
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var page := VBoxContainer.new()
	add_child(page)
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.offset_left = 18.0
	page.offset_top = 16.0
	page.offset_right = -18.0
	page.offset_bottom = -16.0
	page.add_theme_constant_override("separation", 12)
	page.add_child(_build_header())
	var workspace := HBoxContainer.new()
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 12)
	page.add_child(workspace)
	workspace.add_child(_build_palette())
	workspace.add_child(_build_canvas())


func _build_header() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("091311"), UiTokens.COLOR_BORDER_STRONG, 4))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var copy := VBoxContainer.new()
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var eyebrow := Label.new()
	eyebrow.text = "SHIP DEPLOYMENT / VISUAL TARGET DEMO"
	eyebrow.add_theme_color_override("font_color", UiTokens.COLOR_FOCUS)
	eyebrow.add_theme_font_size_override("font_size", UiTokens.font_size(11))
	copy.add_child(eyebrow)
	var title := Label.new()
	title.text = "舰船装备插槽与投影垂直切片"
	title.add_theme_color_override("font_color", UiTokens.COLOR_TEXT)
	title.add_theme_font_size_override("font_size", UiTokens.font_size(22))
	copy.add_child(title)
	row.add_child(copy)
	_status_label = Label.new()
	_status_label.text = "先拖入舰船，再拖入零件并连接相同形状的接口"
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_SECONDARY)
	row.add_child(_status_label)
	var clear := Button.new()
	clear.text = "清空画布"
	clear.custom_minimum_size = Vector2(116.0, 42.0)
	clear.pressed.connect(_clear_canvas)
	row.add_child(clear)
	panel.add_child(row)
	return panel


func _build_palette() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 350.0
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("08110f"), UiTokens.COLOR_BORDER, 4))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "装配零件库  /  DRAG & CONNECT"
	title.add_theme_color_override("font_color", UiTokens.COLOR_FOCUS)
	title.add_theme_font_size_override("font_size", UiTokens.font_size(13))
	column.add_child(title)
	var instruction := Label.new()
	instruction.text = "先从“舰船”拖入舰体，再从“零件”拖入模块；从模块的实心插头拉线到舰体上同形状的空心插槽。"
	instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instruction.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	instruction.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	column.add_child(instruction)
	column.add_child(_build_palette_tabs())
	column.add_child(_build_port_legend())
	panel.add_child(column)
	return panel


func _build_palette_tabs() -> TabContainer:
	var tabs := TabContainer.new()
	tabs.name = "DemoAssemblyPalette"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.custom_minimum_size.y = 420.0
	var scroll := ScrollContainer.new()
	scroll.name = "舰船"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var cards := VBoxContainer.new()
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 8)
	for definition in DEMO_SHIPS:
		var ship_id := String(definition.get("id", ""))
		var plan_id := String(definition.get("plan_id", ""))
		var hull := Game.content.ships.get(ship_id, {}) as Dictionary
		var visual := hull.get("hull_visual", {}) as Dictionary
		var ui_visual := hull.get("ui_visual", {}) as Dictionary
		var ship_name := I18n.content(hull)
		_ship_names[ship_id] = ship_name
		var card := ShipAssemblyPaletteItemScript.new()
		card.name = "DemoShipCard_%s" % ship_id
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.configure(
			{"ship_assembly_palette":true, "kind":"hull", "plan_id":plan_id, "definition_id":ship_id},
			"%s / %s\n%s · %d 个插槽\nL %.0fm × W %.0fm" % [ship_name, String(definition.get("english", "")), String(hull.get("class", "Ship")), int(hull.get("module_slots", 0)), float(visual.get("length_m", 0.0)), float(visual.get("beam_m", 0.0))],
			true,
			"拖动到右侧装配画布",
			String(ui_visual.get("topdown_texture", ""))
		)
		cards.add_child(card)
	scroll.add_child(cards)
	tabs.add_child(scroll)
	var parts_scroll := ScrollContainer.new()
	parts_scroll.name = "零件"
	parts_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parts_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var part_cards := VBoxContainer.new()
	part_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	part_cards.add_theme_constant_override("separation", 6)
	for module_id in DEMO_PART_IDS:
		var module := Game.content.modules.get(module_id, {}) as Dictionary
		if module.is_empty():
			continue
		var slot := String(module.get("slot", "utility"))
		var mount_role := Game.ship_module_mount_role(module_id)
		var card := ShipAssemblyPaletteItemScript.new()
		card.name = "DemoPartCard_%s" % module_id
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.configure(
			{"ship_assembly_palette":true, "kind":"module", "definition_id":module_id},
			"%s\n%s · %s · %s" % [I18n.content(module), String(module.get("size", "S")), _slot_label(slot), _port_symbol(slot, mount_role)],
			true,
			"拖入画布，再把实心插头连接到同形状的舰体插槽"
		)
		part_cards.add_child(card)
	parts_scroll.add_child(part_cards)
	tabs.add_child(parts_scroll)
	tabs.set_tab_title(0, "舰船")
	tabs.set_tab_title(1, "零件")
	return tabs


func _build_port_legend() -> Control:
	var panel := PanelContainer.new()
	panel.name = "DemoPortLegend"
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("07100e"), UiTokens.COLOR_BORDER, 3))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	var title := Label.new()
	title.text = "接口图形含义  //  空心为插槽，实心为零件插头"
	title.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_SECONDARY)
	title.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	column.add_child(title)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 8)
	flow.add_theme_constant_override("v_separation", 3)
	for definition in PORT_LEGEND:
		var row := HBoxContainer.new()
		row.custom_minimum_size.x = 154.0
		row.add_theme_constant_override("separation", 4)
		var glyph := ShipPortGlyphScript.new()
		glyph.custom_minimum_size = Vector2(30.0, 30.0)
		glyph.configure(String(definition.get("shape", "SQUARE")), Color(String(definition.get("tone", "ffffff"))), false, "idle", 1, 5.0)
		row.add_child(glyph)
		var label := Label.new()
		label.text = "%s\n%s" % [String(definition.get("label", "")), String(definition.get("detail", ""))]
		label.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
		label.add_theme_font_size_override("font_size", UiTokens.font_size(9))
		row.add_child(label)
		flow.add_child(row)
	column.add_child(flow)
	panel.add_child(column)
	return panel


func _build_canvas() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("07100e"), UiTokens.COLOR_BORDER, 4))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	var caption := Label.new()
	caption.text = "ASSEMBLY CANVAS  //  拖放零件并连接匹配的异形接口"
	caption.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	caption.add_theme_font_size_override("font_size", UiTokens.font_size(11))
	column.add_child(caption)
	_assembly_view = ShipAssemblyMapViewScript.new()
	_assembly_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_assembly_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_assembly_view.draft_changed.connect(_on_draft_changed)
	_assembly_view.notice_requested.connect(_on_notice_requested)
	column.add_child(_assembly_view)
	panel.add_child(column)
	_assembly_view.configure(_demo_catalog(), {})
	return panel


func _demo_catalog() -> Dictionary:
	var plans := {}
	var hulls := {}
	for definition in DEMO_SHIPS:
		var ship_id := String(definition.get("id", ""))
		var plan_id := String(definition.get("plan_id", ""))
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
		"slot_labels":{"weapon":"武器", "shield":"护盾", "drive":"引擎", "utility":"功能", "core":"核心"},
		"socket_label_format":"%s %d · %s",
		"module_label_format":"%s · %s · %s",
		"hull_summary_format":"%s · %d sockets",
		"core_socket_format":"能源核心 %d"
	}


func _slot_label(slot: String) -> String:
	return {"weapon":"武器", "shield":"护盾", "drive":"引擎", "utility":"功能", "core":"核心"}.get(slot, slot)


func _port_symbol(slot: String, mount_role: String) -> String:
	if mount_role == "STRUCTURAL":
		return "■ 结构"
	if mount_role == "SPECIAL" and slot == "utility":
		return "⬟ 特殊"
	return {"weapon":"▲ 武器", "shield":"■ 结构", "drive":"◆ 推进", "core":"● 核心"}.get(slot, "■")


func _clear_canvas() -> void:
	_assembly_view.clear_draft()
	_assembly_view.call("_reset_view")
	_status_label.text = "画布已清空，可部署另一艘舰船"


func _on_draft_changed(snapshot: Dictionary) -> void:
	var hull_id := String(snapshot.get("hull_id", ""))
	if hull_id.is_empty():
		_status_label.text = "先拖入舰船，再拖入零件并连接相同形状的接口"
	else:
		var part_count := maxi(0, (snapshot.get("nodes", []) as Array).size() - 1)
		var connection_count := (snapshot.get("connections", []) as Array).size()
		_status_label.text = "%s · 已放置 %d 个零件 · 已连接 %d 个插槽" % [String(_ship_names.get(hull_id, hull_id)), part_count, connection_count]


func _on_notice_requested(code: String) -> void:
	_status_label.text = {
		"HULL_ALREADY_PLACED":"当前画布已有舰船，请先清空再部署另一艘",
		"PORT_DIRECTION_INVALID":"请从零件的实心插头连接到舰体的空心插槽",
		"PORT_SHAPE_MISMATCH":"接口图形或安装类型不匹配，请连接相同图形",
		"PORT_SIZE_MISMATCH":"零件尺寸大于插槽等级，请换用更大的插槽",
		"PORT_ALREADY_OCCUPIED":"这个零件或插槽已经被连接"
	}.get(code, "当前操作无法完成")
