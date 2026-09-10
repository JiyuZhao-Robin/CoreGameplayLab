extends SceneTree

const Trend = preload("res://src/application/location_inventory_trend.gd")
var failures: Array[String] = []


func _initialize() -> void:
	var tracker = Trend.new()
	var first: Dictionary = tracker.sample("earth", 0.0, {"iron":10, "copper":20})
	_check(not first["iron"]["trend_known"], "initial stock is not fabricated surplus")
	var paused: Dictionary = tracker.sample("earth", 0.0, {"iron":50, "copper":20})
	_check(not paused["iron"]["trend_known"], "same-time UI redraw does not create a sample")
	var changed: Dictionary = tracker.sample("earth", 1000.0, {"iron":12, "copper":19})
	_check(is_equal_approx(changed["iron"]["net_rate_per_minute"], 120.0) and is_equal_approx(changed["copper"]["net_rate_per_minute"], -60.0), "opposite arrows derive from exact simulation-time stock changes")
	var other: Dictionary = tracker.sample("moon", 1000.0, {"iron":500})
	_check(not other["iron"]["trend_known"], "locations never share trend baselines")
	tracker.sample("earth", 31_000.0, {"iron":12, "copper":19})
	var settled: Dictionary = tracker.sample("earth", 61_000.0, {"iron":12, "copper":19})
	_check(settled["iron"]["trend_known"] and is_zero_approx(settled["iron"]["net_rate_per_minute"]), "old gains age out and stable stock returns to neutral")
	var rewound: Dictionary = tracker.sample("earth", 0.0, {"iron":5})
	_check(not rewound["iron"]["trend_known"], "rewound simulation clock resets the baseline")
	tracker.reset()
	_check(not tracker.sample("moon", 5000.0, {"iron":999})["iron"]["trend_known"], "new-game reset clears previous organization trends")
	for failure in failures:
		push_error(failure)
	print("LOCATION_INVENTORY_TREND_PASS" if failures.is_empty() else "LOCATION_INVENTORY_TREND_FAIL")
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
