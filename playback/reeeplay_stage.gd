class_name REEEplayStage
extends Node3D
## Isolated 3D host scene node managing playback proxies and ephemeral cue visuals.

var entity_root: Node3D
var cue_root: Node3D


func _init() -> void:
	entity_root = Node3D.new()
	entity_root.name = "Entities"
	add_child(entity_root)

	cue_root = Node3D.new()
	cue_root.name = "Cues"
	add_child(cue_root)


func clear_all() -> void:
	for child in entity_root.get_children():
		child.queue_free()
	for child in cue_root.get_children():
		child.queue_free()

