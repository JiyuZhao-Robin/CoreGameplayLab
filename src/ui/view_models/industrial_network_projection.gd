class_name IndustrialNetworkProjection
extends RefCounted

## Pure presentation projection. Domain rates and blockers arrive through
## SimulationEngine. This class owns stable visual identity and graph topology,
## but never mutates GameState and never evaluates economic formulas.

var _content: ContentDatabase
var _rank_cache := {}


func _init(content: ContentDatabase) -> void:
	_content = content


func build(snapshot: Dictionary) -> Dictionary:
	_rank_cache.clear()
	var location_id := str(snapshot.get("location_id", ""))
	var nodes: Array = []
	var edges: Array = []
	var products := {}
	var demand_rows := _aggregate_demands(snapshot.get("demands", []))

	for source_value in snapshot.get("sources", []):
		var source := source_value as Dictionary
		var source_id := str(source.get("source_id", ""))
		var outputs := _port_rows(source.get("outputs", []), false)
		for output in outputs:
			products[str(output.get("item_id", ""))] = true
		nodes.append(_node(
			"source:%s" % source_id, "SOURCE", source_id, location_id,
			str(source.get("name", source_id)),
			I18n.core("industrial_network.source.subtitle", "Factory-grid material source"),
			str(source.get("status", "IDLE")), [], outputs,
			_sum_field(outputs, "actual_rate"), _sum_field(outputs, "requested_rate"),
			_ratio(_sum_field(outputs, "actual_rate"), _sum_field(outputs, "capacity")),
			{}, source.get("blocker", {}), 0,
			{"page":"frontier", "location_id":location_id, "entity_id":source_id}, ["OPEN"]
		))

	for buffer_value in snapshot.get("buffers", []):
		var buffer := buffer_value as Dictionary
		var product_id := str(buffer.get("product_id", ""))
		if product_id.is_empty():
			continue
		products[product_id] = true
		var rank := _product_rank(product_id, {})
		var buffer_id := "buffer:%s:%s" % [location_id, product_id]
		var product_title := _name(_content.items, product_id, product_id)
		var status := str(buffer.get("status", "STABLE"))
		var buffer_data := {
			"on_hand":buffer.get("on_hand", 0), "available":buffer.get("available", 0),
			"reserved":buffer.get("reserved", 0), "inbound":buffer.get("inbound", 0.0),
			"outbound":buffer.get("outbound", 0.0), "capacity":buffer.get("capacity", 0.0),
			"free":buffer.get("free", 0.0), "utilization":buffer.get("utilization", 0.0),
			"net_rate":buffer.get("net_rate", 0.0), "committed_demand":buffer.get("committed_demand", 0.0),
			"storage_class":buffer.get("storage_class", "BULK")
		}
		var input_ports := [{"id":"in:%s" % product_id, "item_id":product_id, "title":product_title, "port_type":"MATERIAL", "connected":true}]
		var output_ports := [{"id":"out:%s" % product_id, "item_id":product_id, "title":product_title, "port_type":"MATERIAL", "connected":true}]
		nodes.append(_node(
			buffer_id, "BUFFER", product_id, location_id, product_title,
			I18n.core("industrial_network.buffer.subtitle", "%s storage buffer") % str(buffer.get("storage_class", "BULK")),
			status, input_ports, output_ports,
			float(buffer.get("net_rate", 0.0)), maxf(float(buffer.get("production_rate", 0.0)), float(buffer.get("consumption_rate", 0.0))),
			float(buffer.get("utilization", 0.0)), buffer_data, {}, rank * 2 + 1,
			{"page":"inventory", "location_id":location_id, "item_id":product_id}, ["OPEN"]
		))

	var line_facilities := {}
	for line_value in snapshot.get("lines", []):
		var line := line_value as Dictionary
		var line_id := str(line.get("line_id", ""))
		var activity_id := str(line.get("activity_id", ""))
		var facility_id := str(line.get("facility_id", ""))
		line_facilities[facility_id] = true
		var inputs := _port_rows(line.get("inputs", []), true)
		var outputs := _port_rows(line.get("outputs", []), false)
		var column := 2
		for output in outputs:
			var item_id := str(output.get("item_id", ""))
			products[item_id] = true
			column = maxi(column, _product_rank(item_id, {}) * 2)
		for input in inputs:
			products[str(input.get("item_id", ""))] = true
		var activity: Dictionary = _content.activities.get(activity_id, {})
		var facility_name := _name(_content.facilities, facility_id, facility_id)
		var method_name := _name(_content.activities, activity_id, activity_id)
		var blocker: Dictionary = line.get("blocker", {}) if line.get("blocker", null) is Dictionary else {}
		nodes.append(_node(
			"production:%s" % line_id, "PRODUCTION", line_id, location_id,
			method_name, facility_name, str(line.get("status", "PAUSED")), inputs, outputs,
			float(line.get("actual_rate", 0.0)), float(line.get("theoretical_rate", 0.0)),
			float(line.get("utilization", 0.0)), {"method_id":activity_id, "facility_id":facility_id, "production_device_id":line.get("production_device_id", ""), "control_mode":line.get("control_mode", "PINNED"), "slot":line.get("slot", 0)},
			blocker, column,
			{"page":"industry", "section":"production", "view":"list", "entity_id":line_id},
			["STOP", "OPEN"] if str(line.get("runtime_status", "IDLE")) in ["RUNNING", "BLOCKED"] else ["OPEN"]
		))

	for facility_value in snapshot.get("facilities", []):
		var facility := facility_value as Dictionary
		var facility_id := str(facility.get("facility_id", ""))
		if facility_id.is_empty() or line_facilities.has(facility_id):
			continue
		nodes.append(_node(
			"facility:%s:%s" % [location_id, facility_id], "PRODUCTION", facility_id, location_id,
			_name(_content.facilities, facility_id, facility_id),
			I18n.core("industrial_network.facility.idle", "Installed factory · no active production line"),
			"PAUSED", [], [], 0.0, float(facility.get("throughput", 0.0)), 0.0,
			{"facility_id":facility_id, "level":facility.get("level", 1)}, {}, 2,
			{"page":"industry", "section":"production", "view":"list", "entity_id":facility_id}, ["OPEN"]
		))

	for route_value in snapshot.get("logistics", []):
		var route := route_value as Dictionary
		var route_id := str(route.get("route_id", ""))
		var cargo: Dictionary = route.get("cargo", {})
		var cargo_rate: Dictionary = route.get("cargo_rate", {})
		var inbound := str(route.get("direction", "INBOUND")) == "INBOUND"
		var ports: Array = []
		var cargo_ids: Array = cargo.keys()
		cargo_ids.sort()
		for item_id_value in cargo_ids:
			var item_id := str(item_id_value)
			products[item_id] = true
			ports.append({"id":("out:" if inbound else "in:") + item_id, "item_id":item_id, "title":_name(_content.items, item_id, item_id), "port_type":"MATERIAL", "connected":float(cargo.get(item_id, 0.0)) > 0.0, "actual_rate":float(cargo_rate.get(item_id, 0.0)), "in_transit":float(cargo.get(item_id, 0.0))})
		var endpoint := str(route.get("origin", "")) if inbound else str(route.get("destination", ""))
		nodes.append(_node(
			"logistics:%s" % route_id, "LOGISTICS", route_id, location_id,
			_name(_content.logistics_routes, route_id, route_id),
			I18n.core("industrial_network.route.inbound", "Inbound from %s") % _name(_content.regions, endpoint, endpoint) if inbound else I18n.core("industrial_network.route.outbound", "Outbound to %s") % _name(_content.regions, endpoint, endpoint),
			str(route.get("status", "NO_TRANSPORT")), [] if inbound else ports, ports if inbound else [],
			float(route.get("actual_rate", 0.0)), float(route.get("requested_rate", 0.0)), float(route.get("utilization", 0.0)),
			{"capacity":route.get("capacity", 0.0), "in_transit":route.get("in_transit", 0.0), "transport_mode_id":route.get("transport_mode_id", ""), "direction":route.get("direction", "INBOUND")},
			route.get("blocker", {}), 0 if inbound else 8,
			{"page":"logistics", "location_id":location_id, "route_id":route_id}, ["OPEN"]
		))

	for demand_value in demand_rows:
		var demand := demand_value as Dictionary
		var demand_id := str(demand.get("demand_id", ""))
		var product_id := str(demand.get("product_id", ""))
		products[product_id] = true
		var demand_title := _demand_title(demand)
		var requested := float(demand.get("rate", 0.0))
		var committed := float(demand.get("backlog", demand.get("quantity", 0.0)))
		var demand_port := {"id":"in:%s" % product_id, "item_id":product_id, "title":_name(_content.items, product_id, product_id), "port_type":"DEMAND", "connected":committed > 0.0 or requested > 0.0, "requested_rate":requested}
		nodes.append(_node(
			"demand:%s" % demand_id, "DEMAND", demand_id, location_id, demand_title,
			_name(_content.items, product_id, product_id), "ACTIVE", [demand_port], [],
			0.0, requested, 0.0,
			{"product_id":product_id, "quantity":demand.get("quantity", 0.0), "backlog":committed, "priority":demand.get("priority", 50), "source_type":demand.get("source_type", "manual_order"), "source_id":demand.get("source_id", demand_id), "source_ids":demand.get("source_ids", [])},
			{}, _product_rank(product_id, {}) * 2 + 2, _demand_navigation(demand), ["OPEN"]
		))

	var infrastructure: Dictionary = snapshot.get("infrastructure", {})
	var constraints: Dictionary = infrastructure.get("industry", {})
	var local_logistics: Dictionary = infrastructure.get("local_logistics", {})
	var infra_status := str(constraints.get("status", "HEALTHY"))
	if str(local_logistics.get("status", "HEALTHY")) == "CONSTRAINED":
		infra_status = "LOGISTICS_LIMITED"
	nodes.append(_node(
		"infrastructure:%s" % location_id, "INFRASTRUCTURE", location_id, location_id,
		I18n.core("industrial_network.infrastructure.title", "Industrial support envelope"),
		I18n.core("industrial_network.infrastructure.subtitle", "Power · cooling · structure · handling"),
		infra_status, [], [], 0.0, 0.0, float(constraints.get("throughput_multiplier", 1.0)),
		{"power":constraints, "local_logistics":local_logistics, "storage":infrastructure.get("storage", {})}, {}, 8,
		{"page":"industry", "section":"facilities", "location_id":location_id}, ["OPEN"]
	))

	_add_edges(snapshot, nodes, edges, demand_rows)
	var focus := _mark_bottlenecks(snapshot.get("bottlenecks", []), nodes, edges, location_id)
	nodes.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	edges.sort_custom(func(a, b): return str(a.get("id", "")) < str(b.get("id", "")))
	var product_rows: Array = products.keys()
	product_rows.sort()
	return {
		"location_id":location_id,
		"generated_at_ms":snapshot.get("generated_at_ms", 0),
		"nodes":nodes,
		"edges":edges,
		"products":product_rows,
		"bottleneck_node_ids":focus.get("nodes", []),
		"bottleneck_edge_ids":focus.get("edges", []),
		"primary_bottleneck":focus.get("primary", ""),
		"signature":_signature(nodes, edges)
	}


func _add_edges(snapshot: Dictionary, nodes: Array, edges: Array, demand_rows: Array) -> void:
	var location_id := str(snapshot.get("location_id", ""))
	var node_ids := {}
	for node_value in nodes:
		node_ids[str((node_value as Dictionary).get("id", ""))] = true
	for source_value in snapshot.get("sources", []):
		var source := source_value as Dictionary
		var source_node := "source:%s" % str(source.get("source_id", ""))
		for output_value in source.get("outputs", []):
			var output := output_value as Dictionary
			var item_id := str(output.get("item_id", ""))
			_append_edge(edges, source_node, "out:%s" % item_id, "buffer:%s:%s" % [location_id, item_id], "in:%s" % item_id, item_id, "MATERIAL", float(output.get("actual_rate", 0.0)), float(output.get("requested_rate", 0.0)), float(output.get("capacity", 0.0)), 0.0, str(source.get("status", "IDLE")))
	for line_value in snapshot.get("lines", []):
		var line := line_value as Dictionary
		var line_node := "production:%s" % str(line.get("line_id", ""))
		for input_value in line.get("inputs", []):
			var input := input_value as Dictionary
			var item_id := str(input.get("item_id", ""))
			_append_edge(edges, "buffer:%s:%s" % [location_id, item_id], "out:%s" % item_id, line_node, "in:%s" % item_id, item_id, "MATERIAL", float(input.get("actual_rate", 0.0)), float(input.get("requested_rate", 0.0)), float(input.get("requested_rate", 0.0)), 0.0, str(line.get("status", "PAUSED")))
		for output_value in line.get("outputs", []):
			var output := output_value as Dictionary
			var item_id := str(output.get("item_id", ""))
			_append_edge(edges, line_node, "out:%s" % item_id, "buffer:%s:%s" % [location_id, item_id], "in:%s" % item_id, item_id, "MATERIAL", float(output.get("actual_rate", 0.0)), float(output.get("requested_rate", 0.0)), float(output.get("requested_rate", 0.0)), 0.0, str(line.get("status", "PAUSED")))
	for route_value in snapshot.get("logistics", []):
		var route := route_value as Dictionary
		var route_node := "logistics:%s" % str(route.get("route_id", ""))
		var inbound := str(route.get("direction", "INBOUND")) == "INBOUND"
		var cargo: Dictionary = route.get("cargo", {})
		var cargo_rate: Dictionary = route.get("cargo_rate", {})
		var item_ids: Array = cargo.keys()
		item_ids.sort()
		for item_id_value in item_ids:
			var item_id := str(item_id_value)
			var source_id := route_node if inbound else "buffer:%s:%s" % [location_id, item_id]
			var target_id := "buffer:%s:%s" % [location_id, item_id] if inbound else route_node
			_append_edge(edges, source_id, "out:%s" % item_id, target_id, "in:%s" % item_id, item_id, "LOGISTICS", float(cargo_rate.get(item_id, 0.0)), float(cargo_rate.get(item_id, 0.0)), float(route.get("capacity", 0.0)), float(cargo.get(item_id, 0.0)), str(route.get("status", "NO_TRANSPORT")))
	for demand_value in demand_rows:
		var demand := demand_value as Dictionary
		var product_id := str(demand.get("product_id", ""))
		_append_edge(edges, "buffer:%s:%s" % [location_id, product_id], "out:%s" % product_id, "demand:%s" % str(demand.get("demand_id", "")), "in:%s" % product_id, product_id, "DEMAND", 0.0, float(demand.get("rate", 0.0)), 0.0, 0.0, "REQUESTED")
	# Ignore any edge whose domain endpoint was removed by visibility rules.
	for index in range(edges.size() - 1, -1, -1):
		var edge := edges[index] as Dictionary
		if not node_ids.has(str(edge.get("source", ""))) or not node_ids.has(str(edge.get("target", ""))):
			edges.remove_at(index)


func _aggregate_demands(values: Array) -> Array:
	var grouped := {}
	var passthrough: Array = []
	for value in values:
		var demand := value as Dictionary
		var rate := maxf(0.0, float(demand.get("rate", 0.0)))
		var backlog := maxf(0.0, float(demand.get("backlog", demand.get("quantity", 0.0))))
		if rate <= 0.000001 and backlog <= 0.000001:
			continue
		var source_type := str(demand.get("source_type", "manual_order"))
		var demand_kind := str(demand.get("demand_kind", "COMMITTED"))
		if demand_kind != "CONTINUOUS" and source_type not in ["maintenance", "fleet_operation"]:
			passthrough.append(demand.duplicate(true))
			continue
		var product_id := str(demand.get("product_id", ""))
		var group_key := "%s:%s" % [source_type, product_id]
		var row: Dictionary = grouped.get(group_key, {
			"demand_id":"aggregate:%s" % group_key, "product_id":product_id,
			"demand_kind":"CONTINUOUS", "source_type":source_type,
			"source_id":"aggregate:%s" % source_type, "source_ids":[],
			"priority":0, "rate":0.0, "quantity":0.0, "backlog":0.0
		})
		row["rate"] = float(row.get("rate", 0.0)) + rate
		row["quantity"] = float(row.get("quantity", 0.0)) + maxf(0.0, float(demand.get("quantity", 0.0)))
		row["backlog"] = float(row.get("backlog", 0.0)) + backlog
		row["priority"] = maxi(int(row.get("priority", 0)), int(demand.get("priority", 50)))
		row["source_ids"].append(str(demand.get("source_id", demand.get("demand_id", ""))))
		grouped[group_key] = row
	var result: Array = passthrough
	result.append_array(grouped.values())
	result.sort_custom(func(a, b): return str((a as Dictionary).get("demand_id", "")) < str((b as Dictionary).get("demand_id", "")))
	return result


func _append_edge(edges: Array, source: String, source_port: String, target: String, target_port: String, item_id: String, layer: String, actual: float, requested: float, capacity: float, in_transit: float, source_status: String) -> void:
	if source.is_empty() or target.is_empty() or item_id.is_empty():
		return
	var edge_id := "edge:%s:%s>%s:%s:%s" % [source, source_port, target, target_port, item_id]
	var utilization := _ratio(actual, capacity)
	var status := "ACTIVE" if actual > 0.000001 else ("REQUESTED" if layer == "DEMAND" and requested > 0.000001 else ("BLOCKED" if requested > 0.000001 else "IDLE"))
	if source_status in ["SATURATED", "LOGISTICS_LIMITED", "ROUTE_CONGESTED"] or layer == "LOGISTICS" and utilization >= 0.90:
		status = "CONGESTED"
	elif source_status in ["PAUSED", "IDLE", "NO_TRANSPORT"]:
		status = "PAUSED"
	edges.append({
		"id":edge_id, "source":source, "target":target,
		"source_port":source_port, "target_port":target_port,
		"item_id":item_id, "service_type":layer, "layer":layer,
		"actual_flow":actual, "requested_flow":requested, "capacity":capacity,
		"in_transit":in_transit, "utilization":utilization, "status":status,
		"congested":status == "CONGESTED", "blocked":status == "BLOCKED", "in_bottleneck":false
	})


func _mark_bottlenecks(bottlenecks: Array, nodes: Array, edges: Array, location_id: String) -> Dictionary:
	var marked := {}
	var primary := ""
	var primary_trace: Dictionary = {}
	for trace_value in bottlenecks:
		var candidate := trace_value as Dictionary
		if not (candidate.get("shortest_chain", []) as Array).is_empty():
			primary_trace = candidate
			break
	if not primary_trace.is_empty():
		primary = str(primary_trace.get("primary_bottleneck", ""))
	for link_value in primary_trace.get("shortest_chain", []):
		var link := link_value as Dictionary
		var kind := str(link.get("kind", ""))
		var id := str(link.get("id", ""))
		match kind:
			"PRODUCT": marked["buffer:%s:%s" % [location_id, id]] = true
			"ROUTE": marked["logistics:%s" % id] = true
			"SITE": marked["source:%s" % id] = true
			"FACTORY":
				for node_value in nodes:
					var node := node_value as Dictionary
					if str(node.get("data", {}).get("facility_id", "")) == id:
						marked[str(node.get("id", ""))] = true
			"METHOD":
				for node_value in nodes:
					var node := node_value as Dictionary
					if str(node.get("data", {}).get("method_id", "")) == id:
						marked[str(node.get("id", ""))] = true
	var node_ids: Array = marked.keys()
	node_ids.sort()
	for node_value in nodes:
		var node := node_value as Dictionary
		node["in_bottleneck"] = marked.has(str(node.get("id", "")))
	var edge_ids: Array = []
	for edge_value in edges:
		var edge := edge_value as Dictionary
		if marked.has(str(edge.get("source", ""))) and marked.has(str(edge.get("target", ""))):
			edge["in_bottleneck"] = true
			edge_ids.append(str(edge.get("id", "")))
	edge_ids.sort()
	return {"nodes":node_ids, "edges":edge_ids, "primary":primary}


func _node(id: String, kind: String, entity_id: String, location_id: String, title: String, subtitle: String, status: String, inputs: Array, outputs: Array, actual_rate: float, theoretical_rate: float, utilization: float, buffer: Dictionary, blocker_value, column: int, navigation: Dictionary, actions: Array) -> Dictionary:
	var blocker: Dictionary = blocker_value if blocker_value is Dictionary else {}
	return {
		"id":id, "kind":kind, "domain_entity_id":entity_id, "location_id":location_id,
		"title":title, "subtitle":subtitle, "status":status,
		"inputs":inputs, "outputs":outputs,
		"actual_rate":actual_rate, "theoretical_rate":theoretical_rate,
		"utilization":clampf(utilization, 0.0, 1.0), "buffer":buffer,
		"blocker":blocker, "navigation_target":navigation, "allowed_actions":actions,
		"column":maxi(0, column), "in_bottleneck":false, "data":buffer
	}


func _port_rows(values: Array, input: bool) -> Array:
	var rows: Array = []
	for value in values:
		var row := (value as Dictionary).duplicate(true)
		var item_id := str(row.get("item_id", ""))
		row["id"] = ("in:" if input else "out:") + item_id
		row["title"] = _name(_content.items, item_id, item_id)
		row["port_type"] = str(row.get("port_type", "MATERIAL"))
		row["connected"] = float(row.get("actual_rate", row.get("capacity", 0.0))) > 0.000001
		rows.append(row)
	rows.sort_custom(func(a, b): return str(a.get("item_id", "")) < str(b.get("item_id", "")))
	return rows


func _product_rank(product_id: String, visiting: Dictionary) -> int:
	if _rank_cache.has(product_id):
		return int(_rank_cache[product_id])
	if visiting.has(product_id):
		return 0
	var next_visiting := visiting.duplicate()
	next_visiting[product_id] = true
	var best := 0
	var activity_ids: Array = _content.activities.keys()
	activity_ids.sort()
	for activity_id_value in activity_ids:
		var activity: Dictionary = _content.activities.get(str(activity_id_value), {})
		if str(activity.get("domain", "")) != "industry" or not bool(activity.get("repeat", true)):
			continue
		if not activity.get("rewards", []).any(func(reward): return str((reward as Dictionary).get("item", "")) == product_id):
			continue
		var input_rank := 0
		for cost_value in activity.get("costs", []):
			input_rank = maxi(input_rank, _product_rank(str((cost_value as Dictionary).get("item", "")), next_visiting))
		best = maxi(best, input_rank + 1)
	_rank_cache[product_id] = mini(best, 6)
	return int(_rank_cache[product_id])


func _demand_title(demand: Dictionary) -> String:
	var source_type := str(demand.get("source_type", "manual_order"))
	return I18n.core("industrial_network.demand.%s" % source_type, source_type.replace("_", " ").capitalize())


func _demand_navigation(demand: Dictionary) -> Dictionary:
	var source_type := str(demand.get("source_type", "manual_order"))
	var page := "inventory"
	if source_type in ["construction", "megastructure"]:
		page = "construction" if source_type == "construction" else "megastructure"
	elif source_type == "research_project":
		page = "research"
	elif source_type in ["shipbuilding", "fleet_operation"]:
		page = "fleet"
	elif source_type == "logistics_export":
		page = "logistics"
	return {"page":page, "entity_id":demand.get("source_id", demand.get("demand_id", ""))}


func _name(table: Dictionary, id: String, fallback: String) -> String:
	var definition: Dictionary = table.get(id, {"id":id, "name":fallback})
	var localized := I18n.content(definition)
	return localized if not localized.is_empty() else str(definition.get("name", fallback))


func _sum_field(rows: Array, field: String) -> float:
	var result := 0.0
	for row_value in rows:
		result += float((row_value as Dictionary).get(field, 0.0))
	return result


func _ratio(value: float, maximum: float) -> float:
	return 0.0 if maximum <= 0.000001 else clampf(value / maximum, 0.0, 1.0)


func _signature(nodes: Array, edges: Array) -> String:
	var parts: Array[String] = []
	for node_value in nodes:
		var node := node_value as Dictionary
		parts.append("%s|%s|%s|%.4f|%.4f" % [node.get("id", ""), node.get("status", ""), node.get("title", ""), node.get("actual_rate", 0.0), node.get("utilization", 0.0)])
	for edge_value in edges:
		var edge := edge_value as Dictionary
		parts.append("%s|%s|%.4f|%.4f" % [edge.get("id", ""), edge.get("status", ""), edge.get("actual_flow", 0.0), edge.get("requested_flow", 0.0)])
	return "\n".join(parts).sha256_text()
