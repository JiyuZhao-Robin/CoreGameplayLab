extends SceneTree

## Focused road-custody probes for DSPONLINE-style Factory special buildings.
## They use the transport boundary directly: no Game/UI/save fixture is needed.

const Transport = preload("res://src/core/factory_road_transport.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_test_fuel_generator_selects_one_reachable_fuel()
	_test_power_recipe_building_receives_energy_cells()
	_test_recipe_capable_power_output_reaches_shared_inventory()
	_test_proliferator_requires_and_uses_derived_road_service()
	_finish()


func _test_fuel_generator_selects_one_reachable_fuel() -> void:
	var definitions := _definitions()
	definitions["fuel_generator"] = {
		"id":"fuel_generator", "kind":"POWER", "footprint":{"width":1, "height":1}, "input_capacity":4, "output_capacity":0,
		"runtime_metadata":{"power_mode":"FUEL_GENERATOR", "fuel_item_ids":["dsp_coal", "dsp_hydrogen"]}
	}
	var world := _world({
		"warehouse":_entity("warehouse", "STORAGE", "storage", 0),
		"generator":_entity("generator", "POWER", "fuel_generator", 4, {"fuel_item_id":"dsp_coal"})
	}, 0, 4)
	var context := _context({"dsp_hydrogen":3}, {"dsp_hydrogen":7, "dsp_coal":10})
	Transport.queue(world, definitions, {}, _rules(), context)
	_check(world["road_shipments"].size() == 1, "a fuel generator creates one road shipment for its selected fuel buffer")
	var job: Dictionary = world["road_shipments"].values()[0]
	_check(str(job.get("item_id", "")) == "dsp_hydrogen", "an unavailable selected fuel falls through to one reachable allowed fuel")
	Transport.advance(world, 10.0, definitions, {}, _rules(), context)
	_check(int(world["entities"]["generator"]["inputs"].get("dsp_hydrogen", 0)) == 1, "the finite fuel unit arrives in the generator input buffer")
	Transport.queue(world, definitions, {}, _rules(), context)
	_check(world["road_shipments"].is_empty(), "an already buffered fuel prevents mixed-fuel reservations")


func _test_power_recipe_building_receives_energy_cells() -> void:
	var definitions := _definitions()
	definitions["exchanger"] = {
		"id":"exchanger", "kind":"POWER", "footprint":{"width":1, "height":1}, "input_capacity":2, "output_capacity":2,
		"recipe_ids":["dsp_charge"], "runtime_metadata":{"power_mode":"ENERGY_EXCHANGER"}
	}
	var recipes := {
		"dsp_charge":{"id":"dsp_charge", "inputs":[{"item":"dsp_accumulator", "quantity":1}], "outputs":[{"item":"dsp_charged_accumulator", "quantity":1}]}
	}
	var world := _world({
		"warehouse":_entity("warehouse", "STORAGE", "storage", 0),
		"exchanger":_entity("exchanger", "POWER", "exchanger", 4, {"recipe_id":"dsp_charge"})
	}, 0, 4)
	var context := _context({"dsp_accumulator":1}, {"dsp_accumulator":9})
	Transport.queue(world, definitions, recipes, _rules(), context)
	_check(world["road_shipments"].size() == 1, "a recipe-capable POWER building is no longer blocked by the legacy MACHINE guard")
	Transport.advance(world, 10.0, definitions, recipes, _rules(), context)
	_check(int(world["entities"]["exchanger"]["inputs"].get("dsp_accumulator", 0)) == 1, "road delivery supplies the exchanger's actual empty-cell recipe input")


func _test_recipe_capable_power_output_reaches_shared_inventory() -> void:
	var definitions := _definitions()
	definitions["launcher"] = {
		"id":"launcher", "kind":"POWER", "footprint":{"width":1, "height":1}, "input_capacity":2, "output_capacity":2,
		"recipe_ids":["launch"], "runtime_metadata":{"power_mode":"LAUNCHER"}
	}
	var world := _world({
		"launcher":_entity("launcher", "POWER", "launcher", 0, {"outputs":{"dsp_solar_sail":1}}),
		"warehouse":_entity("warehouse", "STORAGE", "storage", 4)
	}, 0, 4)
	var context := _context({}, {"dsp_solar_sail":1})
	Transport.queue(world, definitions, {}, _rules(), context)
	_check(world["road_shipments"].size() == 1 and int(world["entities"]["launcher"]["outputs"].get("dsp_solar_sail", 0)) == 0, "an actual output from a non-MACHINE special building transfers into courier custody")
	Transport.advance(world, 10.0, definitions, {}, _rules(), context)
	_check(int(context["inventory"].get("dsp_solar_sail", 0)) == 1 and world["road_shipments"].is_empty(), "special-building output reaches the shared Location inventory exactly once")


func _test_proliferator_requires_and_uses_derived_road_service() -> void:
	var definitions := _definitions()
	definitions["assembler"] = {
		"id":"assembler", "kind":"MACHINE", "footprint":{"width":1, "height":1}, "input_capacity":4, "output_capacity":4,
		"recipe_ids":["smelt"]
	}
	definitions["coater"] = {
		"id":"coater", "kind":"MACHINE", "footprint":{"width":1, "height":1}, "input_capacity":1, "output_capacity":0,
		"runtime_metadata":{"special_effect_id":"PROLIFERATOR_SERVICE"}
	}
	var recipes := {"smelt":{"id":"smelt", "inputs":[{"item":"ore", "quantity":1}], "outputs":[{"item":"ingot", "quantity":1}]}}
	var world := _world({
		"warehouse":_entity("warehouse", "STORAGE", "storage", 0),
		"coater":_entity("coater", "MACHINE", "coater", 3),
		"machine":_entity("machine", "MACHINE", "assembler", 6, {"recipe_id":"smelt", "proliferator":{"mode":"EXTRA", "item_id":"dsp_proliferator_mk1", "spray_points_per_item":12, "point_cost":1}})
	}, 0, 6)
	var context := _context({"dsp_proliferator_mk1":1}, {"dsp_proliferator_mk1":9})
	Transport.queue(world, definitions, recipes, _rules(), context)
	_check(world["road_shipments"].is_empty(), "proliferator cannot bypass a missing derived spray service")
	world["spray_services"] = {"machine":{"coater_id":"coater", "enabled":true, "item_id":"dsp_proliferator_mk1"}}
	Transport.queue(world, definitions, recipes, _rules(), context)
	_check(world["road_shipments"].size() == 1, "a live coater reference on the same road network enables one finite spray shipment")
	Transport.advance(world, 10.0, definitions, recipes, _rules(), context)
	_check(int(world["entities"]["machine"]["inputs"].get("dsp_proliferator_mk1", 0)) == 1, "the serviced machine receives its proliferator as ordinary road cargo")


func _definitions() -> Dictionary:
	return {"storage":{"id":"storage", "kind":"STORAGE", "footprint":{"width":1, "height":1}, "loading_bays":2}}


func _world(entities: Dictionary, first_x: int, last_x: int) -> Dictionary:
	var roads := {}
	for x in range(first_x, last_x + 1):
		roads["%d,1" % x] = {"x":x, "y":1, "tier":1}
	return {
		"world_id":"dsp-road-transport", "location_id":"earth", "logistics_mode":"PLANET_SHARED_ROADS",
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":12, "y":4}}, "entities":entities,
		"roads":roads, "road_shipments":{}, "next_road_shipment_serial":1, "topology_revision":1
	}


func _entity(id: String, kind: String, definition_id: String, x: int, overrides: Dictionary = {}) -> Dictionary:
	var entity := {
		"id":id, "kind":kind, "definition_id":definition_id,
		"footprint":{"origin":{"x":x, "y":0}, "size":{"x":1, "y":1}},
		"status":"IDLE", "inputs":{}, "outputs":{}
	}
	for key in overrides:
		entity[key] = overrides[key]
	return entity


func _context(inventory: Dictionary, free_capacity: Dictionary) -> Dictionary:
	return {"inventory":inventory.duplicate(true), "available":inventory.duplicate(true), "free_capacity":free_capacity.duplicate(true)}


func _rules() -> Dictionary:
	return {
		"road_couriers_per_building":1, "road_max_active_shipments":16, "road_courier_cargo_capacity":1,
		"road_loading_seconds":0.1, "road_min_travel_seconds":0.05, "road_tier1_speed_tiles_per_second":4.0,
		"road_max_service_distance_tiles":32, "road_fuel_buffer_items":1, "road_spray_buffer_items":1
	}


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_DSP_ROAD_TRANSPORT_PASS")
		quit(0)
		return
	printerr("FACTORY_DSP_ROAD_TRANSPORT_FAIL: %s" % "; ".join(failures))
	quit(1)
