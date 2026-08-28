extends Node

const REGISTRY_PATH := "res://data/gameplay_journey_registry.json"
const REQUIRED_IDS := [
	"JOURNEY_01_EARLY_INDUSTRY",
	"JOURNEY_02_CAPITAL_EXPANSION",
	"JOURNEY_03_LOGISTICS_BOTTLENECK",
	"JOURNEY_04_BOTTLENECK_SHIFT",
	"JOURNEY_05_RESEARCH_PROGRAM",
	"JOURNEY_06_SHIP_INDUSTRY",
	"JOURNEY_07_SURVEY",
	"JOURNEY_08_REMOTE_INDUSTRY",
	"JOURNEY_09_ADVANCED_INDUSTRY",
	"JOURNEY_10_MEGASTRUCTURE"
]


func _ready() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY_PATH))
	if parsed is not Dictionary:
		_fail("Gameplay Journey registry must be valid JSON object")
		return
	var document := parsed as Dictionary
	var journeys: Array = document.get("journeys", [])
	var ids: Array[String] = []
	for journey_value in journeys:
		if journey_value is not Dictionary:
			_fail("Every Gameplay Journey entry must be an object")
			return
		var journey := journey_value as Dictionary
		var journey_id := str(journey.get("journeyId", ""))
		if journey_id.is_empty() or journey_id in ids:
			_fail("Gameplay Journey IDs must be non-empty and unique: %s" % journey_id)
			return
		if not bool(journey.get("core", false)):
			_fail("The ten Golden Journeys must remain core: %s" % journey_id)
			return
		var events: Array = journey.get("events", [])
		if events.size() < 3 or events.any(func(event_id) -> bool: return str(event_id).is_empty()):
			_fail("Gameplay Journey must declare at least three non-empty ordered events: %s" % journey_id)
			return
		ids.append(journey_id)
	ids.sort()
	var expected := REQUIRED_IDS.duplicate()
	expected.sort()
	if ids != expected:
		_fail("Gameplay Journey registry differs from the fixed ten-Journey inventory: %s" % str(ids))
		return
	print("PASS: Gameplay Journey registry declares all ten core ordered Journeys without claiming runtime completion")
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error("FAIL: " + message)
	get_tree().quit(1)
