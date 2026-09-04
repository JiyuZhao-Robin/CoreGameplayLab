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
		"payload":{"link_kind":"POWER", "source_id":"power", "target_id":"mine"}
	}
	var connected: Dictionary = game.execute_factory_command(connect_intent)
	_check(bool(connected.get("accepted", false)) and str(connected.get("reason_code", "x")).is_empty(), "versioned intent creates a link through the application transaction boundary")
	_check(int(connected.get("topology_revision", 0)) == int(before.get("topology_revision", 0)) + 1 and connected.get("events", []).size() == 1, "accepted command returns the committed revision and one correlated domain event")
	var event: Dictionary = connected.get("events", [])[0]
	_check(str(event.get("command_id", "")) == "contract-connect-1" and int(event.get("protocol_version", 0)) == 1 and str(event.get("type", "")) == "FactoryEntitiesConnected", "factory event envelope preserves command correlation and protocol version")
	var replayed: Dictionary = game.execute_factory_command(connect_intent)
	_check(bool(replayed.get("accepted", false)) and bool(replayed.get("replayed", false)), "an exact command-id retry returns its durable receipt without repeating mutation")
	var stale_intent := connect_intent.duplicate(true)
	stale_intent["command_id"] = "contract-connect-stale"
	var stale: Dictionary = game.execute_factory_command(stale_intent)
	_check(not bool(stale.get("accepted", true)) and str(stale.get("reason_code", "")) == "STALE_TOPOLOGY", "a new stale layout intent is rejected before mutation")
	_check(game.state.factory_worlds["intent-grid"].get("links", {}).size() == 1, "replay and stale rejection leave authoritative topology unchanged")
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
