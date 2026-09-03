extends "res://tests/full_gameplay_ui_test.gd"

var _expected_failure_prefix := ""
var _captured_expected_failures: Array[String] = []


func _journey_fail(message: String) -> bool:
	if not _expected_failure_prefix.is_empty() and message.begins_with(_expected_failure_prefix):
		_captured_expected_failures.append(message)
		return false
	return super._journey_fail(message)

# Fast diagnostic only. This starts from a state captured by the no-cheat Golden
# Path and exercises the same visible Megastructure controls/helpers as the fresh
# journey. Its result is never written to the fresh-save evidence artifact.
func _run() -> void:
	Game.persistence_enabled = false
	var builder := GameplayScenarioBuilder.new(Game.content)
	var scenario_id := "megastructure_phase_1"
	var raw_probe_item := ""
	var bottleneck_probe := false
	var mining_start_probe := false
	var local_bootstrap_probe := false
	var local_bootstrap_failure_probe := false
	var maintenance_backlog_probe := false
	var streaming_gas_probe := false
	var running_mining_location_probe := false
	var spendable_production_probe := false
	var reserve_mission_probe := false
	var outer_titan_commission_probe := false
	var outer_titan_exotic_refit_probe := false
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--scenario="):
			scenario_id = argument.trim_prefix("--scenario=")
		elif argument.begins_with("--raw-probe="):
			raw_probe_item = argument.trim_prefix("--raw-probe=")
		elif argument == "--bottleneck-probe":
			bottleneck_probe = true
		elif argument == "--mining-start-probe":
			mining_start_probe = true
		elif argument == "--local-bootstrap-probe":
			local_bootstrap_probe = true
		elif argument == "--local-bootstrap-failure-probe":
			local_bootstrap_failure_probe = true
		elif argument == "--maintenance-backlog-probe":
			maintenance_backlog_probe = true
		elif argument == "--streaming-gas-probe":
			streaming_gas_probe = true
		elif argument == "--running-mining-location-probe":
			running_mining_location_probe = true
		elif argument == "--spendable-production-probe":
			spendable_production_probe = true
		elif argument == "--reserve-mission-probe":
			reserve_mission_probe = true
		elif argument == "--outer-titan-commission-probe":
			outer_titan_commission_probe = true
		elif argument == "--outer-titan-exotic-refit-probe":
			outer_titan_exotic_refit_probe = true
	_check(builder.activate(scenario_id), "legal Golden Scenario %s activates for UI endgame diagnostics" % scenario_id)
	var main := MainScene.instantiate() as Control
	add_child(main)
	await _settle_ui()
	if outer_titan_exotic_refit_probe:
		# open_deep is a Golden, invariant-valid checkpoint captured immediately
		# after the normal Deep System route. Exercise the same consecutive refits
		# that Fresh Save uses: removing a module must finish before the next full
		# Loadout BOM is sampled.
		var titan_id := _ship_id_for_blueprint("outer_titan")
		var initial_modules: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(titan_id))
		_check(not titan_id.is_empty() and String(Game.state.ship_by_id(titan_id).get("status", "")) == "DOCKED",
			"open_deep checkpoint owns one docked Outer Titan for the visible consecutive-refit regression")
		_check(initial_modules.has("targeting_computer") and not initial_modules.has("exotic_containment") and not _ship_has_active_refit(titan_id),
			"Outer Titan starts with Targeting Computer and no active or completed Exotic Containment refit")
		var removed := await _remove_ship_module_ui(main, titan_id, "targeting_computer")
		var modules_after_remove: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(titan_id))
		_check(removed and not modules_after_remove.has("targeting_computer") and not _ship_has_active_refit(titan_id) \
			and String(Game.state.ship_by_id(titan_id).get("status", "")) == "DOCKED",
			"visible Remove returns only after the first physical refit completes and the Titan is docked")
		var expected_final: Array = modules_after_remove.duplicate()
		expected_final.append("exotic_containment")
		var canonical_bom: Dictionary = Game.simulation.loadout_fabrication_costs(expected_final)
		_check(int(canonical_bom.get("superalloy", 0)) >= 11 and int(canonical_bom.get("quantum_component", 0)) >= 8,
			"second refit plans the restored Titan's complete canonical Loadout BOM rather than Exotic Containment alone")
		var refits_before := int(Game.state.statistics.get("refits_completed", 0))
		var installed := await _install_ship_module_ui(main, titan_id, "exotic_containment")
		var final_modules: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(titan_id))
		var expected_sorted := expected_final.duplicate()
		var final_sorted := final_modules.duplicate()
		expected_sorted.sort()
		final_sorted.sort()
		_check(installed and final_sorted == expected_sorted and not _ship_has_active_refit(titan_id),
			"visible Install completes exactly one full-BOM Exotic Containment refit without losing the restored Titan modules")
		_check(int(Game.state.statistics.get("refits_completed", 0)) == refits_before + 1 \
			and Game.simulation.capability_value_for_ships(Game.state, "exotic_containment", [titan_id]) >= 1.0,
			"completed consecutive refit increments authoritative statistics and exposes the real containment capability")
		var loaded := SpaceGameState.from_dictionary(Game.state.to_dictionary(), Game.content.domains.keys(), Game.content.regions)
		var loaded_modules: Array = loaded.ship_module_definition_ids(loaded.ship_by_id(titan_id))
		loaded_modules.sort()
		_check(loaded_modules == expected_sorted and not loaded.refit_projects.any(func(runtime_value) -> bool:
			return String((runtime_value as Dictionary).get("ship_id", "")) == titan_id),
			"completed Outer Titan Exotic Containment refit survives authoritative serialization without a ghost project")
		main.queue_free()
		await get_tree().process_frame
		if failures.is_empty():
			print("PASS: Outer Titan consecutive Exotic Containment refit diagnostic completed")
			get_tree().quit(0)
		else:
			for failure in failures:
				print(failure)
			get_tree().quit(1)
		return
	if outer_titan_commission_probe:
		# open_outer is an invariant-valid Golden checkpoint captured immediately
		# before the exotic-industry and Titan chain. Re-run that exact late-game
		# player flow through visible controls so a mid-build O&M shortage cannot be
		# hidden behind the several-hour Fresh Journey.
		var prepared := await _complete_research_program_ui(main, "research_exotic_materials") \
			and await _complete_construction_activity_ui(main, "upgrade_construction_yard_iii") \
			and await _complete_construction_activity_ui(main, "build_field_engineering_complex") \
			and await _ensure_ui_item(main, "exotic_crystal", 1) \
			and await _complete_research_program_ui(main, "research_antimatter") \
			and await _ensure_ui_item(main, "antimatter_cell", 3) \
			and await _complete_research_program_ui(main, "research_exotic_containment") \
			and await _complete_construction_activity_ui(main, "build_command_array") \
			and await _complete_construction_activity_ui(main, "upgrade_starport_iv")
		_check(prepared, "visible late-game UI prepares the invariant-valid Outer Titan construction chain")
		var titan_id := await _develop_and_build_ship_ui(main, "develop_outer_titan", "construct_outer_titan", "outer_titan") if prepared else ""
		_check(not titan_id.is_empty(), "visible Shipyard commissions Outer Titan despite concurrent O&M demand")
		main.queue_free()
		await get_tree().process_frame
		if failures.is_empty():
			print("PASS: Outer Titan commissioning recovery diagnostic completed")
			get_tree().quit(0)
		else:
			for failure in failures:
				print(failure)
			get_tree().quit(1)
		return
	if reserve_mission_probe:
		var starter_id := _ship_id_for_blueprint("patchwork_prospector")
		var pathfinder_id := _ship_id_for_blueprint("lunar_pathfinder")
		var cruiser_id := _ship_id_for_blueprint("belt_cruiser")
		var route_ship_ids: Array = [starter_id, pathfinder_id, cruiser_id]
		var reserved_before_route := await _set_idle_fleet_ready_reserve_ui(main)
		_check(reserved_before_route > 0 and route_ship_ids.all(func(ship_id): return String(Game.state.ship_by_id(String(ship_id)).get("maintenance_state", "")) == "READY_RESERVE"),
			"visible operating-stock policy can place the complete Jovian mission roster in Ready Reserve")
		_check(not Game.start_expedition_route("jovian_route", route_ship_ids),
			"authoritative Expedition transaction rejects a Ready Reserve mission roster")
		var bulk_freighter_id := _ship_id_for_blueprint("bulk_freighter")
		# The checkpoint's Bulk Freighter is still serving the Belt trunk and therefore
		# is not idle. Release it through the visible mixed-cargo control, then reserve
		# it visibly so the rejection below proves the lifecycle rule itself.
		await _open_location_from_system(main, "asteroid_belt")
		await _press_named(main, "LocationTab_logistics", "OPEN_BELT_LOGISTICS_FOR_RESERVE_SERVICE_PROBE")
		await _press_named(main, "TransportMode_lunar_belt_freight_general_cargo", "RELEASE_BULK_FREIGHTER_FOR_RESERVE_SERVICE_PROBE")
		_check(Game.state.ship_is_unassigned_docked(bulk_freighter_id),
			"visible mixed-cargo route control releases the Bulk Freighter to its dock")
		await _set_idle_fleet_ready_reserve_ui(main)
		_check(String(Game.state.ship_by_id(bulk_freighter_id).get("maintenance_state", "")) == "READY_RESERVE",
			"visible lifecycle control places the released Bulk Freighter in Ready Reserve")
		_check(not Game.configure_logistics_service("lunar_belt_freight", "bulk_tug", [bulk_freighter_id], "BULK_FIRST"),
			"authoritative Logistics transaction rejects a Ready Reserve transport hull")
		_check(await _complete_route_ui(main, "jovian_route", route_ship_ids),
			"visible Jovian route helper reactivates its requested reserve roster before launch")
		var reserved_before_survey := await _set_idle_fleet_ready_reserve_ui(main)
		_check(reserved_before_survey > 0 and String(Game.state.ship_by_id(pathfinder_id).get("maintenance_state", "")) == "READY_RESERVE",
			"returned Jovian survey vessel can enter Ready Reserve through visible lifecycle controls")
		var reserve_survey_availability := Game.survey_mission_availability("gas_giant_region", LocationState.SURVEYED, [pathfinder_id])
		_check(not bool(reserve_survey_availability.get("allowed", true)) and (reserve_survey_availability.get("blockers", []) as Array).any(func(blocker): return String((blocker as Dictionary).get("code", "")) == "SURVEY_VESSEL_UNAVAILABLE"),
			"authoritative Survey query rejects a Ready Reserve vessel with a structured availability blocker")
		var isolated_state := SpaceGameState.from_dictionary(Game.state.to_dictionary(), Game.content.domains.keys(), Game.content.regions)
		_check(not Game.simulation.start_survey_mission(isolated_state, "gas_giant_region", LocationState.SURVEYED, [pathfinder_id]),
			"authoritative Survey transaction rejects a Ready Reserve vessel")
		_check(await _survey_location_to_ui(main, "gas_giant_region", LocationState.SURVEYED, pathfinder_id),
			"visible Survey helper reactivates its preferred reserve vessel before mission start")
		main.queue_free()
		await get_tree().process_frame
		if failures.is_empty():
			print("PASS: reserve mission lifecycle diagnostic completed")
			get_tree().quit(0)
		else:
			for failure in failures:
				print(failure)
			get_tree().quit(1)
		return
	if spendable_production_probe:
		var rate_before := float(Game.simulation.maintenance_recovery_requirement(
			Game.state, SpaceGameState.MAIN_BASE_LOCATION_ID, "repair_material", 27, 8.0 * 3600000.0
		).get("continuous_rate_per_hour", 0.0))
		var reserve_count := await _set_idle_fleet_ready_reserve_ui(main)
		var rate_after := float(Game.simulation.maintenance_recovery_requirement(
			Game.state, SpaceGameState.MAIN_BASE_LOCATION_ID, "repair_material", 27, 8.0 * 3600000.0
		).get("continuous_rate_per_hour", 0.0))
		_check(reserve_count > 0, "visible Ships controls move at least one idle docked hull into Ready Reserve")
		_check(rate_after < rate_before, "Ready Reserve visibly reduces the authoritative continuous maintenance rate")
		_check(_planned_entry_gross_target(0, 0, 98, 27) == 98,
			"continuous-sink recovery preserves the authoritative 98-unit gross production budget")
		_check(_planned_entry_gross_target(40, 10, 5, 27) == 57,
			"spendable shortage can raise a smaller production entry without discarding current gross stock")
		_check(_planned_entry_gross_target(40, 30, 5, 27) == 45,
			"already-spendable stock leaves the dependency plan's physical production quantity intact")
		main.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if failures.is_empty() else 1)
		return
	if running_mining_location_probe:
		var mining_ship_id := _ship_id_for_blueprint("lunar_pathfinder")
		var reserved_count := await _set_idle_fleet_ready_reserve_ui(main)
		_check(reserved_count > 0 and String(Game.state.ship_by_id(mining_ship_id).get("maintenance_state", "")) == "READY_RESERVE",
			"visible Ships lifecycle control can place the legal Belt miner in Ready Reserve")
		_check(await _ensure_ship_active_ui(main, mining_ship_id, "RUNNING_MINING_LOCATION_PROBE"),
			"visible Ships lifecycle control reactivates the selected reserve miner before assignment")
		# Reproduce the Fresh Journey ordering hazard: operating-stock preparation can
		# reserve the just-selected idle miner. The final preparation step must be a
		# second visible reactivation immediately before Assign/Start.
		var restaged_reserve_count := await _set_idle_fleet_ready_reserve_ui(main)
		_check(restaged_reserve_count > 0 and String(Game.state.ship_by_id(mining_ship_id).get("maintenance_state", "")) == "READY_RESERVE",
			"operating-stock preparation can legitimately return the selected idle miner to Ready Reserve")
		_check(await _ensure_ship_active_ui(main, mining_ship_id, "RUNNING_MINING_AFTER_OPERATING_STOCK_PROBE"),
			"selected miner is visibly reactivated after operating-stock preparation")
		await _press_named(main, "SpeedPause", "PAUSE_FOR_RUNNING_MINING_LOCATION_PROBE")
		await _press_named(main, "Navigation_ships", "OPEN_SHIPS_FOR_RUNNING_MINING_LOCATION_PROBE")
		var roster_section := main.find_child("FleetSection_roster", true, false) as Button
		if roster_section != null and roster_section.is_visible_in_tree() and not roster_section.disabled:
			await _press_control(roster_section, "OPEN_ROSTER_FOR_RUNNING_MINING_LOCATION_PROBE")
		await _press_named(main, "AssignMining_%s" % mining_ship_id, "ASSIGN_MINER_FOR_RUNNING_MINING_LOCATION_PROBE")
		await _press_named(main, "Navigation_survey", "OPEN_SURVEY_FOR_RUNNING_MINING_LOCATION_PROBE")
		await _press_named(main, "StartMining_belt_cobalt_frontier", "START_BELT_MINING_FOR_LOCATION_PROBE")
		var belt_runtime := _mining_runtime_for_site("belt_cobalt_frontier")
		var inventory_location := _mining_runtime_inventory_location_read_only(belt_runtime)
		print("RUNNING_MINING_LOCATION_PROBE=", JSON.stringify({"runtime":belt_runtime, "inventory_location":inventory_location}))
		_check(not belt_runtime.is_empty(), "open_jovian fixture retains the real running Belt mining operation")
		_check(Game.state.has_location(inventory_location), "running-mining selection resolves its site to a strategic inventory Location")
		_check(inventory_location == "asteroid_belt", "running Belt mining resolves belt_cobalt_seam to asteroid_belt for UI Logistics")
		await _stop_mining_site_ui(main, "belt_cobalt_frontier", "mixed_raw_ore")
		_check(String(Game.state.ship_by_id(mining_ship_id).get("maintenance_state", "")) == "READY_RESERVE",
			"stopping a bootstrap mine returns the docked hull to Ready Reserve through visible Ships controls")
		_check(await _recover_mining_ship_service_ui(main, mining_ship_id, "RUNNING_MINING_RECOVERY_PROBE"),
			"normal mining-service recovery visibly reactivates a repaired Ready Reserve hull")
		main.queue_free()
		await get_tree().process_frame
		if failures.is_empty():
			print("PASS: running mining Location normalization diagnostic completed")
			get_tree().quit(0)
		else:
			for failure in failures:
				print(failure)
			get_tree().quit(1)
		return
	if not raw_probe_item.is_empty():
		# Require more than the one-unit lunar checkpoint seed so this focused
		# diagnostic necessarily exercises a physical mining cycle and freight.
		var target := Game.state.item_quantity(raw_probe_item, SpaceGameState.MAIN_BASE_LOCATION_ID) + 10
		var replenished := await _ensure_raw_resource_ui(main, raw_probe_item, target)
		_check(replenished, "scenario diagnostic replenishes %s through visible mining and logistics controls" % raw_probe_item)
		main.queue_free()
		await get_tree().process_frame
		if failures.is_empty():
			print("PASS: UI raw-resource scenario diagnostic completed")
			get_tree().quit(0)
		else:
			for failure in failures:
				print(failure)
			get_tree().quit(1)
		return
	if bottleneck_probe:
		var saturated := await _create_belt_route_pressure_ui(main)
		_check(saturated, "scenario diagnostic creates physical Belt freight pressure through visible controls")
		_check(
			String(Game.simulation.logistics.service_snapshot(Game.state, "lunar_belt_freight").get("status", "")) == "SATURATED",
			"scenario diagnostic observes SATURATED from the real logistics service"
		)
		main.queue_free()
		await get_tree().process_frame
		if failures.is_empty():
			print("PASS: UI logistics-bottleneck scenario diagnostic completed")
			get_tree().quit(0)
		else:
			for failure in failures:
				print(failure)
			get_tree().quit(1)
		return
	if mining_start_probe:
		var mining_ship_id := _ship_id_for_blueprint("lunar_pathfinder")
		var mining_activity: Dictionary = Game.content.get_mining_activity_for_site("belt_cobalt_frontier")
		var wrong_fleet_availability: Dictionary = Game.extraction_operation_availability("belt_cobalt_frontier", [mining_ship_id])
		_check(String(wrong_fleet_availability.get("reason_code", "")) == "SHIP_WRONG_FLEET", "explicit extraction query rejects a site-capable ship outside the Mining Fleet")
		await _press_named(main, "SpeedPause", "PAUSE_FOR_MINING_START_PROBE")
		await _press_named(main, "Navigation_survey", "OPEN_SURVEY_FOR_MINING_BLOCKER_PROBE")
		var blocked_start := main.find_child("StartMining_belt_cobalt_frontier", true, false) as Button
		_check(blocked_start != null and blocked_start.disabled, "Survey disables Start Mining while no Mining Fleet ship satisfies the site capability")
		var blocked_query: Dictionary = Game.extraction_operation_availability("belt_cobalt_frontier")
		_check(String(blocked_query.get("reason_code", "")) == "SHIP_REQUIREMENTS", "disabled Survey action exposes the structured site-capability blocker")
		await _press_named(main, "Navigation_ships", "OPEN_SHIPS_FOR_MINING_START_PROBE")
		var roster_section := main.find_child("FleetSection_roster", true, false) as Button
		if roster_section != null and roster_section.is_visible_in_tree() and not roster_section.disabled:
			await _press_control(roster_section, "OPEN_ROSTER_FOR_MINING_START_PROBE")
		await _press_named(main, "AssignMining_%s" % mining_ship_id, "ASSIGN_MINER_FOR_MINING_START_PROBE")
		await _press_named(main, "Navigation_survey", "OPEN_SURVEY_FOR_MINING_START_PROBE")
		var candidate_evidence: Array = []
		var unsuitable_predecessor := false
		var unsuitable_predecessor_id := ""
		for candidate_id_value in Game.state.fleet_ship_ids("mining"):
			var candidate_id := str(candidate_id_value)
			var requirements_met := Game.simulation.activity_requirements_met_for_ships(Game.state, mining_activity, [candidate_id])
			candidate_evidence.append({
				"ship_id":candidate_id,
				"docked":Game.state.ship_is_docked(candidate_id),
				"mining_power":Game.simulation.mining_power(Game.state, [candidate_id]),
				"site_requirements_met":requirements_met
			})
			if candidate_id == mining_ship_id:
				break
			if Game.state.ship_is_docked(candidate_id) and Game.simulation.mining_power(Game.state, [candidate_id]) > 0.0 and not requirements_met:
				unsuitable_predecessor = true
				unsuitable_predecessor_id = candidate_id
		var ready_availability: Dictionary = Game.extraction_operation_availability("belt_cobalt_frontier")
		var unsuitable_availability: Dictionary = Game.extraction_operation_availability("belt_cobalt_frontier", [unsuitable_predecessor_id]) if not unsuitable_predecessor_id.is_empty() else {}
		# Classify readiness from an isolated authoritative save snapshot. A fitted,
		# site-capable miner at zero maintenance coverage still owns its equipment;
		# both explicit and automatic selection must report service debt rather than
		# the misleading SHIP_REQUIRED equipment error.
		var maintenance_state := SpaceGameState.from_dictionary(Game.state.to_dictionary(), Game.content.domains.keys(), Game.content.regions)
		var maintenance_ship: Dictionary = maintenance_state.ship_by_id(mining_ship_id)
		maintenance_ship["maintenance_coverage"] = 0.0
		maintenance_ship["maintenance_debt"] = 1.0
		var maintenance_explicit: Dictionary = Game._extraction_operation_availability_for_state(maintenance_state, "belt_cobalt_frontier", [mining_ship_id])
		var maintenance_auto: Dictionary = Game._extraction_operation_availability_for_state(maintenance_state, "belt_cobalt_frontier")
		_check(String(maintenance_explicit.get("reason_code", "")) == "MAINTENANCE_REQUIRED", "explicit extraction availability preserves fitted equipment identity at zero Maintenance coverage")
		_check(String(maintenance_auto.get("reason_code", "")) == "MAINTENANCE_REQUIRED", "automatic extraction selection reports Maintenance debt instead of SHIP_REQUIRED")
		var availability_before := {
			"activity_available":Game.simulation.activity_available(Game.state, mining_activity),
			"can_start":Game.can_start_activity("mining", mining_activity),
			"site_available":Game.state.mining_site_available("belt_cobalt_frontier"),
			"selected_ship_requirements_met":Game.simulation.activity_requirements_met_for_ships(Game.state, mining_activity, [mining_ship_id]),
			"candidates":candidate_evidence,
			"structured":ready_availability
		}
		await _press_named(main, "StartMining_belt_cobalt_frontier", "START_MINING_START_PROBE")
		var runtime := _mining_runtime_for_site("belt_cobalt_frontier")
		print("UI_MINING_START_PROBE=", JSON.stringify({
			"last_notice":Game.last_notice,
			"runtime":runtime,
			"ship":Game.state.ship_by_id(mining_ship_id),
			"operations":Game.state.mining_operations,
			"availability_before":availability_before,
			"event_log":main.get("_event_log")
		}))
		_check(not runtime.is_empty(), "visible Start Mining command creates a Belt mining runtime")
		_check(unsuitable_predecessor, "probe fixture contains an earlier basic miner that cannot satisfy the Belt site's deep-core requirement")
		_check(String(unsuitable_availability.get("reason_code", "")) == "SHIP_REQUIREMENTS", "explicit extraction query reports the basic miner's site-capability failure")
		_check(bool(ready_availability.get("allowed", false)) and ready_availability.get("selected_ship_ids", []).has(mining_ship_id), "shared extraction availability selects the Pathfinder before the UI command")
		_check(runtime.get("assigned_ship_ids", []).has(mining_ship_id), "automatic Domain selection skips the earlier unsuitable miner and assigns the lunar Pathfinder")
		main.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if failures.is_empty() else 1)
		return
	if local_bootstrap_probe:
		var item_id := "mixed_raw_ore"
		await _stop_mining_site_ui(main, "earth_resource_cluster_prospect", item_id)
		await _press_named(main, "Navigation_survey", "OPEN_SURVEY_FOR_LOCAL_BOOTSTRAP_PROBE")
		var integrate_button := main.find_child("IntegrateMining_earth_resource_cluster_prospect", true, false) as Button
		if integrate_button != null and integrate_button.is_visible_in_tree() and not integrate_button.disabled:
			await _press_control(integrate_button, "INTEGRATE_EARTH_NETWORK_FOR_LOCAL_BOOTSTRAP_PROBE")
		_check(_active_local_extraction_network_produces(item_id), "probe fixture enables the real Earth extraction network through visible Survey controls")
		var production_before := _local_extraction_production_total_read_only(item_id)
		var action_count_before := player_action_execution_log.size()
		_operating_stock_guard_trace.clear()
		var raw_target := Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) + 50
		var recovered := await _stage_remote_operating_stock_ui(
			main,
			SpaceGameState.MAIN_BASE_LOCATION_ID,
			1,
			"asteroid_belt",
			{item_id:raw_target}
		)
		var new_actions := player_action_execution_log.slice(action_count_before)
		var remote_mining_action := new_actions.any(func(action_value):
			return String((action_value as Dictionary).get("action_id", "")).begins_with("START_MINING_TO_REPLENISH_"))
		var expected_guard_key := "earth_outbound:asteroid_belt"
		_check(recovered, "real Earth outbound staging recovers its source stock through visible production controls")
		_check(_operating_stock_guard_trace.size() == 2, "Earth outbound staging records one bounded guard ENTER/EXIT pair")
		if _operating_stock_guard_trace.size() == 2:
			_check(String(_operating_stock_guard_trace[0].get("event", "")) == "ENTER" and String(_operating_stock_guard_trace[0].get("key", "")) == expected_guard_key, "Earth outbound staging enters its owned bootstrap guard")
			_check(String(_operating_stock_guard_trace[1].get("event", "")) == "EXIT" and String(_operating_stock_guard_trace[1].get("key", "")) == expected_guard_key and bool(_operating_stock_guard_trace[1].get("result", false)), "Earth outbound staging releases its owned bootstrap guard after success")
		_check(_local_extraction_production_total_read_only(item_id) > production_before, "guarded recovery is backed by real Earth extraction-network output")
		_check(not remote_mining_action, "guarded Earth bootstrap recovery never falls back to a remote mining operation")
		_check(_operating_stock_stage_guard.is_empty(), "local bootstrap guard is released after bounded recovery")
		main.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if failures.is_empty() else 1)
		return
	if local_bootstrap_failure_probe:
		var item_id := "mixed_raw_ore"
		var path: Dictionary = Game.simulation.logistics._shortest_path(
			Game.state, "asteroid_belt", SpaceGameState.MAIN_BASE_LOCATION_ID, item_id)
		var belt_before := Game.state.item_quantity(item_id, "asteroid_belt")
		var delivered_before := int(Game.state.logistics_network.get("item_statistics", {}).get(item_id, {}).get("delivered", 0))
		var shipments_before: Array = Game.state.logistics_network.get("shipments", []).duplicate(true)
		var belt_policies_before: Dictionary = Game.state.location_state("asteroid_belt").get("logistics", {}).get("policies", {}).duplicate(true)
		var earth_policies_before: Dictionary = Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {}).duplicate(true)
		_check(not path.is_empty() and belt_before > 0, "failure fixture has a legal remote fallback that the Earth bootstrap guard must refuse")
		_check(not _active_local_extraction_network_produces(item_id), "failure fixture has no active Earth extraction network")
		var action_count_before := player_action_execution_log.size()
		_operating_stock_guard_trace.clear()
		_captured_expected_failures.clear()
		_expected_failure_prefix = "LOCAL_BOOTSTRAP_EXHAUSTED:"
		var raw_target := Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) + 2
		var recovered := await _stage_remote_operating_stock_ui(
			main,
			SpaceGameState.MAIN_BASE_LOCATION_ID,
			1,
			"asteroid_belt",
			{item_id:raw_target}
		)
		_expected_failure_prefix = ""
		var new_actions := player_action_execution_log.slice(action_count_before)
		var remote_fallback_action := new_actions.any(func(action_value):
			var action_id := String((action_value as Dictionary).get("action_id", ""))
			return action_id.begins_with("START_MINING_TO_REPLENISH_") \
				or action_id == "ADD_SUPPLY_POLICY_MIXED_RAW_ORE_AT_ASTEROID_BELT" \
				or action_id == "ADD_DEMAND_POLICY_MIXED_RAW_ORE_AT_EARTH_ORBIT")
		var expected_guard_key := "earth_outbound:asteroid_belt"
		_check(not recovered, "Earth outbound staging fails closed when its local bootstrap producer is unavailable")
		_check(not _captured_expected_failures.is_empty() and _captured_expected_failures.all(func(message): return String(message).begins_with("LOCAL_BOOTSTRAP_EXHAUSTED:")), "failure is reported only through the structured local-bootstrap exhaustion contract")
		_check(_operating_stock_guard_trace.size() == 2, "failed Earth outbound staging records one bounded guard ENTER/EXIT pair")
		if _operating_stock_guard_trace.size() == 2:
			_check(String(_operating_stock_guard_trace[0].get("event", "")) == "ENTER" and String(_operating_stock_guard_trace[0].get("key", "")) == expected_guard_key, "failed staging enters its owned bootstrap guard")
			_check(String(_operating_stock_guard_trace[1].get("event", "")) == "EXIT" and String(_operating_stock_guard_trace[1].get("key", "")) == expected_guard_key and not bool(_operating_stock_guard_trace[1].get("result", true)), "failed staging releases its owned bootstrap guard with result=false")
		_check(_operating_stock_stage_guard.is_empty(), "failed local bootstrap cannot leak its recursion guard")
		_check(not remote_fallback_action, "failed local bootstrap never starts remote mining or creates fallback freight policies")
		_check(Game.state.item_quantity(item_id, "asteroid_belt") == belt_before and int(Game.state.logistics_network.get("item_statistics", {}).get(item_id, {}).get("delivered", 0)) == delivered_before, "failed local bootstrap cannot move or duplicate remote ore")
		_check(Game.state.logistics_network.get("shipments", []) == shipments_before and Game.state.location_state("asteroid_belt").get("logistics", {}).get("policies", {}) == belt_policies_before and Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {}) == earth_policies_before, "failed local bootstrap leaves shipments and logistics policy state unchanged")
		main.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if failures.is_empty() else 1)
		return
	if maintenance_backlog_probe:
		var location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
		var repair_before := Game.state.item_quantity("repair_material", location_id)
		var initial_recovery := Game.simulation.maintenance_recovery_requirement(Game.state, location_id, "repair_material", 20, 0.0)
		var debt_before := float(initial_recovery.get("fleet_debt", 0.0))
		_check(Game.state.available_item_quantity("repair_material", location_id) == 0 and debt_before >= 8.0, "maintenance-backlog Scenario starts from real exhausted stock and fleet debt")
		_check(_active_local_extraction_network_produces("mixed_raw_ore"), "maintenance-backlog Scenario retains a legal Earth raw-material recovery network")
		var cycles_before := int(Game.state.completed_activities.get("fabricate_repair_material", 0))
		var fleet_consumed_before := int(Game.state.fleet_maintenance.get("consumption_totals", {}).get("repair_material", 0))
		var operations_consumed_before := int(Game.state.operations_maintenance.get("consumption_totals", {}).get("repair_material", 0))
		var shipment_serial_before := int(Game.state.logistics_network.get("next_shipment_serial", 1))
		var shipments_before: Array = Game.state.logistics_network.get("shipments", []).duplicate(true)
		var action_count_before := player_action_execution_log.size()
		_operating_stock_guard_trace.clear()
		var recovered := await _stage_remote_operating_stock_ui(main, location_id, 1, "asteroid_belt")
		var final_recovery := Game.simulation.maintenance_recovery_requirement(Game.state, location_id, "repair_material", 20, 0.0)
		var cycles_after := int(Game.state.completed_activities.get("fabricate_repair_material", 0))
		var completed_cycles := cycles_after - cycles_before
		var fleet_consumed := int(Game.state.fleet_maintenance.get("consumption_totals", {}).get("repair_material", 0)) - fleet_consumed_before
		var operations_consumed := int(Game.state.operations_maintenance.get("consumption_totals", {}).get("repair_material", 0)) - operations_consumed_before
		var repair_after := Game.state.item_quantity("repair_material", location_id)
		var new_actions := player_action_execution_log.slice(action_count_before)
		var action_ids: Array = new_actions.map(func(action_value): return String((action_value as Dictionary).get("action_id", "")))
		var expected_guard_key := "earth_outbound:asteroid_belt"
		print("UI_MAINTENANCE_BACKLOG_RECOVERY=", JSON.stringify({
			"initial":initial_recovery, "final":final_recovery,
			"repair_before":repair_before, "repair_after":repair_after,
			"completed_cycles":completed_cycles, "fleet_consumed":fleet_consumed,
			"operations_consumed":operations_consumed, "actions":action_ids,
			"guard_trace":_operating_stock_guard_trace
		}))
		_check(recovered and Game.state.available_item_quantity("repair_material", location_id) >= 20, "visible UI recovery returns success only with the requested Repair Material spendable")
		_check(float(final_recovery.get("fleet_debt", 1.0)) <= 0.000001, "visible UI recovery clears the real fleet maintenance debt")
		_check(completed_cycles > ceili(debt_before), "visible Industry controls manufacture both debt recovery and spendable Repair Material")
		_check(action_ids.has("START_FABRICATE_REPAIR_MATERIAL") and action_ids.any(func(action_id): return String(action_id).begins_with("SET_GAME_SPEED_")), "maintenance recovery uses the visible Repair Material recipe and public speed controls")
		_check(not action_ids.any(func(action_id): return String(action_id).begins_with("START_MINING_TO_REPLENISH_")), "Earth maintenance recovery does not fall back to a remote mining operation")
		_check(_operating_stock_guard_trace.size() == 2 and String(_operating_stock_guard_trace[0].get("event", "")) == "ENTER" and String(_operating_stock_guard_trace[0].get("key", "")) == expected_guard_key and String(_operating_stock_guard_trace[1].get("event", "")) == "EXIT" and bool(_operating_stock_guard_trace[1].get("result", false)), "maintenance recovery owns and releases one successful Earth outbound guard")
		_check(_operating_stock_stage_guard.is_empty(), "maintenance recovery cannot leak its recursion guard")
		_check(int(Game.state.logistics_network.get("next_shipment_serial", 1)) == shipment_serial_before and Game.state.logistics_network.get("shipments", []) == shipments_before, "source-only maintenance staging cannot create an unrequested freight shipment")
		_check(completed_cycles == repair_after - repair_before + fleet_consumed + operations_consumed, "UI maintenance recovery conserves Repair Material across production, debt settlement, O&M and Inventory")
		main.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if failures.is_empty() else 1)
		return
	if streaming_gas_probe:
		var cruiser_id := _ship_id_for_blueprint("belt_cruiser")
		_check(not cruiser_id.is_empty(), "Jovian checkpoint owns the normal Belt Cruiser mining hull")
		if not cruiser_id.is_empty():
			_check(await _recover_mining_ship_service_ui(main, cruiser_id, "STREAMING_GAS_REFIT"), "visible industry clears pre-refit Mining ship maintenance debt")
			_check(await _install_ship_module_ui(main, cruiser_id, "gas_collector"), "visible Ship configuration installs Gas Collection through its full BOM")
			var delivered_before := int(Game.state.logistics_network.get("item_statistics", {}).get("mixed_raw_gas", {}).get("delivered", 0))
			var streamed := await _mine_and_freight_ui(main, "gas_giant_region", "jovian_cloud_frontier", cruiser_id, "mixed_raw_gas", 24)
			var delivered_delta := int(Game.state.logistics_network.get("item_statistics", {}).get("mixed_raw_gas", {}).get("delivered", 0)) - delivered_before
			_check(streamed, "small Jovian depot streams physical gas into normal Logistics instead of deadlocking at STORAGE_FULL")
			_check(delivered_delta >= 24, "streaming gas probe records the full 24-unit conserved delivery target")
		main.queue_free()
		await get_tree().process_frame
		get_tree().quit(0 if failures.is_empty() else 1)
		return
	var completed := await _complete_megastructure_ui(main)
	_check(completed, "scenario diagnostic reaches Megastructure completion through visible UI controls")
	_check(bool(Game.state.game_complete), "scenario diagnostic observes the real game-complete consequence")
	main.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("PASS: UI endgame scenario diagnostic completed; not fresh-save certification evidence")
		get_tree().quit(0)
	else:
		for failure in failures:
			print(failure)
		get_tree().quit(1)
