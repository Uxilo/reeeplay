@tool
## The REEEplay editor dock:
## - Simple / Advanced mode toggle (Simple defaults to a 3-step Quick Setup + nice tweaks; Advanced exposes full channel/rate controls, Presets & Budget, and all Project Settings)
## - Recordings (.reee) browser & structured inspector (Summary, Entities, Events, Damage Logs)
class_name REEEplayDock
extends VBoxContainer

signal setting_changed(path: String, value: Variant)
signal mode_changed(advanced: bool)

const PRESET_NAMES := [
	"Singleplayer (30 Hz Full + LOD)",
	"Fun Game (60/20 Hz Ring 90s)",
	"Casual (20 Hz Full + Budget)",
	"Competitive (60/30 Hz Full+Ring)",
	"Esports (60 Hz Raw F32)",
	"Custom (Manual Settings)",
]

const CHANNEL_PRESET_ITEMS := [
	["3D Transform (Q16 + Quat)", &"transform_3d"],
	["3D Transform Full (F32)", &"transform_3d_full"],
	["2D Transform (Q16 + Angle)", &"transform_2d"],
	["Skeleton3D Pose (Ragdoll)", &"skeleton_pose"],
	["Visibility (bool)", &"visibility"],
	["3D Velocity (Character/Rigid)", &"velocity_3d"],
	["2D Velocity", &"velocity_2d"],
	["Camera3D (Transform + FOV)", &"camera_3d"],
	["Camera2D (Transform + Zoom)", &"camera_2d"],
]

const QUICK_SETTING_PATHS := [
	"reeeplay/recording/sample_rate",
	"reeeplay/recording/tick_rate",
	"reeeplay/recording/default_mode",
	"reeeplay/recording/ring_buffer_seconds",
	"reeeplay/recording/keyframe_interval_seconds",
	"reeeplay/recording/epsilon_scale",
	"reeeplay/damage/recap_window_seconds",
	"reeeplay/damage/combat_timeout_seconds",
]

## Save project.godot after each ProjectSettings edit (disable in headless tests).
var persist := true

var _setting_controls: Dictionary = {} # path -> Control (Tab 4: all REEEplaySettings.DEFS)
var _setting_rows: Dictionary = {} # path -> Control
var _quick_controls: Dictionary = {} # path -> Control (Tab 2: Presets & Budget)
var _simple_controls: Dictionary = {} # path -> Control (Tab 1 Simple: Quick Tweaks)
var _updating_ui := false
var _advanced_mode := false

# Header & Context Bar
var _simple_mode_btn: Button
var _advanced_mode_btn: Button
var _selection_pill: Label
var _target_picker: OptionButton
var _target_nodes: Array[Node] = []
var _pinned_target: Node = null
var _tabs: TabContainer

# Tab 0 containers (Simple vs Advanced)
var _simple_setup_box: VBoxContainer
var _advanced_setup_box: VBoxContainer

# Tab 0 — Simple Mode widgets
var _simple_session_status: Label
var _simple_add_session_btn: Button
var _simple_select_session_btn: Button
var _simple_auto_start_check: CheckBox
var _simple_auto_save_exit_check: CheckBox
var _simple_preset_option: OptionButton
var _simple_entity_card: VBoxContainer
var _simple_entity_hint: Label
var _simple_display_name_edit: LineEdit
var _simple_team_spin: SpinBox
var _simple_setup_output: RichTextLabel
var _simple_rate_slider: HSlider
var _simple_rate_value_lbl: Label
var _simple_budget_bar: ProgressBar
var _simple_budget_label: RichTextLabel

# Tab 0 — Advanced Mode widgets
var _checklist_box: VBoxContainer
var _rate_readout_label: RichTextLabel
var _track_fields_box: VBoxContainer
var _auto_track_check: CheckBox
var _arch_id_edit: LineEdit
var _stable_key_edit: LineEdit
var _display_name_edit: LineEdit
var _team_spin: SpinBox
var _priority_spin: SpinBox
var _entity_rate_spin: SpinBox
var _fallback_check: CheckBox
var _channels_list: VBoxContainer
var _preset_menu_btn: MenuButton
var _setup_output: RichTextLabel

# Tab 1: Presets & Budget
var _preset_option: OptionButton
var _budget_bar: ProgressBar
var _budget_label: RichTextLabel

# Tab 2: Recordings (.reee Browser & Inspector)
var _rec_picker: OptionButton
var _rec_paths: Array[String] = []
var _rec_output: RichTextLabel
var _rec_event_filter: OptionButton
var _rec_event_search: LineEdit
var _rec_event_tree: Tree
var _rec_inspected_info: Dictionary = {}
var _rec_inspected_path: String = ""
var _file_dialog: FileDialog

# Tab 3: Settings
var _settings_filter: LineEdit
var _settings_list: VBoxContainer


func _ready() -> void:
	name = "REEEplay"
	if _setting_controls.is_empty():
		build()
	else:
		refresh_selection()
		_refresh_recordings_list()


## Builds or rebuilds the entire REEEplay dock UI. Safe to call standalone in tests.
func build() -> void:
	for child in get_children():
		child.queue_free()
	_setting_controls.clear()
	_setting_rows.clear()
	_quick_controls.clear()
	_simple_controls.clear()

	REEEplaySettings.register()
	add_theme_constant_override(&"separation", 4)

	_build_header_bar()

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tabs)

	_tabs.add_child(_wrap_tab("Quick Setup", _build_setup_tab()))
	_tabs.add_child(_wrap_tab("Presets & Budget", _build_presets_tab()))
	_tabs.add_child(_wrap_tab("Recordings", _build_recordings_tab()))
	_tabs.add_child(_wrap_tab("Settings", _build_settings_tab()))

	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.filters = PackedStringArray(["*.reee ; REEEplay Recording"])
	_file_dialog.file_selected.connect(inspect_file)
	add_child(_file_dialog)

	set_advanced_mode(_advanced_mode)
	refresh_selection()
	_refresh_presets_and_budget()
	_refresh_recordings_list()


## Switches between Simple (guided 3-step setup + nice tweaks) and Advanced (full controls + all settings).
func set_advanced_mode(enabled: bool) -> void:
	_advanced_mode = enabled
	if _simple_mode_btn != null:
		_simple_mode_btn.set_pressed_no_signal(not enabled)
	if _advanced_mode_btn != null:
		_advanced_mode_btn.set_pressed_no_signal(enabled)
	if _simple_setup_box != null:
		_simple_setup_box.visible = not enabled
	if _advanced_setup_box != null:
		_advanced_setup_box.visible = enabled
	if _tabs != null and _tabs.get_tab_count() >= 4:
		_tabs.set_tab_title(0, "Setup & Track" if enabled else "Quick Setup")
		_tabs.set_tab_hidden(1, not enabled)
		_tabs.set_tab_hidden(3, not enabled)
		if not enabled and (_tabs.current_tab == 1 or _tabs.current_tab == 3):
			_tabs.current_tab = 0
	mode_changed.emit(enabled)


## Returns true when Advanced mode is active.
func is_advanced_mode() -> bool:
	return _advanced_mode


# ---- Header & Context Bar -------------------------------------------------------------------------

func _build_header_bar() -> void:
	var top_card := _make_card(4)
	var top_vbox := VBoxContainer.new()
	top_vbox.add_theme_constant_override(&"separation", 4)
	top_card.add_child(top_vbox)

	var brand_row := HBoxContainer.new()
	brand_row.add_theme_constant_override(&"separation", 6)
	var title := Label.new()
	title.text = "REEEplay"
	title.add_theme_font_size_override(&"font_size", 13)
	brand_row.add_child(title)

	var mode_box := HBoxContainer.new()
	mode_box.add_theme_constant_override(&"separation", 2)
	_simple_mode_btn = Button.new()
	_simple_mode_btn.text = "Simple"
	_simple_mode_btn.toggle_mode = true
	_simple_mode_btn.button_pressed = not _advanced_mode
	_simple_mode_btn.tooltip_text = "Guided 3-step setup with essential recording tweaks."
	_simple_mode_btn.pressed.connect(func() -> void: set_advanced_mode(false))
	mode_box.add_child(_simple_mode_btn)

	_advanced_mode_btn = Button.new()
	_advanced_mode_btn.text = "Advanced"
	_advanced_mode_btn.toggle_mode = true
	_advanced_mode_btn.button_pressed = _advanced_mode
	_advanced_mode_btn.tooltip_text = "Full channel editor, presets, budget estimator, and all Project Settings."
	_advanced_mode_btn.pressed.connect(func() -> void: set_advanced_mode(true))
	mode_box.add_child(_advanced_mode_btn)
	brand_row.add_child(mode_box)

	_selection_pill = Label.new()
	_selection_pill.text = "Ready"
	_selection_pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_selection_pill.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_selection_pill.clip_text = true
	_selection_pill.add_theme_font_size_override(&"font_size", 11)
	brand_row.add_child(_selection_pill)

	var reset_btn := Button.new()
	reset_btn.text = ""
	reset_btn.flat = true
	reset_btn.icon = _icon(&"Reload")
	reset_btn.tooltip_text = "Reset every REEEplay Project Setting to its default value."
	reset_btn.pressed.connect(_reset_all_settings)
	brand_row.add_child(reset_btn)
	top_vbox.add_child(brand_row)

	var picker_row := HBoxContainer.new()
	picker_row.add_theme_constant_override(&"separation", 4)
	var target_lbl := Label.new()
	target_lbl.text = "Target:"
	target_lbl.add_theme_font_size_override(&"font_size", 11)
	target_lbl.add_theme_color_override(&"font_color", _editor_color(&"font_disabled_color", Color(0.65, 0.65, 0.65)))
	picker_row.add_child(target_lbl)

	_target_picker = OptionButton.new()
	_target_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_picker.clip_text = true
	_target_picker.tooltip_text = "Select a REEEplayTracked or REEEplaySession node in the active scene."
	_target_picker.item_selected.connect(_on_target_picker_selected)
	picker_row.add_child(_target_picker)

	picker_row.add_child(_btn("Select", _on_focus_active_target, &"Node",
		"Focus the active REEEplayTracked or REEEplaySession node in the Scene Tree & Inspector."))
	top_vbox.add_child(picker_row)

	add_child(top_card)


func _wrap_tab(tab_title: String, content: Control) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override(&"margin_left", 6)
	margin.add_theme_constant_override(&"margin_right", 6)
	margin.add_theme_constant_override(&"margin_top", 6)
	margin.add_theme_constant_override(&"margin_bottom", 8)
	margin.add_child(content)
	scroll.add_child(margin)
	return scroll


# ---- Tab 0: Quick Setup (Simple) & Setup & Track (Advanced) ---------------------------------------

func _build_setup_tab() -> Control:
	var root_box := VBoxContainer.new()
	root_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_box.add_theme_constant_override(&"separation", 8)

	_simple_setup_box = _build_simple_setup_box()
	_advanced_setup_box = _build_advanced_setup_box()
	root_box.add_child(_simple_setup_box)
	root_box.add_child(_advanced_setup_box)
	return root_box


func _build_simple_setup_box() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override(&"separation", 8)

	# Step 1: Scene Recorder
	var s1 := _make_section_card(vbox, "1. Scene Recorder",
		"Every scene needs one REEEplaySession (or start/stop via REEEplay autoload in code).")
	_simple_session_status = Label.new()
	_simple_session_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_simple_session_status.add_theme_font_size_override(&"font_size", 11)
	s1.add_child(_simple_session_status)

	var s1_btns := HBoxContainer.new()
	s1_btns.add_theme_constant_override(&"separation", 4)
	var auto_scene_btn := _btn("Auto-Setup Scene", _on_auto_setup_scene, &"Tools",
		"One-click setup: adds REEEplaySession (auto-start & save) and attaches REEEplayTracked to characters, physics bodies, skeletons, and cameras in this scene.")
	_simple_add_session_btn = _btn("+ Add Recorder", func() -> void: _on_create_session_node(true), &"Play",
		"Adds a REEEplaySession that auto-starts on Play and auto-saves on Exit.")
	_simple_select_session_btn = _btn("Select Recorder", _on_select_scene_session, &"Node",
		"Selects the scene's REEEplaySession in the Scene Tree.")
	s1_btns.add_child(auto_scene_btn)
	s1_btns.add_child(_simple_add_session_btn)
	s1_btns.add_child(_simple_select_session_btn)
	s1.add_child(s1_btns)

	var s1_toggles := HBoxContainer.new()
	s1_toggles.add_theme_constant_override(&"separation", 10)
	_simple_auto_start_check = CheckBox.new()
	_simple_auto_start_check.text = "Auto-Start on Play"
	_simple_auto_start_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_simple_auto_start_check.toggled.connect(func(on: bool) -> void: _set_scene_session_prop(&"auto_start_on_ready", on))
	s1_toggles.add_child(_simple_auto_start_check)

	_simple_auto_save_exit_check = CheckBox.new()
	_simple_auto_save_exit_check.text = "Auto-Save on Exit"
	_simple_auto_save_exit_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_simple_auto_save_exit_check.toggled.connect(func(on: bool) -> void: _set_scene_session_prop(&"auto_save_on_exit", on))
	s1_toggles.add_child(_simple_auto_save_exit_check)
	s1.add_child(s1_toggles)

	var sp_row := HBoxContainer.new()
	sp_row.add_theme_constant_override(&"separation", 6)
	var sp_lbl := Label.new()
	sp_lbl.text = "Game Style Preset:"
	sp_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp_lbl.add_theme_font_size_override(&"font_size", 11)
	sp_row.add_child(sp_lbl)
	_simple_preset_option = OptionButton.new()
	_simple_preset_option.custom_minimum_size.x = 175
	for pname in PRESET_NAMES:
		_simple_preset_option.add_item(pname)
	_simple_preset_option.item_selected.connect(_on_preset_selected)
	sp_row.add_child(_simple_preset_option)
	s1.add_child(sp_row)

	# Step 2: Tracked Entities
	var s2 := _make_section_card(vbox, "2. Tracked Entities",
		"Select any character, prop, or Skeleton3D in the Scene Tree and track it in one click.")
	var s2_btns := HBoxContainer.new()
	s2_btns.add_theme_constant_override(&"separation", 4)
	s2_btns.add_child(_btn("+ Track Selected", _on_track_selected_node, &"Add",
		"Attach REEEplayTracked to the selected node with automatic transform & visibility channels."))
	s2_btns.add_child(_btn("+ Track Skeleton", _on_track_skeleton_node, &"Skeleton3D",
		"Find Skeleton3D on the selected character and track full ragdoll/animation bone poses."))
	s2_btns.add_child(_btn("Make Proxy", _on_generate_proxy, &"PackedScene",
		"Generate a stripped visual-only proxy scene for playback."))
	s2.add_child(s2_btns)

	_simple_entity_hint = Label.new()
	_simple_entity_hint.text = "No tracked entity selected. Pick a node in the Scene Tree and click '+ Track Selected'."
	_simple_entity_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_simple_entity_hint.add_theme_font_size_override(&"font_size", 11)
	_simple_entity_hint.modulate = Color(0.68, 0.74, 0.82)
	s2.add_child(_simple_entity_hint)

	_simple_entity_card = VBoxContainer.new()
	_simple_entity_card.add_theme_constant_override(&"separation", 4)
	_simple_display_name_edit = _line_row(_simple_entity_card, "Display Name", "Player",
		"Name shown in timelines, damage recaps, and replay inspection.",
		func(t: String) -> void: _set_tracked_prop(&"display_name", t))
	_simple_team_spin = _spin_row(_simple_entity_card, "Team ID", -1, 64, 1, -1, "",
		"Team index (-1 = neutral / free-for-all).",
		func(v: float) -> void: _set_tracked_prop(&"team_id", int(v)))

	var quick_ch_row := HBoxContainer.new()
	quick_ch_row.add_theme_constant_override(&"separation", 4)
	quick_ch_row.add_child(_btn("+ 3D Move", func() -> void: _quick_add_channel(&"transform_3d"), &"", "Add 3D position + rotation."))
	quick_ch_row.add_child(_btn("+ 2D Move", func() -> void: _quick_add_channel(&"transform_2d"), &"", "Add 2D position + rotation."))
	quick_ch_row.add_child(_btn("+ Ragdoll Pose", func() -> void: _quick_add_channel(&"skeleton_pose"), &"", "Add Skeleton3D bone pose channel."))
	quick_ch_row.add_child(_btn("+ Visibility", func() -> void: _quick_add_channel(&"visibility"), &"", "Track visible flag."))
	_simple_entity_card.add_child(quick_ch_row)
	s2.add_child(_simple_entity_card)

	_simple_setup_output = RichTextLabel.new()
	_simple_setup_output.bbcode_enabled = true
	_simple_setup_output.fit_content = true
	_simple_setup_output.scroll_active = false
	_simple_setup_output.add_theme_font_size_override(&"normal_font_size", 11)
	s2.add_child(_simple_setup_output)

	# Step 3: Simple Tweaks
	var s3 := _make_section_card(vbox, "3. Quick Tweaks",
		"Dial in recording smoothness, clip length, save location, and debug HUD without digging into settings.")

	# Recording Mode
	var mode_def := _find_setting_def("reeeplay/recording/default_mode")
	if not mode_def.is_empty():
		var mode_ctrl := _make_setting_control_widget(mode_def, true)
		_add_labeled_row(s3, "Recording Mode", str(mode_def[4]), mode_ctrl)
		_simple_controls["reeeplay/recording/default_mode"] = mode_ctrl

	# Smoothness (Sample Rate slider)
	var rate_row := HBoxContainer.new()
	rate_row.add_theme_constant_override(&"separation", 6)
	rate_row.tooltip_text = "How smoothly movement is sampled (Hz). Higher = smoother replays, slightly larger files."
	var rate_lbl := Label.new()
	rate_lbl.text = "Smoothness"
	rate_lbl.custom_minimum_size.x = 85
	rate_lbl.add_theme_font_size_override(&"font_size", 11)
	rate_row.add_child(rate_lbl)

	_simple_rate_slider = HSlider.new()
	_simple_rate_slider.min_value = 5.0
	_simple_rate_slider.max_value = 60.0
	_simple_rate_slider.step = 5.0
	_simple_rate_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_simple_rate_slider.value = clampf(float(REEEplaySettings.value(&"reeeplay/recording/sample_rate")), 5.0, 60.0)
	_simple_rate_slider.value_changed.connect(func(v: float) -> void:
		_apply_project_setting("reeeplay/recording/sample_rate", float(v))
	)
	rate_row.add_child(_simple_rate_slider)

	_simple_rate_value_lbl = Label.new()
	_simple_rate_value_lbl.custom_minimum_size.x = 95
	_simple_rate_value_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_simple_rate_value_lbl.add_theme_font_size_override(&"font_size", 11)
	rate_row.add_child(_simple_rate_value_lbl)
	s3.add_child(rate_row)
	_simple_controls["reeeplay/recording/sample_rate"] = _simple_rate_slider

	# Ring buffer, recap window, storage dir, auto-save, debug overlay
	for item: Array in [
		["reeeplay/recording/ring_buffer_seconds", "Clip Buffer Length"],
		["reeeplay/damage/recap_window_seconds", "Damage Recap Window"],
		["reeeplay/storage/directory", "Save Folder"],
		["reeeplay/storage/auto_save", "Auto-Save on Stop"],
		["reeeplay/debug/overlay", "Debug Stats Overlay"],
	]:
		var spath := str(item[0])
		var sdef := _find_setting_def(spath)
		if sdef.is_empty():
			continue
		var sctrl := _make_setting_control_widget(sdef, true)
		_add_labeled_row(s3, str(item[1]), str(sdef[4]), sctrl)
		_simple_controls[spath] = sctrl

	_simple_budget_bar = ProgressBar.new()
	_simple_budget_bar.min_value = 0.0
	_simple_budget_bar.max_value = 120.0
	_simple_budget_bar.show_percentage = false
	_simple_budget_bar.custom_minimum_size.y = 10
	s3.add_child(_simple_budget_bar)

	_simple_budget_label = RichTextLabel.new()
	_simple_budget_label.bbcode_enabled = true
	_simple_budget_label.fit_content = true
	_simple_budget_label.scroll_active = false
	_simple_budget_label.add_theme_font_size_override(&"normal_font_size", 11)
	s3.add_child(_simple_budget_label)

	return vbox


func _build_advanced_setup_box() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override(&"separation", 8)

	var ready_card := _make_section_card(vbox, "Readiness & Quick Actions",
		"Inspect or auto-configure tracked entities and recording sessions in your scene.")
	_checklist_box = VBoxContainer.new()
	_checklist_box.add_theme_constant_override(&"separation", 3)
	ready_card.add_child(_checklist_box)

	var top_actions := HBoxContainer.new()
	top_actions.add_theme_constant_override(&"separation", 4)
	top_actions.add_child(_btn("+ Track Node", _on_track_selected_node, &"Add",
		"Attach and auto-configure REEEplayTracked on the currently selected scene node."))
	top_actions.add_child(_btn("+ Session", func() -> void: _on_create_session_node(false), &"Play",
		"Add a REEEplaySession node under the edited scene root."))
	ready_card.add_child(top_actions)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override(&"separation", 4)
	action_row.add_child(_btn("Auto-Setup Tracked", _on_auto_setup_tracked, &"Tools",
		"Populate default transform/visibility channels and stable_key on the active target."))

	_preset_menu_btn = MenuButton.new()
	_preset_menu_btn.text = "Add Channel Preset"
	_preset_menu_btn.icon = _icon(&"Add")
	_preset_menu_btn.flat = false
	_preset_menu_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_menu_btn.tooltip_text = "Append a built-in channel bundle (3D/2D transform, skeleton pose, visibility, etc.) to custom_channels."
	var pop := _preset_menu_btn.get_popup()
	for i in range(CHANNEL_PRESET_ITEMS.size()):
		pop.add_item(str(CHANNEL_PRESET_ITEMS[i][0]), i)
	pop.id_pressed.connect(_on_add_channel_preset_id)
	action_row.add_child(_preset_menu_btn)

	action_row.add_child(_btn("Generate Proxy", _on_generate_proxy, &"PackedScene",
		"Create a stripped visual-only proxy PackedScene and assign it to proxy_scene."))
	ready_card.add_child(action_row)

	_setup_output = RichTextLabel.new()
	_setup_output.bbcode_enabled = true
	_setup_output.fit_content = true
	_setup_output.scroll_active = false
	_setup_output.add_theme_font_size_override(&"normal_font_size", 11)
	ready_card.add_child(_setup_output)

	var rate_card := _make_section_card(vbox, "Rate & Precision Readout")
	_rate_readout_label = RichTextLabel.new()
	_rate_readout_label.bbcode_enabled = true
	_rate_readout_label.fit_content = true
	_rate_readout_label.scroll_active = false
	_rate_readout_label.add_theme_font_size_override(&"normal_font_size", 11)
	_rate_readout_label.text = "Select a REEEplayTracked node to view resolved rate & bandwidth."
	rate_card.add_child(_rate_readout_label)

	_track_fields_box = _make_section_card(vbox, "Tracked Properties & Channels")
	_auto_track_check = _toggle_row(_track_fields_box, "Auto Track", true,
		"Automatically register when entering the SceneTree.",
		func(on: bool) -> void: _set_tracked_prop(&"auto_track", on))
	_fallback_check = _toggle_row(_track_fields_box, "Fallback to Source Scene", true,
		"Instantiate the original scene (sanitized) if no proxy_scene is assigned.",
		func(on: bool) -> void: _set_tracked_prop(&"fallback_to_source_scene", on))
	_arch_id_edit = _line_row(_track_fields_box, "Archetype ID", "Auto (Node3D/Node2D)",
		"Archetype identifier shared across entities of the same kind.",
		func(t: String) -> void: _set_tracked_prop(&"archetype_id", StringName(t.strip_edges())))
	_stable_key_edit = _line_row(_track_fields_box, "Stable Key", "player_1",
		"Persistent cross-respawn / scoreboard identifier.",
		func(t: String) -> void: _set_tracked_prop(&"stable_key", StringName(t.strip_edges())))
	_display_name_edit = _line_row(_track_fields_box, "Display Name", "Player",
		"Human-readable name displayed in event timelines and damage recaps.",
		func(t: String) -> void: _set_tracked_prop(&"display_name", t))
	_team_spin = _spin_row(_track_fields_box, "Team ID", -1, 64, 1, -1, "",
		"Team index (-1 = neutral / unassigned).",
		func(v: float) -> void: _set_tracked_prop(&"team_id", int(v)))
	_priority_spin = _spin_row(_track_fields_box, "Priority", -100, 100, 1, 0, "",
		"Higher priority entities resist adaptive rate throttling.",
		func(v: float) -> void: _set_tracked_prop(&"priority", int(v)))
	_entity_rate_spin = _spin_row(_track_fields_box, "Sample Rate Override", 0, 240, 1, 0, "Hz",
		"Per-entity sample rate in Hz (0 = inherit from archetype/preset/project).",
		func(v: float) -> void:
			_set_tracked_prop(&"sample_rate", float(v))
			refresh_selection())

	var ch_hdr := Label.new()
	ch_hdr.text = "Configured Custom Channels:"
	ch_hdr.add_theme_font_size_override(&"font_size", 11)
	ch_hdr.add_theme_color_override(&"font_color", _editor_color(&"font_disabled_color", Color(0.68, 0.72, 0.78)))
	_track_fields_box.add_child(ch_hdr)

	_channels_list = VBoxContainer.new()
	_channels_list.add_theme_constant_override(&"separation", 2)
	_track_fields_box.add_child(_channels_list)

	return vbox


# ---- Tab 1: Presets & Budget (Advanced) -----------------------------------------------------------

func _build_presets_tab() -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override(&"separation", 8)

	var preset_card := _make_section_card(vbox, "Recording Preset",
		"Choosing a preset writes its baseline recording rates and retention settings into Project Settings.")
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override(&"separation", 6)
	var plbl := Label.new()
	plbl.text = "Active Preset:"
	plbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plbl.add_theme_font_size_override(&"font_size", 11)
	prow.add_child(plbl)

	_preset_option = OptionButton.new()
	_preset_option.custom_minimum_size.x = 180
	for pname in PRESET_NAMES:
		_preset_option.add_item(pname)
	_preset_option.item_selected.connect(_on_preset_selected)
	prow.add_child(_preset_option)
	preset_card.add_child(prow)

	var quick_card := _make_section_card(vbox, "Core Recording & Damage Tuning",
		"Changes sync immediately with Project Settings and the 50-Entity Budget Estimator.")
	for qpath: String in QUICK_SETTING_PATHS:
		var def := _find_setting_def(qpath)
		if def.is_empty():
			continue
		var qctrl := _make_setting_control_widget(def, true)
		_add_labeled_row(quick_card, qpath.get_file().capitalize(), "%s\n(%s)" % [str(def[4]), qpath], qctrl)
		_quick_controls[qpath] = qctrl

	var budget_card := _make_section_card(vbox, "50-Entity Budget Estimator",
		"Estimated recording footprint for 50 active entities (~65% moving/changing per sample, 18 B/sample avg).")
	_budget_bar = ProgressBar.new()
	_budget_bar.min_value = 0.0
	_budget_bar.max_value = 120.0
	_budget_bar.show_percentage = false
	_budget_bar.custom_minimum_size.y = 14
	budget_card.add_child(_budget_bar)

	_budget_label = RichTextLabel.new()
	_budget_label.bbcode_enabled = true
	_budget_label.fit_content = true
	_budget_label.scroll_active = false
	_budget_label.add_theme_font_size_override(&"normal_font_size", 11)
	budget_card.add_child(_budget_label)

	return vbox


# ---- Tab 2: Recordings (.reee Browser & Inspector) ------------------------------------------------

func _build_recordings_tab() -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override(&"separation", 8)

	var browser_card := _make_section_card(vbox, "Saved Recordings (.reee)",
		"Inspect metadata, entity schemas, timeline events, and damage logs without launching playback.")

	var picker_row := HBoxContainer.new()
	picker_row.add_theme_constant_override(&"separation", 4)
	_rec_picker = OptionButton.new()
	_rec_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rec_picker.clip_text = true
	_rec_picker.item_selected.connect(_on_recording_picker_selected)
	picker_row.add_child(_rec_picker)
	picker_row.add_child(_btn("Refresh", _refresh_recordings_list, &"Reload",
		"Rescan the configured replays directory."))
	picker_row.add_child(_btn("Browse...", _on_browse_reee_file, &"Folder",
		"Open any .reee file from disk."))
	picker_row.add_child(_btn("Sample", _on_inspect_demo_sample, &"Play",
		"Inspect the built-in demo sample_playback.reee."))
	picker_row.add_child(_btn("Recover .part", _on_recover_part_files, &"Tools",
		"Scan for leftover .reee.part partial files in the replays directory."))
	browser_card.add_child(picker_row)

	var tl_card := _make_section_card(vbox, "Timeline Events & Damage Log",
		"Filter markers, notes, damage/heal entries, and cues.")
	var tl_filter_row := HBoxContainer.new()
	tl_filter_row.add_theme_constant_override(&"separation", 4)
	_rec_event_filter = OptionButton.new()
	for label_str in ["All Events", "Markers & Notes", "Damage & Heal", "Cues & Other"]:
		_rec_event_filter.add_item(label_str)
	_rec_event_filter.item_selected.connect(func(_idx: int) -> void: _rebuild_rec_event_tree())
	tl_filter_row.add_child(_rec_event_filter)

	_rec_event_search = LineEdit.new()
	_rec_event_search.placeholder_text = "Search actor, source, label..."
	_rec_event_search.clear_button_enabled = true
	_rec_event_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rec_event_search.text_changed.connect(func(_t: String) -> void: _rebuild_rec_event_tree())
	tl_filter_row.add_child(_rec_event_search)
	tl_filter_row.add_child(_btn("Diff vs Sample", _on_diff_vs_sample, &"Search",
		"Compare the currently inspected .reee against the built-in sample_playback.reee using REEEplayDiff."))
	tl_card.add_child(tl_filter_row)

	_rec_event_tree = Tree.new()
	_rec_event_tree.custom_minimum_size = Vector2(0, 170)
	_rec_event_tree.columns = 4
	_rec_event_tree.column_titles_visible = true
	_rec_event_tree.set_column_title(0, "Time")
	_rec_event_tree.set_column_title(1, "Tick")
	_rec_event_tree.set_column_title(2, "Type")
	_rec_event_tree.set_column_title(3, "Details")
	_rec_event_tree.set_column_expand(0, false)
	_rec_event_tree.set_column_custom_minimum_width(0, 56)
	_rec_event_tree.set_column_expand(1, false)
	_rec_event_tree.set_column_custom_minimum_width(1, 50)
	_rec_event_tree.set_column_expand(2, false)
	_rec_event_tree.set_column_custom_minimum_width(2, 110)
	_rec_event_tree.set_column_expand(3, true)
	_rec_event_tree.hide_root = true
	_rec_event_tree.item_selected.connect(_on_rec_event_selected)
	tl_card.add_child(_rec_event_tree)

	var insp_card := _make_section_card(vbox, ".reee File Inspector")
	_rec_output = RichTextLabel.new()
	_rec_output.bbcode_enabled = true
	_rec_output.fit_content = true
	_rec_output.selection_enabled = true
	_rec_output.scroll_active = false
	_rec_output.add_theme_font_size_override(&"normal_font_size", 11)
	_rec_output.text = "Select a recording above or click [b]Browse...[/b] to inspect a .reee file."
	insp_card.add_child(_rec_output)

	return vbox


# ---- Tab 3: Settings (All REEEplaySettings.DEFS — Advanced) ---------------------------------------

func _build_settings_tab() -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override(&"separation", 6)

	var hdr_card := _make_section_card(vbox, "Project Settings (REEEplay)",
		"Edits apply straight into Project Settings and persist across editor restarts.")
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override(&"separation", 4)

	_settings_filter = LineEdit.new()
	_settings_filter.placeholder_text = "Filter project settings..."
	_settings_filter.clear_button_enabled = true
	_settings_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_filter.text_changed.connect(_on_filter_settings)
	filter_row.add_child(_settings_filter)

	filter_row.add_child(_btn("Reset All", _reset_all_settings, &"Reload",
		"Reset every REEEplay setting back to its factory default."))
	hdr_card.add_child(filter_row)

	_settings_list = VBoxContainer.new()
	_settings_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_list.add_theme_constant_override(&"separation", 4)
	vbox.add_child(_settings_list)

	_populate_project_settings()
	return vbox


func _populate_project_settings() -> void:
	if _settings_list == null:
		return
	for child in _settings_list.get_children():
		child.queue_free()
	_setting_controls.clear()
	_setting_rows.clear()

	var current_group := ""
	var current_card_box: VBoxContainer = null

	for d: Array in REEEplaySettings.DEFS:
		var path := str(d[0])
		var parts := path.split("/")
		var group_name := parts[1].capitalize() if parts.size() > 1 else "General"
		if group_name != current_group:
			current_group = group_name
			current_card_box = _make_section_card(_settings_list, current_group)
		var row := _build_setting_row(d)
		current_card_box.add_child(row)
		_setting_rows[path] = row


func _build_setting_row(d: Array) -> Control:
	var path := str(d[0])
	var def_val: Variant = d[1]
	var desc := str(d[4])

	var row := HBoxContainer.new()
	row.tooltip_text = desc
	var lbl := Label.new()
	lbl.text = path.get_file().capitalize()
	lbl.tooltip_text = "%s\n(%s)" % [desc, path]
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.clip_text = true
	lbl.add_theme_font_size_override(&"font_size", 11)
	row.add_child(lbl)

	var ctrl := _make_setting_control_widget(d, false)
	ctrl.tooltip_text = desc
	row.add_child(ctrl)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.flat = true
	reset_btn.tooltip_text = "Reset to %s" % str(def_val)
	reset_btn.pressed.connect(func() -> void: _reset_setting(path))
	row.add_child(reset_btn)

	_setting_controls[path] = ctrl
	return row


func _make_setting_control_widget(d: Array, is_quick: bool) -> Control:
	var path := str(d[0])
	var def_val: Variant = d[1]
	var hint_type := int(d[2])
	var hint_str := str(d[3])
	var val: Variant = ProjectSettings.get_setting(path, def_val)

	if typeof(def_val) == TYPE_BOOL:
		var cb := CheckBox.new()
		cb.button_pressed = bool(val)
		cb.toggled.connect(func(on: bool) -> void: _apply_project_setting(path, on))
		return cb

	if hint_type == PROPERTY_HINT_ENUM:
		var opt := OptionButton.new()
		opt.custom_minimum_size.x = 135
		var items := _parse_enum_hint(hint_str)
		var sel_idx := 0
		for i in range(items.size()):
			var entry: Array = items[i]
			opt.add_item(str(entry[0]))
			opt.set_item_metadata(i, entry[1])
			if typeof(def_val) == TYPE_INT and int(val) == int(entry[1]):
				sel_idx = i
			elif typeof(def_val) == TYPE_STRING and str(val) == str(entry[1]):
				sel_idx = i
		opt.select(sel_idx)
		opt.item_selected.connect(func(idx: int) -> void:
			var meta_val: Variant = opt.get_item_metadata(idx)
			var typed_val: Variant = int(meta_val) if typeof(def_val) == TYPE_INT else str(meta_val)
			_apply_project_setting(path, typed_val)
		)
		return opt

	if typeof(def_val) == TYPE_INT or typeof(def_val) == TYPE_FLOAT:
		var sp := SpinBox.new()
		var r := _parse_range_hint(hint_str)
		sp.min_value = float(r[0])
		sp.max_value = float(r[1])
		sp.step = 1.0 if typeof(def_val) == TYPE_INT else float(r[2])
		sp.allow_greater = bool(r[3])
		sp.suffix = str(r[4])
		sp.custom_minimum_size.x = 110 if not is_quick else 125
		sp.value = float(val)
		sp.value_changed.connect(func(v: float) -> void:
			var cast_val: Variant = int(roundi(v)) if typeof(def_val) == TYPE_INT else float(v)
			_apply_project_setting(path, cast_val)
		)
		return sp

	var le := LineEdit.new()
	le.custom_minimum_size.x = 140
	le.text = _format_line_setting_value(def_val, val)
	if typeof(def_val) == TYPE_PACKED_FLOAT32_ARRAY:
		le.tooltip_text = "Comma-separated float speeds (e.g. 0.25, 0.5, 1, 2, 4)"
	var commit_fn := func() -> void:
		_apply_project_setting(path, _parse_line_setting_value(def_val, le.text))
	le.text_submitted.connect(func(_t: String) -> void: commit_fn.call())
	le.focus_exited.connect(commit_fn)
	return le


# ---- ProjectSettings Sync & Callbacks -------------------------------------------------------------

const PRESET_OVERRIDDEN_PATHS := {
	"reeeplay/recording/sample_rate": true,
	"reeeplay/recording/tick_rate": true,
	"reeeplay/recording/default_mode": true,
	"reeeplay/recording/ring_buffer_seconds": true,
	"reeeplay/recording/keyframe_interval_seconds": true,
	"reeeplay/recording/epsilon_scale": true,
}

func _apply_project_setting(path: String, value: Variant) -> void:
	if _updating_ui:
		return
	if PRESET_OVERRIDDEN_PATHS.has(path) and int(ProjectSettings.get_setting("reeeplay/recording/preset", REEEplayPreset.Kind.CUSTOM)) != REEEplayPreset.Kind.CUSTOM:
		ProjectSettings.set_setting("reeeplay/recording/preset", int(REEEplayPreset.Kind.CUSTOM))
		_sync_control_value(_setting_controls.get("reeeplay/recording/preset", null), _find_setting_def("reeeplay/recording/preset"), int(REEEplayPreset.Kind.CUSTOM))
	if ProjectSettings.get_setting(path) != value:
		ProjectSettings.set_setting(path, value)
		if persist:
			ProjectSettings.save()
		setting_changed.emit(path, value)
	var def := _find_setting_def(path)
	_sync_control_value(_setting_controls.get(path, null), def, value)
	_sync_control_value(_quick_controls.get(path, null), def, value)
	_sync_control_value(_simple_controls.get(path, null), def, value)
	_refresh_presets_and_budget()


func _reset_setting(path: String) -> void:
	var def := _find_setting_def(path)
	if def.is_empty():
		return
	_apply_project_setting(path, def[1])


func _reset_all_settings() -> void:
	for d: Array in REEEplaySettings.DEFS:
		_apply_project_setting(str(d[0]), d[1])
	refresh()


## Re-reads all REEEplaySettings values from ProjectSettings without triggering writes.
func refresh() -> void:
	_updating_ui = true
	for d: Array in REEEplaySettings.DEFS:
		var path := str(d[0])
		var val: Variant = ProjectSettings.get_setting(path, d[1])
		_sync_control_value(_setting_controls.get(path, null), d, val)
		_sync_control_value(_quick_controls.get(path, null), d, val)
		_sync_control_value(_simple_controls.get(path, null), d, val)
	_updating_ui = false
	_refresh_presets_and_budget()
	refresh_selection()


## Alias expected by EditorPlugin.settings_changed hooks.
func _reload_settings_editor() -> void:
	refresh()


func _sync_control_value(c: Variant, d: Array, value: Variant) -> void:
	if c == null or d.is_empty():
		return
	var def_val: Variant = d[1]
	if c is CheckBox:
		(c as CheckBox).set_pressed_no_signal(bool(value))
	elif c is HSlider:
		(c as HSlider).set_value_no_signal(float(value))
	elif c is OptionButton:
		var opt := c as OptionButton
		for i in range(opt.item_count):
			var meta_val: Variant = opt.get_item_metadata(i)
			if typeof(def_val) == TYPE_INT and int(meta_val) == int(value):
				opt.select(i)
				break
			if typeof(def_val) == TYPE_STRING and str(meta_val) == str(value):
				opt.select(i)
				break
	elif c is SpinBox:
		(c as SpinBox).set_value_no_signal(float(value))
	elif c is LineEdit:
		(c as LineEdit).text = _format_line_setting_value(def_val, value)


func _on_filter_settings(query: String) -> void:
	var q := query.strip_edges().to_lower()
	for path: String in _setting_rows.keys():
		var row := _setting_rows[path] as Control
		if row != null:
			row.visible = q.is_empty() or path.to_lower().contains(q) or row.tooltip_text.to_lower().contains(q)


func _on_preset_selected(idx: int) -> void:
	if _updating_ui:
		return
	var kind := clampi(idx, 0, REEEplayPreset.Kind.CUSTOM) as REEEplayPreset.Kind
	_updating_ui = true
	ProjectSettings.set_setting("reeeplay/recording/preset", int(kind))
	if kind != REEEplayPreset.Kind.CUSTOM:
		var p := REEEplayPreset.from_kind(kind)
		ProjectSettings.set_setting("reeeplay/recording/tick_rate", p.tick_rate)
		ProjectSettings.set_setting("reeeplay/recording/sample_rate", float(p.sample_rate))
		ProjectSettings.set_setting("reeeplay/recording/default_mode", int(p.recording_mode))
		ProjectSettings.set_setting("reeeplay/recording/ring_buffer_seconds", p.ring_buffer_seconds)
		ProjectSettings.set_setting("reeeplay/recording/keyframe_interval_seconds", p.keyframe_interval_seconds)
		ProjectSettings.set_setting("reeeplay/recording/epsilon_scale", p.epsilon_scale)
	var sess := _find_scene_session()
	if sess != null:
		sess.preset_kind = kind
	if persist:
		ProjectSettings.save()
	_updating_ui = false
	refresh()
	setting_changed.emit("reeeplay/recording/preset", int(kind))


func _refresh_presets_and_budget() -> void:
	var p_kind := clampi(int(REEEplaySettings.value(&"reeeplay/recording/preset")), 0, PRESET_NAMES.size() - 1)
	if _preset_option != null:
		_preset_option.select(p_kind)
	if _simple_preset_option != null:
		_simple_preset_option.select(p_kind)

	var sample_hz := float(REEEplaySettings.value(&"reeeplay/recording/sample_rate"))
	var tick_hz := int(REEEplaySettings.value(&"reeeplay/recording/tick_rate"))
	var kf_sec := float(REEEplaySettings.value(&"reeeplay/recording/keyframe_interval_seconds"))
	if p_kind != REEEplayPreset.Kind.CUSTOM:
		var preset := REEEplayPreset.from_kind(p_kind as REEEplayPreset.Kind)
		sample_hz = float(preset.sample_rate)
		tick_hz = preset.tick_rate
		kf_sec = preset.keyframe_interval_seconds
	var resolved_tick := tick_hz if tick_hz > 0 else Engine.physics_ticks_per_second
	var div := maxi(1, roundi(float(resolved_tick) / maxf(0.1, sample_hz)))
	var eff_hz := float(resolved_tick) / float(div)

	if _simple_rate_value_lbl != null:
		var desc := "Balanced"
		if eff_hz <= 10.0:
			desc = "Light"
		elif eff_hz >= 45.0:
			desc = "Crisp"
		elif eff_hz >= 28.0:
			desc = "Smooth"
		_simple_rate_value_lbl.text = "%.0f Hz · %s" % [eff_hz, desc]
	if _simple_rate_slider != null:
		_simple_rate_slider.set_value_no_signal(clampf(sample_hz, _simple_rate_slider.min_value, _simple_rate_slider.max_value))

	var est := REEEplayAuthoring.estimate_budget(eff_hz, 50, 18.0, kf_sec, 0.65)
	if _budget_bar != null:
		_budget_bar.value = clampf(float(est["kb_per_sec"]), 0.0, _budget_bar.max_value)
	if _budget_label != null:
		_budget_label.text = (
			"[b]Effective Rate:[/b] %.1f Hz (%d tick/s, div %d)\n"
			+"[b]50-Entity Est.:[/b] ~%.1f KB/s  |  ~%.2f MB/min  |  ~%.1f MB/hour\n"
			+"[b]CPU & Seek:[/b] ~%.2f ms/peak tick  |  Keyframe interval %.1f s"
		) % [
			eff_hz, resolved_tick, div,
			float(est["kb_per_sec"]), float(est["mb_per_min"]), float(est["mb_per_hour"]),
			float(est["est_tick_ms"]), float(est["keyframe_interval_sec"]),
		]
	if _simple_budget_bar != null:
		_simple_budget_bar.value = clampf(float(est["kb_per_sec"]), 0.0, _simple_budget_bar.max_value)
	if _simple_budget_label != null:
		_simple_budget_label.text = "[b]Est. Footprint (50 entities):[/b] ~%.1f KB/s  ·  ~%.1f MB/hour" % [
			float(est["kb_per_sec"]), float(est["mb_per_hour"])
		]


# ---- Scene Discovery & Tracked Node Authoring -----------------------------------------------------

## Refreshes the target selector, Simple setup cards, readiness checklist, and tracked properties.
func refresh_selection() -> void:
	if _selection_pill == null:
		return
	_rebuild_target_picker()
	_refresh_simple_session_card()

	var target := _active_target_node()
	if target is REEEplayTracked:
		_render_tracked_selection(target as REEEplayTracked)
	elif target is REEEplaySession:
		_render_session_selection(target as REEEplaySession)
	else:
		_selection_pill.text = "No target"
		_selection_pill.modulate = Color(0.65, 0.72, 0.8)
		_refresh_checklist(null)
		_set_track_fields_enabled(false)
		_sync_simple_entity_card(null)
		if _rate_readout_label != null:
			_rate_readout_label.text = "Select a node and click [b]+ Track Node[/b], or select an existing [b]REEEplayTracked[/b]."


func _refresh_simple_session_card() -> void:
	if _simple_session_status == null:
		return
	var sess := _find_scene_session()
	if sess == null:
		_simple_session_status.text = "○ No REEEplaySession in this scene yet. Add one for zero-code recording."
		_simple_session_status.modulate = Color(0.95, 0.78, 0.42)
		_simple_add_session_btn.disabled = false
		_simple_select_session_btn.disabled = true
		_simple_auto_start_check.disabled = true
		_simple_auto_save_exit_check.disabled = true
		_simple_auto_start_check.set_pressed_no_signal(false)
		_simple_auto_save_exit_check.set_pressed_no_signal(false)
	else:
		_simple_session_status.text = "✓ Scene Recorder ready: %s" % sess.name
		_simple_session_status.modulate = Color(0.45, 0.92, 0.58)
		_simple_add_session_btn.disabled = true
		_simple_select_session_btn.disabled = false
		_simple_auto_start_check.disabled = false
		_simple_auto_save_exit_check.disabled = false
		_simple_auto_start_check.set_pressed_no_signal(sess.auto_start_on_ready)
		_simple_auto_save_exit_check.set_pressed_no_signal(sess.auto_save_on_exit)


func _sync_simple_entity_card(tracked: REEEplayTracked) -> void:
	if _simple_entity_card == null:
		return
	if tracked == null:
		_simple_entity_card.visible = false
		_simple_entity_hint.visible = true
		return
	_simple_entity_card.visible = true
	_simple_entity_hint.visible = false
	_updating_ui = true
	_simple_display_name_edit.text = tracked.display_name
	_simple_team_spin.set_value_no_signal(float(tracked.team_id))
	_updating_ui = false


func _render_tracked_selection(tracked: REEEplayTracked) -> void:
	var diag := REEEplayAuthoring.diagnose_tracked(tracked)
	var ready := bool(diag.get("ready", false))
	_selection_pill.text = ("%s · %s" % [tracked.name, str(diag.get("summary", ""))])
	_selection_pill.modulate = Color(0.45, 0.92, 0.58) if ready else Color(1.0, 0.78, 0.32)
	_refresh_checklist(diag.get("checks", []))
	_set_track_fields_enabled(true)
	_sync_simple_entity_card(tracked)

	_updating_ui = true
	_auto_track_check.set_pressed_no_signal(tracked.auto_track)
	_fallback_check.set_pressed_no_signal(tracked.fallback_to_source_scene)
	_arch_id_edit.text = String(tracked.archetype_id)
	_stable_key_edit.text = String(tracked.stable_key)
	_display_name_edit.text = tracked.display_name
	_team_spin.set_value_no_signal(float(tracked.team_id))
	_priority_spin.set_value_no_signal(float(tracked.priority))
	_entity_rate_spin.set_value_no_signal(tracked.sample_rate)
	_updating_ui = false

	if _rate_readout_label != null:
		_rate_readout_label.text = "[b]Resolved Rate:[/b] %.1f Hz (%s)\n[b]Est. Bandwidth:[/b] ~%.0f B/s (%d explicit channels)" % [
			float(diag.get("effective_hz", 0.0)),
			str(diag.get("rate_chain", "")),
			float(diag.get("bytes_per_sec", 0.0)),
			int(diag.get("channel_count", 0)),
		]
	_rebuild_channels_list(tracked)


func _render_session_selection(session: REEEplaySession) -> void:
	_selection_pill.text = "Session: %s" % session.name
	_selection_pill.modulate = Color(0.45, 0.85, 1.0)
	var pname := str(REEEplayPreset.Kind.keys()[clampi(int(session.preset_kind), 0, REEEplayPreset.Kind.size() - 1)])
	_refresh_checklist([
		{"ok": true, "severity": "ok", "title": "Session", "detail": session.name},
		{"ok": true, "severity": "ok", "title": "Preset", "detail": pname},
		{"ok": session.auto_start_on_ready, "severity": "ok" if session.auto_start_on_ready else "warn", "title": "Auto Start", "detail": "Enabled" if session.auto_start_on_ready else "Manual start_recording()"},
	])
	_set_track_fields_enabled(false)
	_sync_simple_entity_card(null)
	if _rate_readout_label != null:
		_rate_readout_label.text = "[b]REEEplaySession:[/b] %s (preset=%s, auto_start=%s, auto_save=%s)" % [
			session.name, pname, str(session.auto_start_on_ready), str(session.auto_save_on_exit)
		]


func _find_scene_session() -> REEEplaySession:
	var root := _edited_scene_root()
	if root != null:
		var all := REEEplayAuthoring.find_all_sessions(root)
		if not all.is_empty():
			return all[0]
	if is_instance_valid(_pinned_target) and _pinned_target is REEEplaySession:
		return _pinned_target as REEEplaySession
	return null


func _set_scene_session_prop(prop: StringName, val: Variant) -> void:
	if _updating_ui:
		return
	var sess := _find_scene_session()
	if sess == null:
		return
	sess.set(prop, val)
	sess.notify_property_list_changed()
	_refresh_simple_session_card()


func _on_select_scene_session() -> void:
	var sess := _find_scene_session()
	if sess == null:
		return
	_pinned_target = sess
	_on_focus_active_target()
	refresh_selection()


func _on_auto_setup_scene() -> void:
	var scene_root := EditorInterface.get_edited_scene_root() if Engine.is_editor_hint() else null
	if scene_root == null:
		if _simple_setup_output != null:
			_simple_setup_output.text = "[color=#f5c242]Open a scene first to run Auto-Setup.[/color]"
		return
	var res := REEEplayAuthoring.auto_setup_scene(scene_root)
	var added: Array = res.get("tracked_added", [])
	var existing_count := int(res.get("tracked_existing", 0))
	var sess_msg := "Added REEEplaySession (auto-start & save)" if bool(res.get("session_created", false)) else "REEEplaySession already present"
	if _simple_setup_output != null:
		_simple_setup_output.text = "[color=#6be689]Auto-Setup complete:[/color] %s | +%d tracked (%s) | %d already tracked." % [
			sess_msg, added.size(), ", ".join(added) if not added.is_empty() else "none", existing_count
		]
	refresh_selection()


func _rebuild_target_picker() -> void:
	if _target_picker == null:
		return
	_target_nodes.clear()
	_target_picker.clear()

	var root := _edited_scene_root()
	if root != null:
		for t in REEEplayAuthoring.find_all_tracked(root):
			_target_nodes.append(t)
		for s in REEEplayAuthoring.find_all_sessions(root):
			_target_nodes.append(s)

	if is_instance_valid(_pinned_target) and not _target_nodes.has(_pinned_target):
		_target_nodes.append(_pinned_target)

	if _target_nodes.is_empty():
		_target_picker.add_item("No REEEplayTracked / Session")
		_target_picker.disabled = true
		return

	_target_picker.disabled = false
	var active := _active_target_node()
	var sel_idx := 0
	for i in range(_target_nodes.size()):
		var n := _target_nodes[i]
		var prefix := (n.get_parent().name + "/") if n.get_parent() != null else ""
		var tag := "[T]" if n is REEEplayTracked else "[S]"
		_target_picker.add_item("%s %s%s" % [tag, prefix, n.name])
		if n == active:
			sel_idx = i
	_target_picker.select(sel_idx)


func _active_target_node() -> Node:
	if is_instance_valid(_pinned_target):
		return _pinned_target
	var editor := _editor_interface()
	if editor != null:
		var sel := editor.call(&"get_selection")
		if sel != null:
			var nodes: Array = sel.call(&"get_selected_nodes")
			for n in nodes:
				if n is REEEplaySession:
					return n as Node
				var found := REEEplayAuthoring.find_tracked_for_node(n as Node)
				if found != null:
					return found
	if not _target_nodes.is_empty():
		return _target_nodes[0]
	return null


func _on_target_picker_selected(idx: int) -> void:
	if idx >= 0 and idx < _target_nodes.size():
		_pinned_target = _target_nodes[idx]
		refresh_selection()


func _on_focus_active_target() -> void:
	var target := _active_target_node()
	var editor := _editor_interface()
	if target == null or editor == null:
		return
	var sel := editor.call(&"get_selection")
	if sel != null:
		sel.call(&"clear")
		sel.call(&"add_node", target)
	editor.call(&"edit_node", target)


func _selected_scene_node() -> Node:
	var root := _edited_scene_root()
	var editor := _editor_interface()
	if editor != null:
		var sel := editor.call(&"get_selection")
		if sel != null:
			var nodes: Array = sel.call(&"get_selected_nodes")
			if not nodes.is_empty():
				return nodes[0] as Node
	return root


func _on_track_selected_node() -> void:
	var root := _edited_scene_root()
	var target_parent := _selected_scene_node()
	if target_parent == null:
		_log_setup("[color=#f5c242]Open a scene or select a node in the Scene Tree first.[/color]")
		return
	var tracked := REEEplayAuthoring.auto_setup_node(target_parent, root)
	_pinned_target = tracked
	refresh_selection()
	_log_setup("[color=#6be689]Tracked node ready:[/color] %s (%d channels)" % [tracked.name, tracked.custom_channels.size()])


func _on_track_skeleton_node() -> void:
	var root := _edited_scene_root()
	var base := _selected_scene_node()
	if base == null:
		_log_setup("[color=#f5c242]Open a scene or select a character node first.[/color]")
		return
	var skel := REEEplayAuthoring.find_skeleton_near(base)
	if skel == null:
		_log_setup("[color=#f5c242]No Skeleton3D found on or under '%s'.[/color]" % base.name)
		return
	var tracked := REEEplayAuthoring.auto_setup_node(skel, root)
	_pinned_target = tracked
	refresh_selection()
	_log_setup("[color=#6be689]Skeleton3D tracked:[/color] %s (%d channels)" % [skel.name, tracked.custom_channels.size()])


func _on_create_session_node(auto_enable: bool = true) -> void:
	var root := _edited_scene_root()
	if root == null:
		_log_setup("[color=#f5c242]Open a scene before creating a REEEplaySession.[/color]")
		return
	var sess := REEEplaySession.new()
	sess.name = "REEEplaySession"
	if auto_enable:
		sess.auto_start_on_ready = true
		sess.auto_save_on_exit = true
		sess.preset_kind = int(REEEplaySettings.value(&"reeeplay/recording/preset")) as REEEplayPreset.Kind
	root.add_child(sess)
	sess.owner = root
	_pinned_target = sess
	refresh_selection()
	_log_setup("[color=#6be689]Added REEEplaySession[/color] under %s." % root.name)


func _on_auto_setup_tracked() -> void:
	var t := _active_target_node() as REEEplayTracked
	if t == null:
		_on_track_selected_node()
		return
	REEEplayAuthoring.auto_setup_node(t.get_effective_target(), _edited_scene_root())
	refresh_selection()
	_log_setup("[color=#6be689]Auto-configured[/color] %s." % t.name)


func _quick_add_channel(preset_key: StringName) -> void:
	var t := _active_target_node() as REEEplayTracked
	if t == null:
		_log_setup("[color=#f5c242]Select a REEEplayTracked node first.[/color]")
		return
	var added := REEEplayAuthoring.add_channel_preset(t, preset_key)
	refresh_selection()
	_log_setup("[color=#6be689]Added %d channel(s)[/color] from '%s'." % [added, String(preset_key)])


func _on_add_channel_preset_id(id: int) -> void:
	if id < 0 or id >= CHANNEL_PRESET_ITEMS.size():
		return
	_quick_add_channel(CHANNEL_PRESET_ITEMS[id][1] as StringName)


func _on_generate_proxy() -> void:
	var t := _active_target_node() as REEEplayTracked
	if t == null:
		_log_setup("[color=#f5c242]Select a REEEplayTracked node first.[/color]")
		return
	var target := t.get_effective_target()
	var save_path := ""
	if target != null and not target.scene_file_path.is_empty():
		var base := target.scene_file_path.get_basename()
		save_path = "%s_proxy.tscn" % base
	var res := REEEplayAuthoring.generate_proxy_scene(t, save_path)
	refresh_selection()
	var col := "#6be689" if bool(res.get("ok", false)) else "#ff6b6b"
	_log_setup("[color=%s]%s[/color]" % [col, str(res.get("message", ""))])


func _set_tracked_prop(prop: StringName, val: Variant) -> void:
	if _updating_ui:
		return
	var t := _active_target_node() as REEEplayTracked
	if t == null:
		return
	t.set(prop, val)
	t.notify_property_list_changed()
	if prop == &"display_name":
		if _display_name_edit != null and _display_name_edit.text != str(val):
			_display_name_edit.text = str(val)
		if _simple_display_name_edit != null and _simple_display_name_edit.text != str(val):
			_simple_display_name_edit.text = str(val)
	elif prop == &"team_id":
		if _team_spin != null:
			_team_spin.set_value_no_signal(float(val))
		if _simple_team_spin != null:
			_simple_team_spin.set_value_no_signal(float(val))


func _set_track_fields_enabled(enabled: bool) -> void:
	if _auto_track_check != null:
		_auto_track_check.disabled = not enabled
	if _fallback_check != null:
		_fallback_check.disabled = not enabled
	if _arch_id_edit != null:
		_arch_id_edit.editable = enabled
	if _stable_key_edit != null:
		_stable_key_edit.editable = enabled
	if _display_name_edit != null:
		_display_name_edit.editable = enabled
	if _team_spin != null:
		_team_spin.editable = enabled
	if _priority_spin != null:
		_priority_spin.editable = enabled
	if _entity_rate_spin != null:
		_entity_rate_spin.editable = enabled


func _refresh_checklist(checks: Variant) -> void:
	if _checklist_box == null:
		return
	for child in _checklist_box.get_children():
		child.queue_free()
	if not (checks is Array) or (checks as Array).is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No REEEplayTracked node selected. Use '+ Track Node' above to track the selected node."
		empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty_lbl.add_theme_font_size_override(&"font_size", 11)
		empty_lbl.modulate = Color(0.68, 0.74, 0.82)
		_checklist_box.add_child(empty_lbl)
		return

	for item: Dictionary in (checks as Array):
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 6)
		var ok := bool(item.get("ok", false))
		var sev := str(item.get("severity", "ok"))
		var status_lbl := Label.new()
		status_lbl.text = "✓" if ok else ("!" if sev == "warn" else "✕")
		status_lbl.modulate = Color(0.42, 0.92, 0.56) if ok else (Color(0.98, 0.76, 0.28) if sev == "warn" else Color(1.0, 0.44, 0.44))
		status_lbl.add_theme_font_size_override(&"font_size", 12)
		row.add_child(status_lbl)

		var name_lbl := Label.new()
		name_lbl.text = str(item.get("title", "")) + ":"
		name_lbl.custom_minimum_size.x = 85
		name_lbl.add_theme_font_size_override(&"font_size", 11)
		row.add_child(name_lbl)

		var det_lbl := Label.new()
		det_lbl.text = str(item.get("detail", ""))
		det_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		det_lbl.clip_text = true
		det_lbl.add_theme_font_size_override(&"font_size", 11)
		row.add_child(det_lbl)
		_checklist_box.add_child(row)


func _rebuild_channels_list(tracked: REEEplayTracked) -> void:
	if _channels_list == null:
		return
	for child in _channels_list.get_children():
		child.queue_free()
	if tracked == null or tracked.custom_channels.is_empty():
		var none := Label.new()
		none.text = "  (Using archetype channels or automatic transform inference)"
		none.add_theme_font_size_override(&"font_size", 11)
		none.modulate = Color(0.65, 0.7, 0.75)
		_channels_list.add_child(none)
		return
	for i in range(tracked.custom_channels.size()):
		var ch := tracked.custom_channels[i]
		if ch == null:
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 4)
		var lbl := Label.new()
		lbl.text = "  • %s  (%s)  [%s]" % [String(ch.effective_name()), ch.property_path, _codec_name(ch.codec)]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.clip_text = true
		lbl.add_theme_font_size_override(&"font_size", 11)
		row.add_child(lbl)

		var rm_btn := Button.new()
		rm_btn.text = "✕"
		rm_btn.flat = true
		rm_btn.tooltip_text = "Remove channel '%s'" % String(ch.effective_name())
		var idx := i
		rm_btn.pressed.connect(func() -> void:
			var arr := tracked.custom_channels.duplicate()
			if idx >= 0 and idx < arr.size():
				arr.remove_at(idx)
				tracked.custom_channels = arr
				refresh_selection()
		)
		row.add_child(rm_btn)
		_channels_list.add_child(row)


# ---- Recordings Browser & .reee Inspector ---------------------------------------------------------

func _refresh_recordings_list() -> void:
	if _rec_picker == null:
		return
	_rec_paths.clear()
	_rec_picker.clear()

	var dir_path := str(REEEplaySettings.value(&"reeeplay/storage/directory"))
	var da := DirAccess.open(dir_path)
	var files: Array[Dictionary] = []
	if da != null:
		da.list_dir_begin()
		var fname := da.get_next()
		while not fname.is_empty():
			if not da.current_is_dir() and fname.ends_with(".reee"):
				var full := dir_path.path_join(fname)
				files.append({"name": fname, "path": full, "mtime": FileAccess.get_modified_time(full)})
			fname = da.get_next()
		da.list_dir_end()
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["mtime"]) > int(b["mtime"]))

	if files.is_empty():
		_rec_picker.add_item("No .reee files in %s" % dir_path)
		_rec_picker.disabled = true
		return

	_rec_picker.disabled = false
	for f: Dictionary in files:
		_rec_picker.add_item(str(f["name"]))
		_rec_paths.append(str(f["path"]))
	_rec_picker.select(0)
	inspect_file(_rec_paths[0])


func _on_recording_picker_selected(idx: int) -> void:
	if idx >= 0 and idx < _rec_paths.size():
		inspect_file(_rec_paths[idx])


func _on_browse_reee_file() -> void:
	if _file_dialog == null:
		return
	var dir_path := str(REEEplaySettings.value(&"reeeplay/storage/directory"))
	var glob := ProjectSettings.globalize_path(dir_path) if dir_path.begins_with("user://") or dir_path.begins_with("res://") else dir_path
	if DirAccess.dir_exists_absolute(glob):
		_file_dialog.current_dir = glob
	_file_dialog.popup_centered_ratio(0.6)


func _on_recover_part_files() -> void:
	var dir_path := str(REEEplaySettings.value(&"reeeplay/storage/directory"))
	var da := DirAccess.open(dir_path)
	if da == null:
		if _rec_output != null:
			_rec_output.text = "[color=#f5c242]Directory does not exist yet: %s[/color]" % dir_path
		return
	var found := PackedStringArray()
	da.list_dir_begin()
	var fname := da.get_next()
	while not fname.is_empty():
		if not da.current_is_dir() and fname.ends_with(".reee.part"):
			found.append(fname)
		fname = da.get_next()
	da.list_dir_end()
	if found.is_empty():
		_rec_output.text = "[color=#6be689]No leftover .reee.part files found in %s.[/color]" % dir_path
	else:
		_rec_output.text = "[color=#f5c242]Found %d .reee.part file(s):[/color] %s" % [found.size(), ", ".join(found)]


## Inspects a .reee file on disk and formats Summary, Entities, Events, and Damage Logs into the dock.
func inspect_file(path: String) -> void:
	if _rec_output == null:
		return
	var info := REEEplayAuthoring.inspect_reee_file(path)
	if not bool(info.get("ok", false)):
		_rec_inspected_info = {}
		_rec_inspected_path = ""
		_rebuild_rec_event_tree()
		_rec_output.text = "[color=#ff6b6b]Failed to inspect %s:[/color] %s" % [path, str(info.get("error_message", ""))]
		return
	_rec_inspected_info = info
	_rec_inspected_path = path
	_rebuild_rec_event_tree()

	var s: Dictionary = info["summary"]
	var b: Dictionary = info["blocks"]
	var ents: Array = info["entities"]
	var evs: Array = info["events"]
	var dmg: Array = info["damage"]

	var lines := PackedStringArray()
	lines.append("[b]File:[/b] %s  (%.1f KB)" % [path.get_file(), float(info["file_size_bytes"]) / 1024.0])
	lines.append("[b]ID / Game:[/b] %s  |  %s v%s" % [str(s["recording_id"]), str(s["game_id"]), str(s["game_version"])])
	lines.append("[b]Timeline:[/b] %.2f s (%d ticks @ %d Hz)  |  %d blocks (%d keyframes, %d -> %d B)" % [
		float(s["duration_seconds"]), int(s["total_ticks"]), int(s["tick_rate"]),
		int(b["count"]), int(b["keyframes"]), int(b["raw_bytes"]), int(b["payload_bytes"]),
	])
	if not str(s["scene_path"]).is_empty():
		lines.append("[b]Scene:[/b] %s" % str(s["scene_path"]))

	lines.append("\n[b]Entities (%d):[/b]" % ents.size())
	var ent_limit := mini(ents.size(), 12)
	for i in range(ent_limit):
		var e: Dictionary = ents[i]
		lines.append("  #%d %s [%s] ch=[%s]" % [
			int(e["entity_id"]), str(e["display_name"]), str(e["archetype_id"]), ", ".join(e["channels"])
		])
	if ents.size() > ent_limit:
		lines.append("  ... +%d more" % (ents.size() - ent_limit))

	lines.append("\n[b]Events (%d):[/b]" % evs.size())
	var ev_limit := mini(evs.size(), 15)
	for i in range(ev_limit):
		var ev: Dictionary = evs[i]
		lines.append("  [t=%.2fs] %s: %s" % [float(ev["timestamp"]), str(ev["type_id"]), str(ev["label"])])
	if evs.size() > ev_limit:
		lines.append("  ... +%d more" % (evs.size() - ev_limit))

	lines.append("\n[b]Damage & Heal Log (%d entries):[/b]" % dmg.size())
	var dmg_limit := mini(dmg.size(), 20)
	for i in range(dmg_limit):
		var d: Dictionary = dmg[i]
		var kind_tag := "HEAL" if bool(d["is_heal"]) else ("KILL" if bool(d["is_killing_blow"]) else "DMG")
		var env_tag := " [Env]" if bool(d["is_environmental"]) else ""
		var via := (" via %s" % str(d["source_name"])) if not str(d["source_name"]).is_empty() else ""
		lines.append("  [%s]%s %s -> %s: %.1f (%s)%s" % [
			kind_tag, env_tag, str(d["actor"]), str(d["victim"]),
			float(d["amount"]), str(d["damage_type"]), via
		])
	if dmg.size() > dmg_limit:
		lines.append("  ... +%d more" % (dmg.size() - dmg_limit))

	_rec_output.text = "\n".join(lines)


func _on_inspect_demo_sample() -> void:
	var sample_path := "res://addons/reeeplay/demo/sample_playback.reee"
	if FileAccess.file_exists(sample_path):
		inspect_file(sample_path)
	elif _rec_output != null:
		_rec_output.text = "[color=#f5c242]Sample file not found: %s[/color]" % sample_path


func _on_diff_vs_sample() -> void:
	if _rec_output == null:
		return
	if _rec_inspected_path.is_empty():
		_rec_output.text = "[color=#f5c242]Inspect a .reee file first before running Diff.[/color]"
		return
	var sample_path := "res://addons/reeeplay/demo/sample_playback.reee"
	var diff := REEEplayDiff.compare_files(_rec_inspected_path, sample_path)
	_rec_output.text = diff.to_summary()


func _rebuild_rec_event_tree() -> void:
	if _rec_event_tree == null:
		return
	_rec_event_tree.clear()
	var root_item := _rec_event_tree.create_item()
	if _rec_inspected_info.is_empty():
		return

	var filter_idx := _rec_event_filter.selected if _rec_event_filter != null else 0
	var q := _rec_event_search.text.strip_edges().to_lower() if _rec_event_search != null else ""
	var tick_rate := maxi(1, int(_rec_inspected_info.get("summary", {}).get("tick_rate", 60)))

	var rows: Array[Dictionary] = []
	for d: Dictionary in _rec_inspected_info.get("damage", []):
		var kind_tag := "HEAL" if bool(d["is_heal"]) else ("KILL" if bool(d["is_killing_blow"]) else "DMG")
		var env_tag := " [Env]" if bool(d["is_environmental"]) else ""
		var via := (" via %s" % str(d["source_name"])) if not str(d["source_name"]).is_empty() else ""
		var detail := "%s -> %s: %.1f (%s)%s" % [
			str(d["actor"]), str(d["victim"]), float(d["amount"]), str(d["damage_type"]), via
		]
		var tick := int(d.get("tick", 0))
		rows.append({
			"bucket": 2,
			"tick": tick,
			"time": float(tick) / float(tick_rate),
			"type": kind_tag + env_tag,
			"details": detail,
		})

	for ev: Dictionary in _rec_inspected_info.get("events", []):
		var type_id := str(ev.get("type_id", ""))
		if type_id == "REEEplayDamageEntry":
			continue
		var is_marker := type_id == "REEEplayMarkerEvent" or type_id == "REEEplayRecordingNote"
		rows.append({
			"bucket": 1 if is_marker else 3,
			"tick": int(ev.get("tick", 0)),
			"time": float(ev.get("timestamp", 0.0)),
			"type": type_id.trim_prefix("REEEplay"),
			"details": str(ev.get("label", "")),
		})

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["tick"]) < int(b["tick"])
	)

	for r in rows:
		if filter_idx != 0 and int(r["bucket"]) != filter_idx:
			continue
		var hay := ("%s %s" % [str(r["type"]), str(r["details"])]).to_lower()
		if not q.is_empty() and not hay.contains(q):
			continue
		var item := _rec_event_tree.create_item(root_item)
		item.set_text(0, "%.2fs" % float(r["time"]))
		item.set_text(1, str(int(r["tick"])))
		item.set_text(2, str(r["type"]))
		item.set_text(3, str(r["details"]))
		item.set_metadata(0, r)


func _on_rec_event_selected() -> void:
	if _rec_event_tree == null or _rec_output == null:
		return
	var sel := _rec_event_tree.get_selected()
	if sel == null:
		return
	var meta: Variant = sel.get_metadata(0)
	if meta is Dictionary:
		var r := meta as Dictionary
		_rec_output.text = "[b]Selected Timeline Entry[/b]\n[b]Time:[/b] %.2fs (tick %d)\n[b]Type:[/b] %s\n[b]Details:[/b] %s" % [
			float(r["time"]), int(r["tick"]), str(r["type"]), str(r["details"])
		]


# ---- Parsing & UI Utilities -----------------------------------------------------------------------

static func _find_setting_def(path: String) -> Array:
	for d: Array in REEEplaySettings.DEFS:
		if str(d[0]) == path:
			return d
	return []


static func _parse_enum_hint(hint_str: String) -> Array:
	var out: Array = []
	for part in hint_str.split(","):
		var s := part.strip_edges()
		if s.is_empty():
			continue
		if s.contains(":"):
			var kv := s.split(":", true, 1)
			out.append([kv[0].strip_edges(), kv[1].strip_edges().to_int()])
		else:
			out.append([s, s])
	return out


static func _parse_range_hint(hint: String) -> Array:
	var out := [0.0, 100.0, 0.01, false, ""]
	if hint.is_empty():
		return out
	var parts := hint.split(",")
	if parts.size() >= 2:
		out[0] = parts[0].to_float()
		out[1] = parts[1].to_float()
	if parts.size() >= 3 and parts[2].is_valid_float():
		out[2] = parts[2].to_float()
	for p in parts:
		if p == "or_greater":
			out[3] = true
		elif p.begins_with("suffix:"):
			out[4] = p.trim_prefix("suffix:")
	return out


static func _format_line_setting_value(def_val: Variant, value: Variant) -> String:
	if typeof(def_val) == TYPE_PACKED_FLOAT32_ARRAY:
		var arr := value as PackedFloat32Array
		var parts := PackedStringArray()
		for v in arr:
			parts.append(str(v))
		return ", ".join(parts)
	return str(value)


static func _parse_line_setting_value(def_val: Variant, raw_text: String) -> Variant:
	if typeof(def_val) == TYPE_STRING_NAME:
		return StringName(raw_text.strip_edges())
	if typeof(def_val) == TYPE_PACKED_FLOAT32_ARRAY:
		var arr := PackedFloat32Array()
		for part in raw_text.split(","):
			var s := part.strip_edges()
			if s.is_valid_float():
				arr.append(s.to_float())
		return arr
	return raw_text.strip_edges()


static func _codec_name(codec_id: int) -> String:
	var keys := REEEplayCodec.Id.keys()
	if codec_id >= 0 and codec_id < keys.size():
		return str(keys[codec_id])
	return str(codec_id)


func _editor_interface() -> Object:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		return Engine.get_singleton(&"EditorInterface")
	return null


func _edited_scene_root() -> Node:
	var editor := _editor_interface()
	if editor == null:
		return null
	return editor.call(&"get_edited_scene_root") as Node


func _icon(icon_name: StringName) -> Texture2D:
	var editor := _editor_interface()
	if editor == null:
		return null
	var base := editor.call(&"get_base_control") as Control
	if base != null and base.has_theme_icon(icon_name, &"EditorIcons"):
		return base.get_theme_icon(icon_name, &"EditorIcons")
	return null


func _editor_color(color_name: StringName, fallback: Color = Color.WHITE) -> Color:
	var editor := _editor_interface()
	if editor != null:
		var base := editor.call(&"get_base_control") as Control
		if base != null and base.has_theme_color(color_name, &"Editor"):
			return base.get_theme_color(color_name, &"Editor")
	return fallback


func _log_setup(bbcode: String) -> void:
	if _setup_output != null:
		_setup_output.text = bbcode
	if _simple_setup_output != null:
		_simple_setup_output.text = bbcode


func _add_labeled_row(parent: Control, label_text: String, tip: String, ctrl: Control) -> void:
	var row := HBoxContainer.new()
	row.tooltip_text = tip
	var lbl := Label.new()
	lbl.text = label_text
	lbl.tooltip_text = tip
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.clip_text = true
	lbl.add_theme_font_size_override(&"font_size", 11)
	row.add_child(lbl)
	ctrl.tooltip_text = tip
	row.add_child(ctrl)
	parent.add_child(row)


func _make_card(margin: int = 6) -> PanelContainer:
	var panel := PanelContainer.new()
	var editor := _editor_interface()
	if editor != null:
		var base := editor.call(&"get_base_control") as Control
		if base != null and base.has_theme_stylebox(&"sub_inspector_bg", &"Editor"):
			var sb := base.get_theme_stylebox(&"sub_inspector_bg", &"Editor").duplicate()
			sb.set_content_margin_all(margin)
			panel.add_theme_stylebox_override(&"panel", sb)
			return panel
	var fallback := StyleBoxEmpty.new()
	fallback.set_content_margin_all(margin)
	panel.add_theme_stylebox_override(&"panel", fallback)
	return panel


func _make_section_card(parent: Control, title_text: String, subtitle_text: String = "",
		collapsed: bool = false) -> VBoxContainer:
	var wrapper := VBoxContainer.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override(&"separation", 4)

	var toggle_btn := Button.new()
	toggle_btn.text = title_text
	toggle_btn.flat = true
	toggle_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle_btn.toggle_mode = true
	toggle_btn.button_pressed = not collapsed
	toggle_btn.icon = _icon(&"GuiTreeArrowRight" if collapsed else &"GuiTreeArrowDown")
	toggle_btn.add_theme_font_size_override(&"font_size", 12)
	wrapper.add_child(toggle_btn)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override(&"separation", 5)
	body.visible = not collapsed

	if not subtitle_text.is_empty():
		var sub := Label.new()
		sub.text = subtitle_text
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sub.add_theme_font_size_override(&"font_size", 11)
		sub.add_theme_color_override(&"font_color", _editor_color(&"font_disabled_color", Color(0.65, 0.65, 0.65)))
		body.add_child(sub)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override(&"margin_left", 10)
	margin.add_theme_constant_override(&"margin_right", 2)
	margin.add_theme_constant_override(&"margin_bottom", 4)
	margin.add_child(body)
	wrapper.add_child(margin)
	wrapper.add_child(HSeparator.new())

	toggle_btn.toggled.connect(func(open: bool) -> void:
		body.visible = open
		toggle_btn.icon = _icon(&"GuiTreeArrowDown" if open else &"GuiTreeArrowRight")
	)

	parent.add_child(wrapper)
	return body


func _btn(label: String, cb: Callable, icon_name: StringName = &"", tip: String = "") -> Button:
	var b := Button.new()
	b.text = label
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.tooltip_text = tip
	if not icon_name.is_empty():
		b.icon = _icon(icon_name)
	b.pressed.connect(cb)
	return b


func _toggle_row(parent: Control, label_text: String, default_on: bool, tip: String, on_toggle: Callable) -> CheckBox:
	var row := HBoxContainer.new()
	row.tooltip_text = tip
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override(&"font_size", 11)
	row.add_child(lbl)
	var cb := CheckBox.new()
	cb.button_pressed = default_on
	cb.tooltip_text = tip
	cb.toggled.connect(on_toggle)
	row.add_child(cb)
	parent.add_child(row)
	return cb


func _line_row(parent: Control, label_text: String, placeholder: String, tip: String, on_commit: Callable) -> LineEdit:
	var row := HBoxContainer.new()
	row.tooltip_text = tip
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_font_size_override(&"font_size", 11)
	row.add_child(lbl)
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.custom_minimum_size.x = 140
	le.tooltip_text = tip
	le.text_submitted.connect(func(t: String) -> void: on_commit.call(t))
	le.focus_exited.connect(func() -> void: on_commit.call(le.text))
	row.add_child(le)
	parent.add_child(row)
	return le


func _spin_row(parent: Control, label_text: String, min_v: float, max_v: float, step: float,
		val: float, suffix_str: String = "", tip: String = "", on_change: Callable = Callable()) -> SpinBox:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = label_text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.clip_text = true
	l.tooltip_text = tip
	l.add_theme_font_size_override(&"font_size", 11)
	h.add_child(l)
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = val
	s.suffix = suffix_str
	s.custom_minimum_size.x = 110
	s.tooltip_text = tip
	if on_change.is_valid():
		s.value_changed.connect(on_change)
	h.add_child(s)
	parent.add_child(h)
	return s
