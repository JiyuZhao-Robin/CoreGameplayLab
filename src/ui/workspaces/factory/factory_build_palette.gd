class_name FactoryBuildPalette
extends PanelContainer

## Bottom-docked, snapshot-driven building browser. It owns presentation filters
## only; choosing a card emits an ID and the workspace remains the sole owner of
## build-mode state and versioned command intents.

signal building_selected(building_id: String)
signal filter_changed(filter_id: String)
signal road_tool_selected(tool_mode: String, tier: int)
signal collapsed_changed(collapsed: bool)

const ThemeTokens = preload("res://src/ui/ui_theme_tokens.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const NAVY := Color("121615")
const RAISED := Color("1b201e")
const BORDER := Color("48514d")
const CYAN := Color("64ddd0")
const OFFWHITE := Color("e7ebe7")
const MUTED := Color("a5afaa")
## The dock stays deliberately short so the world remains the primary surface.
## It can be collapsed by an explicit player action; window size never changes
## the dock's authored state.
const PALETTE_HEIGHT := 104.0
const COLLAPSED_HEIGHT := 32.0
const CARD_WIDTH := 192.0
const CARD_HEIGHT := 66.0

const FILTERS := [
	{"id":"ALL"},
	{"id":"EXTRACTION"},
	{"id":"PRODUCTION"},
	{"id":"LOGISTICS"},
	{"id":"POWER"},
	{"id":"SUPPORT"}
]
const LOGISTICS_STORAGE_IDS := [
	"grid_bulk_depot",
	"grid_component_depot",
	"grid_fluid_tank",
	"grid_special_vault"
]

var _buildings: Array = []
var _building_signature := ""
var _selected_building_id := ""
var _active_filter_id := "ALL"
var _single_building_filter_id := ""
var _available := false
var _built := false
var _collapsed := false
var _filter_group := ButtonGroup.new()
var _filter_buttons: Dictionary = {}
var _building_buttons: Dictionary = {}
var _atlas_texture: Texture2D
var _card_normal_style: StyleBoxFlat
var _card_selected_style: StyleBoxFlat
var _card_hover_style: StyleBoxFlat
var _card_focus_style: StyleBoxFlat

var _title_label: Label
var _count_label: Label
var _more_cards_indicator: Label
var _collapse_button: Button
var _quick_filter: OptionButton
var _cards: HBoxContainer
var _empty_label: Label
var _palette_scroll: ScrollContainer
var _content: HBoxContainer
var _road_tools: HBoxContainer
var _filter_scroll: ScrollContainer
var _header_controls: Array[Control] = []
var _road_tools_enabled := false
var _road_tier_one_button: Button
var _road_tier_two_button: Button
var _road_remove_button: Button
var _road_cost_label: Label


func _ready() -> void:
	ensure_built()


func ensure_built() -> void:
	if _built:
		return
	_built = true
	name = "FactoryBuildPalette"
	custom_minimum_size = Vector2(0, ThemeTokens.layout_px(PALETTE_HEIGHT))
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_stylebox_override("panel", ThemeTokens.panel_style(NAVY, BORDER, 4))
	_card_normal_style = ThemeTokens.control_style(RAISED, BORDER, 3)
	_card_selected_style = ThemeTokens.control_style(Color("293a34"), CYAN, 3)
	_card_hover_style = ThemeTokens.control_style(Color("242b28"), Color("75807a"), 3)
	_card_focus_style = ThemeTokens.control_style(Color("293a34"), CYAN, 3)
	_atlas_texture = BuildingArt.atlas_texture()

	var layout := VBoxContainer.new()
	layout.name = "FactoryBuildPaletteLayout"
	layout.add_theme_constant_override("separation", ThemeTokens.layout_px(5))
	add_child(layout)

	var header := HBoxContainer.new()
	header.name = "BuildPaletteHeader"
	header.custom_minimum_size.y = ThemeTokens.layout_px(26)
	header.add_theme_constant_override("separation", ThemeTokens.layout_px(5))
	layout.add_child(header)

	_title_label = _label(_t("factory.palette.construction", "Construction palette"), OFFWHITE, 13)
	_title_label.name = "BuildPaletteTitle"
	_title_label.custom_minimum_size.x = ThemeTokens.layout_px(116)
	_title_label.tooltip_text = _t("factory.tooltip.building_palette", "Choose a building, then click a free tile to queue construction.")
	_title_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	header.add_child(_title_label)
	_collapse_button = Button.new()
	_collapse_button.name = "FactoryBuildPaletteToggle"
	_collapse_button.custom_minimum_size = ThemeTokens.layout_vector(Vector2(28, 24))
	_collapse_button.tooltip_text = _t("factory.palette.collapse_tooltip", "Collapse or expand the construction dock.")
	_collapse_button.pressed.connect(func() -> void: set_collapsed(not _collapsed))
	header.add_child(_collapse_button)

	_road_tools = HBoxContainer.new()
	_road_tools.name = "FactoryRoadTools"
	_road_tools.add_theme_constant_override("separation", ThemeTokens.layout_px(3))
	_road_tools.visible = false
	header.add_child(_road_tools)
	_road_tier_one_button = _road_button("FactoryRoadTierOne", _t("factory.road.build_tier_one", "Basic road"), _t("factory.road.build_tier_one_tooltip", "Draw a shared local road. Basic roads are free during bootstrap."), "BUILD", 1)
	_road_tools.add_child(_road_tier_one_button)
	_road_tier_two_button = _road_button("FactoryRoadTierTwo", _t("factory.road.build_tier_two", "Reinforced road"), _t("factory.road.build_tier_two_tooltip", "Draw or upgrade a faster shared road. Costs 1 iron ingot per tile."), "BUILD", 2)
	_road_tools.add_child(_road_tier_two_button)
	_road_remove_button = _road_button("FactoryRoadRemove", _t("factory.road.remove", "Remove road"), _t("factory.road.remove_tooltip", "Remove road tiles."), "REMOVE", 1)
	_road_tools.add_child(_road_remove_button)
	_road_cost_label = _label("", MUTED, 10)
	_road_cost_label.name = "FactoryRoadCost"
	_road_cost_label.tooltip_text = _t("factory.road.cost_hint", "Basic roads are free. Reinforced roads cost 1 iron ingot per tile.")
	_road_tools.add_child(_road_cost_label)

	# The category strip owns its overflow. Long localized labels therefore stay
	# reachable without increasing the minimum width of the whole Factory page.
	_filter_scroll = ScrollContainer.new()
	_filter_scroll.name = "BuildPaletteFiltersScroll"
	_filter_scroll.custom_minimum_size.x = ThemeTokens.layout_px(190)
	_filter_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_filter_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	header.add_child(_filter_scroll)
	var filter_row := HBoxContainer.new()
	filter_row.name = "BuildPaletteFilters"
	filter_row.add_theme_constant_override("separation", ThemeTokens.layout_px(4))
	_filter_scroll.add_child(filter_row)
	for filter_value in FILTERS:
		var definition := filter_value as Dictionary
		var filter_id := str(definition.get("id", "ALL"))
		var button := Button.new()
		button.name = "FactoryBuildFilter%s" % filter_id.capitalize()
		button.text = _filter_label(filter_id)
		button.tooltip_text = _t("factory.tooltip.build_filter", "Filter the visible construction cards by building role.")
		button.toggle_mode = true
		button.button_group = _filter_group
		button.button_pressed = filter_id == _active_filter_id
		button.pressed.connect(_set_filter.bind(filter_id))
		filter_row.add_child(button)
		_filter_buttons[filter_id] = button
	_count_label = _label("", MUTED, 11)
	_count_label.name = "BuildPaletteCount"
	# Keep this independent from the filter scroller.  At the 4K command view
	# the old 76px slot cut "visible / total" at the slash, hiding both the real
	# inventory and that more cards existed off-screen.
	_count_label.custom_minimum_size.x = ThemeTokens.layout_px(112)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count_label.clip_text = false
	_count_label.tooltip_text = _t("factory.palette.visible_count_tooltip", "Visible and total buildable buildings")
	header.add_child(_count_label)
	_more_cards_indicator = _label("↔", MUTED, 13)
	_more_cards_indicator.name = "PaletteMoreCardsIndicator"
	_more_cards_indicator.custom_minimum_size.x = ThemeTokens.layout_px(22)
	_more_cards_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_more_cards_indicator.tooltip_text = _t("factory.tooltip.building_palette", "Choose a building, then click a free tile to queue construction.")
	_more_cards_indicator.visible = false
	header.add_child(_more_cards_indicator)
	_quick_filter = OptionButton.new()
	_quick_filter.name = "BuildingPalette"
	_quick_filter.fit_to_longest_item = false
	_quick_filter.custom_minimum_size.x = ThemeTokens.layout_px(186)
	_quick_filter.tooltip_text = _t("factory.tooltip.building_palette", "Choose a building, then click a free tile to queue construction.")
	_quick_filter.item_selected.connect(_on_quick_filter_selected)
	header.add_child(_quick_filter)
	_header_controls = [_road_tools, _filter_scroll, _count_label, _more_cards_indicator, _quick_filter]

	_content = HBoxContainer.new()
	_content.name = "BuildPaletteContent"
	_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", ThemeTokens.layout_px(8))
	layout.add_child(_content)

	_palette_scroll = ScrollContainer.new()
	_palette_scroll.name = "PaletteScroll"
	_palette_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_palette_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_palette_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_palette_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_content.add_child(_palette_scroll)
	_cards = HBoxContainer.new()
	_cards.name = "FactoryPalette"
	_cards.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cards.add_theme_constant_override("separation", ThemeTokens.layout_px(6))
	_palette_scroll.add_child(_cards)
	_empty_label = _label(_t("factory.palette.empty", "No unlocked buildings match this filter."), ThemeTokens.COLOR_TEXT_MUTED, 12)
	_empty_label.name = "BuildPaletteEmpty"
	_empty_label.visible = false
	_cards.add_child(_empty_label)

	resized.connect(_schedule_more_cards_affordance)
	_set_collapsed_visuals()
	_refresh_all()


func set_buildings(buildings: Array, available: bool, selected_building_id: String) -> void:
	ensure_built()
	var availability_changed := _available != available
	var selection_changed := _selected_building_id != selected_building_id
	_available = available
	_selected_building_id = selected_building_id
	var signature_parts: PackedStringArray = []
	for building_value in buildings:
		if not building_value is Dictionary:
			continue
		var building := building_value as Dictionary
		var footprint: Dictionary = building.get("footprint", {}) if building.get("footprint", {}) is Dictionary else {}
		# `available_count` is an authoritative, unreserved Location-inventory
		# projection.  Keep it in the presentation signature so a deployment or
		# a completed manufacturing cycle updates the dock without changing its
		# selected card or requiring an unrelated topology refresh.
		signature_parts.append("%s:%s:%s:%s:%s:%s:%s" % [
			str(building.get("id", "")),
			str(building.get("name", "")),
			str(building.get("kind", "")),
			str(footprint.get("width", footprint.get("x", 1))),
			str(footprint.get("height", footprint.get("y", 1))),
			str(building.get("deployment_item_id", "")),
			str(maxi(0, int(building.get("available_count", 0))))
		])
	var next_signature := "|".join(signature_parts)
	if next_signature != _building_signature:
		_building_signature = next_signature
		_buildings = buildings.duplicate(false)
		if not _single_building_filter_id.is_empty() and not _has_building(_single_building_filter_id):
			_single_building_filter_id = ""
		_rebuild_quick_filter()
		_rebuild_cards()
	elif selection_changed:
		_sync_selection_state()
	if availability_changed:
		_sync_available_state()
	_refresh_header()


func set_selected_building(building_id: String) -> void:
	ensure_built()
	if _selected_building_id == building_id:
		return
	_selected_building_id = building_id
	_sync_selection_state()
	_refresh_header()


func set_road_tools_enabled(enabled: bool, active_tool: String = "", tier: int = 1, available: bool = true) -> void:
	ensure_built()
	if not is_instance_valid(_road_tools):
		return
	_road_tools_enabled = enabled
	_road_tools.visible = enabled and not _collapsed
	var normalized := active_tool.to_upper()
	var selected_tier := clampi(tier, 1, 2)
	_road_tier_one_button.disabled = not available
	_road_tier_two_button.disabled = not available
	_road_remove_button.disabled = not available
	_road_tier_one_button.set_pressed_no_signal(normalized == "BUILD" and selected_tier == 1)
	_road_tier_two_button.set_pressed_no_signal(normalized == "BUILD" and selected_tier == 2)
	_road_remove_button.set_pressed_no_signal(normalized == "REMOVE")
	if normalized == "BUILD" and selected_tier == 2:
		_road_cost_label.text = _t("factory.road.cost_tier_two", "1 iron ingot / tile")
	else:
		_road_cost_label.text = _t("factory.road.cost_tier_one", "Basic road · free")


func show_building(building_id: String, isolate: bool = false) -> void:
	ensure_built()
	_selected_building_id = building_id
	if isolate:
		_active_filter_id = "ALL"
		_single_building_filter_id = building_id
		_select_quick_filter_metadata(building_id)
	else:
		_single_building_filter_id = ""
		_select_quick_filter_metadata("")
	_rebuild_cards()


func quick_filter() -> OptionButton:
	ensure_built()
	return _quick_filter


func visible_building_ids() -> Array[String]:
	var result: Array[String] = []
	for building_value in _filtered_buildings():
		result.append(str((building_value as Dictionary).get("id", "")))
	return result


func active_filter_id() -> String:
	return _active_filter_id


func is_collapsed() -> bool:
	return _collapsed


func set_collapsed(collapsed: bool) -> void:
	ensure_built()
	if _collapsed == collapsed:
		return
	_collapsed = collapsed
	_set_collapsed_visuals()
	update_minimum_size()
	var parent_container := get_parent() as Container
	if parent_container != null:
		parent_container.queue_sort()
	collapsed_changed.emit(_collapsed)


func _set_collapsed_visuals() -> void:
	if not is_instance_valid(_collapse_button):
		return
	custom_minimum_size.y = ThemeTokens.layout_px(COLLAPSED_HEIGHT if _collapsed else PALETTE_HEIGHT)
	_collapse_button.text = "▾" if _collapsed else "▴"
	_collapse_button.tooltip_text = _t("factory.palette.expand_tooltip", "Expand the construction dock.") if _collapsed else _t("factory.palette.collapse_tooltip", "Collapse the construction dock.")
	if is_instance_valid(_content):
		_content.visible = not _collapsed
	for control in _header_controls:
		if control == _road_tools:
			# Road tools preserve their logical availability while the player has
			# deliberately collapsed the dock.
			control.visible = not _collapsed and _road_tools_enabled
		else:
			control.visible = not _collapsed
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL if _collapsed else Control.SIZE_SHRINK_BEGIN


func _set_filter(filter_id: String) -> void:
	_active_filter_id = filter_id if not _filter_definition(filter_id).is_empty() else "ALL"
	_single_building_filter_id = ""
	_select_quick_filter_metadata("")
	_rebuild_cards()
	filter_changed.emit(_active_filter_id)


func _on_quick_filter_selected(index: int) -> void:
	var building_id := str(_quick_filter.get_item_metadata(index))
	# The picker is an explicit one-building filter. Reset the role filter first
	# so selecting a machine after browsing Power cannot produce an empty
	# intersection while silently entering BUILD mode.
	_active_filter_id = "ALL"
	_single_building_filter_id = building_id
	if not building_id.is_empty():
		_selected_building_id = building_id
	_rebuild_cards()
	if not building_id.is_empty():
		building_selected.emit(building_id)


func _on_building_card_pressed(building_id: String) -> void:
	_selected_building_id = building_id
	_sync_selection_state()
	building_selected.emit(building_id)


func _rebuild_quick_filter() -> void:
	_quick_filter.clear()
	_quick_filter.add_item(_t("factory.palette.all_buildings", "All buildings"))
	_quick_filter.set_item_metadata(0, "")
	var selected_index := 0
	for building_value in _buildings:
		if not building_value is Dictionary:
			continue
		var building := building_value as Dictionary
		var building_id := str(building.get("id", ""))
		_quick_filter.add_item(str(building.get("name", building_id)))
		var index := _quick_filter.item_count - 1
		_quick_filter.set_item_metadata(index, building_id)
		if building_id == _single_building_filter_id:
			selected_index = index
	_quick_filter.select(selected_index)
	_quick_filter.disabled = not _available


func _rebuild_cards() -> void:
	for child in _cards.get_children():
		if child == _empty_label:
			continue
		_cards.remove_child(child)
		child.queue_free()
	_building_buttons.clear()
	var visible_buildings := _filtered_buildings()
	_empty_label.visible = visible_buildings.is_empty()
	for building_value in visible_buildings:
		var building := building_value as Dictionary
		var building_id := str(building.get("id", ""))
		# A fixed slot keeps the dock's authored rhythm.  The card's real labels
		# wrap inside it instead of clipping or ellipsizing a primary build action.
		var card_slot := Control.new()
		card_slot.name = "FactoryBuildCardSlot%s" % building_id.to_pascal_case()
		card_slot.custom_minimum_size = ThemeTokens.layout_vector(Vector2(CARD_WIDTH, CARD_HEIGHT))
		card_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		var button := Button.new()
		button.name = "FactoryBuildCard%s" % building_id.to_pascal_case()
		button.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		button.toggle_mode = true
		button.button_pressed = building_id == _selected_building_id
		button.disabled = not _available
		button.text = ""
		button.accessibility_name = "%s · %s" % [str(building.get("name", building_id)), _building_card_detail(building)]
		button.clip_text = false
		button.tooltip_text = _building_tooltip(building)
		button.set_meta("building_id", building_id)
		button.set_meta("deployment_item_id", _deployment_item_id(building))
		button.set_meta("available_count", _available_count(building))
		_apply_card_style(button, building_id == _selected_building_id)
		button.pressed.connect(_on_building_card_pressed.bind(building_id))
		var card_content := MarginContainer.new()
		card_content.name = "FactoryBuildCardContent"
		card_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		card_content.add_theme_constant_override("margin_left", ThemeTokens.layout_px(6))
		card_content.add_theme_constant_override("margin_right", ThemeTokens.layout_px(6))
		card_content.add_theme_constant_override("margin_top", ThemeTokens.layout_px(4))
		card_content.add_theme_constant_override("margin_bottom", ThemeTokens.layout_px(4))
		button.add_child(card_content)
		var card_row := HBoxContainer.new()
		card_row.add_theme_constant_override("separation", ThemeTokens.layout_px(6))
		card_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card_content.add_child(card_row)
		var icon := TextureRect.new()
		icon.name = "FactoryBuildCardIcon"
		icon.texture = _building_icon(building)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.custom_minimum_size = ThemeTokens.layout_vector(Vector2(42, 42))
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card_row.add_child(icon)
		var labels := VBoxContainer.new()
		labels.name = "FactoryBuildCardLabels"
		labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card_row.add_child(labels)
		var name_label := _label(str(building.get("name", building_id)), OFFWHITE, 11)
		name_label.name = "FactoryBuildCardName"
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_label.clip_text = false
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_child(name_label)
		var detail_label := _label(_building_card_detail(building), MUTED, 10)
		detail_label.name = "FactoryBuildCardDetail"
		detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail_label.clip_text = false
		detail_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		labels.add_child(detail_label)
		card_slot.add_child(button)
		_cards.add_child(card_slot)
		_building_buttons[building_id] = button
	_refresh_header()


func _filtered_buildings() -> Array:
	var result: Array = []
	for building_value in _buildings:
		if not building_value is Dictionary:
			continue
		var building := building_value as Dictionary
		var building_id := str(building.get("id", ""))
		if not _single_building_filter_id.is_empty() and building_id != _single_building_filter_id:
			continue
		if not _building_matches_filter(building, _active_filter_id):
			continue
		result.append(building)
	return result


func _sync_selection_state() -> void:
	for building_id_value in _building_buttons.keys():
		var building_id := str(building_id_value)
		var button: Button = _building_buttons.get(building_id) as Button
		if button == null:
			continue
		var selected := building_id == _selected_building_id
		if button.button_pressed != selected:
			button.set_pressed_no_signal(selected)
			_apply_card_style(button, selected)
		elif selected:
			# A toggle button changes its pressed state before emitting `pressed`.
			# Reapply the persistent selected normal style in that path too.
			_apply_card_style(button, true)


func _sync_available_state() -> void:
	if is_instance_valid(_quick_filter):
		_quick_filter.disabled = not _available
	for button_value in _building_buttons.values():
		var button := button_value as Button
		if button != null:
			button.disabled = not _available


func _refresh_header() -> void:
	if not is_instance_valid(_count_label):
		return
	var visible_count := _filtered_buildings().size()
	_count_label.text = _t("factory.palette.visible_count", "%d / %d buildable") % [visible_count, _buildings.size()]
	for filter_id_value in _filter_buttons.keys():
		var button: Button = _filter_buttons.get(filter_id_value) as Button
		if button != null:
			button.set_pressed_no_signal(str(filter_id_value) == _active_filter_id)
	_schedule_more_cards_affordance()


func _schedule_more_cards_affordance() -> void:
	if is_instance_valid(_palette_scroll) and is_instance_valid(_more_cards_indicator):
		call_deferred("_refresh_more_cards_affordance")


func _refresh_more_cards_affordance() -> void:
	if not is_instance_valid(_palette_scroll) or not is_instance_valid(_more_cards_indicator):
		return
	var scrollbar := _palette_scroll.get_h_scroll_bar()
	_more_cards_indicator.visible = scrollbar != null and scrollbar.max_value > 0.5


func _refresh_all() -> void:
	_rebuild_quick_filter()
	_rebuild_cards()


func _filter_definition(filter_id: String) -> Dictionary:
	for definition_value in FILTERS:
		var definition := definition_value as Dictionary
		if str(definition.get("id", "")) == filter_id:
			return definition
	return {}


func _building_matches_filter(building: Dictionary, filter_id: String) -> bool:
	var kind := str(building.get("kind", "")).to_upper()
	var building_id := str(building.get("id", ""))
	match filter_id:
		"ALL": return true
		"EXTRACTION": return kind == "EXTRACTOR"
		"PRODUCTION": return kind == "MACHINE"
		"LOGISTICS": return kind == "ROUTER" or LOGISTICS_STORAGE_IDS.has(building_id)
		"POWER": return kind == "POWER"
		"SUPPORT": return kind == "CONSTRUCTION" or (kind == "STORAGE" and not LOGISTICS_STORAGE_IDS.has(building_id))
	return true


func _has_building(building_id: String) -> bool:
	for building_value in _buildings:
		if building_value is Dictionary and str((building_value as Dictionary).get("id", "")) == building_id:
			return true
	return false


func _filter_label(filter_id: String) -> String:
	return _t("factory.palette.filter.%s" % filter_id.to_lower(), filter_id.replace("_", " ").capitalize())


func _building_card_detail(building: Dictionary) -> String:
	var footprint: Dictionary = building.get("footprint", {}) if building.get("footprint", {}) is Dictionary else {}
	var width := int(footprint.get("width", footprint.get("x", 1)))
	var height := int(footprint.get("height", footprint.get("y", 1)))
	return "%d × %d  ·  %s %d" % [
		width,
		height,
		_t("factory.building.available_short", "Available"),
		_available_count(building)
	]


func _building_tooltip(building: Dictionary) -> String:
	var kind := str(building.get("kind", "UNKNOWN"))
	var power_generation := float(building.get("power_generation_kw", 0.0))
	var power_demand := float(building.get("power_demand_kw", 0.0))
	var power_text := "+%.0f kW" % power_generation if power_generation > 0.0 else "-%.0f kW" % power_demand
	var available_count := _available_count(building)
	var deployment_hint := _t("factory.building.deploy_available_hint", "Deploys one finished building from planet inventory.") if available_count > 0 else _t("factory.building.deploy_missing_hint", "No finished building available. Placement creates a ghost that deploys automatically when one arrives.")
	return "%s · %s\n%s · %s\n%s\n%s" % [
		str(building.get("name", building.get("id", ""))),
		_t("factory.kind.%s" % kind.to_lower(), kind.capitalize()),
		power_text,
		_t("factory.building.available", "Available: %d") % available_count,
		deployment_hint,
		_t("factory.palette.card_action", "Select for continuous placement")
	]


func _deployment_item_id(building: Dictionary) -> String:
	var item_id := str(building.get("deployment_item_id", ""))
	return item_id if not item_id.is_empty() else "building_" + str(building.get("id", ""))


func _available_count(building: Dictionary) -> int:
	return maxi(0, int(building.get("available_count", 0)))


func _building_icon(building: Dictionary) -> Texture2D:
	return BuildingArt.icon_texture(_atlas_texture, str(building.get("id", "")), str(building.get("kind", "")))


func _apply_card_style(button: Button, selected: bool) -> void:
	button.add_theme_stylebox_override("normal", _card_selected_style if selected else _card_normal_style)
	button.add_theme_stylebox_override("hover", _card_hover_style)
	button.add_theme_stylebox_override("pressed", _card_selected_style)
	button.add_theme_stylebox_override("focus", _card_focus_style)


func _select_quick_filter_metadata(value: String) -> void:
	if not is_instance_valid(_quick_filter):
		return
	for index in _quick_filter.item_count:
		if str(_quick_filter.get_item_metadata(index)) == value:
			_quick_filter.select(index)
			return
	_quick_filter.select(0)


func _road_button(node_name: String, label: String, tooltip: String, tool_mode: String, tier: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = label
	button.tooltip_text = tooltip
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", ThemeTokens.font_size(10))
	button.pressed.connect(func() -> void: road_tool_selected.emit(tool_mode, tier))
	return button


func _label(text_value: String, color: Color, font_size: int) -> Label:
	var result := Label.new()
	result.text = text_value
	result.add_theme_color_override("font_color", color)
	result.add_theme_font_size_override("font_size", ThemeTokens.font_size(font_size))
	return result


func _t(key: String, fallback: String) -> String:
	var i18n := get_node_or_null("/root/I18n")
	return str(i18n.call("t", key, fallback)) if i18n != null else fallback
