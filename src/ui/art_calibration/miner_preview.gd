class_name HelixMinerPreview
extends Control

## Fixed-design calibration page for the original Helix Miner 3D bake. This is
## an isolated art tool: it can pause Game persistence for an F6 launch, but it
## never emits gameplay commands or changes economic state.

const Assets := preload("res://src/ui/art_calibration/miner_assets.gd")
const Stage := preload("res://src/ui/art_calibration/miner_stage.gd")

var assets := Assets.new()
var stage: Control
var controls: Array[Control] = []
var frame_slider: HSlider
var frame_label: Label
var state_label: Label
var zoom_label: Label
var playback_button: Button
var running_button: Button


func _enter_tree() -> void:
	var game := get_node_or_null("/root/Game")
	if game != null:
		game.set("persistence_enabled", false)
		game.set_process(false)


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	custom_minimum_size = Vector2(1920, 1080)
	assets.load_pack()
	_build_ui()
	if assets.errors.is_empty():
		stage.call("request_running", true)
	else:
		frame_label.text = "资源未就绪：" + "; ".join(assets.errors)
	queue_redraw()


func _process(_delta: float) -> void:
	_update_status()


func request_running(value: bool) -> void:
	if stage != null:
		stage.call("request_running", value)
	_update_status()


func seek_frame(frame: int) -> void:
	if stage != null:
		stage.call("seek_frame", frame)
	_update_status()


func reset_view() -> void:
	if stage != null:
		stage.call("reset_view")
	_update_status()


func _draw() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color("0b1115"))
	draw_rect(Rect2(34, 30, 6, 92), Color("e1a451"))
	draw_line(Vector2(34, 142), Vector2(1886, 142), Color("35434a"), 1.0)
	draw_rect(Rect2(1414, 160, 472, 738), Color("151f25"))
	draw_rect(Rect2(34, 918, 1362, 112), Color("151f25"))


func _build_ui() -> void:
	_label("HELIOS / ORIGINAL 3D BAKE", Vector2(60, 30), 17, Color("e1a451"))
	_label("矿机动画与贴图校准", Vector2(58, 55), 38, Color("eef0eb"))
	_label("HELIX MINER  ·  STARTUP / WORKING / SHUTDOWN  ·  真实烘焙帧", Vector2(60, 108), 17, Color("a5b7bd"))
	_label("HELIX MINER  /  ORIGINAL MESH BAKE", Vector2(1438, 44), 19, Color("e8c58e"))
	_label("4 × 4 占地  ·  独立图层  ·  不接入生产结算", Vector2(1438, 78), 16, Color("9fb0b5"))

	stage = Stage.new()
	stage.name = "MinerStage"
	stage.position = Vector2(34, 160)
	stage.size = Vector2(1362, 738)
	stage.set("assets", assets)
	stage.view_changed.connect(_update_status)
	stage.state_changed.connect(func(_mode, _running): _update_status())
	add_child(stage)
	controls.append(stage)

	_label("播放与状态", Vector2(1438, 178), 23)
	playback_button = _button("暂停动画", Rect2(1438, 220, 198, 42), _toggle_playing)
	playback_button.name = "MinerPlayback"
	running_button = _button("请求停机", Rect2(1654, 220, 198, 42), _toggle_running)
	running_button.name = "MinerRunToggle"
	state_label = _label("", Vector2(1438, 276), 17, Color("bdd1cf"))
	frame_label = _label("", Vector2(1438, 305), 17, Color("a9b9be"))
	frame_slider = HSlider.new()
	frame_slider.name = "MinerFrameSlider"
	frame_slider.position = Vector2(1438, 338)
	frame_slider.size = Vector2(414, 24)
	frame_slider.min_value = 0
	frame_slider.max_value = 59
	frame_slider.step = 1
	frame_slider.value_changed.connect(func(value): seek_frame(roundi(value)))
	add_child(frame_slider)
	controls.append(frame_slider)
	_button("单帧 +1", Rect2(1438, 378, 126, 36), func(): seek_frame(int(stage.call("current_frame")) + 1))
	_button("重置视角", Rect2(1578, 378, 130, 36), reset_view)
	zoom_label = _label("115%", Vector2(1730, 386), 18, Color("e7b466"))
	for index in 4:
		var value: float = [0.5, 1.0, 1.5, 2.0][index]
		_button("%d%%" % int(value * 100), Rect2(1438 + index * 104, 430, 94, 34), func(): stage.call("set_zoom", value))

	_label("图层与标记", Vector2(1438, 486), 22)
	var layers := ["base", "shadow", "mask", "emission", "smoke", "ore", "ground"]
	var captions := ["主体烘焙", "独立阴影", "遮罩着色", "静态发光", "烟雾参考", "铁矿参考", "地面参考"]
	for index in layers.size():
		var id: String = layers[index]
		_check(captions[index], Vector2(1438 + (index % 2) * 208, 522 + (index / 2) * 38), true, func(enabled):
			(stage.get("visible_layers") as Dictionary)[id] = enabled
			stage.call("refresh")
		)
	_check("占地与锚点", Vector2(1438, 674), false, func(enabled): stage.set("show_anchors", enabled); stage.call("refresh"))
	_check("世界网格", Vector2(1650, 674), false, func(enabled): stage.set("show_grid", enabled); stage.call("refresh"))
	_label("日光亮度", Vector2(1438, 726), 17)
	var light := HSlider.new()
	light.position = Vector2(1548, 728)
	light.size = Vector2(304, 22)
	light.min_value = 0.25
	light.max_value = 1.0
	light.step = 0.05
	light.value = 1.0
	light.value_changed.connect(func(value): stage.set("daylight", value); stage.call("refresh"))
	add_child(light)
	controls.append(light)
	_label("遮罩色调", Vector2(1438, 770), 17)
	for index in 3:
		var color: Color = [Color("d4a65a"), Color("59a7b2"), Color("c86958")][index]
		var tint_button := _button(["铜金", "青蓝", "锈红"][index], Rect2(1548 + index * 102, 760, 92, 36), func(): stage.set("tint", color); stage.call("refresh"))
		tint_button.add_theme_color_override("font_color", color.lightened(0.28))
	_label("滚轮缩放 · 左/中键拖动 · 空格暂停", Vector2(1438, 834), 16, Color("dfc39a"))
	_label("状态切换会完整播放当前过渡，避免 3D 姿态跳变。", Vector2(1438, 862), 15, Color("9fb0b5"))

	_add_swatch("ground", Rect2(54, 936, 78, 78))
	_label("GROUND / ORIGINAL REFERENCE", Vector2(148, 944), 17, Color("e8dcc7"))
	_label("Rob Tuytel / Poly Haven · CC0", Vector2(148, 974), 15, Color("9fb0b5"))
	_add_swatch("ore", Rect2(456, 936, 78, 78))
	_label("ORE / ORIGINAL REFERENCE", Vector2(550, 944), 17, Color("e8dcc7"))
	_label("Malcolm Riley · CC BY 4.0", Vector2(550, 974), 15, Color("9fb0b5"))
	_add_swatch("smoke", Rect2(854, 936, 78, 78))
	_label("SMOKE / ORIGINAL REFERENCE", Vector2(948, 944), 17, Color("e8dcc7"))
	_label("rubberduck · CC0", Vector2(948, 974), 15, Color("9fb0b5"))
	_label("HELIX MINER  ·  baked clips are presentation-only  ·  fixed 1920 × 1080 design", Vector2(54, 1042), 15, Color("73868d"))
	_update_status()


func _add_swatch(id: String, rect: Rect2) -> void:
	var swatch := TextureRect.new()
	swatch.name = "Miner%sSwatch" % id.capitalize()
	swatch.position = rect.position
	swatch.size = rect.size
	swatch.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	swatch.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	swatch.texture = assets.texture(id, 0.0)
	add_child(swatch)
	controls.append(swatch)


func _label(text: String, position: Vector2, font_size: int, color: Color = Color("e5ebe6")) -> Label:
	var label := Label.new()
	label.text = text
	label.position = position
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	controls.append(label)
	return label


func _button(text: String, rect: Rect2, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_size_override("font_size", 17)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("23323a")
	normal.border_color = Color("455961")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(4)
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate()
	hover.bg_color = Color("32464d")
	button.add_theme_stylebox_override("hover", hover)
	button.pressed.connect(callback)
	add_child(button)
	controls.append(button)
	return button


func _check(text: String, position: Vector2, checked: bool, callback: Callable) -> void:
	var check := CheckButton.new()
	check.text = text
	check.position = position
	check.size = Vector2(198, 32)
	check.button_pressed = checked
	check.add_theme_font_size_override("font_size", 16)
	check.toggled.connect(callback)
	add_child(check)
	controls.append(check)


func _toggle_playing() -> void:
	stage.set("playing", not bool(stage.get("playing")))
	_update_status()


func _toggle_running() -> void:
	request_running(not bool(stage.get("running")))


func _update_status() -> void:
	if stage == null or frame_label == null or not assets.errors.is_empty():
		return
	var mode := str(stage.get("mode"))
	var frame := int(stage.call("current_frame"))
	var frame_count := int(stage.call("current_frame_count"))
	state_label.text = "%s  ·  请求%s" % [mode, "运行" if bool(stage.get("running")) else "停机"]
	frame_label.text = "%s  %02d / %02d  ·  %d fps" % [str(stage.call("current_clip")).to_upper(), frame, frame_count - 1, roundi(float(stage.call("current_fps")))]
	# Range changes can clamp the value and emit value_changed. A passive status
	# refresh must never scrub the animation or turn a stop request into a start.
	frame_slider.set_block_signals(true)
	frame_slider.max_value = maxi(0, frame_count - 1)
	frame_slider.set_value_no_signal(frame)
	frame_slider.set_block_signals(false)
	zoom_label.text = "%d%%" % roundi(float(stage.get("zoom")) * 100.0)
	playback_button.text = "暂停动画" if bool(stage.get("playing")) else "播放动画"
	running_button.text = "请求停机" if bool(stage.get("running")) else "请求启动"


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_toggle_playing()
		get_viewport().set_input_as_handled()
