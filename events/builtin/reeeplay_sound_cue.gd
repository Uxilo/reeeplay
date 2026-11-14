class_name REEEplaySoundCue
extends REEEplayCue
## Built-in playback cue spawning an ephemeral AudioStreamPlayer (2D, 3D, or non-positional).

var stream_path: String = ""
var bus: StringName = &"Master"
var volume_db: float = 0.0
var pitch_scale: float = 1.0
var spatial: bool = true
var max_distance: float = 0.0


func _init() -> void:
	super._init()
	type_id = &"REEEplaySoundCue"
	is_timeline_visible = false


func get_type_id() -> StringName:
	return &"REEEplaySoundCue"


func _serialize(ser: REEEplaySerializer) -> void:
	ser.write_string(stream_path)
	ser.write_string_name(bus)
	ser.write_float(volume_db)
	ser.write_float(pitch_scale)
	ser.write_bool(spatial)
	ser.write_float(max_distance)


func _deserialize(ser: REEEplaySerializer, _from_version: int) -> void:
	stream_path = ser.read_string()
	bus = ser.read_string_name()
	volume_db = ser.read_float()
	pitch_scale = ser.read_float()
	spatial = ser.read_bool()
	max_distance = ser.read_float()


func _on_playback_forward(player_node: Node) -> void:
	if stream_path.is_empty() or not ResourceLoader.exists(stream_path):
		return
	var stream := ResourceLoader.load(stream_path) as AudioStream
	if stream == null:
		return

	var host: Node = player_node.call("get_cue_host") if player_node.has_method("get_cue_host") else player_node
	if host == null:
		return

	var audio_bus := String(bus)
	var bus_setting := String(REEEplaySettings.value(&"reeeplay/playback/audio_bus"))
	if audio_bus.is_empty() and not bus_setting.is_empty():
		audio_bus = bus_setting

	var effective_pitch := pitch_scale
	if bool(REEEplaySettings.value(&"reeeplay/playback/scale_audio_pitch")) and player_node.has_method("get_playback_speed"):
		effective_pitch *= clampf(absf(float(player_node.call("get_playback_speed"))), 0.25, 4.0)

	if spatial and position is Vector3:
		var asp3 := AudioStreamPlayer3D.new()
		asp3.stream = stream
		asp3.volume_db = volume_db
		asp3.pitch_scale = effective_pitch
		if not audio_bus.is_empty():
			asp3.bus = StringName(audio_bus)
		if max_distance > 0.0:
			asp3.max_distance = max_distance
		host.add_child(asp3)
		asp3.global_position = position as Vector3
		asp3.finished.connect(asp3.queue_free)
		asp3.play()
	elif spatial and position is Vector2:
		var asp2 := AudioStreamPlayer2D.new()
		asp2.stream = stream
		asp2.volume_db = volume_db
		asp2.pitch_scale = effective_pitch
		if not audio_bus.is_empty():
			asp2.bus = StringName(audio_bus)
		if max_distance > 0.0:
			asp2.max_distance = max_distance
		host.add_child(asp2)
		asp2.global_position = position as Vector2
		asp2.finished.connect(asp2.queue_free)
		asp2.play()
	else:
		var asp := AudioStreamPlayer.new()
		asp.stream = stream
		asp.volume_db = volume_db
		asp.pitch_scale = effective_pitch
		if not audio_bus.is_empty():
			asp.bus = StringName(audio_bus)
		host.add_child(asp)
		asp.finished.connect(asp.queue_free)
		asp.play()
