# REEEplay — Map for AI Assistants & Contributors

REEEplay (`addons/reeeplay/`) is a GDScript replay addon for Godot 4.8+. See `docs/reeeplay-implementation.md` for the full specification.

## Directory Map

| Path | Purpose |
|---|---|
| `plugin.cfg`, `plugin.gd` | `EditorPlugin` registration, `REEEplay` autoload, `ProjectSettings` setup |
| `core/` | `REEEplayManager`, `REEEplayRecorder`, `REEEplayRecording`, `REEEplayTracked`, `REEEplayArchetype`, `REEEplayChannel`, `REEEplayPreset`, `REEEplayRatePolicy`, `REEEplayHighlightDetector`, `REEEplaySession`, `REEEplaySettings`, `REEEplayClock` |
| `events/` | `REEEplayEvent`, `REEEplayCue`, `REEEplayAttachment`, `REEEplayActorRef`, `REEEplayEventRegistry`, `REEEplaySerializer`, `REEEplayUnknownEvent`, and `builtin/` events/cues |
| `combat/` | `REEEplayDamageEntry`, `REEEplayDamageLog`, `REEEplayDamageTracker` |
| `io/` | `REEEplayFormat`, `REEEplayWriter`, `REEEplayReader`, `REEEplayByteUtils`, `codecs/` |
| `playback/` | `REEEplayPlayer`, `REEEplayStage`, `REEEplayStage2D`, `REEEplayProxyFactory`, `REEEplayInterpolator`, `REEEplayCamera` |
| `tests/` | Headless unit & integration suite (`run_tests.gd`) |

## Key Invariants
- `entity_id == 0` is reserved for global world state (`REEEplay.set_world_state()`); tracked entities start at `1`.
- Never use `bytes_to_var_with_objects` or `allow_objects = true` when reading `.reee` files.
- A script's `class_name` must not match the autoload name (`REEEplay` autoload -> `REEEplayManager` class).

## Running Headless Tests

```powershell
& "C:\Users\Uxilo\Godot\Editors\.editor_config\Yeet\Godot_v4.8-beta3_mono_win64_console.exe" --headless --path "c:\Users\Uxilo\Godot\Projects\Yeet" -s res://addons/reeeplay/tests/run_tests.gd
```

