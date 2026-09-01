class_name WreckSiteSystem
extends RefCounted

## Finite aftermath-site contract for the future invasion loop.
##
## A wreck site is created by a resolved invasion event, never by assigning a
## permanent "salvaging" fleet job. Salvage and analysis consume the same finite
## work budget. Once that budget reaches zero the active site disappears. Reward
## settlement is intentionally outside this interface until the invasion and
## aftermath designs define ownership, tools, risks and output tables.

const SITE_SCHEMA_VERSION := 1
const WORK_KIND_SALVAGE := "SALVAGE"
const WORK_KIND_ANALYSIS := "ANALYSIS"
const WORK_KINDS := [WORK_KIND_SALVAGE, WORK_KIND_ANALYSIS]


func create_after_invasion(
	state: SpaceGameState,
	location_id: String,
	invasion_event_id: String,
	total_work: float,
	metadata: Dictionary = {}
) -> Dictionary:
	if location_id.is_empty() or invasion_event_id.is_empty() or total_work <= 0.0:
		return _failure("INVALID_AFTERMATH", "A wreck site requires a location, invasion event and positive finite work")
	if not state.has_location(location_id):
		return _failure("UNKNOWN_LOCATION", "The invasion aftermath location does not exist")
	var site_id := "WRECK-%06d" % state.next_wreck_site_serial
	state.next_wreck_site_serial += 1
	var site := {
		"schema_version":SITE_SCHEMA_VERSION,
		"id":site_id,
		"location_id":location_id,
		"source_type":"INVASION_AFTERMATH",
		"source_event_id":invasion_event_id,
		"status":"ACTIVE",
		"total_work":total_work,
		"remaining_work":total_work,
		"work_completed":{"SALVAGE":0.0, "ANALYSIS":0.0},
		"created_at_ms":state.total_elapsed_ms,
		"metadata":metadata.duplicate(true)
	}
	state.wreck_sites[site_id] = site
	return {"ok":true, "site_id":site_id, "site":site.duplicate(true)}


func apply_work(state: SpaceGameState, site_id: String, work_kind: String, requested_work: float) -> Dictionary:
	var normalized_kind := work_kind.to_upper()
	if normalized_kind not in WORK_KINDS:
		return _failure("INVALID_WORK_KIND", "Wreck sites accept only salvage or analysis work")
	if requested_work <= 0.0:
		return _failure("INVALID_WORK", "Wreck-site work must be positive")
	if not state.wreck_sites.has(site_id):
		return _failure("SITE_UNAVAILABLE", "The wreck site is absent or already exhausted")
	var site := state.wreck_sites[site_id] as Dictionary
	var accepted := minf(requested_work, maxf(0.0, float(site.get("remaining_work", 0.0))))
	var completed: Dictionary = site.get("work_completed", {})
	completed[normalized_kind] = float(completed.get(normalized_kind, 0.0)) + accepted
	site["work_completed"] = completed
	site["remaining_work"] = maxf(0.0, float(site.get("remaining_work", 0.0)) - accepted)
	var exhausted := float(site.get("remaining_work", 0.0)) <= 0.000001
	var result := {
		"ok":true,
		"site_id":site_id,
		"work_kind":normalized_kind,
		"accepted_work":accepted,
		"unaccepted_work":maxf(0.0, requested_work - accepted),
		"remaining_work":float(site.get("remaining_work", 0.0)),
		"exhausted":exhausted,
		"outputs":{}
	}
	if exhausted:
		site["status"] = "EXHAUSTED"
		site["exhausted_at_ms"] = state.total_elapsed_ms
		state.wreck_site_history.append(site.duplicate(true))
		state.wreck_sites.erase(site_id)
	return result


static func normalize_sites(source: Variant) -> Dictionary:
	var result := {}
	if source is not Dictionary:
		return result
	for site_id_value in (source as Dictionary).keys():
		var site_id := str(site_id_value)
		var value = (source as Dictionary).get(site_id_value)
		if site_id.is_empty() or value is not Dictionary:
			continue
		var site := (value as Dictionary).duplicate(true)
		var total_work := maxf(0.0, float(site.get("total_work", 0.0)))
		var remaining_work := clampf(float(site.get("remaining_work", total_work)), 0.0, total_work)
		if total_work <= 0.0 or remaining_work <= 0.0:
			continue
		site["schema_version"] = SITE_SCHEMA_VERSION
		site["id"] = site_id
		site["source_type"] = "INVASION_AFTERMATH"
		site["status"] = "ACTIVE"
		site["total_work"] = total_work
		site["remaining_work"] = remaining_work
		var completed: Dictionary = site.get("work_completed", {}) if site.get("work_completed", null) is Dictionary else {}
		site["work_completed"] = {
			"SALVAGE":maxf(0.0, float(completed.get("SALVAGE", 0.0))),
			"ANALYSIS":maxf(0.0, float(completed.get("ANALYSIS", 0.0)))
		}
		site["metadata"] = site.get("metadata", {}).duplicate(true) if site.get("metadata", null) is Dictionary else {}
		result[site_id] = site
	return result


static func normalize_history(source: Variant) -> Array:
	var result: Array = []
	if source is not Array:
		return result
	for value in source:
		if value is Dictionary:
			result.append((value as Dictionary).duplicate(true))
	return result


static func _failure(code: String, message: String) -> Dictionary:
	return {"ok":false, "reason_code":code, "reason":message}
