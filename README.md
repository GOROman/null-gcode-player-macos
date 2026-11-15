# NULL G-Code Player for macOS

**See every layer. Follow every color. Watch your print take shape.**

Drop in a sliced file from Bambu Studio, press Play, and watch your model grow
from its first line of filament. Circle around it, get close to the nozzle,
or skip ahead to see how it all comes together.

Pause on a detail. Replay a color change. Turn a long print into a few minutes
of discovery—all on your Mac, without uploading your files.

![Native Metal preview](docs/metal-preview.png)

## Download

[Download v0.10](https://github.com/GOROman/null-gcode-player-macos/releases/tag/v0.10)

Requires **macOS 14+ and Apple Silicon**. Unzip the app and move it to Applications.
The app is ad-hoc signed and not notarized.

## Explore your print

- **Watch it grow.** Follow the nozzle as it builds your model, layer by layer.
- **Find your angle.** Rotate freely, zoom into the fine details, or enjoy the whole print in fullscreen.
- **See your colors come together.** Preview Bambu Studio's filament colors and watch the spools turn as material is used.
- **Take control of time.** Pause, step through a move, drag the timeline, or fast-forward up to **100×**.
- **Look closer.** Reveal the G-Code behind each movement or inspect potential head-clearance issues.

Feeling experimental? **モジャ (Moja)** turns new extrusion into tangled strands
that fall, collide, and harden. Try different temperatures and cooling settings
in **Environment** to explore how the effect changes. Available in the latest
source build, after v0.10.

Physics and clearance checks are visual approximations, not predictions of real printing behavior.

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
cooling waits are not simulated.

## License

[MIT](LICENSE) © 2026 GOROman.
