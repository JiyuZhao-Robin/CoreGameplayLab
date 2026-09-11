extends SceneTree

const Scene = preload("res://src/ui/art_calibration/building_candidates/building_candidates.tscn")
const OUTPUT := "res://artifacts/ui/building-candidates/"
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Candidate visual test requires a real renderer")
		quit(1)
		return
	var game := root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	var original_state := JSON.stringify(game.state.to_dictionary())
	root.size = Vector2i(3840, 2160)
	var scene := Scene.instantiate()
	root.add_child(scene)
	await process_frame
	_check(scene.candidates.size() == 5, "five independent candidates")
	_check(not game.is_processing() and not game.persistence_enabled, "preview isolates gameplay")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var previous_texture: WeakRef
	for index in scene.candidates.size():
		scene.candidate_buttons[index].pressed.emit()
		_check(scene.selected_index == index and scene.errors.is_empty(), "candidate button loads local assets")
		_check(scene.textures.size() == 4, "only four current atlases retained")
		if previous_texture != null:
			_check(previous_texture.get_ref() == null, "previous candidate atlas released")
		previous_texture = weakref(scene.textures["base"])
		scene.stage.playing = false
		scene.stage.elapsed = 0.0
		scene.stage.refresh()
		await _settle()
		var before := root.get_texture().get_image()
		scene.stage.elapsed = 0.53
		scene.stage.refresh()
		await _settle()
		var after := root.get_texture().get_image()
		_check(after.get_size() == Vector2i(3840,2160), "actual 4K render")
		var left := Rect2i(72, 600, 900, 1100)
		var middle := Rect2i(990, 600, 880, 1100)
		_check(before.get_region(left).get_data() != after.get_region(left).get_data(), "working animation changes actual pixels")
		_check(before.get_region(middle).get_data() == after.get_region(middle).get_data(), "stopped comparison stays static")
		for control in scene.controls:
			_check(Rect2(Vector2.ZERO, Vector2(1920,1080)).encloses(control.get_rect()), "control fits fixed design canvas")
		var path: String = OUTPUT + "%02d-%s.png" % [index + 1, scene.candidates[index].id]
		_check(after.save_png(ProjectSettings.globalize_path(path)) == OK, "capture " + path)
		var preview := after.duplicate() as Image
		preview.resize(1920,1080,Image.INTERPOLATE_LANCZOS)
		_check(preview.save_jpg(ProjectSettings.globalize_path(path.trim_suffix(".png") + ".jpg"),0.92) == OK, "review preview " + path)
		print("CAPTURE: " + path)
		scene.playback_button.pressed.emit()
		var time_before: float = scene.stage.elapsed
		scene.stage._process(0.1)
		_check(scene.stage.elapsed > time_before, "play button advances animation")
		scene.playback_button.pressed.emit()
		time_before = scene.stage.elapsed
		scene.stage._process(0.1)
		_check(scene.stage.elapsed == time_before, "pause button freezes animation")
	scene.next_button.pressed.emit()
	_check(scene.selected_index == 0, "next wraps through every candidate")
	scene.previous_button.pressed.emit()
	_check(scene.selected_index == 4, "previous wraps backwards")
	_check(JSON.stringify(game.state.to_dictionary()) == original_state, "gallery never changes economic state")
	scene.queue_free()
	await process_frame
	_check(not game.persistence_enabled and not game.is_processing(), "leaving restores caller settings")
	if failures.is_empty():
		print("BUILDING_CANDIDATES_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)

func _settle() -> void:
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
