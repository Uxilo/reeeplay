class_name REEEplayEventRegistry
extends RefCounted
## Registry mapping event/cue/attachment type_ids (and legacy aliases) to Scripts, with binary envelope I/O.

var _types: Dictionary[StringName, Script] = {}
var _aliases: Dictionary[StringName, StringName] = {}
var _attachment_types: Dictionary[StringName, Script] = {}
var _attachment_aliases: Dictionary[StringName, StringName] = {}


func _init(auto_register: bool = true) -> void:
	if auto_register:
		register_builtin_types()
		if bool(REEEplaySettings.value(&"reeeplay/events/auto_register_global_classes")):
			scan_global_classes()


func register_builtin_types() -> void:
	register_type(&"REEEplayMarkerEvent", REEEplayMarkerEvent)
	register_type(&"REEEplayRecordingNote", REEEplayRecordingNote)
	register_type(&"REEEplaySoundCue", REEEplaySoundCue)
	register_type(&"REEEplaySceneCue", REEEplaySceneCue)
	register_type(&"REEEplayDamageEntry", REEEplayDamageEntry)


func register_type(
	type_id: StringName,
	script: Script,
	aliases: Array[StringName] = []
) -> void:
	if type_id == &"" or script == null:
		return
	_types[type_id] = script
	for a in aliases:
		if a != &"":
			_aliases[a] = type_id


func register_alias(old_type_id: StringName, current_type_id: StringName) -> void:
	if old_type_id != &"" and current_type_id != &"":
		_aliases[old_type_id] = current_type_id


func register_attachment_type(
	type_id: StringName,
	script: Script,
	aliases: Array[StringName] = []
) -> void:
	if type_id == &"" or script == null:
		return
	_attachment_types[type_id] = script
	for a in aliases:
		if a != &"":
			_attachment_aliases[a] = type_id


## Scans ProjectSettings.get_global_class_list() and registers concrete event/cue/attachment classes.
func scan_global_classes() -> int:
	var class_list := ProjectSettings.get_global_class_list()
	var by_name: Dictionary[StringName, Dictionary] = {}
	for entry in class_list:
		by_name[StringName(entry.get("class", &""))] = entry

	var count := 0
	for entry in class_list:
		var cname := StringName(entry.get("class", &""))
		if cname == &"" or _types.has(cname) or _attachment_types.has(cname):
			continue
		if cname == &"REEEplayEvent" or cname == &"REEEplayCue" or cname == &"REEEplayAttachment" or cname == &"REEEplayUnknownEvent":
			continue

		var kind := _classify_ancestor(cname, by_name)
		if kind.is_empty():
			continue
		var path := String(entry.get("path", ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			continue
		var scr := ResourceLoader.load(path) as Script
		if scr == null or scr.is_abstract():
			continue
		if kind == "event":
			_types[cname] = scr
			count += 1
		elif kind == "attachment":
			_attachment_types[cname] = scr
			count += 1
	return count


func resolve_script(type_id: StringName) -> Script:
	var canonical := _aliases.get(type_id, type_id)
	return _types.get(canonical, null)


func resolve_attachment_script(type_id: StringName) -> Script:
	var canonical := _attachment_aliases.get(type_id, type_id)
	return _attachment_types.get(canonical, null)


func create_event(type_id: StringName) -> REEEplayEvent:
	var scr := resolve_script(type_id)
	if scr == null or not scr.can_instantiate():
		return null
	return scr.new() as REEEplayEvent


func create_attachment(type_id: StringName) -> REEEplayAttachment:
	var scr := resolve_attachment_script(type_id)
	if scr == null or not scr.can_instantiate():
		return null
	return scr.new() as REEEplayAttachment


func serialize_event(buf: StreamPeerBuffer, ev: REEEplayEvent, string_table: REEEplayByteUtils.StringTable) -> void:
	var type_id := ev.get_type_id()
	var schema_ver := ev.get_schema_version()

	REEEplayByteUtils.put_varuint(buf, string_table.intern(type_id))
	REEEplayByteUtils.put_varuint(buf, maxi(0, schema_ver))
	REEEplayByteUtils.put_varuint(buf, maxi(0, ev.tick))
	REEEplayByteUtils.put_varuint(buf, maxi(0, ev.event_id))
	REEEplayByteUtils.put_varuint(buf, maxi(0, ev.entity_id))
	REEEplayByteUtils.put_varuint(buf, maxi(0, ev.secondary_entity_id))

	var flags := 0
	if ev.actor != null:
		flags |= 1
	if ev.target != null:
		flags |= 2
	if ev.position is Vector3:
		flags |= 4
	elif ev.position is Vector2:
		flags |= 8
	if ev.is_timeline_visible:
		flags |= 16
	if not ev.label.is_empty():
		flags |= 32
	if not ev.tags.is_empty():
		flags |= 64
	if not is_zero_approx(ev.timestamp):
		flags |= 128

	buf.put_u16(flags)
	if (flags & 1) != 0:
		ev.actor.serialize(buf, string_table)
	if (flags & 2) != 0:
		ev.target.serialize(buf, string_table)
	if (flags & 4) != 0:
		REEEplayCodec.encode(buf, ev.position as Vector3, REEEplayCodec.Id.VEC3_F32)
	elif (flags & 8) != 0:
		REEEplayCodec.encode(buf, ev.position as Vector2, REEEplayCodec.Id.VEC2_F32)
	if (flags & 32) != 0:
		REEEplayByteUtils.put_utf8(buf, ev.label)
	if (flags & 64) != 0:
		REEEplayByteUtils.put_varuint(buf, ev.tags.size())
		for t in ev.tags:
			REEEplayByteUtils.put_varuint(buf, string_table.intern(t))
	if (flags & 128) != 0:
		buf.put_float(ev.timestamp)

	REEEplayByteUtils.put_varuint(buf, string_table.intern(ev.category))
	buf.put_float(ev.importance)

	var payload_bytes: PackedByteArray
	if ev is REEEplayUnknownEvent:
		payload_bytes = (ev as REEEplayUnknownEvent).raw_payload
	else:
		var ser := REEEplaySerializer.new(true, PackedByteArray(), string_table, schema_ver)
		ev._serialize(ser)
		payload_bytes = ser.to_bytes()

	REEEplayByteUtils.put_varuint(buf, payload_bytes.size())
	if not payload_bytes.is_empty():
		buf.put_data(payload_bytes)


func deserialize_event(buf: StreamPeerBuffer, string_table: REEEplayByteUtils.StringTable) -> REEEplayEvent:
	var type_idx := REEEplayByteUtils.get_varuint(buf)
	if type_idx < 0:
		return null
	var raw_type_id := string_table.get_string(type_idx)
	var schema_ver := REEEplayByteUtils.get_varuint(buf)
	var tick := REEEplayByteUtils.get_varuint(buf)
	var event_id := REEEplayByteUtils.get_varuint(buf)
	var entity_id := REEEplayByteUtils.get_varuint(buf)
	var secondary_entity_id := REEEplayByteUtils.get_varuint(buf)
	var flags := buf.get_u16()

	var actor: REEEplayActorRef = null
	var target: REEEplayActorRef = null
	var position: Variant = null
	var label := ""
	var tags: Array[StringName] = []
	var timestamp := 0.0

	if (flags & 1) != 0:
		actor = REEEplayActorRef.deserialize(buf, string_table)
	if (flags & 2) != 0:
		target = REEEplayActorRef.deserialize(buf, string_table)
	if (flags & 4) != 0:
		position = REEEplayCodec.decode(buf, REEEplayCodec.Id.VEC3_F32)
	elif (flags & 8) != 0:
		position = REEEplayCodec.decode(buf, REEEplayCodec.Id.VEC2_F32)
	if (flags & 32) != 0:
		label = REEEplayByteUtils.get_utf8(buf)
	if (flags & 64) != 0:
		var tag_count := REEEplayByteUtils.get_varuint(buf)
		for _i in range(maxi(0, tag_count)):
			var tidx := REEEplayByteUtils.get_varuint(buf)
			tags.append(string_table.get_string(tidx))
	if (flags & 128) != 0:
		timestamp = buf.get_float()

	var cat_idx := REEEplayByteUtils.get_varuint(buf)
	var category := string_table.get_string(cat_idx)
	var importance := buf.get_float()

	var payload_len := REEEplayByteUtils.get_varuint(buf)
	var payload_bytes := PackedByteArray()
	if payload_len > 0 and payload_len <= 16777216 and payload_len <= buf.get_available_bytes():
		var res := buf.get_data(payload_len)
		if res[0] == OK:
			payload_bytes = res[1] as PackedByteArray

	var ev := create_event(raw_type_id)
	if ev == null:
		var unk := REEEplayUnknownEvent.new()
		unk.original_type_id = raw_type_id
		unk.original_schema_version = schema_ver
		unk.raw_payload = payload_bytes
		ev = unk
	else:
		var ser := REEEplaySerializer.new(false, payload_bytes, string_table, schema_ver)
		ev._deserialize(ser, schema_ver)

	ev.event_id = event_id
	ev.tick = tick
	ev.timestamp = timestamp
	ev.entity_id = entity_id
	ev.secondary_entity_id = secondary_entity_id
	ev.actor = actor
	ev.target = target
	ev.position = position
	ev.category = category
	ev.label = label
	ev.tags = tags
	ev.importance = importance
	ev.is_timeline_visible = (flags & 16) != 0
	return ev


func serialize_attachment(buf: StreamPeerBuffer, att: REEEplayAttachment, string_table: REEEplayByteUtils.StringTable) -> void:
	REEEplayByteUtils.put_varuint(buf, string_table.intern(att.get_type_id()))
	REEEplayByteUtils.put_varuint(buf, maxi(0, att.get_schema_version()))
	REEEplayByteUtils.put_varuint(buf, maxi(0, att.attachment_id))
	REEEplayByteUtils.put_varuint(buf, maxi(0, att.tick))
	REEEplayByteUtils.put_varuint(buf, maxi(0, att.entity_id))
	REEEplayByteUtils.put_utf8(buf, att.label)

	var ser := REEEplaySerializer.new(true, PackedByteArray(), string_table, att.get_schema_version())
	att._serialize(ser)
	var payload := ser.to_bytes()
	REEEplayByteUtils.put_varuint(buf, payload.size())
	if not payload.is_empty():
		buf.put_data(payload)


func deserialize_attachment(buf: StreamPeerBuffer, string_table: REEEplayByteUtils.StringTable) -> REEEplayAttachment:
	var tidx := REEEplayByteUtils.get_varuint(buf)
	if tidx < 0:
		return null
	var type_id := string_table.get_string(tidx)
	var ver := REEEplayByteUtils.get_varuint(buf)
	var att_id := REEEplayByteUtils.get_varuint(buf)
	var tick := REEEplayByteUtils.get_varuint(buf)
	var entity_id := REEEplayByteUtils.get_varuint(buf)
	var label := REEEplayByteUtils.get_utf8(buf)
	var payload_len := REEEplayByteUtils.get_varuint(buf)
	var payload := PackedByteArray()
	if payload_len > 0 and payload_len <= 67108864 and payload_len <= buf.get_available_bytes():
		var res := buf.get_data(payload_len)
		if res[0] == OK:
			payload = res[1] as PackedByteArray

	var att := create_attachment(type_id)
	if att == null:
		return null
	att.attachment_id = att_id
	att.tick = tick
	att.entity_id = entity_id
	att.label = label
	var ser := REEEplaySerializer.new(false, payload, string_table, ver)
	att._deserialize(ser, ver)
	return att


func _classify_ancestor(cname: StringName, by_name: Dictionary[StringName, Dictionary]) -> String:
	var cursor := cname
	for _depth in range(16):
		var entry: Dictionary = by_name.get(cursor, {})
		if entry.is_empty():
			return ""
		var base := StringName(entry.get("base", &""))
		if base == &"REEEplayEvent" or base == &"REEEplayCue" or base == &"REEEplayDamageEntry":
			return "event"
		if base == &"REEEplayAttachment":
			return "attachment"
		cursor = base
	return ""

