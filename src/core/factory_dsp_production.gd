class_name FactoryDspProduction
extends RefCounted

## DSPONLINE-specific Factory extensions. This module is deliberately a
## stateless adapter: `world` and its entity dictionaries remain the only
## authority, roads remain the only local logistics/power topology, and all
## content is read-only input.
##
## Integration order (owned by FactoryGridSimulation):
## 1. `prepare_power` returns finite source/sink candidates without consuming.
## 2. The road component allocates actual generation and charge demand.
## 3. `settle_power` is called exactly once for that simulation step; it is the
##    only mutating API here and settles fuel or energy custody.
## 4. The machine runner applies special gates before normal input consumption.
##    It calls `planned_outputs` before reserving output space, then
##    `finish_recipe` after choosing its completed-cycle count and applies the
##    returned deltas/effects exactly once.
##
## `world.dsp_effects` is the canonical cross-machine effect record. It may
## expose `ray_available_kw` (or the backwards-compatible
## `dyson_generation_kw`) for this step; launch/research effects returned by
## `finish_recipe` are applied by the integration owner to that same record.

const EPSILON := 0.000001
const POWER_MODE_FUEL_GENERATOR := "FUEL_GENERATOR"
const POWER_MODE_BATTERY := "BATTERY"
const POWER_MODE_ENERGY_EXCHANGER := "ENERGY_EXCHANGER"
const POWER_MODE_RAY_RECEIVER := "RAY_RECEIVER"
const POWER_MODE_LAUNCHER := "LAUNCHER"
const POWER_MODE_MATRIX_LAB := "MATRIX_LAB"
const POWER_MODE_PASSIVE := "PASSIVE"

const RECIPE_MODE_STANDARD := "STANDARD"
const RECIPE_MODE_RAY_POWER := "RAY_POWER"
const RECIPE_MODE_CRITICAL_PHOTON := "CRITICAL_PHOTON"
const RECIPE_MODE_LAUNCH := "LAUNCH"
const RECIPE_MODE_MATRIX := "MATRIX"

const EFFECT_DYSON_SAIL_LAUNCH := "DYSON_SAIL_LAUNCH"
const EFFECT_DYSON_ROCKET_LAUNCH := "DYSON_ROCKET_LAUNCH"
const EFFECT_RAY_POWER := "RAY_POWER"
const EFFECT_CRITICAL_PHOTON := "CRITICAL_PHOTON"
const EFFECT_MATRIX_RESEARCH := "MATRIX_RESEARCH"

const DEFAULT_FUEL_ENERGY_MJ := {
	"coal":2.7, "fire_ice":4.8, "crude_oil":4.0, "energetic_graphite":6.3,
	"refined_oil":4.4, "hydrogen":8.0, "hydrogen_fuel_rod":54.0,
	"deuteron_fuel_rod":600.0, "antimatter_fuel_rod":7200.0,
	"dsp_coal":2.7, "dsp_fire_ice":4.8, "dsp_crude_oil":4.0,
	"dsp_energetic_graphite":6.3, "dsp_refined_oil":4.4, "dsp_hydrogen":8.0,
	"dsp_hydrogen_fuel_rod":54.0, "dsp_deuteron_fuel_rod":600.0,
	"dsp_antimatter_fuel_rod":7200.0
}

const DEFAULT_EMPTY_ENERGY_CELL := "dsp_accumulator"
const DEFAULT_CHARGED_ENERGY_CELL := "dsp_charged_accumulator"


## Pure first pass. Values are candidates, not supplied power: the road power
## graph must still choose `allocation_kw` and `charge_kw` for each component.
##
## Returned keys:
## - generation_capacity_kw: entity id -> finite available source output.
## - charge_capacity_kw: entity id -> finite grid-surplus sink capacity.
## - ray_power_kw/ray_photon_kw: source allocation divided deterministically
##   across ray receivers using `world.dsp_effects.ray_available_kw`.
## - recipe_power_factor: special recipe rate multiplier (critical photons).
## - blocked: entity id -> stable reason; presentation-only diagnostic.
static func prepare_power(world: Dictionary, buildings: Dictionary, _recipes: Dictionary, seconds: float) -> Dictionary:
	var plan := {
		"generation_capacity_kw":{}, "charge_capacity_kw":{},
		"ray_power_kw":{}, "ray_photon_kw":{},
		"recipe_power_factor":{}, "blocked":{}
	}
	if seconds <= EPSILON:
		return plan

	var receiver_rows: Array = []
	for entity_id in _sorted_entity_ids(world):
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		var definition := _definition_for(entity, buildings)
		var metadata := _metadata(definition)
		var mode := _power_mode(metadata)
		if mode == POWER_MODE_FUEL_GENERATOR:
			var fuel := _selected_fuel(entity, metadata)
			var energy_mj := _fuel_available_mj(entity, fuel, metadata)
			var rated_kw := _rated_generation_kw(definition, entity, metadata)
			var capacity_kw := minf(rated_kw, energy_mj * _fuel_efficiency(metadata) * 1000.0 / seconds)
			if capacity_kw > EPSILON:
				plan["generation_capacity_kw"][entity_id] = capacity_kw
			else:
				plan["blocked"][entity_id] = "MISSING_FUEL"
		elif mode == POWER_MODE_BATTERY:
			var stored_mj := _stored_energy_mj(entity, metadata)
			var battery_capacity_kw := minf(_discharge_rate_kw(definition, entity, metadata), stored_mj * 1000.0 / seconds)
			var free_mj := maxf(0.0, _energy_capacity_mj(definition, entity, metadata) - stored_mj)
			var battery_charge_kw := minf(_charge_rate_kw(definition, entity, metadata), free_mj * 1000.0 / seconds)
			if battery_capacity_kw > EPSILON:
				plan["generation_capacity_kw"][entity_id] = battery_capacity_kw
			if battery_charge_kw > EPSILON:
				plan["charge_capacity_kw"][entity_id] = battery_charge_kw
		elif mode == POWER_MODE_ENERGY_EXCHANGER:
			var exchanger_mode := str(entity.get("energy_mode", "CHARGE")).to_upper()
			var cell_mj := _energy_cell_mj(metadata)
			if exchanger_mode == "DISCHARGE":
				var discharge_budget := _exchanger_discharge_budget_mj(entity, definition, metadata)
				var discharge_kw := minf(_discharge_rate_kw(definition, entity, metadata), discharge_budget * 1000.0 / seconds)
				if discharge_kw > EPSILON:
					plan["generation_capacity_kw"][entity_id] = discharge_kw
				else:
					plan["blocked"][entity_id] = "MISSING_CHARGED_CELL"
			else:
				var charge_budget := _exchanger_charge_budget_mj(entity, definition, metadata)
				var charge_kw := minf(_charge_rate_kw(definition, entity, metadata), charge_budget * 1000.0 / seconds)
				if charge_kw > EPSILON and cell_mj > EPSILON:
					plan["charge_capacity_kw"][entity_id] = charge_kw
				else:
					plan["blocked"][entity_id] = "MISSING_EMPTY_CELL"
		elif mode == POWER_MODE_RAY_RECEIVER:
			var receiver_rate := _discharge_rate_kw(definition, entity, metadata)
			if receiver_rate > EPSILON:
				receiver_rows.append({"entity_id":entity_id, "recipe_mode":_recipe_mode_for_entity(entity, _recipes), "rate_kw":receiver_rate})

	# Dyson reception is a per-step allocation, never an initial free-energy
	# grant. Capacity is split proportionally, matching DSPONLINE's source model.
	var total_receiver_kw := 0.0
	for row_value in receiver_rows:
		total_receiver_kw += float((row_value as Dictionary).get("rate_kw", 0.0))
	var available_ray_kw := _ray_available_kw(world)
	var receiver_factor := 0.0 if total_receiver_kw <= EPSILON else minf(1.0, available_ray_kw / total_receiver_kw)
	for row_value in receiver_rows:
		var row := row_value as Dictionary
		var entity_id := str(row.get("entity_id", ""))
		var allocated_kw := maxf(0.0, float(row.get("rate_kw", 0.0)) * receiver_factor)
		if str(row.get("recipe_mode", RECIPE_MODE_STANDARD)) == RECIPE_MODE_CRITICAL_PHOTON:
			plan["ray_photon_kw"][entity_id] = allocated_kw
			plan["recipe_power_factor"][entity_id] = receiver_factor
			if allocated_kw <= EPSILON:
				plan["blocked"][entity_id] = "NO_DYSON_POWER"
		else:
			plan["ray_power_kw"][entity_id] = allocated_kw
	return plan


## The sole mutating power hook. Call exactly once after the road graph has
## selected actual allocations. It never creates item outputs: energy-exchanger
## material conversion remains a normal recipe guarded by `finish_recipe`.
##
## allocation_kw and charge_kw are entity-id dictionaries. Values beyond the
## preceding `prepare_power` capacity are clamped, preventing free fuel/energy
## if a caller supplies a stale or malformed allocation.
static func settle_power(world: Dictionary, buildings: Dictionary, allocation_kw: Dictionary, charge_kw: Dictionary, seconds: float) -> Dictionary:
	var settled := {"fuel_consumed":{}, "energy_delta_mj":{}, "generation_kw":{}, "charge_kw":{}}
	if seconds <= EPSILON:
		return settled
	for entity_id in _sorted_entity_ids(world):
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		var definition := _definition_for(entity, buildings)
		var metadata := _metadata(definition)
		var mode := _power_mode(metadata)
		var requested_generation := maxf(0.0, _finite_number(allocation_kw.get(entity_id, 0.0), 0.0))
		var requested_charge := maxf(0.0, _finite_number(charge_kw.get(entity_id, 0.0), 0.0))
		if mode == POWER_MODE_FUEL_GENERATOR:
			var fuel := _selected_fuel(entity, metadata)
			var capacity_kw := minf(_rated_generation_kw(definition, entity, metadata), _fuel_available_mj(entity, fuel, metadata) * _fuel_efficiency(metadata) * 1000.0 / seconds)
			var actual_kw := minf(requested_generation, capacity_kw)
			var fuel_result := _settle_fuel(entity, fuel, metadata, actual_kw * seconds / 1000.0)
			settled["generation_kw"][entity_id] = actual_kw
			settled["fuel_consumed"][entity_id] = fuel_result.get("consumed_items", {})
			settled["energy_delta_mj"][entity_id] = -float(fuel_result.get("burned_mj", 0.0))
		elif mode == POWER_MODE_BATTERY:
			var old_stored := _stored_energy_mj(entity, metadata)
			var capacity := _energy_capacity_mj(definition, entity, metadata)
			var actual_output := minf(requested_generation, minf(_discharge_rate_kw(definition, entity, metadata), old_stored * 1000.0 / seconds))
			var free_after_output := maxf(0.0, capacity - old_stored + actual_output * seconds / 1000.0)
			var actual_charge := minf(requested_charge, minf(_charge_rate_kw(definition, entity, metadata), free_after_output * 1000.0 / seconds))
			var next_stored := clampf(old_stored + (actual_charge - actual_output) * seconds / 1000.0, 0.0, capacity)
			entity["stored_energy_mj"] = _round_energy(next_stored)
			settled["generation_kw"][entity_id] = actual_output
			settled["charge_kw"][entity_id] = actual_charge
			settled["energy_delta_mj"][entity_id] = _round_energy(next_stored - old_stored)
		elif mode == POWER_MODE_ENERGY_EXCHANGER:
			var exchanger_mode := str(entity.get("energy_mode", "CHARGE")).to_upper()
			if exchanger_mode == "DISCHARGE":
				var debt_before := maxf(0.0, _finite_number(entity.get("energy_debt_mj", 0.0), 0.0))
				var discharge_budget := _exchanger_discharge_budget_mj(entity, definition, metadata)
				var actual_output := minf(requested_generation, minf(_discharge_rate_kw(definition, entity, metadata), discharge_budget * 1000.0 / seconds))
				var discharge_mj := actual_output * seconds / 1000.0
				entity["energy_debt_mj"] = _round_energy(debt_before + discharge_mj)
				settled["generation_kw"][entity_id] = actual_output
				settled["energy_delta_mj"][entity_id] = -_round_energy(discharge_mj)
			else:
				var credit_before := maxf(0.0, _finite_number(entity.get("energy_credit_mj", 0.0), 0.0))
				var charge_budget := _exchanger_charge_budget_mj(entity, definition, metadata)
				var actual_charge := minf(requested_charge, minf(_charge_rate_kw(definition, entity, metadata), charge_budget * 1000.0 / seconds))
				var charge_mj := actual_charge * seconds / 1000.0
				entity["energy_credit_mj"] = _round_energy(credit_before + charge_mj)
				settled["charge_kw"][entity_id] = actual_charge
				settled["energy_delta_mj"][entity_id] = _round_energy(charge_mj)
	return settled


## Calculates the total (base + proliferated) output reservation for `cycles`.
## The caller must reserve this exact total before consuming normal recipe
## inputs. `extra_outputs` are applied only after normal base outputs succeed.
static func planned_outputs(entity: Dictionary, recipe: Dictionary, cycles: int) -> Dictionary:
	var safe_cycles := maxi(0, cycles)
	var totals := _recipe_output_totals(recipe, safe_cycles)
	var result := {"cycles":safe_cycles, "total_outputs":totals.duplicate(true), "extra_outputs":{}, "spray":_empty_spray_result()}
	if safe_cycles <= 0:
		return result
	var spray := _spray_result(entity, recipe, safe_cycles)
	result["spray"] = spray
	for item_id_value in spray.get("extra_outputs", {}).keys():
		var item_id := str(item_id_value)
		var quantity := maxi(0, int(spray["extra_outputs"].get(item_id_value, 0)))
		if quantity <= 0:
			continue
		result["extra_outputs"][item_id] = quantity
		result["total_outputs"][item_id] = int(result["total_outputs"].get(item_id, 0)) + quantity
	return result


## Pure recipe completion extension. Normal recipe input/output mutation is
## intentionally not duplicated here. The integration owner applies
## `extra_outputs`, `spray`, `energy_delta_mj`, and `effects` once after normal
## completion. `allowed_cycles` is the special gate that must be used before
## consuming normal inputs.
static func finish_recipe(world: Dictionary, entity: Dictionary, recipe: Dictionary, cycles: int) -> Dictionary:
	var requested_cycles := maxi(0, cycles)
	var result := {
		"allowed_cycles":requested_cycles, "extra_outputs":{}, "spray":_empty_spray_result(),
		"energy_delta_mj":0.0,
		"effects":{"research_points":0, "dyson_sails":0, "dyson_structure":0, "launch_energy_mj":0.0},
		"blocked":""
	}
	if requested_cycles <= 0:
		return result
	var metadata := _metadata(recipe)
	var recipe_mode := str(metadata.get("recipe_mode", RECIPE_MODE_STANDARD)).to_upper()
	var effect_id := str(metadata.get("special_effect_id", "")).to_upper()

	# Ray power factor is decorated from prepare_power for this simulation step.
	# The normal machine runner applies that factor to its fractional progress;
	# this completion hook only hard-gates the zero-allocation case, avoiding a
	# second multiplication at the integer completion boundary.
	if recipe_mode == RECIPE_MODE_CRITICAL_PHOTON or effect_id == EFFECT_CRITICAL_PHOTON:
		var ray_factor := clampf(_finite_number(entity.get("dsp_recipe_power_factor", 0.0), 0.0), 0.0, 1.0)
		if ray_factor <= EPSILON:
			result["allowed_cycles"] = 0
			result["blocked"] = "NO_DYSON_POWER"
			return result

	var building_metadata := _metadata_for_entity(world, entity)
	if _power_mode(building_metadata) == POWER_MODE_ENERGY_EXCHANGER:
		var exchanger_mode := str(entity.get("energy_mode", "CHARGE")).to_upper()
		var cell_mj := _energy_cell_mj(building_metadata)
		var energy_available := maxf(0.0, _finite_number(entity.get("energy_debt_mj" if exchanger_mode == "DISCHARGE" else "energy_credit_mj", 0.0), 0.0))
		var energy_cycles := maxi(0, floori((energy_available + EPSILON) / maxf(EPSILON, cell_mj)))
		result["allowed_cycles"] = mini(int(result.get("allowed_cycles", 0)), energy_cycles)
		if int(result["allowed_cycles"]) <= 0:
			result["blocked"] = "ENERGY_BUDGET_EMPTY"
			return result
		result["energy_delta_mj"] = -float(result["allowed_cycles"]) * cell_mj

	var completed_cycles := int(result.get("allowed_cycles", 0))
	var output_plan := planned_outputs(entity, recipe, completed_cycles)
	result["extra_outputs"] = output_plan.get("extra_outputs", {}).duplicate(true)
	result["spray"] = output_plan.get("spray", _empty_spray_result()).duplicate(true)
	if recipe_mode == RECIPE_MODE_LAUNCH or effect_id in [EFFECT_DYSON_SAIL_LAUNCH, EFFECT_DYSON_ROCKET_LAUNCH]:
		var effects: Dictionary = result["effects"]
		var energy_per_cycle := maxf(0.0, _finite_number(metadata.get("launch_energy_mj", 0.0), 0.0))
		effects["launch_energy_mj"] = float(completed_cycles) * energy_per_cycle
		if effect_id == EFFECT_DYSON_SAIL_LAUNCH:
			effects["dyson_sails"] = completed_cycles
		elif effect_id == EFFECT_DYSON_ROCKET_LAUNCH:
			effects["dyson_structure"] = completed_cycles
	if recipe_mode == RECIPE_MODE_MATRIX or effect_id == EFFECT_MATRIX_RESEARCH:
		result["effects"]["research_points"] = completed_cycles * maxi(1, int(metadata.get("research_points_per_cycle", 1)))
	return result


## Metadata-only projection for workspace inspectors. PASSIVE is intentionally
## inert: source-only mega/endgame records remain visible but this module never
## invents a production or global side effect for them.
static func snapshot_metadata(definition: Dictionary, recipe: Dictionary = {}, entity: Dictionary = {}) -> Dictionary:
	var building_metadata := _metadata(definition)
	var recipe_metadata := _metadata(recipe)
	var power_mode := _power_mode(building_metadata)
	var recipe_mode := str(recipe_metadata.get("recipe_mode", RECIPE_MODE_STANDARD)).to_upper()
	var effect_id := str(recipe_metadata.get("special_effect_id", building_metadata.get("special_effect_id", ""))).to_upper()
	return {
		"power_mode":power_mode,
		"recipe_mode":recipe_mode,
		"special_effect_id":effect_id,
		"fuel_item_ids":building_metadata.get("fuel_item_ids", []).duplicate(true),
		"energy_capacity_mj":_energy_capacity_mj(definition, entity, building_metadata),
		"stored_energy_mj":_stored_energy_mj(entity, building_metadata),
		"energy_mode":str(entity.get("energy_mode", "")),
		"runtime_behavior":"BASE_RUNTIME" if power_mode == POWER_MODE_PASSIVE else "FUNCTIONAL"
	}


static func proliferation_speed_multiplier(entity: Dictionary, recipe: Dictionary) -> float:
	var config := _proliferator_config(entity, recipe)
	if str(config.get("mode", "")) != "SPEED" or int(config.get("sprayed_cycles", 0)) <= 0:
		return 1.0
	return 1.0 + maxf(0.0, _finite_number(config.get("speed_bonus", 0.0), 0.0))


static func proliferation_power_multiplier(entity: Dictionary, recipe: Dictionary) -> float:
	var config := _proliferator_config(entity, recipe)
	if int(config.get("sprayed_cycles", 0)) <= 0:
		return 1.0
	var tier := clampi(int(entity.get("proliferator", {}).get("tier", 1)), 1, 3)
	return [1.3, 1.7, 2.5][tier - 1]


static func _definition_for(entity: Dictionary, buildings: Dictionary) -> Dictionary:
	var definition_value: Variant = buildings.get(str(entity.get("definition_id", "")), {})
	return definition_value as Dictionary if definition_value is Dictionary else {}


static func _metadata_for_entity(world: Dictionary, entity: Dictionary) -> Dictionary:
	# finish_recipe receives only a recipe/entity by contract. The integration
	# decorates its ephemeral entity view with this metadata; reading world is a
	# backwards-compatible fallback for focused direct calls.
	var direct: Variant = entity.get("dsp_runtime_metadata", {})
	if direct is Dictionary:
		return direct as Dictionary
	var definitions_value: Variant = world.get("dsp_building_metadata", {})
	if definitions_value is Dictionary:
		var value: Variant = (definitions_value as Dictionary).get(str(entity.get("definition_id", "")), {})
		if value is Dictionary:
			return value as Dictionary
	return {}


static func _metadata(record: Dictionary) -> Dictionary:
	var value: Variant = record.get("runtime_metadata", {})
	return value as Dictionary if value is Dictionary else {}


static func _power_mode(metadata: Dictionary) -> String:
	var value := str(metadata.get("power_mode", POWER_MODE_PASSIVE)).to_upper()
	return value if value in [POWER_MODE_FUEL_GENERATOR, POWER_MODE_BATTERY, POWER_MODE_ENERGY_EXCHANGER, POWER_MODE_RAY_RECEIVER, POWER_MODE_LAUNCHER, POWER_MODE_MATRIX_LAB, POWER_MODE_PASSIVE] else POWER_MODE_PASSIVE


static func _recipe_mode_for_entity(entity: Dictionary, recipes: Dictionary) -> String:
	var recipe_value: Variant = recipes.get(str(entity.get("recipe_id", "")), {})
	var recipe := recipe_value as Dictionary if recipe_value is Dictionary else {}
	var mode := str(_metadata(recipe).get("recipe_mode", RECIPE_MODE_STANDARD)).to_upper()
	return mode if mode in [RECIPE_MODE_STANDARD, RECIPE_MODE_RAY_POWER, RECIPE_MODE_CRITICAL_PHOTON, RECIPE_MODE_LAUNCH, RECIPE_MODE_MATRIX] else RECIPE_MODE_STANDARD


static func _selected_fuel(entity: Dictionary, metadata: Dictionary) -> String:
	var allowed_value: Variant = metadata.get("fuel_item_ids", [])
	var allowed: Array = allowed_value as Array if allowed_value is Array else []
	var selected := str(entity.get("fuel_item_id", entity.get("dsp_fuel_item_id", "")))
	if not selected.is_empty() and allowed.has(selected):
		return selected
	for item_value in allowed:
		var item_id := str(item_value)
		if int(entity.get("inputs", {}).get(item_id, 0)) > 0:
			return item_id
	return "" if allowed.is_empty() else str(allowed[0])


static func _fuel_available_mj(entity: Dictionary, item_id: String, metadata: Dictionary) -> float:
	if item_id.is_empty():
		return 0.0
	return maxf(0.0, _finite_number(entity.get("fuel_remaining_mj", 0.0), 0.0)) + float(maxi(0, int(entity.get("inputs", {}).get(item_id, 0))) * _fuel_energy_mj(item_id, metadata))


static func _fuel_energy_mj(item_id: String, metadata: Dictionary) -> float:
	var map_value: Variant = metadata.get("fuel_energy_mj", {})
	if map_value is Dictionary and (map_value as Dictionary).has(item_id):
		return maxf(0.0, _finite_number((map_value as Dictionary).get(item_id, 0.0), 0.0))
	return maxf(0.0, float(DEFAULT_FUEL_ENERGY_MJ.get(item_id, 0.0)))


static func _fuel_efficiency(metadata: Dictionary) -> float:
	return clampf(_finite_number(metadata.get("fuel_efficiency", 1.0), 1.0), EPSILON, 1.0)


static func _settle_fuel(entity: Dictionary, item_id: String, metadata: Dictionary, electric_energy_mj: float) -> Dictionary:
	var required_heat_mj := maxf(0.0, electric_energy_mj) / _fuel_efficiency(metadata)
	var heat_before := maxf(0.0, _finite_number(entity.get("fuel_remaining_mj", 0.0), 0.0))
	var energy_per_item := _fuel_energy_mj(item_id, metadata)
	var queued := maxi(0, int(entity.get("inputs", {}).get(item_id, 0)))
	var load_needed := 0 if required_heat_mj <= heat_before + EPSILON else ceili((required_heat_mj - heat_before - EPSILON) / maxf(EPSILON, energy_per_item))
	var loaded := mini(queued, maxi(0, load_needed))
	var available_heat := heat_before + float(loaded) * energy_per_item
	var burned := minf(required_heat_mj, available_heat)
	if loaded > 0:
		entity["inputs"][item_id] = queued - loaded
	entity["fuel_item_id"] = item_id
	entity["fuel_remaining_mj"] = _round_energy(maxf(0.0, available_heat - burned))
	return {"burned_mj":burned, "consumed_items":{} if loaded <= 0 else {item_id:loaded}}


static func _energy_capacity_mj(definition: Dictionary, entity: Dictionary, metadata: Dictionary) -> float:
	var per_unit := maxf(0.0, _finite_number(metadata.get("energy_capacity_mj", definition.get("energy_capacity_mj", 0.0)), 0.0))
	return per_unit * _machine_count(entity)


static func _stored_energy_mj(entity: Dictionary, metadata: Dictionary) -> float:
	return maxf(0.0, _finite_number(entity.get("stored_energy_mj", 0.0), 0.0))


static func _energy_cell_mj(metadata: Dictionary) -> float:
	return maxf(EPSILON, _finite_number(metadata.get("energy_cell_mj", metadata.get("energy_capacity_mj", 0.0)), 0.0))


static func _charge_rate_kw(definition: Dictionary, entity: Dictionary, metadata: Dictionary) -> float:
	var value: Variant = metadata.get("charge_rate_kw", definition.get("power_charge_kw", definition.get("power_generation_kw", 0.0)))
	return maxf(0.0, _finite_number(value, 0.0)) * _machine_count(entity)


static func _discharge_rate_kw(definition: Dictionary, entity: Dictionary, metadata: Dictionary) -> float:
	var value: Variant = metadata.get("discharge_rate_kw", definition.get("power_generation_kw", 0.0))
	return maxf(0.0, _finite_number(value, 0.0)) * _machine_count(entity)


static func _rated_generation_kw(definition: Dictionary, entity: Dictionary, metadata: Dictionary) -> float:
	return _discharge_rate_kw(definition, entity, metadata)


static func _exchanger_charge_budget_mj(entity: Dictionary, definition: Dictionary, metadata: Dictionary) -> float:
	var cell_mj := _energy_cell_mj(metadata)
	var empty_item := str(metadata.get("empty_energy_item_id", DEFAULT_EMPTY_ENERGY_CELL))
	var charged_item := str(metadata.get("charged_energy_item_id", DEFAULT_CHARGED_ENERGY_CELL))
	var cells := maxi(0, int(entity.get("inputs", {}).get(empty_item, 0)))
	cells = mini(cells, _output_free_cells(entity, definition, charged_item))
	var credit := maxf(0.0, _finite_number(entity.get("energy_credit_mj", 0.0), 0.0))
	return maxf(0.0, float(cells) * cell_mj - credit)


static func _exchanger_discharge_budget_mj(entity: Dictionary, definition: Dictionary, metadata: Dictionary) -> float:
	var cell_mj := _energy_cell_mj(metadata)
	var charged_item := str(metadata.get("charged_energy_item_id", DEFAULT_CHARGED_ENERGY_CELL))
	var empty_item := str(metadata.get("empty_energy_item_id", DEFAULT_EMPTY_ENERGY_CELL))
	var cells := maxi(0, int(entity.get("inputs", {}).get(charged_item, 0)))
	cells = mini(cells, _output_free_cells(entity, definition, empty_item))
	var debt := maxf(0.0, _finite_number(entity.get("energy_debt_mj", 0.0), 0.0))
	return maxf(0.0, float(cells) * cell_mj - debt)


static func _output_free_cells(entity: Dictionary, definition: Dictionary, item_id: String) -> int:
	var capacity := maxi(0, int(definition.get("output_capacity", 0)))
	if capacity <= 0:
		return 0
	var used := 0
	for quantity_value in entity.get("outputs", {}).values():
		used += maxi(0, int(quantity_value))
	return maxi(0, capacity - used)


static func _ray_available_kw(world: Dictionary) -> float:
	var effects_value: Variant = world.get("dsp_effects", {})
	var effects := effects_value as Dictionary if effects_value is Dictionary else {}
	return maxf(0.0, _finite_number(effects.get("ray_available_kw", effects.get("dyson_generation_kw", 0.0)), 0.0))


static func _recipe_output_totals(recipe: Dictionary, cycles: int) -> Dictionary:
	var totals := {}
	for output_value in recipe.get("outputs", []):
		if output_value is not Dictionary:
			continue
		var output := output_value as Dictionary
		var item_id := str(output.get("item", output.get("item_id", "")))
		var quantity := maxi(0, int(output.get("quantity", output.get("amount", 0)))) * cycles
		if not item_id.is_empty() and quantity > 0:
			totals[item_id] = int(totals.get(item_id, 0)) + quantity
	return totals


static func _spray_result(entity: Dictionary, recipe: Dictionary, cycles: int) -> Dictionary:
	var config := _proliferator_config(entity, recipe)
	var result := _empty_spray_result()
	var mode := str(config.get("mode", ""))
	if cycles <= 0 or mode not in ["EXTRA", "SPEED"]:
		return result
	var sprayed_cycles := mini(cycles, maxi(0, int(config.get("sprayed_cycles", 0))))
	if sprayed_cycles <= 0:
		return result
	var progress_value: Variant = entity.get("proliferator_bonus_progress", {})
	var progress := progress_value as Dictionary if progress_value is Dictionary else {}
	var next_progress := progress.duplicate(true)
	if mode == "EXTRA":
		var bonus_ratio := maxf(0.0, _finite_number(config.get("extra_product_bonus", 0.0), 0.0))
		for output_value in recipe.get("outputs", []):
			if output_value is not Dictionary:
				continue
			var output := output_value as Dictionary
			var item_id := str(output.get("item", output.get("item_id", "")))
			var per_cycle := maxi(0, int(output.get("quantity", output.get("amount", 0))))
			if item_id.is_empty() or per_cycle <= 0:
				continue
			var accumulated := maxf(0.0, _finite_number(progress.get(item_id, 0.0), 0.0)) + float(per_cycle * sprayed_cycles) * bonus_ratio
			var produced := maxi(0, floori(accumulated + EPSILON))
			if produced > 0:
				result["extra_outputs"][item_id] = produced
			next_progress[item_id] = _round_energy(maxf(0.0, accumulated - float(produced)))
	var point_cost := int(config.get("point_cost", 1))
	var initial_points := int(config.get("initial_points", 0))
	var points_per_item := int(config.get("points_per_item", 0))
	var item_id := str(config.get("item_id", ""))
	var required_points := point_cost * sprayed_cycles
	var consumed_items := 0 if points_per_item <= 0 else maxi(0, ceili(float(maxi(0, required_points - initial_points)) / float(points_per_item)))
	result["points_after"] = maxi(0, initial_points + consumed_items * points_per_item - required_points)
	result["consumed_items"] = {} if item_id.is_empty() or consumed_items <= 0 else {item_id:consumed_items}
	result["bonus_progress"] = next_progress
	result["sprayed_cycles"] = sprayed_cycles
	return result


static func _proliferator_config(entity: Dictionary, recipe: Dictionary) -> Dictionary:
	# Charging/discharging transfers energy into the same physical cell. It is
	# not manufacturing: extra outputs would duplicate both cells and energy.
	if str(recipe.get("source_id", "")) in ["accumulator_charge", "accumulator_discharge"] or str(recipe.get("id", "")) in ["dsp_accumulator_charge", "dsp_accumulator_discharge"]:
		return {"mode":"", "sprayed_cycles":0}
	var config_value: Variant = entity.get("proliferator", {})
	if config_value is not Dictionary:
		return {"mode":"", "sprayed_cycles":0}
	var config := config_value as Dictionary
	var mode := str(config.get("mode", "NORMAL")).to_upper()
	if mode not in ["EXTRA", "SPEED"]:
		return {"mode":"", "sprayed_cycles":0}
	var recipe_mode := str(_metadata(recipe).get("recipe_mode", RECIPE_MODE_STANDARD)).to_upper()
	if recipe_mode == RECIPE_MODE_MATRIX:
		if mode != "SPEED":
			return {"mode":"", "sprayed_cycles":0}
	elif recipe.get("inputs", []).is_empty() or recipe.get("outputs", []).is_empty():
		return {"mode":"", "sprayed_cycles":0}
	var item_id := str(config.get("item_id", ""))
	var points_per_item := maxi(0, int(config.get("spray_points_per_item", 0)))
	var point_cost := maxi(1, int(config.get("point_cost", _recipe_input_count(recipe))))
	var points := maxi(0, int(config.get("points", 0)))
	var queued := maxi(0, int(entity.get("inputs", {}).get(item_id, 0)))
	var available_points := points + queued * points_per_item
	var sprayed_cycles := 0 if point_cost <= 0 else available_points / point_cost
	var required_points := point_cost * sprayed_cycles
	var consumed_items := 0 if points_per_item <= 0 else mini(queued, maxi(0, ceili(float(maxi(0, required_points - points)) / float(points_per_item))))
	return {
		"mode":mode, "item_id":item_id, "point_cost":point_cost,
		"initial_points":points, "points_per_item":points_per_item,
		"available_points":available_points, "sprayed_cycles":sprayed_cycles,
		"consumed_items":{} if item_id.is_empty() or consumed_items <= 0 else {item_id:consumed_items},
		"extra_product_bonus":maxf(0.0, _finite_number(config.get("extra_product_bonus", 0.0), 0.0)),
		"speed_bonus":maxf(0.0, _finite_number(config.get("speed_bonus", 0.0), 0.0))
	}


static func _recipe_input_count(recipe: Dictionary) -> int:
	var total := 0
	for input_value in recipe.get("inputs", []):
		if input_value is Dictionary:
			var input := input_value as Dictionary
			total += maxi(0, int(input.get("quantity", input.get("amount", 0))))
	return maxi(1, total)


static func _empty_spray_result() -> Dictionary:
	return {"extra_outputs":{}, "consumed_items":{}, "points_after":0, "bonus_progress":{}, "sprayed_cycles":0}


static func _machine_count(entity: Dictionary) -> int:
	return maxi(1, int(entity.get("machine_count", 1)))


static func _sorted_entity_ids(world: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for entity_id_value in world.get("entities", {}).keys():
		ids.append(str(entity_id_value))
	ids.sort()
	return ids


static func _finite_number(value: Variant, fallback: float) -> float:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return fallback
	var numeric := float(value)
	return numeric if is_finite(numeric) else fallback


static func _round_energy(value: float) -> float:
	return snappedf(value, 0.000001)
