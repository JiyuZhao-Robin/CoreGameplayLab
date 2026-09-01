extends Control

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipAssemblyPaletteItemScript = preload("res://src/ui/components/ship_assembly_palette_item.gd")

const DEMO_SHIPS: Array[Dictionary] = [
	{
		"id":"lunar_pathfinder", "name":"月面开拓者", "english":"LUNAR PATHFINDER", "role":"护卫舰 · 抽象技术投影",
		"length_m":132.0, "beam_m":44.0, "profile":"p01",
		"asset":"res://assets/ships/lunar_pathfinder/base.png",
		"mask":"res://assets/ships/lunar_pathfinder/fx_mask.png",
		"glow":"#62c8cc"
	}
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
	title.text = "舰船抽象投影垂直切片"
	title.add_theme_color_override("font_color", UiTokens.COLOR_TEXT)
	title.add_theme_font_size_override("font_size", UiTokens.font_size(22))
	copy.add_child(title)
	row.add_child(copy)
	_status_label = Label.new()
	_status_label.text = "从左侧拖一张舰船卡片到画布"
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
	panel.custom_minimum_size.x = 326.0
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("08110f"), UiTokens.COLOR_BORDER, 4))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "可部署舰船  /  01"
	title.add_theme_color_override("font_color", UiTokens.COLOR_FOCUS)
	title.add_theme_font_size_override("font_size", UiTokens.font_size(13))
	column.add_child(title)
	var instruction := Label.new()
	instruction.text = "卡片保留档案信息；进入画布后只显示紧贴轮廓的暗色舰体、弱动态光效和现有工程叠层。"
	instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instruction.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	instruction.add_theme_font_size_override("font_size", UiTokens.font_size(10))
	column.add_child(instruction)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var cards := VBoxContainer.new()
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 8)
	for definition in DEMO_SHIPS:
		var ship_id := String(definition.get("id", ""))
		var plan_id := "demo_construct_%s" % ship_id
		_ship_names["demo_%s" % ship_id] = String(definition.get("name", ship_id))
		var card := ShipAssemblyPaletteItemScript.new()
		card.name = "DemoShipCard_%s" % ship_id
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.configure(
			{"ship_assembly_palette":true, "kind":"hull", "plan_id":plan_id, "definition_id":"demo_%s" % ship_id},
			"%s / %s\n%s\nL %.0fm × W %.0fm" % [String(definition.get("name", "")), String(definition.get("english", "")), String(definition.get("role", "")), float(definition.get("length_m", 0.0)), float(definition.get("beam_m", 0.0))],
			true,
			"拖动到右侧部署画布",
			String(definition.get("asset", ""))
		)
		cards.add_child(card)
	scroll.add_child(cards)
	column.add_child(scroll)
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
	caption.text = "DEPLOYMENT CANVAS  //  正交俯视船体预览"
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
		var hull_id := "demo_%s" % ship_id
		var plan_id := "demo_construct_%s" % ship_id
		hulls[hull_id] = {
			"id":hull_id,
			"title":String(definition.get("name", ship_id)),
			"class":String(definition.get("role", "舰船")),
			"allowed_sizes":["XL"],
			"hull_visual":{
				"profile":String(definition.get("profile", "p24")),
				"length_m":float(definition.get("length_m", 320.0)),
				"beam_m":float(definition.get("beam_m", 140.0)),
				"socket_size":"M"
			},
			"ui_visual":{
				"topdown_texture":String(definition.get("asset", "")),
				"fx_mask":String(definition.get("mask", "")),
				"visual_scale":1.0,
				"fx_profile":"frigate_shadow",
				"glow_color":String(definition.get("glow", "#62c8cc")),
				"flow_strength":0.07,
				"flow_speed":0.052,
				"edge_strength":0.09,
				"emission_strength":0.12,
				"scan_strength":0.024,
				"scan_speed":0.0625,
				"halo_strength":0.11,
				"ghost_strength":0.03
			}
		}
		plans[plan_id] = {"id":plan_id, "title":String(definition.get("name", ship_id)), "ship_id":hull_id, "assembly_sockets":[]}
	return {
		"plans":plans,
		"hulls":hulls,
		"modules":{},
		"slot_labels":{},
		"socket_label_format":"%s %d · %s",
		"module_label_format":"%s · %s · %s",
		"hull_summary_format":"%s · %d sockets",
		"core_socket_format":"Energy Core %d"
	}


func _clear_canvas() -> void:
	_assembly_view.clear_draft()
	_assembly_view.call("_reset_view")
	_status_label.text = "画布已清空，可部署另一艘舰船"


func _on_draft_changed(snapshot: Dictionary) -> void:
	var hull_id := String(snapshot.get("hull_id", ""))
	if hull_id.is_empty():
		_status_label.text = "从左侧拖一张舰船卡片到画布"
	else:
		_status_label.text = "%s 已部署 · 可拖动、缩放、适配全图" % String(_ship_names.get(hull_id, hull_id))


func _on_notice_requested(_message: String) -> void:
	_status_label.text = "当前画布已有舰船，请先清空再部署另一艘"
