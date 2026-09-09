class_name ShipAssemblyBlueprintEditor
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

# The shipyard host gives the editor a bounded 1920 x 1080 design region. The
# editor itself must also remain useful in the shorter in-page shipyard region
# (about 1880 x 650 logical pixels) rather than forcing the Fleet page into a
# second vertical scroll. Physical 4K is supplied by the project-wide uniform
# canvas scale, never by this workspace.
const LIBRARY_COLUMN_END := 0.23
const CANVAS_COLUMN_END := 0.75
const WORKSPACE_GUTTER := 4.0
const SESSION_STATE_VERSION := 1

signal blueprint_saved(design_id: String)

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
var _blueprint_name := ""
var _design_id := ""
var _draft_dirty := false
var _selection_kind := ""
var _selection_id := ""
var _previous_ui_scale := 1.0
var _user_font_scale := DEFAULT_FONT_SCALE
var _applied_font_scale := -1.0
var _interface_rebuild_queued := false
var _interface_rebuilding := false
var _embedded_in_main := false
var _allow_locked_plan := true
var _ship_entries: Array[Dictionary] = DEMO_SHIPS.duplicate(true)
var _part_ids: Array[String] = DEMO_PART_IDS.duplicate()
var _pending_session_state: Dictionary = {}
var _session_restore_revision := 0


func configure_for_main_game() -> void:
	# Configure before entering the tree. The production host shares the shell's
	# explicit UI scale. While the Ship tab frame is being rebuilt, its visible
	# content stays intentionally limited to the approved Demo hull and modules;
	# the full domain catalogue remains untouched and authoritative elsewhere.
	_embedded_in_main = true
	_allow_locked_plan = true


func _ready() -> void:
	_previous_ui_scale = UiTokens.ui_scale()
	if _blueprint_name.is_empty():
		_blueprint_name = I18n.core("ships.assembly.default_blueprint_name", "Escort Configuration A")
	_user_font_scale = _sanitize_font_scale(_previous_ui_scale if _embedded_in_main else float(get_tree().root.get_meta(FONT_SCALE_SESSION_META, DEFAULT_FONT_SCALE)))
	_configure_manual_scaling()
	_apply_native_theme()
	_prepare_catalog_scope()
	_catalog = _blueprint_catalog()
	_build_demo()
	_refresh_saved_designs()
	_refresh_engineering()
	if not _pending_session_state.is_empty():
		var pending_state := _pending_session_state.duplicate(true)
		_pending_session_state.clear()
		_apply_session_state(pending_state, _session_restore_revision)


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


func refresh_domain_state() -> void:
	# The main game may advance while this editor is open. Refresh data that can
	# change in the domain without rebuilding the canvas or discarding its draft.
	if not is_node_ready():
		return
	_refresh_saved_designs()
	_refresh_engineering()


func current_design_id() -> String:
	return _design_id


func capture_session_state() -> Dictionary:
	# Drafts remain UI-local until the player presses Save.  The shell may carry
	# this snapshot across a page, locale, or explicit scale rebuild, but neither
	# capturing nor restoring it writes Game state or persistence.
	var draft := _assembly_view.draft_snapshot() if is_instance_valid(_assembly_view) else _draft.duplicate(true)
	var library_tab: int = _library.current_tab() if is_instance_valid(_library) else 0
	var canvas_zoom := 0.82
	var canvas_center := Vector2.ZERO
	if is_instance_valid(_assembly_view):
		canvas_zoom = _assembly_view.zoom
		canvas_center = (_assembly_view.scroll_offset + _assembly_view.size * 0.5) / maxf(canvas_zoom, 0.01)
	return {
		"version":SESSION_STATE_VERSION,
		"draft":draft.duplicate(true),
		"blueprint_name":_blueprint_name,
		"design_id":_design_id,
		"draft_dirty":_draft_dirty,
		"selection_kind":_selection_kind,
		"selection_id":_selection_id,
		"selection_node_id":_selected_canvas_node_id(),
		"library_tab":library_tab,
		"canvas_world_center":canvas_center,
		"canvas_zoom":canvas_zoom
	}


func restore_session_state(state: Dictionary) -> bool:
	# Accept restoration before _ready as well as after a mounted editor has laid
	# out.  The revision makes a newer caller win over any stale deferred camera
	# restoration still waiting on GraphEdit's layout pass.
	if state.is_empty():
		return false
	var draft_value: Variant = state.get("draft", {})
	if not (draft_value is Dictionary):
		return false
	_session_restore_revision += 1
	_pending_session_state = state.duplicate(true)
	if not is_node_ready():
		return true
	var pending_state := _pending_session_state.duplicate(true)
	_pending_session_state.clear()
	_apply_session_state(pending_state, _session_restore_revision)
	return true


func _apply_session_state(state: Dictionary, revision: int) -> void:
	if revision != _session_restore_revision:
		return
	var restored_draft: Dictionary = (state.get("draft", {}) as Dictionary).duplicate(true)
	_draft = restored_draft
	_blueprint_name = str(state.get("blueprint_name", _blueprint_name))
	_design_id = str(state.get("design_id", ""))
	_draft_dirty = bool(state.get("draft_dirty", false))
	_selection_kind = str(state.get("selection_kind", ""))
	_selection_id = str(state.get("selection_id", ""))
	if is_instance_valid(_assembly_view):
		_assembly_view.configure(_catalog, _draft)
	if is_instance_valid(_library):
		_library.select_tab(clampi(int(state.get("library_tab", 0)), 0, 1))
	_refresh_saved_designs(_design_id)
	_refresh_draft_chrome()
	_refresh_engineering()
	call_deferred("_restore_session_canvas_after_layout", state.duplicate(true), revision)


func _restore_session_canvas_after_layout(state: Dictionary, revision: int) -> void:
	# GraphEdit schedules its own Fit All while restoring the saved nodes.  Let
	# that layout settle first, then restore the player camera in shared world
	# coordinates so nodes, links, hit testing and the grid stay aligned.
	await get_tree().process_frame
	await get_tree().process_frame
	if revision != _session_restore_revision or not is_instance_valid(_assembly_view):
		return
	var zoom_value := _finite_session_float(state.get("canvas_zoom", 0.82), 0.82)
	var world_center := _session_vector2(state.get("canvas_world_center", Vector2.ZERO), Vector2.ZERO)
	_assembly_view.restore_view_center(world_center, zoom_value)
	_restore_session_selection(state)


func _restore_session_selection(state: Dictionary) -> void:
	if not is_instance_valid(_assembly_view):
		return
	var node_id := str(state.get("selection_node_id", ""))
	var selection_kind := str(state.get("selection_kind", ""))
	var selection_id := str(state.get("selection_id", ""))
	if selection_kind.is_empty() or selection_id.is_empty():
		return
	var selected_node := _assembly_view.get_node_or_null(NodePath(node_id)) as GraphNode
	if selected_node == null or String(selected_node.get_meta("entity_kind", "")) != selection_kind or String(selected_node.get_meta("entity_id", "")) != selection_id:
		selected_node = null
		for child in _assembly_view.get_children():
			var candidate := child as GraphNode
			if candidate != null and String(candidate.get_meta("entity_kind", "")) == selection_kind and String(candidate.get_meta("entity_id", "")) == selection_id:
				selected_node = candidate
				break
	if selected_node == null:
		return
	selected_node.selected = true
	# Keep the GraphEdit's own visual presentation synchronized with the restored
	# selection. This only re-emits the component-local selection signal.
	_assembly_view.call("_on_node_selected", selected_node)


func _selected_canvas_node_id() -> String:
	if not is_instance_valid(_assembly_view):
		return ""
	for child in _assembly_view.get_children():
		var graph_node := child as GraphNode
		if graph_node != null and graph_node.selected and String(graph_node.get_meta("entity_kind", "")) == _selection_kind and String(graph_node.get_meta("entity_id", "")) == _selection_id:
			return String(graph_node.name)
	return ""


func _session_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Dictionary:
		return Vector2(
			_finite_session_float((value as Dictionary).get("x", fallback.x), fallback.x),
			_finite_session_float((value as Dictionary).get("y", fallback.y), fallback.y)
		)
	return fallback


func _finite_session_float(value: Variant, fallback: float) -> float:
	if not (value is int or value is float or value is String):
		return fallback
	if value is String and not String(value).strip_edges().is_valid_float():
		return fallback
	var numeric := float(value)
	return fallback if is_nan(numeric) or is_inf(numeric) else numeric


func load_blueprint(design_id: String) -> bool:
	return _load_blueprint_by_id(design_id)


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
	page.offset_left = 8.0
	page.offset_top = 8.0
	page.offset_right = -8.0
	page.offset_bottom = -8.0
	page.add_theme_constant_override("separation", 8)
	page.add_child(_build_header())
	# The production host uses anchored thirds so its bounded shipyard stage
	# never grows into a page scroll. Keep the standalone demonstration's legacy
	# HBox surface intact: it is a separate lab with its own explicit font picker
	# and remains useful to focused interaction tests.
	var workspace: Control = Control.new() if _embedded_in_main else HBoxContainer.new()
	workspace.name = "BlueprintWorkspace"
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if not _embedded_in_main:
		(workspace as HBoxContainer).add_theme_constant_override("separation", 10)
	page.add_child(workspace)
	_library = ShipAssemblyLibraryScript.new()
	_library.entity_selected.connect(_on_entity_selected)
	workspace.add_child(_library)
	_library.configure(_catalog, _ship_entries, _part_ids)
	var canvas_region := _build_canvas()
	workspace.add_child(canvas_region)
	_data_panel = ShipAssemblyDataPanelScript.new()
	_data_panel.save_requested.connect(_save_blueprint)
	_data_panel.blueprint_name_changed.connect(_on_blueprint_name_changed)
	workspace.add_child(_data_panel)
	if _embedded_in_main:
		_place_workspace_column(_library, 0.0, LIBRARY_COLUMN_END, 0.0, -WORKSPACE_GUTTER)
		_place_workspace_column(canvas_region, LIBRARY_COLUMN_END, CANVAS_COLUMN_END, WORKSPACE_GUTTER, -WORKSPACE_GUTTER)
		_place_workspace_column(_data_panel, CANVAS_COLUMN_END, 1.0, WORKSPACE_GUTTER, 0.0)
	else:
		_library.custom_minimum_size.x = 320.0 * _accessibility_layout_scale()
		_data_panel.custom_minimum_size.x = 288.0 * _accessibility_layout_scale()


func _place_workspace_column(control: Control, left_anchor: float, right_anchor: float, left_inset: float, right_inset: float) -> void:
	# Asset library 23%, design canvas 52%, engineering data 25%. Each panel
	# keeps its own explicitly named inner scroller where its content can grow.
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.anchor_left = left_anchor
	control.anchor_right = right_anchor
	control.offset_left = left_inset
	control.offset_right = right_inset
	control.offset_top = 0.0
	control.offset_bottom = 0.0


func _build_header() -> Control:
	var panel := PanelContainer.new()
	panel.name = "BlueprintCommandBar"
	panel.custom_minimum_size.y = 52.0
	panel.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("0a1918"), UiTokens.COLOR_BORDER_STRONG, 3))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)
	var primary_row := HBoxContainer.new()
	primary_row.add_theme_constant_override("separation", 8)
	margin.add_child(primary_row)
	# At 150% the prior two-row command bar stole canvas height. The target
	# command width has room for this compact, stable single row.
	var actions_row := primary_row
	var brand := VBoxContainer.new()
	brand.custom_minimum_size.x = 218.0
	brand.add_theme_constant_override("separation", 1)
	var brand_name := _label("HELIOS CORE", 10, UiTokens.COLOR_FOCUS)
	brand_name.name = "BlueprintBrand"
	brand.add_child(brand_name)
	brand.add_child(_label(I18n.core("ships.assembly.lab_title", "SHIP ASSEMBLY LAB"), 14, UiTokens.COLOR_TEXT))
	primary_row.add_child(brand)
	var context := VBoxContainer.new()
	context.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	context.alignment = BoxContainer.ALIGNMENT_CENTER
	context.add_theme_constant_override("separation", 1)
	context.add_child(_label(I18n.core("ships.assembly.current_blueprint", "CURRENT BLUEPRINT"), 8, UiTokens.COLOR_TEXT_MUTED))
	_design_badge = _label("UNSAVED DESIGN", 9, UiTokens.COLOR_TEXT_SECONDARY)
	_design_badge.name = "CurrentBlueprintBadge"
	context.add_child(_design_badge)
	primary_row.add_child(context)
	if not _embedded_in_main:
		_font_scale_picker = OptionButton.new()
		_font_scale_picker.name = "ShipAssemblyFontScale"
		_font_scale_picker.custom_minimum_size.x = 96.0
		_font_scale_picker.tooltip_text = I18n.core("ships.assembly.text_size_tooltip", "TEXT SIZE")
		_font_scale_picker.accessibility_name = I18n.core("ships.assembly.text_size", "Text size")
		for percent in FONT_SCALE_OPTIONS:
			_font_scale_picker.add_item("%d%%" % percent, percent)
		var selected_percent := int(round(_user_font_scale * 100.0))
		_font_scale_picker.select(_font_scale_picker.get_item_index(selected_percent))
		_font_scale_picker.item_selected.connect(_on_font_scale_selected)
		actions_row.add_child(_font_scale_picker)
	_load_picker = OptionButton.new()
	_load_picker.name = "SavedBlueprintPicker"
	_load_picker.custom_minimum_size.x = 168.0
	_load_picker.tooltip_text = I18n.core("ships.assembly.select_saved_tooltip", "Select a saved ship blueprint")
	_load_picker.item_selected.connect(_on_load_picker_selected)
	actions_row.add_child(_load_picker)
	_load_button = Button.new()
	_load_button.name = "LoadBlueprintButton"
	_load_button.text = I18n.core("ships.assembly.load", "LOAD")
	_load_button.custom_minimum_size = Vector2(88.0, 36.0)
	_load_button.pressed.connect(_load_selected_blueprint)
	actions_row.add_child(_load_button)
	var new_button := Button.new()
	new_button.name = "NewBlueprintButton"
	new_button.text = I18n.core("ships.assembly.new", "NEW")
	new_button.custom_minimum_size = Vector2(94.0, 36.0)
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
	caption.custom_minimum_size.y = 24.0
	caption.add_theme_constant_override("separation", 8)
	var canvas_title := _label(I18n.core("ships.assembly.canvas_title", "ASSEMBLY CANVAS"), 9, UiTokens.COLOR_TEXT_MUTED)
	canvas_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	status_bar.custom_minimum_size.y = 24.0
	status_bar.add_theme_stylebox_override("panel", UiTokens.panel_style(Color("071210"), UiTokens.COLOR_BORDER, 0))
	_status_label = _label(I18n.core("ships.assembly.choose_hull", "Choose a hull from the left to begin."), 8, UiTokens.COLOR_TEXT_SECONDARY)
	_status_label.name = "BlueprintStatusLabel"
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_bar.add_child(_status_label)
	column.add_child(status_bar)
	return panel


func _prepare_catalog_scope() -> void:
	_ship_entries = DEMO_SHIPS.duplicate(true)
	_part_ids = DEMO_PART_IDS.duplicate()


func _blueprint_catalog() -> Dictionary:
	var plans := {}
	var hulls := {}
	for definition in _ship_entries:
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
	for module_id in _part_ids:
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
		"slot_labels":{"weapon":I18n.core("ships.assembly.slot.weapon", "WEAPON"), "shield":I18n.core("ships.assembly.slot.shield", "DEFENSE"), "drive":I18n.core("ships.assembly.slot.drive", "PROPULSION"), "utility":I18n.core("ships.assembly.slot.utility", "UTILITY"), "core":I18n.core("ships.assembly.slot.core", "CORE")},
		"structural_label":I18n.core("ships.assembly.slot.structure", "STRUCTURE"),
		"socket_label_format":I18n.core("ships.assembly.format.socket_label", "%s %d"),
		"module_label_format":I18n.core("ships.assembly.format.module_label", "%s · %s"),
		"hull_summary_format":I18n.core("ships.assembly.format.hull_summary", "%s · %d sockets"),
		"core_socket_format":I18n.core("ships.assembly.format.core_socket", "ENERGY CORE %d"),
		"functional_socket_shapes":true
	}


func _refresh_engineering() -> void:
	if not is_instance_valid(_data_panel):
		return
	var plan_id := str(_draft.get("plan_id", ""))
	if plan_id.is_empty() and not _ship_entries.is_empty():
		plan_id = str(_ship_entries[0].get("plan_id", ""))
	var nodes := _draft.get("nodes", []) as Array
	var connections := _draft.get("connections", []) as Array
	# The standalone replacement Demo may author design intent before the hull
	# development project is complete. Shipyard submission still enforces the
	# real unlock in Game.enqueue_saved_ship_design().
	var validation := Game.ship_design_validation(plan_id, nodes, connections, _allow_locked_plan)
	var summary := Game.ship_design_engineering_summary(plan_id, nodes, connections, _allow_locked_plan)
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
		_status_label.text = status_override if not status_override.is_empty() else I18n.core("ships.assembly.choose_hull", "Choose a hull from the left to begin.")
		_measurement_label.text = "W —  ·  L —"
	else:
		var hull := Game.content.ships.get(hull_id, {}) as Dictionary
		var visual := hull.get("hull_visual", {}) as Dictionary
		var module_count := maxi(0, (_draft.get("nodes", []) as Array).size() - 1)
		var connection_count := (_draft.get("connections", []) as Array).size()
		_status_label.text = status_override if not status_override.is_empty() else (I18n.core("ships.assembly.draft_summary", "%s · %d modules placed · %d sockets connected") % [I18n.content(hull), module_count, connection_count])
		_measurement_label.text = I18n.core("ships.assembly.dimensions", "W %.0fm  ·  L %.0fm") % [float(visual.get("beam_m", 0.0)), float(visual.get("length_m", 0.0))]


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
	_design_badge.text = I18n.core("ships.assembly.format.blueprint_state", "%s  ·  %s") % [_blueprint_name, state_label]


func _on_font_scale_selected(index: int) -> void:
	if not is_instance_valid(_font_scale_picker) or index < 0:
		return
	_user_font_scale = _sanitize_font_scale(float(_font_scale_picker.get_item_id(index)))
	get_tree().root.set_meta(FONT_SCALE_SESSION_META, _user_font_scale)
	_queue_interface_rebuild()


func _save_blueprint() -> void:
	var snapshot := _assembly_view.draft_snapshot() if is_instance_valid(_assembly_view) else _draft
	var plan_id := str(snapshot.get("plan_id", ""))
	if Game.save_ship_design(_design_id, _blueprint_name, plan_id, snapshot.get("nodes", []), snapshot.get("connections", []), _allow_locked_plan):
		_design_id = Game.last_saved_ship_design_id
		var saved_design := Game.state.ship_designs.get(_design_id, {}) as Dictionary
		_blueprint_name = str(saved_design.get("name", _blueprint_name))
		_draft = saved_design.duplicate(true)
		_draft_dirty = false
		var saved_notice := Game.last_notice
		var persisted := not Game.persistence_enabled or Game.save_game()
		var status := I18n.core("ships.assembly.saved_notice", "%s; blueprint saved without starting construction or refit.") % saved_notice
		if not persisted:
			status = I18n.core("ships.assembly.save_write_failed", "%s; blueprint remains in this session, but the local save write failed.") % saved_notice
		_refresh_saved_designs(_design_id)
		_refresh_draft_chrome(status)
		blueprint_saved.emit(_design_id)
	else:
		_status_label.text = Game.last_notice
	_refresh_engineering()


func _new_blueprint() -> void:
	_design_id = ""
	_blueprint_name = I18n.core("ships.assembly.new_blueprint_name", "New Ship Blueprint %d") % (Game.state.ship_designs.size() + 1)
	_selection_kind = ""
	_selection_id = ""
	_draft = {}
	_draft_dirty = false
	_assembly_view.clear_draft(false)
	_assembly_view.call("_reset_view")
	_library.select_tab(0)
	_refresh_saved_designs()
	_refresh_draft_chrome(I18n.core("ships.assembly.blank_created", "Blank blueprint created; no physical ship was changed."))
	_refresh_engineering()


func _refresh_saved_designs(preferred_design_id: String = "") -> void:
	if not is_instance_valid(_load_picker):
		return
	_load_picker.clear()
	_load_picker.add_item(I18n.core("ships.assembly.no_saved_blueprints", "No saved blueprints"))
	_load_picker.set_item_metadata(0, "")
	var design_ids: Array = Game.state.ship_designs.keys()
	design_ids.sort()
	for design_id_value in design_ids:
		var design_id := str(design_id_value)
		var design := Game.state.ship_designs.get(design_id, {}) as Dictionary
		if not (_catalog.get("plans", {}) as Dictionary).has(str(design.get("plan_id", ""))):
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
		_load_picker.set_item_text(0, I18n.core("ships.assembly.select_saved", "Select saved blueprint"))
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
		_status_label.text = I18n.core("ships.assembly.select_saved_first", "Select a saved ship blueprint first.")
		return
	var design_id := str(_load_picker.get_item_metadata(_load_picker.selected))
	_load_blueprint_by_id(design_id)


func _load_blueprint_by_id(design_id: String) -> bool:
	var design := Game.state.ship_designs.get(design_id, {}) as Dictionary
	if design.is_empty():
		_status_label.text = I18n.core("ships.assembly.selected_not_found", "The selected blueprint was not found.")
		return false
	if not (_catalog.get("plans", {}) as Dictionary).has(str(design.get("plan_id", ""))):
		_status_label.text = I18n.core("ships.assembly.selected_hull_unavailable", "The selected blueprint hull plan is not in the current catalogue.")
		return false
	_design_id = design_id
	_blueprint_name = str(design.get("name", design_id))
	_selection_kind = ""
	_selection_id = ""
	_draft = design.duplicate(true)
	_draft_dirty = false
	_assembly_view.configure(_catalog, _draft)
	_refresh_draft_chrome(I18n.core("ships.assembly.loaded_notice", "Loaded %s; edits remain in the current blueprint draft.") % _blueprint_name)
	_refresh_engineering()
	return true


func _on_notice_requested(code: String) -> void:
	match code:
		"HULL_ALREADY_PLACED": _status_label.text = I18n.core("ships.assembly.notice.hull_already_placed", "This blueprint already contains its single allowed hull.")
		"PORT_DIRECTION_INVALID": _status_label.text = I18n.core("ships.assembly.notice.port_direction_invalid", "Connect from the module's inset interface to a hull socket.")
		"PORT_SHAPE_MISMATCH": _status_label.text = I18n.core("ships.assembly.notice.port_shape_mismatch", "The functional family or physical interface is incompatible.")
		"PORT_SIZE_MISMATCH": _status_label.text = I18n.core("ships.assembly.notice.port_size_mismatch", "The module exceeds this socket's physical size rating.")
		"PORT_ALREADY_OCCUPIED": _status_label.text = I18n.core("ships.assembly.notice.port_already_occupied", "The module interface or hull socket is already occupied.")
		_: _status_label.text = I18n.core("ships.assembly.notice.operation_failed", "The operation could not be completed.")


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", UiTokens.ship_assembly_font_size(font_size))
	label.add_theme_color_override("font_color", color)
	return label
