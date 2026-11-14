@tool
class_name REEEplayChannel
extends Resource
## Describes a single recorded property or custom sampled channel on a REEEplay archetype.

@export var name: StringName = &""
@export var property_path: String = ""
@export var codec: REEEplayCodec.Id = REEEplayCodec.Id.AUTO
@export var epsilon: float = 0.0
@export var quantize_step: float = 0.001
@export var interpolate: bool = true
@export var rate_divider: int = 1

## Optional runtime sampler hook: func(target: Node) -> Variant
var getter: Callable = Callable()
## Optional runtime playback applicator hook: func(proxy: Node, value: Variant) -> void
var setter: Callable = Callable()


## Convenience constructor for defining channels in code.
static func create(
	p_property_path: String,
	p_codec: REEEplayCodec.Id = REEEplayCodec.Id.AUTO,
	p_epsilon: float = 0.0,
	p_interpolate: bool = true,
	p_name: StringName = &"",
	p_quantize_step: float = 0.001,
	p_rate_divider: int = 1
) -> REEEplayChannel:
	var ch := REEEplayChannel.new()
	ch.name = p_name if p_name != &"" else StringName(p_property_path)
	ch.property_path = p_property_path
	ch.codec = p_codec
	ch.epsilon = p_epsilon
	ch.interpolate = p_interpolate
	ch.quantize_step = p_quantize_step
	ch.rate_divider = maxi(1, p_rate_divider)
	return ch


## Returns the canonical channel identifier.
func effective_name() -> StringName:
	if name != &"":
		return name
	return StringName(property_path)


## Samples this channel from target using custom getter or Node.get_indexed().
func sample_from(target: Node) -> Variant:
	if getter.is_valid():
		return getter.call(target)
	if target == null or property_path.is_empty():
		return null
	var eff_path := _resolve_tree_safe_path(target, property_path)
	if eff_path.contains(":"):
		return target.get_indexed(NodePath(eff_path))
	return target.get(StringName(eff_path))


## Applies a decoded/interpolated value onto proxy using custom setter or Node.set_indexed().
func apply_to(proxy: Node, value: Variant) -> void:
	if setter.is_valid():
		setter.call(proxy, value)
		return
	if proxy == null or property_path.is_empty():
		return
	var eff_path := _resolve_tree_safe_path(proxy, property_path)
	if eff_path.contains(":"):
		proxy.set_indexed(NodePath(eff_path), value)
	else:
		proxy.set(StringName(eff_path), value)


static func _resolve_tree_safe_path(node: Node, raw_path: String) -> String:
	if node.is_inside_tree():
		return raw_path
	match raw_path:
		"global_position":
			return "position"
		"global_rotation":
			return "rotation"
		"global_transform":
			return "transform"
		_:
			return raw_path
