extends SceneTree

## Focused pure/isolated contract for DSP production hooks. Integration with
## roads, normal recipes and world effect persistence is intentionally owned by
## FactoryGridSimulation and is tested by the primary agent.

var failures: Array[String] = []


func _initialize() -> void:
	_test_fuel_capacity_and_single_settlement()
	_test_storage_charge_is_bounded_and_recipe_gated()
	_test_ray_photons_require_dyson_energy()
	_test_launch_and_matrix_effects_are_real_results()
	_test_zero_elapsed_is_idempotent()
	_finish()


func _test_fuel_capacity_and_single_settlement() -> void:
	var buildings := {
		"grid_dsp_thermal":{"id":"grid_dsp_thermal", "power_generation_kw":1000.0, "runtime_metadata":{"power_mode":"FUEL_GENERATOR", "fuel_item_ids":["dsp_coal"], "fuel_efficiency":1.0, "fuel_energy_mj":{"dsp_coal":50.0}}}
	}
	var world := {"entities":{"fuel":{"id":"fuel", "definition_id":"grid_dsp_thermal", "inputs":{"dsp_coal":2}, "fuel_remaining_mj":0.0}}, "dsp_effects":{}}
	var plan := FactoryDspProduction.prepare_power(world, buildings, {}, 10.0)
	_check(is_equal_approx(float(plan["generation_capacity_kw"].get("fuel", 0.0)), 1000.0), "fuel generation is limited by rated output and real MJ")
	var settled := FactoryDspProduction.settle_power(world, buildings, {"fuel":1000.0}, {}, 10.0)
	var entity: Dictionary = world["entities"]["fuel"]
	_check(int(entity["inputs"].get("dsp_coal", 0)) == 1 and is_equal_approx(float(entity.get("fuel_remaining_mj", 0.0)), 40.0), "one settlement consumes only the fuel required and preserves leftover MJ")
	_check(int(settled["fuel_consumed"].get("fuel", {}).get("dsp_coal", 0)) == 1, "fuel custody delta reports exactly one consumed item")


func _test_storage_charge_is_bounded_and_recipe_gated() -> void:
	var buildings := {
		"grid_dsp_exchanger":{"id":"grid_dsp_exchanger", "output_capacity":1, "power_generation_kw":90.0, "power_charge_kw":90.0, "runtime_metadata":{"power_mode":"ENERGY_EXCHANGER", "energy_capacity_mj":90.0, "energy_cell_mj":90.0, "charge_rate_kw":90.0, "discharge_rate_kw":90.0}}
	}
	var charge_recipe := {"id":"dsp_accumulator_charge", "inputs":[{"item":"dsp_accumulator", "quantity":1}], "outputs":[{"item":"dsp_charged_accumulator", "quantity":1}]}
	var world := {"entities":{"ex":{"id":"ex", "definition_id":"grid_dsp_exchanger", "energy_mode":"CHARGE", "inputs":{"dsp_accumulator":1}, "outputs":{}}}, "dsp_effects":{}}
	var first := FactoryDspProduction.prepare_power(world, buildings, {}, 1.0)
	_check(is_equal_approx(float(first["charge_capacity_kw"].get("ex", 0.0)), 90.0), "empty accumulator offers only its real 90 MJ charge budget")
	FactoryDspProduction.settle_power(world, buildings, {}, {"ex":90.0}, 1000.0)
	FactoryDspProduction.settle_power(world, buildings, {}, {"ex":90.0}, 1000.0)
	var entity: Dictionary = world["entities"]["ex"]
	_check(is_equal_approx(float(entity.get("energy_credit_mj", 0.0)), 90.0), "repeated charge settlement clamps at one cell instead of charging the same cell twice")
	var decorated := entity.duplicate(true)
	decorated["dsp_runtime_metadata"] = buildings["grid_dsp_exchanger"]["runtime_metadata"]
	var finished := FactoryDspProduction.finish_recipe(world, decorated, charge_recipe, 1)
	_check(int(finished.get("allowed_cycles", 0)) == 1 and is_equal_approx(float(finished.get("energy_delta_mj", 0.0)), -90.0), "charged-cell recipe is gated by actual settled energy and returns, rather than creates, its debit")


func _test_ray_photons_require_dyson_energy() -> void:
	var buildings := {
		"grid_dsp_receiver":{"id":"grid_dsp_receiver", "power_generation_kw":600.0, "runtime_metadata":{"power_mode":"RAY_RECEIVER", "discharge_rate_kw":600.0}}
	}
	var recipes := {"dsp_critical_photon":{"id":"dsp_critical_photon", "runtime_metadata":{"recipe_mode":"CRITICAL_PHOTON", "special_effect_id":"CRITICAL_PHOTON"}}}
	var world := {"entities":{"ray":{"id":"ray", "definition_id":"grid_dsp_receiver", "recipe_id":"dsp_critical_photon", "inputs":{}, "outputs":{}}}, "dsp_effects":{"ray_available_kw":0.0}}
	var plan := FactoryDspProduction.prepare_power(world, buildings, recipes, 1.0)
	_check(is_zero_approx(float(plan["recipe_power_factor"].get("ray", 0.0))) and str(plan["blocked"].get("ray", "")) == "NO_DYSON_POWER", "critical photons receive no production factor without actual Dyson energy")
	var entity: Dictionary = world["entities"]["ray"].duplicate(true)
	entity["dsp_recipe_power_factor"] = float(plan["recipe_power_factor"].get("ray", 0.0))
	var finished := FactoryDspProduction.finish_recipe(world, entity, recipes["dsp_critical_photon"], 1)
	_check(int(finished.get("allowed_cycles", 1)) == 0 and str(finished.get("blocked", "")) == "NO_DYSON_POWER", "photon completion is explicitly blocked instead of yielding free output")


func _test_launch_and_matrix_effects_are_real_results() -> void:
	var world := {"entities":{}, "dsp_effects":{}}
	var launcher := {"definition_id":"grid_dsp_ejector", "inputs":{}, "outputs":{}}
	var sail_recipe := {"id":"dsp_solar_sail_launch", "runtime_metadata":{"recipe_mode":"LAUNCH", "special_effect_id":"DYSON_SAIL_LAUNCH", "launch_energy_mj":18.0}}
	var sail_result := FactoryDspProduction.finish_recipe(world, launcher, sail_recipe, 2)
	_check(int(sail_result["effects"].get("dyson_sails", 0)) == 2 and is_equal_approx(float(sail_result["effects"].get("launch_energy_mj", 0.0)), 36.0), "sail launch completion returns real Dyson and energy effects for the canonical world record")
	var lab := {"definition_id":"grid_dsp_matrix_lab", "inputs":{}, "outputs":{}}
	var matrix_recipe := {"id":"dsp_matrix_research", "runtime_metadata":{"recipe_mode":"MATRIX", "special_effect_id":"MATRIX_RESEARCH", "research_points_per_cycle":3}}
	var matrix_result := FactoryDspProduction.finish_recipe(world, lab, matrix_recipe, 2)
	_check(int(matrix_result["effects"].get("research_points", 0)) == 6, "matrix research outputs explicit research points instead of silently disappearing")


func _test_zero_elapsed_is_idempotent() -> void:
	var buildings := {"battery":{"id":"battery", "runtime_metadata":{"power_mode":"BATTERY", "energy_capacity_mj":90.0, "charge_rate_kw":90.0, "discharge_rate_kw":90.0}}}
	var world := {"entities":{"b":{"id":"b", "definition_id":"battery", "stored_energy_mj":20.0, "inputs":{}, "outputs":{}}}, "dsp_effects":{}}
	var before := world.duplicate(true)
	var plan := FactoryDspProduction.prepare_power(world, buildings, {}, 0.0)
	FactoryDspProduction.settle_power(world, buildings, {"b":90.0}, {"b":90.0}, 0.0)
	var empty := FactoryDspProduction.finish_recipe(world, world["entities"]["b"], {}, 0)
	_check(plan["generation_capacity_kw"].is_empty() and world == before and int(empty.get("allowed_cycles", -1)) == 0, "zero elapsed performs no power, custody, or special-effect mutation")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Factory DSP production")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
