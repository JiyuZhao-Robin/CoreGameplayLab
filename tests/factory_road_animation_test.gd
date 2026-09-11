extends SceneTree

const CanvasScript = preload("res://src/ui/workspaces/factory/factory_canvas.gd")
const ItemArt = preload("res://src/ui/workspaces/location/location_item_icon.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var canvas = CanvasScript.new()
	canvas.size = Vector2(800,500)
	root.add_child(canvas)
	var snapshot := {"protocol_version":1,"valid":true,"world_id":"animation-test","elapsed_ms":1000.0,"runtime_revision":1,"topology_revision":1,"bounds":{"origin":{"x":0,"y":0},"size":{"x":900,"y":600}},"logistics_mode":"PLANET_SHARED_ROADS","chunk_size_tiles":64,"entities":[],"roads":[],"links":[],"palette":{"buildings":[],"recipes":[]},"road_shipments":[_job("near",["20,10","21,10","22,10"],0.2),_job("far",["800,500","801,500"],0.2)]}
	canvas.apply_snapshot(snapshot)
	canvas.set_road_logistics_mode(true)
	canvas.set("_overview_mode",false)
	canvas.set("_zoom",1.0)
	canvas.focus_tile(Vector2i(50,25))
	var next := snapshot.duplicate(true)
	next["road_shipments"][0]["path_progress"] = 0.8
	next["elapsed_ms"] = 2000.0
	canvas.apply_snapshot(next)
	canvas.set("_shipment_blend_elapsed",0.125)
	var row: Dictionary = next["road_shipments"][0]
	_check(is_equal_approx(float(canvas.call("_cargo_draw_progress",row)),0.5),"cargo interpolates between observed snapshots, not an invented looping route")
	canvas.set("_shipment_blend_elapsed",100.0)
	_check(is_equal_approx(float(canvas.call("_cargo_draw_progress",row)),0.8),"stale snapshots never extrapolate cargo beyond its authoritative progress")
	var visible: Array = canvas.call("_visible_shipment_ids")
	_check(visible.has("near") and not visible.has("far"),"cargo path chunk index excludes entirely offscreen tasks")
	canvas.set("_runtime_snapshot_age",0.1)
	_check(not is_equal_approx(float(canvas.call("_building_activity_brightness",{"status":"RUNNING","actual_rate":1.0})),1.0),"a genuinely running building has a material brightness pulse")
	_check(is_equal_approx(float(canvas.call("_building_activity_brightness",{"status":"OUTPUT_FULL","actual_rate":0.0})),1.0),"full-buffer stopped buildings do not pretend to produce")
	canvas.set_reduced_motion(true)
	_check(not bool(canvas.call("_road_feedback_animation_allowed")) and is_equal_approx(float(canvas.call("_cargo_draw_progress",row)),0.8),"Reduced Motion keeps current cargo position without interpolation")
	canvas.set_reduced_motion(false)
	canvas.set("_overview_mode",true)
	_check(bool(canvas.call("_road_feedback_animation_allowed")),"bounded local reset view retains animation within the visible-record budget")
	canvas.set("_overview_mode",false)
	canvas.set("_zoom",0.1)
	_check(not bool(canvas.call("_road_feedback_animation_allowed")),"subtile LOD disables animated feedback")
	canvas.set("_zoom",1.0)
	canvas.set("_visible_records",{"entity_ids":range(10000)})
	_check(not bool(canvas.call("_road_feedback_animation_allowed")),"large visible record counts respect the animation budget")
	canvas.set("_visible_records",{})
	next = next.duplicate(true)
	next["road_shipments"][0]["phase"] = "BLOCKED"
	next["road_shipments"][0]["status"] = "BLOCKED_PATH"
	canvas.apply_snapshot(next)
	canvas.set("_shipment_blend_elapsed",0.0)
	_check(is_equal_approx(float(canvas.call("_cargo_draw_progress",next["road_shipments"][0])),0.8),"blocked cargo stays fixed instead of continuing to animate")
	next = next.duplicate(true)
	next["road_shipments"] = []
	canvas.apply_snapshot(next)
	_check((canvas.call("_visible_shipment_ids") as Array).is_empty(),"completed task removal clears its cargo icon and chunk index")
	_check(ItemArt.texture_for_item("iron_ore") is Texture2D,"cargo feedback uses the generated material texture")
	canvas.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("FACTORY_ROAD_ANIMATION_PASS" if failures.is_empty() else "FACTORY_ROAD_ANIMATION_FAIL")
	quit(0 if failures.is_empty() else 1)


func _job(id: String, path: Array, progress: float) -> Dictionary:
	return {"id":id,"item_id":"iron_ore","quantity":1,"phase":"TRAVEL","status":"IN_TRANSIT","travel_progress":progress,"path_progress":progress,"path_tiles":path}


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)
