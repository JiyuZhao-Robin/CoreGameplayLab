class_name CombatResolver
extends RefCounted

const MAX_COMBAT_EVENTS := 10000
const MAX_LOG_ENTRIES := 48
const COMBAT_STATE_VERSION := 3

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
	var combat_state := {
		"version":COMBAT_STATE_VERSION,
		"status":"RUNNING", "victory":false, "reason":"", "enemy_id":enemy_id,
		"ship_ids":ship_ids.duplicate(), "actors":actors, "phase_index":0,
		"phase_count":maxi(1, enemy.get("phases", []).size()), "phase_id":"", "phase_name":"",
		"enemy_statuses":{}, "enemy_skill_index":0, "elapsed_ms":0.0, "events":0, "log":[]
	}
	_load_phase(combat_state, enemy, 0)
	_sync_fleet_summary(combat_state)
	_append_log(combat_state, {"type":"COMBAT_STARTED", "enemy_id":enemy_id, "phase_id":combat_state.get("phase_id", ""), "actor_count":actors.size()})
	return combat_state


func advance_clock(combat_state: Dictionary, elapsed_ms: float) -> void:
	if str(combat_state.get("status", "")) != "RUNNING":
		return
	_normalize_combat_state(combat_state)
	var step := maxf(0.0, elapsed_ms)
	var actors: Array = combat_state.get("actors", [])
	for actor in actors:
		if float(actor.get("hull", 0.0)) <= 0.0:
			continue
		actor["attack_next_ms"] = maxf(0.0, float(actor.get("attack_next_ms", 0.0)) - step)
		if not actor.get("skills", []).is_empty():
			actor["skill_next_ms"] = maxf(0.0, float(actor.get("skill_next_ms", 0.0)) - step)
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
	var actor_index := int(action.get("actor_index", -1))
	var event: Dictionary
	match str(action.get("kind", "")):
		"SHIP_TRIGGER":
			event = _ship_trigger_action(state, combat_state, actor_index)
		"SHIP_SKILL":
			event = _ship_skill_cycle(state, combat_state, actor_index)
		"SHIP_ATTACK":
			event = _ship_attack_cycle(state, combat_state, actor_index)
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
	return {
		"victory":victory, "reason":str(combat_state.get("reason", "ENEMY_DEFEATED" if victory else "FLEET_DISABLED")),
		"duration_ms":float(combat_state.get("elapsed_ms", 0.0)), "damage_taken":total_damage,
		"fleet_hull_remaining":maxf(0.0, float(combat_state.get("fleet_hull", 0.0))), "fleet_shield_remaining":maxf(0.0, float(combat_state.get("fleet_shield", 0.0))),
		"enemy_hull_remaining":maxf(0.0, float(combat_state.get("enemy_hull", 0.0))), "enemy_shield_remaining":maxf(0.0, float(combat_state.get("enemy_shield", 0.0))),
		"phase_index":int(combat_state.get("phase_index", 0)), "phase_count":int(combat_state.get("phase_count", 1)),
		"events":int(combat_state.get("events", 0)), "ship_results":ship_results, "log":combat_state.get("log", []).duplicate(true)
	}


func resolve(state: SpaceGameState, ship_ids: Array, enemy_id: String) -> Dictionary:
	var combat_state := begin(state, ship_ids, enemy_id)
	while str(combat_state.get("status", "")) == "RUNNING" and int(combat_state.get("events", 0)) < MAX_COMBAT_EVENTS:
		advance_clock(combat_state, next_event_ms(combat_state))
		settle_next_event(state, combat_state)
	return result(combat_state)


func fleet_stats(state: SpaceGameState, ship_ids: Array) -> Dictionary:
	var stats := {"hull":0.0, "shield":0.0, "armor":0.0, "damage":0.0, "attack_interval_ms":INF, "accuracy":0.0, "evasion":0.0, "skills":[], "attack_triggers":[], "ship_count":0}
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
	var stats := {"hull":float(base.get("hull", 0.0)), "shield":float(base.get("shield", 0.0)), "armor":float(base.get("armor", 0.0)), "damage":float(base.get("damage", 0.0)), "attack_interval_ms":float(base.get("attack_interval_ms", 3000.0)), "accuracy":float(base.get("accuracy", 0.5)), "evasion":float(base.get("evasion", 0.0)), "skills":blueprint.get("combat_skills", []).duplicate(true), "attack_triggers":blueprint.get("attack_triggers", []).duplicate(true), "ammunition_item":"", "ammunition_per_attack":0}
	for module_id in state.ship_module_definition_ids(ship):
		var module: Dictionary = content.modules.get(str(module_id), {})
		var module_stats: Dictionary = module.get("combat_stats", {})
		for stat in ["hull", "shield", "armor", "damage", "accuracy", "evasion"]:
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
	return stats


func _build_ship_actor(state: SpaceGameState, ship_id: String) -> Dictionary:
	var ship := state.ship_by_id(ship_id)
	if ship.is_empty() or ship.get("condition", "") != "OPERATIONAL":
		return {}
	var blueprint: Dictionary = content.ships.get(str(ship.get("blueprint_id", "")), {})
	var stats := _ship_stats(state, ship)
	var current_shield := float(stats.shield)
	var current_hull := float(stats.hull)
	var prior_damage := maxf(0.0, float(ship.get("damage_taken", 0.0)))
	var shield_damage := minf(current_shield, prior_damage)
	current_shield -= shield_damage
	current_hull = maxf(0.0, current_hull - maxf(0.0, prior_damage - shield_damage))
	return {
		"id":str(ship.get("blueprint_id", "")), "ship_id":ship_id, "blueprint_id":str(ship.get("blueprint_id", "")), "name":str(blueprint.get("name", ship_id)), "instance_name":str(ship.get("name", ship_id)), "class":str(blueprint.get("class", "Ship")),
		"max_hull":float(stats.hull), "max_shield":float(stats.shield), "starting_hull":current_hull, "starting_shield":current_shield,
		"hull":current_hull, "shield":current_shield, "armor":float(stats.armor), "damage":float(stats.damage), "accuracy":float(stats.accuracy), "evasion":float(stats.evasion),
		"attack_interval_ms":float(stats.attack_interval_ms), "attack_next_ms":float(stats.attack_interval_ms),
		"ammunition_item":str(stats.get("ammunition_item", "")), "ammunition_per_attack":int(stats.get("ammunition_per_attack", 0)),
		"statuses":{}, "skills":stats.skills.duplicate(true), "skill_index":0,
		"skill_next_ms":_skill_cycle_ms(stats.skills[0], float(stats.attack_interval_ms)) if not stats.skills.is_empty() else 0.0,
		"attack_triggers":stats.attack_triggers.duplicate(true), "pending_trigger_actions":[],
		"attacks":0, "skills_used":0, "triggered_actions":0, "damage_dealt":0.0
	}


func _ship_attack_cycle(state: SpaceGameState, combat_state: Dictionary, actor_index: int) -> Dictionary:
	var actors: Array = combat_state.get("actors", [])
	var actor: Dictionary = actors[actor_index]
	var ammunition_item := str(actor.get("ammunition_item", ""))
	var ammunition_per_attack := int(actor.get("ammunition_per_attack", 0))
	if not ammunition_item.is_empty() and ammunition_per_attack > 0 and not state.consume_fleet_supply(ammunition_item, ammunition_per_attack):
		actor["attack_next_ms"] = float(actor.get("attack_interval_ms", 3000.0))
		combat_state["status"] = "WITHDRAWN"
		combat_state["victory"] = false
		combat_state["reason"] = "AMMUNITION_DEPLETED"
		return {"type":"SUPPLY_DEPLETED", "source":"SHIP", "ship_id":str(actor.get("ship_id", "")), "item_id":ammunition_item, "action_kind":"BASIC_ATTACK", "cycle_kind":"ATTACK", "combat_ended":true}
	var action := {"id":"ship_attack", "name":"Attack", "damage_multiplier":1.0}
	var event := _resolve_ship_action(state, combat_state, actor_index, action, "BASIC_ATTACK")
	actor["attacks"] = int(actor.get("attacks", 0)) + 1
	var queued_ids: Array[String] = []
	for trigger in actor.get("attack_triggers", []):
		var every_attacks := int(trigger.get("every_attacks", 0))
		if every_attacks > 0 and int(actor.get("attacks", 0)) % every_attacks == 0:
			var pending: Array = actor.get("pending_trigger_actions", [])
			pending.append(trigger.duplicate(true))
			actor["pending_trigger_actions"] = pending
			queued_ids.append(str(trigger.get("id", "")))
	if not queued_ids.is_empty():
		event["queued_trigger_ids"] = queued_ids
	actor["attack_next_ms"] = float(actor.get("attack_interval_ms", 3000.0)) * _status_cycle_interval_multiplier(actor.get("statuses", {}), "ATTACK")
	return event


func _ship_skill_cycle(state: SpaceGameState, combat_state: Dictionary, actor_index: int) -> Dictionary:
	var actor: Dictionary = combat_state.get("actors", [])[actor_index]
	var skills: Array = actor.get("skills", [])
	if skills.is_empty():
		return {}
	var skill_index := int(actor.get("skill_index", 0)) % skills.size()
	var skill: Dictionary = skills[skill_index]
	var event := _resolve_ship_action(state, combat_state, actor_index, skill, "SKILL")
	actor["skills_used"] = int(actor.get("skills_used", 0)) + 1
	actor["skill_index"] = skill_index + 1
	var next_skill: Dictionary = skills[int(actor.skill_index) % skills.size()]
	actor["skill_next_ms"] = _skill_cycle_ms(next_skill, float(actor.get("attack_interval_ms", 3000.0))) * _status_cycle_interval_multiplier(actor.get("statuses", {}), "SKILL")
	return event


func _ship_trigger_action(state: SpaceGameState, combat_state: Dictionary, actor_index: int) -> Dictionary:
	var actor: Dictionary = combat_state.get("actors", [])[actor_index]
	var pending: Array = actor.get("pending_trigger_actions", [])
	if pending.is_empty():
		return {}
	var trigger: Dictionary = pending.pop_front()
	actor["pending_trigger_actions"] = pending
	var event := _resolve_ship_action(state, combat_state, actor_index, trigger, "ATTACK_TRIGGER")
	actor["triggered_actions"] = int(actor.get("triggered_actions", 0)) + 1
	return event


func _resolve_ship_action(state: SpaceGameState, combat_state: Dictionary, actor_index: int, action: Dictionary, action_kind: String) -> Dictionary:
	var actors: Array = combat_state.get("actors", [])
	var actor: Dictionary = actors[actor_index]
	var enemy: Dictionary = content.enemies.get(str(combat_state.get("enemy_id", "")), {})
	var accuracy := float(actor.get("accuracy", 0.5)) + float(action.get("accuracy_bonus", 0.0)) + _status_sum(actor.get("statuses", {}), "accuracy_modifier_per_stack")
	var chance := clampf(accuracy - float(combat_state.get("enemy_evasion", 0.0)) + 0.5, 0.05, 0.95)
	var hit := rng.next_float(state, "combat.hit.%s" % actor.get("ship_id", actor_index)) <= chance
	var damage := 0.0
	if hit:
		damage = _mitigated_damage(float(actor.get("damage", 0.0)) * float(action.get("damage_multiplier", 1.0)), float(combat_state.get("enemy_armor", 0.0)))
		damage *= 1.0 + _status_sum(combat_state.get("enemy_statuses", {}), "damage_taken_multiplier_per_stack")
		_apply_enemy_damage(combat_state, damage)
	actor["damage_dealt"] = float(actor.get("damage_dealt", 0.0)) + damage
	_tick_status_dictionary(combat_state, "enemy_statuses")
	if action.has("apply_status"):
		_apply_enemy_status(combat_state, action.get("apply_status", {}))
	var event := _attack_event("SHIP", str(action.get("id", "ship_attack")), hit, damage, combat_state)
	event["action_kind"] = action_kind
	event["cycle_kind"] = "ATTACK" if action_kind == "BASIC_ATTACK" else ("SKILL" if action_kind == "SKILL" else "TRIGGER")
	event["ship_id"] = str(actor.get("ship_id", ""))
	event["actor_index"] = actor_index
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
	for actor_index in target_indices:
		var actor: Dictionary = combat_state.get("actors", [])[actor_index]
		target_ids.append(str(actor.get("ship_id", "")))
		var accuracy := float(combat_state.get("enemy_accuracy", 0.5)) + float(skill.get("accuracy_bonus", 0.0)) + _status_sum(combat_state.get("enemy_statuses", {}), "accuracy_modifier_per_stack")
		var chance := clampf(accuracy - float(actor.get("evasion", 0.0)) + 0.5, 0.05, 0.95)
		var hit := rng.next_float(state, "combat.enemy_hit.%s" % actor.get("ship_id", actor_index)) <= chance
		if hit:
			var damage := _mitigated_damage(float(combat_state.get("enemy_damage", 1.0)) * float(skill.get("damage_multiplier", 1.0)), float(actor.get("armor", 0.0)))
			damage *= 1.0 + _status_sum(actor.get("statuses", {}), "damage_taken_multiplier_per_stack")
			_apply_actor_damage(actor, damage)
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
	event["shield_restored"] = restored
	if _living_actor_indices(combat_state).is_empty():
		combat_state["status"] = "DEFEAT"
		combat_state["victory"] = false
		combat_state["reason"] = "FLEET_DISABLED"
		event["combat_ended"] = true
	return event


func _enemy_target_indices(state: SpaceGameState, combat_state: Dictionary, skill: Dictionary) -> Array[int]:
	var living := _living_actor_indices(combat_state)
	if living.is_empty():
		return []
	if str(skill.get("target_mode", "SINGLE")) in ["ALL", "ALL_SHIPS"]:
		return living
	return [living[rng.next_int(state, "combat.enemy_target", 0, living.size() - 1)]]


func _living_actor_indices(combat_state: Dictionary) -> Array[int]:
	var result: Array[int] = []
	var actors: Array = combat_state.get("actors", [])
	for index in range(actors.size()):
		if float(actors[index].get("hull", 0.0)) > 0.0:
			result.append(index)
	return result


func _next_action_candidate(combat_state: Dictionary) -> Dictionary:
	var best := {"kind":"", "actor_index":-1, "remaining_ms":INF, "priority":999, "order":999999}
	var actors: Array = combat_state.get("actors", [])
	for index in range(actors.size()):
		var actor: Dictionary = actors[index]
		if float(actor.get("hull", 0.0)) <= 0.0:
			continue
		if not actor.get("pending_trigger_actions", []).is_empty():
			best = _prefer_action(best, "SHIP_TRIGGER", index, 0.0, 0, index)
		if not actor.get("skills", []).is_empty():
			best = _prefer_action(best, "SHIP_SKILL", index, float(actor.get("skill_next_ms", INF)), 1, index)
		best = _prefer_action(best, "SHIP_ATTACK", index, float(actor.get("attack_next_ms", INF)), 2, index)
	if not _current_enemy_skills(combat_state).is_empty():
		best = _prefer_action(best, "ENEMY_SKILL", -1, float(combat_state.get("enemy_skill_next_ms", INF)), 1, actors.size())
	best = _prefer_action(best, "ENEMY_ATTACK", -1, float(combat_state.get("enemy_attack_next_ms", INF)), 2, actors.size())
	return best


func _prefer_action(current: Dictionary, kind: String, actor_index: int, remaining_ms: float, priority: int, order: int) -> Dictionary:
	var current_time := float(current.get("remaining_ms", INF))
	if remaining_ms < current_time - 0.0001:
		return {"kind":kind, "actor_index":actor_index, "remaining_ms":remaining_ms, "priority":priority, "order":order}
	if absf(remaining_ms - current_time) <= 0.0001:
		if priority < int(current.get("priority", 999)) or (priority == int(current.get("priority", 999)) and order < int(current.get("order", 999999))):
			return {"kind":kind, "actor_index":actor_index, "remaining_ms":remaining_ms, "priority":priority, "order":order}
	return current


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


func _apply_enemy_damage(combat_state: Dictionary, damage: float) -> void:
	var absorbed := minf(float(combat_state.get("enemy_shield", 0.0)), damage)
	combat_state["enemy_shield"] = float(combat_state.get("enemy_shield", 0.0)) - absorbed
	combat_state["enemy_hull"] = float(combat_state.get("enemy_hull", 0.0)) - (damage - absorbed)


func _apply_actor_damage(actor: Dictionary, damage: float) -> void:
	var absorbed := minf(float(actor.get("shield", 0.0)), damage)
	actor["shield"] = float(actor.get("shield", 0.0)) - absorbed
	actor["hull"] = maxf(0.0, float(actor.get("hull", 0.0)) - (damage - absorbed))


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
		next_ms = minf(next_ms, float(actor.get("attack_next_ms", INF)))
		if not actor.get("skills", []).is_empty():
			next_ms = minf(next_ms, float(actor.get("skill_next_ms", INF)))
		if not actor.get("pending_trigger_actions", []).is_empty():
			next_ms = 0.0
		active += 1
		for status_id in actor.get("statuses", {}):
			combined_statuses[status_id] = actor.get("statuses", {})[status_id].duplicate(true)
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
			actor["pending_trigger_actions"] = actor.get("pending_trigger_actions", []).duplicate(true)
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
		actor.erase("next_ms")
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
