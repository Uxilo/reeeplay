class_name REEEplaySession
extends Node
## High-level Node wrapper owning a REEEplayRecorder and fixed-step physics progression.

signal recording_started(recording: REEEplayRecording)
signal recording_stopped(recording: REEEplayRecording)
signal recording_saved(path: String, error: int)

var recorder: REEEplayRecorder = REEEplayRecorder.new()
var last_recording: REEEplayRecording = null
var active_player: REEEplayPlayer = null
var _preset_kind_override: int = -1


func _ready() -> void:
	_sync_process_mode()


func _physics_process(delta: float) -> void:
	if recorder.is_recording:
		recorder.advance(delta)


func start_recording(preset_or_kind: Variant = null, options: Dictionary = {}) -> REEEplayRecording:
	var preset: REEEplayPreset = null
	if preset_or_kind is REEEplayPreset:
		preset = preset_or_kind as REEEplayPreset
	elif preset_or_kind is int:
		preset = REEEplayPreset.from_kind(int(preset_or_kind) as REEEplayPreset.Kind)
	else:
		preset = _preset_from_project_settings()

	recorder.preset = preset
	if not options.has("scene_path") and is_inside_tree() and get_tree().current_scene != null:
		options["scene_path"] = get_tree().current_scene.scene_file_path
	_sync_process_mode()
	var rec := recorder.begin(options)
	last_recording = rec
	recording_started.emit(rec)
	return rec


func stop_recording(save_path: String = "", compress: bool = true) -> REEEplayRecording:
	var rec := recorder.stop()
	last_recording = rec
	recording_stopped.emit(rec)
	if not save_path.is_empty() and rec != null:
		var err := REEEplayWriter.save_file(rec, save_path, compress)
		recording_saved.emit(save_path, err)
	return rec


func is_recording() -> bool:
	return recorder.is_recording


func register_archetype(archetype: REEEplayArchetype) -> void:
	recorder.register_archetype(archetype)


func track(target: Node, archetype_id: StringName = &"", options: Dictionary = {}) -> int:
	return recorder.track(target, archetype_id, options)


func untrack(target_or_id: Variant) -> void:
	recorder.despawn(target_or_id)


func respawn(target: Node, entity_id: int, archetype_id: StringName = &"", options: Dictionary = {}) -> int:
	return recorder.respawn(target, entity_id, archetype_id, options)


func set_entity_rate(target_or_id: Variant, divider: int, phase: int = -1) -> void:
	recorder.set_entity_rate(target_or_id, divider, phase)


func set_world_state(key: StringName, value: Variant) -> void:
	recorder.set_world_state(key, value)


func emit_event(ev: REEEplayEvent) -> void:
	recorder.emit_event(ev)


func record_damage(
	attacker: Variant,
	victim: Variant,
	amount: float,
	damage_type: StringName = &"physical",
	source_name: String = "",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return recorder.get_damage_tracker().record_damage(attacker, victim, amount, damage_type, source_name, options)


func record_heal(
	healer: Variant,
	target_entity: Variant,
	amount: float,
	source_name: String = "",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return recorder.get_damage_tracker().record_heal(healer, target_entity, amount, source_name, options)


func record_environmental_damage(
	victim: Variant,
	amount: float,
	damage_type: StringName = &"environment",
	source_name: String = "Environment",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return recorder.get_damage_tracker().record_environmental_damage(victim, amount, damage_type, source_name, options)


func record_environmental_heal(
	target_entity: Variant,
	amount: float,
	source_name: String = "Environment",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return recorder.get_damage_tracker().record_environmental_heal(target_entity, amount, source_name, options)


func get_damage_log() -> REEEplayDamageLog:
	return recorder.get_damage_tracker().log


func add_attachment(att: REEEplayAttachment) -> void:
	recorder.add_attachment(att)


func save_recording(path: String, compress: bool = true) -> int:
	var rec := recorder.recording if recorder.recording != null else last_recording
	if rec == null:
		return ERR_DOES_NOT_EXIST
	var err := REEEplayWriter.save_file(rec, path, compress)
	recording_saved.emit(path, err)
	return err


func load_recording(path: String, options: Dictionary = {}) -> REEEplayReader.ReadResult:
	return REEEplayReader.load_file(path, options)


func create_player(parent: Node = null, p_recording: REEEplayRecording = null) -> REEEplayPlayer:
	var player := REEEplayPlayer.new()
	player.name = "REEEplayPlayer"
	for k in recorder._archetypes:
		player.register_archetype(recorder._archetypes[k])
	if parent != null:
		parent.add_child(player)
	else:
		add_child(player)
	var rec := p_recording if p_recording != null else (recorder.recording if recorder.recording != null else last_recording)
	if rec != null:
		player.load_recording(rec)
	active_player = player
	return player


func _sync_process_mode() -> void:
	if bool(REEEplaySettings.value(&"reeeplay/recording/record_while_paused")):
		process_mode = Node.PROCESS_MODE_ALWAYS
	else:
		process_mode = Node.PROCESS_MODE_PAUSABLE


func _preset_from_project_settings() -> REEEplayPreset:
	var p_idx := int(REEEplaySettings.value(&"reeeplay/recording/preset"))
	var p := REEEplayPreset.from_kind(p_idx as REEEplayPreset.Kind)
	if p_idx == REEEplayPreset.Kind.CUSTOM:
		p.tick_rate = int(REEEplaySettings.value(&"reeeplay/recording/tick_rate"))
		p.sample_rate = int(REEEplaySettings.value(&"reeeplay/recording/sample_rate"))
		p.keyframe_interval_seconds = float(REEEplaySettings.value(&"reeeplay/recording/keyframe_interval_seconds"))
		p.recording_mode = int(REEEplaySettings.value(&"reeeplay/recording/default_mode")) as REEEplayPreset.RecordingMode
		p.ring_buffer_seconds = float(REEEplaySettings.value(&"reeeplay/recording/ring_buffer_seconds"))
		p.epsilon_scale = float(REEEplaySettings.value(&"reeeplay/recording/epsilon_scale"))
		p.compression = bool(REEEplaySettings.value(&"reeeplay/storage/compression"))
	return p
