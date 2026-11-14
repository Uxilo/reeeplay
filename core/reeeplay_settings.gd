## REEEplay's project settings under Project > Project Settings > Reeeplay.
## Safe to call repeatedly; registers missing settings without overwriting user values.
@tool
class_name REEEplaySettings
extends RefCounted

## [path, default_value, property_hint, hint_string, description]
static var DEFS: Array = [
	# Recording
	["reeeplay/recording/tick_rate", 0, PROPERTY_HINT_RANGE, "0,240,1", "Timeline resolution in ticks/s. 0 follows physics/common/physics_ticks_per_second. Locked per recording."],
	["reeeplay/recording/sample_rate", 20.0, PROPERTY_HINT_RANGE, "1,240,0.5,suffix:Hz", "Default recording sample rate for all entities."],
	["reeeplay/recording/preset", 5, PROPERTY_HINT_ENUM, "Singleplayer:0,Fun Game:1,Casual:2,Competitive:3,Esports:4,Custom:5", "Preset bundle applied when not set to Custom."],
	["reeeplay/recording/epsilon_scale", 1.0, PROPERTY_HINT_RANGE, "0.01,100,0.05", "Global multiplier applied to every channel's change epsilon."],
	["reeeplay/recording/rate_policy", "", PROPERTY_HINT_FILE, "*.tres,*.res", "Optional REEEplayRatePolicy resource path for automatic rate tuning."],
	["reeeplay/recording/rate_policy_evaluation_interval", 0.25, PROPERTY_HINT_RANGE, "0.05,5.0,0.05,suffix:s", "Seconds between automatic rate policy evaluations."],
	["reeeplay/recording/keyframe_interval_seconds", 5.0, PROPERTY_HINT_RANGE, "0.5,60,0.5,suffix:s", "Spacing between seek-anchor keyframes."],
	["reeeplay/recording/default_mode", 0, PROPERTY_HINT_ENUM, "Full:0,Ring Buffer:1,Full With Ring:2", "Default recording retention mode."],
	["reeeplay/recording/ring_buffer_seconds", 60.0, PROPERTY_HINT_RANGE, "5,600,1,suffix:s", "Duration retained in ring-buffer modes."],
	["reeeplay/recording/stop_on_scene_change", true, PROPERTY_HINT_NONE, "", "Automatically stop recording when the main scene changes."],
	["reeeplay/recording/record_while_paused", false, PROPERTY_HINT_NONE, "", "Advance recording ticks even while the SceneTree is paused."],
	["reeeplay/recording/max_memory_mb", 128, PROPERTY_HINT_RANGE, "8,4096,8,suffix:MB", "In-memory frame block budget before paging older blocks out."],
	["reeeplay/recording/default_perspective", "LOCAL", PROPERTY_HINT_ENUM, "LOCAL,AUTHORITATIVE,SPECTATOR", "Default recording perspective stored in META."],

	# Storage
	["reeeplay/storage/directory", "user://replays/", PROPERTY_HINT_DIR, "", "Directory used to store saved .reee recordings."],
	["reeeplay/storage/filename_template", "{date}_{time}_{map}", PROPERTY_HINT_NONE, "", "Filename template supporting {date}, {time}, {map}, {mode}, {match_id}."],
	["reeeplay/storage/auto_save", true, PROPERTY_HINT_NONE, "", "Automatically save recordings on stop_recording()."],
	["reeeplay/storage/stream_to_disk", true, PROPERTY_HINT_NONE, "", "Incrementally stream sealed blocks to .reee.part files."],
	["reeeplay/storage/auto_recover", true, PROPERTY_HINT_NONE, "", "Recover leftover .reee.part files on startup."],
	["reeeplay/storage/compression", 2, PROPERTY_HINT_ENUM, "None:0,Deflate:1,Zstd:2", "Chunk compression algorithm."],
	["reeeplay/storage/compression_min_bytes", 256, PROPERTY_HINT_RANGE, "0,65536,64,suffix:B", "Minimum raw payload size before chunk compression is applied."],
	["reeeplay/storage/max_saved_recordings", 50, PROPERTY_HINT_RANGE, "0,1000,1", "Maximum unpinned recordings kept on disk (0 = unlimited)."],
	["reeeplay/storage/max_storage_mb", 1024, PROPERTY_HINT_RANGE, "0,102400,64,suffix:MB", "Maximum storage budget for unpinned recordings (0 = unlimited)."],

	# Playback
	["reeeplay/playback/speeds", PackedFloat32Array([0.25, 0.5, 1.0, 2.0, 4.0, 8.0]), PROPERTY_HINT_NONE, "", "Preset playback speed steps."],
	["reeeplay/playback/block_cache_size", 8, PROPERTY_HINT_RANGE, "1,128,1", "Maximum decoded frame blocks kept in the player's LRU cache."],
	["reeeplay/playback/max_cue_dispatch_speed", 4.0, PROPERTY_HINT_RANGE, "0.5,32,0.5", "Suppress cosmetic cues above this playback speed."],
	["reeeplay/playback/audio_bus", &"Master", PROPERTY_HINT_NONE, "", "Audio bus used by REEEplaySoundCue during playback."],
	["reeeplay/playback/scale_audio_pitch", true, PROPERTY_HINT_NONE, "", "Scale sound cue pitch with playback speed (clamped 0.5-2.0)."],
	["reeeplay/playback/process_always", true, PROPERTY_HINT_NONE, "", "Allow REEEplayPlayer to advance while the SceneTree is paused."],

	# Events & Damage
	["reeeplay/events/auto_register_global_classes", true, PROPERTY_HINT_NONE, "", "Scan global classes for REEEplayEvent, REEEplayCue, and REEEplayAttachment subclasses at boot."],
	["reeeplay/damage/recap_window_seconds", 15.0, PROPERTY_HINT_RANGE, "1,120,1,suffix:s", "Default rolling damage recap window per entity."],
	["reeeplay/damage/combat_timeout_seconds", 5.0, PROPERTY_HINT_RANGE, "0.5,30,0.5,suffix:s", "Inactivity duration before an active combat session ends."],

	# Debug & Net
	["reeeplay/debug/overlay", false, PROPERTY_HINT_NONE, "", "Show live REEEplay recording diagnostics overlay."],
	["reeeplay/debug/warn_unserializable_properties", true, PROPERTY_HINT_NONE, "", "Warn in debug builds when an event exports unsupported Object/Node properties."],
	["reeeplay/net/enabled", false, PROPERTY_HINT_NONE, "", "Enable optional multiplayer comms/handover bridge."],
]


## Registers all REEEplay ProjectSettings with defaults and editor property hints.
static func register() -> void:
	for entry: Array in DEFS:
		var path: String = entry[0]
		if not ProjectSettings.has_setting(path):
			ProjectSettings.set_setting(path, entry[1])
		ProjectSettings.set_initial_value(path, entry[1])
		ProjectSettings.add_property_info({
			"name": path,
			"type": typeof(entry[1]),
			"hint": entry[2],
			"hint_string": entry[3],
		})
		ProjectSettings.set_as_basic(path, true)


## Returns the configured setting value or its default if not registered.
static func value(path: StringName) -> Variant:
	for entry: Array in DEFS:
		if entry[0] == path:
			return ProjectSettings.get_setting(path, entry[1])
	push_error("REEEplaySettings: unknown setting %s" % path)
	return null


## Returns the human-readable description for a setting path.
static func description(path: StringName) -> String:
	for entry: Array in DEFS:
		if entry[0] == path:
			return entry[4]
	return ""
