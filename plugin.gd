@tool
extends EditorPlugin

const AUTOLOAD_NAME := "REEEplay"
const AUTOLOAD_PATH := "res://addons/reeeplay/core/reeeplay_manager.gd"


func _enter_tree() -> void:
	REEEplaySettings.register()


func _enable_plugin() -> void:
	REEEplaySettings.register()
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
