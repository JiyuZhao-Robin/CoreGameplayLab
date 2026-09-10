class_name FactoryEnvironmentEffects
extends RefCounted

## Deterministic, presentation-safe environment adjustments for Factory worlds.
##
## The authoritative Location projection owns the environmental record. Factory
## persists a copy at `world.environment` so its physical power graph and
## construction simulation use the same input as its workspace snapshot. Missing
## or malformed values intentionally resolve to the neutral baseline, preserving
## legacy worlds and isolated Factory fixtures.

const THERMAL_POWER_MULTIPLIERS := {
	"CONTROLLED":1.0,
	"THERMAL_CYCLING":1.10,
	"COLD":1.15,
	"EXTREME_COLD":1.30,
	"EXTREME_HEAT":1.35
}

const RADIATION_POWER_MULTIPLIERS := {
	"LOW":1.0,
	"MODERATE":1.05,
	"HIGH":1.15,
	"EXTREME":1.30
}


## Returns the complete, stable effect snapshot. `construction_work_multiplier`
## communicates the environmental difficulty for presentation, but authored
## `work_required` is never rewritten: simulation applies its reciprocal through
## construction capacity instead.
static func snapshot(environment: Dictionary = {}) -> Dictionary:
	var solar_flux := maxf(0.0, finite_number(environment.get("solar_flux", 1.0), 1.0))
	var thermal_key := str(environment.get("thermal_environment", environment.get("thermal", "CONTROLLED"))).to_upper()
	var radiation_key := str(environment.get("radiation", "LOW")).to_upper()
	var atmosphere := str(environment.get("atmosphere", "NONE")).to_upper()
	var gravity := maxf(0.0, finite_number(environment.get("gravity", 0.0), 0.0))
	var construction_difficulty := maxf(0.1, finite_number(environment.get("construction_difficulty", 1.0), 1.0))
	var thermal_power_multiplier := float(THERMAL_POWER_MULTIPLIERS.get(thermal_key, 1.0))
	var radiation_power_multiplier := float(RADIATION_POWER_MULTIPLIERS.get(radiation_key, 1.0))
	var gravity_power_multiplier := 1.0 + gravity * 0.10
	var atmosphere_power_multiplier := 1.15 if atmosphere == "GAS_GIANT" else 1.0
	return {
		"solar_generation_multiplier":sqrt(solar_flux),
		"power_demand_multiplier":thermal_power_multiplier * radiation_power_multiplier * gravity_power_multiplier * atmosphere_power_multiplier,
		"construction_work_multiplier":construction_difficulty,
		"construction_speed_multiplier":1.0 / construction_difficulty,
		"thermal_power_multiplier":thermal_power_multiplier,
		"radiation_power_multiplier":radiation_power_multiplier,
		"gravity_power_multiplier":gravity_power_multiplier,
		"atmosphere_power_multiplier":atmosphere_power_multiplier
	}


static func effective_generation_kw(environment: Dictionary, definition: Dictionary) -> float:
	var generation := nominal_generation_kw(definition)
	if not is_solar_generator(definition):
		return generation
	return generation * maxf(0.0, finite_number(snapshot(environment).get("solar_generation_multiplier", 1.0), 1.0))


static func effective_demand_kw(environment: Dictionary, definition: Dictionary) -> float:
	return nominal_demand_kw(definition) * maxf(0.0, finite_number(snapshot(environment).get("power_demand_multiplier", 1.0), 1.0))


static func effective_construction_capacity_per_second(environment: Dictionary, nominal_capacity: float) -> float:
	return maxf(0.0, finite_number(nominal_capacity, 0.0)) * maxf(0.0, finite_number(snapshot(environment).get("construction_speed_multiplier", 1.0), 1.0))


static func nominal_generation_kw(definition: Dictionary) -> float:
	return maxf(0.0, finite_number(definition.get("power_generation_kw", 0.0), 0.0))


static func nominal_demand_kw(definition: Dictionary) -> float:
	return maxf(0.0, finite_number(definition.get("power_demand_kw", 0.0), 0.0))


static func nominal_construction_capacity_per_second(definition: Dictionary) -> float:
	return maxf(0.0, finite_number(definition.get("construction_capacity_per_second", 0.0), 0.0))


static func is_solar_generator(definition: Dictionary) -> bool:
	return str(definition.get("id", "")) == "grid_solar_array" or bool(definition.get("solar_generator", false))


## Reject NaN/Infinity and non-numeric Variant values rather than letting a bad
## save contaminate deterministic graph totals. Numeric strings are deliberately
## not coerced: serialized Factory environment values are numeric by contract.
static func finite_number(value: Variant, fallback: float) -> float:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return fallback
	var numeric := float(value)
	return numeric if is_finite(numeric) else fallback
