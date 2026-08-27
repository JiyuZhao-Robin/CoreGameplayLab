extends SceneTree

const HOUR_MS := 60.0 * 60.0 * 1000.0

var failures: Array[String] = []
var database: ContentDatabase


func _initialize() -> void:
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "core content loads")
	if not failures.is_empty():
		_finish()
		return
	_test_schema_34_to_35_fixture()
	_test_one_hour_batch_equivalence()
	_test_full_storage_blocks_and_recovers_delivery()
	_test_operations_maintenance_and_construction()
	_test_offline_debt_survives_cap_and_round_trip()
	_test_core_asset_conservation()
	_finish()


func _test_schema_34_to_35_fixture() -> void:
	var fixture_value = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/save_schema_34.json"))
	_check(fixture_value is Dictionary, "schema-34 fixture parses")
	if fixture_value is not Dictionary:
		return
	var fixture := fixture_value as Dictionary
	var migrated_payload := SpaceGameState.migrate_save_dictionary(fixture)
	_check(int(migrated_payload.get("save_version", 0)) == 35, "schema 34 migrates through the explicit 34-to-35 step")
	_check(migrated_payload.get("statistics", {}).get("item_consumed_totals", null) is Dictionary, "schema 34-to-35 initializes item-specific consumption accounting")
	var archive: Dictionary = migrated_payload.get("retired_megastructure_archive", {})
	_check(bool(archive.get("matter_extractor", {}).get("completed", false)), "completed retired Megastructure is archived")
	_check(int(archive.get("autonomous_industry", {}).get("project", {}).get("progress_percent", 0)) == 48, "in-progress retired Megastructure is archived with progress")
	_check(archive.has("deep_space_array") and archive.has("preexisting_legacy_record"), "retired and pre-existing archive records both survive migration")
	_check(not migrated_payload.get("megastructures", {}).has("matter_extractor") and not migrated_payload.get("megastructure_projects", {}).has("autonomous_industry"), "retired Megastructures leave the live project maps")
	var stellar: Dictionary = migrated_payload.get("megastructure_projects", {}).get("stellar_energy", {})
	_check(int(stellar.get("legacy_progress_percent", -1)) == 37 and int(stellar.get("phase_index", -1)) == 2, "legacy stellar progress maps deterministically to the eight-phase project")

	var state := SpaceGameState.from_dictionary(fixture, database.domains.keys(), database.regions)
	_check(state.item_quantity("iron_ore", "earth_orbit") == 120 and state.item_quantity("iron_ore", "lunar_space") == 7, "migration preserves per-Location inventory")
	_check(int(state.location_reserves("earth_orbit").get("iron_ore", 0)) == 11 and int(state.location_reserves("earth_orbit").get("electronics", 0)) == 4, "migration preserves player reserves")
	_check(state.logistics_network.get("shipments", []).size() == 1 and int(state.logistics_network.get("shipments", [])[0].get("cargo", {}).get("electronics", 0)) == 5, "migration preserves in-transit cargo")
	var construction: Dictionary = state.construction_operations[0]
	_check(str(construction.get("project_id", "")) == "CONSTRUCTION-000041" and int(construction.get("consumed", {}).get("iron_ingot", 0)) == 2 and int(construction.get("reserved_costs", {}).get("electronics", 0)) == 1, "migration preserves Construction progress, consumed materials and commitments")
	_check(str(state.research.get("project_id", "")) == "research_industrial_coordination" and int(state.research.get("reserved_costs", {}).get("data_core", 0)) == 1 and int(state.research.get("consumed", {}).get("electronics", 0)) == 3, "migration preserves Research stage ownership and material state")
	_check(not state.ship_by_id("SHIP-034").is_empty() and str(state.ship_by_id("SHIP-034").get("maintenance_state", "")) == "READY_RESERVE", "migration preserves physical Ship identity and lifecycle state")
	_check(state.retired_megastructure_archive == archive, "normalized state preserves the complete retired Megastructure archive")
	var ledger := state.asset_ledger_snapshot()
	_check_ledger_balance(ledger, "migrated fixture")
	_check(bool(ledger.get("ProjectStaging", {}).get("ReservationSubset", false)) and int(ledger.get("ProjectStaging", {}).get("Items", {}).get("electronics", 0)) <= int(ledger.get("Inventory", {}).get("Reserved", {}).get("electronics", 0)), "ProjectStaging is exposed as a bounded Reserved subset")
	var round_trip := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(round_trip.aggregate_inventory() == state.aggregate_inventory() and round_trip.location_reserves("earth_orbit") == state.location_reserves("earth_orbit"), "schema-35 round trip conserves migrated inventory and reserves")
	_check(round_trip.logistics_network.get("shipments", []) == state.logistics_network.get("shipments", []) and round_trip.retired_megastructure_archive == state.retired_megastructure_archive, "schema-35 round trip conserves in-transit cargo and retired projects")


func _test_one_hour_batch_equivalence() -> void:
	var setup_simulation := SimulationEngine.new(database)
	setup_simulation.set_simulation_profile("NORMAL_PROFILE")
	var seed := _integrated_seed_state(setup_simulation)
	var batch := SpaceGameState.from_dictionary(seed.to_dictionary(), database.domains.keys(), database.regions)
	var sliced := SpaceGameState.from_dictionary(seed.to_dictionary(), database.domains.keys(), database.regions)
	var batch_simulation := SimulationEngine.new(database)
	var sliced_simulation := SimulationEngine.new(database)
	batch_simulation.set_simulation_profile("NORMAL_PROFILE")
	sliced_simulation.set_simulation_profile("NORMAL_PROFILE")
	var batch_report := batch_simulation.advance(batch, HOUR_MS)
	var sliced_simulated := 0.0
	for _minute in 60:
		var report := sliced_simulation.advance(sliced, 60000.0)
		sliced_simulated += float(report.get("simulated_ms", 0.0))
	_check(is_equal_approx(float(batch_report.get("simulated_ms", 0.0)), HOUR_MS) and is_equal_approx(sliced_simulated, HOUR_MS), "both one-hour simulations process the full requested interval")
	_compare_variants(batch.to_dictionary(), sliced.to_dictionary(), "simulate(60min) vs 60x1min")


func _integrated_seed_state(simulation: SimulationEngine) -> SpaceGameState:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.regions["lunar_space"] = true
	state.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	simulation.ensure_frontier_state(state)
	state.location_state("lunar_space")["survey_state"] = LocationState.SURVEYED
	state.location_state("lunar_space")["logistics"]["storage_capacities"] = {"BULK":1000, "COMPONENT":1000, "FLUID":1000, "SPECIAL":1000}
	state.location_state("lunar_space")["logistics"]["hub_throughput"] = 100
	state.location_state("lunar_space")["logistics"]["local_throughput_capacity"] = 100.0
	state.add_item("iron_ore", 2400, "earth_orbit")
	state.add_item("electronics", 300, "earth_orbit")
	state.add_item("repair_material", 300, "earth_orbit")
	var industry: Dictionary = state.industrial_operations[0]
	industry.merge({
		"activity_id":"refine_iron", "method_id":"refine_iron", "status":"RUNNING",
		"operating_state":"RUNNING", "progress_ms":0.0, "productivity_progress":0.0,
		"location_id":"earth_orbit", "facility_id":"makeshift_workshop"
	}, true)
	state.ensure_location_industry("earth_orbit", "makeshift_workshop", 1)["production_method_id"] = "refine_iron"
	_check(simulation.queue_location_capacity_upgrade(state, "earth_orbit", "LOGISTICS_HUB_UPGRADE", 125, 80), "integrated scenario queues a real Construction project")
	var project: Dictionary = state.construction_operations[0]
	for item_id_value in project.get("material_plan", {}).keys():
		var item_id := str(item_id_value)
		state.add_item(item_id, int(project.get("material_plan", {}).get(item_id, 0)) + 100, "earth_orbit")
	state.add_item("electronics", 12, "earth_orbit")
	# Direct fixture setup mirrors LogisticsEngine: cargo changes ownership without
	# becoming a production reward or a consumption sink.
	state.location_inventory("earth_orbit")["electronics"] = state.item_quantity("electronics", "earth_orbit") - 12
	state.logistics_network["shipments"] = [{
		"id":"SHIPMENT-INTEGRITY-BATCH", "origin":"earth_orbit", "destination":"lunar_space",
		"cargo":{"electronics":12}, "remaining_ms":30.0 * 60.0 * 1000.0,
		"total_ms":30.0 * 60.0 * 1000.0, "handling_time_ms":1000.0,
		"status":"IN_TRANSIT", "service_path":[], "transport_modes":[]
	}]
	return state


func _test_full_storage_blocks_and_recovers_delivery() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("NORMAL_PROFILE")
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.ships.clear()
	state.location_state("lunar_space")["logistics"]["storage_capacities"]["COMPONENT"] = 0
	state.add_item("electronics", 5, "earth_orbit")
	# The cargo is now owned by the Shipment below, not consumed.
	state.location_inventory("earth_orbit")["electronics"] = state.item_quantity("electronics", "earth_orbit") - 5
	state.logistics_network["shipments"] = [{
		"id":"SHIPMENT-STORAGE-BLOCK", "origin":"earth_orbit", "destination":"lunar_space",
		"cargo":{"electronics":5}, "remaining_ms":1.0, "total_ms":1.0,
		"handling_time_ms":0.0, "status":"IN_TRANSIT", "service_path":[], "transport_modes":[]
	}]
	var owned_before := _owned_item_quantity(state, "electronics")
	simulation.advance(state, 1.0)
	_check(state.logistics_network.get("shipments", []).size() == 1 and str(state.logistics_network.get("shipments", [])[0].get("status", "")) == "BLOCKED_OUTPUT", "full destination storage blocks physical Shipment arrival")
	_check(_owned_item_quantity(state, "electronics") == owned_before and state.item_quantity("electronics", "lunar_space") == 0, "blocked output retains cargo ownership in transit")
	state.location_state("lunar_space")["logistics"]["storage_capacities"]["COMPONENT"] = 100
	simulation.advance(state, 5000.0)
	_check(state.logistics_network.get("shipments", []).is_empty() and state.item_quantity("electronics", "lunar_space") == 5, "freeing destination storage resumes and completes delivery")
	_check(_owned_item_quantity(state, "electronics") == owned_before, "storage block and recovery conserve cargo")


func _test_operations_maintenance_and_construction() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("NORMAL_PROFILE")
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.add_item("repair_material", 100, "earth_orbit")
	state.add_item("electronics", 100, "earth_orbit")
	_check(simulation.queue_location_capacity_upgrade(state, "earth_orbit", "LOGISTICS_HUB_UPGRADE", 125, 90), "O&M scenario queues a normal material-backed Construction project")
	var project: Dictionary = state.construction_operations[0]
	var project_id := str(project.get("project_id", ""))
	for item_id_value in project.get("material_plan", {}).keys():
		var item_id := str(item_id_value)
		state.add_item(item_id, int(project.get("material_plan", {}).get(item_id, 0)) + 20, "earth_orbit")
	var maintenance_before := state.item_quantity("repair_material", "earth_orbit") + state.item_quantity("electronics", "earth_orbit")
	simulation.advance(state, 6.0 * HOUR_MS)
	var maintenance_after := state.item_quantity("repair_material", "earth_orbit") + state.item_quantity("electronics", "earth_orbit")
	_check(maintenance_after < maintenance_before and int(state.statistics.get("item_consumed_totals", {}).get("repair_material", 0)) > 0, "elapsed operation consumes and records real O&M products")
	_check(state.demand_registry.get("sources", {}).values().any(func(row): return str((row as Dictionary).get("demand_kind", "")) == "CONTINUOUS"), "O&M remains visible as continuous Demand Registry sources")
	_check(state.construction_history.any(func(row): return str((row as Dictionary).get("project_id", "")) == project_id), "Construction completes through normal simulation and enters persistent history")
	_check(int(state.location_state("earth_orbit").get("logistics", {}).get("hub_throughput", 0)) >= 125, "completed Construction applies the requested physical Location capacity")


func _test_offline_debt_survives_cap_and_round_trip() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("NORMAL_PROFILE")
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.add_item("repair_material", 1000, "earth_orbit")
	var requested := 30.0 * HOUR_MS
	var first := simulation.advance(state, requested)
	var expected_debt := 6.0 * HOUR_MS
	_check(is_equal_approx(float(first.get("simulated_ms", 0.0)), 24.0 * HOUR_MS) and is_equal_approx(float(first.get("unprocessed_ms", 0.0)), expected_debt), "a request beyond 24 hours reports the complete capped remainder")
	state.offline_time_debt_ms = float(first.get("unprocessed_ms", 0.0))
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(is_equal_approx(restored.offline_time_debt_ms, expected_debt), "offline time debt survives save/load")
	var carried := restored.offline_time_debt_ms
	restored.offline_time_debt_ms = 0.0
	var second := simulation.advance(restored, carried)
	restored.offline_time_debt_ms = float(second.get("unprocessed_ms", 0.0))
	_check(is_equal_approx(restored.total_elapsed_ms, requested) and is_zero_approx(restored.offline_time_debt_ms), "the next pass processes every deferred millisecond without loss")


func _test_core_asset_conservation() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("NORMAL_PROFILE")
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	state.ships.clear()
	state.regions["lunar_space"] = true
	state.region_states["lunar_space"].merge({"discovered":true, "exploration_state":"SURVEYED"}, true)
	simulation.ensure_frontier_state(state)
	state.location_state("lunar_space")["survey_state"] = LocationState.SURVEYED
	state.location_state("lunar_space")["logistics"]["storage_capacities"] = {"BULK":1000, "COMPONENT":1000, "FLUID":1000, "SPECIAL":1000}
	state.location_state("lunar_space")["logistics"]["hub_throughput"] = 100
	state.location_state("lunar_space")["logistics"]["local_throughput_capacity"] = 100.0
	state.add_item("electronics", 30, "earth_orbit")
	state.add_item("chemical_propellant", 20, "earth_orbit")
	state.add_item("repair_material", 20, "earth_orbit")
	state.set_item_reserve("electronics", 4, "earth_orbit")
	state.research.merge({"status":"RUNNING", "location_id":"earth_orbit", "reserved_costs":{"electronics":2}}, true)
	state.construction_operations[0].merge({"project_id":"CONSTRUCTION-LEDGER-A", "status":"RUNNING", "location_id":"earth_orbit", "reserved_costs":{"electronics":3}}, true)
	state.construction_operations[1].merge({"project_id":"CONSTRUCTION-LEDGER-B", "status":"QUEUED", "location_id":"earth_orbit", "reserved_costs":{"electronics":5}}, true)
	_check(state.item_quantity("electronics", "earth_orbit") == state.available_item_quantity("electronics", "earth_orbit") + 4 + 2 + 3 + 5, "OnHand decomposes into Available plus non-overlapping strategic, Research and parallel Construction claims")
	var reservation_ledger := state.asset_ledger_snapshot()
	_check_ledger_balance(reservation_ledger, "parallel reserve and commitment scenario")
	_check(int(reservation_ledger.get("ProjectStaging", {}).get("Items", {}).get("electronics", 0)) == 8 and int(reservation_ledger.get("Inventory", {}).get("Reserved", {}).get("electronics", 0)) == 14, "parallel ProjectStaging includes only Construction reservations, excluding strategic and Research claims")
	state.research = SpaceGameState.empty_research_program()
	state.construction_operations[0] = SpaceGameState._empty_construction_project(0)
	state.construction_operations[1] = SpaceGameState._empty_construction_project(1)
	_check(simulation.logistics.configure_policy(state, "earth_orbit", "electronics", {"mode":"SUPPLY", "reserve":4, "dispatch_threshold":1}), "source policy protects its physical reserve")
	_check(simulation.logistics.configure_policy(state, "lunar_space", "electronics", {"mode":"DEMAND", "target":10, "priority":90, "route_lock":"earth_lunar_freight"}), "destination policy registers real cargo demand")
	var owned_before := _owned_item_quantity(state, "electronics")
	var produced_before := int(state.statistics.get("items_produced", 0))
	var electronics_consumed_before := int(state.statistics.get("item_consumed_totals", {}).get("electronics", 0))
	var events: Array[Dictionary] = simulation.logistics._dispatch(state)
	_check(not events.is_empty() and state.logistics_network.get("shipments", []).size() == 1, "normal Logistics transaction creates a persistent Shipment")
	_check(_owned_item_quantity(state, "electronics") == owned_before, "dispatch moves cargo from Inventory to InTransit without duplication or loss")
	var dispatched_ledger := state.asset_ledger_snapshot()
	_check_ledger_balance(dispatched_ledger, "dispatched cargo scenario")
	_check(int(dispatched_ledger.get("InTransit", {}).get("Items", {}).get("electronics", 0)) == 10, "asset ledger exposes dispatched cargo as InTransit")
	_check(int(state.statistics.get("items_produced", 0)) == produced_before and int(state.statistics.get("item_consumed_totals", {}).get("electronics", 0)) == electronics_consumed_before, "dispatch does not classify cargo movement as production or consumption")
	_check(int(dispatched_ledger.get("Consumed", {}).get("Items", {}).get("chemical_propellant", 0)) > 0 and int(dispatched_ledger.get("Consumed", {}).get("Items", {}).get("repair_material", 0)) > 0, "normal dispatch costs are recorded as item-specific consumption")
	if state.logistics_network.get("shipments", []).is_empty():
		return
	var shipment: Dictionary = state.logistics_network.get("shipments", [])[0]
	state.location_state("earth_orbit")["logistics"]["policies"].clear()
	state.location_state("lunar_space")["logistics"]["policies"].clear()
	simulation.advance(state, float(shipment.get("remaining_ms", shipment.get("total_ms", 0.0))) + 1.0)
	_check(state.logistics_network.get("shipments", []).is_empty() and state.item_quantity("electronics", "lunar_space") == 10, "in-transit cargo reaches its explicit destination")
	_check(_owned_item_quantity(state, "electronics") == owned_before, "Inventory plus InTransit remains conserved across delivery")
	var delivered_ledger := state.asset_ledger_snapshot()
	_check_ledger_balance(delivered_ledger, "delivered cargo scenario")
	_check(int(delivered_ledger.get("InTransit", {}).get("Items", {}).get("electronics", 0)) == 0 and int(state.statistics.get("items_produced", 0)) == produced_before and int(delivered_ledger.get("Consumed", {}).get("Items", {}).get("electronics", 0)) == electronics_consumed_before, "arrival changes ownership without production, consumption or duplication")
	state.construction_history.append({"project_id":"CONSTRUCTION-LOST-ASSET", "status":"CANCELLED", "cancellation_result":{"consumed_lost":{"electronics":2}}})
	_check(int(state.asset_ledger_snapshot().get("Lost", {}).get("Items", {}).get("electronics", 0)) == 2, "asset ledger exposes explicit cancellation loss separately from live ownership")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(_owned_item_quantity(restored, "electronics") == owned_before, "asset ownership remains conserved across a save round trip")


func _owned_item_quantity(state: SpaceGameState, item_id: String) -> int:
	var total := state.aggregate_item_quantity(item_id)
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		total += int(shipment.get("cargo", {}).get(item_id, 0))
	for runtime_value in state.fleet_logistics.values():
		var runtime := runtime_value as Dictionary
		total += int(runtime.get("supplies", {}).get(item_id, 0))
		total += int(runtime.get("recovered", {}).get(item_id, 0))
	return total


func _check_ledger_balance(ledger: Dictionary, context: String) -> void:
	var inventory: Dictionary = ledger.get("Inventory", {})
	var on_hand: Dictionary = inventory.get("OnHand", {})
	var available: Dictionary = inventory.get("Available", {})
	var reserved: Dictionary = inventory.get("Reserved", {})
	for item_id_value in on_hand.keys():
		var item_id := str(item_id_value)
		_check(int(on_hand.get(item_id, 0)) == int(available.get(item_id, 0)) + int(reserved.get(item_id, 0)), "%s ledger balances OnHand = Available + Reserved for %s" % [context, item_id])
	var staging: Dictionary = ledger.get("ProjectStaging", {}).get("Items", {})
	for item_id_value in staging.keys():
		var item_id := str(item_id_value)
		_check(int(staging.get(item_id, 0)) <= int(reserved.get(item_id, 0)), "%s ProjectStaging remains a Reserved subset for %s" % [context, item_id])


func _compare_variants(left, right, path: String) -> void:
	if typeof(left) != typeof(right):
		_fail("%s type differs: %s != %s" % [path, type_string(typeof(left)), type_string(typeof(right))])
		return
	match typeof(left):
		TYPE_DICTIONARY:
			var left_dictionary := left as Dictionary
			var right_dictionary := right as Dictionary
			if left_dictionary.size() != right_dictionary.size():
				_fail("%s dictionary size differs: %d != %d" % [path, left_dictionary.size(), right_dictionary.size()])
			for key in left_dictionary.keys():
				if not right_dictionary.has(key):
					_fail("%s missing key %s" % [path, str(key)])
					continue
				_compare_variants(left_dictionary[key], right_dictionary[key], "%s.%s" % [path, str(key)])
		TYPE_ARRAY:
			var left_array := left as Array
			var right_array := right as Array
			if left_array.size() != right_array.size():
				_fail("%s array size differs: %d != %d" % [path, left_array.size(), right_array.size()])
			for index in mini(left_array.size(), right_array.size()):
				_compare_variants(left_array[index], right_array[index], "%s[%d]" % [path, index])
		TYPE_FLOAT:
			var left_float := float(left)
			var right_float := float(right)
			var tolerance := 0.0001 * maxf(1.0, maxf(absf(left_float), absf(right_float)))
			if absf(left_float - right_float) > tolerance:
				_fail("%s float differs: %.9f != %.9f" % [path, left_float, right_float])
		_:
			if left != right:
				_fail("%s differs: %s != %s" % [path, str(left), str(right)])


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	if not failures.has(message):
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: schema migration, offline consistency and core asset integrity")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
