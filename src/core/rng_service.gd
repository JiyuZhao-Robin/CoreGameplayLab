class_name DomainRng
extends RefCounted

const MODULUS := 2147483647
const MULTIPLIER := 48271


func next_float(state: SpaceGameState, stream_id: String) -> float:
	var streams: Dictionary = state.rng.get("streams", {})
	var stream = streams.get(stream_id, {})
	var current := 0
	var counter := 0
	if typeof(stream) == TYPE_DICTIONARY:
		current = int(stream.get("state", _seed_for_stream(int(state.rng.get("master_seed", 1)), stream_id)))
		counter = int(stream.get("counter", 0))
	else:
		# Save v1 stored only the current generator state.
		current = int(stream)
	current = int((current * MULTIPLIER) % MODULUS)
	streams[stream_id] = {"state":current, "counter":counter + 1}
	state.rng["streams"] = streams
	return float(current) / float(MODULUS)


func next_int(state: SpaceGameState, stream_id: String, minimum: int, maximum: int) -> int:
	if maximum <= minimum:
		return minimum
	return minimum + int(floor(next_float(state, stream_id) * float(maximum - minimum + 1)))


func _seed_for_stream(master_seed: int, stream_id: String) -> int:
	var value := master_seed
	for character in stream_id.to_utf8_buffer():
		value = int((value * 31 + int(character)) % MODULUS)
	return maxi(1, value)
