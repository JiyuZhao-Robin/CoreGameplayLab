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
	if network.get("services", null) is not Dictionary:
		network["services"] = {}
	network["dispatch_interval_ms"] = maxf(100.0, float(network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS)))
	network["dispatch_progress_ms"] = maxf(0.0, float(network.get("dispatch_progress_ms", 0.0)))
	network["next_shipment_serial"] = maxi(1, int(network.get("next_shipment_serial", 1)))
	for route_id_value in content.logistics_routes.keys():
		var route_id := str(route_id_value)
		if network["services"].get(route_id, null) is not Dictionary:
			network["services"][route_id] = _default_service(route_id)
		else:
			network["services"][route_id] = _normalized_service(route_id, network["services"][route_id])
	for location_value in state.locations.values():
		var location := location_value as Dictionary
		var runtime: Dictionary = location.get("logistics", {}) if location.get("logistics", null) is Dictionary else {}
		runtime["policies"] = runtime.get("policies", {}).duplicate(true) if runtime.get("policies", null) is Dictionary else {}
		runtime["storage_capacity"] = maxi(0, int(runtime.get("storage_capacity", DEFAULT_STORAGE_CAPACITY)))
		var capacities: Dictionary = runtime.get("storage_capacities", {}).duplicate(true) if runtime.get("storage_capacities", null) is Dictionary else {}
		if capacities.is_empty():
			capacities = LocationState._split_legacy_storage_capacity(int(runtime["storage_capacity"]))
		for storage_class in content.industry_rules.get("storage_classes", {}).get("classes", ["BULK", "COMPONENT", "FLUID", "SPECIAL"]):
			capacities[str(storage_class)] = maxi(0, int(capacities.get(str(storage_class), 0)))
		runtime["storage_capacities"] = capacities
		runtime["storage_capacity"] = LocationState._total_storage_capacity(capacities)
		runtime["hub_throughput"] = maxi(0, int(runtime.get("hub_throughput", DEFAULT_HUB_THROUGHPUT)))
		runtime["local_throughput_capacity"] = maxf(0.0, float(runtime.get("local_throughput_capacity", DEFAULT_LOCAL_THROUGHPUT)))
		location["logistics"] = runtime
	_normalize_shipments(state)


func _default_service(route_id: String) -> Dictionary:
	var route: Dictionary = content.logistics_routes.get(route_id, {})
	return {
		"id":"SERVICE-%s" % route_id.to_upper(),
		"route_id":route_id,
		"transport_mode_id":str(route.get("default_transport_mode", "general_cargo")),
		"assigned_ship_ids":[],
		"priority_strategy":"DEMAND_PRIORITY",
		"status":"ACTIVE",
		"last_utilization":0.0,
		"last_blocker":{}
	}


func _normalized_service(route_id: String, source: Dictionary) -> Dictionary:
	var result := _default_service(route_id)
	result.merge(source.duplicate(true), true)
	result["route_id"] = route_id
	result["assigned_ship_ids"] = source.get("assigned_ship_ids", []).duplicate() if source.get("assigned_ship_ids", null) is Array else []
	result["priority_strategy"] = str(result.get("priority_strategy", "DEMAND_PRIORITY"))
	result["status"] = str(result.get("status", "ACTIVE"))
	result["last_utilization"] = clampf(float(result.get("last_utilization", 0.0)), 0.0, 1.0)
	result["last_blocker"] = result.get("last_blocker", {}).duplicate(true) if result.get("last_blocker", null) is Dictionary else {}
	return result


func configure_service(state: SpaceGameState, route_id: String, mode_id: String, ship_ids: Array, priority_strategy: String = "DEMAND_PRIORITY") -> bool:
	ensure_state(state)
	if not content.logistics_routes.has(route_id) or not content.transport_modes.has(mode_id) or priority_strategy not in ["DEMAND_PRIORITY", "PRECISION_FIRST", "MAINTENANCE_FIRST", "BULK_FIRST"]:
		return false
	var mode: Dictionary = content.transport_modes[mode_id]
	if not _mode_available(state, mode) or not _mode_available_for_route(state, mode, route_id):
		return false
	var normalized_ship_ids: Array = []
	if bool(mode.get("infrastructure_service", false)) and not ship_ids.is_empty():
		return false
	for ship_id_value in ship_ids:
		var ship_id := str(ship_id_value)
		if normalized_ship_ids.has(ship_id):
			continue
		var ship: Dictionary = state.ship_by_id(ship_id)
		var old_assignment: Dictionary = ship.get("assignment", {})
		var belongs_here := str(old_assignment.get("domain", "")) == "logistics" and str(old_assignment.get("service_id", "")) == "SERVICE-%s" % route_id.to_upper()
		if ship.is_empty() or (not state.ship_is_unassigned_docked(ship_id) and not belongs_here) or str(ship.get("maintenance_state", "ACTIVE")) != "ACTIVE":
			return false
		if not ship_eligible_for_mode(state, ship_id, mode_id):
			return false
		normalized_ship_ids.append(ship_id)
	if not bool(mode.get("infrastructure_service", false)) and not bool(mode.get("public_base_capacity", false)) and normalized_ship_ids.is_empty():
		return false
	var old_service: Dictionary = state.logistics_network["services"].get(route_id, _default_service(route_id))
	for old_ship_id_value in old_service.get("assigned_ship_ids", []):
		var old_ship_id := str(old_ship_id_value)
		if normalized_ship_ids.has(old_ship_id):
			continue
		var released := state.ship_by_id(old_ship_id)
		if not released.is_empty() and str(released.get("assignment", {}).get("service_id", "")) == str(old_service.get("id", "")):
			released["assignment"] = {}
			released["status"] = "DOCKED"
	var service := _default_service(route_id)
	service.merge({"transport_mode_id":mode_id, "assigned_ship_ids":normalized_ship_ids, "priority_strategy":priority_strategy}, true)
	state.logistics_network["services"][route_id] = service
	for ship_id_value in normalized_ship_ids:
		var assigned_ship := state.ship_by_id(str(ship_id_value))
		assigned_ship["assignment"] = {"domain":"logistics", "service_id":service["id"], "route_id":route_id}
		assigned_ship["status"] = "LOGISTICS_SERVICE"
	return true


func ship_eligible_for_mode(state: SpaceGameState, ship_id: String, mode_id: String) -> bool:
	var ship: Dictionary = state.ship_by_id(ship_id)
	var mode: Dictionary = content.transport_modes.get(mode_id, {})
	if ship.is_empty() or mode.is_empty() or bool(mode.get("infrastructure_service", false)):
		return false
	var cargo_capacity := _ship_cargo_capacity(state, ship)
	if cargo_capacity < int(mode.get("minimum_ship_cargo_capacity", 0)):
		return false
	var maximum_capacity := int(mode.get("maximum_ship_cargo_capacity", 0))
	if maximum_capacity > 0 and cargo_capacity > maximum_capacity:
		return false
	var capabilities: Dictionary = {}
	for module_id_value in state.ship_module_definition_ids(ship):
		var module: Dictionary = content.modules.get(str(module_id_value), {})
		for capability_id_value in module.get("capabilities", {}).keys():
			var capability_id := str(capability_id_value)
			capabilities[capability_id] = float(capabilities.get(capability_id, 0.0)) + float(module.get("capabilities", {}).get(capability_id, 0.0))
	for capability_id_value in mode.get("required_ship_capabilities", []):
		if float(capabilities.get(str(capability_id_value), 0.0)) <= 0.0:
			return false
	return true


func service_for_route(state: SpaceGameState, route_id: String) -> Dictionary:
	if state.logistics_network is not Dictionary or state.logistics_network.get("services", null) is not Dictionary or state.logistics_network.get("services", {}).get(route_id, null) is not Dictionary:
		ensure_state(state)
	return state.logistics_network.get("services", {}).get(route_id, _default_service(route_id))


func service_capacity(state: SpaceGameState, route_id: String) -> float:
	var service := service_for_route(state, route_id)
	var mode: Dictionary = content.transport_modes.get(str(service.get("transport_mode_id", "")), {})
	if str(service.get("status", "ACTIVE")) != "ACTIVE" or mode.is_empty() or not _mode_available(state, mode) or not _mode_available_for_route(state, mode, route_id):
		return 0.0
	var corridor_capacity := float(effective_route_capacity(state, route_id))
	var result := corridor_capacity * float(mode.get("capacity_multiplier", 1.0)) if bool(mode.get("public_base_capacity", false)) or bool(mode.get("infrastructure_service", false)) else 0.0
	for ship_id_value in service.get("assigned_ship_ids", []):
		var ship: Dictionary = state.ship_by_id(str(ship_id_value))
		if ship.is_empty() or str(ship.get("assignment", {}).get("service_id", "")) != str(service.get("id", "")):
			continue
		result += float(_ship_cargo_capacity(state, ship)) * float(mode.get("ship_capacity_multiplier", 0.0)) * float(technology_profile(state).get("freight_capacity_multiplier", 1.0))
	return maxf(0.0, result)


func _ship_cargo_capacity(state: SpaceGameState, ship: Dictionary) -> int:
	var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
	var result := maxi(0, int(blueprint.get("cargo_capacity", 0)))
	for module_id_value in state.ship_module_definition_ids(ship):
		result += maxi(0, int(content.modules.get(str(module_id_value), {}).get("cargo_capacity", 0)))
	return result


func service_snapshot(state: SpaceGameState, route_id: String) -> Dictionary:
	var service := service_for_route(state, route_id)
	var mode: Dictionary = content.transport_modes.get(str(service.get("transport_mode_id", "")), {})
	var per_dispatch := service_capacity(state, route_id)
	return {
		"id":service.get("id", ""),
		"route_id":route_id,
		"transport_mode_id":service.get("transport_mode_id", ""),
		"assigned_ship_ids":service.get("assigned_ship_ids", []).duplicate(),
		"allocated_ships":service.get("assigned_ship_ids", []).size(),
		"capacity_per_dispatch":per_dispatch,
		"capacity_per_minute":per_dispatch * 60000.0 / maxf(100.0, float(state.logistics_network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS))),
		"supported_freight_classes":mode.get("supported_freight_classes", []).duplicate(),
		"utilization":float(service.get("last_utilization", 0.0)),
		"priority_strategy":service.get("priority_strategy", "DEMAND_PRIORITY"),
		"status":service.get("status", "ACTIVE")
	}


func _mode_available(state: SpaceGameState, mode: Dictionary) -> bool:
	var technology_id := str(mode.get("required_technology", ""))
	if not technology_id.is_empty() and not bool(state.technologies.get(technology_id, false)):
		return false
	var facility_id := str(mode.get("required_facility", ""))
	return facility_id.is_empty() or str(state.facilities.get(facility_id, {}).get("status", "INACTIVE")) == "ACTIVE"


func _mode_available_for_route(state: SpaceGameState, mode: Dictionary, route_id: String) -> bool:
	var route_ids: Array = mode.get("route_ids", ["*"])
	if not route_ids.has("*") and not route_ids.has(route_id):
		return false
	var requirements: Array = mode.get("environment_requirements", [])
	if requirements.is_empty():
		return true
	var route: Dictionary = content.logistics_routes.get(route_id, {})
	for endpoint_id in [str(route.get("from", "")), str(route.get("to", ""))]:
		var environment: Dictionary = content.regions.get(endpoint_id, {}).get("environment", {})
		if not requirements.all(func(condition): return LocationState.environment_condition_met(environment, condition as Dictionary)):
			return false
	return true


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
		"source_lock":str(policy.get("source_lock", "")),
		"route_lock":str(policy.get("route_lock", "")),
		"blocker":{}
	}
	if not normalized.source_lock.is_empty() and not state.has_location(normalized.source_lock):
		return false
	if not normalized.route_lock.is_empty() and not content.logistics_routes.has(normalized.route_lock):
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
		if not _deliver_shipment(state, shipment):
			shipment["remaining_ms"] = float(state.logistics_network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS))
			shipment["status"] = "BLOCKED_OUTPUT"
			shipment["blocker"] = {"primary_reason":"STORAGE_FULL", "location_id":shipment.get("destination", "")}
			remaining_shipments.append(shipment)
			continue
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
	var active_service_count := 0
	var utilization_total := 0.0
	for route_value in content.logistics_routes.values():
		var route := route_value as Dictionary
		var from_id := str(route.get("from", ""))
		var to_id := str(route.get("to", ""))
		var peer_id := to_id if from_id == location_id else (from_id if to_id == location_id else "")
		if peer_id.is_empty() or not state.has_location(peer_id):
			continue
		if str(state.location_state(peer_id).get("discovery_state", "UNDISCOVERED")) == LocationState.DISCOVERED:
			route_count += 1
			var service := service_for_route(state, str(route.get("id", "")))
			if str(service.get("status", "ACTIVE")) == "ACTIVE" and service_capacity(state, str(route.get("id", ""))) > 0.0:
				active_service_count += 1
				utilization_total += float(service.get("last_utilization", 0.0))
	return {
		"status":"CONNECTED" if route_count > 0 else "NOT_CONNECTED",
		"policy_count":policies.size(),
		"inbound_shipments":inbound,
		"outbound_shipments":outbound,
		"route_count":route_count,
		"active_service_count":active_service_count,
		"average_service_utilization":utilization_total / maxf(1.0, float(active_service_count)),
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
	var route_budget := {}
	for route_id in content.logistics_routes:
		route_budget[route_id] = service_capacity(state, str(route_id))
		var route_service := service_for_route(state, str(route_id))
		route_service["last_utilization"] = 0.0
		route_service["last_blocker"] = {}
	var hub_budget := {}
	var energy_budget := {}
	for location_id in state.locations:
		hub_budget[location_id] = maxf(0.0, float(state.locations[location_id].get("logistics", {}).get("hub_throughput", DEFAULT_HUB_THROUGHPUT)))
		var location: Dictionary = state.locations[location_id]
		var fallback_power := float(location.get("industry", {}).get("power_capacity", 0.0))
		var available_power := maxf(0.0, float(location.get("power", {}).get("available_capacity", fallback_power)))
		energy_budget[location_id] = available_power * float(state.logistics_network.get("dispatch_interval_ms", DISPATCH_INTERVAL_MS)) / 1000.0
	var demands := _demand_rows(state)
	demands.sort_custom(func(a, b):
		var a_score := _demand_priority_score(state, a)
		var b_score := _demand_priority_score(state, b)
		return a_score > b_score if a_score != b_score else (str(a.get("location_id", "")) + ":" + str(a.get("item_id", ""))) < (str(b.get("location_id", "")) + ":" + str(b.get("item_id", "")))
	)
	for demand_value in demands:
		var demand := demand_value as Dictionary
		var destination := str(demand.get("location_id", ""))
		var item_id := str(demand.get("item_id", ""))
		var deficit := maxi(0, int(demand.get("target", 0)) - state.item_quantity(item_id, destination) - incoming_quantity(state, destination, item_id))
		var destination_free := _destination_free_capacity(state, destination, item_id)
		deficit = mini(deficit, destination_free)
		if deficit <= 0:
			_set_demand_blocker(state, demand, {})
			continue
		var any_path := false
		var any_capacity := false
		var any_affordable := false
		var dispatched := false
		var suppliers := _supplier_rows(state, item_id, str(demand.get("source_lock", "")))
		for supplier_value in suppliers:
			if deficit <= 0:
				break
			var supplier := supplier_value as Dictionary
			var origin := str(supplier.get("location_id", ""))
			var path := _shortest_path(state, origin, destination, item_id, str(demand.get("route_lock", "")), route_budget)
			if path.is_empty():
				continue
			any_path = true
			var available := _supply_available(state, origin, item_id, int(supplier.get("reserve", 0)))
			var capacity := _path_dispatch_capacity(path, route_budget, hub_budget, energy_budget)
			any_capacity = any_capacity or capacity > 0
			var costs := _path_costs(state, path)
			if costs.has(item_id):
				available = maxi(0, available - int(costs[item_id]))
			if available <= 0 or capacity <= 0 or not _costs_available(state, origin, costs):
				continue
			any_affordable = true
			var quantity := mini(deficit, mini(available, capacity))
			var threshold := maxi(1, int(supplier.get("dispatch_threshold", 1)))
			if quantity < threshold and quantity < deficit:
				continue
			var shipment := _create_shipment(state, origin, destination, item_id, quantity, path, costs)
			if shipment.is_empty():
				continue
			_consume_path_capacity(state, path, quantity, route_budget, hub_budget, energy_budget)
			deficit -= quantity
			dispatched = true
			events.append({
				"type":"ShipmentDispatched",
				"shipment_id":shipment.get("id", ""),
				"origin":origin,
				"destination":destination,
				"cargo":shipment.get("cargo", {}).duplicate(true),
				"eta_ms":shipment.get("total_ms", 0.0)
			})
		if dispatched or deficit <= 0:
			_set_demand_blocker(state, demand, {})
		elif suppliers.is_empty():
			_set_demand_blocker(state, demand, _logistics_blocker("NO_SUPPLY_SOURCE", "没有地点发布可用供给", item_id, destination))
		elif not any_path:
			var code := "ROUTE_LOCK_UNAVAILABLE" if not str(demand.get("route_lock", "")).is_empty() else "TRANSPORT_MODE_UNAVAILABLE"
			_set_demand_blocker(state, demand, _logistics_blocker(code, "货运类型与当前航线服务不兼容", item_id, destination))
		elif not any_capacity:
			_set_demand_blocker(state, demand, _logistics_blocker("ROUTE_CONGESTION", "航线或枢纽本批次运力已用尽", item_id, destination))
		elif not any_affordable:
			_set_demand_blocker(state, demand, _logistics_blocker("LOGISTICS_OPERATING_COST", "来源地缺少推进剂、维护材料或能源", item_id, destination))
	return events


func _demand_priority_score(state: SpaceGameState, demand: Dictionary) -> int:
	var score := clampi(int(demand.get("priority", 50)), 0, 100) * 100
	var item_id := str(demand.get("item_id", ""))
	var freight_class := str(content.item_freight_profile(item_id).get("freight_class", "STANDARD"))
	for service_value in state.logistics_network.get("services", {}).values():
		var strategy := str((service_value as Dictionary).get("priority_strategy", "DEMAND_PRIORITY"))
		if strategy == "PRECISION_FIRST" and freight_class == "PRECISION":
			score += 2000
		elif strategy == "BULK_FIRST" and freight_class == "BULK":
			score += 2000
		elif strategy == "MAINTENANCE_FIRST" and item_id in ["repair_material", "repair_supplies", "chemical_propellant"]:
			score += 3000
	return score


func _logistics_blocker(code: String, message: String, item_id: String, location_id: String) -> Dictionary:
	return {"code":code, "message":message, "owner_type":"LOGISTICS_POLICY", "owner_id":"%s:%s" % [location_id, item_id], "item_id":item_id, "location_id":location_id}


func _set_demand_blocker(state: SpaceGameState, demand: Dictionary, blocker: Dictionary) -> void:
	if not str(demand.get("demand_kind", "")).is_empty():
		return
	var location_id := str(demand.get("location_id", ""))
	var item_id := str(demand.get("item_id", ""))
	var policy: Dictionary = state.location_state(location_id).get("logistics", {}).get("policies", {}).get(item_id, {})
	if not policy.is_empty():
		policy["blocker"] = blocker.duplicate(true)


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
	# Every live ConstructionProject is a real material sink at its owning
	# Location. Targets are cumulative in priority order, so two projects cannot
	# both claim the same local or in-transit units while dispatching freight.
	var construction_projects: Array = state.construction_operations.filter(func(project): return str(project.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED"] and not str(project.get("project_id", "")).is_empty())
	construction_projects.sort_custom(func(a, b):
		if int(a.get("priority", 50)) != int(b.get("priority", 50)):
			return int(a.get("priority", 50)) > int(b.get("priority", 50))
		if int(a.get("enqueued_at_ms", 0)) != int(b.get("enqueued_at_ms", 0)):
			return int(a.get("enqueued_at_ms", 0)) < int(b.get("enqueued_at_ms", 0))
		return str(a.get("project_id", "")) < str(b.get("project_id", ""))
	)
	var cumulative_targets := {}
	for project_value in construction_projects:
		var project := project_value as Dictionary
		var location_id := str(project.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		var material_plan: Dictionary = project.get("material_plan", {})
		if not state.has_location(location_id) or material_plan.is_empty():
			continue
		var consumed: Dictionary = project.get("consumed", {})
		for item_id_value in material_plan.keys():
			var item_id := str(item_id_value)
			var remaining := maxi(0, int(material_plan.get(item_id, 0)) - int(consumed.get(item_id, 0)))
			if remaining <= 0:
				continue
			# Freight only the next balanced construction tranche. Asking for every
			# remaining unit lets the alphabetically first Component fill a finite
			# staging depot and prevent the complementary BOM from ever arriving.
			var staged_quantity := mini(remaining, maxi(1, ceili(float(material_plan.get(item_id, 0)) * 0.05)))
			var target_key := "%s:%s" % [location_id, item_id]
			cumulative_targets[target_key] = int(cumulative_targets.get(target_key, 0)) + staged_quantity
			result.append({
				"mode":MODE_DEMAND,
				"reserve":0,
				"target":int(cumulative_targets[target_key]),
				"priority":clampi(int(project.get("priority", 50)), 0, 100),
				"dispatch_threshold":1,
				"source_lock":"",
				"route_lock":"",
				"location_id":location_id,
				"item_id":item_id,
				"demand_kind":"CONSTRUCTION_PROJECT",
				"project_id":project.get("project_id", ""),
				"project_type":project.get("project_type", "")
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


func _destination_free_capacity(state: SpaceGameState, location_id: String, item_id: String) -> int:
	var profile := content.item_storage_profile(item_id)
	var storage_class := str(profile.get("storage_class", "SPECIAL"))
	var units_per_item := maxf(0.001, float(profile.get("storage_units", 1.0)))
	var capacities: Dictionary = state.locations[location_id].get("logistics", {}).get("storage_capacities", {})
	var used := 0.0
	for stored_item_value in state.location_inventory(location_id).keys():
		var stored_item := str(stored_item_value)
		var stored_profile := content.item_storage_profile(stored_item)
		if str(stored_profile.get("storage_class", "SPECIAL")) == storage_class:
			used += float(state.item_quantity(stored_item, location_id)) * float(stored_profile.get("storage_units", 1.0))
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if str(shipment.get("destination", "")) != location_id:
			continue
		for cargo_item_value in shipment.get("cargo", {}).keys():
			var cargo_item := str(cargo_item_value)
			var cargo_profile := content.item_storage_profile(cargo_item)
			if str(cargo_profile.get("storage_class", "SPECIAL")) == storage_class:
				used += float(shipment.get("cargo", {}).get(cargo_item, 0)) * float(cargo_profile.get("storage_units", 1.0))
	return maxi(0, int(floor((float(capacities.get(storage_class, 0)) - used) / units_per_item)))


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
	var freight := content.item_freight_profile(item_id)
	var handling_time_ms := float(quantity) * float(path.get("handling_freight_units_per_item", freight.get("freight_units", 1.0))) * float(profile.get("loading_time_ms_per_unit", 40.0)) * 2.0
	var total_time_ms := float(path.get("transit_time_ms", 0.0)) + handling_time_ms
	var shipment := {
		"id":"SHIPMENT-%06d" % serial,
		"origin":origin,
		"destination":destination,
		"cargo":{item_id:quantity},
		"route_path":path.get("route_ids", []).duplicate(),
		"node_path":path.get("nodes", []).duplicate(),
		"service_path":path.get("service_ids", []).duplicate(),
		"transport_modes":path.get("transport_mode_ids", []).duplicate(),
		"freight_class":freight.get("freight_class", "STANDARD"),
		"freight_units":float(quantity) * float(freight.get("freight_units", 1.0)),
		"cargo_mass":float(quantity) * float(freight.get("cargo_mass", freight.get("freight_units", 1.0))),
		"cargo_volume":float(quantity) * float(freight.get("cargo_volume", freight.get("freight_units", 1.0))),
		"route_freight_units":path.get("route_freight_units_per_item", {}).duplicate(true),
		"path_score":float(path.get("score", 0.0)),
		"remaining_ms":total_time_ms,
		"total_ms":total_time_ms,
		"transit_time_ms":float(path.get("transit_time_ms", 0.0)),
		"handling_time_ms":handling_time_ms,
		"costs":costs.duplicate(true),
		"logistics_technology_id":profile.get("id", "chemical_cargo"),
		"energy_units":float(path.get("energy_per_item", 0.0)) * float(quantity),
		"dispatched_at_ms":int(state.total_elapsed_ms)
	}
	state.logistics_network["shipments"].append(shipment)
	for route_id in shipment.route_path:
		var route_stats: Dictionary = state.logistics_network["route_statistics"].get(str(route_id), {"shipments":0, "units":0, "freight_units":0.0, "cargo_mass":0.0, "cargo_volume":0.0, "energy_units":0.0})
		route_stats["shipments"] = int(route_stats.get("shipments", 0)) + 1
		route_stats["units"] = int(route_stats.get("units", 0)) + quantity
		route_stats["freight_units"] = float(route_stats.get("freight_units", 0.0)) + float(quantity) * float(path.get("route_freight_units_per_item", {}).get(str(route_id), freight.get("freight_units", 1.0)))
		route_stats["cargo_mass"] = float(route_stats.get("cargo_mass", 0.0)) + float(quantity) * float(freight.get("cargo_mass", freight.get("freight_units", 1.0)))
		route_stats["cargo_volume"] = float(route_stats.get("cargo_volume", 0.0)) + float(quantity) * float(freight.get("cargo_volume", freight.get("freight_units", 1.0)))
		route_stats["energy_units"] = float(route_stats.get("energy_units", 0.0)) + float(path.get("energy_per_item", 0.0)) * float(quantity)
		state.logistics_network["route_statistics"][str(route_id)] = route_stats
	return shipment


func _deliver_shipment(state: SpaceGameState, shipment: Dictionary) -> bool:
	var destination := str(shipment.get("destination", SpaceGameState.MAIN_BASE_LOCATION_ID))
	for item_id_value in shipment.get("cargo", {}).keys():
		if _destination_free_capacity_excluding_shipment(state, destination, str(item_id_value), str(shipment.get("id", ""))) < int(shipment.get("cargo", {}).get(item_id_value, 0)):
			return false
	for item_id in shipment.get("cargo", {}):
		# Arrival changes location ownership without counting as production.
		state.ensure_location(destination, LocationState.ARTIFICIAL if destination == SpaceGameState.MAIN_BASE_LOCATION_ID else LocationState.NATURAL, true)
		state.location_inventory(destination)[str(item_id)] = state.item_quantity(str(item_id), destination) + int(shipment["cargo"][item_id])
		var item_stats: Dictionary = state.logistics_network["item_statistics"].get(str(item_id), {"delivered":0})
		item_stats["delivered"] = int(item_stats.get("delivered", 0)) + int(shipment["cargo"][item_id])
		state.logistics_network["item_statistics"][str(item_id)] = item_stats
	for project_id_value in state.megastructure_projects.keys():
		var project: Dictionary = state.megastructure_projects[project_id_value]
		if str(project.get("site_location_id", "")) != destination or str(project.get("status", "")) == "COMPLETE":
			continue
		var freight_units := maxf(0.0, float(shipment.get("freight_units", 0.0)))
		project["total_cargo_transported"] = float(project.get("total_cargo_transported", 0.0)) + freight_units
		var suppliers: Dictionary = project.get("supplier_locations", {})
		var origin := str(shipment.get("origin", ""))
		suppliers[origin] = float(suppliers.get(origin, 0.0)) + freight_units
		project["supplier_locations"] = suppliers
	return true


func _destination_free_capacity_excluding_shipment(state: SpaceGameState, location_id: String, item_id: String, excluded_shipment_id: String) -> int:
	var profile := content.item_storage_profile(item_id)
	var storage_class := str(profile.get("storage_class", "SPECIAL"))
	var units_per_item := maxf(0.001, float(profile.get("storage_units", 1.0)))
	var capacity := float(state.locations[location_id].get("logistics", {}).get("storage_capacities", {}).get(storage_class, 0))
	var used := 0.0
	for stored_item_value in state.location_inventory(location_id).keys():
		var stored_item := str(stored_item_value)
		var stored_profile := content.item_storage_profile(stored_item)
		if str(stored_profile.get("storage_class", "SPECIAL")) == storage_class:
			used += float(state.item_quantity(stored_item, location_id)) * float(stored_profile.get("storage_units", 1.0))
	for shipment_value in state.logistics_network.get("shipments", []):
		var other := shipment_value as Dictionary
		if str(other.get("id", "")) == excluded_shipment_id or str(other.get("destination", "")) != location_id:
			continue
		for cargo_item_value in other.get("cargo", {}).keys():
			var cargo_item := str(cargo_item_value)
			var cargo_profile := content.item_storage_profile(cargo_item)
			if str(cargo_profile.get("storage_class", "SPECIAL")) == storage_class:
				used += float(other.get("cargo", {}).get(cargo_item, 0)) * float(cargo_profile.get("storage_units", 1.0))
	return maxi(0, int(floor((capacity - used) / units_per_item)))


func _path_dispatch_capacity(path: Dictionary, route_budget: Dictionary, hub_budget: Dictionary, energy_budget: Dictionary = {}) -> int:
	var result := 2147483647
	for route_id in path.get("route_ids", []):
		var route_units := maxf(0.001, float(path.get("route_freight_units_per_item", {}).get(str(route_id), 1.0)))
		result = mini(result, int(floor(float(route_budget.get(str(route_id), 0.0)) / route_units)))
	var hub_units := maxf(0.001, float(path.get("hub_freight_units_per_item", 1.0)))
	var energy_per_item := maxf(0.0, float(path.get("energy_per_item", 0.0)))
	for node_id in path.get("nodes", []):
		result = mini(result, int(floor(float(hub_budget.get(str(node_id), 0.0)) / hub_units)))
		if energy_per_item > 0.0:
			result = mini(result, int(floor(float(energy_budget.get(str(node_id), 0.0)) / energy_per_item)))
	return maxi(0, result if result != 2147483647 else 0)


func _consume_path_capacity(state: SpaceGameState, path: Dictionary, quantity: int, route_budget: Dictionary, hub_budget: Dictionary, energy_budget: Dictionary = {}) -> void:
	for route_id in path.get("route_ids", []):
		var route_key := str(route_id)
		var consumed := float(quantity) * float(path.get("route_freight_units_per_item", {}).get(route_key, 1.0))
		var before := float(route_budget.get(route_key, 0.0))
		route_budget[route_key] = maxf(0.0, before - consumed)
		var service := service_for_route(state, route_key)
		var total := service_capacity(state, route_key)
		service["last_utilization"] = clampf(1.0 - float(route_budget[route_key]) / maxf(0.001, total), 0.0, 1.0)
	var hub_consumed := float(quantity) * float(path.get("hub_freight_units_per_item", 1.0))
	var energy_consumed := float(quantity) * float(path.get("energy_per_item", 0.0))
	for node_id in path.get("nodes", []):
		hub_budget[str(node_id)] = maxf(0.0, float(hub_budget.get(str(node_id), 0.0)) - hub_consumed)
		if energy_consumed > 0.0:
			energy_budget[str(node_id)] = maxf(0.0, float(energy_budget.get(str(node_id), 0.0)) - energy_consumed)


func _path_costs(state: SpaceGameState, path: Dictionary) -> Dictionary:
	var result := {}
	var profile := technology_profile(state)
	var fuel_multiplier := float(profile.get("fuel_cost_multiplier", 1.0))
	var mode_ids: Array = path.get("transport_mode_ids", [])
	var route_ids: Array = path.get("route_ids", [])
	var maintenance_weight := 0.0
	for index in route_ids.size():
		var route_id := str(route_ids[index])
		var mode: Dictionary = content.transport_modes.get(str(mode_ids[index]) if index < mode_ids.size() else "general_cargo", {})
		for cost_value in content.logistics_routes.get(str(route_id), {}).get("dispatch_costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			var adjusted := maxi(0, int(ceil(float(cost.get("quantity", 0)) * fuel_multiplier * float(mode.get("propellant_multiplier", 1.0)))))
			if adjusted > 0:
				result[item_id] = int(result.get(item_id, 0)) + adjusted
		maintenance_weight += float(mode.get("maintenance_multiplier", 1.0))
	var maintenance_item := str(content.fleet_rules.get("maintenance_item", "repair_material"))
	var maintenance_cost := maxi(0, int(ceil(maintenance_weight * float(profile.get("maintenance_cost_per_route", 1.0)))))
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


func _shortest_path(state: SpaceGameState, origin: String, destination: String, item_id: String = "", route_lock: String = "", route_budget: Dictionary = {}) -> Dictionary:
	if origin == destination:
		return {}
	return _find_path(state, origin, destination, [], [origin], item_id, route_lock, route_budget)


func _find_path(state: SpaceGameState, current: String, destination: String, used_routes: Array, nodes: Array, item_id: String, route_lock: String, route_budget: Dictionary) -> Dictionary:
	var best := {}
	for edge in _edges_from(state, current, item_id):
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
			if not route_lock.is_empty() and not candidate_routes.has(route_lock):
				continue
			candidate = _path_profile(state, candidate_routes, candidate_nodes, item_id, route_budget)
		else:
			candidate = _find_path(state, next_node, destination, candidate_routes, candidate_nodes, item_id, route_lock, route_budget)
		if candidate.is_empty():
			continue
		if best.is_empty() or float(candidate.get("score", INF)) < float(best.get("score", INF)):
			best = candidate
	return best


func _edges_from(state: SpaceGameState, location_id: String, item_id: String = "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for route_id in content.logistics_routes:
		var route: Dictionary = content.logistics_routes[route_id]
		var from_id := str(route.get("from", ""))
		var to_id := str(route.get("to", ""))
		if not state.has_location(from_id) or not state.has_location(to_id):
			continue
		if str(state.location_state(from_id).get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED or str(state.location_state(to_id).get("discovery_state", "UNDISCOVERED")) != LocationState.DISCOVERED:
			continue
		if not item_id.is_empty() and not _service_supports_item(state, str(route_id), item_id):
			continue
		if from_id == location_id and _service_supports_direction(state, str(route_id), true):
			result.append({"route_id":str(route_id), "to":to_id})
		if bool(route.get("bidirectional", true)) and to_id == location_id and _service_supports_direction(state, str(route_id), false):
			result.append({"route_id":str(route_id), "to":from_id})
	return result


func _service_supports_item(state: SpaceGameState, route_id: String, item_id: String) -> bool:
	var service := service_for_route(state, route_id)
	var mode: Dictionary = content.transport_modes.get(str(service.get("transport_mode_id", "")), {})
	if mode.is_empty() or not _mode_available(state, mode) or not _mode_available_for_route(state, mode, route_id) or service_capacity(state, route_id) <= 0.0:
		return false
	var freight_class := str(content.item_freight_profile(item_id).get("freight_class", "STANDARD"))
	return mode.get("supported_freight_classes", []).has(freight_class)


func _service_supports_direction(state: SpaceGameState, route_id: String, forward: bool) -> bool:
	var service := service_for_route(state, route_id)
	var mode: Dictionary = content.transport_modes.get(str(service.get("transport_mode_id", "")), {})
	var direction := str(mode.get("directions", "BOTH"))
	return direction == "BOTH" or (forward and direction == "FORWARD") or (not forward and direction == "REVERSE")


func _path_profile(state: SpaceGameState, route_ids: Array, nodes: Array, item_id: String, route_budget: Dictionary) -> Dictionary:
	var freight := content.item_freight_profile(item_id) if not item_id.is_empty() else {"freight_class":"STANDARD", "freight_units":1.0, "cargo_mass":1.0, "cargo_volume":1.0}
	var freight_class := str(freight.get("freight_class", "STANDARD"))
	var base_units := maxf(0.001, float(freight.get("freight_units", 1.0)))
	var profile := technology_profile(state)
	var service_ids: Array = []
	var mode_ids: Array = []
	var route_units := {}
	var transit_time := 0.0
	var handling_multiplier_total := 0.0
	var energy_per_item := 0.0
	var congestion_score := 0.0
	var operating_score := 0.0
	var risk_score := 0.0
	for route_id_value in route_ids:
		var route_id := str(route_id_value)
		var service := service_for_route(state, route_id)
		var mode: Dictionary = content.transport_modes.get(str(service.get("transport_mode_id", "general_cargo")), {})
		if mode.is_empty():
			return {}
		var adaptation := maxf(0.01, float(mode.get("adaptation_modifiers", {}).get(freight_class, 1.0)))
		var occupied_units := base_units * adaptation
		route_units[route_id] = occupied_units
		service_ids.append(str(service.get("id", "")))
		mode_ids.append(str(mode.get("id", "")))
		transit_time += effective_route_transit_time_ms(state, route_id) * float(mode.get("transit_time_multiplier", 1.0))
		handling_multiplier_total += float(mode.get("handling_time_multiplier", 1.0))
		energy_per_item += occupied_units * (float(profile.get("energy_per_route_unit", 0.0)) + float(mode.get("energy_per_freight_unit", 0.0)))
		var total_capacity := service_capacity(state, route_id)
		var remaining_capacity := float(route_budget.get(route_id, total_capacity))
		congestion_score += 10000.0 * clampf(1.0 - remaining_capacity / maxf(0.001, total_capacity), 0.0, 1.0)
		for cost_value in content.logistics_routes.get(route_id, {}).get("dispatch_costs", []):
			operating_score += float((cost_value as Dictionary).get("quantity", 0)) * float(mode.get("propellant_multiplier", 1.0)) * 1000.0
		operating_score += float(mode.get("maintenance_multiplier", 1.0)) * 500.0 + occupied_units * float(mode.get("energy_per_freight_unit", 0.0)) * 100.0
		if freight_class in ["CRYOGENIC", "HAZARDOUS", "PRECISION"]:
			risk_score += maxf(0.0, adaptation - 1.0) * 2000.0
	var average_handling := handling_multiplier_total / maxf(1.0, float(route_ids.size()))
	var handling_units := base_units * average_handling
	var handling_time := handling_units * float(profile.get("loading_time_ms_per_unit", 40.0)) * 2.0
	var transfer_score := maxf(0.0, float(route_ids.size() - 1)) * 5000.0
	return {
		"route_ids":route_ids.duplicate(),
		"nodes":nodes.duplicate(),
		"service_ids":service_ids,
		"transport_mode_ids":mode_ids,
		"transit_time_ms":transit_time,
		"route_freight_units_per_item":route_units,
		"hub_freight_units_per_item":base_units,
		"handling_freight_units_per_item":handling_units,
		"cargo_mass_per_item":float(freight.get("cargo_mass", base_units)),
		"cargo_volume_per_item":float(freight.get("cargo_volume", base_units)),
		"energy_per_item":energy_per_item,
		"special_cargo_risk":risk_score,
		"score":transit_time + handling_time + congestion_score + operating_score + transfer_score + risk_score
	}


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
		var first_item := str(shipment["cargo"].keys()[0]) if not shipment["cargo"].is_empty() else ""
		var freight := content.item_freight_profile(first_item) if not first_item.is_empty() else {"freight_class":"STANDARD", "freight_units":1.0}
		var cargo_quantity := int(shipment["cargo"].get(first_item, 0)) if not first_item.is_empty() else 0
		shipment["freight_class"] = str(shipment.get("freight_class", freight.get("freight_class", "STANDARD")))
		shipment["freight_units"] = maxf(0.0, float(shipment.get("freight_units", float(cargo_quantity) * float(freight.get("freight_units", 1.0)))))
		shipment["cargo_mass"] = maxf(0.0, float(shipment.get("cargo_mass", float(cargo_quantity) * float(freight.get("cargo_mass", freight.get("freight_units", 1.0))))))
		shipment["cargo_volume"] = maxf(0.0, float(shipment.get("cargo_volume", float(cargo_quantity) * float(freight.get("cargo_volume", freight.get("freight_units", 1.0))))))
		shipment["service_path"] = shipment.get("service_path", []).duplicate() if shipment.get("service_path", null) is Array else []
		shipment["transport_modes"] = shipment.get("transport_modes", []).duplicate() if shipment.get("transport_modes", null) is Array else []
		shipment["route_freight_units"] = shipment.get("route_freight_units", {}).duplicate(true) if shipment.get("route_freight_units", null) is Dictionary else {}
		shipment["path_score"] = maxf(0.0, float(shipment.get("path_score", 0.0)))
		normalized.append(shipment)
	state.logistics_network["shipments"] = normalized
