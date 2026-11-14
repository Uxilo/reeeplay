@tool
class_name REEEplayArchetype
extends Resource
## Defines how an entity category is sampled during recording and instantiated during playback.

@export var archetype_id: StringName = &""
@export var proxy_scene: PackedScene = null
@export var proxy_script: Script = null
@export var channels: Array[REEEplayChannel] = []
@export var default_divider: int = 1
@export var priority: int = 0
@export var strip_physics: bool = true
@export var strip_scripts: bool = false
@export var interpolate: bool = true
@export var metadata: Dictionary = {}

## Optional runtime callback: func(entity_info: REEEplayEntityInfo) -> Node
var proxy_factory: Callable = Callable()


## Convenience constructor for defining archetypes in code.
static func create(
	p_archetype_id: StringName,
	p_channels: Array[REEEplayChannel] = [],
	p_proxy_scene: PackedScene = null
) -> REEEplayArchetype:
	var arch := REEEplayArchetype.new()
	arch.archetype_id = p_archetype_id
	arch.channels = p_channels
	arch.proxy_scene = p_proxy_scene
	return arch


## Finds a channel by effective_name, or returns null.
func find_channel(channel_name: StringName) -> REEEplayChannel:
	for ch in channels:
		if ch != null and ch.effective_name() == channel_name:
			return ch
	return null

