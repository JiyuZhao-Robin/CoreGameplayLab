extends SceneTree

## Focused contract coverage for FactoryDspProjects.  This fixture is isolated
## from Game, saves and UI; the integration owner owns the caller that consumes
## allowed inputs and applies the returned effects.

const Projects = preload("res://src/core/factory_dsp_projects.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_test_source_project_constants_are_lossless()
	_test_catalog_extension_preserves_gates_and_real_recipes()
	_test_export_completion_is_pure_then_accumulates_source_rewards()
	_test_black_hole_requires_explicit_selected_recipe_authorization()
	_test_station_only_accepts_the_current_material_phase()
	_test_time_warp_stability_matches_source_thresholds()
	_finish()


func _test_source_project_constants_are_lossless() -> void:
	var export_ids: Array[String] = []
	for project_value in Projects.GALACTIC_EXPORTS:
		var project := project_value as Dictionary
		export_ids.append(str(project.get("id", "")))
	_check(export_ids == ["universe_archive", "solar_sail_array", "carrier_rocket_fleet", "antimatter_exchange"], "all four source export projects retain their stable project order")
	_check(
		int((Projects.GALACTIC_EXPORTS[0] as Dictionary).get("base_target", 0)) == 1000
		and float((Projects.GALACTIC_EXPORTS[0] as Dictionary).get("target_growth", 0.0)) == 1.55
		and int((Projects.GALACTIC_EXPORTS[3] as Dictionary).get("base_target", 0)) == 500
		and int((Projects.GALACTIC_EXPORTS[3] as Dictionary).get("credits_per_item", 0)) == 80,
		"source export target, growth and credit constants remain lossless"
	)
	var expected_phases := [
		["titanium_alloy", 1000000], ["dsp_frame_material", 500000], ["dsp_small_carrier_rocket", 100000], ["dsp_universe_matrix", 100000],
		["dsp_frame_material", 2000000], ["dsp_dyson_sphere_component", 1000000], ["dsp_titanium_glass", 1000000], ["dsp_quantum_chip", 500000],
		["dsp_antimatter_fuel_rod", 250000], ["dsp_annihilation_constraint_sphere", 500000], ["dsp_strange_matter", 1000000], ["dsp_plane_filter", 1000000],
		["dsp_processor", 5000000], ["dsp_particle_broadband", 2000000], ["dsp_quantum_chip", 2000000], ["dsp_universe_matrix", 1000000]
	]
	var actual_phases: Array = []
	for phase_value in Projects.SPACE_STATION_PHASES:
		var phase := phase_value as Dictionary
		actual_phases.append([str(phase.get("item_id", "")), int(phase.get("amount", 0))])
	_check(actual_phases == expected_phases, "all sixteen source station phases preserve their exact item and amount order")


func _test_catalog_extension_preserves_gates_and_real_recipes() -> void:
	var items := {
		"dsp_universe_matrix":{"id":"dsp_universe_matrix", "category":"Special Equipment"},
		"dsp_solar_sail":{"id":"dsp_solar_sail", "category":"Component"},
		"dsp_small_carrier_rocket":{"id":"dsp_small_carrier_rocket", "category":"Component"},
		"dsp_antimatter_fuel_rod":{"id":"dsp_antimatter_fuel_rod", "category":"Component"},
		"titanium_alloy":{"id":"titanium_alloy", "category":"Processed Material"},
		"building_grid_dsp_example":{"id":"building_grid_dsp_example", "category":"Building", "building_definition_id":"grid_dsp_example"}
	}
	var gates := [{"type":"technology", "id":"megastructure_engineering"}]
	var buildings := {
		"grid_dsp_galactic_material_exporter":{"id":"grid_dsp_galactic_material_exporter", "kind":"MACHINE", "requirements":gates, "reveal_requirements":gates},
		"grid_dsp_micro_black_hole_connector":{"id":"grid_dsp_micro_black_hole_connector", "kind":"MACHINE", "requirements":gates},
		"grid_dsp_space_station_construction_launcher":{"id":"grid_dsp_space_station_construction_launcher", "kind":"STORAGE", "input_capacity":0, "output_capacity":0, "runtime_metadata":{}},
		"grid_dsp_time_warp_device":{"id":"grid_dsp_time_warp_device", "kind":"MACHINE", "runtime_metadata":{}}
	}
	var recipes := {}
	Projects.extend_catalog(items, buildings, recipes)
	_check(recipes.has("dsp_export_universe_archive") and (recipes["dsp_export_universe_archive"] as Dictionary).get("requirements", []) == gates, "export recipes inherit the source building's active technology gates")
	_check((recipes["dsp_export_universe_archive"] as Dictionary).get("inputs", []) == [{"item":"dsp_universe_matrix", "quantity":1}] and (recipes["dsp_export_universe_archive"] as Dictionary).get("outputs", []).is_empty(), "export is a real one-item global-project sink rather than ordinary manufacture")
	_check(str(buildings["grid_dsp_space_station_construction_launcher"].get("kind", "")) == "MACHINE" and (buildings["grid_dsp_space_station_construction_launcher"].get("recipe_ids", []) as Array).size() == 16, "station launcher becomes a recipe-capable machine with all sixteen exact source phases")
	_check(not recipes.has("dsp_black_hole_destroy_building_grid_dsp_example") and recipes.has("dsp_black_hole_destroy_dsp_solar_sail"), "black hole expands every ordinary item but never turns a finished building item into a destruction recipe")
	_check(str(buildings["grid_dsp_time_warp_device"].get("runtime_metadata", {}).get("special_effect_id", "")) == "TIME_WARP", "time warp receives explicit runtime ownership metadata without a fake production recipe")


func _test_export_completion_is_pure_then_accumulates_source_rewards() -> void:
	var world := {"dsp_effects":{}}
	var recipe := {
		"id":"dsp_export_universe_archive",
		"runtime_metadata":{"recipe_mode":"GLOBAL_PROJECT", "special_effect_id":"GALACTIC_EXPORT", "project_id":"universe_archive", "base_target":1000, "target_growth":1.55, "credits_per_item":12, "base_rate_per_minute":120, "reserve":120}
	}
	var before := world.duplicate(true)
	var result := Projects.finish_recipe(world, {}, recipe, 1000)
	_check(world == before and int(result.get("allowed_cycles", 0)) == 1000, "global export completion is pure and permits exactly the caller's real input cycles")
	Projects.apply_effects(world, result.get("effects", {}))
	var effects: Dictionary = world["dsp_effects"]
	var project: Dictionary = effects.get("export_projects", {}).get("universe_archive", {})
	_check(int(project.get("level", 0)) == 1 and int(project.get("delivered", -1)) == 0 and int(project.get("total_delivered", 0)) == 1000, "source base target advances export level and retains only post-target delivery")
	_check(int(effects.get("galactic_credits", 0)) == 24000 and int(effects.get("export_levels", {}).get("universe_archive", 0)) == 1, "delivery credits plus the source level-completion reward accumulate in the canonical effect record")


func _test_black_hole_requires_explicit_selected_recipe_authorization() -> void:
	var world := {"dsp_effects":{}}
	var recipe := {"id":"dsp_black_hole_destroy_dsp_solar_sail", "runtime_metadata":{"recipe_mode":"BLACK_HOLE", "special_effect_id":"BLACK_HOLE_DESTROY", "destroyed_item_id":"dsp_solar_sail"}}
	var blocked := Projects.finish_recipe(world, {}, recipe, 3)
	_check(int(blocked.get("allowed_cycles", -1)) == 0 and str(blocked.get("blocked", "")) == "BLACK_HOLE_AUTHORIZATION_REQUIRED", "an unselected or unconfirmed black-hole machine consumes nothing")
	var entity := {"black_hole_authorized_recipe_id":"dsp_black_hole_destroy_dsp_solar_sail"}
	var accepted := Projects.finish_recipe(world, entity, recipe, 3)
	_check(int(accepted.get("allowed_cycles", 0)) == 3 and int(accepted.get("effects", {}).get("destroyed", {}).get("dsp_solar_sail", 0)) == 3, "the UI-confirmed selected recipe returns one exact destroyed-item manifest")
	Projects.apply_effects(world, accepted.get("effects", {}))
	_check(int(world["dsp_effects"].get("destroyed", {}).get("dsp_solar_sail", 0)) == 3, "black-hole destruction has one canonical accumulated record")


func _test_station_only_accepts_the_current_material_phase() -> void:
	var phase_zero := {
		"id":"dsp_station_phase_00",
		"runtime_metadata":{"recipe_mode":"GLOBAL_PROJECT", "special_effect_id":"SPACE_STATION_DELIVERY", "station_phase_index":0, "station_phase_name":"轨道基座", "station_item_id":"titanium_alloy", "station_required_amount":1000000}
	}
	var phase_one := {
		"id":"dsp_station_phase_01",
		"runtime_metadata":{"recipe_mode":"GLOBAL_PROJECT", "special_effect_id":"SPACE_STATION_DELIVERY", "station_phase_index":1, "station_phase_name":"轨道基座", "station_item_id":"dsp_frame_material", "station_required_amount":500000}
	}
	var world := {"dsp_effects":{"station_phase_index":0, "station_delivered":{"0":999999}}}
	var blocked := Projects.finish_recipe(world, {}, phase_one, 1)
	_check(int(blocked.get("allowed_cycles", -1)) == 0 and str(blocked.get("blocked", "")) == "STATION_PHASE_LOCKED", "a later station phase cannot consume its material early")
	var final_unit := Projects.finish_recipe(world, {}, phase_zero, 5)
	_check(int(final_unit.get("allowed_cycles", 0)) == 1, "station completion clamps consumption to the exact remaining material instead of wasting a batch")
	Projects.apply_effects(world, final_unit.get("effects", {}))
	_check(int(world["dsp_effects"].get("station_phase_index", 0)) == 1 and int(world["dsp_effects"].get("station_delivered", {}).get("0", 0)) == 1000000, "applying one accepted final unit advances only the current phase")
	var completed_phase := Projects.finish_recipe(world, {}, phase_zero, 1)
	_check(int(completed_phase.get("allowed_cycles", -1)) == 0 and str(completed_phase.get("blocked", "")) == "STATION_PHASE_LOCKED", "a completed previous phase cannot consume material indefinitely")


func _test_time_warp_stability_matches_source_thresholds() -> void:
	_check(Projects.stable_multiplier(99999.0, 5) == 1, "below the source 100 MW surplus threshold remains normal realtime")
	_check(Projects.stable_multiplier(100000.0, 5) == 4 and Projects.stable_multiplier(1000000.0, 6) == 5, "source logarithmic power thresholds yield 4x at 100 MW and 5x at 1 GW")
	_check(Projects.stable_multiplier(100000000.0, 5) == 5 and Projects.stable_multiplier(1000000.0, 4) == 1, "requested multiplier caps the source result and invalid requests cannot activate time warp")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Factory DSP projects")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
