extends Node

var failures: Array[String] = []


func _ready() -> void:
	Game.persistence_enabled = false
	Game.set_process(false)
	Game.state = SpaceGameState.create_new(Game.content.domains.keys(), Game.content.regions)
	Game.simulation = SimulationEngine.new(Game.content)
	Game.simulation.ensure_frontier_state(Game.state)
	Game._simulation_accumulator_ms = 0.0
	Game._autosave_accumulator_ms = 0.0
	Game._process(1000.0)
	var first_elapsed := float(Game.state.total_elapsed_ms)
	var first_debt := float(Game._simulation_accumulator_ms)
	Game._process(0.0)
	_check(is_equal_approx(first_elapsed, 15000.0) and is_equal_approx(float(Game.state.total_elapsed_ms), 30000.0), "online simulation processes at most one bounded deterministic window per rendered frame")
	_check(first_debt > 900000.0 and float(Game._simulation_accumulator_ms) < first_debt, "online simulation retains excess elapsed time as debt and consumes it on later frames without loss")
	_finish()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append(message)
		push_error("FAIL: " + message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: online frame simulation budget")
		get_tree().quit(0)
	else:
		get_tree().quit(1)
