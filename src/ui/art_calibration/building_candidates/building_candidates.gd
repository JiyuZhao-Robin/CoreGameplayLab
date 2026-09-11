extends Control

const Stage = preload("res://src/ui/art_calibration/building_candidates/candidate_stage.gd")
const PACK := "res://assets/art_calibration/building_candidates/"
var candidates: Array = []
var selected_index := 0
var stage: Control
var textures: Dictionary = {}
var errors: Array[String] = []
var candidate_buttons: Array[Button] = []
var controls: Array[Control] = []
var title_label: Label
var role_label: Label
var description_label: Label
var frame_label: Label
var playback_button: Button
var previous_button: Button
var next_button: Button
var _game: Node
var _previous_persistence := false
var _previous_processing := false

func _enter_tree() -> void:
	_game = get_node_or_null("/root/Game")
	if _game != null:
		_previous_persistence = _game.persistence_enabled
		_previous_processing = _game.is_processing()
		_game.persistence_enabled = false
		_game.set_process(false)

func _exit_tree() -> void:
	if is_instance_valid(_game):
		_game.persistence_enabled = _previous_persistence
		_game.set_process(_previous_processing)

func _ready() -> void:
	var display_font := SystemFont.new()
	display_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC"])
	theme = Theme.new()
	theme.default_font = display_font
	theme.default_font_size = 20
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(PACK + "manifest.json"))
	if not manifest is Dictionary:
		errors.append("缺少候选素材清单")
	else:
		candidates = manifest.get("candidates", [])
	_build_ui()
	if not candidates.is_empty():
		var initial_index := 0
		for argument in OS.get_cmdline_user_args():
			if str(argument).begins_with("--candidate="):
				for index in candidates.size():
					if str(candidates[index].id) == str(argument).trim_prefix("--candidate="):
						initial_index = index
		select_candidate(initial_index)

func _draw() -> void:
	draw_rect(Rect2(0, 0, 1920, 1080), Color("101719"))
	draw_rect(Rect2(36, 32, 5, 91), Color("d2a05c"))
	draw_line(Vector2(36, 151), Vector2(1884, 151), Color("354248"), 1)
	draw_rect(Rect2(1420, 246, 464, 650), Color("1b2529"))
	draw_rect(Rect2(36, 920, 1848, 110), Color("1b2529"))

func _build_ui() -> void:
	_label("HELIOS  /  BUILDING STUDIES", Rect2(62, 28, 1100, 28), 18, Color("d2a05c"))
	title_label = _label("工业建筑候选", Rect2(60, 62, 1280, 55), 38)
	_label("逐项查看 · 电弧炉已确认并接入 · 其余候选待确认", Rect2(62, 119, 1250, 28), 18, Color("a8b8bd"))
	_label("HURRICANE046 / NULLIUS", Rect2(1434, 56, 430, 32), 22, Color("dfc49d"))
	_label("建筑外观评审", Rect2(1434, 101, 430, 28), 18, Color("a8b8bd"))
	for index in candidates.size():
		var button := _button("%02d  %s" % [index + 1, candidates[index].title], Rect2(36 + index * 374, 177, 352, 48), func(): select_candidate(index))
		button.toggle_mode = true
		candidate_buttons.append(button)
	stage = Stage.new()
	stage.position = Vector2(36, 246)
	stage.size = Vector2(1360, 650)
	add_child(stage)
	controls.append(stage)
	_label("建议用途", Rect2(1446, 271, 412, 35), 25, Color("d2a05c"))
	role_label = _label("", Rect2(1446, 320, 412, 75), 25)
	role_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description_label = _label("", Rect2(1446, 413, 408, 140), 21, Color("c1ced0"))
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	playback_button = _button("暂停动画", Rect2(1446, 579, 192, 46), _toggle_playback)
	_button("重播", Rect2(1654, 579, 202, 46), func(): stage.elapsed = 0.0; stage.refresh())
	frame_label = _label("", Rect2(1446, 641, 410, 32), 18, Color("9cb6b7"))
	_button("缩小", Rect2(1446, 698, 124, 44), func(): _zoom(-0.1))
	_button("原比例", Rect2(1588, 698, 124, 44), func(): stage.zoom = 1.0; stage.refresh())
	_button("放大", Rect2(1730, 698, 126, 44), func(): _zoom(0.1))
	var footprint := CheckButton.new()
	footprint.text = "显示预览占地"
	footprint.position = Vector2(1446, 782)
	footprint.size = Vector2(410, 46)
	footprint.button_pressed = true
	footprint.toggled.connect(func(value: bool): stage.show_footprint = value; stage.refresh())
	add_child(footprint)
	controls.append(footprint)
	previous_button = _button("← 上一个", Rect2(60, 948, 190, 48), func(): select_candidate(selected_index - 1))
	next_button = _button("下一个 →", Rect2(268, 948, 190, 48), func(): select_candidate(selected_index + 1))
	_label("先确认外观与用途，再接入正式建筑。", Rect2(504, 939, 1240, 35), 24)
	_label("运行、停机和部署幽灵同屏对照；预览占地不会改变游戏规则。", Rect2(504, 984, 1300, 28), 18, Color("a8b8bd"))

func select_candidate(index: int) -> void:
	if candidates.is_empty():
		return
	selected_index = posmod(index, candidates.size())
	# Release old stage references before loading the next set of four atlases.
	stage.set_candidate({}, {})
	textures.clear()
	errors.clear()
	var candidate: Dictionary = candidates[selected_index]
	for entry in candidate.layers:
		var path: String = PACK + str(entry.texture)
		var texture := ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
		if texture == null:
			errors.append("无法加载 " + path)
		else:
			textures[entry.id] = texture
	stage.set_candidate(candidate, textures.duplicate())
	stage.zoom = 1.0
	title_label.text = "%02d  /  %s" % [selected_index + 1, candidate.title]
	get_window().title = "工业建筑候选 · " + title_label.text
	role_label.text = candidate.role
	description_label.text = candidate.recommendation if errors.is_empty() else "\n".join(errors)
	if str(candidate.id) == "arc-furnace" and errors.is_empty():
		description_label.text = "已确认：用于原生电弧熔炉和 DSP 电弧熔炉。正式占地和配方保持现有规则。"
	for button_index in candidate_buttons.size():
		candidate_buttons[button_index].set_pressed_no_signal(button_index == selected_index)
	stage.refresh()

func _process(_delta: float) -> void:
	if stage != null and not stage.candidate.is_empty():
		var count := int(stage.layer("base").frame_count)
		frame_label.text = "动画 %d / %d 帧    ·    视图 %d%%" % [stage.frame_index("base") + 1, count, roundi(stage.zoom * 100)]

func _toggle_playback() -> void:
	stage.playing = not stage.playing
	playback_button.text = "暂停动画" if stage.playing else "继续动画"

func _zoom(delta: float) -> void:
	stage.zoom = clampf(stage.zoom + delta, 0.65, 1.25)
	stage.refresh()

func _label(text: String, rect: Rect2, size_px: int, color: Color = Color("edf0e9")) -> Label:
	var label := Label.new()
	label.text = text
	label.position = rect.position
	label.size = rect.size
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_color_override("font_color", color)
	add_child(label)
	controls.append(label)
	return label

func _button(text: String, rect: Rect2, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.position = rect.position
	button.size = rect.size
	button.pressed.connect(action)
	button.add_theme_color_override("font_color", Color("e3e6dd"))
	var box := StyleBoxFlat.new()
	box.bg_color = Color("263238")
	box.border_color = Color("526066")
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	button.add_theme_stylebox_override("normal", box)
	var active := box.duplicate()
	active.bg_color = Color("665236")
	active.border_color = Color("caa368")
	button.add_theme_stylebox_override("pressed", active)
	button.add_theme_stylebox_override("hover", active)
	add_child(button)
	controls.append(button)
	return button
