class_name ShipAssemblyDataPanel
extends PanelContainer

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ShipAssemblyMapViewScript = preload("res://src/ui/components/ship_assembly_map_view.gd")
const ShipModuleInspectorScript = preload("res://src/ui/components/ship_module_inspector.gd")

signal save_requested()
signal blueprint_name_changed(value: String)

var _context: Dictionary = {}
var _content: VBoxContainer
var _name_edit: LineEdit
var _save_button: Button
var _save_status_label: Label


func _ready() -> void:
	name = "ShipAssemblyDataPanel"
	custom_minimum_size.x = 270.0
	add_theme_stylebox_override("panel", UiTokens.panel_style(Color("0b1716"), UiTokens.COLOR_BORDER, 4))
	_build_frame()


func configure(context: Dictionary) -> void:
	_context = context.duplicate(true)
	if is_node_ready():
		_rebuild()


func show_blueprint_summary() -> void:
	_context["selection_kind"] = ""
	_context["selection_id"] = ""
	_rebuild()


func save_enabled() -> bool:
	return is_instance_valid(_save_button) and not _save_button.disabled


func _build_frame() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	var header_margin := MarginContainer.new()
	header_margin.add_theme_constant_override("margin_left", 12)
	header_margin.add_theme_constant_override("margin_top", 12)
	header_margin.add_theme_constant_override("margin_right", 12)
	root.add_child(header_margin)
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 3)
	var header_title := _label(I18n.core("ships.assembly.engineering_data", "ENGINEERING DATA"), 9, UiTokens.COLOR_FOCUS)
	header_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_child(header_title)
	var subtitle := _label(I18n.core("ships.assembly.engineering_subtitle", "Blueprint, selection, and shipyard handoff data"), 8, UiTokens.COLOR_TEXT_MUTED)
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_child(subtitle)
	header_margin.add_child(header)
	var scroll := ScrollContainer.new()
	scroll.name = "AssemblyDataScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	var content_margin := MarginContainer.new()
	content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_margin.add_theme_constant_override("margin_left", 12)
	content_margin.add_theme_constant_override("margin_right", 12)
	scroll.add_child(content_margin)
	_content = VBoxContainer.new()
	_content.name = "AssemblyDataContent"
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	content_margin.add_child(_content)
	root.add_child(HSeparator.new())
	root.add_child(_build_footer())
	_rebuild()


func _build_footer() -> Control:
	var margin := MarginContainer.new()
	margin.name = "AssemblySaveRegion"
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	var name_label := _label(I18n.core("ships.assembly.current_blueprint", "CURRENT BLUEPRINT"), 8, UiTokens.COLOR_TEXT_MUTED)
	column.add_child(name_label)
	_name_edit = LineEdit.new()
	_name_edit.name = "BlueprintNameEdit"
	_name_edit.placeholder_text = I18n.core("ships.assembly.default_blueprint_name", "Escort Configuration A")
	_name_edit.max_length = 48
	_name_edit.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(9))
	_name_edit.text_changed.connect(func(value: String): blueprint_name_changed.emit(value))
	column.add_child(_name_edit)
	_save_status_label = _label(I18n.core("ships.assembly.awaiting_complete", "◇ Awaiting complete blueprint"), 7, UiTokens.COLOR_WARNING)
	_save_status_label.name = "BlueprintSaveStatus"
	_save_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_save_status_label)
	_save_button = Button.new()
	_save_button.name = "SaveBlueprintButton"
	_save_button.text = I18n.core("ships.assembly.save_blueprint", "SAVE BLUEPRINT")
	_save_button.custom_minimum_size.y = 72.0
	_save_button.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(10))
	var normal := UiTokens.control_style(Color("17302d"), UiTokens.COLOR_FOCUS.darkened(0.16), 3)
	var hover := UiTokens.control_style(Color("1d4540"), UiTokens.COLOR_FOCUS, 3)
	hover.set_border_width_all(2)
	_save_button.add_theme_stylebox_override("normal", normal)
	_save_button.add_theme_stylebox_override("hover", hover)
	_save_button.add_theme_stylebox_override("pressed", hover)
	_save_button.pressed.connect(func(): save_requested.emit())
	column.add_child(_save_button)
	margin.add_child(column)
	return margin


func _rebuild() -> void:
	if _content == null:
		return
	_clear_children(_content)
	var selection_kind := str(_context.get("selection_kind", ""))
	var selection_id := str(_context.get("selection_id", ""))
	if selection_kind == "module" and not selection_id.is_empty():
		_build_module_inspector(selection_id)
	elif selection_kind == "hull" and not selection_id.is_empty():
		_build_hull_inspector(selection_id)
	else:
		_build_blueprint_overview()
	if is_instance_valid(_name_edit):
		_name_edit.set_block_signals(true)
		_name_edit.text = str(_context.get("blueprint_name", ""))
		_name_edit.set_block_signals(false)
	var validation := _context.get("validation", {}) as Dictionary
	if is_instance_valid(_save_button):
		var allowed := bool(validation.get("allowed", false))
		_save_button.disabled = not allowed
		_save_button.tooltip_text = str(validation.get("reason", ""))
		_save_status_label.text = I18n.core("ships.assembly.ready_to_save", "● Blueprint ready to save") if allowed else I18n.core("ships.assembly.validation_status", "◇ %s") % _validation_reason_text(str(validation.get("reason_code", "")), str(validation.get("reason", I18n.core("ships.assembly.incomplete", "Blueprint is incomplete"))))
		_save_status_label.add_theme_color_override("font_color", UiTokens.COLOR_RUNNING if allowed else UiTokens.COLOR_WARNING)


func _build_blueprint_overview() -> void:
	var summary := _context.get("summary", {}) as Dictionary
	var validation := _context.get("validation", {}) as Dictionary
	var hull := _context.get("hull", {}) as Dictionary
	var status_section := _section(I18n.core("ships.assembly.blueprint_status", "BLUEPRINT STATUS"))
	var allowed := bool(validation.get("allowed", false))
	status_section.add_child(_status_row(I18n.core("ships.assembly.valid", "Blueprint valid") if allowed else I18n.core("ships.assembly.incomplete", "Blueprint incomplete"), allowed, str(validation.get("reason", I18n.core("ships.assembly.awaiting_hull", "Awaiting hull placement")))))
	_content.add_child(status_section)
	var engineering := summary.get("engineering", {}) as Dictionary
	var connection_overview := summary.get("connection_overview", {}) as Dictionary
	var usage := connection_overview.get("usage", {}) as Dictionary
	var capacity := connection_overview.get("capacity", {}) as Dictionary
	var connections := _section(I18n.core("ships.assembly.connection_overview", "CONNECTION OVERVIEW"))
	for slot in ["weapon", "drive", "structure", "core", "utility"]:
		if int(capacity.get(slot, 0)) <= 0:
			continue
		connections.add_child(_value_row(_slot_label(slot), I18n.core("ships.assembly.format.count_ratio", "%d / %d") % [int(usage.get(slot, 0)), int(capacity.get(slot, 0))], _slot_tone(slot)))
	_content.add_child(connections)
	var blueprint := _section(I18n.core("ships.assembly.blueprint_summary", "BLUEPRINT SUMMARY"))
	blueprint.add_child(_value_row(I18n.core("ships.assembly.hull", "Hull"), I18n.content(hull) if not hull.is_empty() else "—"))
	blueprint.add_child(_value_row(I18n.core("ships.assembly.modules", "Modules"), str(int(summary.get("module_count", 0)))))
	blueprint.add_child(_value_row(I18n.core("ships.assembly.connected", "Connected"), I18n.core("ships.assembly.format.count_ratio", "%d / %d") % [int(summary.get("connected_count", 0)), int(summary.get("module_count", 0))]))
	var totals := engineering.get("totals", {}) as Dictionary
	blueprint.add_child(_value_row(I18n.core("ships.assembly.total_mass", "Total Mass"), I18n.core("ships.assembly.format.mass", "%.1f t") % float(totals.get("mass", 0.0))))
	blueprint.add_child(_value_row(I18n.core("ships.assembly.power_demand", "Power Demand"), I18n.core("ships.assembly.format.power", "%.1f MW") % float(totals.get("power", 0.0))))
	blueprint.add_child(_value_row(I18n.core("ships.assembly.heat_load", "Heat Load"), I18n.core("ships.assembly.format.heat", "%.1f TU") % float(totals.get("thermal", 0.0))))
	_content.add_child(blueprint)
	var capacities := engineering.get("capacities", {}) as Dictionary
	if not capacities.is_empty():
		var stats := _section(I18n.core("ships.assembly.ship_stats", "SHIP STATS"))
		stats.add_child(_capacity_row("MASS", float(totals.get("mass", 0.0)), float(capacities.get("mass", 0.0)), UiTokens.COLOR_INFORMATION))
		stats.add_child(_capacity_row("POWER", float(totals.get("power", 0.0)), float(capacities.get("power", 0.0)), UiTokens.COLOR_WARNING))
		stats.add_child(_capacity_row("HEAT", float(totals.get("thermal", 0.0)), float(capacities.get("thermal", 0.0)), UiTokens.COLOR_CRITICAL))
		_content.add_child(stats)
	if not summary.is_empty():
		var estimate := _section(I18n.core("ships.assembly.build_estimate", "BUILD ESTIMATE"))
		estimate.add_child(_detail_block(I18n.core("ships.assembly.build_materials", "Build Materials"), _cost_text(summary.get("construction_costs", {}) as Dictionary)))
		estimate.add_child(_value_row(I18n.core("ships.assembly.build_time", "Build Time"), _time_text(float(summary.get("estimated_build_time_ms", 0.0)))))
		estimate.add_child(_detail_block(I18n.core("ships.assembly.refit_materials", "Refit Materials"), _cost_text(summary.get("refit_costs", {}) as Dictionary)))
		estimate.add_child(_value_row(I18n.core("ships.assembly.refit_time", "Refit Time"), _time_text(float(summary.get("estimated_refit_time_ms", 0.0)))))
		_content.add_child(estimate)
		var requirements := _section(I18n.core("ships.assembly.requirements", "REQUIREMENTS & COMPATIBILITY"))
		var handoff_mode := str(summary.get("handoff_mode", "BUILD_HULL"))
		var matching_count := (summary.get("matching_refit_ship_ids", []) as Array).size()
		var plan_unlocked := bool(summary.get("plan_unlocked", false))
		var handoff_text := I18n.core("ships.assembly.handoff_locked", "Hull plan locked. The blueprint can still be saved and edited, but cannot enter the shipyard yet.")
		if plan_unlocked:
			handoff_text = (I18n.core("ships.assembly.handoff_refit", "%d matching physical hulls are available for a shipyard refit order.") % matching_count) if handoff_mode == "REFIT" else I18n.core("ships.assembly.handoff_build", "No matching hull is available. Build the hull first, then assemble this blueprint.")
		var handoff := _label(handoff_text, 8, UiTokens.COLOR_TEXT_SECONDARY)
		handoff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		requirements.add_child(handoff)
		var semantic := _label(I18n.core("ships.assembly.save_semantics", "Saving records design intent only; it consumes no materials and does not modify a physical ship."), 8, UiTokens.COLOR_TEXT_MUTED)
		semantic.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		requirements.add_child(semantic)
		_content.add_child(requirements)


func _build_module_inspector(module_id: String) -> void:
	var module := Game.content.modules.get(module_id, {}) as Dictionary
	if module.is_empty():
		_build_blueprint_overview()
		return
	var slot := str(module.get("slot", "utility"))
	var mount_role := Game.ship_module_mount_role(module_id)
	var size_id := str(module.get("size", "S"))
	var tier := int({"S":1, "M":2, "L":3, "XL":4, "XXL":5}.get(size_id, 1))
	_content.add_child(_view_heading(I18n.core("ships.assembly.module_inspector", "MODULE INSPECTOR"), I18n.core("ships.assembly.back_to_summary", "Back to summary"), show_blueprint_summary))
	var inspector := ShipModuleInspectorScript.new()
	inspector.name = "AssemblyModuleInspector"
	inspector.configure(module, {
		"display_name":I18n.content(module),
		"family_label":_slot_label("structure") if mount_role == "STRUCTURAL" else _slot_label(slot),
		"tier_label":"T%d" % tier,
		"installation_state":"BLUEPRINT",
		"diameter_label":"Ø%.0fm" % float({"S":5.0, "M":11.0, "L":22.0, "XL":44.0, "XXL":88.0}.get(size_id, 5.0)),
		"mount_role":mount_role,
		"tone":_slot_tone("structure") if mount_role == "STRUCTURAL" else _slot_tone(slot),
		"art_path":ShipAssemblyMapViewScript.module_icon_path(module),
		"description":str(module.get("description", ""))
	})
	_content.add_child(inspector)


func _build_hull_inspector(hull_id: String) -> void:
	var hull := Game.content.ships.get(hull_id, {}) as Dictionary
	if hull.is_empty():
		_build_blueprint_overview()
		return
	_content.add_child(_view_heading(I18n.core("ships.assembly.hull_inspector", "HULL INSPECTOR"), I18n.core("ships.assembly.back_to_summary", "Back to summary"), show_blueprint_summary))
	var art_frame := PanelContainer.new()
	art_frame.custom_minimum_size.y = 150.0
	art_frame.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("07100f"), Color(UiTokens.COLOR_FOCUS, 0.32), 3))
	var art := TextureRect.new()
	art.name = "AssemblyHullInspectorArtwork"
	var art_path := str(hull.get("ui_visual", {}).get("topdown_texture", ""))
	art.texture = load(art_path) as Texture2D if not art_path.is_empty() and ResourceLoader.exists(art_path) else null
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art_frame.add_child(art)
	_content.add_child(art_frame)
	var identity := _section(I18n.content(hull).to_upper())
	identity.add_child(_value_row("Class", str(hull.get("class", "SHIP"))))
	var visual := hull.get("hull_visual", {}) as Dictionary
	identity.add_child(_value_row("Dimensions", I18n.core("ships.assembly.dimensions", "W %.0fm  ·  L %.0fm") % [float(visual.get("beam_m", 0.0)), float(visual.get("length_m", 0.0))]))
	identity.add_child(_value_row("Sockets", str(int(hull.get("module_slots", 0)))))
	_content.add_child(identity)
	var base_stats := hull.get("base_stats", {}) as Dictionary
	var stats := _section(I18n.core("ships.assembly.baseline_engineering", "BASELINE ENGINEERING"))
	for stat in [[I18n.core("ships.assembly.mass_capacity", "Mass Capacity"), "mass_capacity", "t"], [I18n.core("ships.assembly.power_capacity", "Power Capacity"), "power_capacity", "MW"], [I18n.core("ships.assembly.heat_capacity", "Heat Capacity"), "thermal_capacity", "TU"], [I18n.core("ships.assembly.hull_integrity", "Hull Integrity"), "hull", ""], [I18n.core("ships.assembly.cargo", "Cargo"), "cargo_capacity", "SCU"]]:
		var key := str(stat[1])
		var value: Variant = hull.get(key, base_stats.get(key, 0.0))
		stats.add_child(_value_row(str(stat[0]), "%s%s%s" % [_number_text(float(value)), " " if not str(stat[2]).is_empty() else "", str(stat[2])]))
	_content.add_child(stats)


func _view_heading(title: String, action_text: String, action: Callable) -> Control:
	var row := HBoxContainer.new()
	var title_label := _label(title, 9, UiTokens.COLOR_FOCUS)
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title_label)
	var action_button := Button.new()
	action_button.text = action_text
	action_button.flat = true
	action_button.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(7))
	action_button.pressed.connect(action)
	row.add_child(action_button)
	return row


func _section(title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 5)
	var heading := _label(title, 8, UiTokens.COLOR_TEXT_MUTED)
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	section.add_child(heading)
	section.add_child(HSeparator.new())
	return section


func _status_row(title: String, allowed: bool, detail: String) -> Control:
	var panel := PanelContainer.new()
	var tone := UiTokens.COLOR_RUNNING if allowed else UiTokens.COLOR_WARNING
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color(tone, 0.08), Color(tone, 0.46), 3))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.add_child(_label(("●  " if allowed else "◇  ") + title, 9, tone))
	var detail_label := _label(detail, 8, UiTokens.COLOR_TEXT_SECONDARY)
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(detail_label)
	panel.add_child(column)
	return panel


func _value_row(key: String, value: String, tone: Color = UiTokens.COLOR_TEXT_SECONDARY) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var key_label := _label(key, 8, UiTokens.COLOR_TEXT_MUTED)
	key_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(key_label)
	var value_label := _label(value, 8, tone)
	value_label.name = "AssemblyData_%s" % key.validate_node_name()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	value_label.custom_minimum_size.x = 104.0
	row.add_child(value_label)
	return row


func _capacity_row(title: String, demand: float, capacity: float, tone: Color) -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.add_child(_value_row(title, I18n.core("ships.assembly.format.capacity", "%.1f / %.1f") % [demand, capacity], tone if demand <= capacity + 0.001 else UiTokens.COLOR_CRITICAL))
	var bar := ProgressBar.new()
	bar.name = "AssemblyCapacity_%s" % title
	bar.custom_minimum_size.y = 13.0
	bar.max_value = maxf(1.0, capacity)
	bar.value = demand
	bar.show_percentage = false
	column.add_child(bar)
	return column


func _detail_block(title: String, detail: String) -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.add_child(_label(title, 8, UiTokens.COLOR_TEXT_MUTED))
	var detail_label := _label(detail, 8, UiTokens.COLOR_TEXT_SECONDARY)
	detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(detail_label)
	return column


func _cost_text(costs: Dictionary) -> String:
	if costs.is_empty():
		return "—"
	var parts := PackedStringArray()
	var item_ids: Array = costs.keys()
	item_ids.sort()
	for item_id_value in item_ids:
		var item_id := str(item_id_value)
		parts.append(I18n.core("format.item_count", "%s ×%d") % [I18n.content(Game.content.items.get(item_id, {"name":item_id})), int(costs[item_id])])
	return " · ".join(parts)


func _time_text(milliseconds: float) -> String:
	var seconds := maxf(0.0, milliseconds) / 1000.0
	return I18n.core("ships.assembly.format.minutes", "%.1f min") % (seconds / 60.0) if seconds >= 60.0 else I18n.core("ships.assembly.format.seconds", "%.1f sec") % seconds


func _slot_label(slot: String) -> String:
	var labels := {"weapon":I18n.core("ships.assembly.slot.weapon", "Weapon"), "drive":I18n.core("ships.assembly.slot.drive", "Propulsion"), "shield":I18n.core("ships.assembly.slot.shield", "Defense"), "structure":I18n.core("ships.assembly.slot.structure", "Structure"), "core":I18n.core("ships.assembly.slot.core", "Core"), "utility":I18n.core("ships.assembly.slot.utility", "Utility"), "logistics":I18n.core("ships.assembly.slot.logistics", "Logistics")}
	return labels.get(slot, slot.to_upper())


func _slot_tone(slot: String) -> Color:
	return {"weapon":UiTokens.COLOR_CRITICAL, "drive":UiTokens.COLOR_FOCUS, "shield":UiTokens.COLOR_INFORMATION, "structure":UiTokens.COLOR_INFORMATION, "core":UiTokens.COLOR_WARNING, "utility":UiTokens.COLOR_RUNNING, "logistics":UiTokens.COLOR_INFO}.get(slot, UiTokens.COLOR_FOCUS)


func _number_text(value: float) -> String:
	return String.num(value, 1).trim_suffix(".0")


func _validation_reason_text(reason_code: String, fallback: String) -> String:
	match reason_code:
		"PLAN_LOCKED": return I18n.core("ships.assembly.validation.plan_locked", "Hull plan is locked")
		"HULL_INVALID": return I18n.core("ships.assembly.validation.hull_invalid", "Place exactly one hull matching this plan")
		"MODULE_UNCONNECTED": return I18n.core("ships.assembly.validation.module_unconnected", "Every module must connect to a compatible socket")
		"CORE_REQUIRED": return I18n.core("ships.assembly.validation.core_required", "Install and connect an energy core")
		"SOCKET_MISMATCH": return I18n.core("ships.assembly.validation.socket_mismatch", "Module interface is incompatible with the hull socket")
		"SOCKET_SIZE_MISMATCH": return I18n.core("ships.assembly.validation.socket_size_mismatch", "Module exceeds the socket size rating")
		"FITTING_INVALID": return I18n.core("ships.assembly.validation.fitting_invalid", "Mass, power, or heat exceeds hull limits")
		_: return fallback


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
