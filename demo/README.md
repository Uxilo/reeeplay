# REEEplay Demo

A self-contained 3D demo showing live recording, `.reee` save/load, isolated `REEEplayStage` playback with `REEEplayCamera`, timeline scrubbing, and combat damage recaps.

## How to Run

1. Open `res://addons/reeeplay/demo/reeeplay_demo.tscn` in Godot.
2. Press **F6** (**Run Current Scene**).

## Controls

- **W / A / S / D** (or Arrow Keys): Move the blue `PlayerActor` around the arena while the orange `OrbiterActor` orbits automatically.
- **R** or **Record (R)**: Start recording a clip. Press again to stop and immediately switch to `[REPLAY]` playback.
- **H** / **J** (while recording): Trigger manual damage or heal events in addition to the automatic periodic combat/environment exchanges.
- **Space** or **Play / Pause**: Toggle replay playback.
- **Speed dropdown**: Switch between `0.25x`, `0.5x`, `1.0x`, and `2.0x`.
- **Timeline slider**: Scrub through the recorded `.reee` clip.
- **Save .reee** / **Load .reee**: Persist and reload `user://reeeplay_demo/demo_clip.reee` using `REEEplayWriter` and `REEEplayReader`.
- **Back to Live**: Return from `[REPLAY]` to `[LIVE]`.

## Scene Architecture

- `REEEplaySession` — owns `REEEplayRecorder`, tracks `PlayerActor` & `OrbiterActor`, and logs damage/heal/marker events.
- `REEEplayTracked` — child components on `PlayerActor` and `OrbiterActor` showing standard scene authoring.
- `REEEplayStage` + `REEEplayPlayer` + `REEEplayCamera` — isolated playback stage with orbit camera and interpolated proxies.
