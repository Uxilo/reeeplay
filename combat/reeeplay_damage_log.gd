class_name REEEplayDamageLog
extends RefCounted
## Indexed combat ledger supporting death recaps, attacker attribution, DPS, and TTK queries.

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
		var vid := e.target.entity_id if e.target != null else e.secondary_entity_id
		if vid == victim_entity_id:
			out.append(e)
	return out


func entries_by_attacker(attacker_entity_id: int, from_tick: int = 0, to_tick: int = 2147483647) -> Array[REEEplayDamageEntry]:
	var out: Array[REEEplayDamageEntry] = []
	for e in entries:
		if e.tick < from_tick or e.tick > to_tick:
			continue
		var aid := e.actor.entity_id if e.actor != null else e.entity_id
		if aid == attacker_entity_id:
			out.append(e)
	return out


func total_damage_by_entity(attacker_entity_id: int, from_tick: int = 0, to_tick: int = 2147483647) -> float:
	var total := 0.0
	for e in entries_by_attacker(attacker_entity_id, from_tick, to_tick):
		if not e.is_heal:
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
		if e.is_heal:
			continue
		dmg += e.amount
		first_t = mini(first_t, e.tick)
		last_t = maxi(last_t, e.tick)
	if dmg <= 0.0 or last_t < first_t:
		return 0.0
	var span_ticks := maxi(1, (to_tick - from_tick) if to_tick >= from_tick else (last_t - first_t + 1))
	var duration_sec := maxf(1.0 / float(maxi(1, tick_rate)), float(span_ticks) / float(maxi(1, tick_rate)))
	return dmg / duration_sec


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
	for e in relevant:
		if not e.is_heal:
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
	var killer_id := killer.entity_id if killer != null else -1

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
	var by_attacker: Dictionary = {}
	var by_source: Dictionary = {}
	var by_damage_type: Dictionary = {}
	var assist_ids: Dictionary[int, REEEplayActorRef] = {}

	for e in damage_entries:
		total_damage += e.amount
		var aid := e.actor.entity_id if e.actor != null else e.entity_id
		var a_key := String(e.actor.display_name) if (e.actor != null and not e.actor.display_name.is_empty()) else ("Entity_%d" % aid)
		by_attacker[a_key] = float(by_attacker.get(a_key, 0.0)) + e.amount

		var src := e.source_name if not e.source_name.is_empty() else "Unknown"
		by_source[src] = float(by_source.get(src, 0.0)) + e.amount

		var dt := String(e.damage_type)
		by_damage_type[dt] = float(by_damage_type.get(dt, 0.0)) + e.amount

		if e.tick >= combat_start_tick and aid > 0 and aid != killer_id and aid != victim_entity_id:
			if not assist_ids.has(aid):
				assist_ids[aid] = e.actor if e.actor != null else REEEplayActorRef.create(aid)

	var assists: Array[REEEplayActorRef] = []
	for aid in assist_ids:
		assists.append(assist_ids[aid])

	var ttk_seconds := float(maxi(0, death_tick - combat_start_tick)) / float(rate)
	return {
		"victim_id": victim_entity_id,
		"death_tick": death_tick,
		"combat_start_tick": combat_start_tick,
		"killing_blow": killing_blow,
		"killer": killer,
		"assists": assists,
		"total_damage": total_damage,
		"ttk_seconds": ttk_seconds,
		"time_window_seconds": win_sec,
		"by_attacker": by_attacker,
		"by_source": by_source,
		"by_damage_type": by_damage_type,
		"entries": relevant,
	}


func slice(from_tick: int, to_tick: int) -> REEEplayDamageLog:
	var out := REEEplayDamageLog.new()
	for e in entries:
		if e.tick >= from_tick and e.tick <= to_tick:
			out.add_entry(e)
	return out
