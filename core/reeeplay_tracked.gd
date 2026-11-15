@tool
class_name REEEplayTracked
extends Node
## Drop-in child component that automatically registers its target node with REEEplay when active.

@export var auto_track: bool = true
@export var archetype_id: StringName = &""
@export var archetype: REEEplayArchetype = null:
	set(value):
		archetype = value
		update_configuration_warnings()
@export var target_node: Node = null:
	set(value):
		target_node = value
		update_configuration_warnings()
@export var proxy_scene: PackedScene = null:
	set(value):
		proxy_scene = value
		update_configuration_warnings()
@export var fallback_to_source_scene: bool = true:
	set(value):
		fallback_to_source_scene = value
		update_configuration_warnings()
@export var sample_rate: float = 0.0
@export var stable_key: StringName = &""
@export var display_name: String = ""
@export var player_id: String = ""
@export var team_id: int = -1
@export var priority: int = 0
@export var custom_channels: Array[REEEplayChannel] = []:
	set(value):
		custom_channels = value
		update_configuration_warnings()
@export var despawn_on_exit: bool = true

var entity_id: int = 0
var _registered_manager: Node = null


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	if not is_in_group(&"reeeplay_tracked"):
		add_to_group(&"reeeplay_tracked")
	if auto_track:
		var mgr := _find_manager()
		if mgr != null and mgr.has_method("is_recording") and bool(mgr.call("is_recording")):
			register_now_with(mgr)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if despawn_on_exit and entity_id > 0:
		var mgr := _find_manager()
		if mgr != null and mgr.has_method("untrack"):
			mgr.call("untrack", get_effective_target())
	entity_id = 0


func get_effective_target() -> Node:
	return target_node if target_node != null else get_parent()


func register_now() -> int:
	return register_now_with(_find_manager())


func register_now_with(mgr: Node, force: bool = false) -> int:
	if not force and entity_id > 0 and _registered_manager == mgr:
		return entity_id
	var target := get_effective_target()
	if target == null:
		return 0
	if mgr == null or not mgr.has_method("track"):
		return 0

	var arch_id := archetype_id
	if archetype != null and archetype.archetype_id != &"":
		if mgr.has_method("register_archetype"):
			mgr.call("register_archetype", archetype)
		if arch_id == &"":
			arch_id = archetype.archetype_id
	if arch_id == &"":
		if target is Node3D:
			arch_id = &"Node3D"
		elif target is Node2D:
			arch_id = &"Node2D"
		else:
			arch_id = StringName(target.get_class())

	var opts := {
		"stable_key": stable_key,
		"display_name": display_name if not display_name.is_empty() else target.name,
		"player_id": player_id,
		"team_id": team_id,
		"priority": priority,
		"channels": custom_channels,
		"proxy_scene": proxy_scene,
		"sample_rate": sample_rate,
	}
	entity_id = int(mgr.call("track", target, arch_id, opts))
	_registered_manager = mgr if entity_id > 0 else null
	return entity_id


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if get_effective_target() == null:
		warnings.append("REEEplayTracked needs a parent node or assigned target_node.")
	if proxy_scene == null and (archetype == null or archetype.proxy_scene == null) and not fallback_to_source_scene:
		warnings.append("No proxy_scene assigned and fallback_to_source_scene is disabled.")
	var total_channels := custom_channels.size() + (archetype.channels.size() if archetype != null else 0)
	if total_channels > 64:
		warnings.append("More than 64 channels configured; maximum recommended is 64.")
	return warnings


func _find_manager() -> Node:
	if not is_inside_tree():
		return null
	var scene_root := get_tree().current_scene
	if scene_root != null:
		var found := _find_recording_session(scene_root)
		if found != null:
			return found
	return get_tree().root.get_node_or_null("REEEplay")


static func _find_recording_session(node: Node) -> Node:
	if node is REEEplaySession and (node as REEEplaySession).is_recording():
		return node
	for child in node.get_children():
		var hit := _find_recording_session(child)
		if hit != null:
			return hit
	return null

