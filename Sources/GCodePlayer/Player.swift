import AppKit
import GCodeCore
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

final class Player: ObservableObject {
  @Published var file: PrintFile?
  @Published var playing = false
  @Published var loading = false
  @Published var showCode = false
  @Published var melt = true
  @Published var shadows = true
  @Published var speed = 1.0
  @Published var displayTime = 0.0
  @Published var fps = 0.0
  @Published var gpuMS = 0.0
  @Published var renderScale = 1.0
  @Published var renderedTriangles = 0
  @Published var renderedVertices = 0
  @Published var loadMS = 0.0
  @Published var gpuInfo = "METAL GPU"
  let cpuCores = ProcessInfo.processInfo.activeProcessorCount
  let preparationWorkers = min(16, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
  @Published var message = "Open a Bambu Studio G-Code or sliced 3MF file"
  @Published var error: String?
  var clock = 0.0, lastFrame: Double?, lastUI = 0.0
  var renderer: Renderer?
  func discoverGPU(_ name: String) {
    gpuInfo = name
    DispatchQueue.global(qos: .utility).async {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
      process.arguments = ["SPDisplaysDataType", "-json"]
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let gpus = json?["SPDisplaysDataType"] as? [[String: Any]]
        let gpu = gpus?.first {
          ($0["sppci_model"] as? String) == name || ($0["_name"] as? String) == name
        }
        let raw = gpu?["sppci_cores"]
        let count = (raw as? String).flatMap(Int.init) ?? (raw as? Int)
        DispatchQueue.main.async {
          self.gpuInfo = name + (count.map { " · \($0) GPU CORES" } ?? " · CORES —")
        }
      } catch { DispatchQueue.main.async { self.gpuInfo = name + " · CORES —" } }
    }
  }
  func open() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = ["gcode", "gco", "gc", "3mf", "zip"].compactMap {
      UTType(filenameExtension: $0)
    }
    panel.allowsOtherFileTypes = true
    if panel.runModal() == .OK, let url = panel.url { load(url) }
  }
  func load(_ url: URL) {
    guard !loading else { return }
    playing = false
    loading = true
    message = "Loading \(url.lastPathComponent)…"
    let device = renderer?.device
    DispatchQueue.global(qos: .userInitiated).async {
      let start = ProcessInfo.processInfo.systemUptime
      do {
        let result = try PrintLoader.load(url)
        let geometry = device.map { Renderer.prepare(result, device: $0) }
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        DispatchQueue.main.async {
          self.file = result
          self.clock = 0
          self.displayTime = 0
          self.lastFrame = nil
          self.loadMS = ms
          self.renderer?.load(result, prepared: geometry)
          self.loading = false
          self.message = result.name
        }
      } catch {
        DispatchQueue.main.async {
          self.loading = false
          self.error = error.localizedDescription
          self.message = "Could not load file"
        }
      }
    }
  }
  func seek(_ value: Double) {
    clock = max(0, min(value, file?.duration ?? 0))
    displayTime = clock
    lastFrame = nil
  }
  func step() {
    playing = false
    guard let file else { return }
    seek(file.moves[file.index(at: clock)].end + 0.000001)
  }
  func tick(_ now: Double) {
    if let lastFrame, playing, let file {
      clock = min(file.duration, clock + min(0.1, now - lastFrame) * speed)
      if clock >= file.duration { playing = false }
    }
    lastFrame = now
    if now - lastUI > 0.1 {
      displayTime = clock
      lastUI = now
    }
  }
}
struct ContentView: View {
  @ObservedObject var player: Player
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("NULL").font(.system(size: 23, weight: .black, design: .rounded)).foregroundStyle(
          .mint)
        Text("G-CODE PLAYER · METAL").font(.system(size: 10, weight: .medium, design: .monospaced))
          .tracking(2).foregroundStyle(.secondary)
        Spacer()
        Button("G-Code") { player.showCode.toggle() }
        Toggle("Melt", isOn: $player.melt).toggleStyle(.switch).fixedSize()
        Toggle("Shadows", isOn: $player.shadows).toggleStyle(.switch).fixedSize()
        Button("Top") { player.renderer?.top() }
        Button("Fit") { player.renderer?.fit() }
        Button("Open…", action: player.open).keyboardShortcut("o")
      }.padding(16)
      Divider()
      GeometryReader { geo in
        ZStack(alignment: .topLeading) {
          MetalPreview(player: player)
          if let file = player.file {
            let move = file.moves[file.index(at: player.displayTime)]
            VStack(alignment: .leading, spacing: 7) {
              Text(formatTime(player.displayTime)).font(
                .system(size: 30, weight: .medium, design: .monospaced)
              ).foregroundStyle(Color(red: 1, green: 0.75, blue: 0.36))
              Text("LAYER \(move.layer+1) / \(file.layerCount)    T\(move.tool+1)").font(
                .system(size: 9, design: .monospaced)
              ).foregroundStyle(.secondary)
            }.padding(20).allowsHitTesting(false)
            if player.showCode {
              Text(
                file.lines[max(0, move.line - 7)..<min(file.lines.count, move.line + 9)].joined(
                  separator: "\n")
              )
              .font(.system(size: 8, weight: .light, design: .monospaced)).foregroundStyle(
                .green.opacity(0.22)
              ).lineLimit(18).frame(width: min(geo.size.width * 0.4, 380), alignment: .leading)
              .padding(.leading, 20).padding(.top, 115).allowsHitTesting(false)
            }
            VStack {
              HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                  Text(player.gpuInfo).font(.system(size: 9, design: .monospaced))
                  Text("CPU \(player.cpuCores) CORES · \(player.preparationWorkers) PREP WORKERS")
                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                  Text(String(format: "%0.0f FPS · %0.2f ms GPU", player.fps, player.gpuMS)).font(
                    .system(size: 10, design: .monospaced))
                  Text(
                    "RES \(Int((player.renderScale*100).rounded()))% · POLYGONS \(player.renderedTriangles.formatted())"
                  )
                  .font(.system(size: 9, design: .monospaced))
                  .help(
                    "Triangles submitted in the main view, including the plate and head. Shadow passes are excluded."
                  )
                  Text("VERTICES \(player.renderedVertices.formatted())")
                    .font(.system(size: 9, design: .monospaced))
                    .help(
                      "Vertex shader invocations in the main view, including instanced and repeated vertices. Shadow passes are excluded."
                    )
                  Text(
                    String(format: "%0.1f%%", player.displayTime / max(file.duration, 0.001) * 100)
                  ).font(.system(size: 14, weight: .medium, design: .monospaced))
                }.foregroundStyle(.mint).padding(20)
              }
              Spacer()
            }.allowsHitTesting(false)
          } else if !player.loading {
            Text("Drop G-Code or sliced 3MF here").foregroundStyle(.secondary).frame(
              maxWidth: .infinity, maxHeight: .infinity
            ).allowsHitTesting(false)
          }
          if player.loading {
            ProgressView(player.message).padding(28).background(
              .regularMaterial, in: RoundedRectangle(cornerRadius: 16)
            ).frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      Divider()
      if let file = player.file {
        HStack(spacing: 14) {
          Text("TOOLS").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
          ForEach(file.usedTools, id: \.self) { tool in
            let active = file.moves[file.index(at: player.displayTime)].tool == tool
            HStack(spacing: 5) {
              Circle().fill(swatch(file.filamentColor(tool: tool))).frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
              Text("T\(tool+1)").font(
                .system(size: 10, weight: active ? .bold : .regular, design: .monospaced))
            }.padding(.horizontal, 8).padding(.vertical, 5).background(
              active ? Color.mint.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5)
            ).foregroundStyle(active ? .mint : .secondary)
          }
          Spacer()
          Text(
            "TOOL CHANGES \(file.toolChanges(at:player.displayTime).formatted()) / \(file.toolChanges.formatted())"
          )
          .font(.system(size: 10, design: .monospaced)).foregroundStyle(.mint)
        }.padding(.horizontal, 16).padding(.vertical, 7)
        Divider()
      }
      VStack(spacing: 10) {
        Slider(
          value: Binding(get: { player.displayTime }, set: { player.seek($0) }),
          in: 0...max(player.file?.duration ?? 1, 0.001)
        ).disabled(player.file == nil).tint(.mint)
        HStack(spacing: 16) {
          Button {
            player.playing.toggle()
            player.lastFrame = nil
          } label: {
            Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(
              width: 24, height: 20)
          }.keyboardShortcut(.space, modifiers: []).disabled(player.file == nil)
          Button {
            player.seek(0)
          } label: {
            Image(systemName: "backward.end.fill")
          }
          Button(action: player.step) { Image(systemName: "forward.end.fill") }.keyboardShortcut(
            .rightArrow, modifiers: [])
          Text("\(formatTime(player.displayTime)) / \(formatTime(player.file?.duration ?? 0))")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
          Spacer()
          ForEach([1.0, 5, 10, 25, 50, 100], id: \.self) { rate in
            Button("×\(Int(rate))") { player.speed = rate }.tint(
              player.speed == rate ? .mint : .gray)
          }
          Button {
            NSApp.keyWindow?.toggleFullScreen(nil)
          } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
          }.keyboardShortcut("f", modifiers: [])
        }
        HStack {
          Text(player.message).lineLimit(1)
          Spacer()
          if let file = player.file {
            Text(
              "\(file.moves.count.formatted()) moves · \(file.toolChanges) tool changes · load \(Int(player.loadMS)) ms"
            )
          }
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
      }.padding(16)
    }.background(Color(red: 0.035, green: 0.045, blue: 0.05)).preferredColorScheme(.dark).frame(
      minWidth: 900, minHeight: 640
    )
    .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
      guard let item = providers.first else { return false }
      _ = item.loadObject(ofClass: URL.self) { url, _ in
        if let url { DispatchQueue.main.async { player.load(url) } }
      }
      return true
    }
    .alert(
      "Could not open file",
      isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })
    ) {
      Button("OK") { player.error = nil }
    } message: {
      Text(player.error ?? "")
    }
  }
}
func formatTime(_ seconds: Double) -> String {
  let t = max(0, Int(seconds))
  return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
}
struct MetalPreview: NSViewRepresentable {
  let player: Player
  func makeNSView(context: Context) -> PreviewView {
    let view = PreviewView()
    do {
      let renderer = try Renderer(view: view, player: player)
      player.renderer = renderer
      view.renderer = renderer
      view.delegate = renderer
      if let file = player.file { renderer.load(file) }
    } catch {
      fputs("Metal initialization: \(error)\n", stderr)
      DispatchQueue.main.async { player.error = error.localizedDescription }
    }
    return view
  }
  func updateNSView(_ view: PreviewView, context: Context) {}
}
final class PreviewView: MTKView {
  weak var renderer: Renderer?
  init() {
    super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
    preferredFramesPerSecond = 120
    colorPixelFormat = .bgra8Unorm
    depthStencilPixelFormat = .depth32Float
    sampleCount = 4
    clearColor = MTLClearColorMake(0.018, 0.025, 0.03, 1)
    autoResizeDrawable = true
    enableSetNeedsDisplay = false
    isPaused = false
  }
  required init(coder: NSCoder) { fatalError() }
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
  override func mouseDragged(with event: NSEvent) {
    renderer?.yaw -= Float(event.deltaX) * 0.007
    renderer?.pitch = max(0.04, min(1.56, (renderer?.pitch ?? 0.7) + Float(event.deltaY) * 0.007))
  }
  override func rightMouseDragged(with event: NSEvent) {
    renderer?.pan(Float(event.deltaX), Float(event.deltaY))
  }
  override func scrollWheel(with event: NSEvent) {
    renderer?.distance = max(
      5, min(3000, (renderer?.distance ?? 400) * exp(Float(event.scrollingDeltaY) * 0.015)))
  }
  override func keyDown(with event: NSEvent) {
    switch event.charactersIgnoringModifiers {
    case " ": renderer?.player.playing.toggle()
    case "f": window?.toggleFullScreen(nil)
    case String(UnicodeScalar(NSRightArrowFunctionKey)!): renderer?.player.step()
    default: super.keyDown(with: event)
    }
  }
}

private func swatch(_ color: SIMD4<Float>) -> Color {
  func srgb(_ v: Float) -> Double {
    Double(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
  }
  return Color(red: srgb(color.x), green: srgb(color.y), blue: srgb(color.z))
}
