class_name FactoryDroneTransport
extends RefCounted

## A shipment owns cargo only after pickup. Empty collection flights reserve
## producer output; delivery flights reserve exactly the consumer's deficit.
## Location inventory is the sole warehouse authority, including at drone towers.
const EPSILON := 0.000001


static func center(entity: Dictionary) -> Vector2:
	var footprint: Dictionary = entity.get("footprint", {})
	var origin: Dictionary = footprint.get("origin", {})
	var size: Dictionary = footprint.get("size", {})
	return Vector2(float(origin.get("x", 0)), float(origin.get("y", 0))) + Vector2(float(size.get("x", 1)), float(size.get("y", 1))) * 0.5


static func tower_radius(entity: Dictionary, definitions: Dictionary, rules: Dictionary) -> float:
	var definition: Dictionary = definitions.get(str(entity.get("definition_id", "")), {})
	return maxf(0.0, float(definition.get("drone_radius_tiles", entity.get("drone_radius_tiles", rules.get("drone_radius_tiles", 64.0)))))


static func covering_towers(world: Dictionary, entity: Dictionary, definitions: Dictionary, rules: Dictionary) -> Array:
	var result: Array = []
	for id in _tower_ids(world, definitions):
		var tower: Dictionary = world["entities"][id]
		if center(tower).distance_to(center(entity)) <= tower_radius(tower, definitions, rules) + EPSILON:
			result.append(id)
	return result


static func normalize_shipments(value: Variant, world: Dictionary) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key in value:
		if value[key] is not Dictionary:
			continue
		var job: Dictionary = value[key].duplicate(true)
		var id := str(job.get("id", key))
		var item := str(job.get("item_id", ""))
		var cargo := {}
		if job.get("cargo", {}) is Dictionary:
			for cargo_item in job.get("cargo", {}):
				var quantity := maxi(0, int(job["cargo"][cargo_item]))
				if quantity > 0:
					cargo[str(cargo_item)] = quantity
		var phase := str(job.get("phase", "TO_DELIVERY"))
		if item.is_empty() and not cargo.is_empty():
			item = str(cargo.keys()[0])
		if id.is_empty() or item.is_empty():
			continue
		if cargo.is_empty() and phase not in ["TO_PICKUP", "RETURNING"]:
			continue
		job["id"] = id
		job["item_id"] = item
		job["cargo"] = cargo
		job["phase"] = phase
		job["reserved_quantity"] = maxi(0, int(job.get("reserved_quantity", 0)))
		job["delivery_quantity"] = maxi(0, int(job.get("delivery_quantity", _quantity(job))))
		job["remaining_ms"] = maxf(0.0, float(job.get("remaining_ms", 0.0)))
		job["travel_ms"] = maxf(EPSILON, float(job.get("travel_ms", job["remaining_ms"])))
		job["status"] = str(job.get("status", "IN_TRANSIT"))
		job["tower_id"] = str(job.get("tower_id", ""))
		job["source_id"] = str(job.get("source_id", ""))
		job["target_id"] = str(job.get("target_id", ""))
		job["path_tiles"] = job.get("path_tiles", []).duplicate(true) if job.get("path_tiles", []) is Array else []
		if not job.has("from_position"):
			var path: Array = job["path_tiles"]
			var position := _legacy_position(path, clampf(1.0 - float(job["remaining_ms"]) / float(job["travel_ms"]), 0.0, 1.0))
			var destination := _legacy_position(path, 1.0)
			job["from_position"] = {"x":position.x, "y":position.y}
			job["to_position"] = {"x":destination.x, "y":destination.y}
			job["travel_ms"] = maxf(EPSILON, float(job["remaining_ms"]))
		if str(job["tower_id"]).is_empty():
			for endpoint in [str(job["source_id"]), str(job["target_id"])]:
				if _is_tower(world.get("entities", {}).get(endpoint, {}), {}):
					job["tower_id"] = endpoint
					break
			if str(job["tower_id"]).is_empty():
				job["tower_id"] = _nearest_tower(world, _position(job), {})
		if not (value[key] as Dictionary).has("phase") and str(job.get("destination_kind", "")) == "WAREHOUSE":
			job["phase"] = "RETURNING"
			# The owning tower must be the actual return destination.
			if _is_tower(world.get("entities", {}).get(str(job["target_id"]), {}), {}):
				job["tower_id"] = str(job["target_id"])
			elif not str(job["tower_id"]).is_empty():
				_return_home(job, world, {})
		job["courier_owner_id"] = str(job["tower_id"])
		if str(job["status"]).begins_with("BLOCKED_") and str(job["status"]) != "BLOCKED_MANIFEST":
			job["status"] = "IN_TRANSIT"
		result[id] = job
	return result


static func queue(world: Dictionary, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary = {}, _graph: Dictionary = {}) -> int:
	if not world.get("drone_shipments", {}) is Dictionary:
		world["drone_shipments"] = {}
	if not world.has("drone_shipments"):
		world["drone_shipments"] = {}
	var created := 0
	var tower_ids := _tower_ids(world, building_definitions)
	# One job per tower per round distributes overlapping collection fairly.
	var changed := true
	while changed:
		changed = false
		for tower_id in tower_ids:
			if not _has_slot(world, tower_id, building_definitions, rules):
				continue
			# Production has first choice on three dispatches out of four. The
			# fourth can refill inputs even under continuously saturated output.
			var supply_first := int(world.get("next_drone_shipment_serial", 1)) % 4 == 0
			var queued := false
			if supply_first:
				queued = _queue_supply(world, tower_id, building_definitions, recipe_definitions, rules, inventory_context)
			if not queued:
				queued = _queue_collection(world, tower_id, building_definitions, rules)
			if not queued and not supply_first:
				queued = _queue_supply(world, tower_id, building_definitions, recipe_definitions, rules, inventory_context)
			if queued:
				created += 1
				changed = true
	return created


static func advance(world: Dictionary, seconds: float, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary = {}, graph: Dictionary = {}) -> Dictionary:
	var created := queue(world, building_definitions, recipe_definitions, rules, inventory_context, graph)
	var delivered := 0
	var budget := maxf(0.0, seconds) * 1000.0
	for job in world.get("drone_shipments", {}).values():
		if str(job.get("status", "")) == "BLOCKED_TARGET_FULL":
			job["status"] = "IN_TRANSIT"
	# Advance all flights to the same next event before resolving pickups.
	# This avoids letting a lexically earlier job use time ahead of other drones.
	var events := 0
	while events < 100000:
		events += 1
		var ids: Array = world.get("drone_shipments", {}).keys()
		ids.sort()
		var active: Array = []
		var step := budget
		for id in ids:
			var job: Dictionary = world["drone_shipments"][id]
			_repair(job, world, building_definitions, recipe_definitions, rules)
			if str(job.get("status", "")).begins_with("BLOCKED_"):
				continue
			active.append(id)
			step = minf(step, maxf(0.0, float(job.get("remaining_ms", 0.0))))
		if active.is_empty():
			break
		for id in active:
			var job: Dictionary = world["drone_shipments"][id]
			job["remaining_ms"] = maxf(0.0, float(job.get("remaining_ms", 0.0)) - step)
		budget -= step
		var arrivals := 0
		for id in active:
			var job: Dictionary = world["drone_shipments"][id]
			if float(job.get("remaining_ms", 0.0)) <= EPSILON:
				var result := _arrive(job, world, building_definitions, recipe_definitions, rules, inventory_context)
				delivered += int(result.get("delivered", 0))
				if bool(result.get("done", false)):
					world["drone_shipments"].erase(id)
				arrivals += 1
		created += queue(world, building_definitions, recipe_definitions, rules, inventory_context, graph)
		if budget <= EPSILON or arrivals == 0:
			break
	var blocked := 0
	for job in world.get("drone_shipments", {}).values():
		if str(job.get("status", "")).begins_with("BLOCKED_"):
			blocked += 1
	return {"delivered":delivered, "created":created, "blocked":blocked}


static func logistics_snapshot(world: Dictionary, rules: Dictionary, graph: Dictionary = {}) -> Dictionary:
	var definitions: Dictionary = graph.get("building_definitions", {})
	var capacity := 0
	var tower_ids := _tower_ids(world, definitions)
	for id in tower_ids:
		capacity += _tower_count(world["entities"][id], definitions, rules)
	capacity = mini(capacity, maxi(1, int(rules.get("drone_max_active_shipments", 256))))
	var active: int = world.get("drone_shipments", {}).size()
	return {"tower_count":tower_ids.size(), "capacity":capacity, "required":active, "utilization":0.0 if capacity == 0 else clampf(float(active) / capacity, 0.0, 1.0), "active_shipments":active, "capacity_unit":"CONCURRENT_DRONES"}


static func workspace_shipments(world: Dictionary, _rules: Dictionary) -> Array:
	var result: Array = []
	var ids: Array = world.get("drone_shipments", {}).keys()
	ids.sort()
	for id in ids:
		var job: Dictionary = world["drone_shipments"][id]
		var remaining := maxf(0.0, float(job.get("remaining_ms", 0.0)))
		var progress := clampf(1.0 - remaining / maxf(EPSILON, float(job.get("travel_ms", 0.0))), 0.0, 1.0)
		var position := _position(job)
		var snapshot: Dictionary = job.duplicate(true)
		snapshot["quantity"] = _quantity(job)
		snapshot["position"] = {"x":position.x, "y":position.y}
		snapshot["travel_progress"] = progress
		snapshot["progress"] = progress
		var destination: Dictionary = job.get("to_position", {})
		var origin: Dictionary = job.get("from_position", {})
		snapshot["heading"] = Vector2(float(destination.get("x", 0)) - float(origin.get("x", 0)), float(destination.get("y", 0)) - float(origin.get("y", 0))).angle()
		snapshot["path_progress"] = progress
		snapshot["phase_progress"] = progress
		snapshot["loading_remaining_ms"] = 0.0
		snapshot["eta_ms"] = -1.0 if str(job.get("status", "")).begins_with("BLOCKED_") else remaining
		result.append(snapshot)
	return result


static func _queue_collection(world: Dictionary, tower_id: String, definitions: Dictionary, rules: Dictionary) -> bool:
	var tower: Dictionary = world["entities"][tower_id]
	for source_id in _fair_ids(world, str(world.get("drone_dispatch_after", ""))):
		var source: Dictionary = world["entities"][source_id]
		if not _live(source) or _is_tower(source, definitions) or not _covered(tower, source, definitions, rules):
			continue
		var items: Array = source.get("outputs", {}).keys()
		items.sort()
		for item_value in items:
			var item := str(item_value)
			var reserved := 0
			for job in world["drone_shipments"].values():
				if str(job.get("phase", "")) == "TO_PICKUP" and str(job.get("source_id", "")) == source_id and str(job.get("item_id", "")) == item:
					reserved += int(job.get("reserved_quantity", 0))
			var available := maxi(0, int(source.get("outputs", {}).get(item, 0)) - reserved)
			var amount := _cargo_limit(rules)
			# A completed deployment kit must be usable for the next expansion.
			if item.begins_with("building_") and definitions.has(item.trim_prefix("building_")):
				amount = mini(amount, available)
			var returned := maxi(0, int(source.get("drone_return_items", {}).get(item, 0)) - reserved)
			if returned > 0:
				amount = mini(amount, mini(available, returned))
			if available < amount or amount <= 0:
				continue
			var job := _new_job(world, tower_id, source_id, item)
			job["reserved_quantity"] = amount
			job["phase"] = "TO_PICKUP"
			job["target_id"] = source_id
			job["destination_kind"] = "ENTITY"
			_fly(job, center(tower), center(source), rules)
			world["drone_shipments"][job["id"]] = job
			world["drone_dispatch_after"] = source_id
			return true
	return false


static func _queue_supply(world: Dictionary, tower_id: String, definitions: Dictionary, recipes: Dictionary, rules: Dictionary, context: Dictionary) -> bool:
	var tower: Dictionary = world["entities"][tower_id]
	for target_id in _fair_ids(world, str(tower.get("drone_delivery_after", ""))):
		var target: Dictionary = world["entities"][target_id]
		if not _covered(tower, target, definitions, rules):
			continue
		var wanted := _input_thresholds(world, target, definitions, recipes, rules)
		var items: Array = wanted.keys()
		items.sort()
		var preferred_fuel := str(target.get("fuel_item_id", target.get("dsp_fuel_item_id", "")))
		if items.has(preferred_fuel):
			items.erase(preferred_fuel)
			items.push_front(preferred_fuel)
		for item_value in items:
			var item := str(item_value)
			var quantity := mini(_cargo_limit(rules), mini(_demand(world, target_id, item, definitions, recipes, rules), _available(context, item)))
			if quantity <= 0:
				continue
			_withdraw(context, item, quantity)
			var job := _new_job(world, tower_id, tower_id, item)
			job["source_kind"] = "WAREHOUSE"
			job["cargo"] = {item:quantity}
			_send_consumer(job, target_id, quantity, center(tower), world, rules)
			world["drone_shipments"][job["id"]] = job
			tower["drone_delivery_after"] = target_id
			return true
	return false


static func _repair(job: Dictionary, world: Dictionary, definitions: Dictionary, recipes: Dictionary, rules: Dictionary) -> void:
	var cargo: Dictionary = job.get("cargo", {})
	if cargo.size() > 1 or (not cargo.is_empty() and (not cargo.has(str(job.get("item_id", ""))) or str(job.get("phase", "")) == "TO_PICKUP")):
		job["status"] = "BLOCKED_MANIFEST"
		return
	var tower: Dictionary = world.get("entities", {}).get(str(job.get("tower_id", "")), {})
	if not _is_tower(tower, definitions) or not _live(tower):
		var replacement := _nearest_tower(world, _position(job), definitions)
		if replacement.is_empty():
			job["status"] = "BLOCKED_TOWER"
			return
		job["tower_id"] = replacement
		job["courier_owner_id"] = replacement
		_return_home(job, world, rules)
		return
	if str(job.get("status", "")) == "BLOCKED_TOWER":
		_return_home(job, world, rules)
		return
	var phase := str(job.get("phase", ""))
	if phase == "TO_PICKUP":
		var source: Dictionary = world.get("entities", {}).get(str(job.get("source_id", "")), {})
		if not _live(source) or not _covered(tower, source, definitions, rules):
			_return_home(job, world, rules)
	elif phase == "TO_DELIVERY":
		var target: Dictionary = world.get("entities", {}).get(str(job.get("target_id", "")), {})
		if not _covered(tower, target, definitions, rules) or not _input_thresholds(world, target, definitions, recipes, rules).has(str(job.get("item_id", ""))):
			_return_home(job, world, rules)


static func _arrive(job: Dictionary, world: Dictionary, definitions: Dictionary, recipes: Dictionary, rules: Dictionary, context: Dictionary) -> Dictionary:
	var phase := str(job.get("phase", ""))
	var item := str(job.get("item_id", ""))
	if phase == "TO_PICKUP":
		var source: Dictionary = world.get("entities", {}).get(str(job.get("source_id", "")), {})
		var quantity := int(job.get("reserved_quantity", 0))
		if quantity <= 0 or int(source.get("outputs", {}).get(item, 0)) < quantity:
			_return_home(job, world, rules)
			return {}
		source["outputs"][item] = int(source["outputs"][item]) - quantity
		if source.get("drone_return_items", {}) is Dictionary and source.get("drone_return_items", {}).has(item):
			source["drone_return_items"][item] = maxi(0, int(source["drone_return_items"][item]) - quantity)
		job["cargo"] = {item:quantity}
		job["reserved_quantity"] = 0
		var consumer := _select_consumer(job, world, definitions, recipes, rules)
		if consumer.is_empty():
			_return_home(job, world, rules)
		else:
			_send_consumer(job, str(consumer["id"]), int(consumer["quantity"]), _position(job), world, rules)
		return {}
	if phase == "TO_DELIVERY":
		var target_id := str(job.get("target_id", ""))
		var target: Dictionary = world.get("entities", {}).get(target_id, {})
		var quantity := mini(_quantity(job), mini(int(job.get("delivery_quantity", 0)), _demand(world, target_id, item, definitions, recipes, rules, str(job.get("id", "")))))
		if quantity > 0:
			if not target.has("inputs"):
				target["inputs"] = {}
			target["inputs"][item] = int(target["inputs"].get(item, 0)) + quantity
			_set_quantity(job, _quantity(job) - quantity)
		_return_home(job, world, rules)
		return {"delivered":quantity}
	if phase == "RETURNING":
		var quantity := _quantity(job)
		if quantity == 0:
			return {"done":true}
		var accepted := mini(quantity, maxi(0, int(context.get("free_capacity", {}).get(item, 0)))) if context.has("inventory") else 0
		if accepted > 0:
			_deposit(context, item, accepted)
			_set_quantity(job, quantity - accepted)
		if _quantity(job) == 0:
			return {"done":true, "delivered":accepted}
		# A tower can fill while the drone returns. If demand later appears,
		# retained cargo can resume delivery instead of deadlocking every slot.
		var consumer := _select_consumer(job, world, definitions, recipes, rules)
		if not consumer.is_empty():
			_send_consumer(job, str(consumer["id"]), int(consumer["quantity"]), _position(job), world, rules)
			return {"delivered":accepted}
		job["status"] = "BLOCKED_TARGET_FULL"
		return {"delivered":accepted}
	job["status"] = "BLOCKED_PHASE"
	return {}


static func _select_consumer(job: Dictionary, world: Dictionary, definitions: Dictionary, recipes: Dictionary, rules: Dictionary) -> Dictionary:
	var tower: Dictionary = world["entities"].get(str(job.get("tower_id", "")), {})
	for id in _fair_ids(world, str(tower.get("drone_delivery_after", ""))):
		var target: Dictionary = world["entities"][id]
		if not _covered(tower, target, definitions, rules):
			continue
		var wanted := _demand(world, id, str(job.get("item_id", "")), definitions, recipes, rules)
		if wanted > 0:
			tower["drone_delivery_after"] = id
			return {"id":id, "quantity":mini(_quantity(job), wanted)}
	return {}


static func _input_thresholds(world: Dictionary, target: Dictionary, definitions: Dictionary, recipes: Dictionary, rules: Dictionary) -> Dictionary:
	var result := {}
	if not _live(target) or _is_tower(target, definitions):
		return result
	var definition: Dictionary = definitions.get(str(target.get("definition_id", "")), {})
	var recipe: Dictionary = recipes.get(str(target.get("recipe_id", "")), {})
	var allowed: Array = definition.get("recipe_ids", []).duplicate()
	if bool(target.get("legacy_recipe_continuation", false)) and not str(recipe.get("replacement_building_id", "")).is_empty():
		allowed.append_array(definition.get("legacy_recipe_ids", []))
	if not recipe.is_empty() and (allowed.is_empty() or allowed.has(str(target.get("recipe_id", "")))):
		for input in recipe.get("inputs", []):
			var item := str(input.get("item", ""))
			if not item.is_empty():
				result[item] = int(result.get(item, 0)) + maxi(0, int(input.get("quantity", 1))) * maxi(1, int(rules.get("drone_input_batches", 10)))
	# Preserve fuel/spray consumers when replacing local transport. They use the
	# same finite inputs and capacity checks as ordinary recipe ingredients.
	var metadata: Dictionary = definition.get("runtime_metadata", {})
	if str(metadata.get("power_mode", "")) == "FUEL_GENERATOR":
		var fuels: Array = metadata.get("fuel_item_ids", [])
		var selected := ""
		for fuel in fuels:
			if int(target.get("inputs", {}).get(str(fuel), 0)) > 0:
				selected = str(fuel)
		for shipment in world.get("drone_shipments", {}).values():
			if str(shipment.get("phase", "")) == "TO_DELIVERY" and str(shipment.get("target_id", "")) == str(target.get("id", "")) and fuels.has(str(shipment.get("item_id", ""))):
				selected = str(shipment.get("item_id", ""))
		for fuel in fuels:
			if selected.is_empty() or selected == str(fuel):
				result[str(fuel)] = maxi(1, int(rules.get("drone_fuel_buffer_items", 1)))
	var service: Dictionary = world.get("spray_services", {}).get(str(target.get("id", "")), {})
	var config: Dictionary = target.get("proliferator", {})
	var coater: Dictionary = world.get("entities", {}).get(str(service.get("coater_id", "")), {})
	var coater_definition: Dictionary = definitions.get(str(coater.get("definition_id", "")), {})
	var valid_coater := _live(coater) and str(coater_definition.get("runtime_metadata", {}).get("special_effect_id", "")) == "PROLIFERATOR_SERVICE"
	if valid_coater and bool(service.get("enabled", true)) and str(config.get("mode", "NORMAL")) in ["EXTRA", "SPEED"]:
		var spray := str(config.get("item_id", service.get("item_id", "")))
		if not spray.is_empty() and spray == str(service.get("item_id", spray)):
			result[spray] = maxi(1, int(rules.get("drone_spray_buffer_items", 1)))
	return result


static func _demand(world: Dictionary, target_id: String, item: String, definitions: Dictionary, recipes: Dictionary, rules: Dictionary, exclude: String = "") -> int:
	var target: Dictionary = world.get("entities", {}).get(target_id, {})
	var thresholds := _input_thresholds(world, target, definitions, recipes, rules)
	if not thresholds.has(item):
		return 0
	var inbound_item := 0
	var inbound_total := 0
	for job in world.get("drone_shipments", {}).values():
		if str(job.get("id", "")) == exclude or str(job.get("phase", "")) != "TO_DELIVERY" or str(job.get("target_id", "")) != target_id:
			continue
		var quantity := mini(_quantity(job), int(job.get("delivery_quantity", 0)))
		inbound_total += quantity
		if str(job.get("item_id", "")) == item:
			inbound_item += quantity
	var definition: Dictionary = definitions.get(str(target.get("definition_id", "")), {})
	var free := maxi(0, int(definition.get("input_capacity", 20)) - _total(target.get("inputs", {})) - inbound_total)
	return mini(free, maxi(0, int(thresholds[item]) - int(target.get("inputs", {}).get(item, 0)) - inbound_item))


static func _new_job(world: Dictionary, tower_id: String, source_id: String, item: String) -> Dictionary:
	var serial := maxi(1, int(world.get("next_drone_shipment_serial", 1)))
	while world.get("drone_shipments", {}).has("DRONE-SHIP-%d" % serial):
		serial += 1
	world["next_drone_shipment_serial"] = serial + 1
	return {"id":"DRONE-SHIP-%d" % serial, "tower_id":tower_id, "courier_owner_id":tower_id, "source_id":source_id, "source_kind":"ENTITY", "target_id":"", "destination_kind":"ENTITY", "item_id":item, "cargo":{}, "reserved_quantity":0, "delivery_quantity":0, "status":"IN_TRANSIT", "created_at_ms":float(world.get("elapsed_ms", 0.0))}


static func _send_consumer(job: Dictionary, target_id: String, quantity: int, from: Vector2, world: Dictionary, rules: Dictionary) -> void:
	job["target_id"] = target_id
	job["destination_kind"] = "ENTITY"
	job["delivery_quantity"] = quantity
	job["phase"] = "TO_DELIVERY"
	_fly(job, from, center(world["entities"][target_id]), rules)


static func _return_home(job: Dictionary, world: Dictionary, rules: Dictionary) -> void:
	var position := _position(job)
	job["target_id"] = str(job.get("tower_id", ""))
	job["destination_kind"] = "WAREHOUSE"
	job["phase"] = "RETURNING"
	job["reserved_quantity"] = 0
	job["delivery_quantity"] = 0
	var tower: Dictionary = world.get("entities", {}).get(str(job.get("tower_id", "")), {})
	if tower.is_empty():
		job["status"] = "BLOCKED_TOWER"
		return
	_fly(job, position, center(tower), rules)


static func _fly(job: Dictionary, from: Vector2, to: Vector2, rules: Dictionary) -> void:
	var distance := from.distance_to(to)
	var duration := maxf(0.05, distance / maxf(EPSILON, float(rules.get("drone_speed_tiles_per_second", 12.0)))) * 1000.0
	job["from_position"] = {"x":from.x, "y":from.y}
	job["to_position"] = {"x":to.x, "y":to.y}
	job["path_tiles"] = ["%s,%s" % [from.x - 0.5, from.y - 0.5], "%s,%s" % [to.x - 0.5, to.y - 0.5]]
	job["distance_tiles"] = distance
	job["travel_ms"] = duration
	job["remaining_ms"] = duration
	job["status"] = "IN_TRANSIT"


static func _position(job: Dictionary) -> Vector2:
	var from: Dictionary = job.get("from_position", {})
	var to: Dictionary = job.get("to_position", from)
	var progress := clampf(1.0 - float(job.get("remaining_ms", 0.0)) / maxf(EPSILON, float(job.get("travel_ms", 0.0))), 0.0, 1.0)
	return Vector2(float(from.get("x", 0)), float(from.get("y", 0))).lerp(Vector2(float(to.get("x", 0)), float(to.get("y", 0))), progress)


static func _legacy_position(path: Array, progress: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	var offset := clampf(progress, 0.0, 1.0) * maxi(0, path.size() - 1)
	var index := mini(int(floorf(offset)), path.size() - 1)
	var left := str(path[index]).split(",")
	var right := str(path[mini(index + 1, path.size() - 1)]).split(",")
	if left.size() != 2 or right.size() != 2:
		return Vector2.ZERO
	return Vector2(float(left[0]), float(left[1])).lerp(Vector2(float(right[0]), float(right[1])), offset - floorf(offset)) + Vector2.ONE * 0.5


static func _tower_ids(world: Dictionary, definitions: Dictionary) -> Array:
	var result: Array = []
	for id in world.get("entities", {}):
		var entity: Dictionary = world["entities"][id]
		if _live(entity) and _is_tower(entity, definitions):
			result.append(str(id))
	result.sort()
	return result


static func _is_tower(entity: Dictionary, definitions: Dictionary) -> bool:
	var definition: Dictionary = definitions.get(str(entity.get("definition_id", "")), {})
	return bool(definition.get("drone_tower", entity.get("drone_tower", str(entity.get("definition_id", "")) in ["grid_planetary_core", "grid_drone_tower"])))


static func _live(entity: Dictionary) -> bool:
	return not entity.is_empty() and str(entity.get("status", "")) != "UNDER_CONSTRUCTION"


static func _covered(tower: Dictionary, entity: Dictionary, definitions: Dictionary, rules: Dictionary) -> bool:
	return _live(tower) and _live(entity) and center(tower).distance_to(center(entity)) <= tower_radius(tower, definitions, rules) + EPSILON


static func _tower_count(entity: Dictionary, definitions: Dictionary, rules: Dictionary) -> int:
	var definition: Dictionary = definitions.get(str(entity.get("definition_id", "")), {})
	return maxi(0, int(definition.get("drone_count", entity.get("drone_count", rules.get("drone_count", rules.get("drone_drones_per_tower", 4))))))


static func _has_slot(world: Dictionary, tower_id: String, definitions: Dictionary, rules: Dictionary) -> bool:
	if world.get("drone_shipments", {}).size() >= maxi(1, int(rules.get("drone_max_active_shipments", 256))):
		return false
	var used := 0
	for job in world.get("drone_shipments", {}).values():
		if str(job.get("tower_id", "")) == tower_id:
			used += 1
	return used < _tower_count(world["entities"][tower_id], definitions, rules)


static func _nearest_tower(world: Dictionary, position: Vector2, definitions: Dictionary) -> String:
	var result := ""
	var distance := INF
	for id in _tower_ids(world, definitions):
		var candidate := position.distance_squared_to(center(world["entities"][id]))
		if candidate < distance:
			result = id
			distance = candidate
	return result


static func _fair_ids(world: Dictionary, cursor: String) -> Array:
	var ids: Array = world.get("entities", {}).keys()
	ids.sort()
	var pivot := ids.find(cursor) + 1
	return ids.slice(pivot) + ids.slice(0, pivot) if pivot > 0 and pivot < ids.size() else ids


static func _available(context: Dictionary, item: String) -> int:
	return mini(maxi(0, int(context.get("inventory", {}).get(item, 0))), maxi(0, int(context.get("available", {}).get(item, 0))))


static func _withdraw(context: Dictionary, item: String, amount: int) -> void:
	context["inventory"][item] = int(context["inventory"].get(item, 0)) - amount
	context["available"][item] = int(context["available"].get(item, 0)) - amount
	if not context.has("free_capacity"):
		context["free_capacity"] = {}
	context["free_capacity"][item] = int(context["free_capacity"].get(item, 0)) + amount


static func _deposit(context: Dictionary, item: String, amount: int) -> void:
	context["inventory"][item] = int(context["inventory"].get(item, 0)) + amount
	if not context.has("available"):
		context["available"] = {}
	context["available"][item] = int(context["available"].get(item, 0)) + amount
	context["free_capacity"][item] = int(context["free_capacity"].get(item, 0)) - amount


static func _quantity(job: Dictionary) -> int:
	return maxi(0, int(job.get("cargo", {}).get(str(job.get("item_id", "")), 0)))


static func _set_quantity(job: Dictionary, quantity: int) -> void:
	job["cargo"] = {str(job.get("item_id", "")):quantity} if quantity > 0 else {}


static func _cargo_limit(rules: Dictionary) -> int:
	return maxi(1, int(rules.get("drone_cargo_capacity", 10)))


static func _total(value: Dictionary) -> int:
	var total := 0
	for amount in value.values():
		total += maxi(0, int(amount))
	return total
