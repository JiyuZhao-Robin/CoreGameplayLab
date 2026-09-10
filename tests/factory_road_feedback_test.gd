extends SceneTree

## Focused Factory UI contract for the read-only local-road delivery inspector.
## It deliberately supplies only immutable snapshot records: no Game, state, or
## simulation instance is created here.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Control.new()
	host.name = "FactoryRoadFeedbackHost"
	host.size = Vector2(1920, 1080)
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.apply_snapshot(_fixture())
	await _settle()
	await _test_storage_inbound_outbound_and_blocked_eta(workspace)
	await _test_full_stock_does_not_stretch_inspector(workspace)
	await _test_selected_producer_filters_unrelated_shipments(workspace)
	await _test_snapshot_refresh_and_empty_delivery_state(workspace)
	workspace.queue_free()
	await process_frame
	host.queue_free()
	await process_frame
	_finish()


func _test_storage_inbound_outbound_and_blocked_eta(workspace) -> void:
	workspace.call("_on_entity_selected", _entity_by_id(_fixture(), "storage_a"))
	await _settle()
	var inspector := workspace.find_child("FactoryRoadShipmentInspector", true, false) as Control
	var rows := workspace.find_child("FactoryRoadShipmentRows", true, false) as VBoxContainer
	var outgoing := workspace.find_child("RoadShipmentwarehouse_out", true, false) as PanelContainer
	var incoming := workspace.find_child("RoadShipmentmine_in", true, false) as PanelContainer
	var blocked := workspace.find_child("RoadShipmentmachine_blocked", true, false) as PanelContainer
	var unrelated: Node = workspace.find_child("RoadShipmentunrelated", true, false)
	_check(inspector != null and rows != null and rows.get_child_count() == 3, "selecting a warehouse shows its real inbound and outbound road jobs in a bounded inspector list")
	_check(outgoing != null and str(outgoing.get_meta("direction", "")) == "SENDING" and incoming != null and str(incoming.get_meta("direction", "")) == "RECEIVING", "one warehouse delivery list distinguishes goods sent from shared storage from goods received into it")
	_check(unrelated == null, "warehouse delivery inspector filters a shipment whose source and target are both unrelated")
	if outgoing != null:
		var icon = outgoing.get_meta("icon")
		var progress := outgoing.get_meta("progress") as ProgressBar
		var eta := outgoing.get_meta("eta_label") as Label
		var quantity := outgoing.find_child("RoadShipmentQuantity", true, false) as Label
		_check(icon != null and int(icon.call("art_index")) >= 0 and quantity != null and quantity.text == "×2" and progress != null and is_equal_approx(progress.value, 50.0) and eta != null and eta.text.contains("4s"), "outbound warehouse job renders the item icon, quantity progress, and a live ETA")
	if blocked != null:
		var blocked_eta := blocked.get_meta("eta_label") as Label
		var blocked_phase := blocked.find_child("RoadShipmentPhase", true, false) as Label
		_check(str(blocked.get_meta("phase", "")) == "BLOCKED" and float(blocked.get_meta("eta_ms", 0.0)) < 0.0 and blocked_eta != null and not blocked_eta.text.contains("12s") and blocked_phase != null and not blocked_phase.text.is_empty(), "blocked local delivery retains its blocker reason and does not present a decrementing ETA")


func _test_full_stock_does_not_stretch_inspector(workspace) -> void:
	var snapshot := _fixture()
	for index in range(24):
		snapshot["shared_inventory"]["material-%d-with-a-long-display-name" % index] = 40
	snapshot["runtime_revision"] = 15
	snapshot["operations"] = {"materials":[{"item_id":"iron_ore", "stored":17, "buffered":48, "production_per_second":0.0, "consumption_per_second":0.0}]}
	workspace.apply_snapshot(snapshot)
	await _settle()
	var inspector := workspace.find_child("InspectorScroll", true, false) as Control
	_check(inspector.get_global_rect().end.x <= workspace.get_global_rect().end.x + 1.0 and inspector.size.x < workspace.size.x * 0.4, "long shared inventory wraps inside the fixed inspector instead of stretching the page or hiding delivery quantities and ETA")
	var ledger: Control = workspace.call("_production_material_ledger") as Control
	var flow := ledger.find_child("ProductionFlowIronOre", true, false) as HBoxContainer
	_check(flow != null and (flow.get_child(3) as Label).text == "17", "the material ledger retains warehouse stock while output buffers pause production")
	ledger.queue_free()
	workspace.apply_snapshot(_fixture())
	await _settle()


func _test_selected_producer_filters_unrelated_shipments(workspace) -> void:
	workspace.call("_on_entity_selected", _entity_by_id(_fixture(), "machine_a"))
	await _settle()
	var incoming := workspace.find_child("RoadShipmentwarehouse_out", true, false) as PanelContainer
	var outgoing := workspace.find_child("RoadShipmentmachine_blocked", true, false) as PanelContainer
	var mine_in: Node = workspace.find_child("RoadShipmentmine_in", true, false)
	var unrelated: Node = workspace.find_child("RoadShipmentunrelated", true, false)
	_check(incoming != null and str(incoming.get_meta("direction", "")) == "RECEIVING" and outgoing != null and str(outgoing.get_meta("direction", "")) == "SENDING", "selecting a production building shows its receiving and dispatching deliveries with endpoint direction")
	_check(mine_in == null and unrelated == null, "producer delivery inspector excludes warehouse-only and unrelated shipment rows")


func _test_snapshot_refresh_and_empty_delivery_state(workspace) -> void:
	var updated := _fixture().duplicate(true)
	updated["runtime_revision"] = 13
	var jobs: Array = updated.get("road_shipments", [])
	for job_value in jobs:
		if not job_value is Dictionary or str((job_value as Dictionary).get("id", "")) != "warehouse_out":
			continue
		var job := job_value as Dictionary
		job["phase"] = "TRAVEL"
		job["status"] = "IN_TRANSIT"
		job["travel_progress"] = 0.75
		job["eta_ms"] = 1000.0
	workspace.apply_snapshot(updated)
	await _settle()
	var refreshed := workspace.find_child("RoadShipmentwarehouse_out", true, false) as PanelContainer
	var refreshed_progress := refreshed.get_meta("progress") as ProgressBar if refreshed != null else null
	var refreshed_eta := refreshed.get_meta("eta_label") as Label if refreshed != null else null
	_check(refreshed != null and str(refreshed.get_meta("phase", "")) == "TRAVEL" and refreshed_progress != null and is_equal_approx(refreshed_progress.value, 75.0) and refreshed_eta != null and refreshed_eta.text.contains("1s"), "a runtime snapshot refresh updates the selected entity delivery phase, progress, and ETA")
	updated["runtime_revision"] = 14
	updated["road_shipments"] = []
	workspace.apply_snapshot(updated)
	await _settle()
	var empty := workspace.find_child("FactoryRoadShipmentEmpty", true, false) as Label
	var old_card: Node = workspace.find_child("RoadShipmentwarehouse_out", true, false)
	_check(empty != null and old_card == null, "a snapshot with no local deliveries shows an explicit empty state and never invents a transport task")


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"road-feedback-grid",
		"location_name":"Earth",
		"topology_revision":6,
		"runtime_revision":12,
		"logistics_mode":"PLANET_SHARED_ROADS",
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":256, "y":160}},
		"canvas_limits":{"max_world_size_tiles":{"x":256, "y":160}},
		"chunk_size_tiles":64,
		"roads":[],
		"road_logistics":{"capacity":4, "required":3, "utilization":0.75, "active_shipments":3},
		"shared_inventory":{"iron_ore":17, "copper_ore":36},
		"item_names":{"iron_ore":"Iron ore", "copper_ore":"Copper ore"},
		"entities":[
			_entity("storage_a", "STORAGE", "Bulk Depot", Vector2i(30, 30)),
			_entity("mine_a", "EXTRACTOR", "Iron Mine", Vector2i(60, 30)),
			_entity("machine_a", "MACHINE", "Arc Smelter", Vector2i(90, 30)),
			_entity("machine_b", "MACHINE", "Unrelated Works", Vector2i(130, 30)),
			_entity("storage_b", "STORAGE", "Remote Depot", Vector2i(160, 30))
		],
		"road_shipments":[
			{"id":"warehouse_out", "source_id":"storage_a", "target_id":"machine_a", "source_kind":"WAREHOUSE", "destination_kind":"ENTITY", "item_id":"iron_ore", "quantity":2, "cargo":{"iron_ore":2}, "status":"WAITING_LOADING", "phase":"LOADING", "travel_progress":0.0, "phase_progress":0.5, "eta_ms":4000.0, "position":{"x":42.0, "y":30.0}, "path_tiles":[], "remaining_ms":3000.0, "loading_remaining_ms":1000.0},
			{"id":"mine_in", "source_id":"mine_a", "target_id":"storage_a", "source_kind":"ENTITY", "destination_kind":"WAREHOUSE", "item_id":"iron_ore", "quantity":1, "cargo":{"iron_ore":1}, "status":"IN_TRANSIT", "phase":"TRAVEL", "travel_progress":0.25, "phase_progress":0.0, "eta_ms":15000.0, "position":{"x":48.0, "y":30.0}, "path_tiles":[], "remaining_ms":15000.0, "loading_remaining_ms":0.0},
			{"id":"machine_blocked", "source_id":"machine_a", "target_id":"storage_a", "source_kind":"ENTITY", "destination_kind":"WAREHOUSE", "item_id":"copper_ore", "quantity":1, "cargo":{"copper_ore":1}, "status":"BLOCKED_TARGET_FULL", "phase":"BLOCKED", "travel_progress":1.0, "phase_progress":1.0, "eta_ms":-1.0, "position":{"x":30.0, "y":30.0}, "path_tiles":[], "remaining_ms":0.0, "loading_remaining_ms":0.0},
			{"id":"unrelated", "source_id":"machine_b", "target_id":"storage_b", "source_kind":"ENTITY", "destination_kind":"WAREHOUSE", "item_id":"copper_ore", "quantity":8, "cargo":{"copper_ore":8}, "status":"IN_TRANSIT", "phase":"TRAVEL", "travel_progress":0.1, "phase_progress":0.0, "eta_ms":8000.0, "position":{"x":145.0, "y":30.0}, "path_tiles":[], "remaining_ms":8000.0, "loading_remaining_ms":0.0}
		],
		"links":[], "resource_fields":[], "construction_orders":[],
		"palette":{"buildings":[], "recipes":[]}
	}


func _entity(entity_id: String, kind: String, title: String, origin: Vector2i) -> Dictionary:
	return {
		"id":entity_id, "node_kind":kind, "name":title,
		"definition_id":"grid_bulk_depot" if kind == "STORAGE" else "grid_arc_smelter",
		"footprint":{"origin":{"x":origin.x, "y":origin.y}, "size":{"x":4, "y":4}},
		"status":"READY", "power_factor":1.0, "actual_rate":0.0,
		"road_connected":true, "road_component_id":"road-main",
		"ports":{"inputs":[], "outputs":[], "accepts_power":false, "provides_power":false},
		"inputs":{}, "outputs":{}, "inventory":{}
	}


func _entity_by_id(snapshot: Dictionary, entity_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		if entity_value is Dictionary and str((entity_value as Dictionary).get("id", "")) == entity_id:
			return (entity_value as Dictionary).duplicate(true)
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
		print("FACTORY_ROAD_FEEDBACK_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
