class_name REEEplaySceneCue
extends REEEplayCue
## Built-in playback cue spawning a sanitized visual scene (VFX, muzzle flash, impact).

var scene_path: String = ""
var attach_to_entity: bool = false
var scale_vec: Vector3 = Vector3.ONE
var auto_free_seconds: float = 3.0


func _init() -> void:
	super._init()
	type_id = &"REEEplaySceneCue"
	is_timeline_visible = false


func get_type_id() -> StringName:
	return &"REEEplaySceneCue"


func _serialize(ser: REEEplaySerializer) -> void:
	ser.write_string(scene_path)
	ser.write_bool(attach_to_entity)
	ser.write_vec3(scale_vec)
	ser.write_float(auto_free_seconds)


func _deserialize(ser: REEEplaySerializer, _from_version: int) -> void:
	scene_path = ser.read_string()
	attach_to_entity = ser.read_bool()
	scale_vec = ser.read_vec3()
	auto_free_seconds = ser.read_float()


func _on_playback_forward(player_node: Node) -> void:
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		return
	var instance := packed.instantiate()
	if instance == null:
		return
	REEEplayProxyFactory.sanitize_node(instance, true, true)

	var parent_node: Node = null
	if attach_to_entity and entity_id > 0 and player_node.has_method("get_proxy"):
		parent_node = player_node.call("get_proxy", entity_id) as Node
	if parent_node == null and player_node.has_method("get_cue_host"):
		parent_node = player_node.call("get_cue_host") as Node
	if parent_node == null:
		parent_node = player_node

	parent_node.add_child(instance)
	if instance is Node3D:
		var n3 := instance as Node3D
		if position is Vector3 and not attach_to_entity:
			n3.global_position = position as Vector3
		n3.scale = scale_vec
	elif instance is Node2D:
		var n2 := instance as Node2D
		if position is Vector2 and not attach_to_entity:
			n2.global_position = position as Vector2
		n2.scale = Vector2(scale_vec.x, scale_vec.y)

	if auto_free_seconds > 0.0 and instance.is_inside_tree():
		var timer := instance.get_tree().create_timer(auto_free_seconds)
		timer.timeout.connect(func() -> void:
			if is_instance_valid(instance):
				instance.queue_free()
		)
