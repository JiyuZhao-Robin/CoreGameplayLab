class_name ShipRegistryQuery
extends RefCounted

## Read-only STEP 09 projection for the Ship Registry. The canonical ship Array
## remains owned by GameState; this helper only derives an ordered visible view.

const ALL_SHIP_TYPES := ""
const ALL_FORMATIONS := ""
const UNASSIGNED_FORMATION := "__UNASSIGNED__"

const SORT_CANONICAL := "CANONICAL"
const SORT_NAME_ASCENDING := "NAME_ASCENDING"
const SORT_NAME_DESCENDING := "NAME_DESCENDING"
const SORT_TYPE_THEN_NAME := "TYPE_THEN_NAME"
const SORT_FORMATION_THEN_NAME := "FORMATION_THEN_NAME"
const SORT_MODES := [
	SORT_CANONICAL,
	SORT_NAME_ASCENDING,
	SORT_NAME_DESCENDING,
	SORT_TYPE_THEN_NAME,
	SORT_FORMATION_THEN_NAME
]


static func derive(
		canonical_ships: Array,
		lifecycle_filter: String,
		search_query: String,
		ship_type_filter: String,
		formation_filter: String,
		sort_mode: String,
		ship_definitions: Dictionary,
		formation_for_ship: Callable
	) -> Array:
	var normalized_query := search_query.strip_edges().to_lower()
	var normalized_type := normalize_type_id(ship_type_filter)
	var result: Array = []
	for ship_value in canonical_ships:
		var ship := ship_value as Dictionary
		if lifecycle_filter != "ALL" and String(ship.get("maintenance_state", "ACTIVE")) != lifecycle_filter:
			continue
		if not _matches_search(ship, normalized_query):
			continue
		var definition := ship_definitions.get(String(ship.get("blueprint_id", "")), {}) as Dictionary
		if not normalized_type.is_empty() and normalize_type_id(String(definition.get("class", ""))) != normalized_type:
			continue
		var formation_id := _formation_id(ship, formation_for_ship)
		if formation_filter == UNASSIGNED_FORMATION:
			if not formation_id.is_empty():
				continue
		elif not formation_filter.is_empty() and formation_id != formation_filter:
			continue
		result.append(ship)
	if sort_mode in SORT_MODES and sort_mode != SORT_CANONICAL:
		result.sort_custom(_less.bind(sort_mode, ship_definitions, formation_for_ship))
	return result


static func ship_type_ids(canonical_ships: Array, ship_definitions: Dictionary) -> Array[String]:
	var seen := {}
	for ship_value in canonical_ships:
		var ship := ship_value as Dictionary
		var definition := ship_definitions.get(String(ship.get("blueprint_id", "")), {}) as Dictionary
		var type_id := normalize_type_id(String(definition.get("class", "")))
		if not type_id.is_empty():
			seen[type_id] = true
	var result: Array[String] = []
	for type_id_value in seen.keys():
		result.append(String(type_id_value))
	result.sort_custom(func(left: String, right: String): return left.naturalnocasecmp_to(right) < 0)
	return result


static func normalize_type_id(type_id: String) -> String:
	return type_id.strip_edges().to_upper()


static func _matches_search(ship: Dictionary, normalized_query: String) -> bool:
	if normalized_query.is_empty():
		return true
	var candidates := [
		String(ship.get("name", "")),
		String(ship.get("instance_id", ""))
	]
	# registry_code is an optional canonical instance field. The current base
	# save does not define it, so an absent field contributes no placeholder or
	# UI alias to search.
	if ship.has("registry_code"):
		candidates.append(String(ship.get("registry_code", "")))
	for candidate_value in candidates:
		var candidate := String(candidate_value)
		if not candidate.is_empty() and candidate.to_lower().contains(normalized_query):
			return true
	return false


static func _formation_id(ship: Dictionary, formation_for_ship: Callable) -> String:
	if not formation_for_ship.is_valid():
		return ""
	return String(formation_for_ship.call(String(ship.get("instance_id", ""))))


static func _less(
		left_value,
		right_value,
		sort_mode: String,
		ship_definitions: Dictionary,
		formation_for_ship: Callable
	) -> bool:
	var left := left_value as Dictionary
	var right := right_value as Dictionary
	var comparison := 0
	match sort_mode:
		SORT_NAME_ASCENDING:
			comparison = _compare_optional(String(left.get("name", "")), String(right.get("name", "")))
		SORT_NAME_DESCENDING:
			comparison = _compare_optional_descending(String(left.get("name", "")), String(right.get("name", "")))
		SORT_TYPE_THEN_NAME:
			comparison = _compare_optional(_ship_type_id(left, ship_definitions), _ship_type_id(right, ship_definitions))
			if comparison == 0:
				comparison = _compare_optional(String(left.get("name", "")), String(right.get("name", "")))
		SORT_FORMATION_THEN_NAME:
			comparison = _compare_optional(_formation_id(left, formation_for_ship), _formation_id(right, formation_for_ship))
			if comparison == 0:
				comparison = _compare_optional(String(left.get("name", "")), String(right.get("name", "")))
	if comparison == 0:
		comparison = String(left.get("instance_id", "")).naturalnocasecmp_to(String(right.get("instance_id", "")))
	return comparison < 0


static func _ship_type_id(ship: Dictionary, ship_definitions: Dictionary) -> String:
	var definition := ship_definitions.get(String(ship.get("blueprint_id", "")), {}) as Dictionary
	return normalize_type_id(String(definition.get("class", "")))


static func _compare_optional(left: String, right: String) -> int:
	# Missing canonical values always follow present values. This deliberately
	# never compares the localized em-dash presentation fallback.
	if left.is_empty() != right.is_empty():
		return 1 if left.is_empty() else -1
	return left.naturalnocasecmp_to(right)


static func _compare_optional_descending(left: String, right: String) -> int:
	if left.is_empty() != right.is_empty():
		return 1 if left.is_empty() else -1
	return -left.naturalnocasecmp_to(right)
