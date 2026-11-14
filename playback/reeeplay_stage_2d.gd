class_name REEEplayStage2D
extends Node2D
## Isolated 2D host scene node managing 2D playback proxies and ephemeral cue visuals.

var entity_root: Node2D
var cue_root: Node2D


func _init() -> void:
	entity_root = Node2D.new()
	entity_root.name = "Entities2D"
	add_child(entity_root)

	cue_root = Node2D.new()
	cue_root.name = "Cues2D"
	add_child(cue_root)


func clear_all() -> void:
	for child in entity_root.get_children():
		child.queue_free()
	for child in cue_root.get_children():
		child.queue_free()

