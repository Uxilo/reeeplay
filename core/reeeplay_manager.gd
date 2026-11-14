class_name REEEplayManager
extends Node
## Autoload singleton ("REEEplay") providing one-call recording, playback, persistence, and pruning APIs.

signal recording_started(recording: REEEplayRecording)
signal recording_stopped(recording: REEEplayRecording)
signal recording_saved(path: String, error: int)

var default_session: REEEplaySession = null
var event_registry: REEEplayEventRegistry = null
var _last_scene_path: String = ""


func _ready() -> void:
	REEEplaySettings.register()
	event_registry = REEEplayEventRegistry.new(true)
	default_session = REEEplaySession.new()
	default_session.name = "DefaultSession"
	add_child(default_session)

	default_session.recording_started.connect(func(r: REEEplayRecording) -> void: recording_started.emit(r))
	default_session.recording_stopped.connect(func(r: REEEplayRecording) -> void: recording_stopped.emit(r))
	default_session.recording_saved.connect(func(p: String, e: int) -> void: recording_saved.emit(p, e))

	if is_inside_tree():
		get_tree().node_added.connect(_on_tree_changed_check)


func get_session() -> REEEplaySession:
	return default_session


func create_session(parent: Node = null) -> REEEplaySession:
	var s := REEEplaySession.new()
	if parent != null:
		parent.add_child(s)
	else:
		add_child(s)
	return s


func start_recording(preset_or_kind: Variant = null, options: Dictionary = {}) -> REEEplayRecording:
	return default_session.start_recording(preset_or_kind, options)


func stop_recording(auto_save_override: Variant = null) -> REEEplayRecording:
	var do_save := bool(auto_save_override) if auto_save_override is bool else bool(REEEplaySettings.value(&"reeeplay/storage/auto_save"))
	var path := ""
	if auto_save_override is String:
		path = str(auto_save_override)
		do_save = not path.is_empty()
	var rec := default_session.stop_recording("")
	if do_save and rec != null:
		if path.is_empty():
			path = build_default_save_path(rec)
		var comp := bool(REEEplaySettings.value(&"reeeplay/storage/compression"))
		var err := REEEplayWriter.save_file(rec, path, comp, event_registry)
		recording_saved.emit(path, err)
		prune_recordings()
	return rec


func is_recording() -> bool:
	return default_session.is_recording()


func register_archetype(archetype: REEEplayArchetype) -> void:
	default_session.register_archetype(archetype)


func track(target: Node, archetype_id: StringName = &"", options: Dictionary = {}) -> int:
	return default_session.track(target, archetype_id, options)


func untrack(target_or_id: Variant) -> void:
	default_session.untrack(target_or_id)


func respawn(target: Node, entity_id: int, archetype_id: StringName = &"", options: Dictionary = {}) -> int:
	return default_session.respawn(target, entity_id, archetype_id, options)


func set_entity_rate(target_or_id: Variant, divider: int, phase: int = -1) -> void:
	default_session.set_entity_rate(target_or_id, divider, phase)


func set_world_state(key: StringName, value: Variant) -> void:
	default_session.set_world_state(key, value)


func emit_event(ev: REEEplayEvent) -> void:
	default_session.emit_event(ev)


func record_damage(
	attacker: Variant,
	victim: Variant,
	amount: float,
	damage_type: StringName = &"physical",
	source_name: String = "",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return default_session.record_damage(attacker, victim, amount, damage_type, source_name, options)


func record_heal(
	healer: Variant,
	target_entity: Variant,
	amount: float,
	source_name: String = "",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return default_session.record_heal(healer, target_entity, amount, source_name, options)


func record_environmental_damage(
	victim: Variant,
	amount: float,
	damage_type: StringName = &"environment",
	source_name: String = "Environment",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return default_session.record_environmental_damage(victim, amount, damage_type, source_name, options)


func record_environmental_heal(
	target_entity: Variant,
	amount: float,
	source_name: String = "Environment",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return default_session.record_environmental_heal(target_entity, amount, source_name, options)


func add_attachment(att: REEEplayAttachment) -> void:
	default_session.add_attachment(att)


func save_recording(path: String = "", compress: bool = true) -> int:
	var target_path := path
	var rec := default_session.recorder.recording if default_session.recorder.recording != null else default_session.last_recording
	if rec == null:
		return ERR_DOES_NOT_EXIST
	if target_path.is_empty():
		target_path = build_default_save_path(rec)
	var err := REEEplayWriter.save_file(rec, target_path, compress, event_registry)
	recording_saved.emit(target_path, err)
	return err


func load_recording(path: String, options: Dictionary = {}) -> REEEplayReader.ReadResult:
	var opts := options.duplicate()
	if not opts.has("event_registry"):
		opts["event_registry"] = event_registry
	return REEEplayReader.load_file(path, opts)


func create_player(parent: Node = null, recording: REEEplayRecording = null) -> REEEplayPlayer:
	return default_session.create_player(parent, recording)


func build_default_save_path(rec: REEEplayRecording) -> String:
	var dir_path := str(REEEplaySettings.value(&"reeeplay/storage/directory"))
	var tmpl := str(REEEplaySettings.value(&"reeeplay/storage/filename_template"))
	var dt := Time.get_datetime_string_from_system(false, false).replace(":", "-")
	var fname := tmpl.replace("{datetime}", dt).replace("{id}", rec.recording_id if rec != null else "replay")
	if not fname.ends_with(".reee"):
		fname += ".reee"
	return dir_path.path_join(fname)


func list_recordings(dir_override: String = "") -> Array[Dictionary]:
	var dir_path := dir_override if not dir_override.is_empty() else str(REEEplaySettings.value(&"reeeplay/storage/directory"))
	var da := DirAccess.open(dir_path)
	if da == null:
		return []
	var out: Array[Dictionary] = []
	da.list_dir_begin()
	var fname := da.get_next()
	while not fname.is_empty():
		if not da.current_is_dir() and fname.ends_with(".reee"):
			var full := dir_path.path_join(fname)
			out.append({
				"file_name": fname,
				"path": full,
				"modified_unix": FileAccess.get_modified_time(full),
				"size_bytes": _file_size(full),
			})
		fname = da.get_next()
	da.list_dir_end()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["modified_unix"]) > int(b["modified_unix"])
	)
	return out


func prune_recordings(dir_override: String = "") -> int:
	var max_count := int(REEEplaySettings.value(&"reeeplay/storage/max_saved_recordings"))
	var max_mb := int(REEEplaySettings.value(&"reeeplay/storage/max_storage_mb"))
	var files := list_recordings(dir_override)
	var removed := 0
	var total_bytes := 0
	for i in range(files.size()):
		var f: Dictionary = files[i]
		total_bytes += int(f["size_bytes"])
		var over_count := max_count > 0 and i >= max_count
		var over_size := max_mb > 0 and total_bytes > (max_mb * 1024 * 1024)
		if over_count or over_size:
			var p := str(f["path"])
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(p) if p.begins_with("user://") or p.begins_with("res://") else p) == OK:
				removed += 1
				total_bytes -= int(f["size_bytes"])
	return removed


func _file_size(path: String) -> int:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return 0
	var sz := fa.get_length()
	fa.close()
	return sz


func _on_tree_changed_check(_node: Node) -> void:
	if not bool(REEEplaySettings.value(&"reeeplay/recording/stop_on_scene_change")):
		return
	if not is_inside_tree():
		return
	var cs := get_tree().current_scene
	var cur_path := cs.scene_file_path if cs != null else ""
	if not _last_scene_path.is_empty() and cur_path != _last_scene_path and is_recording():
		stop_recording()
	_last_scene_path = cur_path
