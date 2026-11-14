extends Node3D
## Self-contained interactive 3D demo for REEEplay recording, .reee save/load, playback, and damage recap.

const DEMO_SAVE_PATH := "user://reeeplay_demo/demo_clip.reee"
const SAMPLE_PLAYBACK_PATH := "res://addons/reeeplay/demo/sample_playback.reee"

@onready var live_world: Node3D = $LiveWorld
@onready var live_camera: Camera3D = $LiveWorld/LiveCamera
@onready var player_actor: Node3D = $LiveWorld/PlayerActor
@onready var orbiter_actor: Node3D = $LiveWorld/OrbiterActor
@onready var session: REEEplaySession = $REEEplaySession
@onready var stage: REEEplayStage = $REEEplayStage

@onready var mode_label: Label = $HUD/Panel/Margin/VBox/HeaderRow/ModeLabel
@onready var status_label: Label = $HUD/Panel/Margin/VBox/StatusLabel
@onready var btn_record: Button = $HUD/Panel/Margin/VBox/RecordRow/BtnRecord
@onready var btn_save: Button = $HUD/Panel/Margin/VBox/RecordRow/BtnSave
@onready var btn_load: Button = $HUD/Panel/Margin/VBox/RecordRow/BtnLoad
@onready var btn_load_sample: Button = $HUD/Panel/Margin/VBox/RecordRow/BtnLoadSample
@onready var btn_live: Button = $HUD/Panel/Margin/VBox/RecordRow/BtnLive
@onready var btn_play: Button = $HUD/Panel/Margin/VBox/PlaybackRow/BtnPlay
@onready var btn_stop: Button = $HUD/Panel/Margin/VBox/PlaybackRow/BtnStop
@onready var speed_option: OptionButton = $HUD/Panel/Margin/VBox/PlaybackRow/SpeedOption
@onready var time_label: Label = $HUD/Panel/Margin/VBox/PlaybackRow/TimeLabel
@onready var scrub_slider: HSlider = $HUD/Panel/Margin/VBox/ScrubSlider
@onready var recap_label: RichTextLabel = $HUD/Panel/Margin/VBox/RecapLabel

var _player: REEEplayPlayer = null
var _replay_camera: REEEplayCamera = null
var _elapsed: float = 0.0
var _player_entity_id: int = 0
var _orbiter_entity_id: int = 0
var _auto_combat_timer: float = 0.0
var _is_scrubbing: bool = false
var _in_replay_mode: bool = false
var _last_recording: REEEplayRecording = null


func _ready() -> void:
	_build_visuals()
	_setup_ui()
	_register_demo_archetypes()
	_set_replay_mode(false)
	if ResourceLoader.exists(SAMPLE_PLAYBACK_PATH) or FileAccess.file_exists(SAMPLE_PLAYBACK_PATH):
		_load_sample_playback(false)
	else:
		_update_status("Ready. Press Record (R) and move with WASD.")


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if not _in_replay_mode:
		_step_live_actors(delta)
		if session.is_recording():
			_auto_combat_timer += delta
			if _auto_combat_timer >= 1.25:
				_auto_combat_timer = 0.0
				_emit_demo_combat_exchange()
			_refresh_damage_recap(session.get_damage_log(), _player_entity_id)
			_update_status("Recording... %.2fs (%d ticks)" % [
				session.recorder.recording.get_duration_seconds() if session.recorder.recording != null else 0.0,
				session.recorder.current_tick,
			])


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key_ev := event as InputEventKey
		if key_ev.keycode == KEY_R:
			_on_record_pressed()
		elif key_ev.keycode == KEY_SPACE and _last_recording != null:
			_on_play_pressed()
		elif key_ev.keycode == KEY_H and not _in_replay_mode and session.is_recording():
			session.record_damage(_player_entity_id, _orbiter_entity_id, 25.0, &"impact", "Manual Slam")
			_refresh_damage_recap(session.get_damage_log(), _player_entity_id)
		elif key_ev.keycode == KEY_J and not _in_replay_mode and session.is_recording():
			session.record_heal(_orbiter_entity_id, _player_entity_id, 15.0, "Field Medic")
			_refresh_damage_recap(session.get_damage_log(), _player_entity_id)


func _build_visuals() -> void:
	var floor_mesh := $LiveWorld/ArenaFloor as MeshInstance3D
	if floor_mesh != null and floor_mesh.mesh == null:
		var plane := PlaneMesh.new()
		plane.size = Vector2(22.0, 22.0)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.16, 0.18, 0.22)
		mat.roughness = 0.85
		plane.material = mat
		floor_mesh.mesh = plane

	_ensure_actor_mesh(player_actor, Color(0.24, 0.72, 0.98), true)
	_ensure_actor_mesh(orbiter_actor, Color(0.98, 0.45, 0.28), false)


static func _ensure_actor_mesh(root: Node3D, color: Color, is_capsule: bool) -> void:
	if root == null:
		return
	var visual := root.get_node_or_null("Visual") as MeshInstance3D
	if visual == null:
		visual = MeshInstance3D.new()
		visual.name = "Visual"
		root.add_child(visual)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.4
	if is_capsule:
		var cap := CapsuleMesh.new()
		cap.radius = 0.45
		cap.height = 1.6
		cap.material = mat
		visual.mesh = cap
		visual.position = Vector3(0.0, 0.8, 0.0)
	else:
		var box := BoxMesh.new()
		box.size = Vector3(1.0, 1.0, 1.0)
		box.material = mat
		visual.mesh = box
		visual.position = Vector3(0.0, 0.5, 0.0)


func _register_demo_archetypes() -> void:
	session.register_archetype(_make_archetype(&"DemoPlayer", Color(0.24, 0.72, 0.98), true))
	session.register_archetype(_make_archetype(&"DemoOrbiter", Color(0.98, 0.45, 0.28), false))


static func _build_proxy_node(color: Color, is_capsule: bool) -> Node:
	var proxy := Node3D.new()
	_ensure_actor_mesh(proxy, color, is_capsule)
	return proxy


func _make_archetype(id: StringName, color: Color, is_capsule: bool) -> REEEplayArchetype:
	var arch := REEEplayArchetype.new()
	arch.archetype_id = id
	arch.channels = REEEplayChannelPresets.transform_3d()
	arch.proxy_factory = func(_info: REEEplayEntityInfo) -> Node:
		return _build_proxy_node(color, is_capsule)
	return arch


func _setup_ui() -> void:
	btn_record.pressed.connect(_on_record_pressed)
	btn_save.pressed.connect(_on_save_pressed)
	btn_load.pressed.connect(_on_load_pressed)
	btn_load_sample.pressed.connect(func() -> void: _load_sample_playback(true))
	btn_live.pressed.connect(func() -> void: _set_replay_mode(false))
	btn_play.pressed.connect(_on_play_pressed)
	btn_stop.pressed.connect(_on_stop_pressed)

	speed_option.clear()
	for label_str in ["0.25x", "0.5x", "1.0x", "2.0x"]:
		speed_option.add_item(label_str)
	speed_option.select(2)
	speed_option.item_selected.connect(_on_speed_selected)

	scrub_slider.drag_started.connect(func() -> void: _is_scrubbing = true)
	scrub_slider.drag_ended.connect(_on_scrub_ended)
	scrub_slider.value_changed.connect(_on_scrub_value_changed)

	btn_save.disabled = true
	btn_play.disabled = true
	btn_stop.disabled = true
	scrub_slider.editable = false


func _step_live_actors(delta: float) -> void:
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		move.z -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		move.z += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		move.x += 1.0

	if move.length_squared() > 0.001:
		move = move.normalized() * 6.0 * delta
		player_actor.position += move
		player_actor.position.x = clampf(player_actor.position.x, -9.0, 9.0)
		player_actor.position.z = clampf(player_actor.position.z, -9.0, 9.0)
		player_actor.rotation.y = atan2(move.x, move.z)
	else:
		# Gentle idle sway so recording always has motion even without keyboard input.
		player_actor.rotation.y = sin(_elapsed * 1.4) * 0.35

	orbiter_actor.position = Vector3(
		cos(_elapsed * 1.3) * 4.5,
		0.35 + sin(_elapsed * 2.6) * 0.35,
		sin(_elapsed * 0.65) * 4.5
	)
	orbiter_actor.rotation.y = _elapsed * 1.8


func _emit_demo_combat_exchange() -> void:
	session.record_damage(_orbiter_entity_id, _player_entity_id, 12.5, &"fire", "Orbiter Pulse")
	session.record_environmental_damage(_player_entity_id, 4.0, &"lava", "Arena Floor Hazard")
	session.record_heal(_player_entity_id, _player_entity_id, 6.0, "Regen")

	var marker := REEEplayMarkerEvent.new()
	marker.marker_name = "Exchange"
	session.emit_event(marker)


func _on_record_pressed() -> void:
	if not session.is_recording():
		_set_replay_mode(false)
		_auto_combat_timer = 0.0
		session.start_recording(REEEplayPreset.Kind.SINGLEPLAYER, {"title": "REEEplay Demo Clip"})
		_player_entity_id = session.track(player_actor, &"DemoPlayer", {"display_name": "Player"})
		_orbiter_entity_id = session.track(orbiter_actor, &"DemoOrbiter", {"display_name": "Orbiter"})
		btn_record.text = "Stop Recording (R)"
		btn_save.disabled = true
		btn_play.disabled = true
		btn_stop.disabled = true
		scrub_slider.editable = false
	else:
		_last_recording = session.stop_recording()
		btn_record.text = "Record (R)"
		if _last_recording != null:
			_load_recording_into_player(_last_recording)
			_set_replay_mode(true)
			_player.play(1.0)
			_update_status("Recorded %.2fs. Playing replay!" % [
				_last_recording.get_duration_seconds(),
			])


func _on_save_pressed() -> void:
	if _last_recording == null:
		return
	var err := REEEplayWriter.save_file(_last_recording, DEMO_SAVE_PATH, true)
	if err == OK:
		_update_status("Saved .reee -> %s" % ProjectSettings.globalize_path(DEMO_SAVE_PATH))
	else:
		_update_status("Save failed (err=%d)" % err)


func _on_load_pressed() -> void:
	if not FileAccess.file_exists(DEMO_SAVE_PATH):
		_update_status("No saved clip yet at %s. Record and Save first." % DEMO_SAVE_PATH)
		return
	var result := REEEplayReader.load_file(DEMO_SAVE_PATH)
	if result.error != REEEplayFormat.LoadError.OK or result.recording == null:
		_update_status("Load failed: %s" % result.error_message)
		return
	_last_recording = result.recording
	_load_recording_into_player(_last_recording)
	_set_replay_mode(true)
	_player.play(1.0)
	_update_status("Loaded .reee from disk (%.2fs)." % _last_recording.get_duration_seconds())


func _load_sample_playback(auto_play: bool = true) -> void:
	var result := REEEplayReader.load_file(SAMPLE_PLAYBACK_PATH)
	if result.error != REEEplayFormat.LoadError.OK or result.recording == null:
		_update_status("Failed to load sample .reee: %s" % result.error_message)
		return
	_last_recording = result.recording
	_load_recording_into_player(_last_recording)
	if auto_play:
		_set_replay_mode(true)
		_player.play(1.0)
		_update_status("Playing premade sample (%.2fs, %d events)." % [
			_last_recording.get_duration_seconds(),
			_last_recording.events.size(),
		])
	else:
		_update_status("Premade sample loaded (%.2fs, %d events). Press Space to play or R to record." % [
			_last_recording.get_duration_seconds(),
			_last_recording.events.size(),
		])


func _load_recording_into_player(rec: REEEplayRecording) -> void:
	if _player != null and is_instance_valid(_player):
		_player.queue_free()
	if _replay_camera != null and is_instance_valid(_replay_camera):
		_replay_camera.queue_free()

	stage.clear_all()
	_player = REEEplayPlayer.new()
	_player.name = "DemoReplayPlayer"
	_player.proxy_root = stage.entity_root
	_player.cue_host = stage.cue_root
	_player.loop = true
	_player.register_archetype(_make_archetype(&"DemoPlayer", Color(0.24, 0.72, 0.98), true))
	_player.register_archetype(_make_archetype(&"DemoOrbiter", Color(0.98, 0.45, 0.28), false))
	add_child(_player)

	_replay_camera = REEEplayCamera.new()
	_replay_camera.name = "DemoReplayCamera"
	_replay_camera.mode = REEEplayCamera.Mode.ORBIT
	_replay_camera.orbit_distance = 11.0
	_replay_camera.orbit_pitch = -0.45
	stage.add_child(_replay_camera)
	_replay_camera.ensure_camera()
	_player.camera = _replay_camera

	_player.time_changed.connect(_on_player_time_changed)
	_player.event_reached.connect(_on_player_event_reached)
	_player.playback_started.connect(func() -> void: btn_play.text = "Pause (Space)")
	_player.playback_paused.connect(func() -> void: btn_play.text = "Play (Space)")

	_player.load_recording(rec)
	if not rec.entities.is_empty():
		_replay_camera.target_entity_id = int(rec.entities.keys()[0])

	var dur := rec.get_duration_seconds()
	scrub_slider.min_value = 0.0
	scrub_slider.max_value = maxf(0.01, dur)
	scrub_slider.step = 0.01
	scrub_slider.value = 0.0
	scrub_slider.editable = true
	btn_save.disabled = false
	btn_play.disabled = false
	btn_stop.disabled = false
	_refresh_damage_recap(rec.damage_log, int(rec.entities.keys()[0]) if not rec.entities.is_empty() else 1)


func _set_replay_mode(enabled: bool) -> void:
	_in_replay_mode = enabled
	live_world.visible = not enabled
	stage.visible = enabled
	btn_live.disabled = not enabled
	if enabled and _replay_camera != null:
		_replay_camera.ensure_camera().current = true
		mode_label.text = "[REPLAY]"
		mode_label.modulate = Color(0.98, 0.76, 0.32)
	else:
		live_camera.current = true
		if _player != null:
			_player.pause()
		mode_label.text = "[LIVE]"
		mode_label.modulate = Color(0.45, 0.92, 0.58)


func _on_play_pressed() -> void:
	if _player == null:
		return
	if not _in_replay_mode:
		_set_replay_mode(true)
	if _player.is_playing:
		_player.pause()
	else:
		_player.play()


func _on_stop_pressed() -> void:
	if _player != null:
		_player.stop()


func _on_speed_selected(index: int) -> void:
	if _player == null:
		return
	var speeds := [0.25, 0.5, 1.0, 2.0]
	if index >= 0 and index < speeds.size():
		_player.set_speed(speeds[index])


func _on_scrub_value_changed(val: float) -> void:
	if _is_scrubbing and _player != null:
		_player.seek_to_time(val)


func _on_scrub_ended(value_changed: bool) -> void:
	if value_changed and _player != null:
		_player.seek_to_time(scrub_slider.value)
	_is_scrubbing = false


func _on_player_time_changed(current_seconds: float, duration_seconds: float) -> void:
	if not _is_scrubbing:
		scrub_slider.set_value_no_signal(current_seconds)
	time_label.text = "%.2fs / %.2fs (t=%d)" % [current_seconds, duration_seconds, _player.current_tick]


func _on_player_event_reached(ev: REEEplayEvent) -> void:
	if ev == null:
		return
	_update_status("Event [t=%d]: %s (%s)" % [ev.tick, ev.get_timeline_label(), ev.get_type_id()])


func _refresh_damage_recap(dlog: REEEplayDamageLog, victim_id: int) -> void:
	if dlog == null or victim_id <= 0:
		recap_label.text = "Damage Log: empty"
		return
	var victim_entries: Array[REEEplayDamageEntry] = dlog.entries_for_victim(victim_id)
	var total_dmg := 0.0
	var total_heal := 0.0
	for e in victim_entries:
		if e.is_heal:
			total_heal += e.amount
		else:
			total_dmg += e.amount
	var lines := PackedStringArray([
		"[b]Damage Recap (Entity %d)[/b]  Dmg: %.1f | Heal: %.1f | Entries: %d" % [
			victim_id, total_dmg, total_heal, dlog.entries.size()
		]
	])
	var start_idx := maxi(0, victim_entries.size() - 3)
	for i in range(start_idx, victim_entries.size()):
		var e: REEEplayDamageEntry = victim_entries[i]
		lines.append("• [t=%d] %s: %.1f (%s)" % [
			e.tick,
			e.source_name if not e.source_name.is_empty() else str(e.damage_type),
			e.amount,
			"HEAL" if e.is_heal else ("ENV" if e.is_environmental else "DMG"),
		])
	recap_label.text = "\n".join(lines)


func _update_status(text: String) -> void:
	status_label.text = text
