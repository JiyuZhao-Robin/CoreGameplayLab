class_name LocationOperationsSnapshot
extends RefCounted

## Detached presentation projection. Factory owns production and field data;
## Location inventory is the sole planetary warehouse authority. Machine and
## transit custody are separate, never a second warehouse total.
static func build(game: Node, location_id: String) -> Dictionary:
	var state: SpaceGameState = game.state
	var content: ContentDatabase = game.content
	var simulation: SimulationEngine = game.simulation
	if not state.has_location(location_id):
		return {"valid":false, "protocol_version":1, "location_id":location_id}
	var location := state.location_state(location_id)
	var intelligence := simulation.location_intelligence(state, location_id)
	var world_ids: Array[String] = game.factory_world_ids_for_location(location_id)
	var survey_state := str(intelligence.get("survey_state", LocationState.UNKNOWN))
	var result := {
		"valid":true, "protocol_version":1, "location_id":location_id,
		"name":I18n.content(content.regions.get(location_id, {"id":location_id, "name":location_id})),
		"system_name":str(location.get("system_id", "sol")).to_upper(),
		"survey_state":survey_state,
		"environment":intelligence.get("environment", {}).duplicate(true),
		"environment_effects":{},
		"world_id":world_ids[0] if not world_ids.is_empty() else "",
		"landing_required":false, "hero_definition_id":"",
		"can_initialize_factory":world_ids.is_empty() and content.factory_grid_rules.get("world_profiles", {}).has(location_id) and simulation.survey_state_rank(survey_state) >= simulation.survey_state_rank(LocationState.SURVEYED),
		"power":{"generation_kw":0.0, "demand_kw":0.0},
		"storage":{},
		"industry":{"running":0, "blocked":0, "building_count":0, "construction_count":0},
		"resources":[], "inventory":[], "facilities":[], "alerts":[], "tasks":[], "fleet_count":0,
		"survey":_survey_snapshot(game, location_id, survey_state)
	}
	var extractors: Array = []
	if simulation.survey_state_rank(survey_state) >= simulation.survey_state_rank(LocationState.SURVEYED):
		result["environment_effects"] = simulation.factory_grid.environment_effects({"environment":intelligence.get("environment", {})})
	for world_id in world_ids:
		var factory: Dictionary = game.factory_workspace_snapshot(world_id)
		if world_id == str(result["world_id"]):
			result["landing_required"] = bool(factory.get("landing_required", false))
			if result["landing_required"]:
				result["hero_definition_id"] = "grid_planetary_core"
		var power: Dictionary = factory.get("power", {})
		result["power"]["generation_kw"] += float(power.get("generation_kw", 0.0))
		result["power"]["demand_kw"] += float(power.get("demand_kw", 0.0))
		for entity_value in factory.get("entities", []):
			var entity := entity_value as Dictionary
			result["industry"]["building_count"] += 1
			var status := str(entity.get("status", "IDLE"))
			var kind := str(entity.get("node_kind", ""))
			if world_id == str(result["world_id"]) and (str(result["hero_definition_id"]).is_empty() or str(entity.get("definition_id", "")) == "grid_planetary_core"):
				result["hero_definition_id"] = str(entity.get("definition_id", ""))
			if status in ["RUNNING", "FLOWING", "POWER_LIMITED", "PARTIAL_COVERAGE"]:
				result["industry"]["running"] += 1
			if status in ["NO_POWER", "POWER_LIMITED", "INPUT_SHORTAGE", "OUTPUT_FULL", "NO_RESOURCE", "NO_RECIPE", "MISSING_FUEL"]:
				result["industry"]["blocked"] += 1
				result["alerts"].append({"code":status, "message":str(entity.get("name", "")) + " · " + I18n.status(status), "entity_id":entity.get("id", ""), "world_id":world_id})
			if kind == "EXTRACTOR":
				var extractor := entity.duplicate(true)
				extractor["world_id"] = world_id
				extractors.append(extractor)
			if kind not in ["EXTRACTOR", "MACHINE"] and not (kind == "POWER" and not str(entity.get("recipe_id", "")).is_empty()):
				continue
			var product_id := str(entity.get("resource_id", ""))
			var rate := float(entity.get("actual_rate", 0.0)) * 3600.0
			var output_rates: Array = []
			var product_names: PackedStringArray = []
			if kind in ["MACHINE", "POWER"]:
				var recipe: Dictionary = content.factory_recipes.get(str(entity.get("recipe_id", "")), {})
				var outputs: Array = recipe.get("outputs", [])
				var cycles_per_hour := rate
				rate = 0.0
				for output in outputs:
					var output_name := _item_name(content, str(output.get("item", "")))
					var output_rate := cycles_per_hour * float(output.get("quantity", 1))
					output_rates.append({"name":output_name, "rate_per_hour":output_rate})
					product_names.append(output_name)
					rate += output_rate
			else:
				product_names.append(_item_name(content, product_id))
				output_rates.append({"name":_item_name(content, product_id), "rate_per_hour":rate})
			result["facilities"].append({"id":entity.get("id", ""), "world_id":world_id, "definition_id":entity.get("definition_id", ""), "name":entity.get("name", ""), "product":" / ".join(product_names), "outputs":output_rates, "rate_per_hour":rate, "status":status, "power_factor":entity.get("power_factor", 1.0)})
			result["facilities"].back()["kind"] = kind
		for order_value in factory.get("construction_orders", []):
			var order := order_value as Dictionary
			result["industry"]["construction_count"] += 1
			result["tasks"].append({"id":order.get("id", ""), "kind":"CONSTRUCTION", "definition_id":order.get("definition_id", ""), "name":order.get("building_name", ""), "status":order.get("status", ""), "blocker":order.get("blocker_code", ""), "progress":order.get("progress", 0.0), "remaining_ms":order.get("remaining_ms", -1.0), "action":{"kind":"OPEN_FACTORY", "world_id":world_id, "section":"CONSTRUCTION", "order_id":order.get("id", "")}})
	for resource_value in intelligence.get("resources", []):
		var resource := resource_value as Dictionary
		var item_id := str(resource.get("resource_type", ""))
		var row := {"id":resource.get("resource_field_id", ""), "name":_item_name(content, item_id) if not item_id.is_empty() else I18n.category(str(resource.get("resource_category", "UNKNOWN"))), "category":resource.get("resource_category", "UNKNOWN"), "discovered":not item_id.is_empty(), "exploited":false, "entity_id":"", "world_id":resource.get("world_id", "")}
		row["item_id"] = item_id
		if not state.factory_worlds.has(str(row["world_id"])):
			row["world_id"] = ""
		if resource.has("grade"):
			row["grade"] = resource["grade"]
		if resource.has("mapped_potential_per_hour"):
			row["potential_per_hour"] = resource["mapped_potential_per_hour"]
		if resource.has("potential_band"):
			row["potential_band"] = resource["potential_band"]
		var source_world: Dictionary = state.factory_worlds.get(str(resource.get("world_id", "")), {})
		var source_field: Dictionary = source_world.get("resource_fields", {}).get(str(resource.get("resource_field_id", "")), {})
		for extractor_value in extractors:
			var extractor := extractor_value as Dictionary
			if item_id.is_empty() or str(extractor.get("resource_id", "")) != item_id or str(extractor.get("world_id", "")) != str(resource.get("world_id", "")):
				continue
			if _footprints_overlap(source_field.get("footprint", {}), extractor.get("footprint", {})):
				row["exploited"] = true
				row["entity_id"] = extractor.get("id", "")
				break
		row["action"] = {"kind":"OPEN_FACTORY", "world_id":row["world_id"], "section":"CANVAS", "entity_id":row["entity_id"]} if not str(row["world_id"]).is_empty() else ({"kind":"INITIALIZE_FACTORY"} if result["can_initialize_factory"] else {"kind":"OPEN_SURVEY", "location_id":location_id})
		result["resources"].append(row)
	var incoming := {}
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		if str(shipment.get("destination", "")) == location_id:
			for item_id_value in shipment.get("cargo", {}).keys():
				incoming[item_id_value] = int(incoming.get(item_id_value, 0)) + int(shipment["cargo"][item_id_value])
		if location_id not in [str(shipment.get("destination", "")), str(shipment.get("origin", ""))]:
			continue
		var remaining := float(shipment.get("remaining_ms", 0.0))
		result["tasks"].append({"id":shipment.get("id", ""), "kind":"TRANSPORT", "name":_amounts(content, shipment.get("cargo", {})), "status":shipment.get("status", "IN_TRANSIT"), "progress":clampf(1.0 - remaining / maxf(1.0, float(shipment.get("total_ms", 1.0))), 0.0, 1.0), "remaining_ms":remaining, "action":{"kind":"OPEN_LOGISTICS"}})
		var cargo_ids: Array = shipment.get("cargo", {}).keys()
		cargo_ids.sort()
		result["tasks"].back()["item_id"] = str(cargo_ids[0]) if not cargo_ids.is_empty() else ""
	result["inventory"] = _inventory_rows(game, location_id, incoming, result["resources"])
	var by_item := {}
	var stocked := 0
	var full := 0
	var maximum_fill := 0.0
	for row in result["inventory"]:
		by_item[row["id"]] = row
		stocked += 1 if int(row["quantity"]) > 0 else 0
		full += 1 if float(row["fill_ratio"]) >= 1.0 else 0
		maximum_fill = maxf(maximum_fill, float(row["fill_ratio"]))
	result["storage"] = {"storage_mode":"PER_ITEM", "item_count":result["inventory"].size(), "stocked_item_count":stocked, "full_item_count":full, "max_utilization":maximum_fill}
	for row in result["resources"]:
		var stock: Dictionary = by_item.get(str(row.get("item_id", "")), {})
		for key in ["quantity", "capacity", "fill_ratio", "net_rate_per_minute", "trend_known", "trend_window_ms", "incoming"]:
			if stock.has(key):
				row[key] = stock[key]
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		if str(ship.get("location_id", "")) == location_id and str(ship.get("condition", "")) != "DESTROYED" and str(ship.get("status", "")) != "EXPEDITION":
			result["fleet_count"] += 1
	for order_value in state.shipyard_queue:
		var order := order_value as Dictionary
		if str(order.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != location_id:
			continue
		var total := maxi(1, int(order.get("quantity_total", 1)))
		var completed := float(order.get("quantity_completed", 0)) + (float(order.get("completed_segments", 0)) + float(order.get("cycle_progress", 0.0))) / 100.0
		result["tasks"].append({"id":order.get("project_id", order.get("plan_id", "")), "kind":"SHIPYARD", "name":I18n.content(content.ship_construction_projects.get(str(order.get("plan_id", "")), {})), "status":order.get("status", ""), "progress":clampf(completed / float(total), 0.0, 1.0), "remaining_ms":-1.0, "action":{"kind":"OPEN_SURVEY_SHIPYARD"}})
	var mission: Dictionary = state.survey_mission
	if str(mission.get("status", "")) == "RUNNING" and location_id in [str(mission.get("target", "")), str(mission.get("origin", ""))]:
		var duration := maxf(1.0, float(mission.get("duration_ms", 1.0)))
		result["tasks"].append({"id":mission.get("mission_id", ""), "kind":"SURVEY", "name":I18n.content(content.regions.get(str(mission.get("target", "")), {})) + " · " + I18n.status(str(mission.get("target_state", ""))), "status":"RUNNING", "progress":clampf(float(mission.get("progress_ms", 0.0)) / duration, 0.0, 1.0), "remaining_ms":maxf(0.0, duration - float(mission.get("progress_ms", 0.0))), "action":{"kind":"OPEN_SURVEY", "location_id":mission.get("target", "")}})
		result["tasks"].back()["item_id"] = "sensor_array"
	result["industry_empty_action"] = {"kind":"OPEN_FACTORY", "world_id":result["world_id"], "section":"CANVAS"} if not str(result["world_id"]).is_empty() else ({"kind":"INITIALIZE_FACTORY"} if result["can_initialize_factory"] else {"kind":"OPEN_SURVEY", "location_id":location_id})
	result["task_empty_action"] = {"kind":"OPEN_FACTORY", "world_id":result["world_id"], "section":"CONSTRUCTION"} if not str(result["world_id"]).is_empty() else result["industry_empty_action"].duplicate(true)
	if bool(result["landing_required"]):
		result["industry_empty_action"]["definition_id"] = "grid_planetary_core"
		result["task_empty_action"] = result["industry_empty_action"].duplicate(true)
	return result


static func _inventory_rows(game: Node, location_id: String, incoming: Dictionary, resources: Array) -> Array:
	var known: Dictionary = incoming.duplicate(true)
	var quantities: Dictionary = game.state.location_inventory(location_id).duplicate(true)
	var capacities: Dictionary = game.simulation.location_storage_capacities(game.state, location_id)
	# Retain compatibility columns as zero, not a second storage authority.
	var factory_quantities := {}
	var factory_capacity := 0
	known.merge(quantities, true)
	for recipe in game.content.factory_recipes.values():
		if not game._factory_definition_available(recipe):
			continue
		for entry in recipe.get("inputs", []) + recipe.get("outputs", []):
			known[str(entry.get("item", ""))] = true
	for building in game.content.factory_buildings.values():
		if not game._factory_definition_available(building):
			continue
		var product_id := str(building.get("deployment_item_id", ""))
		if not product_id.is_empty():
			known[product_id] = true
	for resource in resources:
		if not str(resource.get("item_id", "")).is_empty():
			known[str(resource["item_id"])] = true
	var ids: Array = known.keys()
	ids.sort()
	for item_id in ids:
		if not quantities.has(item_id):
			quantities[item_id] = 0
	var trends: Dictionary = game.location_inventory_trends.sample(location_id, game.state.total_elapsed_ms, quantities)
	var rows: Array = []
	for item_id_value in ids:
		var item_id := str(item_id_value)
		if not game.content.items.has(item_id):
			continue
		var quantity := maxi(0, int(quantities.get(item_id, 0)))
		var local_capacity := int(capacities.get(game.simulation.storage_class_for_item(item_id), 0))
		var capacity := local_capacity + factory_capacity
		var row := {"id":item_id, "item_id":item_id, "name":_item_name(game.content, item_id), "quantity":quantity, "location_quantity":game.state.item_quantity(item_id, location_id), "warehouse_quantity":int(factory_quantities.get(item_id, 0)), "capacity":capacity, "fill_ratio":clampf(float(quantity) / float(capacity), 0.0, 1.0) if capacity > 0 else (1.0 if quantity > 0 else 0.0), "incoming":int(incoming.get(item_id, 0)), "category":str(game.content.items[item_id].get("category", "UNKNOWN")), "discovered":true}
		row.merge(trends.get(item_id, {}), true)
		rows.append(row)
	return rows


static func _survey_snapshot(game: Node, location_id: String, survey_state: String) -> Dictionary:
	var state: SpaceGameState = game.state
	var content: ContentDatabase = game.content
	var simulation: SimulationEngine = game.simulation
	var order := LocationState.SURVEY_STATE_ORDER
	var index := order.find(survey_state)
	var next_state := str(order[index + 1]) if index >= 0 and index + 1 < order.size() else ""
	var mission: Dictionary = state.survey_mission
	var active := str(mission.get("status", "")) == "RUNNING" and location_id in [str(mission.get("target", "")), str(mission.get("origin", ""))]
	var duration := maxf(1.0, float(mission.get("duration_ms", 1.0)))
	var result := {"next_state":next_state, "active":active, "progress":float(mission.get("progress_ms", 0.0)) / duration if active else 0.0, "remaining_ms":maxf(0.0, duration - float(mission.get("progress_ms", 0.0))) if active else 0.0, "cost_text":"", "ships":[], "reason":"", "can_start":false}
	result["target_location_id"] = str(mission.get("target", location_id)) if active else location_id
	if active:
		result["next_state"] = str(mission.get("target_state", next_state))
	if next_state.is_empty():
		return result
	var availability: Dictionary = game.survey_mission_availability(location_id, next_state)
	result["reason"] = _availability_reason(content, availability)
	result["cost_text"] = _amounts(content, availability.get("costs", {}))
	var capability := str(content.survey_rules.get("required_capabilities", {}).get(next_state, ""))
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		var ship_id := str(ship.get("instance_id", ""))
		if simulation.capability_value_for_ships(state, capability, [ship_id]) < 1.0:
			continue
		var candidate: Dictionary = game.survey_mission_availability(location_id, next_state, [ship_id])
		var assignment: Dictionary = game.ship_formation_assignment_availability(ship_id, SpaceGameState.DEFAULT_FORMATION_ID)
		result["ships"].append({"id":ship_id, "name":ship.get("name", ship_id), "allowed":bool(candidate.get("allowed", false)), "reason":_availability_reason(content, candidate), "can_assign":state.ship_formation_id(ship_id).is_empty() and bool(assignment.get("allowed", false))})
		result["can_start"] = bool(result["can_start"]) or bool(candidate.get("allowed", false))
	return result


static func _availability_reason(content: ContentDatabase, availability: Dictionary) -> String:
	var reasons: PackedStringArray = []
	for blocker_value in availability.get("blockers", []):
		var blocker := blocker_value as Dictionary
		var code := str(blocker.get("code", "UNKNOWN"))
		if code == "INPUT_SHORTAGE":
			reasons.append(I18n.core("blocker.INPUT_SHORTAGE") % [_item_name(content, str(blocker.get("item_id", ""))), blocker.get("available", 0), blocker.get("required", 0)])
		else:
			reasons.append(I18n.core("availability.%s" % code, code.replace("_", " ").capitalize()))
	return " · ".join(reasons)


static func _item_name(content: ContentDatabase, item_id: String) -> String:
	return "—" if item_id.is_empty() else I18n.content(content.items.get(item_id, {"id":item_id, "name":item_id}))


static func _amounts(content: ContentDatabase, values: Dictionary) -> String:
	var parts: PackedStringArray = []
	var keys := values.keys()
	keys.sort()
	for key in keys:
		parts.append("%s × %d" % [_item_name(content, str(key)), int(values[key])])
	return " · ".join(parts)


static func _footprints_overlap(left: Dictionary, right: Dictionary) -> bool:
	var lo: Dictionary = left.get("origin", {})
	var ls: Dictionary = left.get("size", {})
	var ro: Dictionary = right.get("origin", {})
	var rs: Dictionary = right.get("size", {})
	return Rect2(float(lo.get("x", 0)), float(lo.get("y", 0)), float(ls.get("x", 0)), float(ls.get("y", 0))).intersects(Rect2(float(ro.get("x", 0)), float(ro.get("y", 0)), float(rs.get("x", 0)), float(rs.get("y", 0))))
