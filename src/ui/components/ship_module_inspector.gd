class_name ShipModuleInspector
extends VBoxContainer

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

const PROPERTY_SPECS: Array[Dictionary] = [
	{"id":"efficiency_bonus", "display_name":"Efficiency", "unit":"%", "presentation_type":"PERCENT", "priority":90, "category":"PERFORMANCE"},
	{"id":"mass", "display_name":"Mass", "unit":"t", "presentation_type":"NUMBER", "priority":90, "category":"ENGINEERING"},
	{"id":"power", "display_name":"Power", "unit":"MW", "presentation_type":"NUMBER", "priority":85, "category":"ENGINEERING"},
	{"id":"power_grid", "display_name":"Power grid", "unit":"MW", "presentation_type":"NUMBER", "priority":82, "category":"ENGINEERING"},
	{"id":"thermal", "display_name":"Heat", "unit":"TU", "presentation_type":"NUMBER", "priority":80, "category":"ENGINEERING"},
	{"id":"cooling", "display_name":"Cooling", "unit":"TU", "presentation_type":"NUMBER", "priority":78, "category":"ENGINEERING"},
	{"id":"cpu", "display_name":"Compute", "unit":"CU", "presentation_type":"NUMBER", "priority":72, "category":"ENGINEERING"},
	{"id":"cargo_capacity", "display_name":"Cargo capacity", "unit":"SCU", "presentation_type":"NUMBER", "priority":70, "category":"PERFORMANCE"},
	{"id":"ammunition_per_attack", "display_name":"Ammunition / attack", "unit":"", "presentation_type":"NUMBER", "priority":65, "category":"INSTALLATION"}
]

var _module: Dictionary = {}
var _context: Dictionary = {}
var _collapsed := {"PERFORMANCE":false, "ENGINEERING":true, "COMPATIBILITY":false, "INSTALLATION":true, "EFFECTS":true, "DESCRIPTION":true, "ADVANCED":true}


func _ready() -> void:
	add_theme_constant_override("separation", 8)


func configure(module: Dictionary, context: Dictionary = {}) -> void:
	_module = module.duplicate(true)
	_context = context.duplicate(true)
	_rebuild()


func property_descriptors() -> Array[Dictionary]:
	var descriptors: Array[Dictionary] = []
	for spec_value in PROPERTY_SPECS:
		var spec := (spec_value as Dictionary).duplicate(true)
		var property_id := String(spec.get("id", ""))
		if _module.has(property_id):
			spec["value"] = _module[property_id]
			descriptors.append(spec)
	for explicit_value in _module.get("ui_properties", []):
		if explicit_value is not Dictionary:
			continue
		var explicit := (explicit_value as Dictionary).duplicate(true)
		var source_field := String(explicit.get("source_field", explicit.get("id", "")))
		if not explicit.has("value") and _module.has(source_field):
			explicit["value"] = _module[source_field]
		if explicit.has("value"):
			descriptors.append(explicit)
	_append_nested_number_properties(descriptors, "fitting_capacity_bonus", "INSTALLATION", "Capacity")
	_append_nested_number_properties(descriptors, "combat_stats", "PERFORMANCE", "Combat")
	var capabilities := _module.get("capabilities", {}) as Dictionary
	for capability_id_value in capabilities.keys():
		var capability_id := String(capability_id_value)
		descriptors.append({"id":"capability.%s" % capability_id, "display_name":capability_id.replace("_", " ").capitalize(), "value":capabilities[capability_id_value], "unit":"", "presentation_type":"TAG", "priority":50, "category":"EFFECTS"})
	descriptors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("priority", 0)) > int(b.get("priority", 0)))
	return descriptors


func _append_nested_number_properties(result: Array[Dictionary], field: String, category: String, prefix: String) -> void:
	var values := _module.get(field, {}) as Dictionary
	for key_value in values.keys():
		var key := String(key_value)
		result.append({"id":"%s.%s" % [field, key], "display_name":"%s · %s" % [prefix, key.replace("_", " ").capitalize()], "value":values[key_value], "unit":"", "presentation_type":"NUMBER", "priority":55, "category":category})


func _rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	if _module.is_empty():
		return
	add_child(_build_header())
	var grouped := {}
	for descriptor in property_descriptors():
		var category := String(descriptor.get("category", "ADVANCED")).to_upper()
		if not grouped.has(category):
			grouped[category] = []
		(grouped[category] as Array).append(descriptor)
	for category in ["PERFORMANCE", "ENGINEERING", "COMPATIBILITY", "INSTALLATION", "EFFECTS", "DESCRIPTION", "ADVANCED"]:
		var descriptors := grouped.get(category, []) as Array
		if category == "COMPATIBILITY":
			descriptors = _compatibility_properties()
		elif category == "DESCRIPTION":
			var description := String(_module.get("description", _context.get("description", "")))
			if not description.is_empty():
				descriptors = [{"id":"description", "display_name":"", "value":description, "presentation_type":"TEXT"}]
		if not descriptors.is_empty():
			add_child(_build_section(category, descriptors))


func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.name = "ModuleInspectorHeader"
	header.add_theme_constant_override("separation", 12)
	var art_bay := PanelContainer.new()
	art_bay.custom_minimum_size = Vector2(88.0, 88.0)
	var tone := _context.get("tone", UiTokens.COLOR_FOCUS) as Color
	var style := UiTokens.panel_style(Color(UiTokens.COLOR_INSET, 0.96), Color(tone, 0.34), 4)
	art_bay.add_theme_stylebox_override("panel", style)
	var artwork := TextureRect.new()
	artwork.name = "ModuleInspectorArtwork"
	var art_path := String(_context.get("art_path", ""))
	artwork.texture = load(art_path) as Texture2D if not art_path.is_empty() and ResourceLoader.exists(art_path) else null
	artwork.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	artwork.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art_bay.add_child(artwork)
	header.add_child(art_bay)
	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.alignment = BoxContainer.ALIGNMENT_CENTER
	identity.add_theme_constant_override("separation", 4)
	identity.add_child(_label(String(_context.get("display_name", _module.get("name", _module.get("id", "Module")))), UiTokens.ship_assembly_font_size(13), UiTokens.COLOR_TEXT))
	identity.add_child(_label(String(_context.get("family_label", String(_module.get("slot", "utility")).capitalize())), UiTokens.ship_assembly_font_size(9), tone))
	identity.add_child(_label("%s · %s" % [String(_context.get("tier_label", "T1")), String(_context.get("installation_state", "AVAILABLE"))], UiTokens.ship_assembly_font_size(8), UiTokens.COLOR_TEXT_SECONDARY))
	header.add_child(identity)
	return header


func _compatibility_properties() -> Array:
	return [
		{"id":"socket_family", "display_name":"Socket family", "value":String(_context.get("family_label", String(_module.get("slot", "utility")).capitalize())), "presentation_type":"TEXT"},
		{"id":"interface_size", "display_name":"Interface", "value":"%s · %s" % [String(_module.get("size", "S")), String(_context.get("diameter_label", ""))], "presentation_type":"TEXT"},
		{"id":"mount_role", "display_name":"Mount role", "value":String(_context.get("mount_role", "—")), "presentation_type":"TEXT"}
	]


func _build_section(category: String, descriptors: Array) -> Control:
	var section := VBoxContainer.new()
	section.name = "ModuleInspectorSection_%s" % category
	section.add_theme_constant_override("separation", 4)
	var button := Button.new()
	button.name = "ModuleInspectorSectionToggle_%s" % category
	button.flat = true
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(8))
	button.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	button.pressed.connect(_toggle_section.bind(category))
	section.add_child(button)
	var body := GridContainer.new()
	body.name = "ModuleInspectorSectionBody_%s" % category
	body.columns = 2
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("h_separation", 12)
	body.add_theme_constant_override("v_separation", 4)
	for descriptor_value in descriptors:
		var descriptor := descriptor_value as Dictionary
		var display_name := String(descriptor.get("display_name", ""))
		var presentation_type := String(descriptor.get("presentation_type", "TEXT")).to_upper()
		if presentation_type == "BAR" and descriptor.has("minimum") and descriptor.has("maximum"):
			var key_label := _label(display_name, UiTokens.ship_assembly_font_size(8), UiTokens.COLOR_TEXT_MUTED)
			key_label.custom_minimum_size.x = 124.0
			body.add_child(key_label)
			body.add_child(_bar_value(descriptor))
		else:
			var key_label := _label(display_name, UiTokens.ship_assembly_font_size(8), UiTokens.COLOR_TEXT_MUTED)
			key_label.custom_minimum_size.x = 124.0
			body.add_child(key_label)
			var value_label := _label(_format_property(descriptor), UiTokens.ship_assembly_font_size(9), UiTokens.COLOR_TEXT_SECONDARY)
			value_label.name = "ModuleProperty_%s" % String(descriptor.get("id", "value")).replace(".", "_")
			value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if String(descriptor.get("id", "")) == "description" else TextServer.AUTOWRAP_OFF
			value_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			body.add_child(value_label)
	section.add_child(body)
	var collapsed := bool(_collapsed.get(category, true))
	button.text = "%s  %s" % ["+" if collapsed else "−", category.replace("_", " ")]
	body.visible = not collapsed
	return section


func _toggle_section(category: String) -> void:
	_collapsed[category] = not bool(_collapsed.get(category, true))
	_rebuild()


func _bar_value(descriptor: Dictionary) -> Control:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(120.0, 18.0)
	bar.min_value = float(descriptor.get("minimum", 0.0))
	bar.max_value = float(descriptor.get("maximum", 100.0))
	bar.value = float(descriptor.get("value", 0.0))
	bar.show_percentage = bool(descriptor.get("show_percentage", true))
	return bar


func _format_property(descriptor: Dictionary) -> String:
	var value = descriptor.get("value", "")
	var presentation_type := String(descriptor.get("presentation_type", "TEXT")).to_upper()
	var unit := String(descriptor.get("unit", ""))
	match presentation_type:
		"PERCENT":
			return "%s%s" % [_number_text(float(value)), "%"]
		"BOOLEAN":
			return "YES" if bool(value) else "NO"
		"TAG":
			if value is float or value is int:
				return "ACTIVE" if float(value) > 0.0 else "INACTIVE"
			return String(value)
		"RANGE":
			if value is Dictionary:
				return "%s–%s%s" % [value.get("minimum", ""), value.get("maximum", ""), unit]
		"RATING":
			return "◆".repeat(maxi(0, int(value)))
		_:
			pass
	return "%s%s%s" % [_number_text(float(value)), " " if not unit.is_empty() else "", unit] if value is float or value is int else "%s%s%s" % [String(value), " " if not unit.is_empty() else "", unit]


func _number_text(value: float) -> String:
	return String.num(value, 2).trim_suffix("0").trim_suffix(".") if not is_equal_approx(value, roundf(value)) else str(roundi(value))


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label
