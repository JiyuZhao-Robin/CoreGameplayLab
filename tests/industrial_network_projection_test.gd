extends Node

const ProjectionScript = preload("res://src/ui/view_models/industrial_network_projection.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("en")
	var projection = ProjectionScript.new(Game.content)
	var snapshot := _fixture_snapshot()
	var first: Dictionary = projection.build(snapshot)
	var second: Dictionary = projection.build(snapshot)
	_check(JSON.stringify(first) == JSON.stringify(second), "identical authoritative snapshots produce a deterministic graph")
	_check(str(first.get("signature", "")) == str(second.get("signature", "")) and not str(first.get("signature", "")).is_empty(), "projection exposes a stable content signature")

	var node_ids := {}
	for value in first.get("nodes", []):
		var node := value as Dictionary
		var node_id := str(node.get("id", ""))
		_check(not node_id.is_empty() and not node_ids.has(node_id), "node IDs are stable and unique: %s" % node_id)
		node_ids[node_id] = true
	var edge_ids := {}
	for value in first.get("edges", []):
		var edge := value as Dictionary
		var edge_id := str(edge.get("id", ""))
		_check(not edge_id.is_empty() and not edge_ids.has(edge_id), "edge IDs are stable and unique: %s" % edge_id)
		edge_ids[edge_id] = true

	var running := _node(first, "production:line-running")
	_check(str(running.get("domain_entity_id", "")) == "line-running" and str(running.get("data", {}).get("method_id", "")) == "refine_iron", "a real Production Line maps to a production node and current Production Method")
	_check(float(running.get("actual_rate", 0.0)) == 8.0 and float(running.get("theoretical_rate", 0.0)) == 10.0, "actual and theoretical throughput remain authoritative snapshot values")
	var steel_buffer := _node(first, "buffer:earth_orbit:iron_ingot")
	_check(int(steel_buffer.get("buffer", {}).get("available", 0)) == 42 and int(steel_buffer.get("buffer", {}).get("reserved", 0)) == 8, "inventory available and reserved amounts map without recomputation")
	_check(float(steel_buffer.get("buffer", {}).get("inbound", 0.0)) == 14.0 and float(steel_buffer.get("buffer", {}).get("committed_demand", 0.0)) == 30.0, "in-transit and committed demand are preserved")
	var maintenance := _node(first, "demand:aggregate:maintenance:iron_ingot")
	_check(float(maintenance.get("theoretical_rate", 0.0)) == 3.0 and (maintenance.get("data", {}).get("source_ids", []) as Array).size() == 2, "continuous O&M DemandSources aggregate by type and product without losing their real total rate or sources")
	_check(_node(first, "demand:completed:test").is_empty(), "completed zero-rate demand is omitted from the active network instead of creating visual spaghetti")
	var route := _node(first, "logistics:earth_moon_bulk")
	_check(str(route.get("status", "")) == "SATURATED" and float(route.get("buffer", {}).get("in_transit", 0.0)) == 14.0, "real route congestion and Shipment cargo map to Logistics")
	_check(first.get("bottleneck_node_ids", []).has("buffer:earth_orbit:iron_ingot"), "authoritative shortest bottleneck chain highlights its buffer node")
	_check(first.get("bottleneck_node_ids", []).has("production:line-running"), "authoritative shortest bottleneck chain highlights its factory line")

	var expected_statuses := {
		"line-running":"RUNNING", "line-paused":"PAUSED", "line-input":"BLOCKED_INPUT",
		"line-output":"BLOCKED_OUTPUT", "line-power":"POWER_LIMITED",
		"line-cooling":"COOLING_LIMITED", "line-logistics":"LOGISTICS_LIMITED"
	}
	for line_id_value in expected_statuses.keys():
		var line_id := str(line_id_value)
		_check(str(_node(first, "production:%s" % line_id).get("status", "")) == str(expected_statuses[line_id]), "production status projects without UI inference: %s" % expected_statuses[line_id])

	# Exercise the real Simulation read model with an actual industrial operation.
	var runtime_state := SpaceGameState.create_new(Game.content.domains.keys(), Game.content.regions)
	runtime_state.industrial_operations.append({
		"line_id":"LINE-PROJECTION-TEST", "slot":0, "location_id":SpaceGameState.MAIN_BASE_LOCATION_ID,
		"activity_id":"refine_iron", "method_id":"refine_iron", "facility_id":"makeshift_workshop",
		"production_device_id":"bootstrap_fabrication_bay", "status":"RUNNING", "operating_state":"RUNNING",
		"actual_rate":1.0 / 6.0, "theoretical_rate":1.0 / 6.0, "control_mode":"PINNED", "manual_lock":true
	})
	var runtime_snapshot := Game.simulation.industrial_network_snapshot(runtime_state, SpaceGameState.MAIN_BASE_LOCATION_ID)
	var mapped_runtime := projection.build(runtime_snapshot)
	var runtime_node := _node(mapped_runtime, "production:LINE-PROJECTION-TEST")
	_check(not runtime_node.is_empty() and str(runtime_node.get("data", {}).get("method_id", "")) == "refine_iron", "Simulation industrial_network_snapshot maps a real state Production Line")

	I18n.set_locale("zh_CN")
	var chinese := projection.build(snapshot)
	_check(str(_node(chinese, "infrastructure:earth_orbit").get("title", "")) != str(_node(first, "infrastructure:earth_orbit").get("title", "")), "projection rebuild localizes player-facing node text after language change")
	I18n.set_locale("en")
	_finish()


func _fixture_snapshot() -> Dictionary:
	var lines: Array = []
	var statuses := [
		["line-running", "RUNNING", 8.0], ["line-paused", "PAUSED", 0.0],
		["line-input", "BLOCKED_INPUT", 0.0], ["line-output", "BLOCKED_OUTPUT", 0.0],
		["line-power", "POWER_LIMITED", 4.0], ["line-cooling", "COOLING_LIMITED", 5.0],
		["line-logistics", "LOGISTICS_LIMITED", 3.0]
	]
	for index in statuses.size():
		var row: Array = statuses[index]
		lines.append({
			"line_id":row[0], "slot":index, "facility_id":"makeshift_workshop",
			"production_device_id":"bootstrap_fabrication_bay", "activity_id":"refine_iron",
			"method_id":"refine_iron", "status":row[1], "runtime_status":"RUNNING" if row[1] != "PAUSED" else "IDLE",
			"actual_rate":row[2], "theoretical_rate":10.0, "utilization":float(row[2]) / 10.0,
			"inputs":[{"item_id":"iron_ore", "actual_rate":float(row[2]) * 2.0, "requested_rate":20.0}],
			"outputs":[{"item_id":"iron_ingot", "actual_rate":row[2], "requested_rate":10.0}],
			"blocker":{} if row[1] == "RUNNING" else {"code":row[1], "primary_reason":row[1]},
			"control_mode":"PINNED"
		})
	return {
		"location_id":"earth_orbit", "generated_at_ms":12345,
		"sources":[{"source_id":"earth_extraction_network", "status":"RUNNING", "outputs":[{"item_id":"iron_ore", "actual_rate":16.0, "requested_rate":20.0, "capacity":24.0}], "blocker":{}}],
		"buffers":[
			{"product_id":"iron_ore", "on_hand":20, "available":20, "reserved":0, "inbound":0.0, "outbound":0.0, "capacity":100.0, "free":80.0, "utilization":0.2, "production_rate":16.0, "consumption_rate":16.0, "net_rate":0.0, "committed_demand":0.0, "status":"STABLE", "storage_class":"BULK"},
			{"product_id":"iron_ingot", "on_hand":50, "available":42, "reserved":8, "inbound":14.0, "outbound":2.0, "capacity":100.0, "free":50.0, "utilization":0.5, "production_rate":8.0, "consumption_rate":12.0, "net_rate":-4.0, "committed_demand":30.0, "status":"TIGHT", "storage_class":"BULK"}
		],
		"lines":lines,
		"facilities":[],
		"logistics":[{"route_id":"earth_moon_bulk", "origin":"lunar_space", "destination":"earth_orbit", "direction":"INBOUND", "status":"SATURATED", "transport_mode_id":"bulk_hauling", "actual_rate":14.0, "requested_rate":18.0, "capacity":14.0, "utilization":1.0, "in_transit":14.0, "cargo":{"iron_ingot":14.0}, "cargo_rate":{"iron_ingot":14.0}, "blocker":{"code":"ROUTE_CONGESTED"}}],
		"demands":[
			{"demand_id":"construction:test", "product_id":"iron_ingot", "source_type":"construction", "source_id":"test", "priority":70, "rate":4.0, "quantity":30.0, "backlog":30.0},
			{"demand_id":"maintenance:a", "product_id":"iron_ingot", "demand_kind":"CONTINUOUS", "source_type":"maintenance", "source_id":"factory-a", "priority":50, "rate":1.0, "quantity":0.0, "backlog":0.0},
			{"demand_id":"maintenance:b", "product_id":"iron_ingot", "demand_kind":"CONTINUOUS", "source_type":"maintenance", "source_id":"factory-b", "priority":60, "rate":2.0, "quantity":0.0, "backlog":0.0},
			{"demand_id":"completed:test", "product_id":"iron_ingot", "source_type":"construction", "source_id":"completed", "priority":10, "rate":0.0, "quantity":0.0, "backlog":0.0}
		],
		"infrastructure":{"industry":{"status":"HEALTHY", "throughput_multiplier":1.0}, "local_logistics":{"status":"CONSTRAINED"}, "storage":{}},
		"bottlenecks":[{"primary_bottleneck":"Iron supply", "shortest_chain":[{"kind":"PRODUCT", "id":"iron_ingot"}, {"kind":"FACTORY", "id":"makeshift_workshop"}]}]
	}


func _node(graph: Dictionary, node_id: String) -> Dictionary:
	for value in graph.get("nodes", []):
		var node := value as Dictionary
		if str(node.get("id", "")) == node_id:
			return node
	return {}


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("INDUSTRIAL_NETWORK_PROJECTION_PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
