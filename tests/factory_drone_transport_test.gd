extends SceneTree

const Transport = preload("res://src/core/factory_drone_transport.gd")
var failures: Array[String] = []
var definitions := {
	"tower":{"drone_tower":true, "drone_count":4, "drone_radius_tiles":64},
	"machine":{"input_capacity":30, "output_capacity":20, "recipe_ids":["circuit", "copper", "iron"]},
	"storage":{"kind":"STORAGE"}
}
var recipes := {
	"circuit":{"id":"circuit", "inputs":[{"item":"copper", "quantity":1}, {"item":"iron", "quantity":2}]},
	"copper":{"id":"copper", "inputs":[{"item":"copper", "quantity":1}]},
	"iron":{"id":"iron", "inputs":[{"item":"iron", "quantity":1}]}
}
var rules := {"drone_speed_tiles_per_second":10.0}


func _initialize() -> void:
	_test_threshold_and_pickup_time()
	_test_recipe_ratios_and_reservations()
	_test_circle_and_overlap()
	_test_partial_and_shared_supply()
	_test_normalize_and_migration()
	_test_deletion_and_capacity()
	_test_returns_and_slots()
	_test_fairness_and_chunking()
	_test_fuel_and_spray()
	if failures.is_empty():
		print("PASS factory_drone_transport_test")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_threshold_and_pickup_time() -> void:
	var world := _world()
	var context := _context()
	world["entities"]["producer"] = _entity("producer", 10, 0, "", {"copper":9})
	_check(Transport.queue(world, definitions, recipes, rules, context) == 0, "nine products do not launch a collection drone")
	world["entities"]["producer"]["outputs"]["copper"] = 10
	_check(Transport.queue(world, definitions, recipes, rules, context) == 1, "ten products launch one empty drone")
	var job: Dictionary = world["drone_shipments"].values()[0]
	_check(job["cargo"].is_empty() and int(world["entities"]["producer"]["outputs"]["copper"]) == 10, "dispatch reserves output without transferring custody")
	_check(Transport.queue(world, definitions, recipes, rules, context) == 0, "repeat queue cannot duplicate reserved output")
	world["entities"]["consumer"] = _entity("consumer", 20, 0, "copper")
	Transport.advance(world, 1.0, definitions, recipes, rules, context)
	_check(int(job["cargo"].get("copper", 0)) == 10 and job["target_id"] == "consumer", "a consumer built during outbound flight is selected at actual pickup")
	_check(int(world["entities"]["producer"]["outputs"]["copper"]) == 0, "pickup transfers exactly ten products")
	Transport.advance(world, 1.0, definitions, recipes, rules, context)
	_check(int(world["entities"]["consumer"]["inputs"].get("copper", 0)) == 10, "selected consumer receives ten copper")


func _test_recipe_ratios_and_reservations() -> void:
	var world := _world()
	var context := _context()
	world["entities"]["copper_source"] = _entity("copper_source", 10, 0, "", {"copper":20})
	world["entities"]["iron_source"] = _entity("iron_source", 0, 10, "", {"iron":20})
	world["entities"]["consumer"] = _entity("consumer", 10, 10, "circuit")
	Transport.advance(world, 10.0, definitions, recipes, rules, context)
	var inputs: Dictionary = world["entities"]["consumer"]["inputs"]
	_check(int(inputs.get("copper", 0)) == 10 and int(inputs.get("iron", 0)) == 20, "ten recipe batches mean copper 10 and iron 20 with inbound reservations")
	_check(int(context["inventory"].get("copper", 0)) == 10, "duplicate copper collection returns surplus to the shared inventory")
	_check(_total_assets(world, context, "copper") == 20 and _total_assets(world, context, "iron") == 20, "recipe routing conserves every product")


func _test_circle_and_overlap() -> void:
	var world := _world()
	var context := _context()
	var edge := _entity("edge", 64, 0, "", {"copper":10})
	var outside := _entity("outside", 46, 46, "", {"iron":10})
	world["entities"]["edge"] = edge
	world["entities"]["outside"] = outside
	_check(Transport.covering_towers(world, edge, definitions, rules) == ["tower"], "circle includes a building center on radius 64")
	_check(Transport.covering_towers(world, outside, definitions, rules).is_empty(), "square corner outside the circle is excluded")
	world["entities"]["tower2"] = _entity("tower2", 1, 0, "", {}, "tower")
	world["entities"]["tower2"]["drone_tower"] = true
	Transport.queue(world, definitions, recipes, rules, context)
	_check(world["drone_shipments"].size() == 1, "overlapping towers share pickup reservations")
	world["entities"]["old_store"] = _entity("old_store", 46, 46, "", {}, "storage")
	world["entities"]["old_store"]["kind"] = "STORAGE"
	_check(not Transport.covering_towers(world, outside, definitions, rules).has("old_store"), "ordinary storage does not implicitly launch drones")


func _test_partial_and_shared_supply() -> void:
	var world := _world()
	var context := _context()
	world["entities"]["producer"] = _entity("producer", 10, 0, "", {"copper":10})
	world["entities"]["consumer"] = _entity("consumer", 20, 0, "copper")
	world["entities"]["consumer"]["inputs"] = {"copper":7}
	Transport.advance(world, 8.0, definitions, recipes, rules, context)
	_check(int(world["entities"]["consumer"]["inputs"]["copper"]) == 10 and int(context["inventory"].get("copper", 0)) == 7, "partial deficit gets three and the same drone returns seven to tower storage")
	world["entities"]["consumer"]["inputs"]["copper"] = 4
	Transport.advance(world, 8.0, definitions, recipes, rules, context)
	_check(int(world["entities"]["consumer"]["inputs"]["copper"]) == 10 and int(context["inventory"].get("copper", 0)) == 1, "later demand draws a partial load from shared tower inventory")
	var reserved_context := _context({"iron":10})
	reserved_context["available"]["iron"] = 0
	world["entities"]["consumer"]["recipe_id"] = "iron"
	_check(Transport.queue(world, definitions, recipes, rules, reserved_context) == 0, "external inventory reservations are never withdrawn")


func _test_normalize_and_migration() -> void:
	var world := _world()
	var context := _context()
	world["entities"]["producer"] = _entity("producer", 10, 0, "", {"copper":10})
	Transport.queue(world, definitions, recipes, rules, context)
	world["drone_shipments"] = Transport.normalize_shipments(JSON.parse_string(JSON.stringify(world["drone_shipments"])), world)
	_check(world["drone_shipments"].size() == 1 and world["drone_shipments"].values()[0]["cargo"].is_empty(), "save normalization preserves empty pickup reservations")
	Transport.advance(world, 1.5, definitions, recipes, rules, context)
	world["drone_shipments"] = Transport.normalize_shipments(JSON.parse_string(JSON.stringify(world["drone_shipments"])), world)
	_check(_total_assets(world, context, "copper") == 10, "loaded flight survives JSON normalization with one cargo owner")
	Transport.advance(world, 2.0, definitions, recipes, rules, context)
	_check(int(context["inventory"].get("copper", 0)) == 10, "loaded normalized return reaches shared inventory")
	var legacy := {"road1":{"id":"road1", "item_id":"copper", "cargo":{"copper":7}, "source_id":"removed", "target_id":"removed_store", "destination_kind":"WAREHOUSE", "remaining_ms":500.0, "travel_ms":1000.0, "path_tiles":["10,0", "0,0"]}}
	world["drone_shipments"] = Transport.normalize_shipments(legacy, world)
	Transport.advance(world, 3.0, definitions, recipes, rules, context)
	_check(int(context["inventory"].get("copper", 0)) == 17, "legacy loaded road cargo migrates without a second withdrawal")
	legacy["road1"]["cargo"] = {"copper":2, "iron":3}
	world["drone_shipments"] = Transport.normalize_shipments(legacy, world)
	Transport.advance(world, 1.0, definitions, recipes, rules, context)
	_check(world["drone_shipments"]["road1"]["cargo"] == {"copper":2, "iron":3} and world["drone_shipments"]["road1"]["status"] == "BLOCKED_MANIFEST", "malformed multi-item legacy cargo is retained intact")


func _test_deletion_and_capacity() -> void:
	var world := _world()
	var context := _context()
	context["free_capacity"]["copper"] = 0
	world["entities"]["producer"] = _entity("producer", 10, 0, "", {"copper":10})
	Transport.advance(world, 2.0, definitions, recipes, rules, context)
	_check(world["drone_shipments"].size() == 1 and world["drone_shipments"].values()[0]["status"] == "BLOCKED_TARGET_FULL", "full shared inventory retains cargo at the tower")
	_check(_total_assets(world, context, "copper") == 10, "blocked deposit does not lose cargo")
	world["entities"].erase("tower")
	Transport.advance(world, 3.0, definitions, recipes, rules, context)
	_check(world["drone_shipments"].values()[0]["status"] == "BLOCKED_TOWER", "deleting the only tower leaves recoverable cargo")
	world["entities"]["replacement"] = _entity("replacement", 20, 0, "", {}, "tower")
	world["entities"]["replacement"]["drone_tower"] = true
	context["free_capacity"]["copper"] = 10
	Transport.advance(world, 4.0, definitions, recipes, rules, context)
	_check(int(context["inventory"].get("copper", 0)) == 10 and world["drone_shipments"].is_empty(), "a replacement tower recovers the original retained cargo")
	world = _world()
	context = _context()
	world["entities"]["producer"] = _entity("producer", 10, 0, "", {"copper":10})
	world["entities"]["consumer"] = _entity("consumer", 20, 0, "copper")
	Transport.advance(world, 1.0, definitions, recipes, rules, context)
	world["entities"]["consumer"]["recipe_id"] = "iron"
	Transport.advance(world, 5.0, definitions, recipes, rules, context)
	_check(int(context["inventory"].get("copper", 0)) == 10 and world["entities"]["consumer"]["inputs"].is_empty(), "recipe changes return incompatible loaded cargo to the tower")


func _test_returns_and_slots() -> void:
	var world := _world()
	var context := _context()
	var one_drone := definitions.duplicate(true)
	one_drone["tower"]["drone_count"] = 1
	world["entities"]["producer"] = _entity("producer", 10, 0, "", {"copper":20})
	world["entities"]["consumer"] = _entity("consumer", 20, 0, "copper")
	Transport.advance(world, 2.0, one_drone, recipes, rules, context)
	var rows := Transport.workspace_shipments(world, rules)
	_check(rows.size() == 1 and rows[0]["phase"] == "RETURNING" and int(rows[0]["quantity"]) == 0, "empty return flights remain visible and occupy a drone slot")
	_check(int(world["entities"]["producer"]["outputs"]["copper"]) == 10 and Transport.queue(world, one_drone, recipes, rules, context) == 0, "a delivering drone cannot launch another collection before reaching home")
	_check(int(Transport.logistics_snapshot(world, rules, {"building_definitions":one_drone})["active_shipments"]) == 1, "capacity snapshot counts empty return flights")
	world = _world()
	context = _context()
	world["entities"]["producer"] = _entity("producer", 10, 0, "", {"copper":3})
	world["entities"]["producer"]["drone_return_items"] = {"copper":3}
	Transport.advance(world, 4.0, definitions, recipes, rules, context)
	_check(int(context["inventory"].get("copper", 0)) == 3 and int(world["entities"]["producer"]["drone_return_items"]["copper"]) == 0, "explicit retool returns drain sub-batch orphan inputs")


func _test_fairness_and_chunking() -> void:
	var world := _world()
	var context := _context({"iron":10})
	world["entities"]["a"] = _entity("a", 10, 0, "", {"copper":80})
	world["entities"]["b"] = _entity("b", 0, 10, "", {"copper":80})
	world["entities"]["consumer"] = _entity("consumer", 20, 0, "iron")
	Transport.queue(world, definitions, recipes, rules, context)
	var sources := {}
	for job in world["drone_shipments"].values():
		sources[str(job["source_id"])] = true
	_check(sources.has("a") and sources.has("b") and sources.has("tower"), "fair output rotation and bounded supply priority prevent starvation")
	var split_world := world.duplicate(true)
	var split_context := context.duplicate(true)
	Transport.advance(world, 12.0, definitions, recipes, rules, context)
	for _tick in range(120):
		Transport.advance(split_world, 0.1, definitions, recipes, rules, split_context)
	_check(context["inventory"] == split_context["inventory"] and world["entities"]["consumer"]["inputs"] == split_world["entities"]["consumer"]["inputs"], "event timing gives the same completed transfers across coarse and fine steps")


func _test_fuel_and_spray() -> void:
	var special := definitions.duplicate(true)
	special["generator"] = {"input_capacity":4, "runtime_metadata":{"power_mode":"FUEL_GENERATOR", "fuel_item_ids":["dsp_coal", "dsp_hydrogen"]}}
	special["coater"] = {"input_capacity":1, "runtime_metadata":{"special_effect_id":"PROLIFERATOR_SERVICE"}}
	var world := _world()
	var context := _context({"dsp_hydrogen":3})
	world["entities"]["generator"] = _entity("generator", 10, 0, "", {}, "generator")
	world["entities"]["generator"]["kind"] = "POWER"
	world["entities"]["generator"]["fuel_item_id"] = "dsp_coal"
	Transport.advance(world, 4.0, special, recipes, rules, context)
	_check(int(world["entities"]["generator"]["inputs"].get("dsp_hydrogen", 0)) == 1, "fuel metadata permits fallback to available allowed fuel when selected coal is absent")
	context["inventory"]["dsp_coal"] = 10
	context["available"]["dsp_coal"] = 10
	Transport.advance(world, 4.0, special, recipes, rules, context)
	_check(int(world["entities"]["generator"]["inputs"].get("dsp_coal", 0)) == 0, "existing buffered fuel prevents mixing another fuel type")
	world = _world()
	context = _context({"dsp_proliferator_mk1":3})
	world["entities"]["consumer"] = _entity("consumer", 10, 0, "copper")
	world["entities"]["consumer"]["proliferator"] = {"mode":"EXTRA", "item_id":"dsp_proliferator_mk1"}
	world["entities"]["coater"] = _entity("coater", 8, 0, "", {}, "coater")
	_check(Transport.queue(world, special, recipes, rules, context) == 0, "spray cannot bypass a missing derived coater service")
	world["spray_services"] = {"consumer":{"enabled":true, "coater_id":"coater", "item_id":"dsp_proliferator_mk1"}}
	Transport.queue(world, special, recipes, rules, context)
	_check(world["drone_shipments"].size() == 1, "live derived coater service receives ordinary finite spray cargo")
	world["entities"].erase("coater")
	Transport.advance(world, 4.0, special, recipes, rules, context)
	_check(world["entities"]["consumer"]["inputs"].is_empty() and int(context["inventory"]["dsp_proliferator_mk1"]) == 3, "deleting a coater redirects in-flight spray back to tower even with a stale service record")
	world["entities"]["coater"] = _entity("coater", 8, 0, "", {}, "coater")
	Transport.advance(world, 4.0, special, recipes, rules, context)
	_check(int(world["entities"]["consumer"]["inputs"].get("dsp_proliferator_mk1", 0)) == 1, "restored derived service receives one physical spray input")


func _world() -> Dictionary:
	var tower := _entity("tower", 0, 0, "", {}, "tower")
	tower["drone_tower"] = true
	return {"entities":{"tower":tower}, "drone_shipments":{}, "next_drone_shipment_serial":1}


func _entity(id: String, x: int, y: int, recipe: String = "", outputs: Dictionary = {}, definition: String = "machine") -> Dictionary:
	return {"id":id, "definition_id":definition, "kind":"MACHINE", "recipe_id":recipe, "status":"IDLE", "footprint":{"origin":{"x":x, "y":y}, "size":{"x":1, "y":1}}, "inputs":{}, "outputs":outputs.duplicate(true)}


func _context(inventory: Dictionary = {}) -> Dictionary:
	return {"inventory":inventory.duplicate(true), "available":inventory.duplicate(true), "free_capacity":{"copper":1000, "iron":1000}}


func _total_assets(world: Dictionary, context: Dictionary, item: String) -> int:
	var total := int(context["inventory"].get(item, 0))
	for entity in world["entities"].values():
		total += int(entity.get("inputs", {}).get(item, 0)) + int(entity.get("outputs", {}).get(item, 0))
	for job in world["drone_shipments"].values():
		total += int(job.get("cargo", {}).get(item, 0))
	return total


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
