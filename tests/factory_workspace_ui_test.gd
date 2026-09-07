extends SceneTree

## Fixture-only UI contract. The workspace must remain a pure snapshot renderer
## and intent emitter.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture := _snapshot_fixture()
	var original_signature := JSON.stringify(fixture)
	var host := Control.new()
	host.size = Vector2(1280, 720)
	get_root().add_child(host)
	var workspace: Control = WorkspaceScript.new()
	workspace.size = host.size
	host.add_child(workspace)
	workspace.apply_snapshot(fixture)
	await process_frame
	await process_frame

	_check(workspace.find_child("FactoryPalettePane", true, false) != null and workspace.find_child("FactoryCanvasSurface", true, false) != null and workspace.find_child("FactoryInspectorPane", true, false) != null, "workspace mounts DSP-style construction, canvas, and inspector panes")
	_check(workspace._canvas._node_rects.size() == 4 and workspace._canvas._link_hit_rects.size() == 2, "canvas deterministically draws resource fields, entities, and CARGO/POWER connections")
	_check(workspace.find_child("FactoryPalette_grid_surface_mine", true, false) != null, "definition-backed construction palette is rendered")
	var world_power_row := workspace.find_child("FactoryInspectorPower", true, false) as HBoxContainer
	var world_power_value := world_power_row.get_child(1) as Label if world_power_row != null and world_power_row.get_child_count() > 1 else null
	var inspector_pane := workspace.find_child("FactoryInspectorPane", true, false) as Control
	_check(world_power_value != null and world_power_value.text.contains("100") and world_power_value.size.x > 0.0 and inspector_pane != null and inspector_pane.get_global_rect().encloses(world_power_value.get_global_rect()), "world inspector renders its power value inside the visible metric column")

	var emitted: Array = []
	workspace.command_intent.connect(func(intent: Dictionary) -> void: emitted.append(intent.duplicate(true)))
	workspace._select_building("grid_surface_mine", _building("grid_surface_mine"))
	var resource_hit: Rect2 = workspace._canvas._node_rects.get("iron-field", {}).get("rect", Rect2())
	workspace._canvas._select_at(resource_hit.get_center())
	_check(emitted.size() == 1 and _has_valid_envelope(emitted[0] as Dictionary, "QUEUE_CONSTRUCTION") and (emitted[0] as Dictionary).get("payload", {}).get("origin", {}) == {"x":40, "y":40}, "placement mode turns a click on resource terrain into a versioned queue-construction intent")
	workspace._cancel_placement()

	workspace._on_entity_selected(_entity("mine"))
	await process_frame
	_check(workspace.find_child("FactoryInspectorStatus", true, false) != null and workspace.find_child("FactoryInspectorBlocker", true, false) != null and workspace.find_child("FactoryInspectorThroughput", true, false) != null and workspace.find_child("FactoryInspectorInventory", true, false) != null and workspace.find_child("FactoryInspectorPower", true, false) != null, "entity inspector exposes status, blocker, throughput, I/O inventory, and power")
	var stable_target := workspace.find_child("FactoryConnectionTarget", true, false) as OptionButton
	stable_target.grab_focus()
	var runtime_update := fixture.duplicate(true)
	runtime_update["runtime_revision"] = 4
	workspace.apply_snapshot(runtime_update)
	await process_frame
	_check(is_instance_valid(stable_target) and workspace.find_child("FactoryConnectionTarget", true, false) == stable_target, "runtime polling preserves focused Inspector controls instead of rebuilding them mid-interaction")
	workspace.request_connection("mine", "smelter", "CARGO", "iron_ore", 2.0)
	_check(emitted.size() == 2 and _has_valid_envelope(emitted[1] as Dictionary, "CONNECT_ENTITIES"), "entity selection can emit a compatible connection intent")
	workspace.request_connection("iron-field", "smelter", "CARGO", "iron_ore")
	_check(emitted.size() == 2, "resource fields cannot become connection endpoints")

	workspace._on_link_selected(_link("cargo-link"))
	await process_frame
	_check(workspace.find_child("FactoryRemoveLinkButton", true, false) != null, "link inspection offers a remove-link intent")
	workspace.request_remove_link("cargo-link")
	_check(emitted.size() == 3 and _has_valid_envelope(emitted[2] as Dictionary, "REMOVE_LINK"), "remove-link uses the versioned command envelope")

	workspace._select_order(_order("BUILD-1"))
	await process_frame
	_check(workspace.find_child("FactoryFundConstructionButton", true, false) != null and workspace.find_child("FactoryFundingStorage", true, false) != null, "construction inspection exposes an explicit storage-backed funding action")
	workspace.request_fund_construction("BUILD-1", "depot")
	_check(emitted.size() == 4 and _has_valid_envelope(emitted[3] as Dictionary, "FUND_CONSTRUCTION"), "construction funding emits no direct state mutation")
	_check(JSON.stringify(fixture) == original_signature, "workspace never mutates the supplied fixture snapshot")

	host.queue_free()
	await process_frame
	await _test_main_command_gateway()
	_finish()


func _test_main_command_gateway() -> void:
	var game = get_root().get_node("Game")
	game.persistence_enabled = false
	game.reset_game()
	var main_scene: PackedScene = load("res://src/ui/main.tscn")
	var main := main_scene.instantiate()
	main.set_anchors_preset(Control.PRESET_TOP_LEFT)
	main.size = Vector2(1440, 900)
	get_root().add_child(main)
	await process_frame
	await process_frame
	main.call("_switch_page", "industry", false)
	await process_frame
	await process_frame
	_check(str(main.call("_factory_world_id_for_location", "lunar_space")).is_empty(), "Factory workspace never substitutes another location's world when the selected location has no grid")
	var mounted_workspace := main.find_child("FactoryMiningProductionWorkspace", true, false)
	_check(mounted_workspace != null, "main Industry route mounts the Factory workspace instead of the retired aggregate production UI")
	if mounted_workspace != null:
		var mounted_snapshot: Dictionary = mounted_workspace.get("_snapshot")
		var world_id := str(mounted_snapshot.get("world_id", ""))
		var before_orders := (mounted_snapshot.get("construction_orders", []) as Array).size()
		var before_revision := int(mounted_snapshot.get("topology_revision", -1))
		mounted_workspace.call("_select_building", "grid_surface_mine", _building("grid_surface_mine"))
		var mounted_canvas = mounted_workspace.get("_canvas")
		var mounted_resource_hit: Rect2 = mounted_canvas._node_rects.get("starter-iron-field", {}).get("rect", Rect2())
		mounted_canvas._select_at(mounted_resource_hit.position + Vector2(2, 2))
		await process_frame
		var refreshed_snapshot: Dictionary = mounted_workspace.get("_snapshot")
		var world: Dictionary = game.state.factory_worlds.get(world_id, {})
		_check(world.get("construction_orders", {}).size() == before_orders + 1 and int(refreshed_snapshot.get("topology_revision", -1)) == before_revision + 1, "main forwards a placement intent through Game.execute_factory_command and refreshes the committed snapshot")
	main.queue_free()
	await process_frame


func _has_valid_envelope(intent: Dictionary, kind: String) -> bool:
	return int(intent.get("protocol_version", 0)) == 1 and str(intent.get("kind", "")) == kind and not str(intent.get("command_id", "")).is_empty() and str(intent.get("world_id", "")) == "fixture-grid" and intent.has("base_topology_revision") and intent.has("base_runtime_revision") and intent.get("payload", null) is Dictionary


func _snapshot_fixture() -> Dictionary:
	return {
		"valid":true, "protocol_version":1, "world_id":"fixture-grid", "location_id":"earth_orbit", "topology_revision":7, "runtime_revision":3,
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":128, "y":128}},
		"resource_fields":[{"id":"iron-field", "node_kind":"RESOURCE_FIELD", "is_entity":false, "resource_id":"iron_ore", "resource_color":"#b98555", "grade":1.15, "potential_density":0.5, "footprint":{"origin":{"x":32, "y":32}, "size":{"x":16, "y":16}}, "ports":{"inputs":[], "outputs":[]}}],
		"entities":[_entity("depot"), _entity("mine"), _entity("smelter")],
		"links":[_link("cargo-link"), _link("power-link", "POWER")],
		"construction_orders":[_order("BUILD-1")],
		"palette":{"buildings":[_building("grid_arc_smelter"), _building("grid_surface_mine")], "recipes":[{"id":"grid_refine_iron", "name":"Refine iron", "inputs":[], "outputs":[]}]},
		"power":{"generation_kw":100.0, "demand_kw":130.0, "served_kw":100.0, "satisfaction":0.77}, "statistics":{}, "summary":{}
	}


func _building(id: String) -> Dictionary:
	return {"id":id, "name":"Surface Mining Field" if id == "grid_surface_mine" else "Macro Arc Smelter", "kind":"EXTRACTOR" if id == "grid_surface_mine" else "MACHINE", "footprint":{"width":3, "height":3} if id == "grid_surface_mine" else {"width":16, "height":12}, "recipe_ids":[] if id == "grid_surface_mine" else ["grid_refine_iron"]}


func _entity(id: String) -> Dictionary:
	var data := {
		"id":id, "is_entity":true, "definition_id":"grid_bulk_depot", "name":id.capitalize(), "node_kind":"STORAGE", "status":"RUNNING", "blocker_code":"", "footprint":{"origin":{"x":5, "y":5}, "size":{"x":8, "y":8}}, "inputs":{}, "outputs":{}, "inventory":{"scrap_metal":10}, "progress":0.5, "power_factor":1.0, "actual_rate":0.0, "power_generation_kw":0.0, "power_demand_kw":0.0, "ports":{"inputs":["*"], "outputs":["*"]}
	}
	if id == "mine":
		data.merge({"definition_id":"grid_surface_mine", "name":"Surface Mining Field", "node_kind":"EXTRACTOR", "footprint":{"origin":{"x":35, "y":35}, "size":{"x":3, "y":3}}, "outputs":{"iron_ore":4}, "inventory":{"iron_ore":6}, "actual_rate":4.0, "power_demand_kw":50.0, "ports":{"inputs":[], "outputs":["iron_ore"]}})
	elif id == "smelter":
		data.merge({"definition_id":"grid_arc_smelter", "name":"Macro Arc Smelter", "node_kind":"MACHINE", "status":"INPUT_SHORTAGE", "blocker_code":"INPUT_SHORTAGE", "footprint":{"origin":{"x":65, "y":36}, "size":{"x":16, "y":12}}, "inputs":{"iron_ore":0}, "outputs":{"iron_ingot":0}, "actual_rate":0.0, "power_demand_kw":80.0, "ports":{"inputs":["iron_ore"], "outputs":["iron_ingot"]}})
	return data


func _link(id: String, kind: String = "CARGO") -> Dictionary:
	return {"id":id, "kind":kind, "source_id":"mine" if kind == "CARGO" else "depot", "target_id":"smelter" if kind == "CARGO" else "mine", "item_id":"iron_ore" if kind == "CARGO" else "", "capacity_per_second":4.0, "last_flow":2.0 if kind == "CARGO" else 0.0, "utilization":0.5, "priority":1, "status":"FLOWING" if kind == "CARGO" else "CONNECTED"}


func _order(id: String) -> Dictionary:
	return {"id":id, "entity_id":"build-entity", "definition_id":"grid_surface_mine", "footprint":{"origin":{"x":48, "y":40}, "size":{"x":3, "y":3}}, "required_items":{"scrap_metal":4}, "delivered_items":{"scrap_metal":0}, "work_required":20.0, "work_done":0.0, "progress":0.0, "status":"WAITING_MATERIALS", "blocker_code":"MISSING_MATERIALS"}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_WORKSPACE_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
