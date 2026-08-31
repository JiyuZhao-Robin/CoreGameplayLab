extends Node

const ViewScript = preload("res://src/ui/components/industrial_network_view.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("en")
	var view: IndustrialNetworkView = ViewScript.new()
	view.build({}, false)
	view.size = Vector2(1100, 620)
	add_child(view)
	view.apply_projection(_small_projection())
	await _settle()
	_check(view._nodes.size() == 3 and view._edge_layer._edges.size() == 2, "network view creates independent node components and a batched edge layer")

	var selected_payload := [{}]
	view.entity_selected.connect(func(value): selected_payload[0] = value)
	view._select_node("production:line-a", true)
	_check(str((selected_payload[0] as Dictionary).get("domain_entity_id", "")) == "line-a" and str(view.selected_entity().get("id", "")) == "production:line-a", "node selection resolves the stable Projection entity for Context Inspector")

	var node = view._nodes.get("production:line-a") as IndustrialNetworkNode
	node.position_offset = Vector2(432.0, 188.0)
	view._graph.zoom = 0.9
	view._graph.scroll_offset = Vector2(51.0, 37.0)
	var saved := view.export_preferences()
	var restored: IndustrialNetworkView = ViewScript.new()
	restored.build(saved, false)
	restored.size = Vector2(1100, 620)
	add_child(restored)
	restored.apply_projection(_small_projection())
	await _settle()
	var restored_node = restored._nodes.get("production:line-a") as IndustrialNetworkNode
	_check(restored_node.position_offset.is_equal_approx(Vector2(432.0, 188.0)), "stable node ID restores the player's network layout")
	_check(is_equal_approx(restored._graph.zoom, 0.9) and restored._graph.scroll_offset.is_equal_approx(Vector2(51.0, 37.0)), "canvas zoom and pan restore as UI preferences")

	var corrupt: IndustrialNetworkView = ViewScript.new()
	corrupt.build({"positions":{"earth_orbit":{"production:line-a":["broken", {}]}}, "viewports":{"earth_orbit":"broken"}, "layers":"broken"}, false)
	corrupt.size = Vector2(1100, 620)
	add_child(corrupt)
	corrupt.apply_projection(_small_projection())
	await _settle()
	var fallback_node = corrupt._nodes.get("production:line-a") as IndustrialNetworkNode
	_check(is_finite(fallback_node.position_offset.x) and is_finite(fallback_node.position_offset.y), "corrupt UI preferences fall back to deterministic finite layout")

	var phase_before := view._edge_layer.animation_phase()
	view._process(0.5)
	var phase_running := view._edge_layer.animation_phase()
	_check(phase_running > phase_before, "one shared visual clock advances real-flow feedback")
	view.set_reduced_motion(true)
	view._process(0.5)
	_check(is_equal_approx(view._edge_layer.animation_phase(), phase_running), "Reduced Motion disables continuous edge animation without removing graph state")
	view.set_reduced_motion(false)
	view.hide()
	view._process(0.5)
	_check(is_equal_approx(view._edge_layer.animation_phase(), phase_running), "a hidden industrial network does not continue high-frequency animation work")

	await _test_large_graph()
	view.queue_free()
	restored.queue_free()
	corrupt.queue_free()
	await get_tree().process_frame
	_finish()


func _test_large_graph() -> void:
	var graph := _large_projection(100, 200)
	var view: IndustrialNetworkView = ViewScript.new()
	view.build({}, true)
	view.size = Vector2(1200, 700)
	add_child(view)
	var started := Time.get_ticks_usec()
	view.apply_projection(graph)
	await _settle()
	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var first_instance = view._nodes.get("perf:0")
	view.apply_projection(graph)
	await get_tree().process_frame
	_check(view._nodes.size() == 100 and view._edge_layer._edges.size() == 200, "large graph contract renders 100 aggregate nodes and 200 edges")
	_check(view._nodes.get("perf:0") == first_instance, "unchanged low-frequency snapshots preserve node instances instead of rebuilding the tree")
	_check(elapsed_ms < 2500.0, "100-node/200-edge graph is interactive within the headless construction budget (%.1f ms)" % elapsed_ms)
	view.queue_free()
	await get_tree().process_frame


func _small_projection() -> Dictionary:
	return {
		"location_id":"earth_orbit", "products":["iron_ingot"], "bottleneck_node_ids":["production:line-a"], "bottleneck_edge_ids":["edge:a"], "primary_bottleneck":"Input shortage",
		"nodes":[
			_node("source:ore", "SOURCE", "ore", 0, [], [_port("out:iron_ingot")], "RUNNING"),
			_node("production:line-a", "PRODUCTION", "line-a", 1, [_port("in:iron_ingot")], [_port("out:iron_ingot")], "RUNNING"),
			_node("buffer:earth_orbit:iron_ingot", "BUFFER", "iron_ingot", 2, [_port("in:iron_ingot")], [_port("out:iron_ingot")], "TIGHT")
		],
		"edges":[
			_edge("edge:a", "source:ore", "production:line-a"),
			_edge("edge:b", "production:line-a", "buffer:earth_orbit:iron_ingot")
		]
	}


func _large_projection(node_count: int, edge_count: int) -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	for index in node_count:
		nodes.append(_node("perf:%d" % index, "PRODUCTION", "line-%d" % index, index % 10, [_port("in:material")], [_port("out:material")], "RUNNING"))
	for index in edge_count:
		var source_index := index % node_count
		var target_index := (source_index + 1 + index / node_count) % node_count
		edges.append(_edge("perf-edge:%d" % index, "perf:%d" % source_index, "perf:%d" % target_index))
	return {"location_id":"performance", "products":["material"], "nodes":nodes, "edges":edges, "bottleneck_node_ids":[], "bottleneck_edge_ids":[], "primary_bottleneck":""}


func _node(id: String, kind: String, entity_id: String, column: int, inputs: Array, outputs: Array, status: String) -> Dictionary:
	return {
		"id":id, "kind":kind, "domain_entity_id":entity_id, "location_id":"earth_orbit",
		"title":entity_id, "subtitle":"Aggregate industrial entity", "status":status,
		"inputs":inputs, "outputs":outputs, "actual_rate":4.0, "theoretical_rate":8.0,
		"utilization":0.5, "buffer":{"utilization":0.5}, "blocker":{}, "column":column,
		"navigation_target":{"page":"industry"}, "allowed_actions":["OPEN"], "in_bottleneck":id == "production:line-a", "data":{}
	}


func _port(id: String) -> Dictionary:
	return {"id":id, "item_id":"material" if "material" in id else "iron_ingot", "title":"Material", "port_type":"MATERIAL", "connected":true}


func _edge(id: String, source: String, target: String) -> Dictionary:
	return {
		"id":id, "source":source, "target":target, "source_port":"out:material" if source.begins_with("perf:") else "out:iron_ingot",
		"target_port":"in:material" if target.begins_with("perf:") else "in:iron_ingot", "item_id":"material", "layer":"MATERIAL",
		"actual_flow":4.0, "requested_flow":6.0, "capacity":8.0, "in_transit":0.0, "utilization":0.5,
		"status":"ACTIVE", "congested":false, "blocked":false, "in_bottleneck":id == "edge:a"
	}


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("INDUSTRIAL_NETWORK_UI_PASS")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
