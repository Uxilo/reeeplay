class_name REEEplayDamageTracker
extends RefCounted
## Live combat tracker capturing multi-attacker damage, multi-healer healing, and environmental hazards.

signal entry_recorded(entry: REEEplayDamageEntry)

var log: REEEplayDamageLog = REEEplayDamageLog.new()
var _next_hit_id: int = 1
var _tick_provider: Callable = Callable()
var _actor_resolver: Callable = Callable()
var _event_sink: Callable = Callable()
var _connected_routers: Array[Dictionary] = []


func configure(
	tick_provider: Callable,
	actor_resolver: Callable = Callable(),
	event_sink: Callable = Callable()
) -> void:
	_tick_provider = tick_provider
	_actor_resolver = actor_resolver
	_event_sink = event_sink


func reset() -> void:
	log.clear()
	_next_hit_id = 1


func record_damage(
	attacker: Variant,
	victim: Variant,
	amount: float,
	damage_type: StringName = &"physical",
	source_name: String = "",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	return _record_internal(false, attacker, victim, amount, damage_type, source_name, options)


func record_heal(
	healer: Variant,
	target_entity: Variant,
	amount: float,
	source_name: String = "",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	var dmg_type := StringName(options.get("damage_type", &"heal"))
	return _record_internal(true, healer, target_entity, amount, dmg_type, source_name, options)


## Records environmental / hazard damage (e.g. lava, fall, trap) attributed to the environment.
func record_environmental_damage(
	victim: Variant,
	amount: float,
	damage_type: StringName = &"environment",
	source_name: String = "Environment",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	var opts := options.duplicate()
	opts["is_environmental"] = true
	var env_name := str(opts.get("environment_name", source_name if not source_name.is_empty() else "Environment"))
	var env_actor := opts.get("environment_actor", REEEplayActorRef.environmental(env_name))
	return _record_internal(false, env_actor, victim, amount, damage_type, source_name, opts)


## Records environmental healing (e.g. healing fountain, shrine, regeneration zone).
func record_environmental_heal(
	target_entity: Variant,
	amount: float,
	source_name: String = "Environment",
	options: Dictionary = {}
) -> REEEplayDamageEntry:
	var opts := options.duplicate()
	opts["is_environmental"] = true
	var env_name := str(opts.get("environment_name", source_name if not source_name.is_empty() else "Environment"))
	var env_actor := opts.get("environment_actor", REEEplayActorRef.environmental(env_name))
	return _record_internal(true, env_actor, target_entity, amount, StringName(opts.get("damage_type", &"heal")), source_name, opts)


func get_actor_summary(actor_or_id: Variant, from_tick: int = 0, to_tick: int = 2147483647) -> Dictionary:
	var ref := _resolve_actor(actor_or_id)
	var key := ref.actor_key() if ref != null else "entity:0"
	return log.get_actor_summary(key, from_tick, to_tick)


## Connects to a YeetNativeHitboxRouter (or any Node emitting hit events) without hard compile dependency.
func connect_yeet_router(router: Object, signal_name: StringName = &"hit_occurred") -> bool:
	if router == null or not router.has_signal(signal_name):
		return false
	var cb := _on_yeet_hit_signal.bind()
	if not router.is_connected(signal_name, cb):
		router.connect(signal_name, cb)
		_connected_routers.append({"object": router, "signal": signal_name, "callable": cb})
	return true


func disconnect_all_routers() -> void:
	for rec in _connected_routers:
		var obj: Object = rec["object"]
		var sig: StringName = rec["signal"]
		var cb: Callable = rec["callable"]
		if is_instance_valid(obj) and obj.is_connected(sig, cb):
			obj.disconnect(sig, cb)
	_connected_routers.clear()


func _record_internal(
	p_is_heal: bool,
	p_attacker: Variant,
	p_victim: Variant,
	p_amount: float,
	p_damage_type: StringName,
	p_source_name: String,
	options: Dictionary
) -> REEEplayDamageEntry:
	var entry := REEEplayDamageEntry.new()
	entry.hit_id = _next_hit_id
	_next_hit_id += 1
	entry.tick = int(options.get("tick", _current_tick()))
	entry.kind = REEEplayDamageEntry.Kind.HEAL if p_is_heal else (int(options.get("kind", REEEplayDamageEntry.Kind.DAMAGE)) as REEEplayDamageEntry.Kind)
	entry.amount = p_amount
	entry.raw_amount = float(options.get("raw_amount", p_amount))
	entry.absorbed = float(options.get("absorbed", maxf(0.0, entry.raw_amount - p_amount)))
	entry.damage_type = p_damage_type
	entry.source_name = p_source_name
	entry.hit_zone = StringName(options.get("hit_zone", &""))
	entry.is_critical = bool(options.get("is_critical", false))
	entry.is_killing_blow = bool(options.get("is_killing_blow", false))
	entry.victim_hp_before = float(options.get("victim_hp_before", 0.0))
	entry.victim_hp_after = float(options.get("victim_hp_after", 0.0))
	entry.position = options.get("position", null)

	entry.attacker = _resolve_actor(p_attacker, p_source_name)
	entry.victim = _resolve_actor(p_victim)

	var is_env := bool(options.get("is_environmental", false))
	if entry.attacker != null and entry.attacker.is_environmental:
		is_env = true
	elif p_attacker == null:
		is_env = true
	elif (p_attacker is String or p_attacker is StringName) and (entry.attacker == null or entry.attacker.entity_id <= 0):
		is_env = true
	elif p_attacker is Node and is_instance_valid(p_attacker):
		var n := p_attacker as Node
		if n.is_in_group(&"environment") or n.is_in_group(&"hazard"):
			is_env = true

	entry.is_environmental = is_env
	if is_env and entry.attacker != null:
		entry.attacker.is_environmental = true
		entry.attacker.is_anonymous = true
		if entry.attacker.display_name.is_empty():
			entry.attacker.display_name = p_source_name if not p_source_name.is_empty() else "Environment"

	if entry.position == null and p_victim is Node3D:
		var v3 := p_victim as Node3D
		entry.position = v3.global_position if v3.is_inside_tree() else v3.position
	elif entry.position == null and p_victim is Node2D:
		var v2 := p_victim as Node2D
		entry.position = v2.global_position if v2.is_inside_tree() else v2.position

	var tags_out: Array[StringName] = []
	if entry.is_killing_blow:
		entry.importance = 3.0
		tags_out = [&"kill", &"combat"]
	elif entry.is_critical:
		entry.importance = 2.0
		tags_out = [&"crit", &"combat"]
	else:
		entry.importance = 0.5 if p_is_heal else 1.0
		tags_out = [&"heal" if p_is_heal else &"combat"]
	if is_env:
		tags_out.append(&"environment")
	entry.tags = tags_out

	log.add_entry(entry)
	if _event_sink.is_valid():
		_event_sink.call(entry)
	entry_recorded.emit(entry)
	return entry


func _current_tick() -> int:
	if _tick_provider.is_valid():
		return int(_tick_provider.call())
	return 0


func _resolve_actor(actor_or_node: Variant, fallback_env_label: String = "") -> REEEplayActorRef:
	if actor_or_node is REEEplayActorRef:
		return actor_or_node as REEEplayActorRef
	if _actor_resolver.is_valid():
		var resolved: Variant = _actor_resolver.call(actor_or_node)
		if resolved is REEEplayActorRef:
			return resolved as REEEplayActorRef
	if actor_or_node is int:
		return REEEplayActorRef.create(int(actor_or_node))
	if actor_or_node is Node:
		var node := actor_or_node as Node
		var is_env := node.is_in_group(&"environment") or node.is_in_group(&"hazard")
		return REEEplayActorRef.create(0, node.name, "", -1, &"", is_env)
	if actor_or_node == null:
		var env_name := fallback_env_label if not fallback_env_label.is_empty() else "Environment"
		return REEEplayActorRef.environmental(env_name)
	if actor_or_node is String or actor_or_node is StringName:
		var label := String(actor_or_node)
		return REEEplayActorRef.environmental(label if not label.is_empty() else "Environment")
	return REEEplayActorRef.create(0, str(actor_or_node))


func _on_yeet_hit_signal(hit_payload: Variant) -> void:
	if hit_payload == null:
		return
	var attacker_v: Variant = null
	var victim_v: Variant = null
	var dmg := 0.0
	var dmg_type: StringName = &"melee"
	var src := "yeet_hitbox"
	var opts := {}

	if hit_payload is Dictionary:
		var d: Dictionary = hit_payload
		attacker_v = d.get("attacker", d.get("source", null))
		victim_v = d.get("victim", d.get("target", null))
		dmg = float(d.get("damage", d.get("amount", 0.0)))
		dmg_type = StringName(d.get("damage_type", &"melee"))
		src = str(d.get("move_name", d.get("source_name", "yeet_hitbox")))
		if d.has("hit_position"):
			opts["position"] = d["hit_position"]
		if d.has("hit_zone"):
			opts["hit_zone"] = d["hit_zone"]
		if d.has("is_critical"):
			opts["is_critical"] = bool(d["is_critical"])
		if d.has("is_killing_blow"):
			opts["is_killing_blow"] = bool(d["is_killing_blow"])
		if bool(d.get("is_environmental", false)) or attacker_v == null:
			opts["is_environmental"] = true
	elif hit_payload is Object:
		var obj := hit_payload as Object
		attacker_v = obj.get(&"attacker")
		victim_v = obj.get(&"victim")
		var raw_dmg: Variant = obj.get(&"damage")
		dmg = float(raw_dmg) if raw_dmg != null else 0.0
		var pos_v: Variant = obj.get(&"hit_position")
		if pos_v != null:
			opts["position"] = pos_v
		var hz: Variant = obj.get(&"hit_zone")
		if hz != null:
			opts["hit_zone"] = StringName(hz)
		if attacker_v == null:
			opts["is_environmental"] = true

	record_damage(attacker_v, victim_v, dmg, dmg_type, src, opts)
