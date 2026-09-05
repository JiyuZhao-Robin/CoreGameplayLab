extends SceneTree

## Godot 4.6 exits before running this repository's 4.7-declared main scene.
## This small runner keeps Node-based scene tests executable through --script
## while preserving the project's real autoloads and SceneTree lifecycle.


func _initialize() -> void:
	var scene_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--test-scene="):
			scene_path = argument.trim_prefix("--test-scene=")
			break
	if scene_path.is_empty():
		push_error("FAIL: scene_test_runner requires --test-scene=res://path/to/test.tscn")
		quit(2)
		return
	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null:
		push_error("FAIL: unable to load scene test: %s" % scene_path)
		quit(2)
		return
	var test_node := packed_scene.instantiate()
	if test_node == null:
		push_error("FAIL: unable to instantiate scene test: %s" % scene_path)
		quit(2)
		return
	root.add_child(test_node)
