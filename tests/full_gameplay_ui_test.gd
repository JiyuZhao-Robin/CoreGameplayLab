extends Node

const MainScene := preload("res://src/ui/main.tscn")
const EVIDENCE_PATH := "res://artifacts/test-results/full-gameplay-ui.json"
const PLAYTHROUGH_SCREENSHOT_ROOT := "res://artifacts/ui/playthrough"

const WALL_POLL_SECONDS := 0.025
const EXTRACTION_TIMEOUT_SECONDS := 8.0
const PRODUCTION_TIMEOUT_SECONDS := 8.0
const BOOTSTRAP_BATCH_TIMEOUT_SECONDS := 14.0
const CONSTRUCTION_TIMEOUT_SECONDS := 10.0
const LARGE_BATCH_TIMEOUT_SECONDS := 40.0
const RESEARCH_TIMEOUT_SECONDS := 12.0
const JOURNEY_STAGE_TIMEOUT_SECONDS := 24.0

const UI_INDUSTRY_RECIPE_BY_ITEM := {
	"iron_ore":"separate_iron_ore",
	"copper_ore":"separate_copper_ore",
	"titanium_ore":"separate_titanium_ore",
	"iron_ingot":"refine_iron",
	"copper_ingot":"refine_copper",
	"titanium_alloy":"refine_titanium",
	"electronics":"fabricate_electronics",
	"data_core":"fabricate_data_core",
	"structural_frame":"assemble_frame",
	"industrial_machine_tools":"fabricate_basic_machine_tools",
	"repair_material":"fabricate_repair_material",
	"chemical_propellant":"manufacture_emergency_propellant",
	"reactor_part":"fabricate_reactor_part",
	"propulsion_test_article":"fabricate_propulsion_test_article",
	"superconducting_composite":"fabricate_superconducting_composite",
	"superconducting_coil":"wind_superconducting_coil",
	"radiation_hardened_electronics":"fabricate_radiation_hardened_electronics",
	"material_test_article":"fabricate_material_test_article",
	"silicate_ore":"separate_silicate_ore",
	"silicate_ceramic":"process_silicate_ceramic",
	"cobalt_ore":"separate_cobalt_ore",
	"cobalt_ingot":"refine_cobalt",
	"steel_composite":"refine_steel",
	"heavy_structural_section":"fabricate_heavy_structural_section",
	"precision_actuator":"fabricate_precision_actuator",
	"power_bus_component":"fabricate_power_bus_component",
	"logistics_handling_equipment":"fabricate_logistics_handling_equipment",
	"thermal_exchange_unit":"fabricate_thermal_exchange_unit",
	"automated_control_core":"fabricate_automated_control_core",
	"construction_robotics":"fabricate_construction_robotics",
	"quantum_component":"fabricate_quantum_component",
	"superalloy":"refine_superalloy",
	"methane":"separate_methane",
	"helium_3":"separate_helium_3",
	"thorium_ore":"separate_thorium_ore",
	"thorium_fuel":"prepare_thorium_fuel",
	"fusion_service_component":"fabricate_fusion_service_component",
	"project_core":"assemble_project_core",
	"exotic_crystal":"separate_exotic_crystal",
	"antimatter_cell":"build_antimatter_cell",
	"dark_matter":"separate_dark_matter",
	"kinetic_munitions":"manufacture_kinetic_munitions",
	"repair_supplies":"manufacture_repair_supplies",
	"water_ice":"separate_water_ice",
	"rare_earth_concentrate":"separate_rare_earth_concentrate"
}

var failures: Array[String] = []
var player_action_execution_log: Array[Dictionary] = []
var journey_event_log: Array[String] = []
var registry_journey_events: Dictionary = {}
var evidence_run_id := "UNBOUND"
var _operating_stock_stage_guard := {}


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--evidence-run-id="):
			evidence_run_id = argument.trim_prefix("--evidence-run-id=")
	_check(not evidence_run_id.is_empty() and evidence_run_id != "UNBOUND", "Fresh Save evidence is bound to the invoking audit run")
	# Disabling persistence is a harness boundary only. The fresh state itself is
	# created by pressing the same Restart confirmation controls as a player.
	Game.persistence_enabled = false
	var main := MainScene.instantiate() as Control
	add_child(main)
	await _settle_ui()
	var initial_header_text := String((main.find_child("HeaderStatus", true, false) as Label).text)

	await _start_fresh_save_through_ui(main)
	_check(int(Game.state.completed_activities.get("extract_earth_mixed_ore", 0)) == 0, "fresh-save UI reset clears prior extraction progress")
	_check(int(Game.state.completed_activities.get("separate_iron_ore", 0)) == 0, "fresh-save UI reset clears prior industrial progress")
	journey_event_log.append("NEW_GAME")
	_record_registry_event("JOURNEY_01_EARLY_INDUSTRY", "NEW_GAME")
	await _capture_playthrough_milestone(main, "01_new_game")

	await _press_named(main, "Navigation_ships", "OPEN_SHIPS")
	var assign_mining := _first_enabled_button(main, "AssignMining_")
	await _press_control(assign_mining, "ASSIGN_SHIP_MINING")
	var mining_assignment_ready := _starter_ship_is_assigned_to_mining()
	_check(mining_assignment_ready, "visible Ships control assigns the starter vessel to extraction")
	if mining_assignment_ready:
		journey_event_log.append("FIRST_FLEET_ASSIGNMENT")

	await _press_named(main, "Navigation_survey", "OPEN_SURVEY")
	var start_mining := main.find_child("StartMining_earth_resource_cluster_prospect", true, false) as Button
	await _press_control(start_mining, "START_EXTRACTION")
	var extraction_running := _has_running_extraction()
	_check(extraction_running, "visible Survey control starts the real permanent extraction runtime")
	if extraction_running:
		journey_event_log.append("FIRST_EXTRACTION_STARTED")
		_record_registry_event("JOURNEY_01_EARLY_INDUSTRY", "START_EXTRACTION")

	# The default service is a real player-visible logistics surface, not hidden
	# debug state. Open it before the first processed batch to preserve Journey 01's
	# required causal order.
	await _press_named(main, "Navigation_logistics", "OPEN_STARTING_LOGISTICS")
	var starting_logistics_established: bool = not Game.state.logistics_network.get("services", {}).is_empty()
	_check(starting_logistics_established, "fresh save exposes an established physical Logistics service through UI")
	if starting_logistics_established:
		_record_registry_event("JOURNEY_01_EARLY_INDUSTRY", "ESTABLISH_LOGISTICS")

	await _press_named(main, "Speed10", "SET_GAME_SPEED_10")
	var extracted := await _wait_until(func() -> bool:
		return int(Game.state.completed_activities.get("extract_earth_mixed_ore", 0)) >= 1 \
			and Game.state.item_quantity("mixed_raw_ore", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 2,
		EXTRACTION_TIMEOUT_SECONDS)
	_check(extracted, "normal 10x speed control and real process time reach FIRST_EXTRACTION")
	if extracted:
		journey_event_log.append("FIRST_EXTRACTION")

	await _press_named(main, "Navigation_industry", "OPEN_INDUSTRY")
	var start_separation := main.find_child("StartIndustry_separate_iron_ore", true, false) as Button
	await _press_control(start_separation, "START_SEPARATE_IRON_ORE")
	var separation_running := _industry_activity_is_running("separate_iron_ore")
	_check(separation_running, "visible Industry control starts the real separation recipe")
	if separation_running:
		journey_event_log.append("FIRST_PRODUCTION_STARTED")

	var processed := await _wait_until(func() -> bool:
		return int(Game.state.completed_activities.get("separate_iron_ore", 0)) >= 1 \
			and Game.state.item_quantity("iron_ore", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 2,
		PRODUCTION_TIMEOUT_SECONDS)
	_check(processed, "normal 10x speed control and real process time reach FIRST_PROCESSED_MATERIAL")
	if processed:
		journey_event_log.append("FIRST_PROCESSED_MATERIAL")
		_record_registry_event("JOURNEY_01_EARLY_INDUSTRY", "FIRST_PROCESSED_MATERIAL")
		await _capture_playthrough_milestone(main, "02_first_industry")

	# Continue the same fresh save through the complete single-workshop bootstrap.
	# The starter extractor remains active, so every input below is produced by
	# the real economy while the test changes recipes only through UI controls.
	var iron_feedstock_ready := await _wait_until(func() -> bool:
		return int(Game.state.completed_activities.get("separate_iron_ore", 0)) >= 6 \
			and Game.state.item_quantity("iron_ore", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 12,
		BOOTSTRAP_BATCH_TIMEOUT_SECONDS)
	_check(iron_feedstock_ready, "UI-started extraction and separation accumulate the six-cycle Foundry iron batch")
	await _press_named(main, "StopIndustry_separate_iron_ore", "STOP_SEPARATE_IRON_ORE")

	await _press_named(main, "StartIndustry_refine_iron", "START_REFINE_IRON")
	var refined_iron_ready := await _wait_until(func() -> bool:
		return int(Game.state.completed_activities.get("refine_iron", 0)) >= 6 \
			and Game.state.item_quantity("iron_ingot", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 6,
		BOOTSTRAP_BATCH_TIMEOUT_SECONDS)
	_check(refined_iron_ready, "visible Industry controls refine the six Iron Ingots required by frame and Foundry")
	if refined_iron_ready:
		journey_event_log.append("FIRST_REFINED_IRON")
	await _press_named(main, "StopIndustry_refine_iron", "STOP_REFINE_IRON")

	await _press_named(main, "StartIndustry_separate_copper_ore", "START_SEPARATE_COPPER_ORE")
	var copper_feedstock_ready := await _wait_until(func() -> bool:
		return int(Game.state.completed_activities.get("separate_copper_ore", 0)) >= 1 \
			and Game.state.item_quantity("copper_ore", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 2,
		PRODUCTION_TIMEOUT_SECONDS)
	_check(copper_feedstock_ready, "visible Industry controls produce the first Copper Ore batch")
	await _press_named(main, "StopIndustry_separate_copper_ore", "STOP_SEPARATE_COPPER_ORE")

	await _press_named(main, "StartIndustry_refine_copper", "START_REFINE_COPPER")
	var refined_copper_ready := await _wait_until(func() -> bool:
		return int(Game.state.completed_activities.get("refine_copper", 0)) >= 1 \
			and Game.state.item_quantity("copper_ingot", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 1,
		PRODUCTION_TIMEOUT_SECONDS)
	_check(refined_copper_ready, "visible Industry controls refine the first Copper Ingot")
	if refined_copper_ready:
		journey_event_log.append("FIRST_REFINED_COPPER")
	await _press_named(main, "StopIndustry_refine_copper", "STOP_REFINE_COPPER")

	await _press_named(main, "StartIndustry_assemble_frame", "START_ASSEMBLE_FRAME")
	var frame_ready := await _wait_until(func() -> bool:
		return int(Game.state.completed_activities.get("assemble_frame", 0)) >= 1 \
			and Game.state.item_quantity("structural_frame", SpaceGameState.MAIN_BASE_LOCATION_ID) >= 1,
		PRODUCTION_TIMEOUT_SECONDS)
	_check(frame_ready, "visible Industry controls produce the first real Structural Frame")
	if frame_ready:
		journey_event_log.append("FIRST_STRUCTURAL_FRAME")
	await _press_named(main, "StopIndustry_assemble_frame", "STOP_ASSEMBLE_FRAME")

	await _press_named(main, "IndustrySection_construction", "OPEN_CONSTRUCTION")
	await _press_named(main, "StartConstruction_build_orbital_foundry", "START_ORBITAL_FOUNDRY_CONSTRUCTION")
	var foundry_project_started := _construction_activity_exists("build_orbital_foundry")
	_check(foundry_project_started, "visible Construction control creates a material-backed Foundry project")
	if foundry_project_started:
		journey_event_log.append("FIRST_FACILITY_CONSTRUCTION_STARTED")
	var foundry_ready := await _wait_until(func() -> bool:
		return "orbital_foundry" in Game.state.facilities,
		CONSTRUCTION_TIMEOUT_SECONDS)
	_check(foundry_ready, "normal 10x speed completes the real Orbital Foundry construction project")
	if not foundry_ready:
		_print_time_orchestration_diagnostic("build_orbital_foundry")
	if foundry_ready:
		journey_event_log.append("FIRST_FACILITY_COMPLETED")

	# Close the founding-industry loop through normal player surfaces. The batch
	# is deliberately produced rather than granted: two Structures plus 22 Iron
	# fund the High-Energy Works and Research Complex, while four retained Iron
	# fund the first R&D program.
	await _open_industry_production(main)
	_check(await _produce_until(main, "separate_iron_ore", "iron_ore", 52, LARGE_BATCH_TIMEOUT_SECONDS), "UI production prepares the full Establish Industry iron feedstock batch")
	_check(await _produce_until(main, "refine_iron", "iron_ingot", 26, LARGE_BATCH_TIMEOUT_SECONDS), "UI production refines the full Establish Industry iron batch")
	_check(await _produce_until(main, "separate_copper_ore", "copper_ore", 4, PRODUCTION_TIMEOUT_SECONDS), "UI production prepares Copper for two additional Structural Frames")
	_check(await _produce_until(main, "refine_copper", "copper_ingot", 2, PRODUCTION_TIMEOUT_SECONDS), "UI production refines Copper for two additional Structural Frames")
	_check(await _produce_until(main, "assemble_frame", "structural_frame", 2, PRODUCTION_TIMEOUT_SECONDS), "UI production assembles the two Structural Frames required by High-Energy Systems")

	await _open_industry_construction(main)
	await _press_named(main, "StartConstruction_build_electronics_facility", "START_HIGH_ENERGY_SYSTEMS_CONSTRUCTION")
	var electronics_facility_ready := await _wait_until(func() -> bool:
		return "electronics_facility" in Game.state.facilities,
		CONSTRUCTION_TIMEOUT_SECONDS)
	_check(electronics_facility_ready, "UI completes the material-backed High-Energy Systems construction")

	# The Research Complex card becomes valid only after the preceding facility
	# completion is observed and the page rebuilds from the new Domain state.
	await _open_industry_construction(main)
	await _press_named(main, "StartConstruction_build_research_complex", "START_RESEARCH_COMPLEX_CONSTRUCTION")
	var research_facility_ready := await _wait_until(func() -> bool:
		return "research_complex" in Game.state.facilities,
		CONSTRUCTION_TIMEOUT_SECONDS)
	_check(research_facility_ready, "UI completes the material-backed Research Complex construction")
	if electronics_facility_ready and research_facility_ready:
		journey_event_log.append("ESTABLISH_INDUSTRY_COMPLETED")

	await _press_named(main, "Navigation_research", "OPEN_RESEARCH")
	await _press_named(main, "StartResearch_research_industrial_coordination", "START_FIRST_RESEARCH_PROGRAM")
	# 100x is a normal player-facing fast-forward control reserved for a long,
	# decision-free wait after every material input has already been committed.
	await _press_named(main, "Speed100", "SET_GAME_SPEED_100")
	var first_research_ready := await _wait_until(func() -> bool:
		return bool(Game.state.technologies.get("industrial_coordination", false)),
		RESEARCH_TIMEOUT_SECONDS)
	var fast_forward_backlog_ms := float(Game.get("_simulation_accumulator_ms"))
	await _press_named(main, "Speed10", "RETURN_GAME_SPEED_10")
	_check(first_research_ready, "visible Research control completes Industrial Coordination through normal time")
	if first_research_ready:
		journey_event_log.append("FIRST_RESEARCH_PROGRAM")

	# Industrial Coordination reveals the recoverable machine-tool recipe. Build
	# every ingredient through the same workshop controls, then manufacture the
	# first persistent Capital Good.
	await _open_industry_production(main)
	_check(await _produce_until(main, "separate_iron_ore", "iron_ore", 14, BOOTSTRAP_BATCH_TIMEOUT_SECONDS), "UI production prepares iron for the first Capital Good")
	_check(await _produce_until(main, "refine_iron", "iron_ingot", 7, BOOTSTRAP_BATCH_TIMEOUT_SECONDS), "UI production refines iron for the first Capital Good")
	_check(await _produce_until(main, "separate_copper_ore", "copper_ore", 4, PRODUCTION_TIMEOUT_SECONDS), "UI production prepares Copper for electronics and frame inputs")
	_check(await _produce_until(main, "refine_copper", "copper_ingot", 2, PRODUCTION_TIMEOUT_SECONDS), "UI production refines Copper for electronics and frame inputs")
	_check(await _produce_until(main, "fabricate_electronics", "electronics", 2, PRODUCTION_TIMEOUT_SECONDS), "UI production recovers the Electronics consumed by research")
	_check(await _produce_until(main, "assemble_frame", "structural_frame", 1, PRODUCTION_TIMEOUT_SECONDS), "UI production assembles the machine-tool Structural Frame")
	var capital_good_ready := await _produce_until(main, "fabricate_basic_machine_tools", "industrial_machine_tools", 1, PRODUCTION_TIMEOUT_SECONDS)
	_check(capital_good_ready, "visible Industry control manufactures the first persistent Industrial Machine Tool")
	if capital_good_ready:
		journey_event_log.append("FIRST_CAPITAL_GOOD")

	# Level 2 introduces a real machine-tool dependency. Produce the remaining
	# iron/electronics, then use Location > Industry's visible expansion control.
	_check(await _produce_until(main, "separate_iron_ore", "iron_ore", 16, BOOTSTRAP_BATCH_TIMEOUT_SECONDS), "UI production prepares iron for the first facility expansion")
	_check(await _produce_until(main, "refine_iron", "iron_ingot", 8, BOOTSTRAP_BATCH_TIMEOUT_SECONDS), "UI production refines iron for the first facility expansion")
	_check(await _produce_until(main, "separate_copper_ore", "copper_ore", 4, PRODUCTION_TIMEOUT_SECONDS), "UI production prepares Copper for expansion Electronics")
	_check(await _produce_until(main, "refine_copper", "copper_ingot", 2, PRODUCTION_TIMEOUT_SECONDS), "UI production refines Copper for expansion Electronics")
	_check(await _produce_until(main, "fabricate_electronics", "electronics", 4, PRODUCTION_TIMEOUT_SECONDS), "UI production manufactures the expansion Electronics")

	await _press_named(main, "Navigation_location", "OPEN_LOCATION_FOR_EXPANSION")
	await _press_named(main, "LocationTab_industry", "OPEN_LOCATION_INDUSTRY")
	await _press_named(main, "ExpandIndustry_makeshift_workshop_1", "START_FIRST_FACILITY_EXPANSION")
	var expansion_project_started := _facility_expansion_exists("makeshift_workshop")
	_check(expansion_project_started, "visible Location Industry control creates a Capital-Good-backed expansion project")
	var first_upgrade_ready := await _wait_until(func() -> bool:
		return int(Game.state.location_industry(SpaceGameState.MAIN_BASE_LOCATION_ID, "makeshift_workshop").get("level", 0)) >= 2,
		CONSTRUCTION_TIMEOUT_SECONDS)
	_check(first_upgrade_ready, "normal 10x speed completes the first real facility expansion")
	if first_upgrade_ready:
		journey_event_log.append("FIRST_FACILITY_UPGRADE")

	# Continue the same fresh save into the off-world chain. Every dependency is
	# recursively produced by selecting visible Industry recipes; the helper only
	# reads Content definitions to calculate how many real UI cycles are needed.
	_check(await _ensure_ui_costs(main, {"iron_ingot":8, "electronics":4}), "UI production prepares the automatic Earth extraction network")
	await _open_industry_construction(main)
	await _press_named(main, "StartConstruction_build_earth_extraction_network", "START_EARTH_EXTRACTION_NETWORK")
	var earth_network_ready := await _wait_until(func() -> bool:
		return "earth_extraction_network" in Game.state.facilities,
		CONSTRUCTION_TIMEOUT_SECONDS)
	_check(earth_network_ready, "visible Construction control completes the automatic Earth extraction network")
	await _press_named(main, "Navigation_survey", "OPEN_SURVEY_FOR_EARTH_AUTOMATION")
	await _press_named(main, "IntegrateMining_earth_resource_cluster_prospect", "INTEGRATE_EARTH_MINING_SITE")
	var earth_site_integrated := _network_has_site("earth_extraction_network", "earth_resource_cluster_prospect")
	_check(earth_site_integrated, "visible Survey control integrates the mastered Earth site without a state shortcut")
	if earth_network_ready and earth_site_integrated:
		journey_event_log.append("EARTH_EXTRACTION_AUTOMATED")

	var starter_ship_id := _ship_id_for_blueprint("patchwork_prospector")
	await _assign_ship_and_open_route(main, starter_ship_id, "lunar_route")
	var lunar_route_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.completed_activities.get("route:lunar_route", 0)) > 0,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(lunar_route_ready, "visible Expedition route and public speed control unlock Lunar Space")
	if lunar_route_ready:
		journey_event_log.append("FIRST_ROUTE_COMPLETED")

	# The major propulsion program consumes actual lunar alloy and electronics,
	# then pauses for a manufactured prototype and a real proving-flight route.
	_check(await _ensure_ui_costs(main, {"titanium_alloy":5, "electronics":4, "data_core":1}), "UI industry manufactures every staged Advanced Propulsion input")
	var early_lunar_storage_target := Game.simulation.suggested_location_capacity_upgrade_target(Game.state, "lunar_space", "BULK_STORAGE_UPGRADE")
	_check(not _capacity_upgrade_supply_chain_is_unlocked("lunar_space", "BULK_STORAGE_UPGRADE", early_lunar_storage_target), "pre-Heavy-Industry availability query identifies the Lunar storage BOM as not yet supplyable")
	var early_lunar_storage_project := Game.state.construction_operations.any(func(runtime_value):
		var runtime := runtime_value as Dictionary
		return String(runtime.get("location_id", "")) == "lunar_space" \
			and String(runtime.get("project_type", "")) == "BULK_STORAGE_UPGRADE" \
			and String(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"])
	_check(not early_lunar_storage_project, "pre-Heavy-Industry planning does not queue an unavailable advanced Lunar storage BOM")
	await _press_named(main, "Navigation_research", "OPEN_RESEARCH_FOR_ADVANCED_PROPULSION")
	await _press_named(main, "StartResearch_research_advanced_propulsion_HIGH_THRUST", "START_ADVANCED_PROPULSION_HIGH_THRUST")
	_record_registry_event("JOURNEY_05_RESEARCH_PROGRAM", "RESEARCH_STARTED")
	var propulsion_experiment_complete := await _wait_at_public_fast_speed(main, func() -> bool:
		return bool(Game.state.technology_spillovers.get("experimental_propulsion_engineering", false)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(propulsion_experiment_complete, "routed R&D reaches the experimental propulsion milestone using committed industrial inputs")
	if propulsion_experiment_complete:
		_record_registry_event("JOURNEY_05_RESEARCH_PROGRAM", "THEORY_COMPLETED")
	_check(await _ensure_ui_item(main, "propulsion_test_article", 2), "visible Industry control manufactures the physical propulsion test articles")
	_record_registry_event("JOURNEY_05_RESEARCH_PROGRAM", "EXPERIMENTAL_MATERIAL_MANUFACTURED")
	if "research_complex" in Game.state.facilities:
		_record_registry_event("JOURNEY_05_RESEARCH_PROGRAM", "RESEARCH_FACILITY_COMMISSIONED")
	var propulsion_field_test_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_advanced_propulsion" \
			and String(Game.state.research.get("stage_id", "")) == "field_test",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(propulsion_field_test_ready, "Advanced Propulsion waits at its real Field Test milestone")
	if propulsion_field_test_ready:
		journey_event_log.append("FIRST_PROTOTYPE")
		_record_registry_event("JOURNEY_05_RESEARCH_PROGRAM", "PROTOTYPE_MANUFACTURED")

	await _assign_ship_and_open_route(main, starter_ship_id, "propulsion_proving_route")
	var proving_route_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.completed_activities.get("route:propulsion_proving_route", 0)) > 0,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(proving_route_ready, "the physical starter ship completes the Advanced Propulsion proving flight through UI")
	if proving_route_ready:
		journey_event_log.append("FIRST_FIELD_TEST")
		_record_registry_event("JOURNEY_05_RESEARCH_PROGRAM", "FIELD_TEST_COMPLETED")
	var propulsion_release_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return bool(Game.state.technologies.get("advanced_propulsion", false)) \
			or (String(Game.state.research.get("project_id", "")) == "research_advanced_propulsion" \
				and String(Game.state.research.get("stage_id", "")) == "industrialization"),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(propulsion_release_ready, "the proving flight advances Advanced Propulsion to its real industrial release stage")
	if propulsion_release_ready and not bool(Game.state.technologies.get("advanced_propulsion", false)):
		var propulsion_project: Dictionary = Game.content.research_projects.get("research_advanced_propulsion", {})
		var propulsion_release: Dictionary = Game.simulation.research_stage_definition(
			Game.state,
			propulsion_project,
			int(Game.state.research.get("stage_index", 0)),
			String(Game.state.research.get("route_id", "")))
		_check(String(propulsion_release.get("id", "")) == "industrialization", "Advanced Propulsion exposes the canonical industrial release definition")
		_check(await _ensure_ui_research_stage_costs(main, "research_advanced_propulsion", "industrialization"), "UI industry supplies the current Advanced Propulsion industrialization package")
	var advanced_propulsion_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return bool(Game.state.technologies.get("advanced_propulsion", false)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(advanced_propulsion_ready, "Advanced Propulsion completes only after its UI-triggered prototype and Field Test")
	if advanced_propulsion_ready:
		journey_event_log.append("ADVANCED_PROPULSION_COMPLETED")
		_record_registry_event("JOURNEY_05_RESEARCH_PROGRAM", "TECHNOLOGY_UNLOCKED")
		await _press_named(main, "Navigation_research", "OPEN_RESEARCH_FOR_MILESTONE_CAPTURE")
		await _capture_playthrough_milestone(main, "05_research")

	# Develop and physically build the Pathfinder. The research program and the
	# Shipyard order consume separate real BOMs, both manufactured through UI.
	_check(await _ensure_ui_item(main, "reactor_part", 2), "UI industry manufactures the Pathfinder reactor components")
	_check(await _ensure_ui_item(main, "data_core", 1), "UI industry manufactures the Pathfinder development data core")
	_check(await _ensure_ui_item(main, "titanium_alloy", 3), "UI industry manufactures the Pathfinder hull alloy")
	_check(await _ensure_ui_item(main, "electronics", 4), "UI industry manufactures Pathfinder development and construction electronics")
	await _press_named(main, "Navigation_research", "OPEN_RESEARCH_FOR_PATHFINDER")
	await _press_named(main, "StartResearch_develop_lunar_pathfinder", "START_PATHFINDER_DEVELOPMENT")
	var pathfinder_plan_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return bool(Game.state.completed_projects.get("develop_lunar_pathfinder", false)) \
			and bool(Game.state.unlocked_ship_plans.get("construct_lunar_pathfinder", false)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(pathfinder_plan_ready, "visible Research control unlocks the Pathfinder plan")
	if pathfinder_plan_ready:
		_record_registry_event("JOURNEY_06_SHIP_INDUSTRY", "SHIP_CONFIGURATION_SELECTED")
	var pathfinder_plan: Dictionary = Game.content.ship_construction_projects.get("construct_lunar_pathfinder", {})
	var pathfinder_costs: Dictionary = Game.simulation.ship_construction_material_totals(pathfinder_plan)
	for fixed_cost_value in pathfinder_plan.get("fixed_costs", []):
		var fixed_cost := fixed_cost_value as Dictionary
		var fixed_item := String(fixed_cost.get("item", ""))
		pathfinder_costs[fixed_item] = int(pathfinder_costs.get(fixed_item, 0)) + int(fixed_cost.get("quantity", 0))
	_check(await _ensure_ui_costs_stable(main, pathfinder_costs), "UI industry satisfies the canonical Pathfinder Shipyard BOM")
	await _press_named(main, "Navigation_ships", "OPEN_SHIPS_FOR_PATHFINDER_BUILD")
	await _press_named(main, "FleetSection_shipyard", "OPEN_PATHFINDER_SHIPYARD")
	await _press_named(main, "BuildShip_construct_lunar_pathfinder_1", "BUILD_PATHFINDER")
	if Game.simulation.shipyard_queue_index(Game.state, "construct_lunar_pathfinder") >= 0:
		_record_registry_event("JOURNEY_06_SHIP_INDUSTRY", "SHIP_BOM_COMMITTED")
	var pathfinder_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return not _ship_id_for_blueprint("lunar_pathfinder").is_empty(),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(pathfinder_ready, "visible Shipyard control commissions the physical Lunar Pathfinder")
	var pathfinder_id := _ship_id_for_blueprint("lunar_pathfinder")
	if pathfinder_ready:
		journey_event_log.append("FIRST_COMMISSIONED_SHIP")
		_record_registry_event("JOURNEY_06_SHIP_INDUSTRY", "SHIP_MANUFACTURED")
		_record_registry_event("JOURNEY_06_SHIP_INDUSTRY", "SHIP_ASSEMBLED")
		_record_registry_event("JOURNEY_06_SHIP_INDUSTRY", "SHIP_COMMISSIONED")

	await _assign_ship_and_open_route(main, pathfinder_id, "asteroid_route")
	var asteroid_route_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.completed_activities.get("route:asteroid_route", 0)) > 0 \
			and bool(Game.state.regions.get("asteroid_belt", false)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(asteroid_route_ready, "the commissioned Pathfinder unlocks the Asteroid Belt through the visible route")
	if asteroid_route_ready:
		journey_event_log.append("ASTEROID_BELT_REACHED")
		_record_registry_event("JOURNEY_06_SHIP_INDUSTRY", "SHIP_ASSIGNED")
		_record_registry_event("JOURNEY_07_SURVEY", "LOCATION_DETECTED")

	# The Belt is not treated as surveyed merely because its route completed.
	# Manufacture the deployment package, then execute both real Survey missions.
	_check(await _ensure_ui_item(main, "industrial_machine_tools", 1), "UI industry supplies the Belt survey machine tool")
	_check(await _ensure_ui_item(main, "structural_frame", 2), "UI industry supplies the Belt survey structural package")
	_check(await _ensure_ui_item(main, "repair_material", 1), "UI industry supplies the Belt survey maintenance package")
	_check(await _ensure_ui_item(main, "electronics", 2), "UI industry supplies the Belt survey electronics package")
	_check(await _ensure_ui_item(main, "chemical_propellant", 3), "UI recovery recipe manufactures the three Survey propellant units outside fleet escrow")
	var belt_survey_costs := Game.simulation.survey_mission_costs(LocationState.SURVEYED)
	_check(await _ensure_ui_costs_stable(main, belt_survey_costs), "UI stages the complete spendable Belt Survey deployment package after reservations and O&M")
	await _open_location_from_system(main, "asteroid_belt")
	_check(String(Game.state.location_state("asteroid_belt").get("survey_state", "")) == LocationState.DETECTED, "the completed Asteroid route exposes only DETECTED intelligence before player Survey")
	var belt_survey_button := main.find_child("StartSurvey_asteroid_belt_SURVEYED_%s" % pathfinder_id, true, false) as Button
	if belt_survey_button == null or belt_survey_button.disabled:
		print("FULL_GAMEPLAY_UI_SURVEY_UNAVAILABLE=", JSON.stringify({
			"control_found":belt_survey_button != null,
			"control_tooltip":belt_survey_button.tooltip_text if belt_survey_button != null else "",
			"ship":Game.state.ship_by_id(pathfinder_id),
			"costs":belt_survey_costs,
			"earth_inventory":Game.state.location_inventory(SpaceGameState.MAIN_BASE_LOCATION_ID),
			"earth_reserves":Game.state.location_reserves(SpaceGameState.MAIN_BASE_LOCATION_ID)
		}))
	await _press_control(belt_survey_button, "START_BELT_INDUSTRIAL_SURVEY")
	var belt_survey_started := String(Game.state.survey_mission.get("status", "IDLE")) == "RUNNING" \
		and (Game.state.survey_mission.get("assigned_ship_ids", []) as Array).has(pathfinder_id)
	_check(belt_survey_started, "visible Survey control assigns the physical Pathfinder to the Belt mission")
	if belt_survey_started:
		_record_registry_event("JOURNEY_07_SURVEY", "SURVEY_VESSEL_ASSIGNED")
	var belt_surveyed := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.state.location_state("asteroid_belt").get("survey_state", "")) == LocationState.SURVEYED,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(belt_surveyed, "Pathfinder completes the material-backed SURVEYED stage and deploys finite staging capacity")
	if belt_surveyed:
		journey_event_log.append("FIRST_REMOTE_SURVEY")
		_record_registry_event("JOURNEY_07_SURVEY", "SURVEY_COMPLETED")
		_record_registry_event("JOURNEY_08_REMOTE_INDUSTRY", "REMOTE_SITE_SURVEYED")
	await _press_named(main, "LocationTab_resources", "OPEN_BELT_RESOURCE_DATA")
	_record_registry_event("JOURNEY_07_SURVEY", "RESOURCE_DATA_OPENED")

	# Install the real Foundry capability, fabricate the Pathfinder's complete
	# desired loadout BOM, and execute a Starport refit before Belt extraction.
	await _open_location_from_system(main, SpaceGameState.MAIN_BASE_LOCATION_ID)
	_check(await _ensure_ui_costs_stable(main, {"iron_ingot":4, "electronics":2}), "UI industry supplies the Precision Mechanics Cell")
	await _open_industry_production(main)
	# Manufacturing refits are intentionally blocked while any line in the
	# target facility is RUNNING or BLOCKED. Stop every player-visible line
	# before pressing the normal module-install control; this is the same
	# recovery a player performs from the Industry page.
	await _stop_all_visible_industry_lines(main)
	await _open_industry_facilities(main)
	await _press_named(main, "InstallManufacturingModule_orbital_foundry_precision_mechanics_cell_process", "INSTALL_PRECISION_MECHANICS_CELL")
	_check(_facility_has_process_module("orbital_foundry", "precision_mechanics_cell"), "visible manufacturing-module control installs precision mechanics")
	var pathfinder_ship := Game.state.ship_by_id(pathfinder_id)
	var desired_loadout: Array = Game.state.ship_module_definition_ids(pathfinder_ship)
	desired_loadout.append("deep_core_drill")
	var refit_costs: Dictionary = Game.simulation.loadout_fabrication_costs(desired_loadout)
	_check(await _ensure_ui_costs_stable(main, refit_costs), "UI industry supplies the canonical full-loadout refit BOM")
	await _press_named(main, "Navigation_ships", "OPEN_SHIPS_FOR_DEEP_CORE_REFIT")
	var roster_after_shipyard := main.find_child("FleetSection_roster", true, false) as Button
	if roster_after_shipyard != null and not roster_after_shipyard.disabled:
		await _press_control(roster_after_shipyard, "OPEN_ROSTER_FOR_DEEP_CORE_REFIT")
	await _press_named(main, "InstallModule_%s_deep_core_drill" % pathfinder_id, "INSTALL_PATHFINDER_DEEP_CORE_DRILL")
	var deep_core_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return "deep_core_drill" in Game.state.ship_module_definition_ids(Game.state.ship_by_id(pathfinder_id)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(deep_core_ready, "visible Ship configuration control completes the physical Deep Core refit")

	await _press_named(main, "AssignMining_%s" % pathfinder_id, "ASSIGN_PATHFINDER_BELT_MINING")
	await _press_named(main, "Navigation_survey", "OPEN_SURVEY_FOR_BELT_EXTRACTION")
	await _press_named(main, "StartMining_belt_cobalt_frontier", "START_BELT_EXTRACTION")
	var belt_ore_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.completed_activities.get("extract_belt_mixed_ore", 0)) >= 1 \
			and Game.state.item_quantity("mixed_raw_ore", "asteroid_belt") >= 2,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(belt_ore_ready, "the surveyed Belt site produces conserved remote ore through the refitted Pathfinder")
	if not belt_ore_ready:
		_print_mining_diagnostic("belt_cobalt_frontier", pathfinder_id)
	if belt_ore_ready:
		journey_event_log.append("FIRST_REMOTE_EXTRACTION")

	# Bootstrap the normal multi-hop freight path. Dispatch operating costs are
	# real conserved items, so Earth first publishes propellant/repair supply and
	# the Belt requests them before it can export remote ore.
	await _open_location_from_system(main, SpaceGameState.MAIN_BASE_LOCATION_ID)
	_check(await _ensure_ui_costs_stable(main, {"chemical_propellant":12, "repair_material":5}), "UI industry manufactures freight operating stock for the Belt corridor")
	await _set_location_logistics_policy(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "chemical_propellant", LogisticsEngine.MODE_SUPPLY)
	await _set_location_logistics_policy(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "repair_material", LogisticsEngine.MODE_SUPPLY)
	await _set_location_logistics_policy(main, "asteroid_belt", "chemical_propellant", LogisticsEngine.MODE_DEMAND)
	await _set_location_logistics_policy(main, "asteroid_belt", "repair_material", LogisticsEngine.MODE_DEMAND)
	var belt_propellant_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.state.item_quantity("chemical_propellant", "asteroid_belt") >= 5,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(belt_propellant_ready, "normal freight delivers the first propellant operating stock to the remote source")
	if not belt_propellant_ready:
		_print_logistics_diagnostic(["chemical_propellant", "repair_material"])
	# A reserve-zero supply correctly exports all available propellant. Once the
	# remote fuel tranche lands, clear that fulfilled Demand through its visible
	# policy control, manufacture a new dispatch-cost tranche, and let the
	# maintenance Demand use it instead of creating a bootstrap deadlock.
	await _open_location_from_system(main, "asteroid_belt")
	await _press_named(main, "LocationTab_logistics", "OPEN_BELT_LOGISTICS_TO_CLEAR_PROPELLANT_DEMAND")
	await _press_named(main, "ClearLogisticsPolicy_asteroid_belt_chemical_propellant", "CLEAR_FULFILLED_BELT_PROPELLANT_DEMAND")
	await _open_location_from_system(main, SpaceGameState.MAIN_BASE_LOCATION_ID)
	_check(await _ensure_ui_item(main, "chemical_propellant", 6), "UI manufactures a second propellant tranche for maintenance dispatch costs")
	var belt_operating_stock_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.state.item_quantity("repair_material", "asteroid_belt") >= 3,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(belt_operating_stock_ready, "normal freight delivers maintenance stock after the fulfilled fuel Demand is cleared")
	if not belt_operating_stock_ready:
		_print_logistics_diagnostic(["chemical_propellant", "repair_material"])

	# The default Demand action targets max(50, current stock). Consume the large
	# local bootstrap pile first so the normal default creates a real deficit.
	await _open_location_from_system(main, SpaceGameState.MAIN_BASE_LOCATION_ID)
	_check(await _consume_ui_item_below(main, "separate_iron_ore", "mixed_raw_ore", 40), "visible Industry controls create a genuine Earth mixed-ore freight deficit")
	var mixed_delivered_before := int(Game.state.logistics_network.get("item_statistics", {}).get("mixed_raw_ore", {}).get("delivered", 0))
	await _set_location_logistics_policy(main, "asteroid_belt", "mixed_raw_ore", LogisticsEngine.MODE_SUPPLY)
	await _set_location_logistics_policy(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "mixed_raw_ore", LogisticsEngine.MODE_DEMAND)
	var belt_ore_delivered := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.logistics_network.get("item_statistics", {}).get("mixed_raw_ore", {}).get("delivered", 0)) > mixed_delivered_before,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(belt_ore_delivered, "Belt SUPPLY and Earth DEMAND dispatch and deliver conserved remote ore")
	if belt_ore_delivered:
		journey_event_log.append("FIRST_REMOTE_FREIGHT")

	# Process real Belt feedstock and establish both High-Energy manufacturing
	# capabilities required by the Heavy Industry program.
	_check(await _ensure_ui_item(main, "silicate_ore", 8), "UI separates imported Belt silicates")
	_check(await _ensure_ui_item(main, "silicate_ceramic", 1), "UI fires the first structural silicate ceramic")
	_check(await _install_process_module(main, "electronics_facility", "cryogenic_process_unit"), "visible Facilities control installs cryogenic processing")
	_check(await _install_process_module(main, "electronics_facility", "radiation_electronics_cell"), "visible Facilities control installs radiation electronics")
	_check(await _ensure_ui_item(main, "electronics", 1), "UI industry stages the Heavy Industry theory input")
	await _press_named(main, "Navigation_research", "OPEN_RESEARCH_FOR_HEAVY_INDUSTRY")
	await _press_named(main, "StartResearch_research_heavy_industry", "START_HEAVY_INDUSTRY_RESEARCH")
	var heavy_experiment_waiting := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_heavy_industry" \
			and String(Game.state.research.get("stage_id", "")) == "experiment",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(heavy_experiment_waiting, "Heavy Industry reaches its real Experiment material gate")
	_check(await _ensure_ui_research_stage_costs(main, "research_heavy_industry", "experiment"), "UI industry supplies the Heavy Industry Experiment")
	var heavy_experiment_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return bool(Game.state.technology_spillovers.get("high_field_superconductors", false)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(heavy_experiment_ready, "Heavy Industry reaches its material-test spillover through real staged inputs")
	var heavy_engineering_waiting := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_heavy_industry" \
			and String(Game.state.research.get("stage_id", "")) == "engineering",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(heavy_engineering_waiting, "Heavy Industry reaches its real Precision Engineering stage")
	_check(await _ensure_ui_research_stage_costs(main, "research_heavy_industry", "engineering"), "UI industry supplies the Heavy Industry engineering gate")
	var heavy_prototype_waiting := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_heavy_industry" \
			and String(Game.state.research.get("stage_id", "")) == "prototype",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(heavy_prototype_waiting, "Heavy Industry reaches its real physical Prototype gate")
	_check(await _ensure_ui_research_stage_costs(main, "research_heavy_industry", "prototype"), "UI manufactures the physical Heavy Industry prototype")
	var heavy_industrialization_waiting := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.state.research.get("project_id", "")) == "research_heavy_industry" \
			and String(Game.state.research.get("stage_id", "")) == "industrialization",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(heavy_industrialization_waiting, "Heavy Industry reaches its industrial release gate")
	_check(await _ensure_ui_research_stage_costs(main, "research_heavy_industry", "industrialization"), "UI industry supplies the Heavy Industry industrialization package")
	var heavy_industry_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return bool(Game.state.technologies.get("heavy_industry", false)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(heavy_industry_ready, "visible Research completes the full Heavy Industry program")

	_check(await _ensure_ui_costs_stable(main, {"silicate_ore":6, "titanium_alloy":3}), "UI stages the real Heavy Extraction research package")
	await _press_named(main, "Navigation_research", "OPEN_RESEARCH_FOR_HEAVY_EXTRACTION")
	await _press_named(main, "StartResearch_research_heavy_extraction", "START_HEAVY_EXTRACTION_RESEARCH")
	var heavy_extraction_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return bool(Game.state.technologies.get("heavy_extraction", false)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	_check(heavy_extraction_ready, "visible Research unlocks legal cobalt separation")
	if heavy_industry_ready and heavy_extraction_ready:
		journey_event_log.append("FIRST_ADVANCED_INDUSTRY_RESEARCH")
		_record_registry_event("JOURNEY_09_ADVANCED_INDUSTRY", "ADVANCED_TECHNOLOGY_UNLOCKED")

	_check(await _ensure_ui_item(main, "cobalt_ingot", 1), "UI separates and refines imported Belt cobalt")
	_check(await _install_process_module(main, "orbital_foundry", "advanced_alloy_cell"), "visible Facilities control installs the Advanced Alloy Cell")
	if _facility_has_process_module("orbital_foundry", "advanced_alloy_cell"):
		_record_registry_event("JOURNEY_09_ADVANCED_INDUSTRY", "ADVANCED_METHOD_ADOPTED")
	var first_steel_ready := await _ensure_ui_item(main, "steel_composite", 1)
	_check(first_steel_ready, "strict fresh-save UI-only play reaches FIRST_STEEL through the legal cobalt/silicate chain")
	if first_steel_ready:
		journey_event_log.append("FIRST_STEEL")
		_record_registry_event("JOURNEY_01_EARLY_INDUSTRY", "FIRST_STEEL")
		_record_registry_event("JOURNEY_02_CAPITAL_EXPANSION", "FIRST_STEEL")
		await _open_industry_production(main)
		await _capture_playthrough_milestone(main, "03_first_steel")
	var endgame_ready := await _complete_remaining_ui_journey(main, starter_ship_id, pathfinder_id)
	_check(endgame_ready, "the same strict fresh-save UI-only run completes the single-system endgame")

	await _visit_core_screens_for_telemetry(main)
	await _press_named(main, "SpeedPause", "PAUSE_GAME")
	_check(is_zero_approx(Engine.time_scale), "the visible Pause speed control stops simulation time")
	_check(fast_forward_backlog_ms < 5000.0, "100x online orchestration drains its simulation backlog instead of leaving unprocessed time")
	_check(String((main.find_child("HeaderStatus", true, false) as Label).text) != initial_header_text, "Top Status Bar visibly refreshes after accelerated online simulation")
	_assert_journey_evidence(main)
	_finish(main)


func _visit_core_screens_for_telemetry(main: Control) -> void:
	# The certification trace must prove that every core player surface is
	# reachable from the live shell, not merely that its scene exists in source.
	# These are ordinary visible Navigation controls exercised after the same
	# fresh save has unlocked and completed the endgame.
	var core_navigation := [
		{"button":"Navigation_system_map", "action":"VERIFY_SCREEN_SYSTEM"},
		{"button":"Navigation_location", "action":"VERIFY_SCREEN_LOCATION"},
		{"button":"Navigation_industry", "action":"VERIFY_SCREEN_INDUSTRY"},
		{"button":"Navigation_inventory", "action":"VERIFY_SCREEN_INVENTORY"},
		{"button":"Navigation_logistics", "action":"VERIFY_SCREEN_LOGISTICS"},
		{"button":"Navigation_construction", "action":"VERIFY_SCREEN_CONSTRUCTION"},
		{"button":"Navigation_research", "action":"VERIFY_SCREEN_RESEARCH"},
		{"button":"Navigation_ships", "action":"VERIFY_SCREEN_SHIPS"},
		{"button":"Navigation_survey", "action":"VERIFY_SCREEN_SURVEY"},
		{"button":"Navigation_megastructure", "action":"VERIFY_SCREEN_MEGASTRUCTURE"},
		{"button":"Navigation_diagnostics", "action":"VERIFY_SCREEN_DIAGNOSTICS"}
	]
	for entry_value in core_navigation:
		var entry := entry_value as Dictionary
		await _press_named(main, String(entry.get("button", "")), String(entry.get("action", "")))


func _complete_remaining_ui_journey(main: Control, starter_ship_id: String, pathfinder_id: String) -> bool:
	# Finish the Lunar combat gate that is independent from the earlier peaceful
	# navigation route, then establish the complete Tier-II construction base.
	if not await _prepare_route_supplies_ui(main, 120, 20, 80): return false
	if not await _complete_route_ui(main, "lunar_relay_assault", [starter_ship_id]): return false
	journey_event_log.append("LUNAR_DEMONSTRATION_COMPLETED")
	if not await _ensure_ui_item(main, "industrial_machine_tools", Game.state.item_quantity("industrial_machine_tools", SpaceGameState.MAIN_BASE_LOCATION_ID) + 1): return false
	_record_registry_event("JOURNEY_02_CAPITAL_EXPANSION", "INDUSTRIAL_MACHINE_TOOLS")
	if not await _ensure_ui_item(main, "heavy_structural_section", Game.state.item_quantity("heavy_structural_section", SpaceGameState.MAIN_BASE_LOCATION_ID) + 1): return false
	_record_registry_event("JOURNEY_02_CAPITAL_EXPANSION", "HEAVY_STRUCTURAL_SECTIONS")
	if not await _complete_construction_activity_ui(main, "upgrade_construction_yard_ii"): return false
	_record_registry_event("JOURNEY_02_CAPITAL_EXPANSION", "CONSTRUCTION_STARTED")
	_record_registry_event("JOURNEY_02_CAPITAL_EXPANSION", "FACILITY_UPGRADED")
	for activity_id in ["build_assembly_yard", "build_repair_dock", "upgrade_starport_ii"]:
		if not await _complete_construction_activity_ui(main, activity_id): return false
	if not await _install_process_module(main, "assembly_yard", "photonic_integration_line"): return false
	if not await _ensure_ui_item(main, "quantum_component", 1): return false
	journey_event_log.append("CAPITAL_EXPANSION_COMPLETED")

	var cruiser_id := await _develop_and_build_ship_ui(main, "develop_belt_cruiser", "construct_belt_cruiser", "belt_cruiser")
	if cruiser_id.is_empty(): return false
	var bulk_freighter_id := await _develop_and_build_ship_ui(main, "develop_bulk_freighter", "construct_bulk_freighter", "bulk_freighter")
	if bulk_freighter_id.is_empty(): return false
	var survey_ship_id := await _develop_and_build_ship_ui(main, "develop_deep_survey_vessel", "construct_deep_survey_vessel", "deep_survey_vessel")
	if survey_ship_id.is_empty(): return false
	journey_event_log.append("SHIP_INDUSTRY_ESTABLISHED")
	if not await _exercise_bottleneck_journeys_ui(main, bulk_freighter_id): return false

	if not await _develop_remote_site_ui(main, "asteroid_belt", "belt_cobalt_frontier", "fixed_excavation"): return false
	if not await _expand_remote_industry_ui(main, "asteroid_belt", "makeshift_workshop"): return false
	journey_event_log.append("FIRST_REMOTE_SITE")
	_record_registry_event("JOURNEY_08_REMOTE_INDUSTRY", "REMOTE_EXTRACTION_STARTED")
	if int(Game.state.logistics_network.get("item_statistics", {}).get("mixed_raw_ore", {}).get("delivered", 0)) > 0:
		_record_registry_event("JOURNEY_08_REMOTE_INDUSTRY", "REMOTE_LOGISTICS_ACTIVE")
	var maintenance_pressure := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.simulation._location_maintenance_coverage(Game.state, "asteroid_belt") < 1.0,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not maintenance_pressure: return _journey_fail("developed Belt industry never exposed real maintenance pressure")
	_record_registry_event("JOURNEY_08_REMOTE_INDUSTRY", "REMOTE_MAINTENANCE_PRESSURE")
	_record_registry_event("JOURNEY_09_ADVANCED_INDUSTRY", "INDUSTRIAL_GEOGRAPHY_CHANGED")
	await _open_location_from_system(main, "asteroid_belt")
	await _press_named(main, "LocationTab_industry", "OPEN_BELT_INDUSTRY_FOR_MILESTONE_CAPTURE")
	await _capture_playthrough_milestone(main, "06_remote_base")
	if not await _complete_route_ui(main, "belt_flagship_route", [pathfinder_id, cruiser_id]): return false
	journey_event_log.append("BELT_FLAGSHIP_DEFEATED")

	if not await _complete_route_ui(main, "jovian_route", [starter_ship_id, pathfinder_id, cruiser_id]): return false
	if not await _survey_location_to_ui(main, "gas_giant_region", LocationState.SURVEYED, pathfinder_id): return false
	if not await _uninstall_process_module_ui(main, "electronics_facility", "cryogenic_process_unit"): return false
	if not await _complete_research_program_ui(main, "research_jovian_operations"): return false
	if not await _complete_research_program_ui(main, "research_capital_combat"): return false
	if not await _complete_construction_activity_ui(main, "upgrade_starport_iii"): return false
	var constructor_id := await _develop_and_build_ship_ui(main, "develop_mobile_constructor", "construct_mobile_constructor", "mobile_constructor")
	if constructor_id.is_empty(): return false
	var battleship_id := await _develop_and_build_ship_ui(main, "develop_jovian_battleship", "construct_jovian_battleship", "jovian_battleship")
	if battleship_id.is_empty(): return false
	if not await _install_ship_module_ui(main, cruiser_id, "gas_collector"): return false
	if not await _mine_and_freight_ui(main, "gas_giant_region", "jovian_cloud_frontier", cruiser_id, "mixed_raw_gas", 24): return false
	if not await _ensure_ui_item(main, "methane", 2): return false
	if not await _ensure_ui_item(main, "superalloy", 8): return false
	journey_event_log.append("JOVIAN_INDUSTRY_COMPLETED")
	await _open_industry_production(main)
	await _capture_playthrough_milestone(main, "07_advanced_industry")

	if not await _complete_route_ui(main, "outer_route", [battleship_id]): return false
	if not await _survey_location_to_ui(main, "outer_system", LocationState.SURVEYED, survey_ship_id): return false
	if not await _complete_research_program_ui(main, "research_exotic_materials"): return false
	if not await _complete_construction_activity_ui(main, "upgrade_construction_yard_iii"): return false
	if not await _complete_construction_activity_ui(main, "build_field_engineering_complex"): return false
	if not await _ensure_ui_item(main, "exotic_crystal", 1): return false
	if not await _complete_research_program_ui(main, "research_antimatter"): return false
	if not await _ensure_ui_item(main, "antimatter_cell", 3): return false
	if not await _complete_research_program_ui(main, "research_exotic_containment"): return false
	if not await _complete_construction_activity_ui(main, "build_command_array"): return false
	if not await _complete_construction_activity_ui(main, "upgrade_starport_iv"): return false
	var titan_id := await _develop_and_build_ship_ui(main, "develop_outer_titan", "construct_outer_titan", "outer_titan")
	if titan_id.is_empty(): return false
	if not await _complete_route_ui(main, "deep_system_route", [titan_id]): return false
	if not await _survey_location_to_ui(main, "deep_system", LocationState.SURVEYED, survey_ship_id): return false
	if not await _remove_ship_module_ui(main, titan_id, "targeting_computer"): return false
	if not await _install_ship_module_ui(main, titan_id, "exotic_containment"): return false
	if not await _install_ship_module_ui(main, titan_id, "heavy_mining_array"): return false
	if not await _mine_and_freight_ui(main, "deep_system", "deep_matter_frontier", titan_id, "mixed_raw_gas", 32): return false
	if not await _complete_construction_activity_ui(main, "build_frontier_matterworks"): return false
	if not await _ensure_ui_item(main, "dark_matter", 2): return false
	if not await _complete_construction_activity_ui(main, "upgrade_research_complex"): return false
	journey_event_log.append("DEEP_SYSTEM_INDUSTRY_COMPLETED")

	# Pre-build the process-limited stellar stock before the Megastructure program.
	if not await _uninstall_process_module_ui(main, "electronics_facility", "fusion_component_test_rig"): return false
	if not await _install_process_module(main, "electronics_facility", "cryogenic_process_unit"): return false
	if not await _ensure_ui_item(main, "superconducting_coil", 150): return false
	if not await _uninstall_process_module_ui(main, "electronics_facility", "cryogenic_process_unit"): return false
	if not await _install_process_module(main, "electronics_facility", "fusion_component_test_rig"): return false
	if not await _ensure_ui_item(main, "fusion_service_component", 40): return false
	if not await _survey_location_to_ui(main, "earth_sun_lagrange", LocationState.DEEP_SURVEYED, survey_ship_id): return false
	if not await _complete_research_program_ui(main, "research_megastructures"): return false
	journey_event_log.append("MEGASTRUCTURE_RESEARCHED")
	_record_registry_event("JOURNEY_10_MEGASTRUCTURE", "MEGASTRUCTURE_RESEARCHED")
	await _press_named(main, "Navigation_megastructure", "OPEN_MEGASTRUCTURE_SITE_SELECTION")
	await _press_named(main, "SelectMegastructureSite_earth_sun_lagrange", "SELECT_STELLAR_ENERGY_SITE")
	if int(Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_index", 0)) != 1:
		return _journey_fail("visible site selection did not record the site-selection phase")
	journey_event_log.append("MEGASTRUCTURE_SITE_SELECTED")
	_record_registry_event("JOURNEY_10_MEGASTRUCTURE", "SITE_SELECTED")
	if not await _complete_megastructure_ui(main): return false
	journey_event_log.append("MEGASTRUCTURE_COMPLETED")
	_record_registry_event("JOURNEY_10_MEGASTRUCTURE", "MEGASTRUCTURE_COMPLETED")
	return true


func _complete_construction_activity_ui(main: Control, activity_id: String) -> bool:
	if int(Game.state.completed_activities.get(activity_id, 0)) > 0:
		return true
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	if activity.is_empty():
		return _journey_fail("missing construction definition %s" % activity_id)
	if not await _ensure_ui_costs_stable(main, _cost_dictionary(activity.get("costs", []))):
		return false
	await _open_industry_construction(main)
	await _press_named(main, "StartConstruction_%s" % activity_id, "START_CONSTRUCTION_%s" % activity_id.to_upper())
	var completed := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.completed_activities.get(activity_id, 0)) > 0,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not completed:
		_print_time_orchestration_diagnostic(activity_id)
		return _journey_fail("visible Construction did not complete %s" % activity_id)
	return true


func _complete_research_program_ui(main: Control, project_id: String) -> bool:
	if bool(Game.state.completed_projects.get(project_id, false)):
		return true
	var project: Dictionary = Game.content.research_projects.get(project_id, {})
	var initial_stage: Dictionary = Game.simulation.research_stage_definition(Game.state, project, 0, Game.simulation.default_research_route_id(project))
	for requirement_value in initial_stage.get("requirements", []):
		var requirement := requirement_value as Dictionary
		if not Game.simulation.requirement_met(Game.state, requirement) and not await _satisfy_research_requirement_ui(main, requirement):
			return _journey_fail("UI cannot prepare initial Research requirement %s / %s" % [project_id, str(requirement)])
	if not await _ensure_ui_costs_stable(main, _cost_dictionary(initial_stage.get("costs", []))):
		return false
	await _press_named(main, "Navigation_research", "OPEN_RESEARCH_FOR_%s" % project_id.to_upper())
	await _press_named(main, "StartResearch_%s" % project_id, "START_RESEARCH_%s" % project_id.to_upper())
	for stage_pass in 32:
		if bool(Game.state.completed_projects.get(project_id, false)):
			return true
		if String(Game.state.research.get("project_id", "")) != project_id:
			return _journey_fail("Research UI lost active project %s at pass %d" % [project_id, stage_pass])
		var stage_index := int(Game.state.research.get("stage_index", 0))
		var stage_id := String(Game.state.research.get("stage_id", ""))
		var stage: Dictionary = Game.simulation.research_stage_definition(Game.state, project, stage_index, String(Game.state.research.get("route_id", "")))
		for requirement_value in stage.get("requirements", []):
			var requirement := requirement_value as Dictionary
			if Game.simulation.requirement_met(Game.state, requirement):
				continue
			if not await _satisfy_research_requirement_ui(main, requirement):
				return _journey_fail("UI cannot satisfy %s / %s requirement %s" % [project_id, stage_id, str(requirement)])
		if not await _ensure_ui_research_stage_costs(main, project_id, stage_id):
			return false
		var advanced := await _wait_at_public_fast_speed(main, func() -> bool:
			return bool(Game.state.completed_projects.get(project_id, false)) \
				or String(Game.state.research.get("stage_id", "")) != stage_id,
			JOURNEY_STAGE_TIMEOUT_SECONDS)
		if not advanced:
			print("FULL_GAMEPLAY_UI_RESEARCH_TIMEOUT=", JSON.stringify({"project":project_id, "stage":stage, "runtime":Game.state.research.duplicate(true)}))
			return _journey_fail("Research stage did not advance through normal time: %s / %s" % [project_id, stage_id])
	return _journey_fail("Research exceeded stage guard: %s" % project_id)


func _satisfy_research_requirement_ui(main: Control, requirement: Dictionary) -> bool:
	match String(requirement.get("type", "")):
		"item":
			return await _ensure_ui_item(main, String(requirement.get("id", "")), int(requirement.get("quantity", 1)))
		"activity_complete":
			return await _run_industry_activity_once_ui(main, String(requirement.get("id", "")))
		"route_complete":
			var route_id := String(requirement.get("id", ""))
			var candidates := _docked_route_candidates_read_only(route_id)
			return not candidates.is_empty() and await _complete_route_ui(main, route_id, candidates)
		"manufacturing_module_installed":
			return await _install_process_module(main, String(requirement.get("facility", "")), String(requirement.get("id", "")))
		"own_facility":
			var build_id := _construction_activity_for_facility(String(requirement.get("id", "")))
			return not build_id.is_empty() and await _complete_construction_activity_ui(main, build_id)
		_:
			return Game.simulation.requirement_met(Game.state, requirement)


func _ensure_ui_research_stage_costs(main: Control, project_id: String, stage_id: String) -> bool:
	for attempt in 16:
		if bool(Game.state.completed_projects.get(project_id, false)):
			return true
		if String(Game.state.research.get("project_id", "")) != project_id:
			return _journey_fail("Research UI lost active project while supplying stage costs: %s / %s" % [project_id, stage_id])
		if String(Game.state.research.get("stage_id", "")) != stage_id:
			return true
		var project: Dictionary = Game.content.research_projects.get(project_id, {})
		var stage: Dictionary = Game.simulation.research_stage_definition(
			Game.state,
			project,
			int(Game.state.research.get("stage_index", 0)),
			String(Game.state.research.get("route_id", "")))
		var costs := _cost_dictionary(stage.get("costs", []))
		var shortages := {}
		var consumed_targets := {}
		for item_id_value in costs.keys():
			var item_id := String(item_id_value)
			var total := int(costs[item_id])
			var outstanding := maxi(0, total - int(Game.state.research.get("stage_consumed", {}).get(item_id, 0)))
			var usable := Game.state.available_item_quantity_for_research(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
			var shortage := maxi(0, outstanding - usable)
			if shortage > 0:
				shortages[item_id] = shortage
				consumed_targets[item_id] = total
		if shortages.is_empty():
			return true
		var stage_complete := func() -> bool:
			return bool(Game.state.completed_projects.get(project_id, false)) \
				or String(Game.state.research.get("project_id", "")) != project_id \
				or String(Game.state.research.get("stage_id", "")) != stage_id
		var stage_consumed := func(item_id: String) -> int:
			if String(Game.state.research.get("project_id", "")) != project_id \
					or String(Game.state.research.get("stage_id", "")) != stage_id:
				return int(consumed_targets.get(item_id, 0))
			return int(Game.state.research.get("stage_consumed", {}).get(item_id, 0))
		# The active Research reservation is a legitimate committed sink. Track its
		# Domain consumption ledger while visible Industry recipes run so a material
		# consumed on the same settlement boundary is not mistaken for failed output.
		if not await _ensure_ui_costs_stable(main, shortages, stage_complete, stage_consumed, consumed_targets):
			return false
		if bool(stage_complete.call()):
			return true
	return _journey_fail("active Research stage costs did not converge: %s / %s" % [project_id, stage_id])


func _run_industry_activity_once_ui(main: Control, activity_id: String) -> bool:
	if int(Game.state.completed_activities.get(activity_id, 0)) > 0:
		return true
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	if Game.simulation.is_construction_activity(activity):
		return await _complete_construction_activity_ui(main, activity_id)
	if not await _ensure_ui_costs_stable(main, _cost_dictionary(activity.get("costs", []))):
		return false
	await _open_industry_production(main)
	var before := int(Game.state.completed_activities.get(activity_id, 0))
	await _press_named(main, "StartIndustry_%s" % activity_id, "START_%s" % activity_id.to_upper())
	var completed := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.completed_activities.get(activity_id, 0)) > before,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	var stop_button := main.find_child("StopIndustry_%s" % activity_id, true, false) as Button
	if stop_button != null and stop_button.is_visible_in_tree() and not stop_button.disabled:
		await _press_control(stop_button, "STOP_%s_AFTER_ONE_CYCLE" % activity_id.to_upper())
	return completed or _journey_fail("visible Industry did not complete %s" % activity_id)


func _develop_and_build_ship_ui(main: Control, project_id: String, plan_id: String, blueprint_id: String) -> String:
	var existing := _ship_id_for_blueprint(blueprint_id)
	if not existing.is_empty():
		return existing
	var plan: Dictionary = Game.content.ship_construction_projects.get(plan_id, {})
	var costs: Dictionary = Game.simulation.ship_construction_material_totals(plan)
	for fixed_value in plan.get("fixed_costs", []):
		var fixed := fixed_value as Dictionary
		var item_id := String(fixed.get("item", ""))
		costs[item_id] = int(costs.get(item_id, 0)) + int(fixed.get("quantity", 0))
	if not await _ensure_ui_costs_stable(main, costs): return ""
	if not await _complete_research_program_ui(main, project_id): return ""
	if not await _ensure_ui_costs_stable(main, costs): return ""
	await _press_named(main, "Navigation_ships", "OPEN_SHIPYARD_FOR_%s" % blueprint_id.to_upper())
	await _press_named(main, "FleetSection_shipyard", "OPEN_SHIPYARD_SECTION_FOR_%s" % blueprint_id.to_upper())
	await _press_named(main, "BuildShip_%s_1" % plan_id, "BUILD_SHIP_%s" % blueprint_id.to_upper())
	var completed := await _wait_at_public_fast_speed(main, func() -> bool:
		return not _ship_id_for_blueprint(blueprint_id).is_empty(),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not completed:
		_journey_fail("visible Shipyard did not commission %s" % blueprint_id)
		return ""
	return _ship_id_for_blueprint(blueprint_id)


func _prepare_route_supplies_ui(main: Control, munitions: int, repair: int, propellant: int) -> bool:
	return await _ensure_ui_costs_stable(main, {
		"kinetic_munitions":munitions,
		"repair_supplies":repair,
		"chemical_propellant":propellant
	})


func _complete_route_ui(main: Control, route_id: String, ship_ids: Array) -> bool:
	if int(Game.state.completed_activities.get("route:%s" % route_id, 0)) > 0:
		return true
	var route: Dictionary = Game.content.expedition_routes.get(route_id, {})
	if not await _prepare_route_supplies_ui(main, 120, 20, maxi(20, int(route.get("fuel_cost", 0)))):
		return false
	await _press_named(main, "Navigation_ships", "OPEN_SHIPS_FOR_%s" % route_id.to_upper())
	var roster_button := main.find_child("FleetSection_roster", true, false) as Button
	if roster_button != null and not roster_button.disabled:
		await _press_control(roster_button, "OPEN_ROSTER_FOR_%s" % route_id.to_upper())
	for ship_id_value in ship_ids:
		await _press_named(main, "AssignExpedition_%s" % String(ship_id_value), "ASSIGN_%s_TO_%s" % [String(ship_id_value).to_upper(), route_id.to_upper()])
	await _press_named(main, "ShipsMissions", "OPEN_MISSIONS_FOR_%s" % route_id.to_upper())
	await _press_named(main, "StartRoute_%s" % route_id, "START_ROUTE_%s" % route_id.to_upper())
	var completed := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.completed_activities.get("route:%s" % route_id, 0)) > 0,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not completed:
		return _journey_fail("visible Expedition route did not complete %s" % route_id)
	return true


func _survey_location_to_ui(main: Control, location_id: String, target_state: String, preferred_ship_id: String = "") -> bool:
	var order: Array = Game.content.survey_rules.get("state_order", [LocationState.UNKNOWN, LocationState.DETECTED, LocationState.SURVEYED, LocationState.DEEP_SURVEYED])
	for next_state_value in order:
		var next_state := String(next_state_value)
		if Game.simulation.survey_state_rank(next_state) <= Game.simulation.survey_state_rank(String(Game.state.location_state(location_id).get("survey_state", LocationState.UNKNOWN))):
			continue
		if Game.simulation.survey_state_rank(next_state) > Game.simulation.survey_state_rank(target_state):
			break
		if not await _ensure_ui_costs_stable(main, Game.simulation.survey_mission_costs(next_state)):
			return false
		await _open_location_from_system(main, location_id)
		var ship_id := preferred_ship_id
		var named_button := main.find_child("StartSurvey_%s_%s_%s" % [location_id, next_state, ship_id], true, false) as Button
		if named_button == null or named_button.disabled:
			named_button = _first_enabled_button(main, "StartSurvey_%s_%s_" % [location_id, next_state])
		await _press_control(named_button, "START_SURVEY_%s_%s" % [location_id.to_upper(), next_state])
		var completed := await _wait_at_public_fast_speed(main, func() -> bool:
			return Game.simulation.survey_state_rank(String(Game.state.location_state(location_id).get("survey_state", LocationState.UNKNOWN))) >= Game.simulation.survey_state_rank(next_state),
			JOURNEY_STAGE_TIMEOUT_SECONDS)
		if not completed:
			return _journey_fail("visible Survey did not reach %s at %s" % [next_state, location_id])
	return true


func _develop_remote_site_ui(main: Control, location_id: String, site_id: String, method_id: String) -> bool:
	if bool(Game.state.mining_site_states.get(site_id, {}).get("developed", false)):
		return true
	await _open_location_from_system(main, location_id)
	await _press_named(main, "LocationTab_resources", "OPEN_%s_RESOURCES_FOR_SITE_DEVELOPMENT" % location_id.to_upper())
	await _press_named(main, "DevelopSite_%s_%s" % [site_id, method_id], "START_SITE_DEVELOPMENT_%s" % site_id.to_upper())
	_record_registry_event("JOURNEY_07_SURVEY", "SITE_DEVELOPMENT_STARTED")
	var completed := await _supply_remote_construction_ui(main, location_id, "SITE_DEVELOPMENT", site_id, func() -> bool:
		return bool(Game.state.mining_site_states.get(site_id, {}).get("developed", false)))
	if not completed: return false
	_record_registry_event("JOURNEY_08_REMOTE_INDUSTRY", "REMOTE_SITE_DEVELOPED")
	var location: Dictionary = Game.state.location_state(location_id)
	if float(Game.simulation.location_storage_snapshot(Game.state, location_id).get("capacity", 0.0)) > 0.0:
		_record_registry_event("JOURNEY_08_REMOTE_INDUSTRY", "REMOTE_STORAGE_BUILT")
	if float(location.get("industry", {}).get("power_capacity", 0.0)) > 0.0:
		_record_registry_event("JOURNEY_08_REMOTE_INDUSTRY", "REMOTE_POWER_BUILT")
	return true


func _exercise_bottleneck_journeys_ui(main: Control, bulk_freighter_id: String) -> bool:
	_record_registry_event("JOURNEY_03_LOGISTICS_BOTTLENECK", "PRODUCTION_INCREASED")
	# Keep a genuine Belt export backlog active until the default infrastructure
	# service consumes its whole dispatch budget.
	await _replace_policy_ui(main, "asteroid_belt", "mixed_raw_ore", LogisticsEngine.MODE_SUPPLY)
	await _replace_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "mixed_raw_ore", LogisticsEngine.MODE_DEMAND)
	var saturated := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.simulation.logistics.service_snapshot(Game.state, "lunar_belt_freight").get("status", "")) == "SATURATED",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not saturated:
		return _journey_fail("real Belt export pressure did not saturate lunar_belt_freight")
	_record_registry_event("JOURNEY_03_LOGISTICS_BOTTLENECK", "ROUTE_SATURATED")
	await _press_named(main, "Navigation_logistics", "OPEN_LOGISTICS_FOR_BOTTLENECK_CAPTURE")
	await _capture_playthrough_milestone(main, "04_logistics_bottleneck")
	await _press_named(main, "Navigation_diagnostics", "OPEN_DIAGNOSTICS_FOR_ROUTE_SATURATION")
	var why_button := _first_enabled_button(main, "BlockerWhy_")
	var why_available := why_button != null
	await _press_control(why_button, "OPEN_ROUTE_SATURATION_ROOT_CAUSE")
	if not why_available:
		return _journey_fail("Diagnostics did not expose a clickable root cause for saturated freight")
	_record_registry_event("JOURNEY_03_LOGISTICS_BOTTLENECK", "ROOT_CAUSE_OPENED")
	var capacity_before: float = Game.simulation.logistics.service_capacity(Game.state, "lunar_belt_freight")
	await _open_location_from_system(main, "asteroid_belt")
	await _press_named(main, "LocationTab_logistics", "OPEN_BELT_LOGISTICS_FOR_BULK_UPGRADE")
	await _press_named(main, "TransportMode_lunar_belt_freight_bulk_tug", "UPGRADE_BELT_ROUTE_TO_BULK_TUG")
	var assign_bulk := main.find_child("AssignLogisticsShip_lunar_belt_freight_%s" % bulk_freighter_id, true, false) as Button
	if assign_bulk != null and not assign_bulk.disabled:
		await _press_control(assign_bulk, "ASSIGN_BULK_FREIGHTER_TO_BELT_ROUTE")
	var capacity_after: float = Game.simulation.logistics.service_capacity(Game.state, "lunar_belt_freight")
	if capacity_after <= capacity_before:
		return _journey_fail("visible bulk transport upgrade did not increase route capacity")
	_record_registry_event("JOURNEY_03_LOGISTICS_BOTTLENECK", "LOGISTICS_CAPACITY_INCREASED")
	_record_registry_event("JOURNEY_04_BOTTLENECK_SHIFT", "LOGISTICS_UPGRADED")
	await _clear_policy_ui(main, "asteroid_belt", "mixed_raw_ore")
	await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "mixed_raw_ore")
	var resolved := await _wait_at_public_fast_speed(main, func() -> bool:
		return String(Game.simulation.logistics.service_snapshot(Game.state, "lunar_belt_freight").get("status", "")) != "SATURATED",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not resolved: return _journey_fail("bulk capacity did not resolve the observed route bottleneck")
	_record_registry_event("JOURNEY_03_LOGISTICS_BOTTLENECK", "BOTTLENECK_RESOLVED")

	# With freight fixed, deliberately leave the advanced Foundry without remote
	# cobalt. The resulting Domain blocker must become visible before expansion.
	await _open_industry_production(main)
	await _press_named(main, "StartIndustry_refine_steel", "START_STEEL_TO_EXPOSE_FOUNDRY_LIMIT")
	var foundry_limited := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.simulation.production_gameplay_state(Game.state, _industry_runtime("refine_steel")) == "BLOCKED_INPUT",
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not foundry_limited: return _journey_fail("Foundry did not expose the expected input bottleneck after Logistics upgrade")
	_record_registry_event("JOURNEY_04_BOTTLENECK_SHIFT", "FOUNDRY_LIMITED")
	var old_level := int(Game.state.location_industry(SpaceGameState.MAIN_BASE_LOCATION_ID, "orbital_foundry").get("level", 0))
	var expansion_costs: Dictionary = Game.simulation.industry_expansion_costs(Game.state, SpaceGameState.MAIN_BASE_LOCATION_ID, "orbital_foundry", 1)
	if not await _ensure_ui_costs_stable(main, expansion_costs): return false
	await _open_location_from_system(main, SpaceGameState.MAIN_BASE_LOCATION_ID)
	await _press_named(main, "LocationTab_industry", "OPEN_EARTH_INDUSTRY_FOR_FOUNDRY_UPGRADE")
	await _press_named(main, "ExpandIndustry_orbital_foundry_1", "UPGRADE_FOUNDRY_AFTER_LOGISTICS")
	var upgraded := await _wait_at_public_fast_speed(main, func() -> bool:
		return int(Game.state.location_industry(SpaceGameState.MAIN_BASE_LOCATION_ID, "orbital_foundry").get("level", 0)) > old_level,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	if not upgraded: return _journey_fail("visible Foundry expansion did not complete")
	_record_registry_event("JOURNEY_04_BOTTLENECK_SHIFT", "FOUNDRY_UPGRADED")
	if Game.simulation.production_gameplay_state(Game.state, _industry_runtime("refine_steel")) != "BLOCKED_INPUT":
		return _journey_fail("post-upgrade Foundry did not reveal remote extraction as the shifted constraint")
	_record_registry_event("JOURNEY_04_BOTTLENECK_SHIFT", "EXTRACTION_LIMITED")
	await _open_industry_production(main)
	var stop_steel := main.find_child("StopIndustry_refine_steel", true, false) as Button
	if stop_steel != null and not stop_steel.disabled:
		await _press_control(stop_steel, "STOP_STEEL_AFTER_BOTTLENECK_SHIFT")
	return true


func _expand_remote_industry_ui(main: Control, location_id: String, facility_id: String) -> bool:
	var before := int(Game.state.location_industry(location_id, facility_id).get("level", 0))
	await _open_location_from_system(main, location_id)
	await _press_named(main, "LocationTab_industry", "OPEN_%s_INDUSTRY_FOR_EXPANSION" % location_id.to_upper())
	await _press_named(main, "ExpandIndustry_%s_1" % facility_id, "EXPAND_%s_AT_%s" % [facility_id.to_upper(), location_id.to_upper()])
	return await _supply_remote_construction_ui(main, location_id, "FACILITY_EXPANSION", facility_id, func() -> bool:
		return int(Game.state.location_industry(location_id, facility_id).get("level", 0)) > before)


func _supply_remote_construction_ui(main: Control, location_id: String, project_type: String, target_id: String, completion: Callable) -> bool:
	var runtime := _active_construction_runtime_read_only(location_id, project_type, target_id)
	if runtime.is_empty():
		return _journey_fail("remote project was not registered: %s / %s" % [project_type, target_id])
	if project_type in ["BULK_STORAGE_UPGRADE", "COMPONENT_STORAGE_UPGRADE", "FLUID_STORAGE_UPGRADE", "SPECIAL_STORAGE_UPGRADE", "POWER_UPGRADE", "COOLING_UPGRADE", "STRUCTURE_UPGRADE", "LOGISTICS_HUB_UPGRADE"]:
		# Capacity projects unblock the active industrial/megaproject queue. Raise
		# them through the normal Construction priority control so shared committed
		# demand sends scarce capital goods to the bottleneck first.
		await _open_industry_construction(main)
		var priority_button := main.find_child("ConstructionPriority_%s_100" % String(runtime.get("project_id", "")), true, false) as Button
		if priority_button != null and priority_button.is_visible_in_tree() and not priority_button.disabled:
			await _press_control(priority_button, "PRIORITIZE_%s_AT_%s" % [project_type, location_id.to_upper()])
		runtime = _active_construction_runtime_read_only(location_id, project_type, target_id)
	var plan: Dictionary = runtime.get("material_plan", {}).duplicate(true)
	# Establish the physical route's operating stock first. Its production can
	# consume ordinary components, so the project BOM is manufactured afterwards.
	# Freight dispatch costs are paid at the shipment origin. Keep propellant and
	# maintenance stock at Earth so the tiny pre-base Component depot remains
	# available for balanced Construction tranches.
	# Manufacture against project-specific remaining delivery. Ordinary O&M and
	# concurrent committed demand can legitimately consume a small part of a long
	# capital batch, so replenish the *new remaining BOM* in bounded tranches. A
	# non-progressing tranche fails with a diagnostic instead of looping forever.
	var project_material_progress := func(item_id: String) -> int:
		if bool(completion.call()):
			return int(plan.get(item_id, 0))
		var active := _active_construction_runtime_read_only(location_id, project_type, target_id)
		if active.is_empty():
			return 0
		return _construction_material_progress(active, item_id)
	var completed := bool(completion.call())
	var previous_project_cycles := int(runtime.get("project_cycles_completed", 0))
	for supply_attempt in 6:
		if completed:
			break
		var active := _active_construction_runtime_read_only(location_id, project_type, target_id)
		if active.is_empty():
			break
		var remaining_plan := _construction_remaining_material_plan(active)
		var planned_dispatches := _construction_dispatch_count_read_only(location_id, remaining_plan)
		if not await _stage_remote_operating_stock_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, planned_dispatches, location_id):
			break
		# Keep final project-material supply closed while manufacturing this
		# dependency-complete tranche. Several final goods are also inputs to later
		# final goods; dispatching them early would correctly make those Industry
		# start buttons unavailable. The project's committed destination demand is
		# sufficient once the whole tranche has been produced.
		if location_id != SpaceGameState.MAIN_BASE_LOCATION_ID:
			for item_id_value in plan.keys():
				await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, String(item_id_value))
		var local_sink_progress := project_material_progress if location_id == SpaceGameState.MAIN_BASE_LOCATION_ID else Callable()
		var local_sink_targets := plan if location_id == SpaceGameState.MAIN_BASE_LOCATION_ID else {}
		var manufactured := await _ensure_ui_costs_stable(main, remaining_plan, completion, local_sink_progress, local_sink_targets)
		if not manufactured and not bool(completion.call()):
			break
		active = _active_construction_runtime_read_only(location_id, project_type, target_id)
		if not active.is_empty() and not bool(completion.call()):
			var remaining_after_manufacturing := _construction_remaining_material_plan(active)
			var remaining_dispatches := _construction_dispatch_count_read_only(location_id, remaining_after_manufacturing)
			if not await _stage_remote_operating_stock_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, remaining_dispatches, location_id):
				break
			if location_id != SpaceGameState.MAIN_BASE_LOCATION_ID:
				for item_id_value in plan.keys():
					await _replace_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, String(item_id_value), LogisticsEngine.MODE_SUPPLY)
		completed = await _wait_at_public_fast_speed(main, completion, LARGE_BATCH_TIMEOUT_SECONDS)
		if completed:
			break
		active = _active_construction_runtime_read_only(location_id, project_type, target_id)
		var current_project_cycles := int(active.get("project_cycles_completed", 0))
		if current_project_cycles <= previous_project_cycles:
			break
		previous_project_cycles = current_project_cycles
		if location_id != SpaceGameState.MAIN_BASE_LOCATION_ID:
			for item_id_value in plan.keys():
				await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, String(item_id_value))
	if not completed:
		_print_remote_construction_diagnostic(location_id, project_type, target_id, plan)
	for item_id_value in plan.keys():
		var item_id := String(item_id_value)
		await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, item_id)
	if not completed:
		return _journey_fail("normal freight and Construction did not complete remote %s / %s" % [project_type, target_id])
	return true


func _mine_and_freight_ui(main: Control, location_id: String, site_id: String, ship_id: String, item_id: String, remote_target: int) -> bool:
	await _press_named(main, "Navigation_ships", "OPEN_SHIPS_FOR_%s_MINING" % location_id.to_upper())
	var roster_button := main.find_child("FleetSection_roster", true, false) as Button
	if roster_button != null and not roster_button.disabled:
		await _press_control(roster_button, "OPEN_ROSTER_FOR_%s_MINING" % location_id.to_upper())
	await _press_named(main, "AssignMining_%s" % ship_id, "ASSIGN_%s_MINING_AT_%s" % [ship_id.to_upper(), location_id.to_upper()])
	await _press_named(main, "Navigation_survey", "OPEN_SURVEY_FOR_%s_MINING" % location_id.to_upper())
	await _press_named(main, "StartMining_%s" % site_id, "START_MINING_%s" % site_id.to_upper())
	var mined := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.state.item_quantity(item_id, location_id) >= remote_target,
		LARGE_BATCH_TIMEOUT_SECONDS)
	if not mined:
		_print_mining_diagnostic(site_id, ship_id)
		return _journey_fail("remote UI mining did not stage %s at %s" % [item_id, location_id])
	return await _freight_remote_item_ui(main, location_id, item_id, true)


func _freight_remote_item_ui(main: Control, location_id: String, item_id: String, require_source_release: bool = false) -> bool:
	var source_before := Game.state.item_quantity(item_id, location_id)
	var cargo_path: Dictionary = Game.simulation.logistics._shortest_path(Game.state, location_id, SpaceGameState.MAIN_BASE_LOCATION_ID, item_id)
	var cargo_per_dispatch := _path_cargo_batch_read_only(cargo_path)
	var planned_dispatches := clampi(ceili(float(source_before) / float(maxi(1, cargo_per_dispatch))), 1, 16) if require_source_release else 1
	if not await _stage_remote_operating_stock_ui(main, location_id, planned_dispatches): return false
	if Game.simulation.logistics._destination_free_capacity(Game.state, SpaceGameState.MAIN_BASE_LOCATION_ID, item_id) <= 0:
		if not await _upgrade_item_storage_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, item_id): return false
	var delivered_before := int(Game.state.logistics_network.get("item_statistics", {}).get(item_id, {}).get("delivered", 0))
	await _replace_policy_ui(main, location_id, item_id, LogisticsEngine.MODE_SUPPLY)
	var transient_demand_buffer := maxi(4096, source_before * 2) if require_source_release else 0
	var import_target := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) \
		+ maxi(1, Game.state.available_item_quantity(item_id, location_id)) \
		+ transient_demand_buffer
	await _replace_policy_with_target_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, item_id, LogisticsEngine.MODE_DEMAND, import_target, 90)
	var delivered := await _wait_at_public_fast_speed(main, func() -> bool:
		if require_source_release:
			# Observe a bounded number of real dispatch-capacity tranches leave before
			# clearing temporary policies; small depots normally drain completely.
			# Once the resource is mature, its background extraction network can
			# replenish the source in the same boundary that freight removes cargo.
			# In that case the conserved delivery ledger is the physical-movement
			# evidence; requiring a lower net source stock creates a false deadlock.
			var release_target := mini(source_before, planned_dispatches * cargo_per_dispatch)
			return Game.state.item_quantity(item_id, location_id) <= source_before - release_target \
				or int(Game.state.logistics_network.get("item_statistics", {}).get(item_id, {}).get("delivered", 0)) > delivered_before
		return int(Game.state.logistics_network.get("item_statistics", {}).get(item_id, {}).get("delivered", 0)) > delivered_before,
		LARGE_BATCH_TIMEOUT_SECONDS)
	var import_satisfied_by_normal_economy := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= import_target
	await _clear_policy_ui(main, location_id, item_id)
	await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, item_id)
	if require_source_release and not delivered:
		_print_logistics_diagnostic([item_id, "chemical_propellant", "repair_material"])
		return _journey_fail("normal freight did not move %s from %s" % [item_id, location_id])
	if not delivered and not import_satisfied_by_normal_economy:
		_print_logistics_diagnostic([item_id, "chemical_propellant", "repair_material"])
		return _journey_fail("normal freight did not deliver %s from %s" % [item_id, location_id])
	if not delivered:
		_check(import_satisfied_by_normal_economy, "normal automated extraction satisfies %s demand before the optional remote shipment dispatches" % item_id)
	return true


func _path_cargo_batch_read_only(path: Dictionary) -> int:
	if path.is_empty():
		return 1
	var result := 2147483647
	for route_id_value in path.get("route_ids", []):
		var route_id := String(route_id_value)
		var route_units := maxf(0.001, float(path.get("route_freight_units_per_item", {}).get(route_id, 1.0)))
		result = mini(result, floori(float(Game.simulation.logistics.service_capacity(Game.state, route_id)) / route_units))
	var hub_units := maxf(0.001, float(path.get("hub_freight_units_per_item", 1.0)))
	for node_id_value in path.get("nodes", []):
		var node_id := String(node_id_value)
		var hub_capacity := float(Game.state.location_state(node_id).get("logistics", {}).get("hub_throughput", 0.0))
		result = mini(result, floori(hub_capacity / hub_units))
	return maxi(1, result if result != 2147483647 else 1)


func _stage_remote_operating_stock_ui(main: Control, location_id: String, dispatch_count: int = 1, destination_id: String = "") -> bool:
	if location_id == SpaceGameState.MAIN_BASE_LOCATION_ID:
		var source_requirements := {"chemical_propellant":40, "repair_material":20}
		if not destination_id.is_empty():
			var outbound_path: Dictionary = Game.simulation.logistics._shortest_path(Game.state, location_id, destination_id, "chemical_propellant")
			var outbound_costs: Dictionary = Game.simulation.logistics._path_costs(Game.state, outbound_path)
			var bounded_dispatches := clampi(dispatch_count, 1, 64)
			# Eight dispatch-costs of margin cover concurrent O&M settlement while
			# the visible production plan is running. The main depot is mature and
			# these are real manufactured/consumed operating goods, not free fuel.
			source_requirements["chemical_propellant"] = maxi(40, int(outbound_costs.get("chemical_propellant", 0)) * (bounded_dispatches + 8))
			source_requirements["repair_material"] = maxi(20, int(outbound_costs.get("repair_material", 0)) * (bounded_dispatches + 8))
		return await _ensure_ui_costs_stable(main, source_requirements)
	if bool(_operating_stock_stage_guard.get(location_id, false)):
		return _journey_fail("remote operating-stock dependency recursed through %s" % location_id)
	var path: Dictionary = Game.simulation.logistics._shortest_path(Game.state, SpaceGameState.MAIN_BASE_LOCATION_ID, location_id, "chemical_propellant")
	var path_costs: Dictionary = Game.simulation.logistics._path_costs(Game.state, path)
	dispatch_count = clampi(dispatch_count, 1, 16)
	var fuel_target := maxi(1, int(path_costs.get("chemical_propellant", 0)) * dispatch_count)
	var repair_target := maxi(1, int(path_costs.get("repair_material", 0)) * dispatch_count)
	# A remote origin only needs one return-dispatch cost buffer. Oversupplying this
	# stock can fill a frontier Fluid depot and block the raw gas the route exists
	# to export; replenish the buffer before each dispatch instead.
	if Game.state.item_quantity("chemical_propellant", location_id) >= fuel_target and Game.state.item_quantity("repair_material", location_id) >= repair_target:
		return true
	# Two cargo dispatches stage the fuel and repair buffers. Keep a bounded
	# multi-tick operating margin above the source reserve: the two cargoes each
	# pay route costs and ordinary O&M can settle between their dispatch ticks.
	# Destination targets remain exact, so this margin cannot overfill the remote
	# Fluid or Component depot.
	var fuel_budget := fuel_target + 8 * int(path_costs.get("chemical_propellant", 0))
	var repair_budget := repair_target + 8 * int(path_costs.get("repair_material", 0))
	# Manufacture the actual bounded dispatch budget plus a small O&M reserve.
	# The previous fixed 40/20 stock target was legal but multiplied early-game
	# mining and UI work for every two-unit frontier cargo without changing the
	# outcome of the freight transaction.
	_operating_stock_stage_guard[location_id] = true
	var source_stock_ready := await _ensure_ui_costs_stable(main, {
		"chemical_propellant":maxi(10, fuel_budget),
		"repair_material":maxi(10, repair_budget)
	})
	_operating_stock_stage_guard.erase(location_id)
	if not source_stock_ready: return false
	await _press_named(main, "SpeedPause", "PAUSE_FOR_BOUNDED_OPERATING_STOCK_POLICIES")
	await _replace_supply_with_budget_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "chemical_propellant", fuel_budget)
	await _replace_supply_with_budget_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "repair_material", repair_budget)
	# Use the visible advanced target fields for the actual operating tranche.
	# The generic Add Demand default of 50 legitimately filled the pre-base Fluid
	# and Component depots, leaving no staging room for construction materials.
	await _replace_policy_with_target_ui(main, location_id, "chemical_propellant", LogisticsEngine.MODE_DEMAND, fuel_target, 95)
	await _replace_policy_with_target_ui(main, location_id, "repair_material", LogisticsEngine.MODE_DEMAND, repair_target, 100)
	var operating_stock_ready := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.state.item_quantity("chemical_propellant", location_id) >= fuel_target \
			and Game.state.item_quantity("repair_material", location_id) >= repair_target,
		LARGE_BATCH_TIMEOUT_SECONDS)
	var fuel_ready := Game.state.item_quantity("chemical_propellant", location_id) >= fuel_target
	var repair_ready := Game.state.item_quantity("repair_material", location_id) >= repair_target
	var operating_failure_snapshot := {
		"source_inventory":Game.state.location_inventory(SpaceGameState.MAIN_BASE_LOCATION_ID).duplicate(true),
		"source_policies":Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {}).duplicate(true),
		"destination_policies":Game.state.location_state(location_id).get("logistics", {}).get("policies", {}).duplicate(true),
		"services":Game.state.logistics_network.get("services", {}).duplicate(true)
	}
	await _clear_policy_ui(main, location_id, "chemical_propellant")
	await _clear_policy_ui(main, location_id, "repair_material")
	await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "chemical_propellant")
	await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, "repair_material")
	if not operating_stock_ready:
		print("FULL_GAMEPLAY_UI_OPERATING_STOCK_TIMEOUT=", JSON.stringify({
			"location_id":location_id,
			"fuel_ready":fuel_ready,
			"repair_ready":repair_ready,
			"fuel":Game.state.item_quantity("chemical_propellant", location_id),
			"repair":Game.state.item_quantity("repair_material", location_id),
			"path":path,
			"path_costs":path_costs,
			"fuel_budget":fuel_budget,
			"repair_budget":repair_budget,
			"policy_snapshot":operating_failure_snapshot,
			"shipments":Game.state.logistics_network.get("shipments", []).duplicate(true)
		}))
	return operating_stock_ready or _journey_fail("remote route operating stock did not reach %s" % location_id)


func _replace_policy_ui(main: Control, location_id: String, item_id: String, mode: String) -> void:
	await _clear_policy_ui(main, location_id, item_id)
	await _set_location_logistics_policy(main, location_id, item_id, mode)


func _replace_policy_with_target_ui(main: Control, location_id: String, item_id: String, mode: String, target: int, priority: int = 50) -> void:
	await _replace_policy_ui(main, location_id, item_id, mode)
	# The policy editor is a visible card. Resolve its four numeric inputs from
	# the named Save button's nearest card so this still drives the same player
	# control even though individual SpinBoxes intentionally have no domain IDs.
	var save_button := main.find_child("SetLogisticsPolicy_%s_%s" % [location_id, item_id], true, false) as Button
	var editor_root: Node = save_button
	var inputs: Array[Node] = []
	while editor_root != null:
		inputs = editor_root.find_children("*", "SpinBox", true, false)
		if inputs.size() >= 4:
			break
		editor_root = editor_root.get_parent()
	var valid := save_button != null and save_button.is_visible_in_tree() and not save_button.disabled and inputs.size() >= 4
	_check(valid, "visible Logistics policy editor exposes target stock for %s at %s" % [item_id, location_id])
	if not valid:
		return
	var target_input := inputs[1] as SpinBox
	var priority_input := inputs[2] as SpinBox
	player_action_execution_log.append({
		"action_id":"SET_DEMAND_TARGET_%s_AT_%s" % [item_id.to_upper(), location_id.to_upper()],
		"control_name":"SpinBox[target]@SetLogisticsPolicy_%s_%s" % [location_id, item_id],
		"value":target,
		"simulation_time_ms":int(Game.state.total_elapsed_ms)
	})
	target_input.value = target
	target_input.value_changed.emit(float(target))
	priority_input.value = priority
	priority_input.value_changed.emit(float(priority))
	await _press_control(save_button, "SAVE_DEMAND_TARGET_%s_AT_%s" % [item_id.to_upper(), location_id.to_upper()])
	var policy: Dictionary = Game.state.location_state(location_id).get("logistics", {}).get("policies", {}).get(item_id, {})
	_check(int(policy.get("target", -1)) == target, "visible Logistics policy editor persists target %d for %s at %s" % [target, item_id, location_id])
	_check(int(policy.get("priority", -1)) == priority, "visible Logistics policy editor persists priority %d for %s at %s" % [priority, item_id, location_id])


func _replace_supply_with_budget_ui(main: Control, location_id: String, item_id: String, dispatch_budget: int) -> void:
	await _replace_policy_ui(main, location_id, item_id, LogisticsEngine.MODE_SUPPLY)
	var save_button := main.find_child("SetLogisticsPolicy_%s_%s" % [location_id, item_id], true, false) as Button
	var editor_root: Node = save_button
	var inputs: Array[Node] = []
	while editor_root != null:
		inputs = editor_root.find_children("*", "SpinBox", true, false)
		if inputs.size() >= 4:
			break
		editor_root = editor_root.get_parent()
	var valid := save_button != null and save_button.is_visible_in_tree() and not save_button.disabled and inputs.size() >= 4
	_check(valid, "visible Logistics policy editor exposes a bounded source reserve for %s at %s" % [item_id, location_id])
	if not valid:
		return
	var reserve_input := inputs[0] as SpinBox
	var current := Game.state.item_quantity(item_id, location_id)
	var reserve := maxi(0, current - maxi(0, dispatch_budget))
	reserve_input.value = reserve
	reserve_input.value_changed.emit(float(reserve))
	await _press_control(save_button, "SAVE_BOUNDED_SUPPLY_%s_AT_%s" % [item_id.to_upper(), location_id.to_upper()])
	var policy: Dictionary = Game.state.location_state(location_id).get("logistics", {}).get("policies", {}).get(item_id, {})
	_check(int(policy.get("reserve", -1)) == reserve, "visible Logistics supply policy limits %s dispatch stock to %d at %s" % [item_id, dispatch_budget, location_id])


func _clear_policy_ui(main: Control, location_id: String, item_id: String) -> void:
	if not Game.state.location_state(location_id).get("logistics", {}).get("policies", {}).has(item_id):
		return
	await _open_location_from_system(main, location_id)
	await _press_named(main, "LocationTab_logistics", "OPEN_%s_LOGISTICS_TO_CLEAR_%s" % [location_id.to_upper(), item_id.to_upper()])
	await _press_named(main, "ClearLogisticsPolicy_%s_%s" % [location_id, item_id], "CLEAR_%s_POLICY_AT_%s" % [item_id.to_upper(), location_id.to_upper()])


func _install_ship_module_ui(main: Control, ship_id: String, module_id: String) -> bool:
	if module_id in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)):
		return true
	var desired: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	desired.append(module_id)
	if not await _ensure_ui_costs_stable(main, Game.simulation.loadout_fabrication_costs(desired)): return false
	await _press_named(main, "Navigation_ships", "OPEN_SHIPS_TO_INSTALL_%s" % module_id.to_upper())
	var roster_button := main.find_child("FleetSection_roster", true, false) as Button
	if roster_button != null and not roster_button.disabled:
		await _press_control(roster_button, "OPEN_ROSTER_TO_INSTALL_%s" % module_id.to_upper())
	await _press_named(main, "InstallModule_%s_%s" % [ship_id, module_id], "INSTALL_%s_ON_%s" % [module_id.to_upper(), ship_id.to_upper()])
	var completed := await _wait_at_public_fast_speed(main, func() -> bool:
		return module_id in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	return completed or _journey_fail("visible refit did not install %s on %s" % [module_id, ship_id])


func _remove_ship_module_ui(main: Control, ship_id: String, module_id: String) -> bool:
	if module_id not in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)):
		return true
	var desired: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	desired.erase(module_id)
	if not await _ensure_ui_costs_stable(main, Game.simulation.loadout_fabrication_costs(desired)): return false
	await _press_named(main, "Navigation_ships", "OPEN_SHIPS_TO_REMOVE_%s" % module_id.to_upper())
	var roster_button := main.find_child("FleetSection_roster", true, false) as Button
	if roster_button != null and not roster_button.disabled:
		await _press_control(roster_button, "OPEN_ROSTER_TO_REMOVE_%s" % module_id.to_upper())
	await _press_named(main, "RemoveModule_%s_%s" % [ship_id, module_id], "REMOVE_%s_FROM_%s" % [module_id.to_upper(), ship_id.to_upper()])
	var completed := await _wait_at_public_fast_speed(main, func() -> bool:
		return module_id not in Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)),
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	return completed or _journey_fail("visible refit did not remove %s from %s" % [module_id, ship_id])


func _uninstall_process_module_ui(main: Control, facility_id: String, module_id: String) -> bool:
	if not _facility_has_process_module(facility_id, module_id):
		return true
	await _open_industry_production(main)
	await _stop_all_visible_industry_lines(main)
	await _open_industry_facilities(main)
	await _press_named(main, "UninstallManufacturingModule_%s_%s_process" % [facility_id, module_id], "UNINSTALL_PROCESS_%s" % module_id.to_upper())
	return not _facility_has_process_module(facility_id, module_id) or _journey_fail("visible facility control did not uninstall %s" % module_id)


func _complete_megastructure_ui(main: Control) -> bool:
	var definition: Dictionary = Game.content.megastructures.get("stellar_energy", {})
	var phases: Array = definition.get("phases", [])
	while int(Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_index", 0)) < phases.size():
		var phase_index := int(Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_index", 0))
		if phase_index == 4:
			if not await _upgrade_worksite_capacity_ui(main, "earth_sun_lagrange", "POWER_UPGRADE", 300): return false
			if not await _upgrade_worksite_capacity_ui(main, "earth_sun_lagrange", "COOLING_UPGRADE", 300): return false
		if phase_index == 7 and not await _stage_worksite_maintenance_ui(main, "earth_sun_lagrange"):
			return false
		await _press_named(main, "Navigation_megastructure", "OPEN_MEGASTRUCTURE_PHASE_%d" % phase_index)
		await _press_named(main, "StartMegastructure_stellar_energy", "START_MEGASTRUCTURE_PHASE_%d" % phase_index)
		var phase: Dictionary = phases[phase_index]
		var activity_id := String(phase.get("activity_id", ""))
		var completed := await _supply_remote_construction_ui(main, "earth_sun_lagrange", "MEGASTRUCTURE", activity_id, func() -> bool:
			return int(Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_index", 0)) == phase_index + 1)
		if not completed: return false
		var phase_events := {
			1:"FORWARD_BASE_COMPLETED", 2:"FOUNDATION_COMPLETED", 3:"FRAME_COMPLETED",
			4:"BACKBONE_COMPLETED", 5:"SYSTEMS_COMPLETED", 6:"INTEGRATION_COMPLETED",
			7:"COMMISSIONING_COMPLETED"
		}
		var phase_event := String(phase_events.get(phase_index, "MEGASTRUCTURE_PHASE_%d" % phase_index))
		journey_event_log.append(phase_event)
		_record_registry_event("JOURNEY_10_MEGASTRUCTURE", phase_event)
		if phase_index == 1:
			await _press_named(main, "Navigation_megastructure", "OPEN_MEGASTRUCTURE_FOR_EARLY_CAPTURE")
			await _capture_playthrough_milestone(main, "08_megastructure_early")
		elif phase_index == 4:
			await _press_named(main, "Navigation_megastructure", "OPEN_MEGASTRUCTURE_FOR_MID_CAPTURE")
			await _capture_playthrough_milestone(main, "09_megastructure_mid")
		elif phase_index == 7:
			await _press_named(main, "Navigation_megastructure", "OPEN_MEGASTRUCTURE_FOR_COMPLETE_CAPTURE")
			await _capture_playthrough_milestone(main, "10_megastructure_complete")
	return (bool(Game.state.game_complete) \
		and bool(Game.state.megastructures.get("stellar_energy", false)) \
		and (Game.state.megastructure_projects.get("stellar_energy", {}).get("phase_history", []) as Array).size() == 8) \
		or _journey_fail("the seven physical Megastructure phases did not commission the game")


func _upgrade_worksite_capacity_ui(main: Control, location_id: String, project_type: String, target_value: int) -> bool:
	for guard in 16:
		var current := _location_capacity_value(location_id, project_type)
		if current >= target_value:
			return true
		var runtime := _active_construction_runtime_read_only(location_id, project_type, "")
		if runtime.is_empty():
			await _open_location_from_system(main, location_id)
			await _press_named(main, "LocationTab_industry", "OPEN_%s_CAPACITY_FOR_%s" % [location_id.to_upper(), project_type])
			var queued_target := Game.simulation.suggested_location_capacity_upgrade_target(Game.state, location_id, project_type)
			var button := main.find_child("UpgradeLocationCapacity_%s_%s_%d" % [location_id, project_type, queued_target], true, false) as Button
			await _press_control(button, "UPGRADE_%s_AT_%s_TO_%d" % [project_type, location_id.to_upper(), queued_target])
			runtime = _active_construction_runtime_read_only(location_id, project_type, "")
			if runtime.is_empty():
				return _journey_fail("capacity button did not queue %s at %s" % [project_type, location_id])
		var completion_target := int(runtime.get("target_level", current + 1))
		if not await _supply_remote_construction_ui(main, location_id, project_type, "", func() -> bool:
			return _location_capacity_value(location_id, project_type) >= completion_target): return false
	return _journey_fail("capacity upgrade guard exceeded for %s" % project_type)


func _stage_worksite_maintenance_ui(main: Control, location_id: String) -> bool:
	var requirements := {}
	for source_value in Game.state.demand_registry.get("sources", {}).values():
		var source := source_value as Dictionary
		if String(source.get("consumer_type", "")) != "facility_om" or String(source.get("location_id", "")) != location_id:
			continue
		var item_id := String(source.get("product_id", ""))
		requirements[item_id] = int(requirements.get(item_id, 0)) + maxi(10, ceili(float(source.get("rate_per_hour", 0.0)) * 48.0))
	if not await _ensure_ui_costs_stable(main, requirements): return false
	if not await _stage_remote_operating_stock_ui(main, location_id): return false
	for item_id_value in requirements.keys():
		var item_id := String(item_id_value)
		await _replace_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, item_id, LogisticsEngine.MODE_SUPPLY)
		await _replace_policy_ui(main, location_id, item_id, LogisticsEngine.MODE_DEMAND)
	var covered := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.simulation._location_maintenance_coverage(Game.state, location_id) >= 0.75,
		LARGE_BATCH_TIMEOUT_SECONDS)
	for item_id_value in requirements.keys():
		await _clear_policy_ui(main, SpaceGameState.MAIN_BASE_LOCATION_ID, String(item_id_value))
		await _clear_policy_ui(main, location_id, String(item_id_value))
	return covered or _journey_fail("worksite maintenance coverage stayed below commissioning threshold")


func _location_capacity_value(location_id: String, project_type: String) -> int:
	return Game.simulation.location_capacity_value(Game.state, location_id, project_type)


func _capacity_upgrade_supply_chain_is_unlocked(location_id: String, project_type: String, target_value: int) -> bool:
	var plan := Game.simulation.location_capacity_upgrade_plan(Game.state, location_id, project_type, target_value)
	if plan.is_empty():
		return false
	for item_id_value in (plan.get("costs", {}) as Dictionary).keys():
		var item_id := String(item_id_value)
		var required := int(plan.get("costs", {}).get(item_id, 0))
		if Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= required:
			continue
		if not _ui_production_chain_is_unlocked(item_id, {}):
			return false
	return true


func _ui_production_chain_is_unlocked(item_id: String, visiting: Dictionary) -> bool:
	if item_id in ["mixed_raw_ore", "mixed_raw_gas"]:
		return not _mining_selection_read_only(item_id).is_empty()
	if bool(visiting.get(item_id, false)):
		return false
	var activity_id := String(UI_INDUSTRY_RECIPE_BY_ITEM.get(item_id, ""))
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	if activity.is_empty() or not Game.simulation.activity_available(Game.state, activity):
		return false
	visiting[item_id] = true
	for cost_value in activity.get("costs", []):
		var cost_item := String((cost_value as Dictionary).get("item", ""))
		if not _ui_production_chain_is_unlocked(cost_item, visiting):
			visiting.erase(item_id)
			return false
	visiting.erase(item_id)
	return true


func _visible_button_with_text(root: Node, expected_text: String) -> Button:
	for candidate_value in root.find_children("*", "Button", true, false):
		var candidate := candidate_value as Button
		if candidate.text == expected_text and candidate.is_visible_in_tree() and not candidate.disabled:
			return candidate
	return null


func _active_construction_runtime_read_only(location_id: String, project_type: String, target_id: String) -> Dictionary:
	for runtime_value in Game.state.construction_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("location_id", "")) != location_id or String(runtime.get("project_type", "")) != project_type:
			continue
		if not target_id.is_empty() and String(runtime.get("target_id", "")) != target_id and String(runtime.get("activity_id", "")) != target_id:
			continue
		if String(runtime.get("status", "")) in ["RUNNING", "BLOCKED", "QUEUED", "PAUSED"]:
			return runtime.duplicate(true)
	return {}


func _construction_material_progress(runtime: Dictionary, item_id: String) -> int:
	# Domain-owned delivery state is the project-specific proof. Do not infer
	# delivery from global recipe completions: another project or route may have
	# consumed the same SKU.
	var delivered: Dictionary = runtime.get("delivered_materials", {})
	var delivered_quantity := int(delivered.get(item_id, -1))
	if delivered_quantity < 0:
		delivered_quantity = int(runtime.get("consumed", {}).get(item_id, 0)) \
			+ int(runtime.get("reserved_costs", {}).get(item_id, 0))
	return delivered_quantity + int(runtime.get("in_transit_materials", {}).get(item_id, 0))


func _construction_remaining_material_plan(runtime: Dictionary) -> Dictionary:
	var remaining := {}
	for item_id_value in runtime.get("material_plan", {}).keys():
		var item_id := String(item_id_value)
		var quantity := maxi(0, int(runtime.get("material_plan", {}).get(item_id, 0)) - _construction_material_progress(runtime, item_id))
		if quantity > 0:
			remaining[item_id] = quantity
	return remaining


func _construction_dispatch_count_read_only(destination_id: String, material_plan: Dictionary) -> int:
	var dispatches := 0
	for item_id_value in material_plan.keys():
		var item_id := String(item_id_value)
		var path: Dictionary = Game.simulation.logistics._shortest_path(Game.state, SpaceGameState.MAIN_BASE_LOCATION_ID, destination_id, item_id)
		var cargo_batch := maxi(1, _path_cargo_batch_read_only(path))
		dispatches += ceili(float(material_plan.get(item_id, 0)) / float(cargo_batch))
	return maxi(1, dispatches)


func _docked_route_candidates_read_only(route_id: String) -> Array:
	var result: Array = []
	var route: Dictionary = Game.content.expedition_routes.get(route_id, {})
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		var ship_id := String(ship.get("instance_id", ""))
		if not Game.state.ship_is_docked(ship_id): continue
		var valid := true
		for node_value in route.get("nodes", []):
			if not Game.simulation.build_requirements_met(Game.state, node_value as Dictionary, [ship_id]):
				valid = false
				break
		if valid:
			result.append(ship_id)
			break
	return result


func _construction_activity_for_facility(facility_id: String) -> String:
	for activity_value in Game.content.activities.values():
		var activity := activity_value as Dictionary
		for effect_value in activity.get("effects", []):
			var effect := effect_value as Dictionary
			if String(effect.get("type", "")) == "unlock_facility" and String(effect.get("facility", "")) == facility_id:
				return String(activity.get("id", ""))
	return ""


func _cost_dictionary(entries: Array) -> Dictionary:
	var result := {}
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := String(entry.get("item", ""))
		result[item_id] = int(result.get(item_id, 0)) + int(entry.get("quantity", 0))
	return result


func _journey_fail(message: String) -> bool:
	_check(false, message)
	return false


func _record_registry_event(journey_id: String, event_id: String) -> void:
	var events: Array = registry_journey_events.get(journey_id, [])
	if not events.has(event_id):
		events.append(event_id)
	registry_journey_events[journey_id] = events
	print("FULL_GAMEPLAY_UI_REGISTRY_EVENT=", JSON.stringify({
		"journey_id":journey_id,
		"event_id":event_id,
		"simulation_time_ms":int(Game.state.total_elapsed_ms)
	}))


func _start_fresh_save_through_ui(main: Control) -> void:
	await _press_named(main, "RestartButton", "OPEN_NEW_GAME_CONFIRMATION")
	var dialog := main.find_child("ResetConfirmation", true, false) as ConfirmationDialog
	_check(dialog != null and dialog.visible, "Restart opens the player-visible destructive New Game confirmation")
	if dialog == null:
		return
	var confirm := dialog.get_ok_button()
	await _press_control(confirm, "CONFIRM_NEW_GAME")
	await _settle_ui()


func _press_named(root: Node, control_name: String, action_id: String) -> void:
	await _press_control(root.find_child(control_name, true, false) as Button, action_id)


func _press_control(button: Button, action_id: String) -> void:
	var valid := button != null and button.is_visible_in_tree() and not button.disabled
	_check(valid, "%s is reachable through a visible enabled Control" % action_id)
	if not valid:
		return
	player_action_execution_log.append({
		"action_id": action_id,
		"control_name": String(button.name),
		"simulation_time_ms": int(Game.state.total_elapsed_ms)
	})
	button.pressed.emit()
	await _settle_ui()


func _open_industry_production(main: Control) -> void:
	# Industry is contextual to the Location selected through the public map. A
	# remote logistics inspection legitimately changes that context, so return to
	# Earth through visible navigation before asking its workshop to manufacture
	# the Journey BOM.
	if String(main.get("_selected_location_id")) != SpaceGameState.MAIN_BASE_LOCATION_ID:
		await _open_location_from_system(main, SpaceGameState.MAIN_BASE_LOCATION_ID)
	# Dependency-ordered BOM production calls this helper for every intermediate.
	# Re-pressing an already-selected navigation item rebuilds the complete page,
	# obscures the real actions in telemetry and can turn a finite capital-goods
	# plan into minutes of redundant UI work. The initial transition still uses
	# the same visible controls; subsequent calls keep the already-visible surface.
	if String(main.get("_active_page_key")) != "industry":
		await _press_named(main, "Navigation_industry", "OPEN_INDUSTRY_PRODUCTION")
	if String(main.get("_industry_section")) != "production":
		var production_tab := main.find_child("IndustrySection_production", true, false) as Button
		if production_tab != null and not production_tab.disabled:
			await _press_control(production_tab, "SELECT_INDUSTRY_PRODUCTION")


func _open_industry_construction(main: Control) -> void:
	await _press_named(main, "Navigation_industry", "OPEN_INDUSTRY_CONSTRUCTION")
	var construction_tab := main.find_child("IndustrySection_construction", true, false) as Button
	if construction_tab != null and not construction_tab.disabled:
		await _press_control(construction_tab, "SELECT_INDUSTRY_CONSTRUCTION")


func _open_industry_facilities(main: Control) -> void:
	await _press_named(main, "Navigation_industry", "OPEN_INDUSTRY_FACILITIES")
	var facilities_tab := main.find_child("IndustrySection_facilities", true, false) as Button
	if facilities_tab != null and not facilities_tab.disabled:
		await _press_control(facilities_tab, "SELECT_INDUSTRY_FACILITIES")


func _install_process_module(main: Control, facility_id: String, module_id: String) -> bool:
	if _facility_has_process_module(facility_id, module_id):
		return true
	var definition: Dictionary = Game.content.process_modules.get(module_id, {})
	var costs := {}
	for cost_value in definition.get("costs", []):
		var cost := cost_value as Dictionary
		costs[String(cost.get("item", ""))] = int(cost.get("quantity", 0))
	if not await _ensure_ui_costs_stable(main, costs):
		return false
	await _open_industry_production(main)
	await _stop_all_visible_industry_lines(main)
	await _open_industry_facilities(main)
	await _press_named(main, "InstallManufacturingModule_%s_%s_process" % [facility_id, module_id], "INSTALL_PROCESS_MODULE_%s" % module_id.to_upper())
	return _facility_has_process_module(facility_id, module_id)


func _set_location_logistics_policy(main: Control, location_id: String, item_id: String, mode: String) -> void:
	await _open_location_from_system(main, location_id)
	await _press_named(main, "LocationTab_logistics", "OPEN_LOGISTICS_%s_FOR_%s" % [location_id.to_upper(), item_id.to_upper()])
	var selector := main.find_child("LogisticsItemSelector", true, false) as OptionButton
	if selector == null:
		await _press_named(main, "LogisticsPolicyAdvancedToggle", "OPEN_ADVANCED_LOGISTICS_POLICY_%s" % location_id.to_upper())
		selector = main.find_child("LogisticsItemSelector", true, false) as OptionButton
	await _select_option_text(selector, I18n.content(Game.content.items.get(item_id, {})), "SELECT_LOGISTICS_ITEM_%s_AT_%s" % [item_id.to_upper(), location_id.to_upper()])
	await _press_named(main, "AddLogisticsPolicy_%s_%s" % [location_id, mode], "ADD_%s_POLICY_%s_AT_%s" % [mode, item_id.to_upper(), location_id.to_upper()])
	var policy: Dictionary = Game.state.location_state(location_id).get("logistics", {}).get("policies", {}).get(item_id, {})
	_check(String(policy.get("mode", "")) == mode, "visible advanced Logistics controls persist %s %s at %s" % [item_id, mode, location_id])


func _select_option_text(selector: OptionButton, expected_text: String, action_id: String) -> void:
	var valid := selector != null and selector.is_visible_in_tree() and not selector.disabled
	_check(valid, "%s is reachable through a visible enabled OptionButton" % action_id)
	if not valid:
		return
	var selected_index := -1
	for index in selector.item_count:
		if selector.get_item_text(index) == expected_text:
			selected_index = index
			break
	_check(selected_index >= 0, "%s exposes the requested localized option" % action_id)
	if selected_index < 0:
		return
	player_action_execution_log.append({
		"action_id":action_id,
		"control_name":String(selector.name),
		"selected_index":selected_index,
		"simulation_time_ms":int(Game.state.total_elapsed_ms)
	})
	selector.select(selected_index)
	selector.item_selected.emit(selected_index)
	await _settle_ui()


func _capture_playthrough_milestone(main: Control, basename: String) -> void:
	# Scenario diagnostics reuse several endgame helpers, but only the strict
	# fresh-save run owns the certification screenshot matrix.
	if "NEW_GAME" not in journey_event_log:
		return
	var original_locale := String(I18n.current_locale)
	for locale in ["en", "zh_CN"]:
		if String(I18n.current_locale) != locale:
			await _press_named(main, "ToggleLocale", "SWITCH_LOCALE_FOR_%s_%s_CAPTURE" % [basename.to_upper(), locale.to_upper()])
		await _settle_ui()
		_check(String(I18n.current_locale) == locale, "%s capture renders with the requested %s localization" % [basename, locale])
		RenderingServer.force_draw()
		await get_tree().process_frame
		var image := main.get_viewport().get_texture().get_image()
		var directory := "%s/%s" % [PLAYTHROUGH_SCREENSHOT_ROOT, locale]
		var absolute_directory := ProjectSettings.globalize_path(directory)
		var mkdir_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
		_check(mkdir_error in [OK, ERR_ALREADY_EXISTS], "screenshot directory is writable for %s" % locale)
		var resource_path := "%s/%s.png" % [directory, basename]
		var save_error := ERR_CANT_CREATE if image == null or image.is_empty() else image.save_png(ProjectSettings.globalize_path(resource_path))
		_check(save_error == OK, "captures %s in %s from the real rendered UI" % [basename, locale])
		if save_error == OK:
			print("FULL_GAMEPLAY_UI_SCREENSHOT=", resource_path)
	if String(I18n.current_locale) != original_locale:
		await _press_named(main, "ToggleLocale", "RESTORE_LOCALE_AFTER_%s_CAPTURE" % basename.to_upper())
		_check(String(I18n.current_locale) == original_locale, "%s capture restores the prior locale" % basename)


func _consume_ui_item_below(main: Control, activity_id: String, item_id: String, maximum_quantity: int) -> bool:
	if Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) <= maximum_quantity:
		return true
	await _open_industry_production(main)
	await _press_named(main, "StartIndustry_%s" % activity_id, "START_%s_FOR_FREIGHT_DEFICIT" % activity_id.to_upper())
	var consumed := await _wait_at_public_fast_speed(main, func() -> bool:
		return Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) <= maximum_quantity,
		JOURNEY_STAGE_TIMEOUT_SECONDS)
	var stop_button := main.find_child("StopIndustry_%s" % activity_id, true, false) as Button
	if stop_button != null and stop_button.is_visible_in_tree() and not stop_button.disabled:
		await _press_control(stop_button, "STOP_%s_AFTER_FREIGHT_DEFICIT" % activity_id.to_upper())
	return consumed


func _stop_all_visible_industry_lines(main: Control) -> void:
	# Page rebuilds free the remaining controls after each press, so resolve the
	# visible tree again until no normal Stop action remains.
	while true:
		var stop_button := _first_enabled_button(main, "StopIndustry_")
		if stop_button == null:
			return
		var stable_name := String(stop_button.name)
		await _press_control(stop_button, "STOP_BUSY_LINE_BEFORE_MANUFACTURING_REFIT_%s" % stable_name.trim_prefix("StopIndustry_").to_upper())
		await _open_industry_production(main)


func _produce_until(main: Control, activity_id: String, product_id: String, target_quantity: int, timeout_seconds: float, use_public_fast_speed: bool = false, storage_recovery_attempts: int = 0, progress_retry_attempts: int = 0, committed_sink_progress: Callable = Callable(), committed_sink_target: int = 0) -> bool:
	if Game.state.item_quantity(product_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= target_quantity:
		return true
	var quantity_before := Game.state.item_quantity(product_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
	var completed_before := int(Game.state.completed_activities.get(activity_id, 0))
	var activity_definition: Dictionary = Game.content.activities.get(activity_id, {})
	var existing_runtime := _industry_runtime(activity_id)
	if existing_runtime.is_empty() or String(existing_runtime.get("status", "")) not in ["RUNNING", "BLOCKED"]:
		var start_button := main.find_child("StartIndustry_%s" % activity_id, true, false) as Button
		if start_button != null and start_button.disabled:
			# A legal checkpoint can retain another method on the same physical
			# facility. Release it through visible Stop controls before selecting the
			# production plan's next method; domain validation still owns availability.
			await _stop_all_visible_industry_lines(main)
			await _open_industry_production(main)
		for cost_value in activity_definition.get("costs", []):
			var cost := cost_value as Dictionary
			var cost_item := String(cost.get("item", ""))
			var required := int(cost.get("quantity", 0))
			var available := Game.state.available_item_quantity(cost_item, SpaceGameState.MAIN_BASE_LOCATION_ID)
			if available >= required:
				continue
			var target_cost_stock := Game.state.item_quantity(cost_item, SpaceGameState.MAIN_BASE_LOCATION_ID) + required - available
			if not await _ensure_ui_item(main, cost_item, target_cost_stock):
				return false
			await _open_industry_production(main)
		var start_control := main.find_child("StartIndustry_%s" % activity_id, true, false) as Button
		if start_control == null or not start_control.is_visible_in_tree() or start_control.disabled:
			# UI availability can change during settle frames when O&M or another
			# committed sink claims the last input unit. Give the normal simulation a
			# bounded chance to settle, then re-run the same visible dependency plan;
			# do not record a false button-action failure before recovery is exhausted.
			for availability_attempt in 3:
				await _open_industry_production(main)
				start_control = main.find_child("StartIndustry_%s" % activity_id, true, false) as Button
				if start_control != null and start_control.is_visible_in_tree() and not start_control.disabled:
					break
				await _wait_at_public_fast_speed(main, func() -> bool: return false, 1.0)
			if (start_control == null or not start_control.is_visible_in_tree() or start_control.disabled) and progress_retry_attempts < 8:
				await _open_industry_production(main)
				return await _produce_until(main, activity_id, product_id, target_quantity, timeout_seconds, use_public_fast_speed, storage_recovery_attempts, progress_retry_attempts + 1, committed_sink_progress, committed_sink_target)
		if start_control == null or not start_control.is_visible_in_tree() or start_control.disabled:
			print("FULL_GAMEPLAY_UI_START_UNAVAILABLE=", JSON.stringify({
				"activity_id":activity_id,
				"product_id":product_id,
				"target_quantity":target_quantity,
				"runtime":_industry_runtime(activity_id),
				"domain_can_start":Game.can_start_activity("industry", activity_definition)
			}))
			return false
		await _press_control(start_control, "START_%s" % activity_id.to_upper())
	var completion_predicate := func() -> bool:
		# A live Construction project can reserve and consume each unit in the same
		# settlement. In that mode the immutable completion ledger is the physical
		# delivery proof; wait for the whole requested batch instead of restarting
		# the UI production line after every individual cycle.
		var current_quantity := Game.state.item_quantity(product_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
		return current_quantity >= target_quantity \
			or (committed_sink_progress.is_valid() and int(committed_sink_progress.call()) >= committed_sink_target)
	if use_public_fast_speed:
		await _wait_at_public_fast_speed(main, completion_predicate, timeout_seconds)
	else:
		await _wait_until(completion_predicate, timeout_seconds)
	var produced := Game.state.item_quantity(product_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= target_quantity
	var delivered_to_committed_sink := committed_sink_progress.is_valid() \
		and int(committed_sink_progress.call()) >= committed_sink_target
	var runtime_before_stop := _industry_runtime(activity_id)
	var storage_limited := String(runtime_before_stop.get("blocked_reason", "")) == "STORAGE_FULL" \
		or String(runtime_before_stop.get("blocker", {}).get("primary_reason", "")) == "STORAGE_FULL"
	var stop_button := main.find_child("StopIndustry_%s" % activity_id, true, false) as Button
	if stop_button != null and stop_button.is_visible_in_tree() and not stop_button.disabled:
		await _press_control(stop_button, "STOP_%s" % activity_id.to_upper())
	if delivered_to_committed_sink:
		return true
	if not produced:
		if storage_limited and storage_recovery_attempts < 6:
			var expanded := await _upgrade_activity_storage_ui(main, runtime_before_stop, Game.content.activities.get(activity_id, {}))
			if expanded:
				await _open_industry_production(main)
				return await _produce_until(main, activity_id, product_id, target_quantity, timeout_seconds, use_public_fast_speed, storage_recovery_attempts + 1, progress_retry_attempts, committed_sink_progress, committed_sink_target)
		var primary_reason := String(runtime_before_stop.get("blocker", {}).get("primary_reason", ""))
		var input_limited := String(runtime_before_stop.get("blocked_reason", "")) == "RESOURCES" \
			or primary_reason in ["INPUT_SHORTAGE", "MISSING_CAPITAL_GOOD"]
		if input_limited and progress_retry_attempts < 8:
			# Replenish one real recipe cycle after a long-running O&M/Construction
			# sink wins the final input settlement. This is the player-visible answer
			# to INPUT_SHORTAGE and remains bounded by the shared retry guard.
			for cost_value in activity_definition.get("costs", []):
				var cost := cost_value as Dictionary
				var cost_item := String(cost.get("item", ""))
				var required := int(cost.get("quantity", 0))
				var available := Game.state.available_item_quantity(cost_item, SpaceGameState.MAIN_BASE_LOCATION_ID)
				if available < required:
					var target_cost_stock := Game.state.item_quantity(cost_item, SpaceGameState.MAIN_BASE_LOCATION_ID) + required - available
					if not await _ensure_ui_item(main, cost_item, target_cost_stock):
						return false
			await _open_industry_production(main)
			return await _produce_until(main, activity_id, product_id, target_quantity, timeout_seconds, use_public_fast_speed, storage_recovery_attempts, progress_retry_attempts + 1, committed_sink_progress, committed_sink_target)
		var completed_after := int(Game.state.completed_activities.get(activity_id, 0))
		if (Game.state.item_quantity(product_id, SpaceGameState.MAIN_BASE_LOCATION_ID) > quantity_before \
				or completed_after > completed_before) and progress_retry_attempts < 8:
			# A live project can reserve and consume a newly completed output in the
			# same settlement. The immutable completed-activity ledger is still proof
			# of forward progress, so continue until the sink is funded and spendable
			# stock accumulates. A genuinely stalled recipe records no new completion.
			await _open_industry_production(main)
			return await _produce_until(main, activity_id, product_id, target_quantity, timeout_seconds, use_public_fast_speed, storage_recovery_attempts, progress_retry_attempts + 1, committed_sink_progress, committed_sink_target)
		print("FULL_GAMEPLAY_UI_PRODUCTION_TIMEOUT=", JSON.stringify({
			"activity_id":activity_id,
			"product_id":product_id,
			"target_quantity":target_quantity,
			"current_quantity":Game.state.item_quantity(product_id, SpaceGameState.MAIN_BASE_LOCATION_ID),
			"completed_before":completed_before,
			"completed_after":int(Game.state.completed_activities.get(activity_id, 0)),
			"runtime":runtime_before_stop,
			"total_simulation_ms":int(Game.state.total_elapsed_ms)
		}))
	return produced


func _upgrade_activity_storage_ui(main: Control, runtime: Dictionary, activity: Dictionary) -> bool:
	if runtime.is_empty() or activity.is_empty():
		return false
	var location_id := String(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var outputs: Dictionary = Game.simulation._activity_output_totals(Game.state, "industry", runtime, activity)
	var inputs: Dictionary = Game.simulation.industry_cycle_costs(Game.state, runtime, activity, false)
	var used: Dictionary = Game.simulation.location_storage_used(Game.state, location_id)
	var capacities: Dictionary = Game.simulation.location_storage_capacities(Game.state, location_id)
	var deltas := {}
	for item_id_value in outputs.keys():
		var item_id := String(item_id_value)
		var storage_class := Game.simulation.storage_class_for_item(item_id)
		deltas[storage_class] = float(deltas.get(storage_class, 0.0)) + float(outputs.get(item_id, 0)) * Game.simulation.storage_units_for_item(item_id)
	for item_id_value in inputs.keys():
		var item_id := String(item_id_value)
		var storage_class := Game.simulation.storage_class_for_item(item_id)
		deltas[storage_class] = float(deltas.get(storage_class, 0.0)) - float(inputs.get(item_id, 0)) * Game.simulation.storage_units_for_item(item_id)
	var expanded := false
	for storage_class_value in deltas.keys():
		var storage_class := String(storage_class_value)
		if float(used.get(storage_class, 0.0)) + float(deltas.get(storage_class, 0.0)) <= float(capacities.get(storage_class, 0.0)) + 0.000001:
			continue
		var project_type := String({
			"BULK":"BULK_STORAGE_UPGRADE",
			"COMPONENT":"COMPONENT_STORAGE_UPGRADE",
			"FLUID":"FLUID_STORAGE_UPGRADE",
			"SPECIAL":"SPECIAL_STORAGE_UPGRADE"
		}.get(storage_class, ""))
		if project_type.is_empty():
			return false
		var current_capacity := _location_capacity_value(location_id, project_type)
		if not await _upgrade_worksite_capacity_ui(main, location_id, project_type, current_capacity + 1):
			return false
		expanded = true
	return expanded


func _upgrade_item_storage_ui(main: Control, location_id: String, item_id: String) -> bool:
	var storage_class := Game.simulation.storage_class_for_item(item_id)
	var project_type := String({
		"BULK":"BULK_STORAGE_UPGRADE",
		"COMPONENT":"COMPONENT_STORAGE_UPGRADE",
		"FLUID":"FLUID_STORAGE_UPGRADE",
		"SPECIAL":"SPECIAL_STORAGE_UPGRADE"
	}.get(storage_class, ""))
	if project_type.is_empty():
		return _journey_fail("no normal storage project exists for %s" % storage_class)
	var current_capacity := _location_capacity_value(location_id, project_type)
	return await _upgrade_worksite_capacity_ui(main, location_id, project_type, current_capacity + 1)


func _ensure_ui_costs(main: Control, costs: Dictionary) -> bool:
	for item_id_value in costs.keys():
		var item_id := String(item_id_value)
		var required_available := int(costs[item_id])
		var available := Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
		# Domain availability, not gross stock, funds commands. Produce above any
		# legitimate reservation so the visible button receives spendable inputs.
		var target_total := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) + maxi(0, required_available - available)
		if not await _ensure_ui_item(main, item_id, target_total):
			return false
	return true


func _ensure_ui_costs_stable(main: Control, costs: Dictionary, completion: Callable = Callable(), committed_sink_progress: Callable = Callable(), committed_sink_targets: Dictionary = {}) -> bool:
	# Reserve the whole requested BOM in a read-only virtual inventory before
	# pressing any recipe. This gives one dependency-ordered UI production plan;
	# producing a later capital good can no longer consume a product that an
	# earlier loop had incorrectly considered "finished". All execution still
	# uses the ordinary Industry/Mining controls and public speed buttons.
	for pass_index in 3:
		if completion.is_valid() and bool(completion.call()):
			return true
		await _open_industry_production(main)
		await _stop_all_visible_industry_lines(main)
		var planning := _build_ui_production_plan(costs)
		if not bool(planning.get("ok", false)):
			_print_cost_convergence_diagnostic(costs, pass_index, String(planning.get("error", "PLANNING_FAILED")))
			return false
		print("FULL_GAMEPLAY_UI_COST_PLAN=", JSON.stringify({
			"pass":pass_index,
			"costs":costs,
			"entries":planning.get("entries", [])
		}))
		for entry_value in planning.get("entries", []):
			if completion.is_valid() and bool(completion.call()):
				return true
			var entry := entry_value as Dictionary
			var item_id := String(entry.get("item_id", ""))
			var quantity := int(entry.get("quantity", 0))
			if quantity <= 0:
				continue
			var target := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) + quantity
			if String(entry.get("kind", "")) == "RAW":
				if not await _ensure_raw_resource_ui(main, item_id, target):
					_print_cost_convergence_diagnostic(costs, pass_index, "RAW_PRODUCTION_FAILED")
					return false
			else:
				var activity_id := String(entry.get("activity_id", ""))
				var item_sink_progress := Callable()
				var item_sink_target := 0
				if committed_sink_progress.is_valid() and committed_sink_targets.has(item_id):
					item_sink_progress = committed_sink_progress.bind(item_id)
					item_sink_target = int(committed_sink_targets.get(item_id, 0))
				await _open_industry_production(main)
				if not await _produce_until(main, activity_id, item_id, target, LARGE_BATCH_TIMEOUT_SECONDS, true, 0, 0, item_sink_progress, item_sink_target):
					_print_cost_convergence_diagnostic(costs, pass_index, "PRODUCTION_FAILED:%s" % activity_id)
					return false
			if completion.is_valid() and bool(completion.call()):
				return true
		var complete := true
		for item_id_value in costs.keys():
			var item_id := String(item_id_value)
			if Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) < int(costs[item_id]):
				complete = false
		if complete:
			return true
		if completion.is_valid():
			# The planned batch has been physically produced once. A live remote
			# project may already have consumed or freighted it, so a second pass
			# would manufacture the entire BOM again merely because it is no longer
			# visible as available Earth stock. The caller now waits on the actual
			# project completion condition and reports any real delivery shortfall.
			return true
	_print_cost_convergence_diagnostic(costs, 3, "PASS_LIMIT")
	return false


func _build_ui_production_plan(costs: Dictionary) -> Dictionary:
	var virtual_available := {}
	for item_id_value in Game.content.items.keys():
		var item_id := String(item_id_value)
		virtual_available[item_id] = Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
	var entries: Array[Dictionary] = []
	var visiting := {}
	for item_id_value in costs.keys():
		var item_id := String(item_id_value)
		var error := _reserve_virtual_ui_requirement(item_id, int(costs[item_id]), virtual_available, entries, visiting)
		if not error.is_empty():
			return {"ok":false, "error":error, "entries":entries}
	return {"ok":true, "entries":entries}


func _reserve_virtual_ui_requirement(item_id: String, quantity: int, virtual_available: Dictionary, entries: Array[Dictionary], visiting: Dictionary) -> String:
	if quantity <= 0:
		return ""
	var existing := maxi(0, int(virtual_available.get(item_id, 0)))
	var consumed_existing := mini(existing, quantity)
	virtual_available[item_id] = existing - consumed_existing
	var shortage := quantity - consumed_existing
	if shortage <= 0:
		return ""
	if item_id in ["mixed_raw_ore", "mixed_raw_gas"]:
		entries.append({"kind":"RAW", "item_id":item_id, "quantity":shortage})
		return ""
	if bool(visiting.get(item_id, false)):
		return "PRODUCTION_CYCLE:%s" % item_id
	var activity_id := String(UI_INDUSTRY_RECIPE_BY_ITEM.get(item_id, ""))
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	if activity_id.is_empty() or activity.is_empty():
		return "NO_UI_RECIPE:%s" % item_id
	var reward_quantity := 0
	for reward_value in activity.get("rewards", []):
		var reward := reward_value as Dictionary
		if String(reward.get("item", "")) == item_id:
			reward_quantity += int(reward.get("quantity", 0))
	if reward_quantity <= 0:
		return "INVALID_UI_RECIPE:%s:%s" % [activity_id, item_id]
	var cycles := ceili(float(shortage) / float(reward_quantity))
	visiting[item_id] = true
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var error := _reserve_virtual_ui_requirement(String(cost.get("item", "")), int(cost.get("quantity", 0)) * cycles, virtual_available, entries, visiting)
		if not error.is_empty():
			visiting.erase(item_id)
			return error
	visiting.erase(item_id)
	entries.append({"kind":"ACTIVITY", "activity_id":activity_id, "item_id":item_id, "quantity":cycles * reward_quantity})
	for reward_value in activity.get("rewards", []):
		var reward := reward_value as Dictionary
		var reward_id := String(reward.get("item", ""))
		virtual_available[reward_id] = int(virtual_available.get(reward_id, 0)) + int(reward.get("quantity", 0)) * cycles
	virtual_available[item_id] = maxi(0, int(virtual_available.get(item_id, 0)) - shortage)
	return ""


func _print_cost_convergence_diagnostic(costs: Dictionary, pass_index: int, reason: String) -> void:
	var items := {}
	for item_id_value in costs.keys():
		var item_id := String(item_id_value)
		var gross := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
		var available := Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
		items[item_id] = {
			"required":int(costs[item_id]),
			"available":available,
			"gross":gross,
			"reserved":maxi(0, gross - available)
		}
	print("FULL_GAMEPLAY_UI_COST_CONVERGENCE=", JSON.stringify({"pass":pass_index, "reason":reason, "items":items}))


func _print_remote_construction_diagnostic(location_id: String, project_type: String, target_id: String, plan: Dictionary) -> void:
	var source_items := {}
	var destination_items := {}
	var source_policies: Dictionary = Game.state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID).get("logistics", {}).get("policies", {})
	var destination_policies: Dictionary = Game.state.location_state(location_id).get("logistics", {}).get("policies", {})
	for item_id_value in plan.keys():
		var item_id := String(item_id_value)
		source_items[item_id] = {
			"on_hand":Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID),
			"available":Game.state.available_item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID),
			"policy":source_policies.get(item_id, {}).duplicate(true)
		}
		destination_items[item_id] = {
			"on_hand":Game.state.item_quantity(item_id, location_id),
			"incoming":Game.simulation.logistics.incoming_quantity(Game.state, location_id, item_id),
			"policy":destination_policies.get(item_id, {}).duplicate(true),
			"committed_demands":Game.simulation.demand_sources_for(Game.state, item_id, location_id)
		}
	var service_snapshots := {}
	for route_id_value in Game.content.logistics_routes.keys():
		var route_id := String(route_id_value)
		service_snapshots[route_id] = Game.simulation.logistics.service_snapshot(Game.state, route_id)
	print("FULL_GAMEPLAY_UI_REMOTE_CONSTRUCTION_TIMEOUT=", JSON.stringify({
		"location":location_id,
		"project_type":project_type,
		"target":target_id,
		"runtime":_active_construction_runtime_read_only(location_id, project_type, target_id),
		"source_items":source_items,
		"destination_items":destination_items,
		"destination_inventory":Game.state.location_inventory(location_id).duplicate(true),
		"destination_storage":Game.simulation.location_storage_snapshot(Game.state, location_id),
		"shipments":Game.state.logistics_network.get("shipments", []).duplicate(true),
		"services":service_snapshots
	}))


func _ensure_ui_item(main: Control, item_id: String, target_quantity: int) -> bool:
	var current := Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
	if current >= target_quantity:
		return true
	if item_id in ["mixed_raw_ore", "mixed_raw_gas"]:
		return await _ensure_raw_resource_ui(main, item_id, target_quantity)
	var activity_id := String(UI_INDUSTRY_RECIPE_BY_ITEM.get(item_id, ""))
	if activity_id.is_empty():
		_check(false, "no UI recipe orchestration is registered for required item %s" % item_id)
		return false
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	var reward_quantity := 0
	for reward_value in activity.get("rewards", []):
		var reward := reward_value as Dictionary
		if String(reward.get("item", "")) == item_id:
			reward_quantity += int(reward.get("quantity", 0))
	if reward_quantity <= 0:
		_check(false, "registered UI recipe %s does not produce %s" % [activity_id, item_id])
		return false
	var cycles := ceili(float(target_quantity - current) / float(reward_quantity))
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var cost_item := String(cost.get("item", ""))
		var required := int(cost.get("quantity", 0)) * cycles
		var available := Game.state.available_item_quantity(cost_item, SpaceGameState.MAIN_BASE_LOCATION_ID)
		var target_stock := Game.state.item_quantity(cost_item, SpaceGameState.MAIN_BASE_LOCATION_ID) + maxi(0, required - available)
		if not await _ensure_ui_item(main, cost_item, target_stock):
			return false
	await _open_industry_production(main)
	return await _produce_until(main, activity_id, item_id, target_quantity, LARGE_BATCH_TIMEOUT_SECONDS, true)


func _ensure_raw_resource_ui(main: Control, item_id: String, target_quantity: int) -> bool:
	for batch in 64:
		if Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= target_quantity:
			return true
		var local_network_available := _active_local_extraction_network_produces(item_id)
		if local_network_available:
			# Prefer the already-established local recovery path before inspecting
			# frontier stock. Freight from a remote mining origin consumes the very
			# operating goods this replenishment may be trying to manufacture.
			var local_progress := await _wait_at_public_fast_speed(main, func() -> bool:
				return Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= target_quantity,
				LARGE_BATCH_TIMEOUT_SECONDS)
			if local_progress: return true
			print("FULL_GAMEPLAY_UI_LOCAL_EXTRACTION_RECOVERY_TIMEOUT=", JSON.stringify({
				"item_id":item_id,
				"target":target_quantity,
				"current":Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID),
				"networks":Game.state.extraction_network_states.duplicate(true),
				"storage":Game.simulation.location_storage_snapshot(Game.state, SpaceGameState.MAIN_BASE_LOCATION_ID)
			}))
		for source_location in ["deep_system", "gas_giant_region", "asteroid_belt"]:
			if Game.state.item_quantity(item_id, source_location) <= 0:
				continue
			if not await _freight_remote_item_ui(main, source_location, item_id, true): return false
			if Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= target_quantity:
				return true
		# Give the permanent Earth network a normal chance to settle before taking
		# explicit control of a physical mining vessel. Once the starter ship is on
		# frontier duty, this network is also the legitimate bootstrap recovery path
		# for Earth maintenance materials. A three-second probe only yielded a small
		# fraction of a late-game BOM and incorrectly fell back to the remote mine
		# whose own operating stock depended on that BOM.
		if not local_network_available:
			var automatic_progress := await _wait_at_public_fast_speed(main, func() -> bool:
				return Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= target_quantity,
				3.0)
			if automatic_progress: return true
		var selection := _mining_selection_read_only(item_id)
		if selection.is_empty():
			return _journey_fail("no visible legal mining ship/site can replenish %s" % item_id)
		var ship_id := String(selection.get("ship_id", ""))
		var site_id := String(selection.get("site_id", ""))
		var source_location := String(selection.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		if source_location != SpaceGameState.MAIN_BASE_LOCATION_ID and not await _stage_remote_operating_stock_ui(main, source_location):
			return false
		# Remote starter depots intentionally have very little storage.  Empty any
		# already-mined cargo through the same visible logistics controls before
		# asking the mine for another batch; otherwise a legitimate STORAGE_FULL
		# boundary can make a fixed-size wait impossible.
		if source_location != SpaceGameState.MAIN_BASE_LOCATION_ID \
				and Game.state.item_quantity(item_id, source_location) > 0:
			await _stop_mining_site_ui(main, site_id, item_id)
			if not await _freight_remote_item_ui(main, source_location, item_id, true):
				return false
			if Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID) >= target_quantity:
				return true
			if not await _stage_remote_operating_stock_ui(main, source_location):
				return false
		if source_location != SpaceGameState.MAIN_BASE_LOCATION_ID:
			var remaining_at_destination := target_quantity - Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
			var current_free := Game.simulation.location_storage_free_quantity_for_item(Game.state, source_location, item_id)
			var current_bulk_capacity := _location_capacity_value(source_location, "BULK_STORAGE_UPGRADE")
			# Once a raw requirement exceeds the starter depot, make the strategic
			# storage investment through Construction instead of forcing dozens of
			# four-unit administrative batches. The upgrade has a real BOM, remote
			# freight demand and construction-capacity cost.
			var strategic_target := Game.simulation.suggested_location_capacity_upgrade_target(Game.state, source_location, "BULK_STORAGE_UPGRADE")
			if remaining_at_destination > current_free and current_bulk_capacity < 1000 \
					and _capacity_upgrade_supply_chain_is_unlocked(source_location, "BULK_STORAGE_UPGRADE", strategic_target):
				if not await _upgrade_worksite_capacity_ui(main, source_location, "BULK_STORAGE_UPGRADE", current_bulk_capacity + 1):
					return false
				if not await _stage_remote_operating_stock_ui(main, source_location):
					return false
		var runtime := _mining_runtime_for_site(site_id)
		if runtime.is_empty() or String(runtime.get("status", "")) not in ["RUNNING", "BLOCKED"]:
			# Freeze the simulation through the public speed control while the UI
			# creates the operation. A tiny frontier depot can otherwise complete
			# several cycles during UI settle frames before the baseline is sampled.
			await _press_named(main, "SpeedPause", "PAUSE_BEFORE_%s_MINING_BATCH" % item_id.to_upper())
			await _press_named(main, "Navigation_ships", "OPEN_SHIPS_TO_REPLENISH_%s" % item_id.to_upper())
			var roster_button := main.find_child("FleetSection_roster", true, false) as Button
			if roster_button != null and not roster_button.disabled:
				await _press_control(roster_button, "OPEN_ROSTER_TO_REPLENISH_%s" % item_id.to_upper())
			await _press_named(main, "AssignMining_%s" % ship_id, "ASSIGN_MINER_TO_REPLENISH_%s" % item_id.to_upper())
			await _press_named(main, "Navigation_survey", "OPEN_SURVEY_TO_REPLENISH_%s" % item_id.to_upper())
			await _press_named(main, "StartMining_%s" % site_id, "START_MINING_TO_REPLENISH_%s" % item_id.to_upper())
		var source_before := Game.state.item_quantity(item_id, source_location)
		var free_capacity: int = int(Game.simulation.logistics._destination_free_capacity(Game.state, source_location, item_id))
		var activity: Dictionary = Game.content.get_mining_activity_for_site(site_id)
		var cycle_output := 0
		for reward_value in activity.get("rewards", []):
			var reward := reward_value as Dictionary
			if String(reward.get("item", "")) == item_id:
				cycle_output += int(reward.get("quantity", 0))
		cycle_output = maxi(1, cycle_output)
		if free_capacity < cycle_output:
			# A mature automated home economy can legitimately fill its Bulk depot
			# while a large capital-goods BOM is being manufactured. Resolve that
			# player-visible STORAGE_FULL condition with the normal Location capacity
			# project, exactly as frontier depots do, instead of bypassing storage or
			# discarding the accumulated ore.
			var current_bulk_capacity := _location_capacity_value(source_location, "BULK_STORAGE_UPGRADE")
			var recovery_target := Game.simulation.suggested_location_capacity_upgrade_target(Game.state, source_location, "BULK_STORAGE_UPGRADE")
			if _capacity_upgrade_supply_chain_is_unlocked(source_location, "BULK_STORAGE_UPGRADE", recovery_target):
				if not await _upgrade_worksite_capacity_ui(main, source_location, "BULK_STORAGE_UPGRADE", current_bulk_capacity + 1):
					return false
				free_capacity = int(Game.simulation.logistics._destination_free_capacity(Game.state, source_location, item_id))
		if free_capacity < cycle_output:
			_print_mining_diagnostic(site_id, ship_id)
			return _journey_fail("visible mining cannot fit one %s output cycle at %s" % [item_id, source_location])
		var remaining_quantity := maxi(1, target_quantity - Game.state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID))
		var desired_cycles := ceili(float(remaining_quantity) / float(cycle_output))
		var capacity_cycles := floori(float(free_capacity) / float(cycle_output))
		var mine_increment: int = maxi(cycle_output, mini(desired_cycles, capacity_cycles) * cycle_output)
		var mined := await _wait_at_public_fast_speed(main, func() -> bool:
			return Game.state.item_quantity(item_id, source_location) >= source_before + mine_increment,
			JOURNEY_STAGE_TIMEOUT_SECONDS)
		# A mine can fill the last fractional storage slot before reaching the
		# integer capacity estimate.  Any physically produced unit is a valid
		# batch and is freighted immediately below.
		if not mined and Game.state.item_quantity(item_id, source_location) > source_before:
			mined = true
		if not mined:
			_print_mining_diagnostic(site_id, ship_id)
			return _journey_fail("visible mining did not replenish %s at %s" % [item_id, source_location])
		if source_location != SpaceGameState.MAIN_BASE_LOCATION_ID:
			await _stop_mining_site_ui(main, site_id, item_id)
			if not await _freight_remote_item_ui(main, source_location, item_id, true):
				return false
	return _journey_fail("raw-resource UI batching exceeded guard for %s target %d" % [item_id, target_quantity])


func _active_local_extraction_network_produces(item_id: String) -> bool:
	for network_id_value in Game.state.extraction_network_states.keys():
		var network_id := String(network_id_value)
		var runtime: Dictionary = Game.state.extraction_network_states.get(network_id, {})
		if not bool(runtime.get("unlocked", false)) or runtime.get("integrated_site_ids", []).is_empty():
			continue
		var network: Dictionary = Game.content.extraction_networks.get(network_id, {})
		if String(network.get("region", SpaceGameState.MAIN_BASE_LOCATION_ID)) != SpaceGameState.MAIN_BASE_LOCATION_ID:
			continue
		for site_id_value in runtime.get("integrated_site_ids", []):
			var site: Dictionary = Game.content.mining_sites.get(String(site_id_value), {})
			var mining_location: Dictionary = Game.content.mining_locations.get(String(site.get("location", "")), {})
			if String(mining_location.get("raw_material", "")) == item_id:
				return true
	return false


func _stop_mining_site_ui(main: Control, site_id: String, item_id: String) -> void:
	await _press_named(main, "Navigation_survey", "OPEN_SURVEY_TO_STOP_%s_MINING" % item_id.to_upper())
	var stop_button := main.find_child("StopMining_%s" % site_id, true, false) as Button
	if stop_button != null and stop_button.is_visible_in_tree() and not stop_button.disabled:
		await _press_control(stop_button, "STOP_MINING_AFTER_%s_BATCH" % item_id.to_upper())


func _mining_selection_read_only(item_id: String) -> Dictionary:
	# This helper is replenishing Earth inventory. Prefer a legal local source
	# before an already-running frontier mine. Otherwise producing the repair
	# stock needed by the frontier mine can select that same mine again and form
	# an operating-stock dependency cycle.
	for prefer_main_base in [true, false]:
		for runtime_value in Game.state.mining_operations:
			var runtime := runtime_value as Dictionary
			var runtime_location := String(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
			if (runtime_location == SpaceGameState.MAIN_BASE_LOCATION_ID) != prefer_main_base: continue
			if String(runtime.get("status", "")) not in ["RUNNING", "BLOCKED"]: continue
			var activity: Dictionary = Game.content.activities.get(String(runtime.get("activity_id", "")), {})
			if not activity.get("rewards", []).any(func(reward): return String((reward as Dictionary).get("item", "")) == item_id): continue
			var ship_ids: Array = runtime.get("ship_ids", [])
			if ship_ids.is_empty(): continue
			return {"site_id":String(runtime.get("site_id", "")), "ship_id":String(ship_ids[0]), "location_id":runtime_location}
	for prefer_main_base in [true, false]:
		for site_id_value in Game.content.mining_sites.keys():
			var site_id := String(site_id_value)
			if not Game.state.mining_site_available(site_id): continue
			var activity: Dictionary = Game.content.get_mining_activity_for_site(site_id)
			var mining_location: Dictionary = Game.content.mining_locations.get(String(activity.get("location", "")), {})
			var location_id := String(mining_location.get("region", SpaceGameState.MAIN_BASE_LOCATION_ID))
			if (location_id == SpaceGameState.MAIN_BASE_LOCATION_ID) != prefer_main_base: continue
			var produces_item := false
			for reward_value in activity.get("rewards", []):
				if String((reward_value as Dictionary).get("item", "")) == item_id:
					produces_item = true
			if not produces_item: continue
			for ship_value in Game.state.ships:
				var ship := ship_value as Dictionary
				var ship_id := String(ship.get("instance_id", ""))
				if not Game.state.ship_is_docked(ship_id): continue
				if Game.simulation.mining_power(Game.state, [ship_id]) <= 0.0: continue
				if not Game.simulation.build_requirements_met(Game.state, activity, [ship_id]): continue
				return {"site_id":site_id, "ship_id":ship_id, "location_id":location_id}
	return {}


func _mining_runtime_for_site(site_id: String) -> Dictionary:
	for runtime_value in Game.state.mining_operations:
		var runtime := runtime_value as Dictionary
		if String(runtime.get("site_id", "")) == site_id:
			return runtime.duplicate(true)
	return {}


func _assign_ship_and_open_route(main: Control, ship_id: String, route_id: String) -> void:
	await _press_named(main, "Navigation_ships", "OPEN_SHIPS_FOR_%s" % route_id.to_upper())
	var roster_button := main.find_child("FleetSection_roster", true, false) as Button
	if roster_button != null and not roster_button.disabled:
		await _press_control(roster_button, "OPEN_SHIP_ROSTER_FOR_%s" % route_id.to_upper())
	await _press_named(main, "AssignExpedition_%s" % ship_id, "ASSIGN_EXPEDITION_FOR_%s" % route_id.to_upper())
	await _press_named(main, "ShipsMissions", "OPEN_MISSIONS_FOR_%s" % route_id.to_upper())
	await _press_named(main, "StartRoute_%s" % route_id, "START_ROUTE_%s" % route_id.to_upper())


func _wait_at_public_fast_speed(main: Control, predicate: Callable, timeout_seconds: float) -> bool:
	var simulation_before := int(Game.state.total_elapsed_ms)
	await _press_named(main, "Speed100", "SET_GAME_SPEED_100_FOR_LONG_WAIT")
	# A preceding player-visible Pause is used while editing bounded logistics or
	# assigning a mining vessel. Verify the speed command has crossed a real
	# simulation boundary before starting the wall-clock timeout. On Windows the
	# first post-pause frame can occasionally retain a zero delta; reselecting 1×
	# then 100× through the same top-bar controls provides a bounded UI recovery.
	if int(Game.state.total_elapsed_ms) <= simulation_before:
		print("FULL_GAMEPLAY_UI_SPEED_RECOVERY=", JSON.stringify({
			"before":simulation_before,
			"after_first_press":int(Game.state.total_elapsed_ms),
			"engine_time_scale":Engine.time_scale,
			"game_processing":Game.is_processing(),
			"tree_paused":get_tree().paused,
			"game_accumulator_ms":Game.get("_simulation_accumulator_ms"),
			"next_boundary_ms":Game.simulation.next_state_change_ms(Game.state),
			"industry":Game.state.industrial_operations.map(func(operation_value):
				var operation := operation_value as Dictionary
				return {"activity_id":operation.get("activity_id", ""), "status":operation.get("status", ""), "blocked_reason":operation.get("blocked_reason", ""), "progress_ms":operation.get("progress_ms", 0.0), "location_id":operation.get("location_id", "")}),
			"extraction_networks":Game.state.extraction_network_states.duplicate(true),
			"logistics":Game.state.logistics_network.duplicate(true),
			"research":Game.state.research.duplicate(true),
			"active_expedition":Game.state.active_expedition.duplicate(true)
		}))
		await _press_named(main, "Speed1", "RECOVER_GAME_SPEED_1_AFTER_PAUSE")
		await _press_named(main, "Speed100", "RECOVER_GAME_SPEED_100_AFTER_PAUSE")
		var resumed := await _wait_until(func() -> bool:
			return int(Game.state.total_elapsed_ms) > simulation_before,
			1.0)
		if not resumed:
			print("FULL_GAMEPLAY_UI_SPEED_RECOVERY_DEFERRED=true")
	var completed := await _wait_until(predicate, timeout_seconds)
	await _press_named(main, "Speed10", "RETURN_GAME_SPEED_10_AFTER_LONG_WAIT")
	return completed


func _open_location_from_system(main: Control, location_id: String) -> void:
	await _press_named(main, "Navigation_system_map", "OPEN_SYSTEM_FOR_%s" % location_id.to_upper())
	await _press_named(main, "Location_%s" % location_id, "OPEN_LOCATION_%s" % location_id.to_upper())


func _first_enabled_button(root: Node, prefix: String) -> Button:
	for candidate_value in root.find_children("%s*" % prefix, "Button", true, false):
		var candidate := candidate_value as Button
		if candidate.is_visible_in_tree() and not candidate.disabled:
			return candidate
	return null


func _wait_until(predicate: Callable, wall_timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(wall_timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			await _settle_ui()
			return true
		# ignore_time_scale=true: this polling delay measures wall time while the
		# game advances only because the player selected a normal top-bar speed.
		await get_tree().create_timer(WALL_POLL_SECONDS, true, false, true).timeout
	return bool(predicate.call())


func _settle_ui() -> void:
	await get_tree().process_frame
	# Main intentionally coalesces dirty page rebuilds for 180 ms. Wait past that
	# public UI refresh boundary so the next lookup observes the replacement tree.
	await get_tree().create_timer(0.21, true, false, true).timeout
	await get_tree().process_frame


func _starter_ship_is_assigned_to_mining() -> bool:
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		if String(ship.get("blueprint_id", "")) == "patchwork_prospector":
			return Game.state.ship_fleet_domain(String(ship.get("instance_id", ""))) == "mining"
	return false


func _has_running_extraction() -> bool:
	for operation_value in Game.state.mining_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("site_id", "")) == "earth_resource_cluster_prospect" \
			and String(operation.get("status", "")) == "RUNNING":
			return true
	return false


func _industry_activity_is_running(activity_id: String) -> bool:
	for operation_value in Game.state.industrial_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")) == activity_id \
			and String(operation.get("status", "")) == "RUNNING":
			return true
	return false


func _industry_runtime(activity_id: String) -> Dictionary:
	for operation_value in Game.state.industrial_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")) == activity_id \
			and String(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == SpaceGameState.MAIN_BASE_LOCATION_ID:
			return operation.duplicate(true)
	return {}


func _construction_activity_exists(activity_id: String) -> bool:
	for operation_value in Game.state.construction_operations:
		if String((operation_value as Dictionary).get("activity_id", "")) == activity_id:
			return true
	return false


func _facility_expansion_exists(facility_id: String) -> bool:
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("project_type", "")) == "FACILITY_EXPANSION" \
			and String(operation.get("target_id", "")) == facility_id:
			return true
	return false


func _network_has_site(network_id: String, site_id: String) -> bool:
	var runtime: Dictionary = Game.state.extraction_network_states.get(network_id, {})
	return site_id in runtime.get("integrated_site_ids", [])


func _facility_has_process_module(facility_id: String, module_id: String) -> bool:
	var facility: Dictionary = Game.state.facilities.get(facility_id, {})
	return module_id in facility.get("installed_process_modules", [])


func _ship_id_for_blueprint(blueprint_id: String) -> String:
	for ship_value in Game.state.ships:
		var ship := ship_value as Dictionary
		if String(ship.get("blueprint_id", "")) == blueprint_id:
			return String(ship.get("instance_id", ""))
	return ""


func _print_time_orchestration_diagnostic(activity_id: String) -> void:
	var runtime := {}
	for operation_value in Game.state.construction_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("activity_id", "")) == activity_id:
			runtime = operation.duplicate(true)
			break
	print("FULL_GAMEPLAY_UI_TIMEOUT=", JSON.stringify({
		"activity_id":activity_id,
		"total_simulation_ms":int(Game.state.total_elapsed_ms),
		"unprocessed_accumulator_ms":float(Game.get("_simulation_accumulator_ms")),
		"runtime":runtime
	}))


func _print_mining_diagnostic(site_id: String, ship_id: String) -> void:
	var runtimes: Array = []
	var inventory_locations: Array[String] = []
	for operation_value in Game.state.mining_operations:
		var operation := operation_value as Dictionary
		if String(operation.get("site_id", "")) == site_id:
			runtimes.append(operation.duplicate(true))
			var runtime_location_id := String(operation.get("location_id", ""))
			var mining_location: Dictionary = Game.content.mining_locations.get(runtime_location_id, {})
			var inventory_location_id := String(mining_location.get("region", runtime_location_id))
			if Game.state.has_location(inventory_location_id) and inventory_location_id not in inventory_locations:
				inventory_locations.append(inventory_location_id)
	var location_storage := {}
	for location_id in inventory_locations:
		location_storage[location_id] = {
			"inventory":Game.state.location_inventory(location_id).duplicate(true),
			"storage":Game.simulation.location_storage_snapshot(Game.state, location_id)
		}
	print("FULL_GAMEPLAY_UI_MINING_TIMEOUT=", JSON.stringify({
		"site_id":site_id,
		"ship":Game.state.ship_by_id(ship_id).duplicate(true),
		"runtimes":runtimes,
		"location_storage":location_storage,
		"belt_inventory":Game.state.location_inventory("asteroid_belt").duplicate(true),
		"completed_cycles":int(Game.state.completed_activities.get("extract_belt_mixed_ore", 0)),
		"extraction_command_usage":Game.simulation.extraction_command_usage(Game.state),
		"extraction_command_capacity":Game.simulation.extraction_command_capacity(Game.state),
		"total_simulation_ms":int(Game.state.total_elapsed_ms)
	}))


func _print_logistics_diagnostic(item_ids: Array) -> void:
	var location_rows := {}
	for location_id in [SpaceGameState.MAIN_BASE_LOCATION_ID, "lunar_space", "asteroid_belt"]:
		var state_entry: Dictionary = Game.state.location_state(location_id)
		var inventory := {}
		for item_id_value in item_ids:
			var item_id := String(item_id_value)
			inventory[item_id] = Game.state.item_quantity(item_id, location_id)
		location_rows[location_id] = {
			"inventory":inventory,
			"policies":state_entry.get("logistics", {}).get("policies", {}).duplicate(true),
			"storage":state_entry.get("logistics", {}).get("storage_capacities", {}).duplicate(true),
			"hub":state_entry.get("logistics", {}).get("hub_throughput", 0)
		}
	print("FULL_GAMEPLAY_UI_LOGISTICS_TIMEOUT=", JSON.stringify({
		"locations":location_rows,
		"shipments":Game.state.logistics_network.get("shipments", []).duplicate(true),
		"services":Game.state.logistics_network.get("services", {}).duplicate(true),
		"statistics":Game.state.logistics_network.get("item_statistics", {}).duplicate(true),
		"total_simulation_ms":int(Game.state.total_elapsed_ms)
	}))


func _assert_journey_evidence(main: Control) -> void:
	var required_events := [
		"NEW_GAME",
		"FIRST_FLEET_ASSIGNMENT",
		"FIRST_EXTRACTION_STARTED",
		"FIRST_EXTRACTION",
		"FIRST_PRODUCTION_STARTED",
		"FIRST_PROCESSED_MATERIAL",
		"FIRST_REFINED_IRON",
		"FIRST_REFINED_COPPER",
		"FIRST_STRUCTURAL_FRAME",
		"FIRST_FACILITY_CONSTRUCTION_STARTED",
		"FIRST_FACILITY_COMPLETED",
		"ESTABLISH_INDUSTRY_COMPLETED",
		"FIRST_RESEARCH_PROGRAM",
		"FIRST_CAPITAL_GOOD",
		"FIRST_FACILITY_UPGRADE",
		"EARTH_EXTRACTION_AUTOMATED",
		"FIRST_ROUTE_COMPLETED",
		"FIRST_PROTOTYPE",
		"FIRST_FIELD_TEST",
		"ADVANCED_PROPULSION_COMPLETED",
		"FIRST_COMMISSIONED_SHIP",
		"ASTEROID_BELT_REACHED",
		"FIRST_REMOTE_SURVEY",
		"FIRST_REMOTE_EXTRACTION",
		"FIRST_REMOTE_FREIGHT",
		"FIRST_ADVANCED_INDUSTRY_RESEARCH",
		"FIRST_STEEL"
	]
	_check(required_events.all(func(event_id: String) -> bool: return journey_event_log.has(event_id)), "Journey Event Log contains every achieved early-industry milestone in order")
	_check(_ordered_subsequence(journey_event_log, required_events), "Journey Event Log preserves the expected causal milestone order while continuing into endgame")

	var telemetry := main.call("telemetry_snapshot") as Dictionary
	var telemetry_actions: Array = telemetry.get("actions_exercised", [])
	var core_screens := [
		"system_map", "location", "industry", "inventory", "logistics",
		"construction", "research", "fleet", "frontier", "megastructure",
		"diagnostics"
	]
	var screens_visited: Array = telemetry.get("screens_visited", [])
	var screens_never_visited := core_screens.filter(func(screen_id: String) -> bool: return not screens_visited.has(screen_id))
	_check(screens_never_visited.is_empty(), "UI telemetry proves every core screen was reached through visible Navigation controls")
	_check(telemetry_actions.has("SET_GAME_SPEED"), "UI telemetry records the normal speed-control action")
	_check(_telemetry_has_domain_event(telemetry, "extract_earth_mixed_ore"), "UI telemetry observes the real extraction completion event")
	_check(_telemetry_has_domain_event(telemetry, "separate_iron_ore"), "UI telemetry observes the real production completion event")
	_check(_telemetry_has_domain_event(telemetry, "build_orbital_foundry"), "UI telemetry observes the real Foundry construction completion event")
	var required_actions := [
		"OPEN_NEW_GAME_CONFIRMATION",
		"CONFIRM_NEW_GAME",
		"OPEN_SHIPS",
		"ASSIGN_SHIP_MINING",
		"OPEN_SURVEY",
		"START_EXTRACTION",
		"SET_GAME_SPEED_10",
		"OPEN_INDUSTRY",
		"START_SEPARATE_IRON_ORE",
		"STOP_SEPARATE_IRON_ORE",
		"START_REFINE_IRON",
		"STOP_REFINE_IRON",
		"START_SEPARATE_COPPER_ORE",
		"STOP_SEPARATE_COPPER_ORE",
		"START_REFINE_COPPER",
		"STOP_REFINE_COPPER",
		"START_ASSEMBLE_FRAME",
		"STOP_ASSEMBLE_FRAME",
		"OPEN_CONSTRUCTION",
		"START_ORBITAL_FOUNDRY_CONSTRUCTION",
		"START_HIGH_ENERGY_SYSTEMS_CONSTRUCTION",
		"START_RESEARCH_COMPLEX_CONSTRUCTION",
		"START_FIRST_RESEARCH_PROGRAM",
		"SET_GAME_SPEED_100",
		"RETURN_GAME_SPEED_10",
		"START_FABRICATE_BASIC_MACHINE_TOOLS",
		"START_FIRST_FACILITY_EXPANSION",
		"START_EARTH_EXTRACTION_NETWORK",
		"INTEGRATE_EARTH_MINING_SITE",
		"START_ROUTE_LUNAR_ROUTE",
		"START_ADVANCED_PROPULSION_HIGH_THRUST",
		"START_ROUTE_PROPULSION_PROVING_ROUTE",
		"START_PATHFINDER_DEVELOPMENT",
		"BUILD_PATHFINDER",
		"START_ROUTE_ASTEROID_ROUTE",
		"START_BELT_INDUSTRIAL_SURVEY",
		"INSTALL_PRECISION_MECHANICS_CELL",
		"INSTALL_PATHFINDER_DEEP_CORE_DRILL",
		"START_BELT_EXTRACTION",
		"ADD_SUPPLY_POLICY_CHEMICAL_PROPELLANT_AT_EARTH_ORBIT",
		"ADD_SUPPLY_POLICY_REPAIR_MATERIAL_AT_EARTH_ORBIT",
		"ADD_DEMAND_POLICY_CHEMICAL_PROPELLANT_AT_ASTEROID_BELT",
		"ADD_DEMAND_POLICY_REPAIR_MATERIAL_AT_ASTEROID_BELT",
		"CLEAR_FULFILLED_BELT_PROPELLANT_DEMAND",
		"ADD_SUPPLY_POLICY_MIXED_RAW_ORE_AT_ASTEROID_BELT",
		"ADD_DEMAND_POLICY_MIXED_RAW_ORE_AT_EARTH_ORBIT",
		"INSTALL_PROCESS_MODULE_CRYOGENIC_PROCESS_UNIT",
		"INSTALL_PROCESS_MODULE_RADIATION_ELECTRONICS_CELL",
		"START_HEAVY_INDUSTRY_RESEARCH",
		"START_HEAVY_EXTRACTION_RESEARCH",
		"INSTALL_PROCESS_MODULE_ADVANCED_ALLOY_CELL",
		"START_REFINE_STEEL",
		"SELECT_STELLAR_ENERGY_SITE",
		"OPEN_MEGASTRUCTURE_PHASE_1",
		"START_MEGASTRUCTURE_PHASE_1",
		"OPEN_MEGASTRUCTURE_PHASE_2",
		"START_MEGASTRUCTURE_PHASE_2",
		"OPEN_MEGASTRUCTURE_PHASE_3",
		"START_MEGASTRUCTURE_PHASE_3",
		"OPEN_MEGASTRUCTURE_PHASE_4",
		"START_MEGASTRUCTURE_PHASE_4",
		"OPEN_MEGASTRUCTURE_PHASE_5",
		"START_MEGASTRUCTURE_PHASE_5",
		"OPEN_MEGASTRUCTURE_PHASE_6",
		"START_MEGASTRUCTURE_PHASE_6",
		"OPEN_MEGASTRUCTURE_PHASE_7",
		"START_MEGASTRUCTURE_PHASE_7",
		"PAUSE_GAME"
	]
	var executed_actions: Array = player_action_execution_log.map(func(entry: Dictionary) -> String: return String(entry.get("action_id", "")))
	_check(required_actions.all(func(action_id: String) -> bool: return executed_actions.has(action_id)), "PlayerActionExecutionLog contains every mandatory visible control used by this Journey")
	_check(player_action_execution_log.size() >= required_actions.size(), "PlayerActionExecutionLog retains the complete ordered interaction trace")
	print("FULL_GAMEPLAY_UI_ACTION_LOG=" + JSON.stringify(player_action_execution_log))
	print("FULL_GAMEPLAY_UI_JOURNEY_LOG=" + JSON.stringify(journey_event_log))
	var completed_journey_ids := _validate_registry_journeys()
	var ui_only_contract := _audit_harness_ui_only_contract()
	_check((ui_only_contract.get("directGameplayCommands", []) as Array).is_empty(), "Fresh Save harness never calls a gameplay command directly")
	_check((ui_only_contract.get("directStateWrites", []) as Array).is_empty(), "Fresh Save harness never writes Domain state directly")
	_write_runtime_evidence(required_events, required_actions, executed_actions, completed_journey_ids, ui_only_contract, telemetry)


func _audit_harness_ui_only_contract() -> Dictionary:
	var source := FileAccess.get_file_as_string("res://tests/full_gameplay_ui_test.gd")
	var direct_state_writes: Array[String] = []
	var direct_gameplay_commands: Array[String] = []
	var state_assignment := RegEx.new()
	var state_container_mutation := RegEx.new()
	var simulation_mutation := RegEx.new()
	var direct_game_call := RegEx.new()
	state_assignment.compile(r"Game\.state[^\r\n]*(?:\+=|-=|\*=|/=|%=|[^=!<>]=[^=])")
	state_container_mutation.compile(r"Game\.state[^\r\n]*\.(append|assign|clear|erase|fill|merge|pop_back|pop_front|push_back|push_front|remove_at|resize|reverse|set)\s*\(")
	simulation_mutation.compile(r"Game\.simulation\.(advance|advance_offline|process_boundary|process_interval|reset|step|tick)\s*\(")
	direct_game_call.compile(r"Game\.([A-Za-z_][A-Za-z0-9_]*)\s*\(")
	for line_index in source.split("\n").size():
		var line := String(source.split("\n")[line_index])
		if line.strip_edges().begins_with("#"):
			continue
		if state_assignment.search(line) != null or state_container_mutation.search(line) != null or simulation_mutation.search(line) != null:
			direct_state_writes.append("%d:%s" % [line_index + 1, line.strip_edges()])
		for call_match in direct_game_call.search_all(line):
			var method_name := call_match.get_string(1)
			if method_name not in ["get", "can_start_activity", "is_processing"]:
				direct_gameplay_commands.append("%d:Game.%s" % [line_index + 1, method_name])
	return {
		"directGameplayCommands":direct_gameplay_commands,
		"directStateWrites":direct_state_writes
	}


func _write_runtime_evidence(required_events: Array, required_actions: Array, executed_actions: Array, completed_journey_ids: Array, ui_only_contract: Dictionary, telemetry: Dictionary) -> void:
	var mega_project: Dictionary = Game.state.megastructure_projects.get("stellar_energy", {})
	var core_screens := [
		"system_map", "location", "industry", "inventory", "logistics",
		"construction", "research", "fleet", "frontier", "megastructure",
		"diagnostics"
	]
	var screens_visited: Array = telemetry.get("screens_visited", []).duplicate()
	screens_visited.sort()
	var screens_never_visited := core_screens.filter(func(screen_id: String) -> bool: return not screens_visited.has(screen_id))
	var actions_exercised: Array = []
	for action_id_value in executed_actions:
		var action_id := String(action_id_value)
		if not actions_exercised.has(action_id):
			actions_exercised.append(action_id)
	var actions_never_exercised := required_actions.filter(func(action_id: String) -> bool: return not actions_exercised.has(action_id))
	var journey_complete := bool(Game.state.game_complete) \
		and bool(Game.state.megastructures.get("stellar_energy", false)) \
		and (mega_project.get("phase_history", []) as Array).size() == 8 \
		and completed_journey_ids.size() == 10 \
		and screens_never_visited.is_empty() \
		and actions_never_exercised.is_empty() \
		and failures.is_empty()
	var evidence := {
		"schemaVersion":1,
		"runId":evidence_run_id,
		"generatedAtUnixMs":int(Time.get_unix_time_from_system() * 1000.0),
		"claim":"FULL_FRESH_SAVE_UI_ONLY_EVIDENCE" if journey_complete else "PARTIAL_FRESH_SAVE_UI_ONLY_EVIDENCE",
		"source":"res://tests/full_gameplay_ui_test.gd",
		"freshSave":true,
		"uiOnly":true,
		"usesDirectGameplayCommands":not (ui_only_contract.get("directGameplayCommands", []) as Array).is_empty(),
		"usesDirectStateWrites":not (ui_only_contract.get("directStateWrites", []) as Array).is_empty(),
		"uiOnlyContract":ui_only_contract,
		"journeyComplete":journey_complete,
		"highestVerifiedMilestone":"MEGASTRUCTURE_COMPLETED" if journey_complete else (journey_event_log[-1] if not journey_event_log.is_empty() else "NONE"),
		"completedJourneyIds":completed_journey_ids,
		"registryJourneyEvents":registry_journey_events,
		"requiredMilestones":required_events,
		"observedMilestones":journey_event_log,
		"requiredVisibleControls":required_actions,
		"executedVisibleControls":executed_actions,
		"orderedControlTrace":player_action_execution_log,
		"telemetry":telemetry,
		"screensVisited":screens_visited,
		"screensNeverVisited":screens_never_visited,
		"actionsExercised":actions_exercised,
		"actionsNeverExercised":actions_never_exercised,
		"blockersEncountered":telemetry.get("blockers_encountered", []).duplicate(true),
		"guidancePathsUsed":telemetry.get("guidance_paths_used", []).duplicate(true),
		"executionOnlyRegistryActions":[
			"RESET_GAME", "SET_GAME_SPEED", "ASSIGN_SHIP", "START_EXTRACTION",
			"START_PRODUCTION", "STOP_PRODUCTION", "START_CONSTRUCTION",
			"START_RESEARCH", "EXPAND_FACTORY"
		],
		"strictFourCaseActionCoverage":[],
		"blockingUiSurface":{},
		"unverifiedMandatoryMilestones":[] if journey_complete else ["MEGASTRUCTURE_COMPLETED"]
	}
	var directory_path := ProjectSettings.globalize_path("res://artifacts/test-results")
	DirAccess.make_dir_recursive_absolute(directory_path)
	var file := FileAccess.open(EVIDENCE_PATH, FileAccess.WRITE)
	if file == null:
		failures.append("FAIL: cannot write Full Gameplay UI evidence")
		return
	file.store_string(JSON.stringify(evidence, "  "))
	file.close()


func _validate_registry_journeys() -> Array:
	var completed: Array = []
	var registry: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gameplay_journey_registry.json"))
	for journey_value in registry.get("journeys", []):
		var journey := journey_value as Dictionary
		var journey_id := String(journey.get("journeyId", ""))
		var expected: Array = journey.get("events", [])
		var observed: Array = registry_journey_events.get(journey_id, [])
		var exact := observed == expected
		_check(exact, "%s records every registry event in exact causal order: expected=%s observed=%s" % [journey_id, str(expected), str(observed)])
		if exact:
			completed.append(journey_id)
	_check(completed.size() == 10, "all ten declared Gameplay Journeys complete through one fresh-save UI trace")
	return completed


func _ordered_subsequence(observed: Array, expected: Array) -> bool:
	var cursor := 0
	for value in observed:
		if cursor < expected.size() and value == expected[cursor]:
			cursor += 1
	return cursor == expected.size()


func _telemetry_has_domain_event(telemetry: Dictionary, entity_id: String) -> bool:
	for event_value in telemetry.get("events", []):
		var event := event_value as Dictionary
		if String(event.get("type", "")) == "DomainEvent" and String(event.get("entity_id", "")) == entity_id:
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append("FAIL: " + message)
		push_error("FAIL: " + message)


func _finish(main: Control) -> void:
	main.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("FULL_GAMEPLAY_UI_TERMINAL=PASS")
		print("Full Gameplay UI fresh-save complete ten-Journey playthrough passed")
		get_tree().quit(0)
	else:
		for failure in failures:
			print(failure)
		get_tree().quit(1)
