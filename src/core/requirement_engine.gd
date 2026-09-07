class_name RequirementEngine
extends RefCounted

var content: ContentDatabase
var _capability_provider_ref: WeakRef
var _capability_provider_method: StringName


func _init(database: ContentDatabase, provider_owner: RefCounted, provider_method: StringName) -> void:
	content = database
	_capability_provider_ref = weakref(provider_owner)
	_capability_provider_method = provider_method


func _capability_value(state: SpaceGameState, capability_id: String) -> float:
	var provider_owner := _capability_provider_ref.get_ref() as RefCounted if _capability_provider_ref != null else null
	if provider_owner == null:
		return 0.0
	return float(provider_owner.call(_capability_provider_method, state, capability_id))


func evaluate(state: SpaceGameState, requirement: Dictionary) -> bool:
	var operator := str(requirement.get("op", ""))
	if operator == "AND":
		for child in requirement.get("children", []):
			if not evaluate(state, child):
				return false
		return true
	if operator == "OR":
		for child in requirement.get("children", []):
			if evaluate(state, child):
				return true
		return false
	match str(requirement.get("type", "")):
		"item":
			return state.item_quantity(str(requirement.get("id", ""))) >= int(requirement.get("quantity", 1))
		"region":
			return bool(state.regions.get(str(requirement.get("id", "")), false))
		"domain_level":
			var domain: Dictionary = state.domains.get(str(requirement.get("domain", "")), {})
			return int(domain.get("level", 0)) >= int(requirement.get("level", 1))
		"technology_domain":
			var technology_domain: Dictionary = state.technology_domains.get(str(requirement.get("domain", "")), {})
			return int(technology_domain.get("level", 0)) >= int(requirement.get("level", 1))
		"research_capacity":
			return _capability_value(state, "research_capacity") >= float(requirement.get("value", 1.0))
		"operating_condition":
			return _capability_value(state, str(requirement.get("id", ""))) >= float(requirement.get("value", 1.0))
		"experimental_maturity":
			var maturity_rank := {"THEORY":0, "LAB_SAMPLE":1, "EXPERIMENTAL":2, "PILOT":3, "INDUSTRIAL":4}
			return int(maturity_rank.get(str(state.experimental_maturity.get(str(requirement.get("id", "")), "THEORY")), 0)) >= int(maturity_rank.get(str(requirement.get("level", "EXPERIMENTAL")), 2))
		"spillover":
			return bool(state.technology_spillovers.get(str(requirement.get("id", "")), false))
		"activity_complete":
			return int(state.completed_activities.get(str(requirement.get("id", "")), 0)) > 0
		"route_complete":
			return int(state.completed_activities.get("route:%s" % str(requirement.get("id", "")), 0)) > 0
		"capability":
			return _capability_value(state, str(requirement.get("id", ""))) >= float(requirement.get("value", 1))
		"technology":
			return bool(state.technologies.get(str(requirement.get("id", "")), false))
		"project_complete":
			return bool(state.completed_projects.get(str(requirement.get("id", "")), false))
		"own_ship":
			return state.owns_ship_model(str(requirement.get("id", "")))
		"own_facility":
			# Ownership is a persistent physical fact. Runtime consumers separately
			# use facility_available(), which requires the backing grid provider to
			# be powered and ACTIVE.
			return state.facilities.has(str(requirement.get("id", "")))
		"manufacturing_module_installed":
			var facility: Dictionary = state.facilities.get(str(requirement.get("facility", "")), {})
			var module_id := str(requirement.get("id", ""))
			return module_id in facility.get("installed_process_modules", []) or module_id in facility.get("installed_plugins", [])
		"facility_level":
			return int(state.facilities.get(str(requirement.get("id", "")), {}).get("level", 0)) >= int(requirement.get("level", 1))
		"infrastructure_site":
			return bool(state.infrastructure_sites.get(str(requirement.get("id", "")), false))
		"boss_defeated":
			return int(state.completed_activities.get("boss:%s" % requirement.get("id", ""), 0)) > 0
		"survey_state":
			var location: Dictionary = state.location_state(str(requirement.get("id", "")))
			return LocationState.SURVEY_STATE_ORDER.find(str(location.get("survey_state", LocationState.UNKNOWN))) >= LocationState.SURVEY_STATE_ORDER.find(str(requirement.get("state", LocationState.SURVEYED)))
		"megastructure":
			return bool(state.megastructures.get(str(requirement.get("id", "")), false))
		"megastructure_phase":
			return int(state.megastructure_projects.get(str(requirement.get("id", "")), {}).get("phase_index", 0)) >= int(requirement.get("phase", 0))
		"game_complete":
			return state.game_complete
	return false
