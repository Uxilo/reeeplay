class_name REEEplayDamageLog
extends RefCounted
## Indexed combat ledger supporting multi-dealer, multi-healer, multi-source, and environmental queries.

var entries: Array[REEEplayDamageEntry] = []


func add_entry(entry: REEEplayDamageEntry) -> void:
	if entry == null:
		return
	entries.append(entry)


func clear() -> void:
	entries.clear()


func size() -> int:
	return entries.size()


## Builds a REEEplayDamageLog from any damage entries present inside an event array.
static func from_events(events: Array[REEEplayEvent]) -> REEEplayDamageLog:
	var log := REEEplayDamageLog.new()
	for ev in events:
		if ev is REEEplayDamageEntry:
			log.add_entry(ev as REEEplayDamageEntry)
	return log


func entries_for_victim(victim_entity_id: int, from_tick: int = 0, to_tick: int = 2147483647) -> Array[REEEplayDamageEntry]:
	var out: Array[REEEplayDamageEntry] = []
	for e in entries:
		if e.tick < from_tick or e.tick > to_tick:
			continue
		if victim_entity_id < 0 or _victim_entity_id(e) == victim_entity_id:
			out.append(e)
	return out


func entries_by_attacker(attacker_entity_id: int, from_tick: int = 0, to_tick: int = 2147483647) -> Array[REEEplayDamageEntry]:
	var out: Array[REEEplayDamageEntry] = []
	for e in entries:
		if e.tick < from_tick or e.tick > to_tick:
			continue
		if _actor_entity_id(e) == attacker_entity_id:
			out.append(e)
	return out


## Returns all environmental damage/heal entries, optionally scoped to victim_entity_id (>= 0) and tick range.
func entries_from_environment(victim_entity_id: int = -1, from_tick: int = 0, to_tick: int = 2147483647) -> Array[REEEplayDamageEntry]:
	var out: Array[REEEplayDamageEntry] = []
	for e in entries:
		if e.tick < from_tick or e.tick > to_tick:
			continue
		if not _is_entry_env(e):
			continue
		if victim_entity_id < 0 or _victim_entity_id(e) == victim_entity_id:
			out.append(e)
	return out


func total_damage_by_entity(attacker_entity_id: int, from_tick: int = 0, to_tick: int = 2147483647) -> float:
	var total := 0.0
	for e in entries_by_attacker(attacker_entity_id, from_tick, to_tick):
		if _is_entry_damage(e):
			total += e.amount
	return total


func total_healing_by_entity(healer_entity_id: int, from_tick: int = 0, to_tick: int = 2147483647) -> float:
	var total := 0.0
	for e in entries_by_attacker(healer_entity_id, from_tick, to_tick):
		if e.is_heal:
			total += e.amount
	return total


func dps_for_attacker(attacker_entity_id: int, tick_rate: int, from_tick: int = 0, to_tick: int = -1) -> float:
	var effective_to := to_tick if to_tick >= 0 else 2147483647
	var list := entries_by_attacker(attacker_entity_id, from_tick, effective_to)
	var dmg := 0.0
	var first_t := 2147483647
	var last_t := -1
	for e in list:
		if not _is_entry_damage(e):
			continue
		dmg += e.amount
		first_t = mini(first_t, e.tick)
		last_t = maxi(last_t, e.tick)
	if dmg <= 0.0 or last_t < first_t:
		return 0.0
	var span_ticks := maxi(1, (to_tick - from_tick) if to_tick >= from_tick else (last_t - first_t + 1))
	var duration_sec := maxf(1.0 / float(maxi(1, tick_rate)), float(span_ticks) / float(maxi(1, tick_rate)))
	return dmg / duration_sec


## Aggregates all damage dealers (entities and distinct environmental sources) sorted by total_damage descending.
func get_damage_dealers(victim_entity_id: int = -1, from_tick: int = 0, to_tick: int = 2147483647) -> Array[Dictionary]:
	var by_key: Dictionary[String, Dictionary] = {}
	for e in entries_for_victim(victim_entity_id, from_tick, to_tick):
		if not _is_entry_damage(e):
			continue
		var akey := _entry_actor_key(e)
		if not by_key.has(akey):
			by_key[akey] = {
				"actor": e.actor,
				"actor_key": akey,
				"display_name": _entry_actor_name(e),
				"entity_id": _actor_entity_id(e),
				"is_environmental": _is_entry_env(e),
				"total_damage": 0.0,
				"hit_count": 0,
				"sources": {},
				"damage_types": {},
			}
		var rec: Dictionary = by_key[akey]
		rec["total_damage"] = float(rec["total_damage"]) + e.amount
		rec["hit_count"] = int(rec["hit_count"]) + 1
		var src := e.source_name if not e.source_name.is_empty() else "Unknown"
		var srcs: Dictionary = rec["sources"]
		srcs[src] = float(srcs.get(src, 0.0)) + e.amount
		var dt := String(e.damage_type)
		var dts: Dictionary = rec["damage_types"]
		dts[dt] = float(dts.get(dt, 0.0)) + e.amount

	var out: Array[Dictionary] = []
	for k in by_key:
		out.append(by_key[k])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["total_damage"]) > float(b["total_damage"])
	)
	return out


## Aggregates all healers (allied, self, and environmental sources) sorted by total_healing descending.
func get_healers(victim_entity_id: int = -1, from_tick: int = 0, to_tick: int = 2147483647) -> Array[Dictionary]:
	var by_key: Dictionary[String, Dictionary] = {}
	for e in entries_for_victim(victim_entity_id, from_tick, to_tick):
		if not e.is_heal:
			continue
		var akey := _entry_actor_key(e)
		var is_env := _is_entry_env(e)
		var aid := _actor_entity_id(e)
		var vid := _victim_entity_id(e)
		var is_self := (not is_env) and aid > 0 and aid == vid
		if not by_key.has(akey):
			by_key[akey] = {
				"actor": e.actor,
				"actor_key": akey,
				"display_name": _entry_actor_name(e),
				"entity_id": aid,
				"is_environmental": is_env,
				"is_self_heal": is_self,
				"total_healing": 0.0,
				"heal_count": 0,
				"sources": {},
			}
		var rec: Dictionary = by_key[akey]
		rec["total_healing"] = float(rec["total_healing"]) + e.amount
		rec["heal_count"] = int(rec["heal_count"]) + 1
		if not is_self:
			rec["is_self_heal"] = false
		var src := e.source_name if not e.source_name.is_empty() else "Unknown"
		var srcs: Dictionary = rec["sources"]
		srcs[src] = float(srcs.get(src, 0.0)) + e.amount

	var out: Array[Dictionary] = []
	for k in by_key:
		out.append(by_key[k])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["total_healing"]) > float(b["total_healing"])
	)
	return out


## Aggregates every unique (actor_key, source_name, is_heal, is_environmental) combination sorted descending.
func get_sources_breakdown(victim_entity_id: int = -1, from_tick: int = 0, to_tick: int = 2147483647) -> Array[Dictionary]:
	var buckets: Dictionary[String, Dictionary] = {}
	for e in entries_for_victim(victim_entity_id, from_tick, to_tick):
		var akey := _entry_actor_key(e)
		var src := e.source_name if not e.source_name.is_empty() else "Unknown"
		var is_env := _is_entry_env(e)
		var bucket_key := "%s|%s|%d|%d" % [akey, src, 1 if e.is_heal else 0, 1 if is_env else 0]
		if not buckets.has(bucket_key):
			buckets[bucket_key] = {
				"actor": e.actor,
				"actor_key": akey,
				"display_name": _entry_actor_name(e),
				"entity_id": _actor_entity_id(e),
				"source_name": src,
				"is_heal": e.is_heal,
				"is_environmental": is_env,
				"total_amount": 0.0,
				"hit_count": 0,
				"damage_types": {},
			}
		var b: Dictionary = buckets[bucket_key]
		b["total_amount"] = float(b["total_amount"]) + e.amount
		b["hit_count"] = int(b["hit_count"]) + 1
		var dt := String(e.damage_type)
		var dts: Dictionary = b["damage_types"]
		dts[dt] = float(dts.get(dt, 0.0)) + e.amount

	var out: Array[Dictionary] = []
	for k in buckets:
		out.append(buckets[k])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["total_amount"]) > float(b["total_amount"])
	)
	return out


## Summarizes combat activity (dealt, healed, taken, healing received, and per-source maps) for one actor_key or entity_id.
func get_actor_summary(actor_key_or_id: Variant, from_tick: int = 0, to_tick: int = 2147483647) -> Dictionary:
	var target_key := ""
	var target_id := -1
	if actor_key_or_id is REEEplayActorRef:
		target_key = (actor_key_or_id as REEEplayActorRef).actor_key()
		target_id = (actor_key_or_id as REEEplayActorRef).entity_id
	elif actor_key_or_id is int:
		target_id = int(actor_key_or_id)
		target_key = "entity:%d" % target_id
	else:
		target_key = str(actor_key_or_id)

	var dmg_dealt := 0.0
	var heal_done := 0.0
	var dmg_taken := 0.0
	var heal_recv := 0.0
	var dmg_sources_used: Dictionary = {}
	var heal_sources_used: Dictionary = {}

	for e in entries:
		if e.tick < from_tick or e.tick > to_tick:
			continue
		var akey := _entry_actor_key(e)
		var aid := _actor_entity_id(e)
		var matches_actor := (akey == target_key) or (target_id > 0 and aid == target_id)
		var src := e.source_name if not e.source_name.is_empty() else "Unknown"
		if matches_actor:
			if e.is_heal:
				heal_done += e.amount
				heal_sources_used[src] = float(heal_sources_used.get(src, 0.0)) + e.amount
			elif _is_entry_damage(e):
				dmg_dealt += e.amount
				dmg_sources_used[src] = float(dmg_sources_used.get(src, 0.0)) + e.amount

		if target_id > 0 and _victim_entity_id(e) == target_id:
			if e.is_heal:
				heal_recv += e.amount
			elif _is_entry_damage(e):
				dmg_taken += e.amount

	return {
		"actor_key": target_key,
		"damage_dealt": dmg_dealt,
		"healing_done": heal_done,
		"damage_taken": dmg_taken,
		"healing_received": heal_recv,
		"damage_sources_used": dmg_sources_used,
		"heal_sources_used": heal_sources_used,
	}


## Computes a structured death recap for victim_entity_id ending at death_tick.
func death_recap(
	victim_entity_id: int,
	death_tick: int,
	tick_rate: int,
	window_seconds: float = -1.0,
	combat_timeout_seconds: float = -1.0
) -> Dictionary:
	var rate := maxi(1, tick_rate)
	var win_sec := window_seconds if window_seconds > 0.0 else float(REEEplaySettings.value(&"reeeplay/damage/recap_window_seconds"))
	var timeout_sec := combat_timeout_seconds if combat_timeout_seconds > 0.0 else float(REEEplaySettings.value(&"reeeplay/damage/combat_timeout_seconds"))

	var win_ticks := maxi(1, roundi(win_sec * float(rate)))
	var timeout_ticks := maxi(1, roundi(timeout_sec * float(rate)))
	var min_tick := maxi(0, death_tick - win_ticks)

	var relevant := entries_for_victim(victim_entity_id, min_tick, death_tick)
	relevant.sort_custom(func(a: REEEplayDamageEntry, b: REEEplayDamageEntry) -> bool:
		return a.tick < b.tick
	)

	var damage_entries: Array[REEEplayDamageEntry] = []
	var heal_entries: Array[REEEplayDamageEntry] = []
	for e in relevant:
		if e.is_heal:
			heal_entries.append(e)
		elif _is_entry_damage(e):
			damage_entries.append(e)

	var killing_blow: REEEplayDamageEntry = null
	for i in range(damage_entries.size() - 1, -1, -1):
		var candidate := damage_entries[i]
		if candidate.is_killing_blow:
			killing_blow = candidate
			break
	if killing_blow == null and not damage_entries.is_empty():
		killing_blow = damage_entries[damage_entries.size() - 1]

	var killer: REEEplayActorRef = killing_blow.attacker if killing_blow != null else null
	var killer_key := _entry_actor_key(killing_blow) if killing_blow != null else ""

	# Walk backward from death_tick using combat_timeout_ticks to find continuous combat start tick (TTK).
	var combat_start_tick := death_tick
	if not damage_entries.is_empty():
		combat_start_tick = damage_entries[damage_entries.size() - 1].tick
		for i in range(damage_entries.size() - 2, -1, -1):
			if (combat_start_tick - damage_entries[i].tick) <= timeout_ticks:
				combat_start_tick = damage_entries[i].tick
			else:
				break

	var total_damage := 0.0
	var env_damage := 0.0
	var by_attacker: Dictionary = {}
	var by_source: Dictionary = {}
	var by_damage_type: Dictionary = {}
	var environmental_sources: Dictionary = {}
	var by_actor_and_source: Dictionary = {}
	var assist_by_key: Dictionary[String, REEEplayActorRef] = {}

	for e in damage_entries:
		total_damage += e.amount
		var is_env := _is_entry_env(e)
		var aid := _actor_entity_id(e)
		var akey := _entry_actor_key(e)
		var a_name := _entry_actor_name(e)
		var src := e.source_name if not e.source_name.is_empty() else "Unknown"

		by_attacker[a_name] = float(by_attacker.get(a_name, 0.0)) + e.amount
		by_source[src] = float(by_source.get(src, 0.0)) + e.amount

		var dt := String(e.damage_type)
		by_damage_type[dt] = float(by_damage_type.get(dt, 0.0)) + e.amount

		if is_env:
			env_damage += e.amount
			environmental_sources[src] = float(environmental_sources.get(src, 0.0)) + e.amount

		var actor_srcs: Dictionary = by_actor_and_source.get(akey, {})
		actor_srcs[src] = float(actor_srcs.get(src, 0.0)) + e.amount
		by_actor_and_source[akey] = actor_srcs

		if e.tick >= combat_start_tick and akey != killer_key:
			if is_env or (aid > 0 and aid != victim_entity_id):
				if not assist_by_key.has(akey):
					assist_by_key[akey] = e.actor if e.actor != null else REEEplayActorRef.create(aid, a_name, "", -1, &"", is_env)

	var total_healing := 0.0
	var env_healing := 0.0
	var by_healer: Dictionary = {}
	var healing_by_source: Dictionary = {}
	for e in heal_entries:
		total_healing += e.amount
		var is_env := _is_entry_env(e)
		var akey := _entry_actor_key(e)
		var h_name := _entry_actor_name(e)
		var src := e.source_name if not e.source_name.is_empty() else "Unknown"

		by_healer[h_name] = float(by_healer.get(h_name, 0.0)) + e.amount
		healing_by_source[src] = float(healing_by_source.get(src, 0.0)) + e.amount
		if is_env:
			env_healing += e.amount
			environmental_sources[src] = float(environmental_sources.get(src, 0.0)) + e.amount

		var actor_srcs: Dictionary = by_actor_and_source.get(akey, {})
		actor_srcs[src] = float(actor_srcs.get(src, 0.0)) + e.amount
		by_actor_and_source[akey] = actor_srcs

	var assists: Array[REEEplayActorRef] = []
	for akey in assist_by_key:
		assists.append(assist_by_key[akey])

	var ttk_seconds := float(maxi(0, death_tick - combat_start_tick)) / float(rate)
	return {
		"victim_id": victim_entity_id,
		"death_tick": death_tick,
		"combat_start_tick": combat_start_tick,
		"killing_blow": killing_blow,
		"killer": killer,
		"assists": assists,
		"total_damage": total_damage,
		"total_healing": total_healing,
		"environmental_damage": env_damage,
		"environmental_healing": env_healing,
		"ttk_seconds": ttk_seconds,
		"time_window_seconds": win_sec,
		"by_attacker": by_attacker,
		"by_healer": by_healer,
		"by_source": by_source,
		"healing_by_source": healing_by_source,
		"by_damage_type": by_damage_type,
		"environmental_sources": environmental_sources,
		"by_actor_and_source": by_actor_and_source,
		"damage_dealers": get_damage_dealers(victim_entity_id, min_tick, death_tick),
		"healers": get_healers(victim_entity_id, min_tick, death_tick),
		"entries": relevant,
	}


func slice(from_tick: int, to_tick: int) -> REEEplayDamageLog:
	var out := REEEplayDamageLog.new()
	for e in entries:
		if e.tick >= from_tick and e.tick <= to_tick:
			out.add_entry(e)
	return out


static func _victim_entity_id(e: REEEplayDamageEntry) -> int:
	return e.target.entity_id if e.target != null else e.secondary_entity_id


static func _actor_entity_id(e: REEEplayDamageEntry) -> int:
	return e.actor.entity_id if e.actor != null else e.entity_id


static func _is_entry_damage(e: REEEplayDamageEntry) -> bool:
	return e.kind == REEEplayDamageEntry.Kind.DAMAGE and not e.is_heal


static func _is_entry_env(e: REEEplayDamageEntry) -> bool:
	return e.is_environmental or (e.actor != null and e.actor.is_environmental)


static func _entry_actor_key(e: REEEplayDamageEntry) -> String:
	if e.actor != null:
		var k := e.actor.actor_key()
		if e.is_environmental and not k.begins_with("env:"):
			return "env:%s" % k
		return k
	if e.is_environmental:
		return "env:%s" % (e.source_name if not e.source_name.is_empty() else "Environment")
	return "entity:%d" % e.entity_id


static func _entry_actor_name(e: REEEplayDamageEntry) -> String:
	if e.actor != null and not e.actor.display_name.is_empty():
		return e.actor.display_name
	if _is_entry_env(e):
		return e.source_name if not e.source_name.is_empty() else "Environment"
	return "Entity_%d" % _actor_entity_id(e)
