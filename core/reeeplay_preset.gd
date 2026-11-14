@tool
class_name REEEplayPreset
extends Resource
## Named configuration bundle controlling tick rate, recording mode, codecs, and rate policy.

enum Kind {
	SINGLEPLAYER = 0,
	FUN_GAME = 1,
	CASUAL = 2,
	COMPETITIVE = 3,
	ESPORTS = 4,
	CUSTOM = 5,
}

enum RecordingMode {
	FULL = 0,
	RING_BUFFER = 1,
	FULL_WITH_RING = 2,
}

@export var kind: Kind = Kind.CUSTOM
@export var tick_rate: int = 30
@export var sample_rate: int = 30
@export var keyframe_interval_seconds: float = 5.0
@export var recording_mode: RecordingMode = RecordingMode.FULL
@export var ring_buffer_seconds: float = 60.0
@export var default_vector3_codec: REEEplayCodec.Id = REEEplayCodec.Id.VEC3_Q16
@export var default_vector2_codec: REEEplayCodec.Id = REEEplayCodec.Id.VEC2_Q16
@export var epsilon_scale: float = 1.0
@export var rate_policy: REEEplayRatePolicy = null
@export var compression: bool = true


## Builds a built-in preset instance matching section 6.5 of the REEEplay specification.
static func from_kind(preset_kind: Kind) -> REEEplayPreset:
	var p := REEEplayPreset.new()
	p.kind = preset_kind
	match preset_kind:
		Kind.SINGLEPLAYER:
			p.tick_rate = 30
			p.sample_rate = 30
			p.recording_mode = RecordingMode.FULL
			p.keyframe_interval_seconds = 5.0
			p.default_vector3_codec = REEEplayCodec.Id.VEC3_Q16
			p.default_vector2_codec = REEEplayCodec.Id.VEC2_Q16
			p.epsilon_scale = 1.0
			var pol := REEEplayRatePolicy.new()
			pol.enabled = true
			pol.mode = REEEplayRatePolicy.Mode.DISTANCE_LOD
			pol.baseline_divider = 1
			p.rate_policy = pol
		Kind.FUN_GAME:
			p.tick_rate = 60
			p.sample_rate = 20
			p.recording_mode = RecordingMode.RING_BUFFER
			p.ring_buffer_seconds = 90.0
			p.keyframe_interval_seconds = 5.0
			p.default_vector3_codec = REEEplayCodec.Id.VEC3_Q16
			p.default_vector2_codec = REEEplayCodec.Id.VEC2_Q16
			p.epsilon_scale = 1.0
			var pol := REEEplayRatePolicy.new()
			pol.enabled = true
			pol.mode = REEEplayRatePolicy.Mode.EVENT_BOOST
			pol.baseline_divider = 3 # 60 / 3 = 20 Hz baseline
			pol.boost_divider = 1    # 60 Hz during burst
			pol.boost_duration_seconds = 2.0
			p.rate_policy = pol
		Kind.CASUAL:
			p.tick_rate = 20
			p.sample_rate = 20
			p.recording_mode = RecordingMode.FULL
			p.keyframe_interval_seconds = 5.0
			p.default_vector3_codec = REEEplayCodec.Id.VEC3_Q16
			p.default_vector2_codec = REEEplayCodec.Id.VEC2_Q16
			p.epsilon_scale = 1.0
			var pol := REEEplayRatePolicy.new()
			pol.enabled = true
			pol.mode = REEEplayRatePolicy.Mode.ADAPTIVE_BUDGET
			pol.baseline_divider = 1
			p.rate_policy = pol
		Kind.COMPETITIVE:
			p.tick_rate = 60
			p.sample_rate = 30
			p.recording_mode = RecordingMode.FULL_WITH_RING
			p.ring_buffer_seconds = 30.0
			p.keyframe_interval_seconds = 3.0
			p.default_vector3_codec = REEEplayCodec.Id.VEC3_Q16
			p.default_vector2_codec = REEEplayCodec.Id.VEC2_Q16
			p.epsilon_scale = 0.5
			var pol := REEEplayRatePolicy.new()
			pol.enabled = true
			pol.mode = REEEplayRatePolicy.Mode.COMBAT_BOOST
			pol.baseline_divider = 2 # 60 / 2 = 30 Hz baseline
			pol.boost_divider = 1    # 60 Hz in combat
			pol.boost_duration_seconds = 2.0
			p.rate_policy = pol
		Kind.ESPORTS:
			p.tick_rate = 60
			p.sample_rate = 60
			p.recording_mode = RecordingMode.FULL
			p.keyframe_interval_seconds = 2.0
			p.default_vector3_codec = REEEplayCodec.Id.VEC3_F32
			p.default_vector2_codec = REEEplayCodec.Id.VEC2_F32
			p.epsilon_scale = 0.25
			var pol := REEEplayRatePolicy.new()
			pol.enabled = false
			pol.mode = REEEplayRatePolicy.Mode.CONSTANT
			p.rate_policy = pol
		_:
			p.rate_policy = REEEplayRatePolicy.new()
	return p

