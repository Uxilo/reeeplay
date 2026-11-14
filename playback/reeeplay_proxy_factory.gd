class_name REEEplayProxyFactory
extends RefCounted
## Instantiates and sanitizes playback proxy nodes, disabling gameplay scripts, physics, and yeet-cpp runtimes.

const _YEET_CPP_CLASSES: Dictionary[StringName, bool] = {
	&"YeetNativeController": true,
	&"YeetNativeScheduler": true,
	&"YeetNativeHitboxRouter": true,
	&"YeetNativeFoleyPlayer": true,
	&"YeetNativePoseSampler": true,
	&"YeetNativeUnisonBridge": true,
}


## Creates a sanitized proxy Node for info using registered archetypes or scene fallback.
static func create_proxy(info: REEEplayEntityInfo, archetypes: Dictionary = {}) -> Node:
	if info == null:
		return Node3D.new()

	var arch: REEEplayArchetype = archetypes.get(info.archetype_id, null) as REEEplayArchetype
	var proxy: Node = null
	var strip_physics := arch.strip_physics if arch != null else true
	var strip_scripts := arch.strip_scripts if arch != null else false

	if arch != null and arch.proxy_factory.is_valid():
		proxy = arch.proxy_factory.call(info) as Node
	elif arch != null and arch.proxy_scene != null:
		proxy = arch.proxy_scene.instantiate()
	elif not info.scene_path.is_empty() and ResourceLoader.exists(info.scene_path):
		var packed := ResourceLoader.load(info.scene_path) as PackedScene
		if packed != null:
			proxy = packed.instantiate()

	if proxy == null:
		proxy = _create_fallback_node(info, arch)

	sanitize_node(proxy, strip_physics, strip_scripts)
	proxy.name = "Proxy_%d_%s" % [info.entity_id, info.display_name if not info.display_name.is_empty() else "Entity"]
	return proxy


## Recursively strips/disables physics bodies, colliders, cameras, REEEplayTracked nodes, and yeet-cpp runtime nodes.
static func sanitize_node(node: Node, strip_physics: bool = true, strip_scripts: bool = false) -> void:
	if node == null:
		return

	# Snapshot children since REEEplayTracked components may be detached.
	var children := node.get_children()
	for child in children:
		if child is REEEplayTracked:
			child.set(&"auto_track", false)
			node.remove_child(child)
			child.queue_free()
		else:
			sanitize_node(child, strip_physics, strip_scripts)

	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	node.set_process_shortcut_input(false)

	var native_cls := StringName(node.get_class())
	if _YEET_CPP_CLASSES.has(native_cls):
		node.process_mode = Node.PROCESS_MODE_DISABLED
		node.set_process(false)
		node.set_physics_process(false)
		if "enabled" in node:
			node.set(&"enabled", false)
		if "active" in node:
			node.set(&"active", false)

	if strip_physics:
		if node is CollisionShape3D:
			(node as CollisionShape3D).disabled = true
		elif node is CollisionPolygon3D:
			(node as CollisionPolygon3D).disabled = true
		elif node is CollisionShape2D:
			(node as CollisionShape2D).disabled = true
		elif node is CollisionPolygon2D:
			(node as CollisionPolygon2D).disabled = true
		elif node is Area3D:
			var a3 := node as Area3D
			a3.monitoring = false
			a3.monitorable = false
		elif node is Area2D:
			var a2 := node as Area2D
			a2.monitoring = false
			a2.monitorable = false
		elif node is RigidBody3D:
			var rb3 := node as RigidBody3D
			rb3.freeze = true
			rb3.collision_layer = 0
			rb3.collision_mask = 0
			rb3.set_physics_process(false)
		elif node is RigidBody2D:
			var rb2 := node as RigidBody2D
			rb2.freeze = true
			rb2.collision_layer = 0
			rb2.collision_mask = 0
			rb2.set_physics_process(false)
		elif node is PhysicsBody3D:
			var pb3 := node as PhysicsBody3D
			pb3.collision_layer = 0
			pb3.collision_mask = 0
			pb3.set_physics_process(false)
		elif node is PhysicsBody2D:
			var pb2 := node as PhysicsBody2D
			pb2.collision_layer = 0
			pb2.collision_mask = 0
			pb2.set_physics_process(false)

	if node is Camera3D:
		(node as Camera3D).current = false
	elif node is Camera2D:
		(node as Camera2D).enabled = false

	if strip_scripts and node.get_script() != null:
		node.set_script(null)


static func _create_fallback_node(info: REEEplayEntityInfo, arch: REEEplayArchetype) -> Node:
	if arch != null and arch.proxy_script != null and arch.proxy_script.can_instantiate():
		var inst: Variant = arch.proxy_script.new()
		if inst is Node:
			return inst as Node

	# Infer dimensionality from channel codecs.
	for c in info.channel_codecs:
		if c == REEEplayCodec.Id.VEC3_F32 or c == REEEplayCodec.Id.VEC3_Q16 or c == REEEplayCodec.Id.TRANSFORM3D or c == REEEplayCodec.Id.QUAT_S3:
			return Node3D.new()
		if c == REEEplayCodec.Id.VEC2_F32 or c == REEEplayCodec.Id.VEC2_Q16 or c == REEEplayCodec.Id.TRANSFORM2D:
			return Node2D.new()

	if info.archetype_id == &"Node2D":
		return Node2D.new()
	if info.archetype_id == &"Node":
		return Node.new()
	return Node3D.new()

