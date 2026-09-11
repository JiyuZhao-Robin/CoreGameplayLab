class_name FactoryShipmentInspector
extends VBoxContainer

## Read-only local drone delivery panel for one Factory entity.  It deliberately
## consumes only the v1 Factory snapshot: real cargo remains owned by the
## simulation and Location inventory is never mutated by this view.

const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const ItemIcon = preload("res://src/ui/workspaces/location/location_item_icon.gd")

const NAVY := Color("0c141c")
const RAISED := Color("15222d")
const BORDER := Color("304652")
const CYAN := Color("65d9d1")
const AMBER := Color("e5b467")
const OFFWHITE := Color("e4ecef")
const MUTED := Color("96aab7")
const CRITICAL := Color("ef867d")

const MAX_PANEL_HEIGHT := 224
const DELIVERY_ROW_HEIGHT := 76

@onready var I18n = get_node_or_null("/root/I18n")

var _snapshot: Dictionary = {}
var _entity: Dictionary = {}


func _ready() -> void:
	name = "FactoryDroneShipmentInspector"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	add_theme_constant_override("separation", UiTokens.layout_px(4))
	_rebuild()


## Snapshot records are immutable presentation data.  Rebuilding this bounded
## sub-tree on a runtime snapshot lets progress, ETA, and block reasons update
## while the selected entity remains stable in FactoryWorkspace.
func configure(snapshot: Dictionary, entity: Dictionary) -> void:
	_snapshot = snapshot.duplicate(false)
	_entity = entity.duplicate(false)
	if is_node_ready():
		_rebuild()


func shipment_rows() -> Array:
	var entity_id := str(_entity.get("id", ""))
	if entity_id.is_empty() or str(_snapshot.get("logistics_mode", "")) != "PLANET_SHARED_DRONES":
		return []
	var rows: Array = []
	var raw_shipments: Variant = _snapshot.get("drone_shipments", [])
	if not raw_shipments is Array:
		return rows
	for shipment_value in raw_shipments:
		if not shipment_value is Dictionary:
			continue
		var shipment := shipment_value as Dictionary
		var is_source := str(shipment.get("source_id", "")) == entity_id
		var is_target := str(shipment.get("target_id", "")) == entity_id
		var is_tower := str(shipment.get("tower_id", "")) == entity_id
		if not is_source and not is_target and not is_tower:
			continue
		var row := shipment.duplicate(false)
		row["direction"] = "TRANSFER" if is_tower or (is_source and is_target) else ("SENDING" if is_source else "RECEIVING")
		rows.append(row)
	rows.sort_custom(func(left, right): return str((left as Dictionary).get("id", "")) < str((right as Dictionary).get("id", "")))
	return rows


func _rebuild() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	if str(_snapshot.get("logistics_mode", "")) != "PLANET_SHARED_DRONES":
		return
	var rows := shipment_rows()
	var heading := HBoxContainer.new()
	heading.name = "FactoryDroneShipmentHeading"
	heading.add_theme_constant_override("separation", UiTokens.layout_px(5))
	var title := _label(_t("factory.drone.shipments", "Drone deliveries"), CYAN, 12)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var count := _label(str(rows.size()), MUTED, 10)
	count.name = "FactoryDroneShipmentCount"
	count.tooltip_text = _t("factory.drone.shipments_count", "%d drone flights") % rows.size()
	heading.add_child(count)
	add_child(HSeparator.new())
	add_child(heading)
	var scroll := ScrollContainer.new()
	scroll.name = "FactoryDroneShipmentScroll"
	scroll.custom_minimum_size.y = UiTokens.layout_px(80)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.tooltip_text = _t("factory.drone.shipments_tooltip", "Timed drone deliveries for this building. Cargo stays in transit until it reaches its destination.")
	add_child(scroll)
	var body := VBoxContainer.new()
	body.name = "FactoryDroneShipmentRows"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", UiTokens.layout_px(4))
	scroll.add_child(body)
	if rows.is_empty():
		var empty := _label(_t("factory.drone.shipments_empty", "No drone flights are active for this building."), MUTED, 10)
		empty.name = "FactoryDroneShipmentEmpty"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.custom_minimum_size.y = UiTokens.layout_px(42)
		body.add_child(empty)
		return
	for row_value in rows:
		body.add_child(_shipment_row(row_value as Dictionary))
	# Keep this sub-list bounded inside the existing inspector scroll.  At large
	# accessibility sizes this still exposes one complete delivery row and scrolls
	# locally rather than stretching the Factory page.
	var visible_rows := mini(3, rows.size())
	scroll.custom_minimum_size.y = UiTokens.layout_px(mini(MAX_PANEL_HEIGHT, visible_rows * DELIVERY_ROW_HEIGHT + 4))


func _shipment_row(shipment: Dictionary) -> Control:
	var shipment_id := str(shipment.get("id", "unknown"))
	var phase := _phase(shipment)
	var status := str(shipment.get("status", "")).to_upper()
	var panel := PanelContainer.new()
	panel.name = "DroneShipment%s" % shipment_id.validate_node_name()
	panel.custom_minimum_size.y = UiTokens.layout_px(DELIVERY_ROW_HEIGHT)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UiTokens.control_style(RAISED, _tone_for(status, phase), 3))
	panel.set_meta("shipment_id", shipment_id)
	panel.set_meta("direction", str(shipment.get("direction", "")))
	panel.set_meta("phase", phase)
	panel.set_meta("eta_ms", float(shipment.get("eta_ms", -1.0)))
	var body := MarginContainer.new()
	body.add_theme_constant_override("margin_left", UiTokens.layout_px(6))
	body.add_theme_constant_override("margin_right", UiTokens.layout_px(6))
	body.add_theme_constant_override("margin_top", UiTokens.layout_px(4))
	body.add_theme_constant_override("margin_bottom", UiTokens.layout_px(4))
	panel.add_child(body)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTokens.layout_px(6))
	body.add_child(row)
	var icon := ItemIcon.new()
	icon.name = "DroneShipmentIcon"
	icon.custom_minimum_size = UiTokens.layout_vector(Vector2(34, 34))
	icon.configure_item(str(shipment.get("item_id", "")))
	icon.tooltip_text = _item_name(str(shipment.get("item_id", "")))
	row.add_child(icon)
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 0)
	row.add_child(detail)
	var top_line := HBoxContainer.new()
	top_line.add_theme_constant_override("separation", UiTokens.layout_px(4))
	detail.add_child(top_line)
	var direction := _label(_direction_text(shipment), _tone_for(status, phase), 10)
	direction.name = "DroneShipmentDirection"
	direction.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	direction.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top_line.add_child(direction)
	var amount := _label("×%d" % maxi(0, int(shipment.get("quantity", _cargo_quantity(shipment)))), OFFWHITE, 11)
	amount.name = "DroneShipmentQuantity"
	top_line.add_child(amount)
	var progress := ProgressBar.new()
	progress.name = "DroneShipmentProgress"
	progress.min_value = 0.0
	progress.max_value = 100.0
	progress.value = _progress_for(shipment, phase) * 100.0
	progress.show_percentage = false
	progress.custom_minimum_size.y = UiTokens.layout_px(6)
	progress.add_theme_stylebox_override("background", UiTokens.control_style(NAVY, NAVY, 2))
	progress.add_theme_stylebox_override("fill", UiTokens.control_style(_tone_for(status, phase), _tone_for(status, phase), 2))
	progress.tooltip_text = _phase_text(phase, status)
	detail.add_child(progress)
	var bottom_line := HBoxContainer.new()
	bottom_line.add_theme_constant_override("separation", UiTokens.layout_px(4))
	detail.add_child(bottom_line)
	var phase_label := _label(_phase_text(phase, status), _tone_for(status, phase), 9)
	phase_label.name = "DroneShipmentPhase"
	phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	phase_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bottom_line.add_child(phase_label)
	var eta := _label(_eta_text(shipment, phase, status), MUTED if phase != "BLOCKED" else CRITICAL, 9)
	eta.name = "DroneShipmentEta"
	eta.tooltip_text = _eta_tooltip(phase)
	bottom_line.add_child(eta)
	panel.tooltip_text = _shipment_tooltip(shipment, phase, status)
	panel.accessibility_name = panel.tooltip_text
	panel.set_meta("icon", icon)
	panel.set_meta("progress", progress)
	panel.set_meta("eta_label", eta)
	return panel


func _direction_text(shipment: Dictionary) -> String:
	if str(shipment.get("phase", "")) == "TO_PICKUP":
		return "%s → %s" % [_t("factory.drone.shipment.to_pickup", "Flying to collect"), _entity_name(str(shipment.get("source_id", "")))]
	if str(shipment.get("phase", "")) == "RETURNING":
		return "%s → %s" % [_t("factory.drone.shipment.returning", "Returning to tower"), _entity_name(str(shipment.get("tower_id", "")))]
	var direction := str(shipment.get("direction", ""))
	var other_id := str(shipment.get("target_id", "")) if direction == "SENDING" else str(shipment.get("source_id", ""))
	var other_name := _entity_name(other_id)
	match direction:
		"SENDING": return "%s → %s" % [_t("factory.drone.shipment.sending", "Sending"), other_name]
		"RECEIVING": return "%s ← %s" % [_t("factory.drone.shipment.receiving", "Receiving"), other_name]
		_: return _t("factory.drone.shipment.transfer", "Local transfer")


func _phase(shipment: Dictionary) -> String:
	if str(shipment.get("status", "")).begins_with("BLOCKED"):
		return "BLOCKED"
	return str(shipment.get("phase", "TO_PICKUP"))

func _phase_text(phase: String, status: String) -> String:
	if phase == "BLOCKED":
		return _blocked_reason(status)
	match phase:
		"TO_PICKUP": return _t("factory.drone.shipment.to_pickup", "Flying to collect")
		"TO_DELIVERY": return _t("factory.drone.shipment.to_delivery", "Delivering cargo")
		"RETURNING": return _t("factory.drone.shipment.returning", "Returning to tower")
		"LOADING": return _t("factory.drone.shipment.loading", "Loading")
		"UNLOADING": return _t("factory.drone.shipment.unloading", "Unloading")
		_: return _t("factory.drone.shipment.travel", "En route")


func _blocked_reason(status: String) -> String:
	match status:
		"BLOCKED_PATH": return _t("factory.drone.shipment.blocked_path", "Blocked: outside tower coverage")
		"BLOCKED_TARGET_FULL": return _t("factory.drone.shipment.blocked_target_full", "Blocked: destination storage full")
		"BLOCKED_TARGET": return _t("factory.drone.shipment.blocked_target", "Blocked: destination unavailable")
		"BLOCKED_MANIFEST": return _t("factory.drone.shipment.blocked_manifest", "Blocked: cargo manifest needs attention")
		_: return _t("factory.drone.shipment.blocked", "Blocked")


func _progress_for(shipment: Dictionary, _phase: String) -> float:
	return clampf(float(shipment.get("progress", shipment.get("travel_progress", 0.0))), 0.0, 1.0)

func _eta_text(shipment: Dictionary, phase: String, _status: String) -> String:
	var eta_ms := float(shipment.get("eta_ms", -1.0))
	if phase == "BLOCKED" or eta_ms < 0.0:
		return _t("factory.drone.shipment.no_eta", "No ETA")
	return _t("factory.drone.shipment.eta", "Remaining %s") % _duration(eta_ms)


func _eta_tooltip(phase: String) -> String:
	return _t("factory.drone.shipment.no_eta", "No ETA") if phase == "BLOCKED" else _t("factory.drone.shipment.eta_tooltip", "Remaining time for the current flight leg.")


func _shipment_tooltip(shipment: Dictionary, phase: String, status: String) -> String:
	var item_id := str(shipment.get("item_id", ""))
	var quantity := maxi(0, int(shipment.get("quantity", _cargo_quantity(shipment))))
	var lines: Array[String] = ["%s ×%d" % [_item_name(item_id), quantity], _direction_text(shipment), _phase_text(phase, status)]
	var eta_ms := float(shipment.get("eta_ms", -1.0))
	if phase != "BLOCKED" and eta_ms >= 0.0:
		lines.append(_t("factory.drone.shipment.eta", "Remaining %s") % _duration(eta_ms))
	return "\n".join(lines)


func _entity_name(entity_id: String) -> String:
	for entity_value in _snapshot.get("entities", []):
		if entity_value is Dictionary and str((entity_value as Dictionary).get("id", "")) == entity_id:
			return str((entity_value as Dictionary).get("name", entity_id))
	return entity_id if not entity_id.is_empty() else _t("factory.drone.shipment.unknown_endpoint", "Unknown endpoint")


func _item_name(item_id: String) -> String:
	var names: Dictionary = _snapshot.get("item_names", {}) if _snapshot.get("item_names", {}) is Dictionary else {}
	return str(names.get(item_id, item_id.replace("_", " ").capitalize())) if not item_id.is_empty() else _t("factory.value.none", "None")


func _cargo_quantity(shipment: Dictionary) -> int:
	var cargo: Dictionary = shipment.get("cargo", {}) if shipment.get("cargo", {}) is Dictionary else {}
	return maxi(0, int(cargo.get(str(shipment.get("item_id", "")), 0)))


func _tone_for(status: String, phase: String) -> Color:
	if phase == "BLOCKED" or status.begins_with("BLOCKED_"):
		return CRITICAL
	if phase in ["LOADING", "UNLOADING"] or status == "WAITING_LOADING":
		return AMBER
	return CYAN


func _duration(milliseconds: float) -> String:
	var seconds := maxi(0, int(ceil(milliseconds / 1000.0)))
	if seconds < 60:
		return "%ds" % seconds
	return "%dm %02ds" % [seconds / 60, seconds % 60]


func _label(value: String, color: Color, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", UiTokens.font_size(font_size))
	return label


func _t(key: String, fallback: String) -> String:
	if I18n == null:
		return fallback
	var localized := str(I18n.t(key))
	return fallback if localized == key else localized
