class_name CombatResolver
extends RefCounted

const MAX_COMBAT_EVENTS := 10000
const MAX_LOG_ENTRIES := 48
const COMBAT_STATE_VERSION := 7
const ZONE_ORDER := ["FRONT", "MID", "REAR"]

var content: ContentDatabase
var rng: DomainRng


func _init(database: ContentDatabase, rng_service: DomainRng) -> void:
	content = database
	rng = rng_service


func begin(state: SpaceGameState, ship_ids: Array, enemy_id: String) -> Dictionary:
	var enemy: Dictionary = content.enemies.get(enemy_id, {})
	if enemy.is_empty():
		return {"status":"DEFEAT", "victory":false, "reason":"MISSING_ENEMY", "enemy_id":enemy_id, "elapsed_ms":0.0, "events":0, "log":[]}
	var actors: Array = []
	for ship_id in ship_ids:
		var actor := _build_ship_actor(state, str(ship_id))
		if not actor.is_empty() and float(actor.get("hull", 0.0)) > 0.0:
			actors.append(actor)
	if actors.is_empty():
		return {"status":"DEFEAT", "victory":false, "reason":"NO_OPERATIONAL_SHIP", "enemy_id":enemy_id, "ship_ids":ship_ids.duplicate(), "actors":[], "elapsed_ms":0.0, "events":0, "log":[]}
	var formation_id := str(state.active_expedition.get("formation_id", SpaceGameState.DEFAULT_FORMATION_ID))
	var formation: Dictionary = state.fleet_logistics_runtime(formation_id).get("formation", {})
	var doctrine := str(formation.get("doctrine", "HOLD_FORMATION"))
	_apply_doctrine_defenses(actors, doctrine)
	var combat_state := {
		"version":COMBAT_STATE_VERSION,
		"status":"RUNNING", "victory":false, "reason":"", "enemy_id":enemy_id,
		"ship_ids":ship_ids.duplicate(), "actors":actors, "cohorts":_build_cohorts(actors), "phase_index":0,
		"doctrine":doctrine,
		"retreat_policy":formation.get("retreat_policy", {"mode":"HULL_THRESHOLD", "threshold":0.25}).duplicate(true),
		"damage_target_locks":{},
		"phase_count":maxi(1, enemy.get("phases", []).size()), "phase_id":"", "phase_name":"",
		"enemy_statuses":{}, "enemy_skill_index":0, "elapsed_ms":0.0, "events":0, "log":[]
	}
	_load_phase(combat_state, enemy, 0)
	_sync_fleet_summary(combat_state)
	_append_log(combat_state, {"type":"COMBAT_STARTED", "enemy_id":enemy_id, "phase_id":combat_state.get("phase_id", ""), "actor_count":actors.size(), "cohort_count":combat_state.get("cohorts", []).size(), "doctrine":doctrine})
	return combat_state


func advance_clock(combat_state: Dictionary, elapsed_ms: float) -> void:
	if str(combat_state.get("status", "")) != "RUNNING":
		return
	_normalize_combat_state(combat_state)
	var step := maxf(0.0, elapsed_ms)
	for cohort_value in combat_state.get("cohorts", []):
		var cohort := cohort_value as Dictionary
		if _living_cohort_member_indices(combat_state, cohort).is_empty():
			continue
		for weapon_value in cohort.get("weapon_cycles", []):
			var weapon := weapon_value as Dictionary
			weapon["next_ms"] = maxf(0.0, float(weapon.get("next_ms", 0.0)) - step)
		_sync_cohort_attack_next(cohort)
		if not cohort.get("skills", []).is_empty():
			cohort["skill_next_ms"] = maxf(0.0, float(cohort.get("skill_next_ms", 0.0)) - step)
	combat_state["enemy_attack_next_ms"] = maxf(0.0, float(combat_state.get("enemy_attack_next_ms", 0.0)) - step)
	if not _current_enemy_skills(combat_state).is_empty():
		combat_state["enemy_skill_next_ms"] = maxf(0.0, float(combat_state.get("enemy_skill_next_ms", 0.0)) - step)
	combat_state["elapsed_ms"] = float(combat_state.get("elapsed_ms", 0.0)) + step
	_sync_fleet_summary(combat_state)


func next_event_ms(combat_state: Dictionary) -> float:
	if str(combat_state.get("status", "")) != "RUNNING":
		return INF
	_normalize_combat_state(combat_state)
	var candidate := _next_action_candidate(combat_state)
	return maxf(0.001, float(candidate.get("remaining_ms", INF)))


func event_ready(combat_state: Dictionary) -> bool:
	if str(combat_state.get("status", "")) != "RUNNING":
		return false
	_normalize_combat_state(combat_state)
	return float(_next_action_candidate(combat_state).get("remaining_ms", INF)) <= 0.001


func settle_next_event(state: SpaceGameState, combat_state: Dictionary) -> Dictionary:
	_migrate_legacy_state(state, combat_state)
	if not event_ready(combat_state):
		return {}
	if int(combat_state.get("events", 0)) >= MAX_COMBAT_EVENTS:
		combat_state["status"] = "DEFEAT"
		combat_state["reason"] = "COMBAT_EVENT_LIMIT"
		return {"type":"COMBAT_ENDED", "victory":false, "reason":"COMBAT_EVENT_LIMIT"}
	var action := _next_action_candidate(combat_state)
	var cohort_index := int(action.get("cohort_index", -1))
	var weapon_index := int(action.get("weapon_index", -1))
	var event: Dictionary
	match str(action.get("kind", "")):
		"SHIP_TRIGGER":
			event = _ship_trigger_action(state, combat_state, cohort_index)
		"SHIP_SKILL":
			event = _ship_skill_cycle(state, combat_state, cohort_index)
		"SHIP_ATTACK":
			event = _ship_attack_cycle(state, combat_state, cohort_index, weapon_index)
		"ENEMY_SKILL":
			event = _enemy_skill_cycle(state, combat_state)
		_:
			event = _enemy_attack_cycle(state, combat_state)
	combat_state["events"] = int(combat_state.get("events", 0)) + 1
	_sync_fleet_summary(combat_state)
	_append_log(combat_state, event)
	return event


func result(combat_state: Dictionary) -> Dictionary:
	var victory := str(combat_state.get("status", "")) == "VICTORY"
	var ship_results: Array = []
	var total_damage := 0.0
	for actor in combat_state.get("actors", []):
		var damage_taken := maxf(0.0, float(actor.get("starting_hull", actor.get("max_hull", 0.0))) + float(actor.get("starting_shield", actor.get("max_shield", 0.0))) - float(actor.get("hull", 0.0)) - float(actor.get("shield", 0.0)))
		total_damage += damage_taken
		ship_results.append({"ship_id":str(actor.get("ship_id", "")), "damage_taken":damage_taken, "hull_remaining":maxf(0.0, float(actor.get("hull", 0.0))), "shield_remaining":maxf(0.0, float(actor.get("shield", 0.0))), "disabled":float(actor.get("hull", 0.0)) <= 0.0, "attacks":int(actor.get("attacks", 0)), "skills_used":int(actor.get("skills_used", 0)), "triggered_actions":int(actor.get("triggered_actions", 0)), "damage_dealt":float(actor.get("damage_dealt", 0.0))})
	var cohort_results: Array = []
	for cohort_value in combat_state.get("cohorts", []):
		var cohort := cohort_value as Dictionary
		var weapon_results: Array = []
		for weapon_value in cohort.get("weapon_cycles", []):
			var weapon := weapon_value as Dictionary
			weapon_results.append({"weapon_id":weapon.get("id", ""), "module_id":weapon.get("module_id", ""), "attacks":int(weapon.get("attacks", 0)), "attack_interval_ms":float(weapon.get("attack_interval_ms", 0.0)), "weapon_kind":weapon.get("weapon_kind", "DIRECT")})
		cohort_results.append({"cohort_id":cohort.get("cohort_id", ""), "blueprint_id":cohort.get("blueprint_id", ""), "loadout_key":cohort.get("loadout_key", ""), "zone":cohort.get("zone", ""), "member_ship_ids":cohort.get("member_ship_ids", []).duplicate(), "attacks":int(cohort.get("attacks", 0)), "skills_used":int(cohort.get("skills_used", 0)), "damage_dealt":float(cohort.get("damage_dealt", 0.0)), "weapon_results":weapon_results})
	return {
		"victory":victory, "reason":str(combat_state.get("reason", "ENEMY_DEFEATED" if victory else "FLEET_DISABLED")),
		"duration_ms":float(combat_state.get("elapsed_ms", 0.0)), "damage_taken":total_damage,
		"fleet_hull_remaining":maxf(0.0, float(combat_state.get("fleet_hull", 0.0))), "fleet_shield_remaining":maxf(0.0, float(combat_state.get("fleet_shield", 0.0))),
		"enemy_hull_remaining":maxf(0.0, float(combat_state.get("enemy_hull", 0.0))), "enemy_shield_remaining":maxf(0.0, float(combat_state.get("enemy_shield", 0.0))),
		"phase_index":int(combat_state.get("phase_index", 0)), "phase_count":int(combat_state.get("phase_count", 1)),
		"events":int(combat_state.get("events", 0)), "ship_results":ship_results, "cohort_results":cohort_results, "doctrine":combat_state.get("doctrine", "HOLD_FORMATION"), "log":combat_state.get("log", []).duplicate(true)
	}


func resolve(state: SpaceGameState, ship_ids: Array, enemy_id: String) -> Dictionary:
	var combat_state := begin(state, ship_ids, enemy_id)
	while str(combat_state.get("status", "")) == "RUNNING" and int(combat_state.get("events", 0)) < MAX_COMBAT_EVENTS:
		advance_clock(combat_state, next_event_ms(combat_state))
		settle_next_event(state, combat_state)
	return result(combat_state)


func fleet_stats(state: SpaceGameState, ship_ids: Array) -> Dictionary:
	var stats := {"hull":0.0, "shield":0.0, "armor":0.0, "damage":0.0, "attack_interval_ms":INF, "accuracy":0.0, "evasion":0.0, "point_defense":0.0, "electronic_warfare":0.0, "skills":[], "attack_triggers":[], "ship_count":0}
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if ship.is_empty() or ship.get("condition", "") != "OPERATIONAL":
			continue
		var ship_stats := _ship_stats(state, ship)
		for stat in ["hull", "shield", "damage"]:
			stats[stat] = float(stats[stat]) + float(ship_stats.get(stat, 0.0))
		stats["armor"] = float(stats.armor) + float(ship_stats.get("armor", 0.0))
		stats["accuracy"] = float(stats.accuracy) + float(ship_stats.get("accuracy", 0.5))
		stats["evasion"] = float(stats.evasion) + float(ship_stats.get("evasion", 0.0))
		stats["point_defense"] = float(stats.point_defense) + float(ship_stats.get("point_defense", 0.0))
		stats["electronic_warfare"] = float(stats.electronic_warfare) + float(ship_stats.get("electronic_warfare", 0.0))
		stats["attack_interval_ms"] = minf(float(stats.attack_interval_ms), float(ship_stats.get("attack_interval_ms", 3000.0)))
		stats["skills"].append_array(ship_stats.get("skills", []).duplicate(true))
		stats["attack_triggers"].append_array(ship_stats.get("attack_triggers", []).duplicate(true))
		stats["ship_count"] = int(stats.ship_count) + 1
	if int(stats.ship_count) > 0:
		stats["armor"] = float(stats.armor) / float(stats.ship_count)
		stats["accuracy"] = float(stats.accuracy) / float(stats.ship_count)
		stats["evasion"] = float(stats.evasion) / float(stats.ship_count)
	if float(stats.attack_interval_ms) == INF:
		stats["attack_interval_ms"] = 3000.0
	return stats


func _ship_stats(state: SpaceGameState, ship: Dictionary) -> Dictionary:
	var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
	var base: Dictionary = blueprint.get("base_stats", {})
	var stats := {"hull":float(base.get("hull", 0.0)), "shield":float(base.get("shield", 0.0)), "armor":float(base.get("armor", 0.0)), "damage":float(base.get("damage", 0.0)), "attack_interval_ms":float(base.get("attack_interval_ms", 3000.0)), "accuracy":float(base.get("accuracy", 0.5)), "evasion":float(base.get("evasion", 0.0)), "point_defense":float(base.get("point_defense", 0.0)), "electronic_warfare":float(base.get("electronic_warfare", 0.0)), "weapon_kind":str(base.get("weapon_kind", "DIRECT")), "shield_penetration":clampf(float(base.get("shield_penetration", 0.0)), 0.0, 1.0), "bypass_exposure":bool(base.get("bypass_exposure", false)), "weapon_actions":[], "skills":blueprint.get("combat_skills", []).duplicate(true), "attack_triggers":blueprint.get("attack_triggers", []).duplicate(true), "ammunition_item":"", "ammunition_per_attack":0}
	if float(base.get("damage", 0.0)) > 0.0:
		stats["weapon_actions"].append({"id":"%s_hull_weapon" % blueprint.get("id", "ship"), "name":"Hull Weapon", "damage":float(base.get("damage", 0.0)), "attack_interval_ms":float(base.get("attack_interval_ms", 3000.0)), "accuracy_bonus":0.0, "weapon_kind":str(base.get("weapon_kind", "DIRECT")).to_upper(), "shield_penetration":clampf(float(base.get("shield_penetration", 0.0)), 0.0, 1.0), "bypass_exposure":bool(base.get("bypass_exposure", false)), "ammunition_item":"", "ammunition_per_attack":0})
	var weapon_serial := 0
	for module_id in state.ship_module_definition_ids(ship):
		var module: Dictionary = content.modules.get(str(module_id), {})
		var module_stats: Dictionary = module.get("combat_stats", {})
		for stat in ["hull", "shield", "armor", "damage", "accuracy", "evasion", "point_defense", "electronic_warfare"]:
			stats[stat] = float(stats[stat]) + float(module_stats.get(stat, 0.0))
		if module_stats.has("attack_interval_ms"):
			stats["attack_interval_ms"] = minf(float(stats.attack_interval_ms), float(module_stats.attack_interval_ms))
		for skill in module.get("combat_skills", []):
			stats["skills"].append(skill.duplicate(true))
		for trigger in module.get("combat_attack_triggers", []):
			stats["attack_triggers"].append(trigger.duplicate(true))
		if stats["ammunition_item"].is_empty() and not str(module.get("ammunition_item", "")).is_empty():
			stats["ammunition_item"] = str(module.get("ammunition_item", ""))
			stats["ammunition_per_attack"] = maxi(1, int(module.get("ammunition_per_attack", 1)))
		if str(module.get("slot", "")) == "weapon":
			weapon_serial += 1
			stats["weapon_kind"] = str(module.get("weapon_kind", module_stats.get("weapon_kind", stats.get("weapon_kind", "DIRECT")))).to_upper()
			stats["shield_penetration"] = maxf(float(stats.get("shield_penetration", 0.0)), clampf(float(module_stats.get("shield_penetration", module.get("shield_penetration", 0.0))), 0.0, 1.0))
			stats["bypass_exposure"] = bool(stats.get("bypass_exposure", false)) or bool(module.get("bypass_exposure", false))
			if float(module_stats.get("damage", 0.0)) > 0.0:
				stats["weapon_actions"].append({
					"id":"%s_%d" % [module.get("id", "weapon"), weapon_serial],
					"module_id":str(module.get("id", "")),
					"name":module.get("name", module.get("id", "Weapon")),
					"damage":float(module_stats.get("damage", 0.0)),
					"attack_interval_ms":float(module_stats.get("attack_interval_ms", base.get("attack_interval_ms", 3000.0))),
					"accuracy_bonus":float(module_stats.get("accuracy", 0.0)),
					"weapon_kind":str(module.get("weapon_kind", module_stats.get("weapon_kind", "DIRECT"))).to_upper(),
					"shield_penetration":clampf(float(module_stats.get("shield_penetration", module.get("shield_penetration", 0.0))), 0.0, 1.0),
					"bypass_exposure":bool(module.get("bypass_exposure", false)),
					"ammunition_item":str(module.get("ammunition_item", "")),
					"ammunition_per_attack":maxi(0, int(module.get("ammunition_per_attack", 0)))
				})
	return stats


func _build_ship_actor(state: SpaceGameState, ship_id: String) -> Dictionary:
	var ship := state.ship_by_id(ship_id)
	if ship.is_empty() or ship.get("condition", "") != "OPERATIONAL" or float(ship.get("maintenance_coverage", 1.0)) <= 0.0:
		return {}
	var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
	var stats := _ship_stats(state, ship)
	var current_shield := float(stats.shield)
	var current_hull := float(stats.hull)
	var prior_damage := maxf(0.0, float(ship.get("damage_taken", 0.0)))
	var shield_damage := minf(current_shield, prior_damage)
	current_shield -= shield_damage
	current_hull = maxf(0.0, current_hull - maxf(0.0, prior_damage - shield_damage))
	var formation_id := str(state.active_expedition.get("formation_id", SpaceGameState.DEFAULT_FORMATION_ID))
	var formation: Dictionary = state.fleet_logistics_runtime(formation_id).get("formation", {})
	var zone := str(formation.get("ship_zones", {}).get(ship_id, "FRONT")).to_upper()
	if zone not in ZONE_ORDER:
		zone = "FRONT"
	return {
		"id":str(ship.get("blueprint_id", "")), "ship_id":ship_id, "blueprint_id":str(ship.get("blueprint_id", "")), "name":str(blueprint.get("name", ship_id)), "instance_name":str(ship.get("name", ship_id)), "class":str(blueprint.get("class", "Ship")),
		"max_hull":float(stats.hull), "max_shield":float(stats.shield), "starting_hull":current_hull, "starting_shield":current_shield,
		"hull":current_hull, "shield":current_shield, "armor":float(stats.armor), "damage":float(stats.damage), "accuracy":float(stats.accuracy), "evasion":float(stats.evasion), "point_defense":clampf(float(stats.point_defense), 0.0, 0.9), "electronic_warfare":clampf(float(stats.electronic_warfare), 0.0, 0.9), "zone":zone,
		"loadout_key":",".join(state.ship_module_definition_ids(ship)),
		"weapon_kind":str(stats.get("weapon_kind", "DIRECT")), "shield_penetration":float(stats.get("shield_penetration", 0.0)), "bypass_exposure":bool(stats.get("bypass_exposure", false)),
		"weapon_actions":stats.get("weapon_actions", []).duplicate(true),
		"attack_interval_ms":float(stats.attack_interval_ms), "attack_next_ms":float(stats.attack_interval_ms),
		"ammunition_item":str(stats.get("ammunition_item", "")), "ammunition_per_attack":int(stats.get("ammunition_per_attack", 0)),
		"statuses":{}, "skills":stats.skills.duplicate(true), "skill_index":0,
		"skill_next_ms":_skill_cycle_ms(stats.skills[0], float(stats.attack_interval_ms)) if not stats.skills.is_empty() else 0.0,
		"attack_triggers":stats.attack_triggers.duplicate(true), "pending_trigger_actions":[],
		"attacks":0, "skills_used":0, "triggered_actions":0, "damage_dealt":0.0
	}


func _apply_doctrine_defenses(actors: Array, doctrine: String) -> void:
	for actor_value in actors:
		var actor := actor_value as Dictionary
		match doctrine:
			"AGGRESSIVE_PUSH":
				actor["evasion"] = maxf(0.0, float(actor.get("evasion", 0.0)) * 0.9)
			"LONG_RANGE_ENGAGEMENT":
				if str(actor.get("zone", "FRONT")) == "REAR":
					actor["evasion"] = minf(0.95, float(actor.get("evasion", 0.0)) * 1.1)


func _build_cohorts(actors: Array) -> Array:
	var result: Array = []
	var cohort_by_key := {}
	for actor_index in range(actors.size()):
		var actor := actors[actor_index] as Dictionary
		var key := "%s|%s|%s" % [actor.get("blueprint_id", ""), actor.get("loadout_key", ""), actor.get("zone", "FRONT")]
		if not cohort_by_key.has(key):
			var cohort := {
				"cohort_id":"COHORT-%03d" % (result.size() + 1),
				"cohort_key":key,
				"blueprint_id":str(actor.get("blueprint_id", "")),
				"loadout_key":str(actor.get("loadout_key", "")),
				"zone":str(actor.get("zone", "FRONT")),
				"member_indices":[],
				"member_ship_ids":[],
				"damage":float(actor.get("damage", 0.0)),
				"accuracy":float(actor.get("accuracy", 0.5)),
				"weapon_kind":str(actor.get("weapon_kind", "DIRECT")),
				"shield_penetration":float(actor.get("shield_penetration", 0.0)),
				"bypass_exposure":bool(actor.get("bypass_exposure", false)),
				"weapon_cycles":_initialize_weapon_cycles(actor.get("weapon_actions", []), actor),
				"attack_interval_ms":float(actor.get("attack_interval_ms", 3000.0)),
				"attack_next_ms":float(actor.get("attack_interval_ms", 3000.0)),
				"ammunition_item":str(actor.get("ammunition_item", "")),
				"ammunition_per_attack":int(actor.get("ammunition_per_attack", 0)),
				"skills":actor.get("skills", []).duplicate(true),
				"skill_index":0,
				"skill_next_ms":float(actor.get("skill_next_ms", 0.0)),
				"attack_triggers":actor.get("attack_triggers", []).duplicate(true),
				"pending_trigger_actions":[],
				"attacks":0,
				"skills_used":0,
				"triggered_actions":0,
				"damage_dealt":0.0
			}
			cohort_by_key[key] = result.size()
			result.append(cohort)
		var cohort: Dictionary = result[int(cohort_by_key[key])]
		cohort["member_indices"].append(actor_index)
		cohort["member_ship_ids"].append(str(actor.get("ship_id", "")))
	return result


func _initialize_weapon_cycles(weapon_actions: Array, actor: Dictionary) -> Array:
	var result: Array = []
	var source_actions := weapon_actions
	if source_actions.is_empty():
		source_actions = [{"id":"legacy_attack", "name":"Attack", "damage":float(actor.get("damage", 0.0)), "attack_interval_ms":float(actor.get("attack_interval_ms", 3000.0)), "accuracy_bonus":0.0, "weapon_kind":actor.get("weapon_kind", "DIRECT"), "shield_penetration":actor.get("shield_penetration", 0.0), "bypass_exposure":actor.get("bypass_exposure", false), "ammunition_item":actor.get("ammunition_item", ""), "ammunition_per_attack":actor.get("ammunition_per_attack", 0)}]
	for action_value in source_actions:
		var action := (action_value as Dictionary).duplicate(true)
		action["attack_interval_ms"] = maxf(1.0, float(action.get("attack_interval_ms", actor.get("attack_interval_ms", 3000.0))))
		action["next_ms"] = float(action.get("next_ms", action.get("attack_interval_ms", 3000.0)))
		action["attacks"] = maxi(0, int(action.get("attacks", 0)))
		result.append(action)
	return result


func _living_cohort_member_indices(combat_state: Dictionary, cohort: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var actors: Array = combat_state.get("actors", [])
	for member_value in cohort.get("member_indices", []):
		var actor_index := int(member_value)
		if actor_index >= 0 and actor_index < actors.size() and float(actors[actor_index].get("hull", 0.0)) > 0.0:
			result.append(actor_index)
	return result


func _ship_attack_cycle(state: SpaceGameState, combat_state: Dictionary, cohort_index: int, weapon_index: int = 0) -> Dictionary:
	var cohort: Dictionary = combat_state.get("cohorts", [])[cohort_index]
	var living_members := _living_cohort_member_indices(combat_state, cohort)
	var weapon_cycles: Array = cohort.get("weapon_cycles", [])
	if weapon_cycles.is_empty():
		cohort["weapon_cycles"] = _initialize_weapon_cycles([], cohort)
		weapon_cycles = cohort.get("weapon_cycles", [])
	weapon_index = clampi(weapon_index, 0, weapon_cycles.size() - 1)
	var weapon: Dictionary = weapon_cycles[weapon_index]
	var ammunition_item := str(weapon.get("ammunition_item", ""))
	var ammunition_per_attack := int(weapon.get("ammunition_per_attack", 0)) * living_members.size() * _doctrine_ammunition_multiplier(combat_state, cohort, weapon)
	var formation_id := str(state.active_expedition.get("formation_id", SpaceGameState.DEFAULT_FORMATION_ID))
	if not ammunition_item.is_empty() and ammunition_per_attack > 0 and not state.consume_fleet_supply(ammunition_item, ammunition_per_attack, formation_id):
		weapon["next_ms"] = float(weapon.get("attack_interval_ms", 3000.0))
		_sync_cohort_attack_next(cohort)
		combat_state["status"] = "WITHDRAWN"
		combat_state["victory"] = false
		combat_state["reason"] = "AMMUNITION_DEPLETED"
		return {"type":"SUPPLY_DEPLETED", "source":"COHORT", "cohort_id":str(cohort.get("cohort_id", "")), "ship_ids":cohort.get("member_ship_ids", []).duplicate(), "item_id":ammunition_item, "weapon_id":weapon.get("id", ""), "weapon_index":weapon_index, "action_kind":"BASIC_ATTACK", "cycle_kind":"ATTACK", "combat_ended":true}
	var action := weapon.duplicate(true)
	action["damage_multiplier"] = 1.0
	var event := _resolve_ship_action(state, combat_state, cohort_index, action, "BASIC_ATTACK")
	cohort["attacks"] = int(cohort.get("attacks", 0)) + 1
	weapon["attacks"] = int(weapon.get("attacks", 0)) + 1
	for actor_index in living_members:
		var actor: Dictionary = combat_state.get("actors", [])[actor_index]
		actor["attacks"] = int(actor.get("attacks", 0)) + 1
	var queued_ids: Array[String] = []
	for trigger in cohort.get("attack_triggers", []):
		var every_attacks := int(trigger.get("every_attacks", 0))
		if every_attacks > 0 and int(cohort.get("attacks", 0)) % every_attacks == 0:
			var pending: Array = cohort.get("pending_trigger_actions", [])
			pending.append(trigger.duplicate(true))
			cohort["pending_trigger_actions"] = pending
			queued_ids.append(str(trigger.get("id", "")))
	if not queued_ids.is_empty():
		event["queued_trigger_ids"] = queued_ids
	weapon["next_ms"] = float(weapon.get("attack_interval_ms", 3000.0)) * _cohort_status_cycle_multiplier(combat_state, cohort, "ATTACK")
	_sync_cohort_attack_next(cohort)
	event["weapon_id"] = str(weapon.get("id", ""))
	event["weapon_index"] = weapon_index
	return event


func _ship_skill_cycle(state: SpaceGameState, combat_state: Dictionary, cohort_index: int) -> Dictionary:
	var cohort: Dictionary = combat_state.get("cohorts", [])[cohort_index]
	var skills: Array = cohort.get("skills", [])
	if skills.is_empty():
		return {}
	var skill_index := int(cohort.get("skill_index", 0)) % skills.size()
	var skill: Dictionary = skills[skill_index]
	var event := _resolve_ship_action(state, combat_state, cohort_index, skill, "SKILL")
	cohort["skills_used"] = int(cohort.get("skills_used", 0)) + 1
	for actor_index in _living_cohort_member_indices(combat_state, cohort):
		var actor: Dictionary = combat_state.get("actors", [])[actor_index]
		actor["skills_used"] = int(actor.get("skills_used", 0)) + 1
	cohort["skill_index"] = skill_index + 1
	var next_skill: Dictionary = skills[int(cohort.skill_index) % skills.size()]
	cohort["skill_next_ms"] = _skill_cycle_ms(next_skill, float(cohort.get("attack_interval_ms", 3000.0))) * _cohort_status_cycle_multiplier(combat_state, cohort, "SKILL")
	return event


func _ship_trigger_action(state: SpaceGameState, combat_state: Dictionary, cohort_index: int) -> Dictionary:
	var cohort: Dictionary = combat_state.get("cohorts", [])[cohort_index]
	var pending: Array = cohort.get("pending_trigger_actions", [])
	if pending.is_empty():
		return {}
	var trigger: Dictionary = pending.pop_front()
	cohort["pending_trigger_actions"] = pending
	var event := _resolve_ship_action(state, combat_state, cohort_index, trigger, "ATTACK_TRIGGER")
	cohort["triggered_actions"] = int(cohort.get("triggered_actions", 0)) + 1
	for actor_index in _living_cohort_member_indices(combat_state, cohort):
		var actor: Dictionary = combat_state.get("actors", [])[actor_index]
		actor["triggered_actions"] = int(actor.get("triggered_actions", 0)) + 1
	return event


func _resolve_ship_action(state: SpaceGameState, combat_state: Dictionary, cohort_index: int, action: Dictionary, action_kind: String) -> Dictionary:
	var cohort: Dictionary = combat_state.get("cohorts", [])[cohort_index]
	var living_members := _living_cohort_member_indices(combat_state, cohort)
	var enemy: Dictionary = content.enemies.get(str(combat_state.get("enemy_id", "")), {})
	var accuracy := float(cohort.get("accuracy", 0.5)) + float(action.get("accuracy_bonus", 0.0)) + _cohort_status_average(combat_state, cohort, "accuracy_modifier_per_stack")
	var chance := clampf(accuracy - float(combat_state.get("enemy_evasion", 0.0)) + 0.5, 0.05, 0.95)
	var hit := rng.next_float(state, "combat.hit.%s" % cohort.get("cohort_id", cohort_index)) <= chance
	var damage := 0.0
	var enemy_packet := {}
	if hit:
		var raw_damage := float(action.get("damage", cohort.get("damage", 0.0))) * float(living_members.size()) * float(action.get("damage_multiplier", 1.0)) * _doctrine_damage_multiplier(combat_state, cohort, action)
		damage = _mitigated_damage(raw_damage, float(combat_state.get("enemy_armor", 0.0)))
		damage *= 1.0 + _status_sum(combat_state.get("enemy_statuses", {}), "damage_taken_multiplier_per_stack")
		enemy_packet = _apply_enemy_damage(combat_state, damage, clampf(float(action.get("shield_penetration", cohort.get("shield_penetration", 0.0))), 0.0, 1.0))
	cohort["damage_dealt"] = float(cohort.get("damage_dealt", 0.0)) + damage
	for actor_index in living_members:
		var actor: Dictionary = combat_state.get("actors", [])[actor_index]
		actor["damage_dealt"] = float(actor.get("damage_dealt", 0.0)) + damage / maxf(1.0, float(living_members.size()))
	_tick_status_dictionary(combat_state, "enemy_statuses")
	if action.has("apply_status"):
		_apply_enemy_status(combat_state, action.get("apply_status", {}))
	var event := _attack_event("SHIP", str(action.get("id", "ship_attack")), hit, damage, combat_state)
	event["action_kind"] = action_kind
	event["cycle_kind"] = "ATTACK" if action_kind == "BASIC_ATTACK" else ("SKILL" if action_kind == "SKILL" else "TRIGGER")
	event["cohort_id"] = str(cohort.get("cohort_id", ""))
	event["ship_ids"] = cohort.get("member_ship_ids", []).duplicate()
	event["cohort_size"] = living_members.size()
	event["cohort_index"] = cohort_index
	event["weapon_kind"] = str(action.get("weapon_kind", cohort.get("weapon_kind", "DIRECT"))).to_upper()
	event["damage_packet"] = enemy_packet
	if float(combat_state.get("enemy_hull", 0.0)) <= 0.0:
		var next_phase := int(combat_state.get("phase_index", 0)) + 1
		if next_phase < int(combat_state.get("phase_count", 1)):
			_load_phase(combat_state, enemy, next_phase)
			event["phase_transition"] = true
			event["next_phase_id"] = combat_state.get("phase_id", "")
		else:
			combat_state["status"] = "VICTORY"
			combat_state["victory"] = true
			combat_state["reason"] = "ENEMY_DEFEATED"
			event["combat_ended"] = true
	return event


func _doctrine_damage_multiplier(combat_state: Dictionary, cohort: Dictionary, action: Dictionary = {}) -> float:
	match str(combat_state.get("doctrine", "HOLD_FORMATION")):
		"AGGRESSIVE_PUSH":
			return 1.15
		"MISSILE_SATURATION":
			return 1.20 if not str(action.get("ammunition_item", cohort.get("ammunition_item", ""))).is_empty() else 1.0
		"LONG_RANGE_ENGAGEMENT":
			return 1.10 if str(cohort.get("zone", "FRONT")) in ["MID", "REAR"] else 0.90
	return 1.0


func _doctrine_ammunition_multiplier(combat_state: Dictionary, cohort: Dictionary, action: Dictionary = {}) -> int:
	return 2 if str(combat_state.get("doctrine", "")) == "MISSILE_SATURATION" and not str(action.get("ammunition_item", cohort.get("ammunition_item", ""))).is_empty() else 1


func _cohort_status_average(combat_state: Dictionary, cohort: Dictionary, field: String) -> float:
	var living := _living_cohort_member_indices(combat_state, cohort)
	if living.is_empty():
		return 0.0
	var total := 0.0
	for actor_index in living:
		total += _status_sum(combat_state.get("actors", [])[actor_index].get("statuses", {}), field)
	return total / float(living.size())


func _cohort_status_cycle_multiplier(combat_state: Dictionary, cohort: Dictionary, cycle_kind: String) -> float:
	var living := _living_cohort_member_indices(combat_state, cohort)
	if living.is_empty():
		return 1.0
	var total := 0.0
	for actor_index in living:
		total += _status_cycle_interval_multiplier(combat_state.get("actors", [])[actor_index].get("statuses", {}), cycle_kind)
	return total / float(living.size())


func _enemy_attack_cycle(state: SpaceGameState, combat_state: Dictionary) -> Dictionary:
	var action := {"id":"enemy_attack", "name":"Attack", "damage_multiplier":1.0}
	var event := _resolve_enemy_action(state, combat_state, action, "BASIC_ATTACK")
	combat_state["enemy_attack_next_ms"] = float(combat_state.get("enemy_attack_interval_ms", 2000.0)) * _status_cycle_interval_multiplier(combat_state.get("enemy_statuses", {}), "ATTACK")
	return event


func _enemy_skill_cycle(state: SpaceGameState, combat_state: Dictionary) -> Dictionary:
	var enemy: Dictionary = content.enemies.get(str(combat_state.get("enemy_id", "")), {})
	var phase := _phase_definition(enemy, int(combat_state.get("phase_index", 0)))
	var skills: Array = phase.get("skills", [])
	if skills.is_empty():
		return {}
	var skill_index := int(combat_state.get("enemy_skill_index", 0)) % skills.size()
	var skill: Dictionary = skills[skill_index]
	var event := _resolve_enemy_action(state, combat_state, skill, "SKILL")
	combat_state["enemy_skill_index"] = skill_index + 1
	var next_skill: Dictionary = skills[int(combat_state.enemy_skill_index) % skills.size()]
	combat_state["enemy_skill_next_ms"] = _skill_cycle_ms(next_skill, float(combat_state.get("enemy_attack_interval_ms", 2000.0))) * _status_cycle_interval_multiplier(combat_state.get("enemy_statuses", {}), "SKILL")
	return event


func _resolve_enemy_action(state: SpaceGameState, combat_state: Dictionary, skill: Dictionary, action_kind: String) -> Dictionary:
	var restored := minf(maxf(0.0, float(skill.get("shield_restore", 0.0))), maxf(0.0, float(combat_state.get("enemy_max_shield", 0.0)) - float(combat_state.get("enemy_shield", 0.0))))
	combat_state["enemy_shield"] = float(combat_state.get("enemy_shield", 0.0)) + restored
	var target_indices := _enemy_target_indices(state, combat_state, skill)
	var total_damage := 0.0
	var hit_any := false
	var target_ids: Array[String] = []
	var damage_packets: Array = []
	for actor_index in target_indices:
		var actor: Dictionary = combat_state.get("actors", [])[actor_index]
		target_ids.append(str(actor.get("ship_id", "")))
		var weapon_kind := str(skill.get("weapon_kind", "DIRECT")).to_upper()
		var defense_strength := _weapon_defense_strength(actor, weapon_kind)
		var accuracy := float(combat_state.get("enemy_accuracy", 0.5)) + float(skill.get("accuracy_bonus", 0.0)) + _status_sum(combat_state.get("enemy_statuses", {}), "accuracy_modifier_per_stack")
		var chance := clampf(accuracy - float(actor.get("evasion", 0.0)) - defense_strength + 0.5, 0.05, 0.95)
		var hit := rng.next_float(state, "combat.enemy_hit.%s" % actor.get("ship_id", actor_index)) <= chance
		if hit:
			var raw_damage := float(combat_state.get("enemy_damage", 1.0)) * float(skill.get("damage_multiplier", 1.0))
			var damage := _mitigated_damage(raw_damage, float(actor.get("armor", 0.0)))
			damage *= (1.0 + _status_sum(actor.get("statuses", {}), "damage_taken_multiplier_per_stack")) * (1.0 - defense_strength * 0.6)
			var penetration := clampf(float(skill.get("shield_penetration", 1.0 if weapon_kind == "PENETRATION" else 0.0)), 0.0, 1.0)
			var packet := _apply_actor_damage(actor, damage, penetration)
			packet.merge({"target_ship_id":str(actor.get("ship_id", "")), "raw_damage":raw_damage, "mitigated_damage":damage, "zone":str(actor.get("zone", "FRONT")), "weapon_kind":weapon_kind, "defense_strength":defense_strength, "shield_penetration":penetration}, true)
			damage_packets.append(packet)
			total_damage += damage
			hit_any = true
		_tick_actor_statuses(actor)
		if skill.has("apply_status"):
			_apply_actor_status(actor, skill.get("apply_status", {}))
	_tick_status_dictionary(combat_state, "enemy_statuses")
	_sync_fleet_summary(combat_state)
	var event := _attack_event("ENEMY", str(skill.get("id", "enemy_attack")), hit_any, total_damage, combat_state)
	event["action_kind"] = action_kind
	event["cycle_kind"] = "ATTACK" if action_kind == "BASIC_ATTACK" else "SKILL"
	event["target_ship_ids"] = target_ids
	event["damage_packets"] = damage_packets
	event["shield_restored"] = restored
	if _living_actor_indices(combat_state).is_empty():
		combat_state["status"] = "DEFEAT"
		combat_state["victory"] = false
		combat_state["reason"] = "FLEET_DISABLED"
		event["combat_ended"] = true
	elif _retreat_policy_triggered(combat_state):
		combat_state["status"] = "WITHDRAWN"
		combat_state["victory"] = false
		combat_state["reason"] = "RETREAT_POLICY"
		event["combat_ended"] = true
		event["retreat_triggered"] = true
	return event


func _enemy_target_indices(state: SpaceGameState, combat_state: Dictionary, skill: Dictionary) -> Array[int]:
	var living := _living_actor_indices(combat_state)
	if living.is_empty():
		return []
	if str(skill.get("target_mode", "SINGLE")) in ["ALL", "ALL_SHIPS"]:
		return living
	var exposed: Array[int] = []
	var zone_order := ZONE_ORDER.duplicate()
	var target_mode := str(skill.get("target_mode", "SINGLE")).to_upper()
	if bool(skill.get("bypass_exposure", false)) or target_mode in ["BYPASS", "BYPASS_EXPOSURE", "MISSILE", "STRIKE_CRAFT"]:
		zone_order.reverse()
	for zone in zone_order:
		for actor_index in living:
			if str(combat_state.get("actors", [])[actor_index].get("zone", "FRONT")) == zone:
				exposed.append(actor_index)
		if not exposed.is_empty():
			break
	var lock_key := str(skill.get("id", "BASIC_ATTACK"))
	var locks: Dictionary = combat_state.get("damage_target_locks", {})
	var current_lock: Dictionary = locks.get(lock_key, {})
	var locked_index := int(current_lock.get("actor_index", -1))
	if exposed.has(locked_index) and int(current_lock.get("remaining_packets", 0)) > 0:
		current_lock["remaining_packets"] = int(current_lock.get("remaining_packets", 0)) - 1
		locks[lock_key] = current_lock
		combat_state["damage_target_locks"] = locks
		return [locked_index]
	var total_weight := 0.0
	var weighted: Array = []
	for actor_index in exposed:
		var actor: Dictionary = combat_state.get("actors", [])[actor_index]
		var hull_ratio := float(actor.get("hull", 0.0)) / maxf(1.0, float(actor.get("max_hull", 1.0)))
		var weight := 1.0 + sqrt(maxf(1.0, float(actor.get("max_hull", 1.0)))) / 20.0
		match str(skill.get("target_priority", "EXPOSURE")):
			"DAMAGED", "LOW_HULL": weight *= 1.0 + (1.0 - hull_ratio) * 3.0
			"CAPITAL", "LARGE_HULL": weight *= 1.0 + float(actor.get("max_hull", 1.0)) / 300.0
			"REAR": weight *= 2.0 if str(actor.get("zone", "")) == "REAR" else 0.5
		total_weight += weight
		weighted.append({"actor_index":actor_index, "ceiling":total_weight})
	var roll := rng.next_float(state, "combat.enemy_target.%s.%s" % [lock_key, str(combat_state.get("events", 0))]) * total_weight
	var selected := int(weighted[-1].get("actor_index", exposed[0]))
	for entry_value in weighted:
		var entry := entry_value as Dictionary
		if roll <= float(entry.get("ceiling", 0.0)):
			selected = int(entry.get("actor_index", selected))
			break
	locks[lock_key] = {"actor_index":selected, "remaining_packets":maxi(0, int(skill.get("stickiness_packets", 2)))}
	combat_state["damage_target_locks"] = locks
	return [selected]


func _living_actor_indices(combat_state: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var actors: Array = combat_state.get("actors", [])
	for index in range(actors.size()):
		if float(actors[index].get("hull", 0.0)) > 0.0:
			result.append(index)
	return result


func _next_action_candidate(combat_state: Dictionary) -> Dictionary:
	var best := {"kind":"", "cohort_index":-1, "weapon_index":-1, "remaining_ms":INF, "priority":999, "order":999999}
	var cohorts: Array = combat_state.get("cohorts", [])
	for index in range(cohorts.size()):
		var cohort: Dictionary = cohorts[index]
		if _living_cohort_member_indices(combat_state, cohort).is_empty():
			continue
		if not cohort.get("pending_trigger_actions", []).is_empty():
			best = _prefer_action(best, "SHIP_TRIGGER", index, 0.0, 0, index)
		if not cohort.get("skills", []).is_empty():
			best = _prefer_action(best, "SHIP_SKILL", index, float(cohort.get("skill_next_ms", INF)), 1, index)
		var weapon_cycles: Array = cohort.get("weapon_cycles", [])
		for weapon_index in weapon_cycles.size():
			var weapon := weapon_cycles[weapon_index] as Dictionary
			best = _prefer_action(best, "SHIP_ATTACK", index, float(weapon.get("next_ms", INF)), 2, index * 100 + weapon_index, weapon_index)
	if not _current_enemy_skills(combat_state).is_empty():
		best = _prefer_action(best, "ENEMY_SKILL", -1, float(combat_state.get("enemy_skill_next_ms", INF)), 1, cohorts.size())
	best = _prefer_action(best, "ENEMY_ATTACK", -1, float(combat_state.get("enemy_attack_next_ms", INF)), 2, cohorts.size())
	return best


func _prefer_action(current: Dictionary, kind: String, cohort_index: int, remaining_ms: float, priority: int, order: int, weapon_index: int = -1) -> Dictionary:
	var current_time := float(current.get("remaining_ms", INF))
	if remaining_ms < current_time - 0.0001:
		return {"kind":kind, "cohort_index":cohort_index, "weapon_index":weapon_index, "remaining_ms":remaining_ms, "priority":priority, "order":order}
	if absf(remaining_ms - current_time) <= 0.0001:
		if priority < int(current.get("priority", 999)) or (priority == int(current.get("priority", 999)) and order < int(current.get("order", 999999))):
			return {"kind":kind, "cohort_index":cohort_index, "weapon_index":weapon_index, "remaining_ms":remaining_ms, "priority":priority, "order":order}
	return current


func _sync_cohort_attack_next(cohort: Dictionary) -> void:
	var next_ms := INF
	for weapon_value in cohort.get("weapon_cycles", []):
		next_ms = minf(next_ms, float((weapon_value as Dictionary).get("next_ms", INF)))
	cohort["attack_next_ms"] = next_ms if next_ms != INF else float(cohort.get("attack_interval_ms", 3000.0))


func _load_phase(combat_state: Dictionary, enemy: Dictionary, phase_index: int) -> void:
	var phase := _phase_definition(enemy, phase_index)
	combat_state["phase_index"] = phase_index
	combat_state["phase_id"] = str(phase.get("id", enemy.get("id", "")))
	combat_state["phase_name"] = str(phase.get("name", enemy.get("name", "")))
	combat_state["enemy_max_hull"] = float(phase.get("hull", enemy.get("hull", 1.0)))
	combat_state["enemy_max_shield"] = float(phase.get("shield", enemy.get("shield", 0.0)))
	combat_state["enemy_hull"] = float(combat_state.enemy_max_hull)
	combat_state["enemy_shield"] = float(combat_state.enemy_max_shield)
	combat_state["enemy_armor"] = float(phase.get("armor", enemy.get("armor", 0.0)))
	combat_state["enemy_damage"] = float(phase.get("damage", enemy.get("damage", 1.0)))
	combat_state["enemy_attack_interval_ms"] = float(phase.get("attack_interval_ms", enemy.get("attack_interval_ms", 2000.0)))
	combat_state["enemy_accuracy"] = float(phase.get("accuracy", enemy.get("accuracy", 0.5)))
	combat_state["enemy_evasion"] = float(phase.get("evasion", enemy.get("evasion", 0.0)))
	combat_state["enemy_attack_next_ms"] = float(combat_state.enemy_attack_interval_ms)
	combat_state["enemy_skill_index"] = 0
	var skills: Array = phase.get("skills", [])
	combat_state["enemy_skill_next_ms"] = _skill_cycle_ms(skills[0], float(combat_state.enemy_attack_interval_ms)) if not skills.is_empty() else 0.0
	combat_state["enemy_statuses"] = {}
	_append_log(combat_state, {"type":"PHASE_STARTED", "phase_index":phase_index, "phase_id":combat_state.phase_id})


func _phase_definition(enemy: Dictionary, phase_index: int) -> Dictionary:
	var phases: Array = enemy.get("phases", [])
	if phases.is_empty():
		return enemy
	return phases[clampi(phase_index, 0, phases.size() - 1)]


func _apply_enemy_damage(combat_state: Dictionary, damage: float, shield_penetration: float = 0.0) -> Dictionary:
	var shield_before := float(combat_state.get("enemy_shield", 0.0))
	var hull_before := float(combat_state.get("enemy_hull", 0.0))
	var bypass_damage := damage * clampf(shield_penetration, 0.0, 1.0)
	var shield_facing_damage := damage - bypass_damage
	var absorbed := minf(shield_before, shield_facing_damage)
	combat_state["enemy_shield"] = shield_before - absorbed
	combat_state["enemy_hull"] = maxf(0.0, hull_before - bypass_damage - (shield_facing_damage - absorbed))
	return {"shield_damage":shield_before - float(combat_state.get("enemy_shield", 0.0)), "hull_damage":hull_before - float(combat_state.get("enemy_hull", 0.0)), "shield_penetration":clampf(shield_penetration, 0.0, 1.0)}


func _apply_actor_damage(actor: Dictionary, damage: float, shield_penetration: float = 0.0) -> Dictionary:
	var shield_before := float(actor.get("shield", 0.0))
	var hull_before := float(actor.get("hull", 0.0))
	var bypass_damage := damage * clampf(shield_penetration, 0.0, 1.0)
	var shield_facing_damage := damage - bypass_damage
	var absorbed := minf(shield_before, shield_facing_damage)
	actor["shield"] = shield_before - absorbed
	actor["hull"] = maxf(0.0, hull_before - bypass_damage - (shield_facing_damage - absorbed))
	return {
		"shield_damage":maxf(0.0, shield_before - float(actor.get("shield", 0.0))),
		"hull_damage":maxf(0.0, hull_before - float(actor.get("hull", 0.0))),
		"shield_remaining":float(actor.get("shield", 0.0)),
		"hull_remaining":float(actor.get("hull", 0.0)),
		"disabled":float(actor.get("hull", 0.0)) <= 0.0,
		"recoverable":true,
		"shield_penetration":clampf(shield_penetration, 0.0, 1.0)
	}


func _weapon_defense_strength(actor: Dictionary, weapon_kind: String) -> float:
	var point_defense := clampf(float(actor.get("point_defense", 0.0)), 0.0, 0.9)
	var electronic_warfare := clampf(float(actor.get("electronic_warfare", 0.0)), 0.0, 0.9)
	match weapon_kind:
		"MISSILE":
			return clampf(point_defense * 0.75 + electronic_warfare * 0.25, 0.0, 0.8)
		"STRIKE_CRAFT":
			return clampf(point_defense * 0.35 + electronic_warfare * 0.65, 0.0, 0.8)
		"PENETRATION":
			return clampf(electronic_warfare * 0.35, 0.0, 0.4)
	return 0.0


func _retreat_policy_triggered(combat_state: Dictionary) -> bool:
	var policy: Dictionary = combat_state.get("retreat_policy", {})
	if str(policy.get("mode", "HULL_THRESHOLD")) == "NEVER":
		return false
	var maximum := maxf(1.0, float(combat_state.get("fleet_max_hull", 1.0)))
	var ratio := maxf(0.0, float(combat_state.get("fleet_hull", 0.0))) / maximum
	return ratio <= clampf(float(policy.get("threshold", 0.25)), 0.05, 0.95)


func _apply_enemy_status(combat_state: Dictionary, definition: Dictionary) -> void:
	var statuses: Dictionary = combat_state.get("enemy_statuses", {})
	_add_status(statuses, definition)
	combat_state["enemy_statuses"] = statuses


func _apply_actor_status(actor: Dictionary, definition: Dictionary) -> void:
	var statuses: Dictionary = actor.get("statuses", {})
	_add_status(statuses, definition)
	actor["statuses"] = statuses


func _add_status(statuses: Dictionary, definition: Dictionary) -> void:
	var status_id := str(definition.get("id", ""))
	if status_id.is_empty():
		return
	var current: Dictionary = statuses.get(status_id, definition.duplicate(true))
	current.merge(definition, true)
	current["stacks"] = mini(int(definition.get("max_stacks", 1)), int(statuses.get(status_id, {}).get("stacks", 0)) + int(definition.get("stacks", 1)))
	current["remaining_events"] = int(definition.get("duration_events", 1))
	statuses[status_id] = current


func _tick_actor_statuses(actor: Dictionary) -> void:
	var statuses: Dictionary = actor.get("statuses", {})
	_tick_statuses(statuses)
	actor["statuses"] = statuses


func _tick_status_dictionary(combat_state: Dictionary, key: String) -> void:
	var statuses: Dictionary = combat_state.get(key, {})
	_tick_statuses(statuses)
	combat_state[key] = statuses


func _tick_statuses(statuses: Dictionary) -> void:
	var expired: Array[String] = []
	for status_value in statuses.keys():
		var status_id := str(status_value)
		var status: Dictionary = statuses[status_id]
		status["remaining_events"] = int(status.get("remaining_events", 1)) - 1
		if int(status.remaining_events) <= 0:
			expired.append(status_id)
	for status_id in expired:
		statuses.erase(status_id)


func _status_sum(statuses: Dictionary, field: String) -> float:
	var total := 0.0
	for status in statuses.values():
		total += float(status.get(field, 0.0)) * float(status.get("stacks", 1))
	return total


func _status_cycle_interval_multiplier(statuses: Dictionary, cycle_kind: String) -> float:
	var modifier := _status_sum(statuses, "action_cycle_interval_multiplier_per_stack")
	if cycle_kind == "ATTACK":
		modifier += _status_sum(statuses, "attack_cycle_interval_multiplier_per_stack")
		modifier += _status_sum(statuses, "attack_interval_multiplier_per_stack")
	elif cycle_kind == "SKILL":
		modifier += _status_sum(statuses, "skill_cycle_interval_multiplier_per_stack")
	return maxf(0.1, 1.0 + modifier)


func _skill_cycle_ms(skill: Dictionary, attack_interval_ms: float) -> float:
	return maxf(1.0, float(skill.get("cycle_time_ms", maxf(1.0, attack_interval_ms) * 4.0)))


func _current_enemy_skills(combat_state: Dictionary) -> Array:
	var enemy: Dictionary = content.enemies.get(str(combat_state.get("enemy_id", "")), {})
	return _phase_definition(enemy, int(combat_state.get("phase_index", 0))).get("skills", [])


func _mitigated_damage(raw_damage: float, armor: float) -> float:
	# Flat subtraction was valid when the whole fleet attacked as one aggregate hit.
	# Per-ship attacks need a smooth curve so armor does not erase every light hit.
	return maxf(1.0, maxf(0.0, raw_damage) * 100.0 / (100.0 + maxf(0.0, armor)))


func _sync_fleet_summary(combat_state: Dictionary) -> void:
	var actors: Array = combat_state.get("actors", [])
	if actors.is_empty():
		return
	var maximum_hull := 0.0
	var maximum_shield := 0.0
	var hull := 0.0
	var shield := 0.0
	var damage := 0.0
	var armor := 0.0
	var accuracy := 0.0
	var evasion := 0.0
	var interval := INF
	var next_ms := INF
	var active := 0
	var combined_statuses := {}
	for actor in actors:
		maximum_hull += float(actor.get("max_hull", 0.0))
		maximum_shield += float(actor.get("max_shield", 0.0))
		hull += maxf(0.0, float(actor.get("hull", 0.0)))
		shield += maxf(0.0, float(actor.get("shield", 0.0)))
		if float(actor.get("hull", 0.0)) <= 0.0:
			continue
		damage += float(actor.get("damage", 0.0))
		armor += float(actor.get("armor", 0.0))
		accuracy += float(actor.get("accuracy", 0.0))
		evasion += float(actor.get("evasion", 0.0))
		interval = minf(interval, float(actor.get("attack_interval_ms", INF)))
		active += 1
		for status_id in actor.get("statuses", {}):
			combined_statuses[status_id] = actor.get("statuses", {})[status_id].duplicate(true)
	for cohort_value in combat_state.get("cohorts", []):
		var cohort := cohort_value as Dictionary
		if _living_cohort_member_indices(combat_state, cohort).is_empty():
			continue
		next_ms = minf(next_ms, float(cohort.get("attack_next_ms", INF)))
		if not cohort.get("skills", []).is_empty():
			next_ms = minf(next_ms, float(cohort.get("skill_next_ms", INF)))
		if not cohort.get("pending_trigger_actions", []).is_empty():
			next_ms = 0.0
	combat_state["fleet_max_hull"] = maximum_hull
	combat_state["fleet_max_shield"] = maximum_shield
	combat_state["fleet_hull"] = hull
	combat_state["fleet_shield"] = shield
	combat_state["fleet_damage"] = damage
	combat_state["fleet_armor"] = armor / float(active) if active > 0 else 0.0
	combat_state["fleet_accuracy"] = accuracy / float(active) if active > 0 else 0.0
	combat_state["fleet_evasion"] = evasion / float(active) if active > 0 else 0.0
	combat_state["fleet_attack_interval_ms"] = interval if interval != INF else 0.0
	combat_state["fleet_next_ms"] = next_ms
	combat_state["fleet_statuses"] = combined_statuses


func _migrate_legacy_state(state: SpaceGameState, combat_state: Dictionary) -> void:
	var actors: Array = combat_state.get("actors", [])
	if actors.is_empty():
		for ship_id in combat_state.get("ship_ids", []):
			var actor := _build_ship_actor(state, str(ship_id))
			if not actor.is_empty():
				actor["attack_next_ms"] = float(combat_state.get("fleet_next_ms", actor.get("attack_next_ms", 0.0)))
				actor["statuses"] = combat_state.get("fleet_statuses", {}).duplicate(true)
				actors.append(actor)
		combat_state["actors"] = actors
	else:
		for actor in actors:
			var ship := state.ship_by_id(str(actor.get("ship_id", "")))
			if ship.is_empty():
				continue
			var current_stats := _ship_stats(state, ship)
			var legacy_skills: Array = actor.get("skills", [])
			if int(combat_state.get("version", 0)) < COMBAT_STATE_VERSION or legacy_skills.any(func(skill): return not skill.has("cycle_time_ms")):
				actor["skills"] = current_stats.get("skills", []).duplicate(true)
			actor["attack_triggers"] = current_stats.get("attack_triggers", []).duplicate(true)
			actor["weapon_actions"] = current_stats.get("weapon_actions", []).duplicate(true)
			actor["pending_trigger_actions"] = actor.get("pending_trigger_actions", []).duplicate(true)
			actor["loadout_key"] = ",".join(state.ship_module_definition_ids(ship))
	if int(combat_state.get("version", 0)) < COMBAT_STATE_VERSION or combat_state.get("cohorts", []).is_empty():
		combat_state["cohorts"] = _build_cohorts(actors)
	_normalize_combat_state(combat_state)
	combat_state["version"] = COMBAT_STATE_VERSION
	_sync_fleet_summary(combat_state)


func _normalize_combat_state(combat_state: Dictionary) -> void:
	var prior_version := int(combat_state.get("version", 0))
	for actor in combat_state.get("actors", []):
		if not actor.has("attack_next_ms"):
			actor["attack_next_ms"] = float(actor.get("next_ms", actor.get("attack_interval_ms", 3000.0)))
		actor["skill_index"] = int(actor.get("skill_index", 0))
		var skills: Array = actor.get("skills", [])
		if not actor.has("skill_next_ms"):
			var current_skill: Dictionary = skills[int(actor.skill_index) % skills.size()] if not skills.is_empty() else {}
			actor["skill_next_ms"] = _skill_cycle_ms(current_skill, float(actor.get("attack_interval_ms", 3000.0))) if not current_skill.is_empty() else 0.0
		actor["attack_triggers"] = actor.get("attack_triggers", []).duplicate(true)
		actor["pending_trigger_actions"] = actor.get("pending_trigger_actions", []).duplicate(true)
		actor["skills_used"] = int(actor.get("skills_used", 0))
		actor["triggered_actions"] = int(actor.get("triggered_actions", 0))
		if str(actor.get("zone", "FRONT")) not in ZONE_ORDER:
			actor["zone"] = "FRONT"
		elif not actor.has("zone"):
			actor["zone"] = "FRONT"
		actor.erase("next_ms")
	if combat_state.get("cohorts", []).is_empty() and not combat_state.get("actors", []).is_empty():
		combat_state["cohorts"] = _build_cohorts(combat_state.get("actors", []))
	for cohort_value in combat_state.get("cohorts", []):
		var cohort := cohort_value as Dictionary
		cohort["member_indices"] = cohort.get("member_indices", []).duplicate()
		cohort["member_ship_ids"] = cohort.get("member_ship_ids", []).duplicate()
		cohort["skills"] = cohort.get("skills", []).duplicate(true)
		cohort["attack_triggers"] = cohort.get("attack_triggers", []).duplicate(true)
		cohort["pending_trigger_actions"] = cohort.get("pending_trigger_actions", []).duplicate(true)
		var weapon_cycles: Array = cohort.get("weapon_cycles", []).duplicate(true)
		if weapon_cycles.is_empty():
			weapon_cycles = _initialize_weapon_cycles([], cohort)
		else:
			for weapon_value in weapon_cycles:
				var weapon := weapon_value as Dictionary
				weapon["attack_interval_ms"] = maxf(1.0, float(weapon.get("attack_interval_ms", cohort.get("attack_interval_ms", 3000.0))))
				weapon["next_ms"] = maxf(0.0, float(weapon.get("next_ms", weapon.get("attack_interval_ms", 3000.0))))
				weapon["attacks"] = maxi(0, int(weapon.get("attacks", 0)))
		cohort["weapon_cycles"] = weapon_cycles
		_sync_cohort_attack_next(cohort)
		cohort["skill_index"] = int(cohort.get("skill_index", 0))
		var cohort_skills: Array = cohort.get("skills", [])
		if not cohort.has("skill_next_ms"):
			var current_skill: Dictionary = cohort_skills[int(cohort.skill_index) % cohort_skills.size()] if not cohort_skills.is_empty() else {}
			cohort["skill_next_ms"] = _skill_cycle_ms(current_skill, float(cohort.get("attack_interval_ms", 3000.0))) if not current_skill.is_empty() else 0.0
	combat_state["doctrine"] = str(combat_state.get("doctrine", "HOLD_FORMATION"))
	combat_state["retreat_policy"] = combat_state.get("retreat_policy", {"mode":"HULL_THRESHOLD", "threshold":0.25}).duplicate(true)
	combat_state["damage_target_locks"] = combat_state.get("damage_target_locks", {}).duplicate(true)
	if not combat_state.has("enemy_attack_next_ms"):
		combat_state["enemy_attack_next_ms"] = float(combat_state.get("enemy_next_ms", combat_state.get("enemy_attack_interval_ms", 2000.0)))
	var enemy_skills := _current_enemy_skills(combat_state)
	if not combat_state.has("enemy_skill_next_ms"):
		var current_enemy_skill: Dictionary = enemy_skills[int(combat_state.get("enemy_skill_index", 0)) % enemy_skills.size()] if not enemy_skills.is_empty() else {}
		combat_state["enemy_skill_next_ms"] = _skill_cycle_ms(current_enemy_skill, float(combat_state.get("enemy_attack_interval_ms", 2000.0))) if not current_enemy_skill.is_empty() else 0.0
	combat_state.erase("enemy_next_ms")
	if prior_version < COMBAT_STATE_VERSION:
		combat_state["version"] = COMBAT_STATE_VERSION


func _attack_event(source: String, skill_id: String, hit: bool, damage: float, combat_state: Dictionary) -> Dictionary:
	return {"type":"ATTACK", "source":source, "skill_id":skill_id, "hit":hit, "damage":damage, "phase_index":int(combat_state.get("phase_index", 0)), "phase_id":combat_state.get("phase_id", ""), "fleet_hull":maxf(0.0, float(combat_state.get("fleet_hull", 0.0))), "fleet_shield":maxf(0.0, float(combat_state.get("fleet_shield", 0.0))), "enemy_hull":maxf(0.0, float(combat_state.get("enemy_hull", 0.0))), "enemy_shield":maxf(0.0, float(combat_state.get("enemy_shield", 0.0)))}


func _append_log(combat_state: Dictionary, event: Dictionary) -> void:
	var log: Array = combat_state.get("log", [])
	log.append(event.duplicate(true))
	while log.size() > MAX_LOG_ENTRIES:
		log.pop_front()
	combat_state["log"] = log
