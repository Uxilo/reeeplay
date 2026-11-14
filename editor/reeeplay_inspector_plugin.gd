@tool
class_name REEEplayInspectorPlugin
extends EditorInspectorPlugin
## Context-aware inspector cards for REEEplayTracked, REEEplayArchetype, REEEplaySession, REEEplayPreset, and REEEplayRatePolicy.

signal action_performed(target: Object, message: String)


func _can_handle(object: Object) -> bool:
	return can_handle_object(object)


## Predicate shared with _can_handle(); callable outside editor-only SceneTree tests.
static func can_handle_object(object: Object) -> bool:
	if object == null:
		return false
	return (
		object is REEEplayTracked
		or object is REEEplayArchetype
		or object is REEEplaySession
		or object is REEEplayPreset
		or object is REEEplayRatePolicy
	)


func _parse_begin(object: Object) -> void:
	if object is REEEplayTracked:
		add_custom_control(_build_tracked_card(object as REEEplayTracked))
	elif object is REEEplayArchetype:
		add_custom_control(_build_archetype_card(object as REEEplayArchetype))
	elif object is REEEplaySession:
		add_custom_control(_build_session_budget_card(object as REEEplaySession))
	elif object is REEEplayPreset:
		add_custom_control(_build_preset_budget_card(object as REEEplayPreset))
	elif object is REEEplayRatePolicy:
		add_custom_control(_build_policy_budget_card(object as REEEplayRatePolicy))


func _build_tracked_card(tracked: REEEplayTracked) -> Control:
	var card := _make_card_panel()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 5)
	card.add_child(vbox)

	var top := HBoxContainer.new()
	var title := Label.new()
	title.text = "REEEplay Tracked Entity"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override(&"font_size", 12)
	top.add_child(title)

	var badge := Label.new()
	badge.add_theme_font_size_override(&"font_size", 11)
	top.add_child(badge)
	vbox.add_child(top)

	var summary_lbl := RichTextLabel.new()
	summary_lbl.bbcode_enabled = true
	summary_lbl.fit_content = true
	summary_lbl.scroll_active = false
	summary_lbl.add_theme_font_size_override(&"normal_font_size", 11)
	vbox.add_child(summary_lbl)

	var refresh_card := func(extra_msg: String = "") -> void:
		var diag := REEEplayAuthoring.diagnose_tracked(tracked)
		var ready := bool(diag.get("ready", false))
		badge.text = ("● %s" % str(diag.get("summary", ""))) if ready else "▲ Setup incomplete"
		badge.modulate = Color(0.45, 0.92, 0.58) if ready else Color(1.0, 0.78, 0.32)
		var text := "[b]Rate:[/b] %s  |  [b]Channels:[/b] %d  |  [b]Est.:[/b] ~%.0f B/s" % [
			str(diag.get("rate_chain", "")),
			int(diag.get("channel_count", 0)),
			float(diag.get("bytes_per_sec", 0.0)),
		]
		if not extra_msg.is_empty():
			text += "\n" + extra_msg
		summary_lbl.text = text

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 4)

	var setup_btn := Button.new()
	setup_btn.text = "Auto-Setup Channels"
	setup_btn.icon = _icon(&"Tools")
	setup_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	setup_btn.pressed.connect(func() -> void:
		REEEplayAuthoring.auto_setup_node(tracked.get_effective_target())
		tracked.notify_property_list_changed()
		refresh_card.call("[color=#6be689]Populated default channels.[/color]")
		action_performed.emit(tracked, "Auto-setup channels completed.")
	)
	row.add_child(setup_btn)

	var preset_menu := MenuButton.new()
	preset_menu.text = "Add Channel Preset"
	preset_menu.icon = _icon(&"Add")
	preset_menu.flat = false
	preset_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pop := preset_menu.get_popup()
	for i in range(REEEplayDock.CHANNEL_PRESET_ITEMS.size()):
		pop.add_item(str(REEEplayDock.CHANNEL_PRESET_ITEMS[i][0]), i)
	pop.id_pressed.connect(func(id: int) -> void:
		if id < 0 or id >= REEEplayDock.CHANNEL_PRESET_ITEMS.size():
			return
		var key := REEEplayDock.CHANNEL_PRESET_ITEMS[id][1] as StringName
		var added := REEEplayAuthoring.add_channel_preset(tracked, key)
		tracked.notify_property_list_changed()
		refresh_card.call("[color=#6be689]Added %d channel(s) from %s.[/color]" % [added, String(key)])
		action_performed.emit(tracked, "Added channel preset %s." % String(key))
	)
	row.add_child(preset_menu)

	var proxy_btn := Button.new()
	proxy_btn.text = "Generate Proxy Scene"
	proxy_btn.icon = _icon(&"PackedScene")
	proxy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	proxy_btn.pressed.connect(func() -> void:
		var target := tracked.get_effective_target()
		var save_path := ""
		if target != null and not target.scene_file_path.is_empty():
			save_path = "%s_proxy.tscn" % target.scene_file_path.get_basename()
		var res := REEEplayAuthoring.generate_proxy_scene(tracked, save_path)
		tracked.notify_property_list_changed()
		var col := "#6be689" if bool(res.get("ok", false)) else "#ff6b6b"
		refresh_card.call("[color=%s]%s[/color]" % [col, str(res.get("message", ""))])
		action_performed.emit(tracked, str(res.get("message", "")))
	)
	row.add_child(proxy_btn)

	vbox.add_child(row)
	refresh_card.call()
	return card


func _build_archetype_card(arch: REEEplayArchetype) -> Control:
	var card := _make_card_panel()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 5)
	card.add_child(vbox)

	var hdr := Label.new()
	hdr.add_theme_font_size_override(&"font_size", 12)
	vbox.add_child(hdr)

	var refresh_arch := func() -> void:
		hdr.text = "REEEplay Archetype '%s' — %d channel(s)" % [String(arch.archetype_id), arch.channels.size()]

	var preset_menu := MenuButton.new()
	preset_menu.text = "Add Channel Preset"
	preset_menu.icon = _icon(&"Add")
	preset_menu.flat = false
	var pop := preset_menu.get_popup()
	for i in range(REEEplayDock.CHANNEL_PRESET_ITEMS.size()):
		pop.add_item(str(REEEplayDock.CHANNEL_PRESET_ITEMS[i][0]), i)
	pop.id_pressed.connect(func(id: int) -> void:
		if id < 0 or id >= REEEplayDock.CHANNEL_PRESET_ITEMS.size():
			return
		var key := REEEplayDock.CHANNEL_PRESET_ITEMS[id][1] as StringName
		REEEplayAuthoring.add_channel_preset(arch, key)
		arch.notify_property_list_changed()
		refresh_arch.call()
		action_performed.emit(arch, "Added preset %s." % String(key))
	)
	vbox.add_child(preset_menu)

	refresh_arch.call()
	return card


func _build_session_budget_card(session: REEEplaySession) -> Control:
	var preset: REEEplayPreset = null
	if session.preset_kind == REEEplayPreset.Kind.CUSTOM and session.custom_preset != null:
		preset = session.custom_preset
	elif session.preset_kind != REEEplayPreset.Kind.CUSTOM:
		preset = REEEplayPreset.from_kind(session.preset_kind)
	var sample_hz := float(preset.sample_rate) if preset != null else float(REEEplaySettings.value(&"reeeplay/recording/sample_rate"))
	var kf_sec := preset.keyframe_interval_seconds if preset != null else float(REEEplaySettings.value(&"reeeplay/recording/keyframe_interval_seconds"))
	return _build_budget_card("REEEplay Session Budget (50 Entities)", sample_hz, kf_sec)


func _build_preset_budget_card(preset: REEEplayPreset) -> Control:
	return _build_budget_card("REEEplay Preset Budget (50 Entities)", float(preset.sample_rate), preset.keyframe_interval_seconds)


func _build_policy_budget_card(policy: REEEplayRatePolicy) -> Control:
	var sample_hz := float(REEEplaySettings.value(&"reeeplay/recording/sample_rate")) / float(maxi(1, policy.baseline_divider))
	var kf_sec := float(REEEplaySettings.value(&"reeeplay/recording/keyframe_interval_seconds"))
	return _build_budget_card("REEEplay Rate Policy Budget (50 Entities)", sample_hz, kf_sec)


func _build_budget_card(heading: String, sample_hz: float, keyframe_sec: float) -> Control:
	var card := _make_card_panel()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override(&"separation", 4)
	card.add_child(vbox)

	var title := Label.new()
	title.text = heading
	title.add_theme_font_size_override(&"font_size", 12)
	vbox.add_child(title)

	var est := REEEplayAuthoring.estimate_budget(sample_hz, 50, 18.0, keyframe_sec, 0.65)
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.add_theme_font_size_override(&"normal_font_size", 11)
	body.text = "~%.1f KB/s  |  ~%.1f MB/hour  |  ~%.2f ms/peak tick  (%.1f Hz, keyframes %.1f s)" % [
		float(est["kb_per_sec"]),
		float(est["mb_per_hour"]),
		float(est["est_tick_ms"]),
		sample_hz,
		keyframe_sec,
	]
	vbox.add_child(body)
	return card


func _icon(icon_name: StringName) -> Texture2D:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var ed := Engine.get_singleton(&"EditorInterface")
		var base := ed.call(&"get_base_control") as Control
		if base != null and base.has_theme_icon(icon_name, &"EditorIcons"):
			return base.get_theme_icon(icon_name, &"EditorIcons")
	return null


func _make_card_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var ed := Engine.get_singleton(&"EditorInterface")
		var base := ed.call(&"get_base_control") as Control
		if base != null and base.has_theme_stylebox(&"sub_inspector_bg", &"Editor"):
			var sb := base.get_theme_stylebox(&"sub_inspector_bg", &"Editor").duplicate()
			sb.set_content_margin_all(6)
			panel.add_theme_stylebox_override(&"panel", sb)
			return panel
	var fallback := StyleBoxEmpty.new()
	fallback.set_content_margin_all(6)
	panel.add_theme_stylebox_override(&"panel", fallback)
	return panel
