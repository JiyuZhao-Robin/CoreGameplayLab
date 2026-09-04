class_name ShipRegistrySelectionState
extends RefCounted

const HEADER_UNCHECKED := "unchecked"
const HEADER_CHECKED := "checked"
const HEADER_INDETERMINATE := "indeterminate"

var primary_ship_id := ""
var bulk_selected_ship_ids: Dictionary = {}


func set_primary(ship_id: String) -> void:
	primary_ship_id = ship_id


func set_bulk_selected(ship_id: String, selected: bool) -> void:
	if ship_id.is_empty():
		return
	if selected:
		bulk_selected_ship_ids[ship_id] = true
	else:
		bulk_selected_ship_ids.erase(ship_id)


func is_bulk_selected(ship_id: String) -> bool:
	return bool(bulk_selected_ship_ids.get(ship_id, false))


func clear_bulk() -> void:
	bulk_selected_ship_ids.clear()


func selected_ids_in_canonical_order(canonical_ids: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for ship_id in canonical_ids:
		if is_bulk_selected(ship_id):
			result.append(ship_id)
	return result


func reconcile(visible_ids: Array[String], canonical_ids: Array[String], prune_hidden: bool) -> void:
	var canonical_set := _id_set(canonical_ids)
	var visible_set := _id_set(visible_ids)
	for selected_id_value in bulk_selected_ship_ids.keys().duplicate():
		var selected_id := String(selected_id_value)
		if not canonical_set.has(selected_id) or (prune_hidden and not visible_set.has(selected_id)):
			bulk_selected_ship_ids.erase(selected_id)
	if not primary_ship_id.is_empty() and visible_set.has(primary_ship_id):
		return
	primary_ship_id = visible_ids[0] if not visible_ids.is_empty() else ""


func select_all_visible(visible_ids: Array[String]) -> void:
	for ship_id in visible_ids:
		if not ship_id.is_empty():
			bulk_selected_ship_ids[ship_id] = true


func deselect_all_visible(visible_ids: Array[String]) -> void:
	for ship_id in visible_ids:
		bulk_selected_ship_ids.erase(ship_id)


func header_state(visible_ids: Array[String]) -> String:
	if visible_ids.is_empty():
		return HEADER_UNCHECKED
	var selected_count := 0
	for ship_id in visible_ids:
		if is_bulk_selected(ship_id):
			selected_count += 1
	if selected_count == 0:
		return HEADER_UNCHECKED
	if selected_count == visible_ids.size():
		return HEADER_CHECKED
	return HEADER_INDETERMINATE


func _id_set(ids: Array[String]) -> Dictionary:
	var result := {}
	for ship_id in ids:
		if not ship_id.is_empty():
			result[ship_id] = true
	return result
