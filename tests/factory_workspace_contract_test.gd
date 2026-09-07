extends SceneTree

var failures: Array[String] = []
var database: ContentDatabase
var factory: FactoryGridSimulation


func _initialize() -> void:
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "factory workspace contract loads content: %s" % str(database.errors))
	if not failures.is_empty():
		_finish()
		return
	factory = FactoryGridSimulation.new(database.factory_buildings, database.factory_recipes, database.factory_grid_rules)
	_test_stable_presentation_snapshot()
	_test_versioned_application_intents()
	_finish()


func _test_stable_presentation_snapshot() -> void:
	var world := factory.create_world("snapshot-grid", "earth_orbit", Vector2i(256, 256), 77)
	factory.add_resource_field(world, "z-field", "iron_ore", Vector2i(32, 32), Vector2i(12, 12), 1.25, 0.5, "solid")
	factory.add_resource_field(world, "a-field", "iron_ore", Vector2i(64, 32), Vector2i(12, 12), 1.0, 0.25, "solid")
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "z-power")
	factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "a-mine")
	var connected := factory.connect_entities(world, "POWER", "z-power", "a-mine")
	_check(bool(connected.get("ok", false)), "snapshot fixture creates an explicit power edge")
	var duplicate_power := factory.connect_entities(world, "power", "z-power", "a-mine", "iron_ore")
	_check(not bool(duplicate_power.get("ok", true)) and str(duplicate_power.get("reason_code", "")) == "DUPLICATE_LINK" and world.get("links", {}).size() == 1, "power links canonicalize kind and discard stale item channels before duplicate detection")
	factory.advance_world(world, 1000.0)
	var snapshot := factory.workspace_snapshot(world)
	_check(int(snapshot.get("protocol_version", 0)) == 1 and int(snapshot.get("world_schema_version", 0)) == 3, "workspace publishes explicit protocol and world-schema versions")
	var fields: Array = snapshot.get("resource_fields", [])
	var entities: Array = snapshot.get("entities", [])
	_check(fields.size() == 2 and str((fields[0] as Dictionary).get("id", "")) == "a-field" and str((fields[1] as Dictionary).get("id", "")) == "z-field", "resource-field projections are stable identifier-sorted arrays")
	_check(not bool((fields[0] as Dictionary).get("is_entity", true)) and (fields[0] as Dictionary).get("ports", {}).get("outputs", []).is_empty(), "resource fields cannot masquerade as connectable factory entities")
	_check(entities.size() == 2 and str((entities[0] as Dictionary).get("id", "")) == "a-mine" and str((entities[1] as Dictionary).get("id", "")) == "z-power", "entity projections are stable identifier-sorted arrays")
	_check((entities[0] as Dictionary).get("ports", {}).get("outputs", []).has("iron_ore"), "extractor projection exposes its actual physical output port")
	_check(not (entities[0] as Dictionary).has("routing_cursor") and not snapshot.has("tile_deltas"), "workspace snapshot hides mutable engine bookkeeping")
	_check(int(snapshot.get("topology_revision", 0)) == 5 and int(snapshot.get("runtime_revision", 0)) == 1, "topology and runtime revisions advance independently")
	var first_building_id := str((snapshot.get("palette", {}).get("buildings", [])[0] as Dictionary).get("id", ""))
	_check(first_building_id == "grid_arc_smelter", "construction palette is deterministic and definition-backed")


func _test_versioned_application_intents() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var world := factory.create_world("intent-grid", "earth_orbit", Vector2i(256, 256), 88)
	factory.add_resource_field(world, "iron-field", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid")
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power")
	factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "mine")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(64, 0), "", "empty-depot")
	var empty_order := factory.queue_construction(world, "grid_bulk_depot", Vector2i(96, 0))
	_check(bool(empty_order.get("ok", false)), "application fixture queues a construction order that its empty depot cannot fund")
	game.state.factory_worlds["intent-grid"] = world
	var before: Dictionary = game.factory_workspace_snapshot("intent-grid")
	_check(bool(before.get("valid", false)) and int(before.get("protocol_version", 0)) == 1, "Game exposes the versioned read-only factory snapshot")
	var connect_intent := {
		"protocol_version":1,
		"command_id":"contract-connect-1",
		"kind":"CONNECT_ENTITIES",
		"world_id":"intent-grid",
		"base_topology_revision":int(before.get("topology_revision", -1)),
		"base_runtime_revision":int(before.get("runtime_revision", -1)),
		"payload":{"link_kind":"POWER", "source_id":"power", "target_id":"mine", "item_id":"iron_ore", "ignored_untrusted_field":{"nested":true}}
	}
	var connected: Dictionary = game.execute_factory_command(connect_intent)
	_check(bool(connected.get("accepted", false)) and str(connected.get("reason_code", "x")).is_empty(), "versioned intent creates a link through the application transaction boundary")
	_check(not (connected.get("request", {}).get("payload", {}) as Dictionary).has("ignored_untrusted_field"), "durable command receipts retain only canonical JSON-safe payload fields")
	_check(str(connected.get("request", {}).get("payload", {}).get("item_id", "invalid")) == "" and str((connected.get("events", [])[0] as Dictionary).get("item_id", "invalid")) == "", "POWER receipts and events expose the canonical item-free link contract")
	_check(int(connected.get("topology_revision", 0)) == int(before.get("topology_revision", 0)) + 1 and connected.get("events", []).size() == 1, "accepted command returns the committed revision and one correlated domain event")
	var event: Dictionary = connected.get("events", [])[0]
	_check(str(event.get("command_id", "")) == "contract-connect-1" and int(event.get("protocol_version", 0)) == 1 and str(event.get("type", "")) == "FactoryEntitiesConnected", "factory event envelope preserves command correlation and protocol version")
	var replayed: Dictionary = game.execute_factory_command(connect_intent)
	_check(bool(replayed.get("accepted", false)) and bool(replayed.get("replayed", false)), "an exact command-id retry returns its durable receipt without repeating mutation")
	var serialized_state = JSON.parse_string(JSON.stringify(game.state.to_dictionary()))
	game.state = SpaceGameState.from_dictionary(serialized_state as Dictionary, database.domains.keys(), database.regions)
	var replayed_after_reload: Dictionary = game.execute_factory_command(connect_intent)
	_check(bool(replayed_after_reload.get("accepted", false)) and bool(replayed_after_reload.get("replayed", false)) and game.state.factory_worlds["intent-grid"].get("links", {}).size() == 1, "a persisted command receipt still makes the exact retry idempotent after save/load")
	var conflicting_replay := connect_intent.duplicate(true)
	conflicting_replay["payload"] = (connect_intent.get("payload", {}) as Dictionary).duplicate(true)
	conflicting_replay["payload"]["target_id"] = "power"
	var conflict: Dictionary = game.execute_factory_command(conflicting_replay)
	_check(not bool(conflict.get("accepted", true)) and str(conflict.get("reason_code", "")) == "COMMAND_ID_CONFLICT", "a reused command id with a different payload is rejected instead of replaying an unrelated receipt")
	var duplicate_intent := connect_intent.duplicate(true)
	duplicate_intent["command_id"] = "contract-connect-duplicate"
	duplicate_intent["base_topology_revision"] = int(game.state.factory_worlds["intent-grid"].get("topology_revision", -1))
	var duplicate: Dictionary = game.execute_factory_command(duplicate_intent)
	_check(not bool(duplicate.get("accepted", true)) and str(duplicate.get("reason_code", "")) == "DUPLICATE_LINK", "a POWER retry with a stale cargo item cannot bypass duplicate-edge rejection")
	var stale_intent := connect_intent.duplicate(true)
	stale_intent["command_id"] = "contract-connect-stale"
	var stale: Dictionary = game.execute_factory_command(stale_intent)
	_check(not bool(stale.get("accepted", true)) and str(stale.get("reason_code", "")) == "STALE_TOPOLOGY", "a new stale layout intent is rejected before mutation")
	var invalid_payload: Dictionary = game.execute_factory_command({"protocol_version":1, "command_id":"bad-origin", "kind":"QUEUE_CONSTRUCTION", "world_id":"intent-grid", "base_topology_revision":int(game.state.factory_worlds["intent-grid"].get("topology_revision", -1)), "payload":{"definition_id":"grid_surface_mine", "origin":"32,32"}})
	_check(not bool(invalid_payload.get("accepted", true)) and str(invalid_payload.get("reason_code", "")) == "INVALID_PAYLOAD", "malformed nested payloads fail closed before reaching FactoryGridSimulation")
	_check(game.state.factory_worlds["intent-grid"].get("links", {}).size() == 1, "replay and stale rejection leave authoritative topology unchanged")
	var runtime_before_empty_funding := int(game.state.factory_worlds["intent-grid"].get("runtime_revision", -1))
	var empty_funding: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-empty-funding",
		"kind":"FUND_CONSTRUCTION",
		"world_id":"intent-grid",
		"base_topology_revision":int(game.state.factory_worlds["intent-grid"].get("topology_revision", -1)),
		"payload":{"order_id":str(empty_order.get("order_id", "")), "storage_id":"empty-depot"}
	})
	_check(not bool(empty_funding.get("accepted", true)) and str(empty_funding.get("reason_code", "")) == "NO_MATERIALS_MOVED" and empty_funding.get("events", []).is_empty(), "an empty construction delivery is rejected instead of publishing a false success event")
	_check(int(game.state.factory_worlds["intent-grid"].get("runtime_revision", -1)) == runtime_before_empty_funding, "rejected empty funding does not commit a Factory runtime mutation")
	var refreshed: Dictionary = game.factory_workspace_snapshot("intent-grid")
	var link_id := str((refreshed.get("links", [])[0] as Dictionary).get("id", ""))
	var remove_intent := {
		"protocol_version":1,
		"command_id":"contract-remove-1",
		"kind":"REMOVE_LINK",
		"world_id":"intent-grid",
		"base_topology_revision":int(refreshed.get("topology_revision", -1)),
		"payload":{"link_id":link_id}
	}
	var removed: Dictionary = game.execute_factory_command(remove_intent)
	_check(bool(removed.get("accepted", false)) and game.state.factory_worlds["intent-grid"].get("links", {}).is_empty(), "remove-link intent commits through the same transaction boundary")
	var unsupported: Dictionary = game.execute_factory_command({"protocol_version":99, "command_id":"bad-version", "kind":"REMOVE_LINK", "world_id":"intent-grid", "base_topology_revision":0, "payload":{}})
	_check(not bool(unsupported.get("accepted", true)) and str(unsupported.get("reason_code", "")) == "UNSUPPORTED_PROTOCOL", "unsupported workspace protocols fail closed")


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: versioned Factory workspace snapshot, commands and events")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
