class_name LocationInventoryTrend
extends RefCounted

## Presentation-only samples of actual stored goods, measured in simulation time.
## Transfers between same-Location warehouses cancel because callers aggregate
## custody first. No production is inferred from recipe selection or stock size.
const WINDOW_MS := 30_000.0
const MIN_SAMPLE_MS := 1_000.0
var _locations: Dictionary = {}


func reset() -> void:
	_locations.clear()


func sample(location_id: String, elapsed_ms: float, quantities: Dictionary) -> Dictionary:
	var samples: Array = _locations.get(location_id, [])
	if not samples.is_empty() and elapsed_ms < float(samples.back()["time"]):
		samples.clear()
	if samples.is_empty():
		samples.append({"time":elapsed_ms, "quantities":quantities.duplicate(true)})
	elif elapsed_ms - float(samples.back()["time"]) >= MIN_SAMPLE_MS:
		samples.append({"time":elapsed_ms, "quantities":quantities.duplicate(true)})
	while samples.size() > 2 and elapsed_ms - float(samples[1]["time"]) >= WINDOW_MS:
		samples.pop_front()
	_locations[location_id] = samples
	var duration := float(samples.back()["time"]) - float(samples.front()["time"])
	var rates := {}
	for item_id in quantities:
		var delta := int(samples.back()["quantities"].get(item_id, 0)) - int(samples.front()["quantities"].get(item_id, 0))
		rates[item_id] = {"net_rate_per_minute":float(delta) * 60_000.0 / duration if duration >= MIN_SAMPLE_MS else 0.0, "trend_known":duration >= MIN_SAMPLE_MS, "trend_window_ms":duration}
	return rates
