@tool
extends EditorPlugin

const AUTOLOAD_NAME := "REEEplay"
const AUTOLOAD_PATH := "res://addons/reeeplay/core/reeeplay_manager.gd"

const DockScript := preload("res://addons/reeeplay/editor/reeeplay_dock.gd")
const InspectorScript := preload("res://addons/reeeplay/editor/reeeplay_inspector_plugin.gd")

var _dock: REEEplayDock
var _inspector: REEEplayInspectorPlugin


func _enter_tree() -> void:
	REEEplaySettings.register()
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)

	_dock = DockScript.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	_inspector = InspectorScript.new()
	_inspector.action_performed.connect(_on_inspector_action_performed)
	add_inspector_plugin(_inspector)

	var sel := EditorInterface.get_selection()
	if sel != null and not sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.connect(_on_selection_changed)

	if not ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.connect(_on_project_settings_changed)

	if not scene_changed.is_connected(_on_scene_changed):
		scene_changed.connect(_on_scene_changed)


func _exit_tree() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if ProjectSettings.settings_changed.is_connected(_on_project_settings_changed):
		ProjectSettings.settings_changed.disconnect(_on_project_settings_changed)

	var sel := EditorInterface.get_selection()
	if sel != null and sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.disconnect(_on_selection_changed)

	if _inspector != null:
		if _inspector.action_performed.is_connected(_on_inspector_action_performed):
			_inspector.action_performed.disconnect(_on_inspector_action_performed)
		remove_inspector_plugin(_inspector)
		_inspector = null

	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _enable_plugin() -> void:
	REEEplaySettings.register()
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


func _on_selection_changed() -> void:
	if _dock != null:
		_dock.refresh_selection()


func _on_scene_changed(_scene_root: Node) -> void:
	if _dock != null:
		_dock.call_deferred(&"refresh_selection")


func _on_inspector_action_performed(_target: Object, _message: String) -> void:
	if _dock != null:
		_dock.refresh_selection()


func _on_project_settings_changed() -> void:
	if _dock != null:
		_dock._reload_settings_editor()

