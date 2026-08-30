extends SceneTree

const MAIN_PATH := "res://src/ui/main.gd"


func _init() -> void:
	var source := FileAccess.get_file_as_string(MAIN_PATH)
	var process_body := _function_body(source, "_process")
	var command_body := _function_body(source, "_command")
	var state_changed_body := _function_body(source, "_on_state_changed")
	var active_rebuild_body := _function_body(source, "_rebuild_active_page")
	var failures: Array[String] = []
	_expect(not process_body.is_empty(), "Main UI defines an explicit refresh scheduler", failures)
	_expect("_dirty" in process_body and "_last_refresh_ms" in process_body, "UI refreshes are dirty/coalesced instead of unconditional per-frame rebuilds", failures)
	_expect("_rebuild_active_page" in process_body and "_rebuild_all" not in process_body, "A simulation event rebuilds only the active workspace", failures)
	_expect("_tabs.get_current_tab_control()" in active_rebuild_body and "match key:" in active_rebuild_body, "Active workspace refresh is selected by the current page", failures)
	_expect("_rebuild_inventory" in active_rebuild_body and "_rebuild_logistics" in active_rebuild_body, "Inventory and Logistics participate in the active-only refresh contract", failures)
	_expect("_rebuild_all()" not in active_rebuild_body, "Active refresh never recursively requests a full hidden-screen rebuild", failures)
	_expect("SIMULATION_REFRESH_INTERVAL_MS" in source, "Long-running simulation refreshes use an explicit low-churn interval", failures)
	_expect("_immediate_refresh_requested" in process_body, "Player interactions can bypass the simulation refresh interval on the next frame", failures)
	_expect("_request_active_page_refresh(true)" in command_body, "Domain commands request a prompt deferred UI refresh", failures)
	_expect("_request_active_page_refresh(false)" in state_changed_body, "Simulation ticks remain dirty/coalesced instead of forcing a tree rebuild", failures)
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
