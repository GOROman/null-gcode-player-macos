# NULL G-Code Player for macOS

A native Swift + Metal G-Code player, built for fast local previews on Apple Silicon. No WebView, browser, Electron, or JavaScript runtime is involved.

This is the independent native implementation of [NULL G-Code Player](https://github.com/GOROman/null-gcode-player), focused on rendering speed. Karaoke, music synchronization, pachislot cut-ins, automatic race cameras, and mechanical tool docking from the web version have not yet been ported.

![Native Metal preview with Bambu filament colors](docs/metal-preview.png)

## Build and launch

Requires macOS 14 or newer, a Metal-capable Mac, and the Swift tools from Xcode or Command Line Tools. No third-party dependencies are required. Builds run on the host architecture; Apple Silicon is the tested target.

```sh
./scripts/build-app.sh
open "build/NULL G-Code Player.app"
```

The app is signed locally with an ad-hoc signature. This is a local development build, not a notarized distribution.

Choose **Open**, press **⌘O**, or drop a `.gcode`, `.gco`, `.gc`, sliced `.3mf`, or `.zip` file. Archives open their first naturally sorted G-Code plate. Unsliced projects are rejected with an explanation.

## Controls

- Play / pause: **Space**. Playback speeds: **×1, ×5, ×10, ×25, ×50, ×100**.
- Step to the next motion: **Right arrow**. Drag the timeline to seek; restart returns to zero.
- Drag to orbit; scroll to zoom; right-drag to pan. **Top** and **Fit** reposition the camera. **F** toggles fullscreen.
- **G-Code** shows a faint green live source overlay.
- **Melt** changes the bead profile, adds fresh-material gloss, and leaves adjacent beads and layers overlapping as they cool. This is a visual approximation of deposition and fusion, not a thermal or fluid solver or a boolean mesh union. Filament remains individually instanced on the GPU.
- **Shadows** enables a directional shadow map with filtered edges. Lighting includes a key light, ambient fill, rim lighting, and specular highlights.
- Filament colors come from Bambu Studio's `filament_colour` / `filament_color` metadata and `T` tool commands. A tool strip shows each used filament and highlights the active tool. Unknown tool colors use a fallback, without wrapping into another tool's color.
- The upper right shows the actual Metal device, the GPU core count reported by macOS, available CPU cores, preparation workers, FPS, and GPU command time. An unavailable GPU core count is shown as `—`; it is not guessed from the chip name. Core count indicates hardware capacity, not measured utilization.

The parser handles absolute/relative XYZ and extrusion, G92, millimeters/inches, tool commands, Bambu layer/width/height comments, XY G2/G3 arcs (I/J or R), and full circles. Non-XY arcs currently fall back to straight moves. The preview clock uses commanded feedrates, without firmware acceleration, heating, or dwell estimates.

## Performance design

- State-dependent G-Code parsing runs off the main thread. Geometry preparation uses up to 16 CPU workers, leaving two logical cores available where possible.
- Workers fill disjoint ranges of shared Metal buffers directly. The buffer is published to the renderer only after all workers finish.
- Each extrusion uses 64 bytes of instance data. Bead geometry is generated in the vertex shader, rather than expanded into CPU vertex meshes.
- Completed geometry stays resident on the GPU. Seeking performs binary searches; playback updates small uniform values rather than rebuilding the model.
- The renderer requests 120 FPS, uses 4× MSAA, and limits commands in flight to three. Actual FPS depends on the display, model size, resolution, and enabled effects.
- Subpixel beads use a cheaper crossed-ribbon representation; close views retain the rounded bead mesh. Shadow maps use the cheaper representation and are refreshed as deposition advances.
- UI updates and GPU telemetry are throttled independently of rendering.

## Checks and measurements

```sh
# Parser checks (works with Command Line Tools; no XCTest dependency)
./scripts/check.sh

# Also compile the Metal shader on a real GPU
NULL_TEST_GPU=1 ./scripts/check.sh

# Parse/archive benchmark
swift build -c release
.build/release/gcode-benchmark /path/to/sample.gcode.3mf

# Full-model rendering benchmark: prints results after 180 measured frames
open -n --stdout /tmp/null-metal.log --stderr /tmp/null-metal-errors.log \
  "build/NULL G-Code Player.app" --args /path/to/sample.gcode.3mf --benchmark
```

The `--benchmark` option shows the complete print and measures actual Metal command-buffer GPU time after warmup. Measurements include the main render pass and shadow updates when they occur. It does not imply feature parity with, or a controlled speed comparison against, the web renderer.

The bundled checks cover relative extrusion, G92, relative coordinates, inch conversion, XY arcs, full circles, radius arcs, Bambu metadata, tool changes, boundary seeking, empty files, and optional real-GPU shader compilation. Sample print files are local inputs and are not committed.

## Layout

- `Sources/GCodeCore`: parser, archive loading, source and motion data.
- `Sources/GCodePlayer`: SwiftUI controls, Metal view, parallel preparation, and rendering.
- `Sources/GCodePlayer/Shaders`: bead generation, melt appearance, lighting, grid, and shadows.
- `Sources/GCodeBenchmark`: command-line parsing benchmark.
- `Tests/GCodeCoreTests`: standalone checks, usable without XCTest.

Created by GOROman.
