class_name REEEplayActorRef
extends RefCounted
## Lightweight snapshot identifying an entity/player involved in a recorded event or damage entry.

var entity_id: int = 0
var archetype_id: StringName = &""
var player_id: String = ""
var display_name: String = ""
var team_id: int = -1
var is_anonymous: bool = false


static func create(
	p_entity_id: int = 0,
	p_display_name: String = "",
	p_player_id: String = "",
	p_team_id: int = -1,
	p_archetype_id: StringName = &""
) -> REEEplayActorRef:
	var ref := REEEplayActorRef.new()
	ref.entity_id = p_entity_id
	ref.display_name = p_display_name
	ref.player_id = p_player_id
	ref.team_id = p_team_id
	ref.archetype_id = p_archetype_id
	return ref


static func anonymous(label: String = "Environment") -> REEEplayActorRef:
	var ref := REEEplayActorRef.new()
	ref.display_name = label
	ref.is_anonymous = true
	return ref


## Returns an anonymized shallow copy for privacy/tournament exports.
func anonymized(alias: String = "") -> REEEplayActorRef:
	var copy := REEEplayActorRef.new()
	copy.entity_id = entity_id
	copy.archetype_id = archetype_id
	copy.team_id = team_id
	copy.player_id = ""
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
	return copy


func serialize(buf: StreamPeerBuffer, string_table: REEEplayByteUtils.StringTable) -> void:
	REEEplayByteUtils.put_varuint(buf, maxi(0, entity_id))
	var arch_idx := string_table.intern(archetype_id) if string_table != null else 0
	REEEplayByteUtils.put_varuint(buf, arch_idx)
	REEEplayByteUtils.put_utf8(buf, player_id)
	REEEplayByteUtils.put_utf8(buf, display_name)
	REEEplayByteUtils.put_varint(buf, team_id)
	buf.put_u8(1 if is_anonymous else 0)


static func deserialize(buf: StreamPeerBuffer, string_table: REEEplayByteUtils.StringTable) -> REEEplayActorRef:
	var ref := REEEplayActorRef.new()
	ref.entity_id = REEEplayByteUtils.get_varuint(buf)
	var arch_idx := REEEplayByteUtils.get_varuint(buf)
	if string_table != null and arch_idx >= 0:
		ref.archetype_id = string_table.get_string(arch_idx)
	ref.player_id = REEEplayByteUtils.get_utf8(buf)
	ref.display_name = REEEplayByteUtils.get_utf8(buf)
	ref.team_id = REEEplayByteUtils.get_varint(buf)
	ref.is_anonymous = buf.get_u8() != 0
	return ref
