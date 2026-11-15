# NULL G-Code Player for macOS

A fast, native **Swift + Metal** viewer for Bambu Studio G-Code on Apple Silicon.

![Native Metal preview](docs/metal-preview.png)

## Download

[Download v0.10](https://github.com/GOROman/null-gcode-player-macos/releases/tag/v0.10) · [Web version](https://github.com/GOROman/null-gcode-player)

Requires **macOS 14+ and Apple Silicon**. Unzip the app and move it to Applications.
The app is ad-hoc signed and not notarized.

## Features

- Real-time 3D playback, pause, step, seek, and speeds up to **100×**.
- Bambu filament colors, rotating spools, and tool-change counts.
- Lighting, shadows, antialiasing, and automatic level of detail.
- Live G-Code overlay and CPU/GPU rendering statistics.
- Approximate head-clearance checks.
- **モジャ (Moja)**: experimental filament failure with GPU contacts, friction, cooling, and hardening. Adjust temperature, humidity, and relative PLA viscosity in **Environment**.

Moja is available in the latest source build, after v0.10. Physics and clearance
checks are visual approximations, not predictions of real printing behavior.

## Use

1. Open your model in **Bambu Studio** and select the printer and filaments.
2. Click **Slice plate** to generate G-Code.
3. Choose **File → Export → Export plate sliced file…** and save the `.gcode.3mf` file. This includes the generated G-Code. You can also use **Export G-code…** to save a plain `.gcode` file.
4. Open **NULL G-Code Player**, then drag the exported file into the window or press **⌘O**.
5. Press **Space** to play.

Use a **sliced export containing G-Code**. A regular project or generic `.3mf` saved before slicing does not contain the toolpaths needed for playback. Menu labels may vary by Bambu Studio version.

The viewer also accepts `.zip` archives containing G-Code.

| Control | Action |
| --- | --- |
| Space | Play / pause |
| Right arrow | Step |
| Drag / scroll / right-drag | Orbit / zoom / pan |
| F | Fullscreen |
| ⌘O | Open file |

## Build

Install Xcode or Apple Command Line Tools, then run:

```sh
./scripts/build-app.sh
open "build/NULL G-Code Player.app"
```

No third-party dependencies. To run checks, including Metal shaders:

```sh
NULL_TEST_GPU=1 ./scripts/check.sh
```

The preview clock uses commanded movement speeds; heating, acceleration, and
cooling waits are not simulated. Music and karaoke are available in the web version.

## License

[MIT](LICENSE) © 2026 GOROman.
