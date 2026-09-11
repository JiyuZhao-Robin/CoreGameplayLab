extends Control

const Assets := preload("res://src/ui/art_calibration/calibration_assets.gd")
const Stage := preload("res://src/ui/art_calibration/calibration_stage.gd")
var assets := Assets.new()
var stage: Control
var frame_label: Label
var zoom_label: Label
var playback_button: Button
var state_button: Button
var frame_slider: HSlider
var controls: Array[Control] = []

func _enter_tree() -> void:
	# Also protect an editor F6 launch. The dedicated launcher additionally prevents
	# the autoload from reading saves in the first place using --no-persistence.
	var game := get_node_or_null("/root/Game")
	if game != null:
		game.set("persistence_enabled", false)
		game.set_process(false)

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	assets.load_pack()
	_build_ui()
	if not assets.errors.is_empty():
		frame_label.text = "资源加载失败：" + "; ".join(assets.errors)
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color("101619"))
	draw_rect(Rect2(36, 34, 5, 86), Color("d2a05c"))
	draw_line(Vector2(36, 142), Vector2(1884, 142), Color("334047"), 1)
	draw_rect(Rect2(1420, 160, 464, 868), Color("192226"))
	draw_rect(Rect2(36, 906, 1360, 122), Color("192226"))

func _build_ui() -> void:
	_label("HELIOS  /  ART LAB  01", Vector2(60, 30), 17, Color("d2a05c"))
	_label("工业美术标定", Vector2(58, 56), 38, Color("ecede7"))
	_label("CHEMICAL STAGER    /    分层动画 · 接地点 · 材质尺度", Vector2(60, 108), 17, Color("9daeb4"))
	_label("HURRICANE046  ×  NULLIUS", Vector2(1420, 48), 22, Color("e0c39c"))
	_label("参考库实图  /  独立预览场景", Vector2(1420, 86), 18, Color("9daeb4"))
	stage = Stage.new()
	stage.name = "CalibrationStage"
	stage.position = Vector2(36, 160)
	stage.size = Vector2(1360, 730)
	stage.assets = assets
	add_child(stage)
	controls.append(stage)
	stage.view_changed.connect(_update_status)
	_label("显示控制", Vector2(1444, 180), 24)
	playback_button = _button("暂停动画", Rect2(1444, 226, 198, 42), _toggle_playback)
	state_button = _button("运行 → 停机", Rect2(1660, 226, 198, 42), _toggle_running)
	frame_label = _label("", Vector2(1444, 282), 18, Color("a7b9bc"))
	frame_slider = HSlider.new()
	frame_slider.position = Vector2(1444, 314)
	frame_slider.size = Vector2(414, 26)
	frame_slider.max_value = 59
	frame_slider.step = 1
	frame_slider.value_changed.connect(_scrub)
	add_child(frame_slider)
	controls.append(frame_slider)
	_button("单帧 +1", Rect2(1444, 352, 126, 38), _step_frame)
	_button("重置视角", Rect2(1584, 352, 130, 38), _reset_view)
	zoom_label = _label("125%", Vector2(1734, 360), 19, Color("d2a05c"))
	for index in 4:
		var value: float = [0.5, 1.0, 1.5, 2.0][index]
		_button("%d%%" % int(value * 100), Rect2(1444 + index * 106, 404, 96, 36), func(): stage.set_zoom(value))
	_label("图层与标记", Vector2(1444, 460), 22)
	for index in 6:
		var id: String = ["base", "shadow", "mask", "emission", "smoke", "ore"][index]
		var title: String = ["建筑主体", "独立阴影", "等级色罩", "运行发光", "烟雾动画", "铁矿样本"][index]
		_check(title, Vector2(1444 + (index % 2) * 218, 500 + (index / 2) * 42), true, func(value): stage.visible_layers[id] = value; stage.refresh())
	_check("占地与锚点", Vector2(1444, 632), false, func(value): stage.show_anchors = value; stage.refresh())
	_check("世界格线", Vector2(1662, 632), false, func(value): stage.show_grid = value; stage.refresh())
	_label("环境亮度", Vector2(1444, 690), 18)
	var light := HSlider.new()
	light.position = Vector2(1574, 690)
	light.size = Vector2(280, 26)
	light.min_value = 0.2
	light.max_value = 1.0
	light.step = 0.05
	light.value = 1.0
	light.value_changed.connect(func(value): stage.daylight = value; stage.refresh())
	add_child(light)
	controls.append(light)
	_label("等级配色", Vector2(1444, 738), 18)
	for index in 3:
		var tint: Color = [Color("c48c42"), Color("519daf"), Color("af655c")][index]
		var button := _button(["铜金", "青蓝", "锈红"][index], Rect2(1574 + index * 96, 730, 88, 38), func(): stage.tint = tint; stage.refresh())
		button.add_theme_color_override("font_color", tint.lightened(0.3))
	_label("4 × 4 格占地  /  原图中心偏移独立换算", Vector2(1444, 796), 17, Color("9daeb4"))
	_label("主体 60 帧 · 阴影 1 帧 · 色罩 1 帧", Vector2(1444, 827), 17, Color("9daeb4"))
	_label("发光 60 帧 · 烟雾 30 帧", Vector2(1444, 858), 17, Color("9daeb4"))
	_label("滚轮缩放 · 拖动画布 · 空格暂停", Vector2(1444, 914), 18, Color("d8c1a0"))
	_label("显示样本由此面板驱动，不结算生产。", Vector2(1444, 954), 17, Color("9daeb4"))
	_add_swatch("ground", Rect2(54, 924, 84, 84))
	_label("AERIAL SAND", Vector2(154, 932), 19, Color("e7d5bb"))
	_label("Rob Tuytel / Poly Haven · CC0", Vector2(154, 968), 16, Color("9daeb4"))
	_add_swatch("ore", Rect2(498, 924, 84, 84))
	_label("CRUSHED IRON ORE", Vector2(598, 932), 19, Color("e7d5bb"))
	_label("Malcolm Riley · CC BY 4.0", Vector2(598, 968), 16, Color("9daeb4"))
	_add_swatch("smoke", Rect2(968, 924, 84, 84))
	_label("VOLUMETRIC SMOKE", Vector2(1068, 932), 19, Color("e7d5bb"))
	_label("rubberduck · CC0", Vector2(1068, 968), 16, Color("9daeb4"))
	_label("建筑：Hurricane046 · CC BY 4.0 · Nullius 图层处理     |     原图未修改；显示色调、缩放、播放节奏在本场景标定", Vector2(36, 1040), 16, Color("798b92"))
	_update_status()

func _add_swatch(id: String, rect: Rect2) -> void:
	var swatch := TextureRect.new()
	swatch.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	swatch.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	swatch.texture = assets.texture(id, 0.65)
	swatch.position = rect.position
	swatch.size = rect.size
	add_child(swatch)
	controls.append(swatch)

func _label(text: String, at: Vector2, font_size: int, color: Color = Color("e4e9e6")) -> Label:
	var label := Label.new()
	label.text = text
	label.position = at
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
	button.add_theme_font_size_override("font_size", 18)
	var style := StyleBoxFlat.new()
	style.bg_color = Color("29363a")
	style.border_color = Color("435257")
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("394b4e")
	button.add_theme_stylebox_override("hover", hover)
	button.pressed.connect(callback)
	add_child(button)
	controls.append(button)
	return button

func _check(text: String, at: Vector2, checked: bool, callback: Callable) -> void:
	var check := CheckButton.new()
	check.text = text
	check.position = at
	check.size = Vector2(205, 36)
	check.add_theme_font_size_override("font_size", 18)
	check.button_pressed = checked
	check.toggled.connect(callback)
	add_child(check)
	controls.append(check)

func _process(_delta: float) -> void:
	_update_status()

func _update_status() -> void:
	if frame_label == null or not assets.errors.is_empty():
		return
	var frame := assets.frame_index("base", stage.elapsed, stage.running)
	frame_label.text = "主体帧  %02d / 59    ·    30 fps" % frame
	frame_slider.set_value_no_signal(frame)
	zoom_label.text = "%d%%" % roundi(stage.zoom * 100)

func _toggle_playback() -> void:
	stage.playing = not stage.playing
	playback_button.text = "暂停动画" if stage.playing else "播放动画"

func _toggle_running() -> void:
	stage.running = not stage.running
	state_button.text = "运行 → 停机" if stage.running else "停机 → 运行"
	stage.refresh()
	_update_status()

func _scrub(frame: float) -> void:
	stage.playing = false
	stage.elapsed = frame / 30.0 + 0.00001
	playback_button.text = "播放动画"
	stage.refresh()
	_update_status()

func _step_frame() -> void:
	_scrub(posmod(assets.frame_index("base", stage.elapsed) + 1, 60))

func _reset_view() -> void:
	stage.zoom = 1.25
	stage.camera = Vector2.ZERO
	stage.refresh()
	_update_status()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_toggle_playback()
		get_viewport().set_input_as_handled()
