class_name REEEplayKillcam
extends Node
## Drop-in killcam / instant-replay helper that slices the last N seconds and plays it in slow-mo with a death recap.

signal killcam_started(clip: REEEplayRecording, recap: Dictionary)
signal killcam_finished

@export var default_window_seconds: float = 6.0
@export var slow_mo_speed: float = 0.35
@export var orbit_distance: float = 7.5
@export var orbit_pitch: float = -0.35
@export var auto_loop: bool = false

var player: REEEplayPlayer = null
var camera: REEEplayCamera = null
var last_clip: REEEplayRecording = null
var last_recap: Dictionary = {}


func capture_clip(recorder_or_session: Variant, window_seconds: float = -1.0) -> REEEplayRecording:
	var rec := _resolve_recorder(recorder_or_session)
	if rec == null:
		return null
	var win := window_seconds if window_seconds > 0.0 else default_window_seconds
	var clip := rec.export_ring_clip(win)
	last_clip = clip
	return clip


func play_killcam(
	recorder_or_session: Variant,
	victim_entity_id: int,
	stage: Node = null,
	options: Dictionary = {}
) -> Dictionary:
	var rec := _resolve_recorder(recorder_or_session)
	if rec == null:
		return {}

	var win := float(options.get("window_seconds", default_window_seconds))
	var spd := float(options.get("speed", slow_mo_speed))
	var focus_id := int(options.get("focus_entity_id", victim_entity_id))

	var clip := capture_clip(rec, win)
	if clip == null:
		return {}

	var end_tick := clip.get_end_tick()
	var recap := clip.damage_log.death_recap(victim_entity_id, end_tick, clip.tick_rate, win)
	last_recap = recap

	_ensure_player_and_camera(rec, stage, focus_id)
	player.loop = bool(options.get("loop", auto_loop))
	player.load_recording(clip)
	player.play(spd)

	killcam_started.emit(clip, recap)
	return {
		"clip": clip,
		"recap": recap,
		"player": player,
		"camera": camera,
	}


func stop_killcam() -> void:
	if player != null and is_instance_valid(player):
		player.stop_and_clear()
	killcam_finished.emit()


func _ensure_player_and_camera(rec: REEEplayRecorder, stage: Node, focus_id: int) -> void:
	if player == null or not is_instance_valid(player):
		player = REEEplayPlayer.new()
		player.name = "KillcamPlayer"
		player.playback_finished.connect(func() -> void:
			killcam_finished.emit()
		)
		add_child(player)

	for k in rec._archetypes:
		player.register_archetype(rec._archetypes[k])

	if stage is REEEplayStage:
		var st3 := stage as REEEplayStage
		player.proxy_root = st3.entity_root
		player.cue_host = st3.cue_root
	elif stage is REEEplayStage2D:
		var st2 := stage as REEEplayStage2D
		player.proxy_root = st2.entity_root
		player.cue_host = st2.cue_root
	elif stage != null:
		player.proxy_root = stage
		player.cue_host = stage

	if stage == null or stage is Node3D:
		if camera == null or not is_instance_valid(camera):
			camera = REEEplayCamera.new()
			camera.name = "KillcamCamera"
			add_child(camera)
		camera.mode = REEEplayCamera.Mode.ORBIT
		camera.orbit_distance = orbit_distance
		camera.orbit_pitch = orbit_pitch
		camera.target_entity_id = focus_id
		camera.ensure_camera()
		player.camera = camera


static func _resolve_recorder(recorder_or_session: Variant) -> REEEplayRecorder:
	if recorder_or_session is REEEplayRecorder:
		return recorder_or_session as REEEplayRecorder
	if recorder_or_session is REEEplaySession:
		return (recorder_or_session as REEEplaySession).recorder
	return null

