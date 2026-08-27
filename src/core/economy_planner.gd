class_name EconomyPlanner
extends RefCounted

## Read-only industrial calculator. It never mutates SpaceGameState and every
## rate comes from SimulationEngine's runtime formula entry points.

var content: ContentDatabase
var simulation: RefCounted
var _dependency_graph_cache := {}


func _init(database: ContentDatabase, simulation_engine: RefCounted) -> void:
	content = database
	simulation = simulation_engine


func production_dependency_graph() -> Dictionary:
	if not _dependency_graph_cache.is_empty():
		return _dependency_graph_cache
	var nodes := {}
	var edges: Array = []
	var producers := {}
	for item_id_value in content.items.keys():
		var item_id := str(item_id_value)
		nodes["product:%s" % item_id] = {"id":"product:%s" % item_id, "kind":"PRODUCT", "definition_id":item_id}
	for activity_value in content.activities.values():
		var method := activity_value as Dictionary
		if str(method.get("domain", "")) != "industry" or not bool(method.get("repeat", true)):
			continue
		var method_id := str(method.get("id", ""))
		var method_node := "method:%s" % method_id
		nodes[method_node] = {"id":method_node, "kind":"PRODUCTION_METHOD", "definition_id":method_id}
		var facility_id := str(method.get("facility", ""))
		var facility_node := "factory:%s" % facility_id
		nodes[facility_node] = {"id":facility_node, "kind":"FACTORY", "definition_id":facility_id}
		edges.append({"from":method_node, "to":facility_node, "type":"REQUIRES"})
		for capability_value in method.get("required_facility_capabilities", []):
			var capability_id := str(capability_value)
			var device_node := "device:%s:%s" % [facility_id, capability_id]
			nodes[device_node] = {"id":device_node, "kind":"PRODUCTION_DEVICE", "definition_id":capability_id, "facility_id":facility_id}
			edges.append({"from":method_node, "to":device_node, "type":"REQUIRES"})
		for cost_value in method.get("costs", []):
			var cost := cost_value as Dictionary
			edges.append({"from":method_node, "to":"product:%s" % cost.get("item", ""), "type":"CONSUMES", "quantity":cost.get("quantity", 0)})
		for reward_value in method.get("rewards", []):
			var reward := reward_value as Dictionary
			var product_id := str(reward.get("item", ""))
			edges.append({"from":"product:%s" % product_id, "to":method_node, "type":"PRODUCED_BY", "quantity":reward.get("quantity", 0)})
			var product_producers: Array = producers.get(product_id, [])
			product_producers.append(method_id)
			producers[product_id] = product_producers
		for support in ["power", "cooling", "storage", "logistics"]:
			var infrastructure_node := "infrastructure:%s" % support
			nodes[infrastructure_node] = {"id":infrastructure_node, "kind":"INFRASTRUCTURE_REQUIREMENT", "definition_id":support}
			edges.append({"from":method_node, "to":infrastructure_node, "type":"REQUIRES"})
	_dependency_graph_cache = {"nodes":nodes, "edges":edges, "producers":producers, "cycle_policy":"EXTERNAL_CREDIT"}
	return _dependency_graph_cache


func upstream_dependencies(product_id: String) -> Dictionary:
	var graph := production_dependency_graph()
	var nodes := {}
	var edges: Array = []
	var credits: Array = []
	_expand_upstream(product_id, graph, nodes, edges, credits, [])
	return {"root":"product:%s" % product_id, "nodes":nodes, "edges":edges, "external_credits":credits}


func _expand_upstream(product_id: String, graph: Dictionary, nodes: Dictionary, edges: Array, credits: Array, stack: Array) -> void:
	var product_node := "product:%s" % product_id
	if stack.has(product_id):
		if not credits.has(product_id):
			credits.append(product_id)
		return
	nodes[product_node] = graph.get("nodes", {}).get(product_node, {"id":product_node, "kind":"PRODUCT", "definition_id":product_id})
	var next_stack := stack.duplicate()
	next_stack.append(product_id)
	for method_id_value in graph.get("producers", {}).get(product_id, []):
		var method_id := str(method_id_value)
		var method_node := "method:%s" % method_id
		nodes[method_node] = graph.get("nodes", {}).get(method_node, {})
		for edge_value in graph.get("edges", []):
			var edge := edge_value as Dictionary
			if str(edge.get("from", "")) not in [product_node, method_node]:
				continue
			edges.append(edge.duplicate(true))
			var target := str(edge.get("to", ""))
			if graph.get("nodes", {}).has(target):
				nodes[target] = graph["nodes"][target]
			if str(edge.get("type", "")) == "CONSUMES" and target.begins_with("product:"):
				_expand_upstream(target.trim_prefix("product:"), graph, nodes, edges, credits, next_stack)


func current_economy_analysis(state: SpaceGameState, location_id: String) -> Dictionary:
	var rows := {}
	var storage_snapshot: Dictionary = simulation.location_storage_snapshot(state, location_id)
	for item_id_value in content.items.keys():
		var item_id := str(item_id_value)
		rows[item_id] = _empty_economy_row(state, location_id, item_id, storage_snapshot)
	for runtime_value in state.mining_operations + state.industrial_operations:
		var runtime := runtime_value as Dictionary
		var domain_id := str(runtime.get("domain", ""))
		if domain_id not in ["mining", "industry"] or str(runtime.get("status", "")) not in ["RUNNING", "BLOCKED"]:
			continue
		var runtime_location: String = str(simulation._runtime_inventory_location_id(state, domain_id, runtime))
		if runtime_location != location_id:
			continue
		var method: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
		if method.is_empty():
			continue
		var cycles_per_hour := 0.0
		if str(runtime.get("status", "")) == "RUNNING":
			var snapshot := runtime.duplicate(true)
			var duration: float = float(simulation.effective_duration_ms(state, domain_id, method, snapshot))
			if duration != INF and duration > 0.0:
				cycles_per_hour = 3600000.0 / duration
		var productivity: float = 1.0 + float(simulation.activity_productivity_bonus(state, domain_id, method, runtime))
		for reward_value in method.get("rewards", []):
			var reward := reward_value as Dictionary
			var product_id := str(reward.get("item", ""))
			rows[product_id]["production_rate"] = float(rows[product_id].get("production_rate", 0.0)) + float(reward.get("quantity", 0)) * cycles_per_hour * productivity
			if str(runtime.get("status", "")) == "BLOCKED":
				rows[product_id]["blocked_sources"].append({"source_id":runtime.get("line_id", runtime.get("site_id", "")), "method_id":method.get("id", ""), "blocker":simulation.blocker_diagnostic(state, domain_id, runtime)})
		for cost_value in method.get("costs", []):
			var cost := cost_value as Dictionary
			var input_id := str(cost.get("item", ""))
			rows[input_id]["production_consumption_rate"] = float(rows[input_id].get("production_consumption_rate", 0.0)) + float(cost.get("quantity", 0)) * cycles_per_hour
	for network_id_value in state.extraction_network_states.keys():
		var network_id := str(network_id_value)
		var runtime: Dictionary = state.extraction_network_states.get(network_id, {})
		var network: Dictionary = content.extraction_networks.get(network_id, {})
		if str(runtime.get("status", "")) not in ["RUNNING", "BLOCKED_OUTPUT"] or network.is_empty():
			continue
		for site_id_value in runtime.get("integrated_site_ids", []):
			var site: Dictionary = content.mining_sites.get(str(site_id_value), {})
			var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
			if str(mining_location.get("region", "")) != location_id:
				continue
			var product_id := str(mining_location.get("raw_material", ""))
			var cycles_per_hour: float = 3600000.0 / float(simulation.extraction_network_cycle_duration_ms(network))
			if str(runtime.get("status", "")) == "RUNNING":
				var nominal_rate := float(network.get("quantity_per_site", 1)) * float(runtime.get("level", 1)) * cycles_per_hour
				var sustainable_rate: float = float(simulation.extraction_site_sustainable_potential(state, str(site_id_value))) * float(simulation.simulation_speed_multiplier("mining"))
				rows[product_id]["production_rate"] = float(rows[product_id].get("production_rate", 0.0)) + minf(nominal_rate, sustainable_rate)
			else:
				rows[product_id]["blocked_sources"].append({"source_id":network_id, "blocker":{"primary_reason":"STORAGE_FULL", "location_id":location_id}})
	for demand_value in state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("location_id", "")) != location_id:
			continue
		var product_id := str(demand.get("product_id", ""))
		if not rows.has(product_id):
			continue
		rows[product_id]["demand_sources"].append(demand.duplicate(true))
		if str(demand.get("demand_kind", "")) == "CONTINUOUS":
			rows[product_id]["continuous_demand_rate"] = float(rows[product_id].get("continuous_demand_rate", 0.0)) + float(demand.get("rate_per_hour", 0.0))
		else:
			rows[product_id]["committed_demand"] = float(rows[product_id].get("committed_demand", 0.0)) + float(demand.get("quantity", 0.0))
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		var duration_hours := maxf(0.001, float(shipment.get("total_ms", 1.0)) / 3600000.0)
		for item_id_value in shipment.get("cargo", {}).keys():
			var item_id := str(item_id_value)
			var rate := float(shipment.get("cargo", {}).get(item_id, 0)) / duration_hours
			if str(shipment.get("destination", "")) == location_id:
				rows[item_id]["import_rate"] = float(rows[item_id].get("import_rate", 0.0)) + rate
			if str(shipment.get("origin", "")) == location_id:
				rows[item_id]["export_rate"] = float(rows[item_id].get("export_rate", 0.0)) + rate
	var result: Array = []
	for item_id_value in rows.keys():
		var row: Dictionary = rows[item_id_value]
		_finalize_economy_row(row)
		if int(row.get("stock", 0)) > 0 or absf(float(row.get("net_rate", 0.0))) > 0.000001 or float(row.get("committed_demand", 0.0)) > 0.0 or not row.get("blocked_sources", []).is_empty():
			result.append(row)
	result.sort_custom(func(a, b): return _status_rank(str(a.get("status", "STABLE"))) > _status_rank(str(b.get("status", "STABLE"))) if _status_rank(str(a.get("status", "STABLE"))) != _status_rank(str(b.get("status", "STABLE"))) else str(a.get("product_id", "")) < str(b.get("product_id", "")))
	return {"location_id":location_id, "products":result, "storage":storage_snapshot, "generated_at_ms":int(state.total_elapsed_ms)}


func _empty_economy_row(state: SpaceGameState, location_id: String, item_id: String, storage: Dictionary) -> Dictionary:
	var storage_class: String = str(simulation.storage_class_for_item(item_id))
	var class_row: Dictionary = storage.get("classes", {}).get(storage_class, {})
	var on_hand := state.item_quantity(item_id, location_id)
	var available := state.available_item_quantity(item_id, location_id)
	return {"product_id":item_id, "stock":on_hand, "on_hand":on_hand, "reserved":maxi(0, on_hand - available), "available":available, "storage_class":storage_class, "storage_capacity":class_row.get("capacity", 0.0), "free_storage":class_row.get("free", 0.0), "storage_utilization":class_row.get("utilization", 0.0), "production_rate":0.0, "production_consumption_rate":0.0, "continuous_demand_rate":0.0, "committed_demand":0.0, "import_rate":0.0, "export_rate":0.0, "net_rate":0.0, "stock_coverage_hours":INF, "demand_sources":[], "blocked_sources":[], "status":"STABLE"}


func _finalize_economy_row(row: Dictionary) -> void:
	var gross_consumption := float(row.get("production_consumption_rate", 0.0)) + float(row.get("continuous_demand_rate", 0.0)) + float(row.get("export_rate", 0.0))
	var gross_supply := float(row.get("production_rate", 0.0)) + float(row.get("import_rate", 0.0))
	row["consumption_rate"] = gross_consumption
	row["net_rate"] = gross_supply - gross_consumption
	var net_consumption := maxf(0.0, gross_consumption - gross_supply)
	row["stock_coverage_hours"] = float(row.get("stock", 0)) / net_consumption if net_consumption > 0.000001 else INF
	if float(row.get("storage_utilization", 0.0)) >= 0.999999:
		row["status"] = "STORAGE_FULL"
	elif not row.get("blocked_sources", []).is_empty():
		row["status"] = "CRITICAL"
	elif float(row.get("net_rate", 0.0)) < -0.000001 and float(row.get("stock_coverage_hours", INF)) < 6.0:
		row["status"] = "CRITICAL"
	elif float(row.get("net_rate", 0.0)) < -0.000001 or float(row.get("stock_coverage_hours", INF)) < 24.0:
		row["status"] = "TIGHT"
	elif float(row.get("net_rate", 0.0)) > 0.000001:
		row["status"] = "SURPLUS"
	else:
		row["status"] = "STABLE"


func plan_targets(state: SpaceGameState, targets: Dictionary, location_id: String) -> Dictionary:
	var required := {}
	var method_cycles := {}
	var selections := {}
	var external_credits: Array = []
	for item_id_value in targets.keys():
		_expand_requirement(state, str(item_id_value), maxf(0.0, float(targets[item_id_value])), location_id, required, method_cycles, selections, external_credits, [])
	var factories: Array = []
	var power_required := 0.0
	var cooling_required := 0.0
	var capital_goods := {}
	for method_id_value in method_cycles.keys():
		var method_id := str(method_id_value)
		var method: Dictionary = content.activities.get(method_id, {})
		var facility_id := str(method.get("facility", ""))
		var cycles_required := float(method_cycles.get(method_id, 0.0))
		var per_device: float = float(simulation.nominal_production_method_cycles_per_hour(state, location_id, method))
		var current_level := int(state.location_industry(location_id, facility_id).get("level", 0))
		var recommended := ceili(cycles_required / maxf(0.000001, per_device))
		var shortage := maxi(0, recommended - current_level)
		var definition: Dictionary = content.facilities.get(facility_id, {})
		power_required += float(recommended) * (float(definition.get("baseline_power_demand", 0.0)) + float(definition.get("advanced_power_demand", 0.0))) * float(method.get("production_energy_multiplier", 1.0))
		cooling_required += float(recommended) * float(content.industry_rules.get("cooling_demand_per_level", 2.0)) * float(method.get("production_cooling_multiplier", 1.0))
		var expansion_costs: Dictionary = simulation.industry_expansion_costs(state, location_id, facility_id, shortage) if shortage > 0 else {}
		for item_id_value in expansion_costs.keys():
			capital_goods[str(item_id_value)] = int(capital_goods.get(str(item_id_value), 0)) + int(expansion_costs[item_id_value])
		factories.append({"facility_id":facility_id, "method_id":method_id, "production_device_requirements":method.get("required_facility_capabilities", []).duplicate(), "required_cycles_per_hour":cycles_required, "cycles_per_hour_per_device":per_device, "current":current_level, "recommended":recommended, "shortage":shortage, "utilization":cycles_required / maxf(0.000001, per_device * float(maxi(1, recommended)))})
	var current_analysis := current_economy_analysis(state, location_id)
	var bottlenecks: Array = []
	for item_id_value in targets.keys():
		bottlenecks.append(trace_bottleneck(state, str(item_id_value), location_id, float(targets[item_id_value])))
	return {"location_id":location_id, "targets":targets.duplicate(true), "product_requirements":required, "method_selections":selections, "factory_requirements":factories, "infrastructure_requirements":{"power":power_required, "cooling":cooling_required, "storage":_planned_storage(required), "capital_goods":capital_goods}, "logistics":_planned_logistics(state, location_id, required), "industrial_geography":extraction_capacity_analysis(state, required), "bottlenecks":bottlenecks, "external_credits":external_credits, "current_economy":current_analysis, "read_only":true}


func _expand_requirement(state: SpaceGameState, item_id: String, rate: float, location_id: String, required: Dictionary, method_cycles: Dictionary, selections: Dictionary, external_credits: Array, stack: Array) -> void:
	required[item_id] = float(required.get(item_id, 0.0)) + rate
	if rate <= 0.0:
		return
	if stack.has(item_id):
		if not external_credits.has(item_id):
			external_credits.append(item_id)
		return
	var method := _preferred_method(state, item_id, location_id)
	if method.is_empty():
		return
	var output_quantity := 0.0
	for reward_value in method.get("rewards", []):
		var reward := reward_value as Dictionary
		if str(reward.get("item", "")) == item_id:
			output_quantity += float(reward.get("quantity", 0))
	if output_quantity <= 0.0:
		return
	var cycles := rate / output_quantity
	var method_id := str(method.get("id", ""))
	method_cycles[method_id] = float(method_cycles.get(method_id, 0.0)) + cycles
	selections[item_id] = method_id
	var next_stack := stack.duplicate()
	next_stack.append(item_id)
	for cost_value in method.get("costs", []):
		var cost := cost_value as Dictionary
		_expand_requirement(state, str(cost.get("item", "")), float(cost.get("quantity", 0)) * cycles, location_id, required, method_cycles, selections, external_credits, next_stack)


func _preferred_method(state: SpaceGameState, item_id: String, location_id: String) -> Dictionary:
	var candidates: Array = []
	for activity_value in content.activities.values():
		var activity := activity_value as Dictionary
		if str(activity.get("domain", "")) != "industry" or not bool(activity.get("repeat", true)):
			continue
		if not activity.get("rewards", []).any(func(reward): return str((reward as Dictionary).get("item", "")) == item_id):
			continue
		if simulation.activity_available(state, activity) and bool(simulation.production_method_environment_eligibility(state, location_id, activity).get("eligible", false)):
			candidates.append(activity)
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a, b): return float(a.get("work_required", 1.0)) < float(b.get("work_required", 1.0)) if float(a.get("work_required", 1.0)) != float(b.get("work_required", 1.0)) else str(a.get("id", "")) < str(b.get("id", "")))
	return candidates[0]


func trace_bottleneck(state: SpaceGameState, product_id: String, location_id: String, target_rate: float = 0.0) -> Dictionary:
	var analysis := current_economy_analysis(state, location_id)
	var rows := {}
	for row_value in analysis.get("products", []):
		rows[str((row_value as Dictionary).get("product_id", ""))] = row_value
	var chain: Array = [{"kind":"PRODUCT", "id":product_id}]
	var current_id := product_id
	var visited := {}
	var primary := "CAPACITY_SHORTAGE"
	while not visited.has(current_id):
		visited[current_id] = true
		var row: Dictionary = rows.get(current_id, {})
		if not row.get("blocked_sources", []).is_empty():
			var blocked: Dictionary = row.get("blocked_sources", [])[0]
			chain.append({"kind":"METHOD", "id":blocked.get("method_id", blocked.get("source_id", ""))})
			var blocker: Dictionary = blocked.get("blocker", {})
			primary = str(blocker.get("primary_reason", "CAPACITY_SHORTAGE"))
			if blocker.has("item_id"):
				current_id = str(blocker.get("item_id", ""))
				chain.append({"kind":"PRODUCT", "id":current_id})
				continue
			chain.append({"kind":"CONSTRAINT", "id":primary, "details":blocker})
			break
		var method := _preferred_method(state, current_id, location_id)
		if method.is_empty():
			primary = "NO_PRODUCTION_METHOD"
			chain.append({"kind":"CONSTRAINT", "id":primary})
			break
		chain.append({"kind":"METHOD", "id":method.get("id", "")})
		var critical_input := ""
		for cost_value in method.get("costs", []):
			var input_id := str((cost_value as Dictionary).get("item", ""))
			var input_row: Dictionary = rows.get(input_id, {})
			if float(input_row.get("net_rate", 0.0)) < -0.000001 or int(input_row.get("stock", 0)) <= 0:
				critical_input = input_id
				break
		if not critical_input.is_empty():
			current_id = critical_input
			chain.append({"kind":"PRODUCT", "id":current_id})
			primary = "INPUT_SHORTAGE"
			continue
		var facility_id := str(method.get("facility", ""))
		primary = "MISSING_FACTORY" if int(state.location_industry(location_id, facility_id).get("level", 0)) <= 0 else "FACTORY_SATURATED"
		chain.append({"kind":"FACTORY", "id":facility_id})
		break
	return {"product_id":product_id, "target_rate":target_rate, "actual_rate":float(rows.get(product_id, {}).get("production_rate", 0.0)), "primary_bottleneck":primary, "shortest_chain":chain}


func _planned_storage(required: Dictionary) -> Dictionary:
	var result := {}
	for item_id_value in required.keys():
		var item_id := str(item_id_value)
		var storage_class: String = str(simulation.storage_class_for_item(item_id))
		result[storage_class] = float(result.get(storage_class, 0.0)) + float(required[item_id]) * simulation.storage_units_for_item(item_id)
	return result


func _planned_logistics(state: SpaceGameState, location_id: String, required: Dictionary) -> Array:
	var result: Array = []
	for item_id_value in required.keys():
		var item_id := str(item_id_value)
		if state.item_quantity(item_id, location_id) > 0 or _preferred_method(state, item_id, location_id).is_empty():
			continue
		result.append({"product_id":item_id, "destination":location_id, "required_rate":required[item_id], "current_route_capacity":0.0, "lead_time_ms":_best_known_source_lead_time(state, item_id, location_id), "potential_congestion":"NO_LOCAL_SOURCE"})
	return result


func extraction_capacity_analysis(state: SpaceGameState, requirements: Dictionary) -> Dictionary:
	var products := {}
	for product_id_value in requirements.keys():
		var product_id := str(product_id_value)
		var sites: Array = []
		var total := 0.0
		var has_unsurveyed := false
		var has_deep_survey_option := false
		var has_method_option := false
		for site_id_value in content.mining_sites.keys():
			var site_id := str(site_id_value)
			var site: Dictionary = content.mining_sites.get(site_id, {})
			var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
			if str(mining_location.get("raw_material", "")) != product_id:
				continue
			var runtime: Dictionary = state.mining_site_states.get(site_id, {})
			var survey_state := str(runtime.get("survey_state", LocationState.UNKNOWN))
			if simulation.survey_state_rank(survey_state) < simulation.survey_state_rank(LocationState.SURVEYED):
				has_unsurveyed = true
				continue
			var method_id := str(runtime.get("extraction_method_id", "mobile_surface_extraction"))
			if method_id.is_empty():
				method_id = "mobile_surface_extraction"
			var potential := float(simulation.extraction_site_sustainable_potential(state, site_id, method_id))
			total += potential
			sites.append({"site_id":site_id, "location_id":mining_location.get("region", ""), "survey_state":survey_state, "method_id":method_id, "developed":runtime.get("developed", false), "sustainable_potential":potential})
			has_deep_survey_option = has_deep_survey_option or survey_state == LocationState.SURVEYED
			for method_value in mining_location.get("resource_profile", {}).get("allowed_methods", []):
				if str(method_value) != method_id and float(content.extraction_methods.get(str(method_value), {}).get("potential_multiplier", 1.0)) > float(content.extraction_methods.get(method_id, {}).get("potential_multiplier", 1.0)):
					has_method_option = true
		var required_rate := maxf(0.0, float(requirements.get(product_id, 0.0)))
		if sites.is_empty() and not has_unsurveyed:
			continue
		var solutions: Array[String] = []
		if required_rate > total + 0.000001:
			if has_unsurveyed:
				solutions.append("SURVEY_ADDITIONAL_SITES")
			if has_deep_survey_option:
				solutions.append("DEEP_SURVEY_EXISTING_SITES")
			if has_method_option:
				solutions.append("UNLOCK_OR_ADOPT_ADVANCED_EXTRACTION")
		products[product_id] = {"required_rate":required_rate, "surveyed_capacity":total, "shortfall":maxf(0.0, required_rate - total), "sites":sites, "potential_solutions":solutions}
	return {"products":products, "read_only":true}


func _best_known_source_lead_time(state: SpaceGameState, item_id: String, destination: String) -> float:
	var result := INF
	for site_value in content.mining_sites.values():
		var site := site_value as Dictionary
		var mining_location: Dictionary = content.mining_locations.get(str(site.get("location", "")), {})
		if str(mining_location.get("raw_material", "")) != item_id:
			continue
		var origin := str(mining_location.get("region", ""))
		if not state.has_location(origin) or str(state.location_state(origin).get("survey_state", LocationState.UNKNOWN)) == LocationState.UNKNOWN:
			continue
		result = minf(result, float(simulation.logistics_lead_time_ms(state, origin, destination)))
	return result


func _status_rank(status: String) -> int:
	match status:
		"CRITICAL": return 5
		"TIGHT": return 4
		"STORAGE_FULL": return 3
		"SURPLUS": return 2
		_: return 1
