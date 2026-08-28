extends SceneTree

const MAIN_PATH := "res://src/ui/main.gd"


func _init() -> void:
	var source := FileAccess.get_file_as_string(MAIN_PATH)
	var process_body := _function_body(source, "_process")
	var active_rebuild_body := _function_body(source, "_rebuild_active_page")
	var failures: Array[String] = []
	_expect(not process_body.is_empty(), "Main UI defines an explicit refresh scheduler", failures)
	_expect("_dirty" in process_body and "_last_refresh_ms" in process_body, "UI refreshes are dirty/coalesced instead of unconditional per-frame rebuilds", failures)
	_expect("_rebuild_active_page" in process_body and "_rebuild_all" not in process_body, "A simulation event rebuilds only the active workspace", failures)
	_expect("match _active_page_key" in active_rebuild_body, "Active workspace refresh is selected by the current page", failures)
	_expect("_rebuild_inventory" in active_rebuild_body and "_rebuild_logistics" in active_rebuild_body, "Inventory and Logistics participate in the active-only refresh contract", failures)
	_expect("_rebuild_all()" not in active_rebuild_body, "Active refresh never recursively requests a full hidden-screen rebuild", failures)
	if failures.is_empty():
		print("PASS: UI refresh scheduler is dirty, coalesced and active-workspace-only")
		quit(0)
	else:
		for failure in failures:
			push_error("FAIL: " + failure)
		quit(1)


func _function_body(source: String, function_name: String) -> String:
	var marker := "func %s(" % function_name
	var start := source.find(marker)
	if start < 0:
		return ""
	var next := source.find("\nfunc ", start + marker.length())
	return source.substr(start, source.length() - start) if next < 0 else source.substr(start, next - start)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append(message)
