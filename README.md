# REEEplay

A data-driven replay recording, playback, damage log, and event-timeline addon for Godot 4.8+ (`Uxilo/reeeplay`).

## Features
- **State-snapshot world recording:** Physics-aligned sampling with per-entity, per-archetype, and runtime-tunable sample rates, phase staggering, presets (`SINGLEPLAYER`, `FUN_GAME`, `CASUAL`, `COMPETITIVE`, `ESPORTS`), and `REEEplayRatePolicy`.
- **Compact `.reee` binary format:** Delta + keyframe blocks, quantized/smallest-three codecs (`VEC3_Q16`, `QUAT_S3`, `SKELETON_POSE`, etc.), per-chunk zstd compression, CRC32 verification, and seek index.
- **Generic event & cue layer:** Subclass `REEEplayEvent`, `REEEplayCue`, and `REEEplayAttachment` with reflection serialization, versioning (`_migrate`), aliases, and lossless unknown-event preservation.
- **Damage pipeline:** `REEEplayDamageTracker` and `REEEplayDamageLog` for live death recaps, combat sessions, and post-match breakdowns.
- **Playback & Bring-Your-Own-UI:** `REEEplayPlayer`, `REEEplayStage` / `REEEplayStage2D`, proxy sanitization (with optional `yeet-cpp` detection), `REEEplayCamera`, and playback signals (with M5 timeline UI controls planned next).

## Running Tests

```sh
godot --headless --path . -s res://addons/reeeplay/tests/run_tests.gd
```

See [docs/reeeplay-implementation.md](docs/reeeplay-implementation.md) for the full architecture and specification.
