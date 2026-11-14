class_name REEEplayActorRef
extends RefCounted
## Lightweight snapshot identifying an entity, player, or environmental hazard involved in an event.

var entity_id: int = 0
var archetype_id: StringName = &""
var player_id: String = ""
var display_name: String = ""
var team_id: int = -1
var is_anonymous: bool = false
var is_environmental: bool = false


static func create(
	p_entity_id: int = 0,
	p_display_name: String = "",
	p_player_id: String = "",
	p_team_id: int = -1,
	p_archetype_id: StringName = &"",
	p_is_environmental: bool = false
) -> REEEplayActorRef:
	var ref := REEEplayActorRef.new()
	ref.entity_id = p_entity_id
	ref.display_name = p_display_name
	ref.player_id = p_player_id
	ref.team_id = p_team_id
	ref.archetype_id = p_archetype_id
	ref.is_environmental = p_is_environmental
	return ref


static func anonymous(label: String = "Environment") -> REEEplayActorRef:
	var ref := REEEplayActorRef.new()
	ref.display_name = label
	ref.is_anonymous = true
	return ref


static func environmental(hazard_name: String = "Environment") -> REEEplayActorRef:
	var ref := REEEplayActorRef.new()
	ref.entity_id = 0
	ref.display_name = hazard_name if not hazard_name.is_empty() else "Environment"
	ref.is_anonymous = true
	ref.is_environmental = true
	return ref


## Returns a stable deduplication key distinguishing tracked entities and named environmental hazards.
func actor_key() -> String:
	if is_environmental:
		return "env:%s" % (display_name if not display_name.is_empty() else "Environment")
	if entity_id > 0:
		return "entity:%d" % entity_id
	if not display_name.is_empty():
		return display_name
	return "entity:0"


## Returns an anonymized shallow copy for privacy/tournament exports.
func anonymized(alias: String = "") -> REEEplayActorRef:
	var copy := REEEplayActorRef.new()
	copy.entity_id = entity_id
	copy.archetype_id = archetype_id
	copy.team_id = team_id
	copy.player_id = ""
	copy.is_environmental = is_environmental
	if is_environmental:
		copy.display_name = alias if not alias.is_empty() else (display_name if not display_name.is_empty() else "Environment")
	else:
		copy.display_name = alias if not alias.is_empty() else ("Entity_%d" % entity_id)
	copy.is_anonymous = true
	return copy


func duplicate_ref() -> REEEplayActorRef:
	var copy := REEEplayActorRef.new()
	copy.entity_id = entity_id
	copy.archetype_id = archetype_id
	copy.player_id = player_id
	copy.display_name = display_name
	copy.team_id = team_id
	copy.is_anonymous = is_anonymous
	copy.is_environmental = is_environmental
	return copy


func serialize(buf: StreamPeerBuffer, string_table: REEEplayByteUtils.StringTable) -> void:
	REEEplayByteUtils.put_varuint(buf, maxi(0, entity_id))
	var arch_idx := string_table.intern(archetype_id) if string_table != null else 0
	REEEplayByteUtils.put_varuint(buf, arch_idx)
	REEEplayByteUtils.put_utf8(buf, player_id)
	REEEplayByteUtils.put_utf8(buf, display_name)
	REEEplayByteUtils.put_varint(buf, team_id)
	var flags := 0
	if is_anonymous:
		flags |= 1
	if is_environmental:
		flags |= 2
	buf.put_u8(flags)


static func deserialize(buf: StreamPeerBuffer, string_table: REEEplayByteUtils.StringTable) -> REEEplayActorRef:
	var ref := REEEplayActorRef.new()
	ref.entity_id = REEEplayByteUtils.get_varuint(buf)
	var arch_idx := REEEplayByteUtils.get_varuint(buf)
	if string_table != null and arch_idx >= 0:
		ref.archetype_id = string_table.get_string(arch_idx)
	ref.player_id = REEEplayByteUtils.get_utf8(buf)
	ref.display_name = REEEplayByteUtils.get_utf8(buf)
	ref.team_id = REEEplayByteUtils.get_varint(buf)
	var flags := buf.get_u8()
	ref.is_anonymous = (flags & 1) != 0
	ref.is_environmental = (flags & 2) != 0
	return ref
