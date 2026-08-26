class_name LogisticsEngine
extends RefCounted

const MODE_SUPPLY := "SUPPLY"
const MODE_DEMAND := "DEMAND"
const MODE_STORAGE := "STORAGE"
const DISPATCH_INTERVAL_MS := 5000.0
const DEFAULT_STORAGE_CAPACITY := 1000000
const DEFAULT_HUB_THROUGHPUT := 100
const DEFAULT_LOCAL_THROUGHPUT := 100.0
const BASE_LOGISTICS_TECH := {
	"id":"chemical_cargo",
	"name":"Chemical Cargo",
	"logistics_tier":0,
	"freight_capacity_multiplier":1.0,
	"transit_time_multiplier":1.0,
	"fuel_cost_multiplier":1.0,
	"energy_per_route_unit":0.0,
	"maintenance_cost_per_route":1.0,
	"loading_time_ms_per_unit":40.0
}

var content: ContentDatabase


func _init(database: ContentDatabase) -> void:
	content = database


func ensure_state(state: SpaceGameState) -> void:
	if state.logistics_network is not Dictionary:
		state.logistics_network = {}
	var network: Dictionary = state.logistics_network
	if network.get("shipments", null) is not Array:
		network["shipments"] = []
	if network.get("route_statistics", null) is not Dictionary:
		network["route_statistics"] = {}
	if network.get("item_statistics", null) is not Dictionary:
		network["item_statistics"] = {}
	network["dispatch_interval_ms"] = maxf(100.0, float(network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS)))
	network["dispatch_progress_ms"] = maxf(0.0, float(network.get("dispatch_progress_ms", 0.0)))
	network["next_shipment_serial"] = maxi(1, int(network.get("next_shipment_serial", 1)))
	for location_value in state.locations.values():
		var location := location_value as Dictionary
		var runtime: Dictionary = location.get("logistics", {}) if location.get("logistics", null) is Dictionary else {}
		runtime["policies"] = runtime.get("policies", {}).duplicate(true) if runtime.get("policies", null) is Dictionary else {}
		runtime["storage_capacity"] = maxi(0, int(runtime.get("storage_capacity", DEFAULT_STORAGE_CAPACITY)))
		runtime["hub_throughput"] = maxi(0, int(runtime.get("hub_throughput", DEFAULT_HUB_THROUGHPUT)))
		runtime["local_throughput_capacity"] = maxf(0.0, float(runtime.get("local_throughput_capacity", DEFAULT_LOCAL_THROUGHPUT)))
		location["logistics"] = runtime
	_normalize_shipments(state)


func configure_policy(state: SpaceGameState, location_id: String, item_id: String, policy: Dictionary) -> bool:
	ensure_state(state)
	if not state.has_location(location_id) or not content.items.has(item_id):
		return false
	var mode := str(policy.get("mode", MODE_STORAGE)).to_upper()
	if mode not in [MODE_SUPPLY, MODE_DEMAND, MODE_STORAGE]:
		return false
	var normalized := {
		"mode":mode,
		"reserve":maxi(0, int(policy.get("reserve", 0))),
		"target":maxi(0, int(policy.get("target", 0))),
		"priority":clampi(int(policy.get("priority", 50)), 0, 100),
		"dispatch_threshold":maxi(1, int(policy.get("dispatch_threshold", 1))),
		"source_lock":str(policy.get("source_lock", ""))
	}
	if not normalized.source_lock.is_empty() and not state.has_location(normalized.source_lock):
		return false
	state.locations[location_id]["logistics"]["policies"][item_id] = normalized
	return true


func clear_policy(state: SpaceGameState, location_id: String, item_id: String) -> bool:
	ensure_state(state)
	if not state.has_location(location_id):
		return false
	state.locations[location_id]["logistics"]["policies"].erase(item_id)
	return true


func set_hub_limits(state: SpaceGameState, location_id: String, storage_capacity: int, hub_throughput: int) -> bool:
	ensure_state(state)
	if not state.has_location(location_id):
		return false
	var runtime: Dictionary = state.locations[location_id]["logistics"]
	runtime["storage_capacity"] = maxi(0, storage_capacity)
	runtime["hub_throughput"] = maxi(0, hub_throughput)
	return true


func technology_profile(state: SpaceGameState) -> Dictionary:
	var result := BASE_LOGISTICS_TECH.duplicate(true)
	for technology_value in content.technologies.values():
		var technology := technology_value as Dictionary
		var technology_id := str(technology.get("id", ""))
		if not bool(state.technologies.get(technology_id, false)) or int(technology.get("logistics_tier", -1)) <= int(result.get("logistics_tier", 0)):
			continue
		result.merge({
			"id":technology_id,
			"name":technology.get("logistics_system_name", technology.get("name", technology_id)),
			"logistics_tier":int(technology.get("logistics_tier", 0)),
			"freight_capacity_multiplier":maxf(0.01, float(technology.get("freight_capacity_multiplier", 1.0))),
			"transit_time_multiplier":maxf(0.01, float(technology.get("transit_time_multiplier", 1.0))),
			"fuel_cost_multiplier":maxf(0.0, float(technology.get("fuel_cost_multiplier", 1.0))),
			"energy_per_route_unit":maxf(0.0, float(technology.get("energy_per_route_unit", 0.0))),
			"maintenance_cost_per_route":maxf(0.0, float(technology.get("maintenance_cost_per_route", 1.0))),
			"loading_time_ms_per_unit":maxf(0.0, float(technology.get("loading_time_ms_per_unit", 40.0)))
		}, true)
	return result


func effective_route_capacity(state: SpaceGameState, route_id: String) -> int:
	var route: Dictionary = content.logistics_routes.get(route_id, {})
	return maxi(0, int(floor(float(route.get("freight_capacity", 0)) * float(technology_profile(state).get("freight_capacity_multiplier", 1.0)))))


func effective_route_transit_time_ms(state: SpaceGameState, route_id: String) -> float:
	var route: Dictionary = content.logistics_routes.get(route_id, {})
	return maxf(1.0, float(route.get("transit_time_ms", 1.0)) * float(technology_profile(state).get("transit_time_multiplier", 1.0)))


func next_event_ms(state: SpaceGameState) -> float:
	ensure_state(state)
	var result := INF
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		result = minf(result, maxf(0.001, float(shipment.get("remaining_ms", 0.0))))
	if _has_dispatch_policies(state):
		var interval := float(state.logistics_network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS))
		result = minf(result, maxf(0.001, interval - float(state.logistics_network.get("dispatch_progress_ms", 0.0))))
	return result


func advance_clock(state: SpaceGameState, elapsed_ms: float) -> void:
	ensure_state(state)
	if elapsed_ms <= 0.0:
		return
	if _has_dispatch_policies(state):
		state.logistics_network["dispatch_progress_ms"] = float(state.logistics_network.get("dispatch_progress_ms", 0.0)) + elapsed_ms
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		shipment["remaining_ms"] = maxf(0.0, float(shipment.get("remaining_ms", 0.0)) - elapsed_ms)


func settle_ready(state: SpaceGameState) -> Dictionary:
	ensure_state(state)
	var events: Array[Dictionary] = []
	var settled := 0
	var remaining_shipments: Array = []
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if float(shipment.get("remaining_ms", 0.0)) > 0.001:
			remaining_shipments.append(shipment)
			continue
		_deliver_shipment(state, shipment)
		events.append({
			"type":"ShipmentArrived",
			"shipment_id":shipment.get("id", ""),
			"origin":shipment.get("origin", ""),
			"destination":shipment.get("destination", ""),
			"cargo":shipment.get("cargo", {}).duplicate(true)
		})
		settled += 1
	state.logistics_network["shipments"] = remaining_shipments
	var interval := float(state.logistics_network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS))
	if _has_dispatch_policies(state) and float(state.logistics_network.get("dispatch_progress_ms", 0.0)) + 0.001 >= interval:
		state.logistics_network["dispatch_progress_ms"] = maxf(0.0, float(state.logistics_network.get("dispatch_progress_ms", 0.0)) - interval)
		var dispatch_events := _dispatch(state)
		events.append_array(dispatch_events)
		settled += 1
	return {"boundaries":settled, "events":events}


func location_summary(state: SpaceGameState, location_id: String) -> Dictionary:
	ensure_state(state)
	if not state.has_location(location_id):
		return {"status":"NOT_CONNECTED"}
	var policies: Dictionary = state.locations[location_id].get("logistics", {}).get("policies", {})
	var inbound := 0
	var outbound := 0
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if str(shipment.get("destination", "")) == location_id:
			inbound += 1
		if str(shipment.get("origin", "")) == location_id:
			outbound += 1
	var route_count := 0
	for route_value in content.logistics_routes.values():
		var route := route_value as Dictionary
		var from_id := str(route.get("from", ""))
		var to_id := str(route.get("to", ""))
		var peer_id := to_id if from_id == location_id else (from_id if to_id == location_id else "")
		if peer_id.is_empty() or not state.has_location(peer_id):
			continue
		if str(state.location_state(peer_id).get("discovery_state", "UNDISCOVERED")) == LocationState.DISCOVERED:
			route_count += 1
	return {
		"status":"CONNECTED" if route_count > 0 else "NOT_CONNECTED",
		"policy_count":policies.size(),
		"inbound_shipments":inbound,
		"outbound_shipments":outbound,
		"route_count":route_count,
		"local_throughput_capacity":float(state.locations[location_id].get("logistics", {}).get("local_throughput_capacity", DEFAULT_LOCAL_THROUGHPUT)),
		"technology_profile":technology_profile(state)
	}


func incoming_quantity(state: SpaceGameState, location_id: String, item_id: String) -> int:
	var result := 0
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if str(shipment.get("destination", "")) == location_id:
			result += int(shipment.get("cargo", {}).get(item_id, 0))
	return result


func _dispatch(state: SpaceGameState) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var profile := technology_profile(state)
	var energy_per_unit_per_route := float(profile.get("energy_per_route_unit", 0.0))
	var route_budget := {}
	for route_id in content.logistics_routes:
		route_budget[route_id] = effective_route_capacity(state, str(route_id))
	var hub_budget := {}
	var energy_budget := {}
	for location_id in state.locations:
		hub_budget[location_id] = maxi(0, int(state.locations[location_id].get("logistics", {}).get("hub_throughput", DEFAULT_HUB_THROUGHPUT)))
		var location: Dictionary = state.locations[location_id]
		var fallback_power := float(location.get("industry", {}).get("power_capacity", 0.0))
		var available_power := maxf(0.0, float(location.get("power", {}).get("available_capacity", fallback_power)))
		energy_budget[location_id] = available_power * float(state.logistics_network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS)) / 1000.0
	var demands := _demand_rows(state)
	demands.sort_custom(func(a, b):
		return int(a.get("priority", 50)) > int(b.get("priority", 50)) if int(a.get("priority", 50)) != int(b.get("priority", 50)) else (str(a.get("location_id", "")) + ":" + str(a.get("item_id", ""))) < (str(b.get("location_id", "")) + ":" + str(b.get("item_id", "")))
	)
	for demand_value in demands:
		var demand := demand_value as Dictionary
		var destination := str(demand.get("location_id", ""))
		var item_id := str(demand.get("item_id", ""))
		var deficit := maxi(0, int(demand.get("target", 0)) - state.item_quantity(item_id, destination) - incoming_quantity(state, destination, item_id))
		var destination_free := _destination_free_capacity(state, destination)
		deficit = mini(deficit, destination_free)
		if deficit <= 0:
			continue
		var suppliers := _supplier_rows(state, item_id, str(demand.get("source_lock", "")))
		for supplier_value in suppliers:
			if deficit <= 0:
				break
			var supplier := supplier_value as Dictionary
			var origin := str(supplier.get("location_id", ""))
			var path := _shortest_path(state, origin, destination)
			if path.is_empty():
				continue
			var available := _supply_available(state, origin, item_id, int(supplier.get("reserve", 0)))
			var path_energy_per_unit := energy_per_unit_per_route * float(path.get("route_ids", []).size())
			var capacity := _path_dispatch_capacity(path, route_budget, hub_budget, energy_budget, path_energy_per_unit)
			var costs := _path_costs(state, path)
			if costs.has(item_id):
				available = maxi(0, available - int(costs[item_id]))
			if available <= 0 or capacity <= 0 or not _costs_available(state, origin, costs):
				continue
			var quantity := mini(deficit, mini(available, capacity))
			var threshold := maxi(1, int(supplier.get("dispatch_threshold", 1)))
			if quantity < threshold and quantity < deficit:
				continue
			var shipment := _create_shipment(state, origin, destination, item_id, quantity, path, costs)
			if shipment.is_empty():
				continue
			_consume_path_capacity(path, quantity, route_budget, hub_budget, energy_budget, path_energy_per_unit)
			deficit -= quantity
			events.append({
				"type":"ShipmentDispatched",
				"shipment_id":shipment.get("id", ""),
				"origin":origin,
				"destination":destination,
				"cargo":shipment.get("cargo", {}).duplicate(true),
				"eta_ms":shipment.get("total_ms", 0.0)
			})
	return events


func _demand_rows(state: SpaceGameState) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for location_id in state.locations:
		if str(state.locations[location_id].get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED:
			continue
		for item_id in state.locations[location_id].get("logistics", {}).get("policies", {}):
			var policy: Dictionary = state.locations[location_id]["logistics"]["policies"][item_id]
			if str(policy.get("mode", MODE_STORAGE)) != MODE_DEMAND:
				continue
			var row := policy.duplicate(true)
			row["location_id"] = str(location_id)
			row["item_id"] = str(item_id)
			result.append(row)
	# A live Megastructure is a real material sink at its construction Location.
	# Project demand participates in the same network as player-authored policies,
	# but it never creates a supplier or overrides an endpoint policy.
	for project_value in state.megastructure_projects.values():
		var project := project_value as Dictionary
		if str(project.get("status", "")) not in ["BUILDING", "BLOCKED"]:
			continue
		var location_id := str(project.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var activity: Dictionary = content.activities.get(str(project.get("activity_id", "")), {})
		if not state.has_location(location_id) or activity.is_empty():
			continue
		var delivered: Dictionary = project.get("delivered_materials", {})
		for cost_value in activity.get("costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			var remaining := maxi(0, int(cost.get("quantity", 0)) - int(delivered.get(item_id, 0)))
			if remaining <= 0:
				continue
			result.append({
				"mode":MODE_DEMAND,
				"reserve":0,
				"target":remaining,
				"priority":100,
				"dispatch_threshold":1,
				"source_lock":"",
				"location_id":location_id,
				"item_id":item_id,
				"demand_kind":"MEGASTRUCTURE",
				"project_id":project.get("id", "")
			})
	return result


func _supplier_rows(state: SpaceGameState, item_id: String, source_lock: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for location_id in state.locations:
		if not source_lock.is_empty() and str(location_id) != source_lock:
			continue
		var policy: Dictionary = state.locations[location_id].get("logistics", {}).get("policies", {}).get(item_id, {})
		if str(policy.get("mode", MODE_STORAGE)) != MODE_SUPPLY:
			continue
		var row := policy.duplicate(true)
		row["location_id"] = str(location_id)
		result.append(row)
	result.sort_custom(func(a, b): return str(a.get("location_id", "")) < str(b.get("location_id", "")))
	return result


func _supply_available(state: SpaceGameState, location_id: String, item_id: String, reserve: int) -> int:
	var above_policy_reserve := maxi(0, state.item_quantity(item_id, location_id) - reserve)
	return mini(above_policy_reserve, state.available_item_quantity(item_id, location_id))


func _destination_free_capacity(state: SpaceGameState, location_id: String) -> int:
	var capacity := int(state.locations[location_id].get("logistics", {}).get("storage_capacity", DEFAULT_STORAGE_CAPACITY))
	var committed := 0
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if str(shipment.get("destination", "")) == location_id:
			for quantity in shipment.get("cargo", {}).values():
				committed += int(quantity)
	return maxi(0, capacity - state.total_inventory_units(location_id) - committed)


func _create_shipment(state: SpaceGameState, origin: String, destination: String, item_id: String, quantity: int, path: Dictionary, costs: Dictionary) -> Dictionary:
	if quantity <= 0 or state.item_quantity(item_id, origin) < quantity:
		return {}
	for cost_item in costs:
		if not state.remove_item(str(cost_item), int(costs[cost_item]), origin):
			return {}
	# Cargo changes ownership but is neither produced nor consumed.
	state.location_inventory(origin)[item_id] = state.item_quantity(item_id, origin) - quantity
	var serial := int(state.logistics_network.get("next_shipment_serial", 1))
	state.logistics_network["next_shipment_serial"] = serial + 1
	var profile := technology_profile(state)
	var handling_time_ms := float(quantity) * float(profile.get("loading_time_ms_per_unit", 40.0)) * 2.0
	var total_time_ms := float(path.get("transit_time_ms", 0.0)) + handling_time_ms
	var shipment := {
		"id":"SHIPMENT-%06d" % serial,
		"origin":origin,
		"destination":destination,
		"cargo":{item_id:quantity},
		"route_path":path.get("route_ids", []).duplicate(),
		"node_path":path.get("nodes", []).duplicate(),
		"remaining_ms":total_time_ms,
		"total_ms":total_time_ms,
		"transit_time_ms":float(path.get("transit_time_ms", 0.0)),
		"handling_time_ms":handling_time_ms,
		"costs":costs.duplicate(true),
		"logistics_technology_id":profile.get("id", "chemical_cargo"),
		"energy_units":float(profile.get("energy_per_route_unit", 0.0)) * float(quantity) * float(path.get("route_ids", []).size()),
		"dispatched_at_ms":int(state.total_elapsed_ms)
	}
	state.logistics_network["shipments"].append(shipment)
	for route_id in shipment.route_path:
		var route_stats: Dictionary = state.logistics_network["route_statistics"].get(str(route_id), {"shipments":0, "units":0, "energy_units":0.0})
		route_stats["shipments"] = int(route_stats.get("shipments", 0)) + 1
		route_stats["units"] = int(route_stats.get("units", 0)) + quantity
		route_stats["energy_units"] = float(route_stats.get("energy_units", 0.0)) + float(technology_profile(state).get("energy_per_route_unit", 0.0)) * float(quantity)
		state.logistics_network["route_statistics"][str(route_id)] = route_stats
	return shipment


func _deliver_shipment(state: SpaceGameState, shipment: Dictionary) -> void:
	var destination := str(shipment.get("destination", SpaceGameState.MAIN_BASE_LOCATION_ID))
	for item_id in shipment.get("cargo", {}):
		# Arrival changes location ownership without counting as production.
		state.ensure_location(destination, LocationState.ARTIFICIAL if destination == SpaceGameState.MAIN_BASE_LOCATION_ID else LocationState.NATURAL, true)
		state.location_inventory(destination)[str(item_id)] = state.item_quantity(str(item_id), destination) + int(shipment["cargo"][item_id])
		var item_stats: Dictionary = state.logistics_network["item_statistics"].get(str(item_id), {"delivered":0})
		item_stats["delivered"] = int(item_stats.get("delivered", 0)) + int(shipment["cargo"][item_id])
		state.logistics_network["item_statistics"][str(item_id)] = item_stats


func _path_dispatch_capacity(path: Dictionary, route_budget: Dictionary, hub_budget: Dictionary, energy_budget: Dictionary = {}, energy_per_unit: float = 0.0) -> int:
	var result := 2147483647
	for route_id in path.get("route_ids", []):
		result = mini(result, int(route_budget.get(str(route_id), 0)))
	for node_id in path.get("nodes", []):
		result = mini(result, int(hub_budget.get(str(node_id), 0)))
		if energy_per_unit > 0.0:
			result = mini(result, int(floor(float(energy_budget.get(str(node_id), 0.0)) / energy_per_unit)))
	return maxi(0, result if result != 2147483647 else 0)


func _consume_path_capacity(path: Dictionary, quantity: int, route_budget: Dictionary, hub_budget: Dictionary, energy_budget: Dictionary = {}, energy_per_unit: float = 0.0) -> void:
	for route_id in path.get("route_ids", []):
		route_budget[str(route_id)] = maxi(0, int(route_budget.get(str(route_id), 0)) - quantity)
	for node_id in path.get("nodes", []):
		hub_budget[str(node_id)] = maxi(0, int(hub_budget.get(str(node_id), 0)) - quantity)
		if energy_per_unit > 0.0:
			energy_budget[str(node_id)] = maxf(0.0, float(energy_budget.get(str(node_id), 0.0)) - float(quantity) * energy_per_unit)


func _path_costs(state: SpaceGameState, path: Dictionary) -> Dictionary:
	var result := {}
	var profile := technology_profile(state)
	var fuel_multiplier := float(profile.get("fuel_cost_multiplier", 1.0))
	for route_id in path.get("route_ids", []):
		for cost_value in content.logistics_routes.get(str(route_id), {}).get("dispatch_costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			var adjusted := maxi(0, int(ceil(float(cost.get("quantity", 0)) * fuel_multiplier)))
			if adjusted > 0:
				result[item_id] = int(result.get(item_id, 0)) + adjusted
	var maintenance_item := str(content.fleet_rules.get("maintenance_item", "repair_material"))
	var maintenance_cost := maxi(0, int(ceil(float(path.get("route_ids", []).size()) * float(profile.get("maintenance_cost_per_route", 1.0)))))
	if not maintenance_item.is_empty() and maintenance_cost > 0:
		result[maintenance_item] = int(result.get(maintenance_item, 0)) + maintenance_cost
	return result


func _costs_available(state: SpaceGameState, origin: String, costs: Dictionary) -> bool:
	for item_id in costs:
		var policy: Dictionary = state.location_state(origin).get("logistics", {}).get("policies", {}).get(str(item_id), {})
		var protected_reserve := int(policy.get("reserve", 0)) if str(policy.get("mode", MODE_STORAGE)) == MODE_SUPPLY else 0
		if state.available_item_quantity(str(item_id), origin) - protected_reserve < int(costs[item_id]):
			return false
	return true


func _shortest_path(state: SpaceGameState, origin: String, destination: String) -> Dictionary:
	if origin == destination:
		return {}
	return _find_path(state, origin, destination, [], [origin])


func _find_path(state: SpaceGameState, current: String, destination: String, used_routes: Array, nodes: Array) -> Dictionary:
	var best := {}
	for edge in _edges_from(state, current):
		var route_id := str(edge.get("route_id", ""))
		var next_node := str(edge.get("to", ""))
		if used_routes.has(route_id) or nodes.has(next_node):
			continue
		var candidate_routes := used_routes.duplicate()
		candidate_routes.append(route_id)
		var candidate_nodes := nodes.duplicate()
		candidate_nodes.append(next_node)
		var candidate := {}
		if next_node == destination:
			candidate = {"route_ids":candidate_routes, "nodes":candidate_nodes, "transit_time_ms":_path_transit_time(state, candidate_routes)}
		else:
			candidate = _find_path(state, next_node, destination, candidate_routes, candidate_nodes)
		if candidate.is_empty():
			continue
		if best.is_empty() or float(candidate.get("transit_time_ms", INF)) < float(best.get("transit_time_ms", INF)):
			best = candidate
	return best


func _edges_from(state: SpaceGameState, location_id: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for route_id in content.logistics_routes:
		var route: Dictionary = content.logistics_routes[route_id]
		var from_id := str(route.get("from", ""))
		var to_id := str(route.get("to", ""))
		if not state.has_location(from_id) or not state.has_location(to_id):
			continue
		if str(state.location_state(from_id).get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED or str(state.location_state(to_id).get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED:
			continue
		if from_id == location_id:
			result.append({"route_id":str(route_id), "to":to_id})
		if bool(route.get("bidirectional", true)) and to_id == location_id:
			result.append({"route_id":str(route_id), "to":from_id})
	return result


func _path_transit_time(state: SpaceGameState, route_ids: Array) -> float:
	var result := 0.0
	for route_id in route_ids:
		result += effective_route_transit_time_ms(state, str(route_id))
	return result


func _has_dispatch_policies(state: SpaceGameState) -> bool:
	for location_value in state.locations.values():
		var location := location_value as Dictionary
		for policy_value in location.get("logistics", {}).get("policies", {}).values():
			if str((policy_value as Dictionary).get("mode", MODE_STORAGE)) in [MODE_SUPPLY, MODE_DEMAND]:
				return true
	return false


func _normalize_shipments(state: SpaceGameState) -> void:
	var normalized: Array = []
	for shipment_value in state.logistics_network.get("shipments", []):
		if shipment_value is not Dictionary:
			continue
		var shipment: Dictionary = shipment_value
		if str(shipment.get("id", "")).is_empty() or not state.has_location(str(shipment.get("destination", ""))):
			continue
		shipment["cargo"] = shipment.get("cargo", {}).duplicate(true) if shipment.get("cargo", null) is Dictionary else {}
		shipment["remaining_ms"] = maxf(0.0, float(shipment.get("remaining_ms", 0.0)))
		shipment["handling_time_ms"] = maxf(0.0, float(shipment.get("handling_time_ms", 0.0)))
		shipment["logistics_technology_id"] = str(shipment.get("logistics_technology_id", "chemical_cargo"))
		shipment["energy_units"] = maxf(0.0, float(shipment.get("energy_units", 0.0)))
		normalized.append(shipment)
	state.logistics_network["shipments"] = normalized
