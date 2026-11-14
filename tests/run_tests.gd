extends SceneTree
## Headless automated test suite for the REEEplay Godot addon.

var _failures: Array[String] = []
var _passed: int = 0


class TestMigratedEventV1 extends REEEplayEvent:
	var dmg: int = 0
	var weapon: String = ""

	func get_type_id() -> StringName:
		return &"TestMigratedEvent"

	func get_schema_version() -> int:
		return 1


class TestMigratedEventV2 extends REEEplayEvent:
	var damage_amount: float = 0.0
	var weapon_name: String = ""
	var migrated_from_v1: bool = false

	func get_type_id() -> StringName:
		return &"TestMigratedEvent"

	func get_schema_version() -> int:
		return 2

	func _migrate(data: Dictionary, from_version: int, _to_version: int) -> Dictionary:
		if from_version == 1:
			return {
				"damage_amount": float(data.get("dmg", 0)),
				"weapon_name": str(data.get("weapon", "")),
				"migrated_from_v1": true,
			}
		return data


class TestAliasEvent extends REEEplayEvent:
	var note_code: int = 0

	func get_type_id() -> StringName:
		return &"TestAliasEvent"


class TestCueCounter extends REEEplayCue:
	var forward_count: int = 0
	var reverse_count: int = 0
	static var tracker_ref: Array = []

	func get_type_id() -> StringName:
		return &"TestCueCounter"

	func _on_playback_forward(_player: Node) -> void:
		forward_count += 1
		tracker_ref.append("fwd:%d" % tick)

	func _on_playback_reverse(_player: Node) -> void:
		reverse_count += 1
		tracker_ref.append("rev:%d" % tick)


class TestReplayAttachment extends REEEplayAttachment:
	var payload_tag: String = ""
	var values: PackedInt32Array = PackedInt32Array()

	func get_type_id() -> StringName:
		return &"TestReplayAttachment"


func _initialize() -> void:
	_run_all.call_deferred()


func _run_all() -> void:
	print("=== REEEplay Automated Test Suite ===")
	REEEplaySettings.register()

	_run_test("ByteUtils varuint / varint / utf8 / StringTable", _test_byte_utils)
	_run_test("All 16 Binary Codecs + AUTO + values_equal", _test_codecs)
	_run_test("Presets + RatePolicies + Adaptive Dividers", _test_presets_and_rate_policies)
	_run_test("Events Migration, Aliases, UnknownEvent, Cues, Attachments", _test_events_and_registry)
	_run_test("DamageTracker + DeathRecap + Yeet Hit Signal + DPS", _test_damage_logs)
	_run_test("Recorder Delta Suppression, Respawn, Despawn, Ring Buffer, Highlights", _test_recorder_features)
	_run_test("End-to-End Write(.reee zstd+CRC) -> Read -> LoadErrors -> Player Seek/Interp/Slice", _test_e2e_file_and_playback)
	_run_test("ProxyFactory Sanitization + Stage + Camera", _test_proxy_sanitization_and_camera)
	_run_test("Manager + Session + 2D Stage + Tracked + Clock", _test_manager_session_and_2d)
	_run_test("Editor Dock, Authoring & Inspector Plugin", _test_editor_dock_and_inspector)
	_run_test("Demo Scene Record, Save/Load .reee & Playback", _test_demo_scene)
	_run_test("Killcam + REEEplayDiff + Dock Timeline Tree", _test_killcam_diff_and_dock_timeline)

	print("=== Results: %d passed, %d failed ===" % [_passed, _failures.size()])
	for f in _failures:
		push_error("FAIL: " + f)
		printerr("FAIL: " + f)

	quit(0 if _failures.is_empty() else 1)


func _run_test(label: String, fn: Callable) -> void:
	var err_before := _failures.size()
	fn.call()
	if _failures.size() == err_before:
		_passed += 1
		print("[PASS] %s" % label)
	else:
		print("[FAIL] %s" % label)


func _assert(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)


func _assert_near(a: float, b: float, eps: float, msg: String) -> void:
	if absf(a - b) > eps:
		_failures.append("%s (got %.6f, expected %.6f +- %.6f)" % [msg, a, b, eps])


func _test_byte_utils() -> void:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	var test_uints := [0, 1, 127, 128, 255, 16383, 16384, 1 << 21, 1 << 30]
	for u in test_uints:
		REEEplayByteUtils.put_varuint(buf, u)
	var test_ints := [0, -1, 1, -64, 64, -100000, 100000, -1073741824]
	for n in test_ints:
		REEEplayByteUtils.put_varint(buf, n)
	REEEplayByteUtils.put_utf8(buf, "REEEplay UTF-8 ✓ 🎮")
	REEEplayByteUtils.put_utf8(buf, "")

	buf.seek(0)
	for u in test_uints:
		_assert(REEEplayByteUtils.get_varuint(buf) == u, "varuint mismatch for %d" % u)
	for n in test_ints:
		_assert(REEEplayByteUtils.get_varint(buf) == n, "varint mismatch for %d" % n)
	_assert(REEEplayByteUtils.get_utf8(buf) == "REEEplay UTF-8 ✓ 🎮", "utf8 mismatch")
	_assert(REEEplayByteUtils.get_utf8(buf) == "", "empty utf8 mismatch")

	var st := REEEplayByteUtils.StringTable.new()
	var i0 := st.intern(&"alpha")
	var i1 := st.intern(&"beta")
	var i0_again := st.intern(&"alpha")
	_assert(i0 == i0_again and i0 != i1, "StringTable intern dedup failed")
	var st_bytes := st.to_bytes()
	var st2 := REEEplayByteUtils.StringTable.from_bytes(st_bytes)
	_assert(st2.size() == st.size(), "StringTable round-trip size mismatch")
	_assert(st2.get_string(i0) == &"alpha" and st2.get_string(i1) == &"beta", "StringTable round-trip content mismatch")


func _test_codecs() -> void:
	var st := REEEplayByteUtils.StringTable.new()
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false

	var q_sample := Quaternion.from_euler(Vector3(0.4, -1.1, 0.7)).normalized()
	var x3_sample := Transform3D(Basis(q_sample).scaled_local(Vector3(1.5, 2.0, 0.75)), Vector3(12.5, -3.25, 9.0))
	var x2_sample := Transform2D(0.85, Vector2(14.0, -7.0)).scaled_local(Vector2(1.25, 0.8))
	var pose_sample: Array[Transform3D] = [
		Transform3D(Basis(Quaternion.from_euler(Vector3(0.1, 0.2, 0.3))), Vector3(0.0, 1.0, 0.0)),
		Transform3D(Basis(Quaternion.from_euler(Vector3(-0.3, 0.5, -0.1))), Vector3(0.5, 0.2, -0.1)),
	]
	var dict_sample := {"round": 3, "scores": [10, 20], "flag": true}

	var cases := [
		{"codec": REEEplayCodec.Id.BOOL, "val": true, "eps": 0.0},
		{"codec": REEEplayCodec.Id.INT_VAR, "val": -4219, "eps": 0.0},
		{"codec": REEEplayCodec.Id.F32, "val": 123.456, "eps": 0.001},
		{"codec": REEEplayCodec.Id.F16, "val": -12.25, "eps": 0.05},
		{"codec": REEEplayCodec.Id.VEC2_F32, "val": Vector2(44.2, -91.8), "eps": 0.001},
		{"codec": REEEplayCodec.Id.VEC2_Q16, "val": Vector2(11.345, -7.891), "eps": 0.003},
		{"codec": REEEplayCodec.Id.VEC3_F32, "val": Vector3(-512.75, 42.5, 1024.125), "eps": 0.001},
		{"codec": REEEplayCodec.Id.VEC3_Q16, "val": Vector3(15.123, -8.456, 4.789), "eps": 0.003},
		{"codec": REEEplayCodec.Id.QUAT_S3, "val": q_sample, "eps": 0.005},
		{"codec": REEEplayCodec.Id.ANGLE_U16, "val": 2.345, "eps": 0.002},
		{"codec": REEEplayCodec.Id.COLOR_RGBA8, "val": Color(0.25, 0.5, 0.75, 0.9), "eps": 0.01},
		{"codec": REEEplayCodec.Id.STRING_REF, "val": &"DashStrike", "eps": 0.0},
		{"codec": REEEplayCodec.Id.TRANSFORM3D, "val": x3_sample, "eps": 0.005},
		{"codec": REEEplayCodec.Id.TRANSFORM2D, "val": x2_sample, "eps": 0.002},
		{"codec": REEEplayCodec.Id.SKELETON_POSE, "val": pose_sample, "eps": 0.005},
		{"codec": REEEplayCodec.Id.VARIANT, "val": dict_sample, "eps": 0.0},
	]

	for c in cases:
		var start_pos := buf.get_position()
		REEEplayCodec.encode(buf, c["val"], c["codec"], st, 0.001)
		_assert(buf.get_position() > start_pos, "Codec %d wrote 0 bytes" % c["codec"])

	buf.seek(0)
	for c in cases:
		var decoded: Variant = REEEplayCodec.decode(buf, c["codec"], st, 0.001)
		_assert(
			REEEplayCodec.values_equal(c["val"], decoded, c["eps"], c["codec"]),
			"Codec %d round-trip mismatch" % c["codec"]
		)

	_assert(REEEplayCodec.resolve_auto_codec(Vector3.ZERO, REEEplayCodec.Id.AUTO) == REEEplayCodec.Id.VEC3_F32, "AUTO Vector3 resolution mismatch")
	_assert(REEEplayCodec.resolve_auto_codec(true, REEEplayCodec.Id.AUTO) == REEEplayCodec.Id.BOOL, "AUTO bool resolution mismatch")


func _test_presets_and_rate_policies() -> void:
	var sp := REEEplayPreset.from_kind(REEEplayPreset.Kind.SINGLEPLAYER)
	_assert(sp.tick_rate == 30 and sp.recording_mode == REEEplayPreset.RecordingMode.FULL, "SINGLEPLAYER preset mismatch")

	var fun := REEEplayPreset.from_kind(REEEplayPreset.Kind.FUN_GAME)
	_assert(fun.tick_rate == 60 and fun.sample_rate == 20 and fun.recording_mode == REEEplayPreset.RecordingMode.RING_BUFFER, "FUN_GAME preset mismatch")

	var comp := REEEplayPreset.from_kind(REEEplayPreset.Kind.COMPETITIVE)
	_assert(comp.tick_rate == 60 and comp.sample_rate == 30 and comp.recording_mode == REEEplayPreset.RecordingMode.FULL_WITH_RING, "COMPETITIVE preset mismatch")
	_assert_near(comp.epsilon_scale, 0.5, 0.001, "COMPETITIVE epsilon_scale")

	var esp := REEEplayPreset.from_kind(REEEplayPreset.Kind.ESPORTS)
	_assert(esp.tick_rate == 60 and esp.default_vector3_codec == REEEplayCodec.Id.VEC3_F32 and not esp.rate_policy.enabled, "ESPORTS preset mismatch")

	# Test Distance LOD evaluation.
	var lod := REEEplayRatePolicy.new()
	lod.mode = REEEplayRatePolicy.Mode.DISTANCE_LOD
	lod.near_distance = 10.0
	lod.mid_distance = 30.0
	lod.far_distance = 60.0
	var eval := lod.evaluate({
		"sim_time": 1.0,
		"focus_position": Vector3.ZERO,
		"entities": {
			1: {"position": Vector3(2, 0, 0), "priority": 0, "base_divider": 1},
			2: {"position": Vector3(20, 0, 0), "priority": 0, "base_divider": 1},
			3: {"position": Vector3(50, 0, 0), "priority": 0, "base_divider": 1},
			4: {"position": Vector3(90, 0, 0), "priority": 0, "base_divider": 1},
		}
	})
	_assert(int(eval[1]["divider"]) == 1, "Near entity should use divider 1")
	_assert(int(eval[2]["divider"]) == 2, "Mid entity should use divider 2")
	_assert(int(eval[3]["divider"]) == 4, "Far entity should use divider 4")
	_assert(int(eval[4]["divider"]) == 8, "Culled entity should use divider 8")

	# Test Event Boost evaluation.
	var ev_pol := REEEplayRatePolicy.new()
	ev_pol.mode = REEEplayRatePolicy.Mode.EVENT_BOOST
	ev_pol.baseline_divider = 3
	ev_pol.boost_divider = 1
	ev_pol.boost_duration_seconds = 2.0
	ev_pol.notify_event(10, 5.0)
	var boost_eval := ev_pol.evaluate({
		"sim_time": 6.0,
		"entities": {
			10: {"position": null, "priority": 0, "base_divider": 3},
			11: {"position": null, "priority": 0, "base_divider": 3},
		}
	})
	_assert(int(boost_eval[10]["divider"]) == 1, "Boosted entity 10 should drop to divider 1")
	_assert(int(boost_eval[11]["divider"]) == 3, "Unboosted entity 11 should stay at divider 3")


func _test_events_and_registry() -> void:
	var reg := REEEplayEventRegistry.new(false)
	reg.register_builtin_types()
	reg.register_type(&"TestAliasEvent", TestAliasEvent, [&"OldLegacyAlias"])
	reg.register_type(&"TestCueCounter", TestCueCounter)
	reg.register_attachment_type(&"TestReplayAttachment", TestReplayAttachment)

	# 1) Test v1 -> v2 _migrate() roundtrip.
	var reg_v1 := REEEplayEventRegistry.new(false)
	reg_v1.register_type(&"TestMigratedEvent", TestMigratedEventV1)
	var ev1 := TestMigratedEventV1.new()
	ev1.tick = 42
	ev1.dmg = 75
	ev1.weapon = "PlasmaRifle"
	ev1.actor = REEEplayActorRef.create(1, "PlayerOne", "steam_123", 1)

	var st := REEEplayByteUtils.StringTable.new()
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	reg_v1.serialize_event(buf, ev1, st)

	# Deserialize with v2 registry.
	reg.register_type(&"TestMigratedEvent", TestMigratedEventV2)
	buf.seek(0)
	var loaded_v2 := reg.deserialize_event(buf, st) as TestMigratedEventV2
	_assert(loaded_v2 != null, "Migrated event failed to deserialize as v2")
	_assert(loaded_v2.tick == 42, "Migrated event tick mismatch")
	_assert_near(loaded_v2.damage_amount, 75.0, 0.001, "Migrated event damage_amount")
	_assert(loaded_v2.weapon_name == "PlasmaRifle", "Migrated event weapon_name")
	_assert(loaded_v2.migrated_from_v1, "Migrated event did not execute _migrate()")

	# 2) Test alias resolution.
	_assert(reg.resolve_script(&"OldLegacyAlias") == TestAliasEvent, "Event alias resolution failed")

	# 3) Test REEEplayUnknownEvent lossless round-trip.
	var reg_missing := REEEplayEventRegistry.new(false)
	buf.seek(0)
	var unk := reg_missing.deserialize_event(buf, st) as REEEplayUnknownEvent
	_assert(unk != null, "Unregistered event should become REEEplayUnknownEvent")
	_assert(unk.get_type_id() == &"TestMigratedEvent" and unk.tick == 42, "UnknownEvent envelope mismatch")

	# Re-serialize UnknownEvent, then read with reg supporting v2!
	var buf_unk := StreamPeerBuffer.new()
	buf_unk.big_endian = false
	var st_unk := REEEplayByteUtils.StringTable.new()
	reg_missing.serialize_event(buf_unk, unk, st_unk)
	buf_unk.seek(0)
	var recovered := reg.deserialize_event(buf_unk, st_unk) as TestMigratedEventV2
	_assert(recovered != null and recovered.migrated_from_v1 and recovered.weapon_name == "PlasmaRifle", "UnknownEvent lossless round-trip failed")

	# 4) Test attachments & PII strip.
	var att := TestReplayAttachment.new()
	att.tick = 10
	att.payload_tag = "nav_snapshot"
	att.values = PackedInt32Array([3, 1, 4, 1, 5])
	var abuf := StreamPeerBuffer.new()
	abuf.big_endian = false
	reg.serialize_attachment(abuf, att, st)
	abuf.seek(0)
	var att2 := reg.deserialize_attachment(abuf, st) as TestReplayAttachment
	_assert(att2 != null and att2.payload_tag == "nav_snapshot" and att2.values.size() == 5, "Attachment round-trip failed")

	loaded_v2.strip_pii()
	_assert(loaded_v2.actor.player_id == "" and loaded_v2.actor.is_anonymous, "strip_pii() did not clear player_id")


func _test_damage_logs() -> void:
	var tick_now := 100
	var events_captured: Array[REEEplayEvent] = []
	var dt := REEEplayDamageTracker.new()
	dt.configure(
		func() -> int: return tick_now,
		Callable(),
		func(ev: REEEplayEvent) -> void: events_captured.append(ev)
	)

	var a1 := REEEplayActorRef.create(1, "AttackerA", "p1", 1)
	var a2 := REEEplayActorRef.create(2, "SupportB", "p2", 1)
	var vic := REEEplayActorRef.create(3, "VictimC", "p3", 2)
	var vic2 := REEEplayActorRef.create(4, "VictimD", "p4", 2)

	# Multi-dealer, multi-source damage on VictimC (entities + environment)
	dt.record_damage(a2, vic, 25.0, &"fire", "Molotov", {"tick": 100})
	dt.record_damage(a1, vic, 30.0, &"explosive", "Frag Grenade", {"tick": 105})
	dt.record_environmental_damage(vic, 20.0, &"fire", "Lava", {"tick": 110})
	dt.record_environmental_damage(vic, 15.0, &"impact", "Falling Debris", {"tick": 112})

	# Multi-healer, multi-source healing on VictimC (allied, self, environment)
	dt.record_heal(a2, vic, 12.0, "Medigun", {"tick": 115})
	dt.record_heal(a2, vic, 8.0, "Healing Grenade", {"tick": 116})
	dt.record_heal(vic, vic, 14.0, "Stimpack", {"tick": 118})
	dt.record_environmental_heal(vic, 16.0, "Healing Shrine", {"tick": 120})

	# Fatal blow by AttackerA using a second weapon source
	dt.record_damage(a1, vic, 85.0, &"ballistic", "Railgun", {"tick": 130, "is_critical": true, "is_killing_blow": true})

	# Separate scenario: VictimD killed by environment after player damage (assists must credit AttackerA)
	dt.record_damage(a1, vic2, 45.0, &"melee", "Dropkick", {"tick": 140})
	dt.record_environmental_damage(vic2, 60.0, &"crush", "Falling Debris", {"tick": 150, "is_killing_blow": true})

	# Test yeet-cpp style Dictionary hit payload routing via _on_yeet_hit_signal (both entity & null env attacker)
	dt._on_yeet_hit_signal({
		"attacker": a1,
		"victim": a2,
		"damage": 40.0,
		"damage_type": &"melee",
		"move_name": "Dropkick",
		"is_critical": true,
	})
	dt._on_yeet_hit_signal({
		"attacker": null,
		"victim": a2,
		"damage": 15.0,
		"damage_type": &"hazard",
		"move_name": "Spike Trap",
	})

	var recap := dt.log.death_recap(3, 130, 30, 10.0, 5.0)
	_assert(recap["killer"] != null and (recap["killer"] as REEEplayActorRef).entity_id == 1, "Death recap killer mismatch")
	# Assists on VictimC should include SupportB, Lava, and Falling Debris (3 distinct non-killer damage dealers)
	_assert((recap["assists"] as Array).size() == 3, "Expected 3 assists (SupportB + Lava + Falling Debris), got %d" % (recap["assists"] as Array).size())
	_assert_near(float(recap["total_damage"]), 175.0, 0.01, "Death recap total damage mismatch")
	_assert_near(float(recap["total_healing"]), 50.0, 0.01, "Death recap total healing mismatch")
	_assert_near(float(recap["environmental_damage"]), 35.0, 0.01, "Death recap environmental_damage mismatch")
	_assert_near(float(recap["environmental_healing"]), 16.0, 0.01, "Death recap environmental_healing mismatch")
	_assert_near(float(recap["ttk_seconds"]), 1.0, 0.01, "Death recap TTK mismatch (30 ticks @ 30Hz = 1.0s)")

	var dealers: Array = recap["damage_dealers"]
	_assert(dealers.size() == 4, "Expected 4 damage dealers (AttackerA, SupportB, Lava, Falling Debris)")
	var top_dealer: Dictionary = dealers[0]
	_assert(int(top_dealer["entity_id"]) == 1 and float(top_dealer["total_damage"]) == 115.0, "Top dealer should be AttackerA with 115")
	_assert(float((top_dealer["sources"] as Dictionary).get("Railgun", 0.0)) == 85.0 and float((top_dealer["sources"] as Dictionary).get("Frag Grenade", 0.0)) == 30.0, "Per-dealer multi-source breakdown mismatch")

	var healers: Array = recap["healers"]
	_assert(healers.size() == 3, "Expected 3 healers (SupportB, Healing Shrine, VictimC self-heal)")
	_assert(float((recap["by_healer"] as Dictionary).get("SupportB", 0.0)) == 20.0, "SupportB healing sum mismatch")
	_assert(float((recap["by_healer"] as Dictionary).get("Healing Shrine", 0.0)) == 16.0, "Environmental healing mismatch")
	_assert(float((recap["by_healer"] as Dictionary).get("VictimC", 0.0)) == 14.0, "Self-heal mismatch")
	var found_self := false
	var found_env_heal := false
	for h in healers:
		var hd: Dictionary = h
		if int(hd["entity_id"]) == 3 and bool(hd["is_self_heal"]):
			found_self = true
		if bool(hd["is_environmental"]) and float(hd["total_healing"]) == 16.0:
			found_env_heal = true
	_assert(found_self and found_env_heal, "Healers list should distinguish self-heal and environmental heal")

	var env_recap := dt.log.death_recap(4, 150, 30, 10.0, 5.0)
	_assert(env_recap["killer"] != null and (env_recap["killer"] as REEEplayActorRef).is_environmental, "VictimD killer should be environmental")
	_assert((env_recap["assists"] as Array).size() == 1 and ((env_recap["assists"] as Array)[0] as REEEplayActorRef).entity_id == 1, "VictimD environmental kill should still credit AttackerA assist")

	_assert(dt.log.entries_from_environment(3).size() == 3, "VictimC should have 3 environmental entries (2 dmg + 1 heal)")
	_assert(dt.log.get_sources_breakdown(3).size() == 9, "VictimC should have 9 distinct (actor, source, kind) rows")
	var a1_sum := dt.get_actor_summary(a1)
	_assert_near(float(a1_sum["damage_dealt"]), 200.0, 0.01, "AttackerA actor summary damage mismatch")
	_assert_near(dt.log.total_damage_by_entity(1), 200.0, 0.01, "Attacker 1 total damage mismatch")
	_assert_near(dt.log.total_healing_by_entity(2), 20.0, 0.01, "Healer 2 total healing mismatch")

	# Binary serialization round-trip check via REEEplayEventRegistry preserving is_environmental & kind
	var reg := REEEplayEventRegistry.new(true)
	var st := REEEplayByteUtils.StringTable.new()
	var sbuf := StreamPeerBuffer.new()
	sbuf.big_endian = false
	for ev in events_captured:
		reg.serialize_event(sbuf, ev, st)
	sbuf.seek(0)
	var decoded_events: Array[REEEplayEvent] = []
	for _i in range(events_captured.size()):
		decoded_events.append(reg.deserialize_event(sbuf, st))
	var rebuilt := REEEplayDamageLog.from_events(decoded_events)
	var rebuilt_recap := rebuilt.death_recap(3, 130, 30, 10.0, 5.0)
	_assert_near(float(rebuilt_recap["environmental_damage"]), 35.0, 0.01, "Binary round-trip lost environmental_damage")
	_assert_near(float(rebuilt_recap["environmental_healing"]), 16.0, 0.01, "Binary round-trip lost environmental_healing")
	_assert(dt.log.entries_from_environment(2).size() == 1, "Yeet null attacker should record environmental entry")


func _test_recorder_features() -> void:
	# 1) Entity IDs start at 1 (0 reserved for world state), delta suppression, rate change, despawn/respawn.
	var preset := REEEplayPreset.from_kind(REEEplayPreset.Kind.ESPORTS)
	preset.tick_rate = 10
	preset.sample_rate = 10
	preset.keyframe_interval_seconds = 1.0 # block every 10 ticks
	var rec := REEEplayRecorder.new(preset)

	var arch := REEEplayArchetype.create(&"Bot", REEEplayChannelPresets.transform_3d(REEEplayCodec.Id.VEC3_F32))
	rec.register_archetype(arch)
	var data_rec := rec.begin({"recording_id": "unit_rec"})

	var n1 := Node3D.new()
	n1.name = "Hero"
	root.add_child(n1)
	var id1 := rec.track(n1, &"Bot", {"stable_key": &"hero_1"})
	_assert(id1 == 1, "First tracked entity_id must be 1 (0 reserved for world state), got %d" % id1)

	rec.set_world_state(&"phase", "warmup")
	for t in range(5):
		n1.position = Vector3(float(t) * 2.0, 0.0, 0.0)
		rec.capture_tick()

	# Stationary ticks 5..7 should be delta-suppressed in non-keyframe ticks!
	for _t in range(3):
		rec.capture_tick()

	# Change rate at tick 8 to divider=2, then despawn at tick 10, respawn at tick 12.
	rec.set_entity_rate(id1, 2, 0)
	rec.capture_tick()
	rec.capture_tick()
	rec.despawn(n1)
	rec.set_world_state(&"phase", "combat")
	rec.capture_tick() # tick 10 (keyframe block boundary)
	rec.capture_tick() # tick 11

	var n1_respawn := Node3D.new()
	root.add_child(n1_respawn)
	var id1_re := rec.respawn(n1_respawn, id1, &"Bot")
	_assert(id1_re == id1, "respawn() did not preserve entity_id")
	n1_respawn.position = Vector3(42.0, 5.0, -3.0)

	var note := REEEplayRecordingNote.new()
	note.title = "Respawn Note"
	note.importance = 4.0
	rec.emit_event(note)

	rec.capture_tick() # tick 12

	rec.stop()
	_assert(data_rec.total_ticks == 13, "Expected 13 captured ticks, got %d" % data_rec.total_ticks)

	# Verify stationary ticks 6..7 omitted EntityFrame for id1 (delta suppressed).
	var b0 := data_rec.get_block(0)
	_assert(b0.ticks[6].entities.is_empty() and b0.ticks[7].entities.is_empty(), "Delta suppression should skip stationary ticks 6 & 7")

	var highlights := data_rec.find_highlights(2.0, 3.0)
	_assert(highlights.size() == 1 and highlights[0].peak_tick == 12, "Highlight detector failed")

	# 2) RING_BUFFER trim test.
	var ring_preset := REEEplayPreset.from_kind(REEEplayPreset.Kind.FUN_GAME)
	ring_preset.tick_rate = 10
	ring_preset.sample_rate = 10
	ring_preset.keyframe_interval_seconds = 0.5 # 5 ticks per block
	ring_preset.ring_buffer_seconds = 1.0       # keep 10 ticks
	var ring_rec := REEEplayRecorder.new(ring_preset)
	ring_rec.begin({"recording_id": "ring_test"})
	var n2 := Node3D.new()
	root.add_child(n2)
	ring_rec.track(n2)
	ring_rec.set_world_state(&"round", 1)
	for i in range(30):
		n2.position = Vector3(float(i), 0.0, 0.0)
		ring_rec.capture_tick()
	var trimmed := ring_rec.stop()
	_assert(trimmed.start_tick > 0, "RING_BUFFER should advance start_tick after pruning old blocks")
	_assert(trimmed.total_ticks >= 10, "RING_BUFFER must retain at least ring_buffer_seconds")
	_assert(trimmed.get_world_state_at(&"round", trimmed.get_end_tick()) == 1, "RING_BUFFER lost anchored world state")

	n1.free()
	n1_respawn.free()
	n2.free()


func _test_e2e_file_and_playback() -> void:
	var preset := REEEplayPreset.from_kind(REEEplayPreset.Kind.ESPORTS)
	preset.tick_rate = 10
	preset.sample_rate = 10
	preset.keyframe_interval_seconds = 1.0 # keyframe every 10 ticks

	var reg := REEEplayEventRegistry.new(true)
	reg.register_type(&"TestCueCounter", TestCueCounter)
	TestCueCounter.tracker_ref.clear()

	var recorder := REEEplayRecorder.new(preset)
	recorder.register_archetype(REEEplayArchetype.create(&"Runner", REEEplayChannelPresets.transform_3d(REEEplayCodec.Id.VEC3_F32)))
	var rec := recorder.begin({"recording_id": "e2e_match", "game_version": "0.9.5"})

	var actor_a := Node3D.new()
	actor_a.name = "RunnerA"
	root.add_child(actor_a)
	var actor_b := Node3D.new()
	actor_b.name = "RunnerB"
	root.add_child(actor_b)

	var eid_a := recorder.track(actor_a, &"Runner", {"display_name": "Alpha"})
	var eid_b := recorder.track(actor_b, &"Runner", {"display_name": "Beta", "divider": 2, "phase": 0})
	recorder.set_world_state(&"score_a", 0)

	for t in range(15):
		actor_a.position = Vector3(float(t) * 10.0, 0.0, 0.0)
		actor_b.position = Vector3(0.0, 0.0, float(t) * 4.0)
		if t == 5:
			recorder.set_world_state(&"score_a", 1)
			var cue := TestCueCounter.new()
			cue.tick = 5
			recorder.emit_event(cue)
		if t == 8:
			recorder.despawn(actor_b)
		if t == 11:
			recorder.respawn(actor_b, eid_b, &"Runner")
		recorder.capture_tick()

	recorder.stop()

	var test_path := "user://reeeplay_tests/e2e_test.reee"
	var save_err := REEEplayWriter.save_file(rec, test_path, true, reg)
	_assert(save_err == OK, "REEEplayWriter.save_file failed with error %d" % save_err)

	# Verify error codes.
	var missing := REEEplayReader.load_file("user://reeeplay_tests/does_not_exist_12345.reee")
	_assert(missing.error == REEEplayFormat.LoadError.FILE_NOT_FOUND, "Expected FILE_NOT_FOUND")

	var ver_rej := REEEplayReader.load_file(test_path, {"accepted_game_version": "2.0.0", "event_registry": reg})
	_assert(ver_rej.error == REEEplayFormat.LoadError.GAME_VERSION_REJECTED, "Expected GAME_VERSION_REJECTED")

	# Create corrupted copy (flip a byte in payload -> CRC_MISMATCH) & bad header copy.
	var raw_bytes := FileAccess.get_file_as_bytes(test_path)
	var bad_crc_bytes := raw_bytes.duplicate()
	bad_crc_bytes[24] = bad_crc_bytes[24] ^ 0x5A
	var bad_crc_path := "user://reeeplay_tests/bad_crc.reee"
	var f_crc := FileAccess.open(bad_crc_path, FileAccess.WRITE)
	f_crc.store_buffer(bad_crc_bytes)
	f_crc.close()
	var crc_res := REEEplayReader.load_file(bad_crc_path, {"event_registry": reg})
	_assert(crc_res.error == REEEplayFormat.LoadError.CRC_MISMATCH, "Expected CRC_MISMATCH, got %d" % crc_res.error)

	var bad_hdr_bytes := raw_bytes.duplicate()
	bad_hdr_bytes[0] = 0x58
	var bad_hdr_path := "user://reeeplay_tests/bad_hdr.reee"
	var f_hdr := FileAccess.open(bad_hdr_path, FileAccess.WRITE)
	f_hdr.store_buffer(bad_hdr_bytes)
	f_hdr.close()
	var hdr_res := REEEplayReader.load_file(bad_hdr_path)
	_assert(hdr_res.error == REEEplayFormat.LoadError.CORRUPT_HEADER, "Expected CORRUPT_HEADER")

	# Load valid replay lazily.
	var load_res := REEEplayReader.load_file(test_path, {"lazy_blocks": true, "event_registry": reg})
	_assert(load_res.error == REEEplayFormat.LoadError.OK and load_res.recording != null, "REEEplayReader.load_file failed: %s" % load_res.error_message)
	var loaded := load_res.recording
	_assert(loaded.get_world_state_at(&"score_a", 2) == 0, "World state at tick 2 should be 0")
	_assert(loaded.get_world_state_at(&"score_a", 7) == 1, "World state at tick 7 should be 1")

	# Playback with Stage + Interpolation + Cue + Despawn/Respawn.
	var stage := REEEplayStage.new()
	var player := REEEplayPlayer.new()
	player.proxy_root = stage.entity_root
	player.cue_host = stage.cue_root
	root.add_child(stage)
	root.add_child(player)
	player.load_recording(loaded)

	# Interpolate mid-tick between tick 2 (x=20) and tick 3 (x=30) -> x = 25.0!
	player.seek_to_time(0.25) # 0.25s * 10Hz = tick 2.5
	var proxy_a := player.get_proxy(eid_a) as Node3D
	_assert(proxy_a != null, "Proxy A missing at t=0.25")
	_assert_near(proxy_a.global_position.x, 25.0, 0.05, "Interpolated x at t=2.5")

	# Check despawn at tick 9: proxy_b must not exist.
	player.seek_to_tick(9)
	_assert(player.get_proxy(eid_b) == null, "Proxy B should be despawned at tick 9")

	# Check respawn at tick 12: proxy_b must return at z = 48.0!
	player.seek_to_tick(12)
	var proxy_b := player.get_proxy(eid_b) as Node3D
	_assert(proxy_b != null, "Proxy B should be respawned at tick 12")
	_assert_near(proxy_b.global_position.z, 48.0, 0.05, "Respawned Proxy B z at tick 12")

	# Check forward & reverse playback cue dispatch crossing tick 5.
	player.seek_to_tick(3)
	player.play(1.0)
	player.step_time(0.35) # reaches tick 6.5 -> crosses tick 5 forward!
	_assert(TestCueCounter.tracker_ref.has("fwd:5"), "Cue should fire forward when crossing tick 5")
	player.set_speed(-1.0)
	player.step_time(0.3) # reverses to tick 3.5 -> crosses tick 5 backward!
	_assert(TestCueCounter.tracker_ref.has("rev:5"), "Cue should fire reverse when crossing tick 5 backward")

	# Slice [4 .. 12] -> rebase to tick 0 -> save -> reload -> verify tick 0 == old tick 4!
	var sliced := loaded.slice(4, 12, true)
	var slice_path := "user://reeeplay_tests/sliced.reee"
	_assert(REEEplayWriter.save_file(sliced, slice_path, true, reg) == OK, "Sliced save_file failed")
	var slice_load := REEEplayReader.load_file(slice_path, {"event_registry": reg})
	_assert(slice_load.error == REEEplayFormat.LoadError.OK, "Sliced reload failed")

	player.load_recording(slice_load.recording)
	player.seek_to_tick(0)
	var sliced_proxy_a := player.get_proxy(eid_a) as Node3D
	_assert(sliced_proxy_a != null, "Sliced proxy A missing at tick 0")
	_assert_near(sliced_proxy_a.global_position.x, 40.0, 0.05, "Sliced tick 0 should correspond to original tick 4 (x=40)")
	_assert(player.get_world_state(&"score_a") == 0, "Sliced world state at tick 0 (orig tick 4) should be 0")
	player.seek_to_tick(2) # orig tick 6
	_assert(player.get_world_state(&"score_a") == 1, "Sliced world state at tick 2 (orig tick 6) should be 1")

	player.stop_and_clear()
	stage.free()
	player.free()
	actor_a.free()
	actor_b.free()


func _test_proxy_sanitization_and_camera() -> void:
	var live_root := RigidBody3D.new()
	var col := CollisionShape3D.new()
	var tracked := REEEplayTracked.new()
	var cam := Camera3D.new()
	cam.current = true
	var area := Area3D.new()
	live_root.add_child(col)
	live_root.add_child(tracked)
	live_root.add_child(cam)
	live_root.add_child(area)

	REEEplayProxyFactory.sanitize_node(live_root, true, false)
	_assert(live_root.freeze and live_root.collision_layer == 0, "RigidBody3D should be frozen with 0 collision")
	_assert(col.disabled, "CollisionShape3D should be disabled")
	_assert(not cam.current, "Live Camera3D should have current=false on proxy")
	_assert(not area.monitoring and not area.monitorable, "Area3D should disable monitoring/monitorable")
	# tracked was queued for free / removed from parent
	_assert(tracked.get_parent() == null, "REEEplayTracked should be removed from proxy hierarchy")
	tracked.free()
	live_root.free()

	var rcam := REEEplayCamera.new()
	rcam.mode = REEEplayCamera.Mode.ORBIT
	rcam.rotate_orbit(0.5, -0.2)
	_assert(rcam.ensure_camera() is Camera3D, "REEEplayCamera should provide Camera3D")
	rcam.free()


func _test_manager_session_and_2d() -> void:
	_assert(REEEplayClock.format_time(125.0) == "2:05", "Clock format mismatch")

	var mgr := root.get_node_or_null("REEEplay") as REEEplayManager
	var created_mgr := false
	if mgr == null:
		mgr = REEEplayManager.new()
		mgr.name = "REEEplay"
		root.add_child(mgr)
		created_mgr = true

	var p := REEEplayPreset.from_kind(REEEplayPreset.Kind.CUSTOM)
	p.tick_rate = 10
	p.sample_rate = 10
	mgr.start_recording(p, {"recording_id": "mgr_2d"})
	_assert(mgr.is_recording(), "REEEplayManager should report active recording")

	var sprite := Node2D.new()
	sprite.position = Vector2(10.0, 20.0)
	sprite.rotation = 0.5
	var tracked_comp := REEEplayTracked.new()
	sprite.add_child(tracked_comp)
	root.add_child(sprite)

	_assert(tracked_comp.entity_id == 1, "REEEplayTracked auto-registration failed")
	mgr.default_session.recorder.capture_tick()
	sprite.position = Vector2(30.0, 60.0)
	sprite.rotation = 1.5
	mgr.default_session.recorder.capture_tick()

	var rec := mgr.stop_recording(false)
	_assert(rec != null and rec.total_ticks == 2, "Manager stop_recording failed")

	var test_mgr_path := "user://reeeplay_tests/mgr_2d.reee"
	_assert(mgr.save_recording(test_mgr_path, true) == OK, "Manager save_recording failed")
	var files := mgr.list_recordings("user://reeeplay_tests")
	_assert(files.size() >= 1, "list_recordings should list saved test replays")

	var res := mgr.load_recording(test_mgr_path)
	_assert(res.error == REEEplayFormat.LoadError.OK, "Manager load_recording failed")

	var stage2d := REEEplayStage2D.new()
	root.add_child(stage2d)
	var player := mgr.create_player(stage2d, res.recording)
	player.proxy_root = stage2d.entity_root
	player.load_recording(res.recording)
	player.seek_to_tick(1)
	var p2 := player.get_proxy(1) as Node2D
	_assert(p2 != null, "2D proxy missing at tick 1")
	_assert_near(p2.global_position.x, 30.0, 0.25, "2D proxy x mismatch")
	_assert_near(p2.global_position.y, 60.0, 0.25, "2D proxy y mismatch")
	_assert_near(p2.global_rotation, 1.5, 0.05, "2D proxy rotation mismatch")

	player.stop_and_clear()
	stage2d.free()
	sprite.free()
	if created_mgr:
		mgr.free()


func _test_editor_dock_and_inspector() -> void:
	var dock := REEEplayDock.new()
	dock.persist = false
	dock.build()
	root.add_child(dock)

	for d: Array in REEEplaySettings.DEFS:
		var path := str(d[0])
		_assert(dock._setting_controls.has(path), "REEEplayDock missing control for setting: %s" % path)

	_assert(not dock.is_advanced_mode(), "Dock should default to Simple mode")
	_assert(dock._tabs.is_tab_hidden(1) and dock._tabs.is_tab_hidden(3), "Simple mode should hide Presets & Settings tabs")
	_assert(dock._simple_setup_box.visible and not dock._advanced_setup_box.visible, "Simple mode should show Simple setup box")
	dock.set_advanced_mode(true)
	_assert(dock.is_advanced_mode(), "set_advanced_mode(true) should enable Advanced mode")
	_assert(not dock._tabs.is_tab_hidden(1) and not dock._tabs.is_tab_hidden(3), "Advanced mode should show all 4 tabs")
	_assert(not dock._simple_setup_box.visible and dock._advanced_setup_box.visible, "Advanced mode should show Advanced setup box")
	dock.set_advanced_mode(false)
	_assert(not dock.is_advanced_mode() and dock._tabs.is_tab_hidden(1), "Toggling back to Simple mode should re-hide Advanced tabs")

	var changed_paths: Array[String] = []
	dock.setting_changed.connect(func(p: String, _v: Variant) -> void: changed_paths.append(p))
	dock._apply_project_setting("reeeplay/recording/sample_rate", 45.0)
	_assert_near(float(ProjectSettings.get_setting("reeeplay/recording/sample_rate")), 45.0, 0.001, "Dock should apply sample_rate to ProjectSettings")
	_assert(changed_paths.has("reeeplay/recording/sample_rate"), "Dock should emit setting_changed on edit")
	_assert_near(dock._simple_rate_slider.value, 45.0, 0.001, "Simple rate slider should sync with ProjectSettings")

	dock._reset_all_settings()
	_assert_near(float(ProjectSettings.get_setting("reeeplay/recording/sample_rate")), 20.0, 0.001, "Reset all should restore default sample_rate")

	var n3 := Node3D.new()
	n3.name = "HeroTestNode"
	var skel := Skeleton3D.new()
	skel.name = "Skeleton3D"
	n3.add_child(skel)
	_assert(REEEplayAuthoring.find_skeleton_near(n3) == skel, "find_skeleton_near should locate child Skeleton3D")
	var tracked := REEEplayAuthoring.auto_setup_node(n3)
	_assert(tracked != null and tracked.get_parent() == n3, "auto_setup_node should attach REEEplayTracked child")
	_assert(tracked.custom_channels.size() >= 3, "auto_setup_node on Node3D should add position, rotation, and visible")
	_assert(tracked.stable_key == &"HeroTestNode", "auto_setup_node should populate stable_key")

	var added := REEEplayAuthoring.add_channel_preset(tracked, &"velocity_3d")
	_assert(added == 1, "add_channel_preset(velocity_3d) should add 1 channel")
	_assert(REEEplayAuthoring.add_channel_preset(tracked, &"velocity_3d") == 0, "add_channel_preset should deduplicate existing channel names")

	var diag := REEEplayAuthoring.diagnose_tracked(tracked)
	_assert(bool(diag.get("ready", false)), "diagnose_tracked should report ready")
	_assert(float(diag.get("effective_hz", 0.0)) > 0.0, "diagnose_tracked should compute effective_hz")
	_assert(float(diag.get("bytes_per_sec", 0.0)) > 0.0, "diagnose_tracked should estimate bytes_per_sec")

	var proxy_res := REEEplayAuthoring.generate_proxy_scene(tracked)
	_assert(bool(proxy_res.get("ok", false)) and tracked.proxy_scene is PackedScene, "generate_proxy_scene should build a PackedScene")

	var budget := REEEplayAuthoring.estimate_budget(30.0)
	_assert(float(budget.get("kb_per_sec", 0.0)) > 0.0 and float(budget.get("mb_per_hour", 0.0)) > 0.0, "estimate_budget should compute bandwidth")

	var test_mgr_path := "user://reeeplay_tests/mgr_2d.reee"
	var insp := REEEplayAuthoring.inspect_reee_file(test_mgr_path)
	_assert(bool(insp.get("ok", false)), "inspect_reee_file should load saved test replay")
	_assert((insp.get("entities", []) as Array).size() == 1, "inspect_reee_file should report 1 entity in mgr_2d.reee")
	dock.inspect_file(test_mgr_path)
	_assert(dock._rec_output.text.contains("mgr_2d"), "Dock inspect_file should populate recording inspector output")

	var arch := REEEplayArchetype.new()
	var sess := REEEplaySession.new()
	var preset := REEEplayPreset.new()
	var pol := REEEplayRatePolicy.new()
	_assert(REEEplayInspectorPlugin.can_handle_object(tracked), "InspectorPlugin should handle REEEplayTracked")
	_assert(REEEplayInspectorPlugin.can_handle_object(arch), "InspectorPlugin should handle REEEplayArchetype")
	_assert(REEEplayInspectorPlugin.can_handle_object(sess), "InspectorPlugin should handle REEEplaySession")
	_assert(REEEplayInspectorPlugin.can_handle_object(preset), "InspectorPlugin should handle REEEplayPreset")
	_assert(REEEplayInspectorPlugin.can_handle_object(pol), "InspectorPlugin should handle REEEplayRatePolicy")
	_assert(not REEEplayInspectorPlugin.can_handle_object(n3), "InspectorPlugin should not handle generic Node3D")
	if Engine.is_editor_hint():
		var plugin_insp := REEEplayInspectorPlugin.new()
		_assert(plugin_insp._can_handle(tracked), "Editor InspectorPlugin _can_handle should match")

	sess.free()
	n3.free()
	root.remove_child(dock)
	dock.free()


func _test_demo_scene() -> void:
	var packed := ResourceLoader.load("res://addons/reeeplay/demo/reeeplay_demo.tscn") as PackedScene
	_assert(packed != null, "Demo scene PackedScene should load")
	if packed == null:
		return
	var demo := packed.instantiate()
	_assert(demo != null, "Demo scene should instantiate")
	root.add_child(demo)

	# Premade sample_playback.reee should be preloaded on _ready() with events and damage entries.
	_assert(demo._last_recording != null, "Demo should preload sample_playback.reee on ready")
	if demo._last_recording != null:
		_assert(demo._last_recording.events.size() >= 5, "Premade sample should contain timeline events")
		_assert(demo._last_recording.damage_log.entries.size() >= 3, "Premade sample should contain combat damage/heal entries")
		_assert(demo.marker_row.get_child_count() >= 5, "Demo marker_row should render clickable timeline marker buttons")

	# Record for 6 physics frames (~0.1s), then stop into replay mode.
	demo._on_record_pressed()
	_assert(demo.session.is_recording(), "Demo should enter recording state")
	for _i in range(6):
		demo._physics_process(1.0 / 60.0)
		demo.session._physics_process(1.0 / 60.0)
	demo._emit_demo_combat_exchange()
	demo._on_record_pressed()

	_assert(not demo.session.is_recording(), "Demo should stop recording on second toggle")
	_assert(demo._last_recording != null, "Demo should store last_recording")
	_assert(demo._in_replay_mode, "Demo should switch into replay mode after stopping")
	_assert(demo._player != null and demo._player.is_playing, "Demo replay player should be playing")

	var tmp_path := "user://reeeplay_demo_test.reee"
	var err := REEEplayWriter.save_file(demo._last_recording, tmp_path, true)
	_assert(err == OK, "Demo recording should save to .reee")
	var read_res := REEEplayReader.load_file(tmp_path)
	_assert(read_res.error == REEEplayFormat.LoadError.OK and read_res.recording != null, "Demo .reee should load back cleanly")
	if read_res.recording != null:
		_assert(read_res.recording.damage_log.entries.size() >= 3, "Demo .reee should preserve combat damage log entries")
		demo._load_recording_into_player(read_res.recording)
		demo._player.seek_to_time(0.05)
		_assert(demo._player.get_proxy(demo._player_entity_id) != null, "Demo replay stage should spawn Player proxy")

	if demo._player != null:
		demo._player.stop_and_clear()
	if FileAccess.file_exists(tmp_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
	root.remove_child(demo)
	demo.free()


func _test_killcam_diff_and_dock_timeline() -> void:
	# 1. REEEplayDiff identical & divergent comparison
	var sample_res := REEEplayReader.load_file("res://addons/reeeplay/demo/sample_playback.reee")
	_assert(sample_res.error == REEEplayFormat.LoadError.OK and sample_res.recording != null, "Sample .reee should load for diff")
	if sample_res.recording != null:
		var same_diff := REEEplayDiff.compare(sample_res.recording, sample_res.recording)
		_assert(same_diff.is_identical(), "Self-diff of sample_playback.reee should be identical")

	var sess_a := REEEplaySession.new()
	var sess_b := REEEplaySession.new()
	var node_a := Node3D.new()
	var node_b := Node3D.new()
	var arch := REEEplayArchetype.new()
	arch.archetype_id = &"DiffActor"
	arch.channels = REEEplayChannelPresets.transform_3d()
	sess_a.register_archetype(arch)
	sess_b.register_archetype(arch)
	sess_a.start_recording(REEEplayPreset.Kind.SINGLEPLAYER)
	sess_b.start_recording(REEEplayPreset.Kind.SINGLEPLAYER)
	var id_a := sess_a.track(node_a, &"DiffActor")
	var id_b := sess_b.track(node_b, &"DiffActor")
	for i in range(10):
		node_a.position = Vector3(float(i), 0.0, 0.0)
		node_b.position = Vector3(float(i) + (2.5 if i >= 5 else 0.0), 0.0, 0.0)
		if i == 6:
			sess_a.record_damage(id_a, id_a, 20.0, &"impact", "Self Hit")
		sess_a.recorder.capture_tick()
		sess_b.recorder.capture_tick()
	var rec_a := sess_a.stop_recording()
	var rec_b := sess_b.stop_recording()

	var div_diff := REEEplayDiff.compare(rec_a, rec_b)
	_assert(not div_diff.is_identical(), "Divergent recordings should not report identical")
	_assert(div_diff.first_divergent_tick == 5, "First divergent tick should be 5 (got %d)" % div_diff.first_divergent_tick)
	_assert(div_diff.max_position_drift >= 2.0, "Max position drift should be >= 2.0")

	# 2. REEEplayKillcam
	var kc_sess := REEEplaySession.new()
	var kc_node := Node3D.new()
	kc_sess.register_archetype(arch)
	kc_sess.start_recording(REEEplayPreset.Kind.FUN_GAME)
	var kc_id := kc_sess.track(kc_node, &"DiffActor", {"display_name": "Victim"})
	for i in range(20):
		kc_node.position = Vector3(float(i) * 0.2, 0.0, 0.0)
		if i == 15:
			kc_sess.record_environmental_damage(kc_id, 35.0, &"lava", "Pit")
		kc_sess.recorder.capture_tick()
	var kc_stage := REEEplayStage.new()
	var kc := REEEplayKillcam.new()
	root.add_child(kc_stage)
	root.add_child(kc)
	var kc_res := kc.play_killcam(kc_sess, kc_id, kc_stage, {"window_seconds": 1.0, "speed": 0.35})
	_assert(kc_res.get("clip", null) != null, "Killcam should produce a sliced clip")
	_assert(kc.player != null and is_equal_approx(kc.player.speed, 0.35), "Killcam should play at 0.35x slow-mo")
	_assert(float(kc.last_recap.get("environmental_damage", 0.0)) >= 35.0, "Killcam recap should include environmental damage")
	kc.stop_killcam()
	kc_sess.stop_recording()

	# 3. Dock Recordings Timeline Tree + Diff
	var dock := REEEplayDock.new()
	dock.persist = false
	root.add_child(dock)
	dock.inspect_file("res://addons/reeeplay/demo/sample_playback.reee")
	_assert(dock._rec_event_tree != null and dock._rec_event_tree.get_root() != null, "Dock event tree should exist")
	_assert(dock._rec_event_tree.get_root().get_child_count() >= 5, "Dock event tree should list sample_playback.reee events")
	dock._on_diff_vs_sample()
	_assert(dock._rec_output.text.contains("REEEplay Diff"), "Dock Diff vs Sample should output REEEplayDiff summary")

	root.remove_child(dock)
	dock.free()
	root.remove_child(kc)
	kc.free()
	root.remove_child(kc_stage)
	kc_stage.free()
	kc_node.free()
	kc_sess.free()
	node_a.free()
	node_b.free()
	sess_a.free()
	sess_b.free()
