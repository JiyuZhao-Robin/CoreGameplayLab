class_name RequirementEngine
extends RefCounted

var content: ContentDatabase
var capability_provider: Callable


func _init(database: ContentDatabase, provider: Callable) -> void:
	content = database
	capability_provider = provider


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
		"activity_complete":
			return int(state.completed_activities.get(str(requirement.get("id", "")), 0)) > 0
		"route_complete":
			return int(state.completed_activities.get("route:%s" % str(requirement.get("id", "")), 0)) > 0
		"capability":
			return float(capability_provider.call(state, str(requirement.get("id", "")))) >= float(requirement.get("value", 1))
		"technology":
			return bool(state.technologies.get(str(requirement.get("id", "")), false))
		"project_complete":
			return bool(state.completed_projects.get(str(requirement.get("id", "")), false))
		"own_ship":
			return state.owns_ship_model(str(requirement.get("id", "")))
		"own_facility":
			return state.facilities.get(str(requirement.get("id", "")), {}).get("status", "") == "ACTIVE"
		"facility_level":
			return int(state.facilities.get(str(requirement.get("id", "")), {}).get("level", 0)) >= int(requirement.get("level", 1))
		"infrastructure_site":
			return bool(state.infrastructure_sites.get(str(requirement.get("id", "")), false))
		"boss_defeated":
			return int(state.completed_activities.get("boss:%s" % requirement.get("id", ""), 0)) > 0
		"mining_site_available":
			return state.mining_site_available(str(requirement.get("id", "")))
		"mining_sites_mastered":
			return state.mastered_mining_site_count(str(requirement.get("region", "")), int(requirement.get("level", 1))) >= int(requirement.get("count", 1))
		"megastructure":
			return bool(state.megastructures.get(str(requirement.get("id", "")), false))
		"game_complete":
			return state.game_complete
	return false
