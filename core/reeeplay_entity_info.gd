class_name REEEplayEntityInfo
extends RefCounted
## Metadata and channel schema describing a single tracked entity in a REEEplay recording.

var entity_id: int = 0
var archetype_id: StringName = &""
var stable_key: StringName = &""
var display_name: String = ""
var player_id: String = ""
var team_id: int = -1
var spawn_tick: int = 0
var despawn_tick: int = -1
var scene_path: String = ""
var channel_names: Array[StringName] = []
var channel_codecs: PackedInt32Array = PackedInt32Array()
var channel_steps: PackedFloat32Array = PackedFloat32Array()
var channel_interpolated: Array[bool] = []
var initial_divider: int = 1
var initial_phase: int = 0
var priority: int = 0
var metadata: Dictionary = {}

# Runtime-only recording state (not persisted in .reee).
var target: Node = null
var archetype: REEEplayArchetype = null
var channels: Array[REEEplayChannel] = []
var current_divider: int = 1
var current_phase: int = 0
var last_values: Array = []
var sample_count: int = 0
var needs_full_sample: bool = true


func channel_count() -> int:
	return channel_names.size()


func find_channel_index(channel_name: StringName) -> int:
	return channel_names.find(channel_name)


## Ensures channel metadata arrays match the runtime channels list.
func sync_from_channels() -> void:
	var n := channels.size()
	channel_names.resize(n)
	channel_codecs.resize(n)
	channel_steps.resize(n)
	channel_interpolated.resize(n)
	for i in range(n):
		var ch := channels[i]
		channel_names[i] = ch.effective_name()
		channel_codecs[i] = ch.codec
		channel_steps[i] = ch.quantize_step if ch.quantize_step > 0.0 else 0.001
		channel_interpolated[i] = ch.interpolate


func duplicate_metadata() -> REEEplayEntityInfo:
	var copy := REEEplayEntityInfo.new()
	copy.entity_id = entity_id
	copy.archetype_id = archetype_id
	copy.stable_key = stable_key
	copy.display_name = display_name
	copy.player_id = player_id
	copy.team_id = team_id
	copy.spawn_tick = spawn_tick
	copy.despawn_tick = despawn_tick
	copy.scene_path = scene_path
	copy.channel_names = channel_names.duplicate()
	copy.channel_codecs = channel_codecs.duplicate()
	copy.channel_steps = channel_steps.duplicate()
	copy.channel_interpolated = channel_interpolated.duplicate()
	copy.initial_divider = initial_divider
	copy.initial_phase = initial_phase
	copy.priority = priority
	copy.metadata = metadata.duplicate(true)
	return copy


func strip_pii() -> void:
	player_id = ""
	display_name = "Entity_%d" % entity_id
	metadata.erase("steam_id")
	metadata.erase("ip")
	metadata.erase("email")
	metadata.erase("account_id")
