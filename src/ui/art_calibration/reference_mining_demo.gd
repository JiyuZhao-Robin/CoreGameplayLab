class_name ReferenceMiningDemo
extends Control

## Fixed 1920 x 1080 art-calibration page for two imported reference miners.
## It is deliberately isolated from Factory, inventory, and save state.

const Assets := preload("res://src/ui/art_calibration/reference_mining_assets.gd")
const Stage := preload("res://src/ui/art_calibration/reference_mining_stage.gd")

var assets := Assets.new()
var stages: Dictionary = {}
var controls: Array[Control] = []

var _state_labels: Dictionary = {}
var _frame_labels: Dictionary = {}
var _frame_sliders: Dictionary = {}
var _run_buttons: Dictionary = {}
var _pause_buttons: Dictionary = {}
var _suspended_game: Node
var _original_persistence := false
var _original_processing := false


func _enter_tree() -> void:
	var game := get_node_or_null("/root/Game")
	if game != null:
		_suspended_game = game
		_original_persistence = bool(game.get("persistence_enabled"))
		_original_processing = game.is_processing()
		game.set("persistence_enabled", false)
		game.set_process(false)


func _exit_tree() -> void:
	if is_instance_valid(_suspended_game):
		_suspended_game.set("persistence_enabled", _original_persistence)
		_suspended_game.set_process(_original_processing)
	_suspended_game = null


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	custom_minimum_size = Vector2(1920, 1080)
	if get_window() != null:
		get_window().title = "Reference Miners / MK2 + Core Extractor"
	assets.load_pack()
	_build_ui()
	queue_redraw()


func _process(_delta: float) -> void:
	for candidate_id in stages.keys():
		_update_panel(str(candidate_id))


func request_running(candidate_id: String, value: bool) -> void:
	var stage := _stage(candidate_id)
	if stage != null:
		stage.call("request_running", value)
		_update_panel(candidate_id)


func seek_frame(candidate_id: String, frame: int) -> void:
	var stage := _stage(candidate_id)
	if stage != null:
		stage.call("seek_frame", frame)
		_update_panel(candidate_id)


func reset_view(candidate_id: String = "") -> void:
	if candidate_id.is_empty():
		for id in stages.keys():
			reset_view(str(id))
		return
	var stage := _stage(candidate_id)
	if stage != null:
		stage.call("reset_view")


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(1920, 1080)), Color("0b1115"))
	draw_rect(Rect2(30, 27, 6, 94), Color("e0a351"))
	draw_line(Vector2(30, 137), Vector2(1890, 137), Color("3c4a4d"), 1.0)
	for x in [30.0, 982.0]:
		draw_rect(Rect2(x, 145, 908, 672), Color("151f25"))
		draw_rect(Rect2(x, 207, 908, 610), Color("10181c"))
		draw_rect(Rect2(x, 817, 908, 187), Color("11191e"))
		draw_line(Vector2(x, 817), Vector2(x + 908, 817), Color("38484e"), 1.0)
	draw_line(Vector2(30, 1021), Vector2(1890, 1021), Color("35434a"), 1.0)


func _build_ui() -> void:
	_label("REFERENCE MINERS / MATERIAL CALIBRATION", Vector2(57, 26), Vector2(900, 22), 17, Color("e0a351"))
	_label("两款矿机 · 原始美术对照", Vector2(57, 51), Vector2(1100, 45), 36, Color("edf0e9"))
	_label("同一地面材质 · 保留建筑原始色彩与光影 · 两侧可独立操作", Vector2(59, 103), Vector2(1500, 22), 17, Color("a9bbc0"))
	_build_panel("mk2", 30.0, "MK2")
	_build_panel("core", 982.0, "CORE EXTRACTOR")
	if assets.errors.is_empty():
		_label("滚轮缩放 · 左键拖动 · 拖动滑条逐帧查看 · 倍率与原始占地见各面板", Vector2(30, 1035), Vector2(1300, 24), 16, Color("7f9698"))
	else:
		_label("素材载入失败：" + "; ".join(assets.errors), Vector2(30, 1035), Vector2(1820, 24), 16, Color("e5ab70"))


func _build_panel(candidate_id: String, x: float, fallback_name: String) -> void:
	var candidate: Dictionary = assets.call("candidate_definition", candidate_id) as Dictionary
	var name := str(candidate.get("name", fallback_name))
	var subtitle := str(candidate.get("subtitle", "Imported reference material"))
	var credit := str(candidate.get("credit", "Source credit recorded in manifest"))
	_label(name.to_upper(), Vector2(x + 22, 154), Vector2(570, 24), 22, Color("ebc17d"))
	_label(subtitle, Vector2(x + 22, 180), Vector2(850, 20), 15, Color("a8babd"))

	var stage := Stage.new() as Control
	stage.name = "ReferenceMiningStage_%s" % candidate_id
	stage.position = Vector2(x, 207)
	stage.size = Vector2(908, 610)
	stage.set("candidate_id", candidate_id)
	stage.set("assets", assets)
	stage.connect("view_changed", func() -> void: _update_panel(candidate_id))
	stage.connect("state_changed", func(_running_state: bool) -> void: _update_panel(candidate_id))
	add_child(stage)
	stages[candidate_id] = stage
	controls.append(stage)

	var state := _label("", Vector2(x + 20, 825), Vector2(235, 20), 15, Color("c4d7cf"))
	_state_labels[candidate_id] = state
	var frame_label := _label("", Vector2(x + 260, 825), Vector2(220, 20), 15, Color("a8bbc1"))
	_frame_labels[candidate_id] = frame_label
	var run_button := _button("停机", Rect2(x + 20, 849, 82, 34), func() -> void: request_running(candidate_id, not bool(stage.get("running"))))
	run_button.name = "%sRunToggle" % candidate_id.capitalize()
	_run_buttons[candidate_id] = run_button
	var pause_button := _button("暂停", Rect2(x + 110, 849, 82, 34), func() -> void: stage.set("playing", not bool(stage.get("playing"))); _update_panel(candidate_id))
	pause_button.name = "%sPause" % candidate_id.capitalize()
	_pause_buttons[candidate_id] = pause_button
	var slider := HSlider.new()
	slider.name = "%sFrameSlider" % candidate_id.capitalize()
	slider.position = Vector2(x + 202, 854)
	slider.size = Vector2(350, 22)
	slider.min_value = 0
	slider.max_value = 1
	slider.step = 1
	slider.value_changed.connect(func(value: float) -> void: seek_frame(candidate_id, roundi(value)))
	add_child(slider)
	controls.append(slider)
	_frame_sliders[candidate_id] = slider
	_button("重置视角", Rect2(x + 562, 849, 112, 34), func() -> void: reset_view(candidate_id))
	_button("单帧 +1", Rect2(x + 684, 849, 104, 34), func() -> void: seek_frame(candidate_id, int(stage.call("current_frame")) + 1))

	_label("缩放", Vector2(x + 20, 893), Vector2(48, 28), 15, Color("8fa8aa"))
	for index in 4:
		var zoom_value: float = [0.5, 1.0, 1.5, 2.0][index]
		var zoom_button := _button("%d%%" % roundi(zoom_value * 100.0), Rect2(x + 72 + index * 62, 889, 56, 30), func() -> void: stage.call("set_zoom", zoom_value))
		zoom_button.name = "%sZoom%d" % [candidate_id.capitalize(), roundi(zoom_value * 100.0)]
	_label("方向", Vector2(x + 332, 893), Vector2(74, 28), 15, Color("8fa8aa"))
	var directions: Array = assets.call("directions_for", candidate_id) as Array
	if directions.is_empty():
		directions = ["N"]
	for index in mini(4, directions.size()):
		var direction_id := str(directions[index])
		var direction_button := _button("固定" if direction_id == "authored" else direction_id, Rect2(x + 410 + index * 76, 889, 68, 30), func() -> void: stage.call("set_direction", direction_id); _update_panel(candidate_id))
		direction_button.name = "%sDirection%s" % [candidate_id.capitalize(), direction_id]

	var layer_names := ["base", "shadow", "emission", "ground", "ore"]
	var layer_captions := ["建筑主体", "独立阴影", "工作发光", "地面材质", "矿石样本"]
	for index in layer_names.size():
		var layer_id := str(layer_names[index])
		var check := _check(layer_captions[index], Vector2(x + 20 + (index % 3) * 180, 930 + (index / 3) * 31), Vector2(166, 28), true, func(enabled: bool) -> void:
			var layers: Dictionary = stage.get("visible_layers") as Dictionary
			layers[layer_id] = enabled
			stage.call("refresh")
		)
		check.name = "%sLayer%s" % [candidate_id.capitalize(), layer_id.capitalize()]
	var anchors := _check("占地与锚点", Vector2(x + 560, 930), Vector2(205, 28), false, func(enabled: bool) -> void: stage.set("show_anchors", enabled); stage.call("refresh"))
	anchors.name = "%sAnchors" % candidate_id.capitalize()
	_label(credit, Vector2(x + 20, 994), Vector2(860, 20), 14, Color("82989b"))
	_update_panel(candidate_id)


func _stage(candidate_id: String) -> Control:
	return stages.get(candidate_id, null) as Control


func _update_panel(candidate_id: String) -> void:
	var stage := _stage(candidate_id)
	var state := _state_labels.get(candidate_id, null) as Label
	var frame_label := _frame_labels.get(candidate_id, null) as Label
	var slider := _frame_sliders.get(candidate_id, null) as HSlider
	var run_button := _run_buttons.get(candidate_id, null) as Button
	var pause_button := _pause_buttons.get(candidate_id, null) as Button
	if stage == null or state == null or frame_label == null or slider == null:
		return
	var running_state := bool(stage.get("running"))
	var playing_state := bool(stage.get("playing"))
	var frame := int(stage.call("current_frame"))
	var frame_count := int(stage.call("current_frame_count"))
	var definition: Dictionary = assets.candidate_definition(candidate_id)
	var tiles: Array = definition.get("footprint_tiles", [1,1])
	state.text = "%s · %d%% · %d×%d" % ["运行" if running_state else "停机", roundi(float(stage.get("zoom"))*100), tiles[0], tiles[1]]
	frame_label.text = "帧 %03d / %03d · %d FPS" % [frame, maxi(0, frame_count - 1), int(definition.get("fps",30))]
	slider.set_block_signals(true)
	slider.max_value = maxi(0, frame_count - 1)
	slider.set_value_no_signal(frame)
	slider.set_block_signals(false)
	if run_button != null:
		run_button.text = "停机" if running_state else "启动"
	if pause_button != null:
		pause_button.text = "暂停" if playing_state else "播放"


func _label(text_value: String, position_value: Vector2, size_value: Vector2, font_size: int, color: Color = Color("e8eee9")) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = position_value
	label.size = size_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	controls.append(label)
	return label


func _button(text_value: String, rect: Rect2, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text_value
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_size_override("font_size", 15)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("23323a")
	normal.border_color = Color("4d6268")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(4)
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate()
	hover.bg_color = Color("33474e")
	button.add_theme_stylebox_override("hover", hover)
	button.pressed.connect(callback)
	add_child(button)
	controls.append(button)
	return button


func _check(text_value: String, position_value: Vector2, size_value: Vector2, pressed: bool, callback: Callable) -> CheckButton:
	var check := CheckButton.new()
	check.text = text_value
	check.position = position_value
	check.size = size_value
	check.button_pressed = pressed
	check.add_theme_font_size_override("font_size", 15)
	check.toggled.connect(callback)
	add_child(check)
	controls.append(check)
	return check
