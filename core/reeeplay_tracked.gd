class_name REEEplayTracked
extends Node
## Drop-in child component that automatically registers its target node with REEEplay when active.

@export var auto_track: bool = true
@export var archetype_id: StringName = &""
@export var target_node: Node = null
@export var stable_key: StringName = &""
@export var display_name: String = ""
@export var player_id: String = ""
@export var team_id: int = -1
@export var priority: int = 0
@export var custom_channels: Array[REEEplayChannel] = []
@export var despawn_on_exit: bool = true

var entity_id: int = 0


func _enter_tree() -> void:
	if Engine.is_editor_hint() or not auto_track:
		return
	register_now()


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
	var target := get_effective_target()
	if target == null:
		return 0
	var mgr := _find_manager()
	if mgr == null or not mgr.has_method("track"):
		return 0

	var arch_id := archetype_id
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
	}
	entity_id = int(mgr.call("track", target, arch_id, opts))
	return entity_id


func _find_manager() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("REEEplay")

