extends SceneTree

## Focused contract for the Research GraphEdit camera. The research page owns
## its workspace size; this test verifies that graph camera state is neither a
## global UI-scale surrogate nor reset by routine model refreshes.

const ResearchTreeViewScript = preload("res://src/ui/components/research_tree_view.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []
var _host: Control
var _view: GraphEdit
var _original_ui_scale := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_original_ui_scale = UiTokens.ui_scale()
	root.size = Vector2i(1920, 1080)
	_host = Control.new()
	_host.name = "ResearchCameraContractHost"
	_host.position = Vector2(20.0, 300.0)
	_host.size = Vector2(1880.0, 650.0)
	root.add_child(_host)
	_view = ResearchTreeViewScript.new()
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_host.add_child(_view)
	await _frames(2)
	_view.configure(_model())
	await _frames(3)
	_assert_initial_camera()
	_assert_fallback_initial_preference()
	_assert_restore_and_scale_independence()
	await _assert_configure_stability()
	await _assert_project_focus()
	_view.queue_free()
	_host.queue_free()
	await process_frame
	UiTokens.set_ui_scale(_original_ui_scale)
	_finish()


func _assert_initial_camera() -> void:
	var active := _view.get_node_or_null(NodePath("research_active")) as GraphNode
	_check(_view.custom_minimum_size.y < 640.0, "Research graph no longer forces a 640px page-level minimum height")
	_check(active != null and active.selected and _camera_centres_node(active), "first visible research state centres the active project at a readable default zoom")
	_check(is_equal_approx(_view.zoom, 0.88) and _view.zoom > _view.zoom_min, "initial camera uses a readable authored zoom instead of auto-fitting the full graph")


func _assert_fallback_initial_preference() -> void:
	var detached_view := ResearchTreeViewScript.new()
	detached_view.set("_node_data", {
		"develop_asteroid_cruiser":{"id":"develop_asteroid_cruiser", "lane":"SHIP_DEVELOPMENT", "status_id":"LOCKED", "dependencies":[]},
		"research_initial":{"id":"research_initial", "lane":"TECHNOLOGY", "status_id":"LOCKED", "dependencies":[]}
	})
	_check(String(detached_view.call("_initial_project_id")) == "research_initial", "fresh locked research prefers the initial technology lane over an alphabetically earlier ship-development project")
	detached_view.free()


func _assert_restore_and_scale_independence() -> void:
	var requested := Vector3(184.5, -72.25, 1.14)
	_view.call("restore_camera", requested)
	_check(_camera_state_matches(requested), "restore_camera applies exact local x/y scroll and clamped zoom")
	UiTokens.set_ui_scale(1.5)
	_check(_camera_state_matches(requested) and _view.scale.is_equal_approx(Vector2.ONE), "player UI scale does not alter the Research GraphEdit camera transform")


func _assert_configure_stability() -> void:
	var before := _view.call("camera_state") as Vector3
	var active_before := _view.get_node_or_null(NodePath("research_active")) as GraphNode
	_view.configure(_model())
	await _frames(2)
	var active_after_same := _view.get_node_or_null(NodePath("research_active")) as GraphNode
	_check(_camera_state_matches(before) and active_before == active_after_same, "identical configure calls preserve both camera and existing graph nodes")
	var changed_model := _model()
	var changed_nodes := changed_model.get("nodes", []) as Array
	var active_data := changed_nodes[1] as Dictionary
	active_data["status_id"] = "PAUSED"
	active_data["status"] = "PAUSED"
	changed_model["nodes"] = changed_nodes
	_view.configure(changed_model)
	await _frames(2)
	var active_after_change := _view.get_node_or_null(NodePath("research_active")) as GraphNode
	_check(
		_camera_state_matches(before) and active_after_change != null and active_after_change.selected,
		"changed model refresh preserves the selected project and exact camera rather than resetting to origin (%s; selected=%s)" % [_camera_diagnostic(before), str(active_after_change != null and active_after_change.selected)]
	)


func _assert_project_focus() -> void:
	var target := _view.get_node_or_null(NodePath("research_ship_design")) as GraphNode
	var camera_before_invalid := _view.call("camera_state") as Vector3
	_check(not bool(_view.call("focus_project", "missing_project")) and _camera_state_matches(camera_before_invalid), "focus_project rejects unknown IDs without disturbing the player camera")
	var focused := bool(_view.call("focus_project", "research_ship_design"))
	await _frames(2)
	_check(
		focused and target != null and target.selected and _camera_centres_node(target),
		"focus_project selects and centres the corresponding graph node (%s; selected=%s)" % [_camera_diagnostic_for_node(target), str(target != null and target.selected)]
	)


func _camera_centres_node(node: GraphNode) -> bool:
	var node_size := node.size if node.size.x > 0.0 and node.size.y > 0.0 else node.custom_minimum_size
	var expected_scroll := (node.position_offset + node_size * 0.5) * _view.zoom - _view.size * 0.5
	return _view.scroll_offset.is_equal_approx(expected_scroll)


func _camera_state_matches(expected: Vector3) -> bool:
	var actual := _view.call("camera_state") as Vector3
	return is_equal_approx(actual.x, expected.x) and is_equal_approx(actual.y, expected.y) and is_equal_approx(actual.z, expected.z)


func _camera_diagnostic(expected: Vector3) -> String:
	var actual := _view.call("camera_state") as Vector3
	return "expected=(%.2f, %.2f, %.2f) actual=(%.2f, %.2f, %.2f)" % [expected.x, expected.y, expected.z, actual.x, actual.y, actual.z]


func _camera_diagnostic_for_node(node: GraphNode) -> String:
	if node == null:
		return "target=<missing>"
	var node_size := node.size if node.size.x > 0.0 and node.size.y > 0.0 else node.custom_minimum_size
	var expected := (node.position_offset + node_size * 0.5) * _view.zoom - _view.size * 0.5
	return _camera_diagnostic(Vector3(expected.x, expected.y, _view.zoom))


func _model() -> Dictionary:
	return {
		"core_title":"RESEARCH CORE",
		"core_subtitle":"Command research lattice",
		"core_summary":"One active programme",
		"status_format":"%s",
		"nodes":[
			{
				"id":"research_bootstrap",
				"title":"Industrial Theory",
				"summary":"Opening programme",
				"status_id":"AVAILABLE",
				"status":"AVAILABLE",
				"lane":"TECHNOLOGY",
				"dependencies":[],
				"action_mode":"START",
				"action_enabled":true,
				"action_label":"START"
			},
			{
				"id":"research_active",
				"title":"Orbital Metallurgy",
				"summary":"Current programme",
				"status_id":"RUNNING",
				"status":"RUNNING",
				"lane":"TECHNOLOGY",
				"dependencies":["research_bootstrap"],
				"action_mode":"PAUSE",
				"action_enabled":true,
				"action_label":"PAUSE"
			},
			{
				"id":"research_ship_design",
				"title":"Pathfinder Architecture",
				"summary":"Ship engineering programme",
				"status_id":"AVAILABLE",
				"status":"AVAILABLE",
				"lane":"SHIP",
				"dependencies":["research_active"],
				"action_mode":"START",
				"action_enabled":true,
				"action_label":"START"
			}
		]
	}


func _frames(count: int) -> void:
	for _frame in count:
		await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("RESEARCH_CAMERA_CONTRACT_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
