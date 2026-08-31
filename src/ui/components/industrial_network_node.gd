class_name IndustrialNetworkNode
extends GraphNode

signal activated(node_id: String)
signal hover_changed(node_id: String, hovered: bool)

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const GlyphScript = preload("res://src/ui/components/industrial_network_glyph.gd")

var node_id := ""
var projection: Dictionary = {}
var input_ports := {}
var output_ports := {}
var _actual_label: Label
var _progress: ProgressBar
var _status_label: Label
var _display_actual := 0.0
var _target_actual := 0.0
var _theoretical := 0.0
var _base_border := UiTokens.COLOR_BORDER_STRONG
var _hovered := false


func configure(data: Dictionary) -> void:
	node_id = str(data.get("id", ""))
	name = StringName("N_%s" % node_id.sha256_text().left(16))
	title = str(data.get("title", node_id))
	tooltip_text = "%s\n%s" % [title, str(data.get("subtitle", ""))]
	draggable = true
	selectable = true
	resizable = false
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size.x = UiTokens.NETWORK_NODE_WIDTH
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	gui_input.connect(_on_gui_input)
	apply_projection(data)


func apply_projection(data: Dictionary) -> void:
	projection = data.duplicate(true)
	title = str(data.get("title", node_id))
	_target_actual = float(data.get("actual_rate", 0.0))
	_theoretical = float(data.get("theoretical_rate", 0.0))
	if not is_instance_valid(_actual_label):
		_display_actual = _target_actual
	_rebuild_content()
	_apply_style()


func input_port(port_id: String) -> int:
	return int(input_ports.get(port_id, -1))


func output_port(port_id: String) -> int:
	return int(output_ports.get(port_id, -1))


func apply_visual_time(phase: float, delta: float, reduced_motion: bool) -> void:
	if is_instance_valid(_actual_label):
		var speed := minf(1.0, delta / 0.22) if not reduced_motion else 1.0
		_display_actual = lerpf(_display_actual, _target_actual, speed)
		_actual_label.text = _rate_text(_display_actual, _theoretical)
	if not is_instance_valid(_progress):
		return
	var status := str(projection.get("status", "PAUSED"))
	var base := _status_color(status)
	if not reduced_motion and status == "RUNNING":
		base = base.lerp(Color.WHITE, 0.06 + sin(phase * TAU / 2.0) * 0.035)
	var fill := UiTokens.panel_style(base.darkened(0.55), base, 2)
	_progress.add_theme_stylebox_override("fill", fill)


func set_focus_tone(mode: String) -> void:
	modulate.a = 0.24 if mode == "DIM" else 1.0
	if mode in ["FOCUS", "BOTTLENECK"]:
		_base_border = UiTokens.COLOR_WARNING if mode == "BOTTLENECK" else UiTokens.COLOR_FOCUS
	else:
		_base_border = _status_color(str(projection.get("status", "PAUSED"))).darkened(0.25)
	_apply_style()


func _rebuild_content() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	input_ports.clear()
	output_ports.clear()
	var kind := str(projection.get("kind", "PRODUCTION"))
	var status := str(projection.get("status", "PAUSED"))
	_base_border = _status_color(status).darkened(0.25)

	var identity := HBoxContainer.new()
	identity.custom_minimum_size.y = 30
	identity.add_theme_constant_override("separation", 6)
	var icon = GlyphScript.new()
	icon.configure(kind, _kind_color(kind), true)
	identity.add_child(icon)
	var kind_label := Label.new()
	kind_label.text = I18n.core("industrial_network.kind.%s" % kind.to_lower(), kind.capitalize())
	kind_label.add_theme_font_size_override("font_size", 10)
	kind_label.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	kind_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_child(kind_label)
	_status_label = Label.new()
	_status_label.text = I18n.status(status)
	_status_label.add_theme_font_size_override("font_size", 10)
	_status_label.add_theme_color_override("font_color", _status_color(status))
	identity.add_child(_status_label)
	add_child(_margin(identity, 8, 8, 4, 2))

	var subtitle := Label.new()
	subtitle.text = str(projection.get("subtitle", ""))
	subtitle.tooltip_text = subtitle.text
	subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	add_child(_margin(subtitle, 10, 10, 2, 5))

	var inputs: Array = projection.get("inputs", [])
	var outputs: Array = projection.get("outputs", [])
	var row_count := maxi(inputs.size(), outputs.size())
	if row_count == 0:
		row_count = 1
	var input_index := 0
	var output_index := 0
	for row_index in row_count:
		var input: Dictionary = inputs[row_index] if row_index < inputs.size() else {}
		var output: Dictionary = outputs[row_index] if row_index < outputs.size() else {}
		var row := HBoxContainer.new()
		row.custom_minimum_size.y = 28
		row.add_theme_constant_override("separation", 4)
		row.add_child(_port_copy(input, true))
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(spacer)
		row.add_child(_port_copy(output, false))
		add_child(_margin(row, 9, 9, 0, 0))
		var slot_index := get_child_count() - 1
		var has_input := not input.is_empty()
		var has_output := not output.is_empty()
		var input_color := _port_color(input)
		var output_color := _port_color(output)
		set_slot(slot_index, has_input, 0, input_color, has_output, 0, output_color)
		if has_input:
			input_ports[str(input.get("id", "in:%s" % input.get("item_id", "")))] = input_index
			input_index += 1
		if has_output:
			output_ports[str(output.get("id", "out:%s" % output.get("item_id", "")))] = output_index
			output_index += 1

	var metrics := HBoxContainer.new()
	metrics.custom_minimum_size.y = 26
	var metric_name := Label.new()
	metric_name.text = I18n.core("industrial_network.throughput", "THROUGHPUT")
	metric_name.add_theme_font_size_override("font_size", 10)
	metric_name.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_MUTED)
	metric_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	metrics.add_child(metric_name)
	_actual_label = Label.new()
	_actual_label.text = _rate_text(_display_actual, _theoretical)
	_actual_label.add_theme_font_size_override("font_size", 11)
	_actual_label.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_SECONDARY)
	metrics.add_child(_actual_label)
	add_child(_margin(metrics, 10, 10, 2, 0))

	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 5
	_progress.max_value = 1.0
	_progress.value = _primary_progress()
	_progress.show_percentage = false
	add_child(_margin(_progress, 10, 10, 0, 7))

	var blocker: Dictionary = projection.get("blocker", {}) if projection.get("blocker", null) is Dictionary else {}
	if not blocker.is_empty():
		var blocker_label := Label.new()
		blocker_label.text = I18n.core("industrial_network.blocker_tag", "! %s") % _blocker_caption(blocker)
		blocker_label.tooltip_text = _blocker_caption(blocker)
		blocker_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		blocker_label.add_theme_font_size_override("font_size", 10)
		blocker_label.add_theme_color_override("font_color", UiTokens.COLOR_WARNING if status != "BLOCKED_OUTPUT" else UiTokens.COLOR_CRITICAL)
		add_child(_margin(blocker_label, 10, 10, 4, 7))


func _port_copy(port: Dictionary, input: bool) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size.x = 102
	row.add_theme_constant_override("separation", 4)
	if port.is_empty():
		return row
	var item_id := str(port.get("item_id", ""))
	var port_type := str(port.get("port_type", "MATERIAL"))
	var glyph = GlyphScript.new()
	glyph.custom_minimum_size = Vector2(14, 14)
	glyph.configure(port_type, _port_color(port), bool(port.get("connected", false)))
	var label := Label.new()
	label.text = str(port.get("title", item_id))
	label.tooltip_text = label.text
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", UiTokens.COLOR_TEXT_SECONDARY)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if input:
		row.add_child(glyph)
		row.add_child(label)
	else:
		row.add_child(label)
		row.add_child(glyph)
	return row


func _margin(control: Control, left: int, right: int, top: int, bottom: int) -> MarginContainer:
	if control.get_parent() != null:
		control.get_parent().remove_child(control)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_bottom", bottom)
	margin.add_child(control)
	return margin


func _apply_style() -> void:
	var normal := UiTokens.panel_style(UiTokens.COLOR_NODE_SURFACE, _base_border, 4)
	normal.shadow_color = Color(0, 0, 0, 0.28)
	normal.shadow_size = 6
	var hovered_border := UiTokens.COLOR_FOCUS if _hovered else _base_border
	if _hovered:
		normal.border_color = hovered_border
	var selected_style := UiTokens.panel_style(UiTokens.COLOR_NODE_SURFACE.lightened(0.025), UiTokens.COLOR_FOCUS, 4)
	selected_style.set_border_width_all(2)
	selected_style.shadow_color = Color(UiTokens.COLOR_FOCUS, 0.26)
	selected_style.shadow_size = 8
	var titlebar := UiTokens.panel_style(UiTokens.COLOR_NODE_HEADER, _base_border, 4)
	titlebar.border_width_bottom = 1
	var titlebar_selected := UiTokens.panel_style(UiTokens.COLOR_NODE_HEADER.lightened(0.035), UiTokens.COLOR_FOCUS, 4)
	titlebar_selected.border_width_bottom = 1
	add_theme_stylebox_override("panel", normal)
	add_theme_stylebox_override("panel_selected", selected_style)
	add_theme_stylebox_override("titlebar", titlebar)
	add_theme_stylebox_override("titlebar_selected", titlebar_selected)
	add_theme_color_override("title_color", UiTokens.COLOR_TEXT)
	add_theme_color_override("title_selected_color", UiTokens.COLOR_TEXT)


func _set_hovered(value: bool) -> void:
	_hovered = value
	_apply_style()
	hover_changed.emit(node_id, value)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		activated.emit(node_id)
		accept_event()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
		activated.emit(node_id)
		accept_event()


func _primary_progress() -> float:
	if str(projection.get("kind", "")) == "BUFFER":
		return clampf(float(projection.get("buffer", {}).get("utilization", 0.0)), 0.0, 1.0)
	return clampf(float(projection.get("utilization", 0.0)), 0.0, 1.0)


func _rate_text(actual: float, theoretical: float) -> String:
	return I18n.core("industrial_network.rate_pair", "%.1f/h · %.1f/h") % [actual, theoretical]


func _blocker_caption(blocker: Dictionary) -> String:
	var reason := str(blocker.get("primary_reason", blocker.get("code", blocker.get("reason", "BLOCKED"))))
	return I18n.status(reason)


func _kind_color(kind: String) -> Color:
	match kind:
		"SOURCE": return UiTokens.COLOR_RUNNING
		"BUFFER": return UiTokens.COLOR_INFORMATION
		"LOGISTICS": return UiTokens.COLOR_INFO
		"DEMAND": return UiTokens.COLOR_ENERGY
		"INFRASTRUCTURE": return UiTokens.COLOR_ENERGY
		_: return UiTokens.COLOR_MATERIAL


func _port_color(port: Dictionary) -> Color:
	match str(port.get("port_type", "MATERIAL")):
		"SERVICE": return UiTokens.COLOR_ENERGY
		"DEMAND": return UiTokens.COLOR_WARNING
		"INFORMATION": return UiTokens.COLOR_RESEARCH
		_: return UiTokens.COLOR_MATERIAL


func _status_color(status: String) -> Color:
	match status:
		"RUNNING", "ACTIVE", "HEALTHY", "STABLE", "SURPLUS": return UiTokens.COLOR_RUNNING
		"BLOCKED", "BLOCKED_INPUT", "BLOCKED_OUTPUT", "CRITICAL": return UiTokens.COLOR_CRITICAL
		"POWER_LIMITED", "COOLING_LIMITED", "LOGISTICS_LIMITED", "CONGESTED", "SATURATED", "TIGHT", "STORAGE_FULL", "CONSTRAINED": return UiTokens.COLOR_WARNING
		_: return UiTokens.COLOR_INACTIVE
