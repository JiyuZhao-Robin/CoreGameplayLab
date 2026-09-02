class_name ShipAssemblyLibrary
extends PanelContainer

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipAssemblyPaletteItemScript = preload("res://src/ui/components/ship_assembly_palette_item.gd")

signal entity_selected(kind: String, entity_id: String)

const CATEGORY_ORDER: Array[String] = ["ALL", "PROPULSION", "WEAPON", "DEFENSE", "CORE", "UTILITY", "LOGISTICS"]

var _catalog: Dictionary = {}
var _ship_entries: Array[Dictionary] = []
var _module_ids: Array[String] = []
var _tabs: TabContainer
var _search: LineEdit
var _category: OptionButton
var _module_cards: VBoxContainer
var _empty_modules: Label


func _ready() -> void:
	name = "ShipAssemblyLibrary"
	custom_minimum_size.x = 300.0
	add_theme_stylebox_override("panel", UiTokens.panel_style(Color("0b1716"), UiTokens.COLOR_BORDER, 4))
	_build_frame()


func configure(catalog: Dictionary, ship_entries: Array[Dictionary], module_ids: Array[String]) -> void:
	_catalog = catalog.duplicate(true)
	_ship_entries = ship_entries.duplicate(true)
	_module_ids = module_ids.duplicate()
	if is_node_ready():
		_rebuild_ship_cards()
		_rebuild_module_cards()


func select_tab(tab_index: int) -> void:
	if is_instance_valid(_tabs):
		_tabs.current_tab = clampi(tab_index, 0, 1)


func current_tab() -> int:
	return _tabs.current_tab if is_instance_valid(_tabs) else 0


func _build_frame() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	var eyebrow := _label("DESIGN ASSETS  /  设计资源", 9, UiTokens.COLOR_FOCUS)
	eyebrow.name = "AssemblyLibraryEyebrow"
	column.add_child(eyebrow)
	var hint := _label("把舰体和模块拖入中央蓝图。选择条目可在右侧查看工程信息。", 9, UiTokens.COLOR_TEXT_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	_tabs = TabContainer.new()
	_tabs.name = "AssemblyLibraryTabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(11))
	column.add_child(_tabs)
	_tabs.add_child(_build_ships_tab())
	_tabs.add_child(_build_modules_tab())
	# At accessibility sizes the bilingual labels made two tabs wider than the
	# complete asset rail. Chinese is primary in this locale; the English meaning
	# remains available in the panel heading and tooltips.
	_tabs.set_tab_title(0, "舰船")
	_tabs.set_tab_title(1, "零件")
	_rebuild_ship_cards()
	_rebuild_module_cards()


func _build_ships_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.name = "舰船"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var cards := VBoxContainer.new()
	cards.name = "AssemblyShipCards"
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards.add_theme_constant_override("separation", 8)
	scroll.add_child(cards)
	return scroll


func _build_modules_tab() -> Control:
	var column := VBoxContainer.new()
	column.name = "零件"
	column.add_theme_constant_override("separation", 8)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	_search = LineEdit.new()
	_search.name = "AssemblyModuleSearch"
	_search.placeholder_text = "搜索零件"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(9))
	_search.text_changed.connect(func(_value: String): _rebuild_module_cards())
	tools.add_child(_search)
	_category = OptionButton.new()
	_category.name = "AssemblyModuleCategory"
	_category.custom_minimum_size.x = 92.0
	for category_name in CATEGORY_ORDER:
		_category.add_item(_category_filter_label(category_name))
	_category.item_selected.connect(func(_index: int): _rebuild_module_cards())
	tools.add_child(_category)
	column.add_child(tools)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_module_cards = VBoxContainer.new()
	_module_cards.name = "AssemblyModuleCards"
	_module_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_module_cards.add_theme_constant_override("separation", 8)
	scroll.add_child(_module_cards)
	column.add_child(scroll)
	_empty_modules = _label("没有符合筛选条件的零件。", 9, UiTokens.COLOR_TEXT_MUTED)
	_empty_modules.name = "AssemblyModuleEmptyState"
	_empty_modules.visible = false
	column.add_child(_empty_modules)
	return column


func _rebuild_ship_cards() -> void:
	var cards := find_child("AssemblyShipCards", true, false) as VBoxContainer
	if cards == null:
		return
	_clear_children(cards)
	for entry_value in _ship_entries:
		var entry := entry_value as Dictionary
		var ship_id := str(entry.get("id", ""))
		var plan_id := str(entry.get("plan_id", ""))
		var hull := _catalog.get("hulls", {}).get(ship_id, {}) as Dictionary
		if hull.is_empty():
			continue
		var visual := hull.get("hull_visual", {}) as Dictionary
		var ui_visual := hull.get("ui_visual", {}) as Dictionary
		var card := ShipAssemblyPaletteItemScript.new()
		card.name = "AssemblyShipCard_%s" % ship_id
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.configure(
			{"ship_assembly_palette":true, "kind":"hull", "plan_id":plan_id, "definition_id":ship_id},
			"%s\n%s · %.0fm\n%d SLOTS" % [I18n.content(hull), str(hull.get("class", "SHIP")).to_upper(), float(visual.get("length_m", 0.0)), int(hull.get("module_slots", 0))],
			bool(entry.get("available", true)),
			"拖动舰体到装配画布",
			str(ui_visual.get("topdown_texture", ""))
		)
		card.custom_minimum_size = Vector2(266.0, 140.0)
		card.pressed.connect(_on_card_pressed.bind("hull", ship_id))
		cards.add_child(card)


func _rebuild_module_cards() -> void:
	if _module_cards == null:
		return
	_clear_children(_module_cards)
	var query := _search.text.strip_edges().to_lower() if is_instance_valid(_search) else ""
	var category_name := CATEGORY_ORDER[_category.selected] if is_instance_valid(_category) and _category.selected >= 0 else "ALL"
	var visible_count := 0
	for module_id in _module_ids:
		var module := _catalog.get("modules", {}).get(module_id, {}) as Dictionary
		if module.is_empty() or bool(module.get("retired", false)):
			continue
		var module_category := _module_category(module_id, module)
		var searchable := "%s %s %s" % [module_id, I18n.content(module), _category_label(module_category)]
		if not query.is_empty() and searchable.to_lower().find(query) < 0:
			continue
		if category_name != "ALL" and module_category != category_name:
			continue
		var slot := str(module.get("slot", "utility"))
		var mount_role := str(module.get("assembly_mount", "SPECIAL"))
		var size_id := str(module.get("size", "S"))
		var tier := int({"S":1, "M":2, "L":3, "XL":4, "XXL":5}.get(size_id, 1))
		var diameter := float({"S":5.0, "M":11.0, "L":22.0, "XL":44.0, "XXL":88.0}.get(size_id, 5.0))
		var card := ShipAssemblyPaletteItemScript.new()
		card.name = "AssemblyModuleCard_%s" % module_id
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.configure(
			{"ship_assembly_palette":true, "kind":"module", "definition_id":module_id, "slot":slot, "mount_role":mount_role},
			"%s\n%s\n%s · T%d · Ø%.0fm" % [I18n.content(module), _category_filter_label(module_category), size_id, tier, diameter],
			true,
			"拖入画布，并连接到同一功能族的舰体插槽",
			ShipAssemblyMapViewScript.module_icon_path(module)
		)
		card.custom_minimum_size = Vector2(266.0, 132.0)
		card.pressed.connect(_on_card_pressed.bind("module", module_id))
		_module_cards.add_child(card)
		visible_count += 1
	_empty_modules.visible = visible_count == 0


func _module_category(module_id: String, module: Dictionary) -> String:
	var slot := str(module.get("slot", "utility"))
	var mount_role := str(module.get("assembly_mount", ""))
	match slot:
		"drive": return "PROPULSION"
		"weapon": return "WEAPON"
		"shield": return "DEFENSE"
		"core": return "CORE"
		"utility": return "LOGISTICS" if mount_role == "STRUCTURAL" or module_id in ["cargo_expansion", "bulk_freight_array", "cryogenic_hold_system"] else "UTILITY"
		_: return "UTILITY"


func _category_label(category_name: String) -> String:
	return {
		"ALL":"全部 / ALL",
		"PROPULSION":"推进 / PROPULSION",
		"WEAPON":"武器 / WEAPON",
		"DEFENSE":"防御 / DEFENSE",
		"CORE":"核心 / CORE",
		"UTILITY":"功能 / UTILITY",
		"LOGISTICS":"结构 / LOGISTICS"
	}.get(category_name, category_name)


func _category_filter_label(category_name: String) -> String:
	return {
		"ALL":"全部",
		"PROPULSION":"推进",
		"WEAPON":"武器",
		"DEFENSE":"防御",
		"CORE":"核心",
		"UTILITY":"功能",
		"LOGISTICS":"结构"
	}.get(category_name, category_name)


func _on_card_pressed(kind: String, entity_id: String) -> void:
	entity_selected.emit(kind, entity_id)


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(font_size))
	label.add_theme_color_override("font_color", color)
	return label
