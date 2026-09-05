extends SceneTree

## Focused protocol-v1 UI contract. This fixture creates only presentation
## objects; it never reaches through the workspace boundary to Game or state.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node.new()
	host.name = "FactoryWorkspaceUiTestHost"
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.size = Vector2(1280, 720)
	host.add_child(workspace)
	workspace.apply_snapshot(_fixture_snapshot())
	await _settle()

	var intents: Array = []
	var refreshes: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	workspace.refresh_requested.connect(func(world_id: String) -> void: refreshes.append(world_id))

	_test_initial_render(workspace)
	_test_construction_intent(workspace, intents)
	_test_recipe_change_intent(workspace, intents)
	_test_cargo_connection_intent(workspace, intents)
	_test_power_connection_intent(workspace, intents)
	_test_location_transfer_intents(workspace, intents)
	_test_result_feedback_and_reduced_motion(workspace, refreshes)
	_test_keyboard_canvas_action(workspace, intents)
	await _test_mouse_hit_priorities(workspace, intents)
	var first_instance_command_id := _emit_rebuild_probe(workspace, intents)

	workspace.queue_free()
	await process_frame
	await _test_rebuilt_workspace_command_id(host, first_instance_command_id)
	host.queue_free()
	await process_frame
	_finish()


func _test_initial_render(workspace) -> void:
	var building_palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	var source_selector := workspace.find_child("ConnectionSource", true, false) as OptionButton
	var target_selector := workspace.find_child("ConnectionTarget", true, false) as OptionButton
	var canvas = workspace.canvas()
	_check(building_palette != null and building_palette.item_count == 4, "Factory workspace renders the versioned construction palette")
	_check(source_selector != null and target_selector != null and source_selector.item_count == 5 and target_selector.item_count == 5, "Factory workspace renders deterministic entity connection selectors")
	_check(canvas != null and canvas.selected_node_id().is_empty() and canvas.selected_link_id().is_empty(), "Factory canvas starts with an empty presentation-only selection")


func _test_construction_intent(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_solar_array")
	workspace._on_tile_hovered(Vector2i(100, 80))
	workspace._on_tile_selected(Vector2i(100, 80))
	_check(not intents.is_empty(), "placing a preview footprint emits an intent instead of mutating Factory state")
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		int(intent.get("protocol_version", 0)) == 1
		and str(intent.get("kind", "")) == "QUEUE_CONSTRUCTION"
		and str(intent.get("world_id", "")) == "ui-grid"
		and int(intent.get("base_topology_revision", -1)) == 17
		and int(intent.get("base_runtime_revision", -1)) == 9
		and str(payload.get("definition_id", "")) == "grid_solar_array"
		and int((payload.get("origin", {}) as Dictionary).get("x", -1)) == 100,
		"construction intent preserves protocol, immutable revision, and selected footprint origin"
	)


func _test_recipe_change_intent(workspace, intents: Array) -> void:
	workspace._on_entity_selected(_snapshot_entity(workspace, "smelter-a"))
	var selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	var apply_button := workspace.find_child("ApplyEntityRecipe", true, false) as Button
	_check(selector != null and apply_button != null, "machine inspector exposes recipe reconfiguration controls")
	if selector == null or apply_button == null:
		return
	_select_metadata(selector, "grid_refine_copper")
	apply_button.pressed.emit()
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(str(intent.get("kind", "")) == "SET_RECIPE" and str(payload.get("entity_id", "")) == "smelter-a" and str(payload.get("recipe_id", "")) == "grid_refine_copper", "machine inspector emits only a versioned SET_RECIPE intent")


func _test_cargo_connection_intent(workspace, intents: Array) -> void:
	workspace._set_connection_mode("CARGO")
	var source_selector := workspace.find_child("ConnectionSource", true, false) as OptionButton
	var target_selector := workspace.find_child("ConnectionTarget", true, false) as OptionButton
	_select_metadata(source_selector, "mine-a")
	_select_metadata(target_selector, "smelter-a")
	var connect_button := workspace.find_child("CreateConnection", true, false) as Button
	var intent_count_before := intents.size()
	if connect_button != null:
		connect_button.pressed.emit()
	_check(connect_button != null and intents.size() == intent_count_before + 1, "real Create Connection press emits exactly one CARGO intent")
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		str(intent.get("kind", "")) == "CONNECT_ENTITIES"
		and str(payload.get("link_kind", "")) == "CARGO"
		and str(payload.get("source_id", "")) == "mine-a"
		and str(payload.get("target_id", "")) == "smelter-a"
		and str(payload.get("item_id", "")) == "iron_ore",
		"compatible entity ports produce a versioned CARGO connection intent"
	)


func _test_power_connection_intent(workspace, intents: Array) -> void:
	workspace._set_connection_mode("POWER")
	var source_selector := workspace.find_child("ConnectionSource", true, false) as OptionButton
	var target_selector := workspace.find_child("ConnectionTarget", true, false) as OptionButton
	_select_metadata(source_selector, "power-a")
	_select_metadata(target_selector, "mine-a")
	var connect_button := workspace.find_child("CreateConnection", true, false) as Button
	var intent_count_before := intents.size()
	if connect_button != null:
		connect_button.pressed.emit()
	_check(connect_button != null and intents.size() == intent_count_before + 1, "real Create Connection press emits exactly one POWER intent")
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		str(intent.get("kind", "")) == "CONNECT_ENTITIES"
		and str(payload.get("link_kind", "")) == "POWER"
		and str(payload.get("source_id", "")) == "power-a"
		and str(payload.get("target_id", "")) == "mine-a"
		and str(payload.get("item_id", "unexpected")) == "",
		"power producer and consumer ports produce a versioned POWER connection intent"
	)


func _test_location_transfer_intents(workspace, intents: Array) -> void:
	workspace._request_storage_transfer("EXPORT_TO_LOCATION", "storage-a", "iron_ingot", 3)
	var export_intent: Dictionary = intents.back() as Dictionary
	workspace._request_storage_transfer("IMPORT_FROM_LOCATION", "storage-a", "iron_ingot", 2)
	var import_intent: Dictionary = intents.back() as Dictionary
	_check(
		str(export_intent.get("kind", "")) == "EXPORT_TO_LOCATION"
		and str((export_intent.get("payload", {}) as Dictionary).get("storage_id", "")) == "storage-a"
		and int((export_intent.get("payload", {}) as Dictionary).get("quantity", 0)) == 3
		and str(import_intent.get("kind", "")) == "IMPORT_FROM_LOCATION"
		and int((import_intent.get("payload", {}) as Dictionary).get("quantity", 0)) == 2,
		"same-location transfer controls construct only versioned import/export intents"
	)


func _test_result_feedback_and_reduced_motion(workspace, refreshes: Array) -> void:
	workspace.apply_command_result({
		"accepted":false,
		"protocol_version":1,
		"world_id":"ui-grid",
		"reason_code":"STALE_TOPOLOGY",
		"message":"Factory layout changed; refresh before retrying."
	})
	var feedback := workspace.find_child("FactoryCommandFeedback", true, false) as Label
	var localization := get_root().get_node_or_null("I18n")
	var expected_rejection := str(localization.call("t", "factory.reason.stale_topology")) if localization != null else "Factory layout changed; refresh before retrying."
	_check(feedback != null and feedback.text.contains("[STALE_TOPOLOGY]") and feedback.text.contains(expected_rejection), "structured localized command rejection remains visible in Factory feedback")
	_check(refreshes.size() == 1 and str(refreshes[0]) == "ui-grid", "command results request a fresh immutable snapshot from the host")
	workspace.set_reduced_motion(true)
	_check(bool(workspace.canvas().get("_reduced_motion")), "reduced-motion setter propagates to the animated Factory canvas")


func _test_keyboard_canvas_action(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_solar_array")
	var canvas = workspace.canvas()
	var right := InputEventKey.new()
	right.pressed = true
	right.keycode = KEY_RIGHT
	canvas._on_gui_input(right)
	var confirm := InputEventKey.new()
	confirm.pressed = true
	confirm.keycode = KEY_ENTER
	canvas._on_gui_input(confirm)
	var intent: Dictionary = intents.back() as Dictionary
	var payload: Dictionary = intent.get("payload", {})
	_check(
		canvas.get("_keyboard_tile") == Vector2i.RIGHT
		and str(intent.get("kind", "")) == "QUEUE_CONSTRUCTION"
		and int((payload.get("origin", {}) as Dictionary).get("x", -1)) == 1,
		"focused Factory canvas supports arrow-key tile movement and Enter placement"
	)


func _test_mouse_hit_priorities(workspace, intents: Array) -> void:
	var palette := workspace.find_child("BuildingPalette", true, false) as OptionButton
	_select_metadata(palette, "grid_surface_mine")
	var canvas = workspace.canvas()
	# The preceding keyboard case centers its tile. Mouse hit coordinates below
	# deliberately exercise world-space field/order rectangles at the origin.
	canvas.reset_camera()
	await _force_canvas_draw(canvas)
	var extractor_tile := Vector2i(16, 16)
	var extractor_point := Vector2(64, 64)
	canvas._on_gui_input(_mouse_motion(extractor_point))
	canvas._on_gui_input(_left_click(extractor_point))
	var extractor_intent: Dictionary = intents.back() as Dictionary
	var extractor_payload: Dictionary = extractor_intent.get("payload", {})
	_check(
		str(extractor_intent.get("kind", "")) == "QUEUE_CONSTRUCTION"
		and Vector2i(int((extractor_payload.get("origin", {}) as Dictionary).get("x", -1)), int((extractor_payload.get("origin", {}) as Dictionary).get("y", -1))) == extractor_tile
		and str((workspace.get("_selection") as Dictionary).get("kind", "")) != "RESOURCE_FIELD",
		"a real mouse click on an extractor preview over a resource field emits construction instead of selecting the field"
	)
	var order_point := Vector2(104, 104)
	canvas._on_gui_input(_mouse_motion(order_point))
	canvas._on_gui_input(_left_click(order_point))
	var selection: Dictionary = workspace.get("_selection") as Dictionary
	_check(
		str(selection.get("kind", "")) == "CONSTRUCTION_ORDER" and str(selection.get("id", "")) == "build-iron",
		"a real mouse click selects a construction order that overlays a resource field"
	)


func _emit_rebuild_probe(workspace, intents: Array) -> String:
	workspace._request_storage_transfer("IMPORT_FROM_LOCATION", "storage-a", "iron_ingot", 1)
	_check(not intents.is_empty(), "first workspace emits a receipt-bearing command before rebuild")
	return str((intents.back() as Dictionary).get("command_id", ""))


func _test_rebuilt_workspace_command_id(host: Node, first_command_id: String) -> void:
	var rebuilt = WorkspaceScript.new()
	rebuilt.size = Vector2(1280, 720)
	host.add_child(rebuilt)
	rebuilt.apply_snapshot(_fixture_snapshot())
	await _settle()
	var rebuilt_intents: Array = []
	rebuilt.command_requested.connect(func(intent: Dictionary) -> void: rebuilt_intents.append(intent.duplicate(true)))
	rebuilt._request_storage_transfer("IMPORT_FROM_LOCATION", "storage-a", "iron_ingot", 1)
	var rebuilt_command_id := str((rebuilt_intents.back() as Dictionary).get("command_id", "")) if not rebuilt_intents.is_empty() else ""
	_check(
		not first_command_id.is_empty() and not rebuilt_command_id.is_empty() and first_command_id != rebuilt_command_id,
		"command IDs remain process-unique after a workspace is destroyed and rebuilt"
	)
	rebuilt.queue_free()
	await process_frame


func _force_canvas_draw(canvas) -> void:
	canvas.queue_redraw()
	RenderingServer.force_draw(false)
	await process_frame


func _mouse_motion(point: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = point
	return event


func _left_click(point: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = point
	return event


func _select_metadata(options: OptionButton, value: String) -> void:
	var index := -1
	for candidate in range(options.item_count):
		if str(options.get_item_metadata(candidate)) == value:
			index = candidate
			break
	_check(index >= 0, "test fixture exposes selector metadata %s" % value)
	if index < 0:
		return
	options.select(index)
	options.item_selected.emit(index)


func _fixture_snapshot() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_schema_version":3,
		"world_id":"ui-grid",
		"location_id":"earth_orbit",
		"topology_revision":17,
		"runtime_revision":9,
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":256, "y":256}},
		"resource_fields":[
			{"id":"iron-field", "resource_id":"iron_ore", "resource_category":"solid", "resource_color":"#B45F45", "grade":1.0, "potential_density":0.25, "footprint":{"origin":{"x":12, "y":12}, "size":{"x":24, "y":24}}, "ports":{"inputs":[], "outputs":[], "accepts_power":false}}
		],
		"entities":[
			_entity("power-a", "POWER", "Solar Array", Vector2i(12, 48), {"inputs":[], "outputs":[], "accepts_power":false, "provides_power":true}),
			_entity("mine-a", "EXTRACTOR", "Surface Mine", Vector2i(40, 12), {"inputs":[], "outputs":["iron_ore"], "accepts_power":true, "provides_power":false}),
			_entity("smelter-a", "MACHINE", "Arc Smelter", Vector2i(70, 12), {"inputs":["iron_ore"], "outputs":["iron_ingot"], "accepts_power":true, "provides_power":false}, {}, "grid_arc_smelter", "grid_refine_iron"),
			_entity("storage-a", "STORAGE", "Bulk Depot", Vector2i(110, 12), {"inputs":["*"], "outputs":["*"], "accepts_power":false, "provides_power":false}, {"iron_ingot":5})
		],
		"links":[],
		"construction_orders":[
			{"id":"build-iron", "entity_id":"entity-build-iron", "definition_id":"grid_surface_mine", "recipe_id":"", "footprint":{"origin":{"x":24, "y":24}, "size":{"x":6, "y":6}}, "required_items":{"iron_ingot":2}, "delivered_items":{}, "work_required":5.0, "work_done":0.0, "progress":0.0, "priority":50, "status":"WAITING_MATERIALS"}
		],
		"location_inventory":{"items":{"iron_ingot":12}},
		"palette":{
			"buildings":[
				{"id":"grid_solar_array", "name":"Surface Solar Array", "kind":"POWER", "footprint":{"width":8, "height":8}, "recipe_ids":[]},
				{"id":"grid_surface_mine", "name":"Surface Mine", "kind":"EXTRACTOR", "footprint":{"width":3, "height":3}, "recipe_ids":[]},
				{"id":"grid_arc_smelter", "name":"Arc Smelter", "kind":"MACHINE", "footprint":{"width":16, "height":12}, "recipe_ids":["grid_refine_iron", "grid_refine_copper"]}
			],
			"recipes":[
				{"id":"grid_refine_iron", "name":"Grid Iron Refining", "duration_seconds":2.0, "inputs":[], "outputs":[]},
				{"id":"grid_refine_copper", "name":"Grid Copper Refining", "duration_seconds":6.0, "inputs":[], "outputs":[]}
			]
			}
	}


func _entity(entity_id: String, kind: String, title: String, origin: Vector2i, ports: Dictionary, inventory: Dictionary = {}, definition_id: String = "", recipe_id: String = "") -> Dictionary:
	return {
		"id":entity_id,
		"node_kind":kind,
		"name":title,
		"definition_id":definition_id if not definition_id.is_empty() else entity_id,
		"recipe_id":recipe_id,
		"footprint":{"origin":{"x":origin.x, "y":origin.y}, "size":{"x":8, "y":8}},
		"status":"READY",
		"ports":ports,
		"inputs":{},
		"outputs":{},
		"inventory":inventory,
		"power_factor":1.0,
		"actual_rate":0.0
	}


func _snapshot_entity(workspace, entity_id: String) -> Dictionary:
	for entity_value in (workspace.get("_snapshot") as Dictionary).get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity.duplicate(true)
	return {}


func _settle() -> void:
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_WORKSPACE_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
