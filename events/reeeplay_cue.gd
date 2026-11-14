@abstract
class_name REEEplayCue
extends REEEplayEvent
## Base class for fire-and-forget playback cues (audio, VFX scenes, camera shakes).

var duration: float = 0.0
var dispatch_on_seek: bool = false


func _init() -> void:
	category = &"cue"


## Called by REEEplayPlayer when forward playback crosses this cue's tick.
func _on_playback_forward(_player: Node) -> void:
	pass


## Optional hook called when reverse playback crosses this cue's tick.
func _on_playback_reverse(_player: Node) -> void:
	pass
