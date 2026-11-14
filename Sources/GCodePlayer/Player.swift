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
  @Published var shadowResolution = 2048 {
    didSet { renderer?.setShadowResolution(shadowResolution) }
  }
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
  func togglePlayback() {
    guard let file else { return }
    if !playing && clock >= file.duration { seek(0) }
    playing.toggle()
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
    case " ": renderer?.player.togglePlayback()
    case "f": window?.toggleFullScreen(nil)
    case String(UnicodeScalar(NSRightArrowFunctionKey)!): renderer?.player.step()
    default: super.keyDown(with: event)
    }
  }
}

func swatch(_ color: SIMD4<Float>) -> Color {
  func srgb(_ v: Float) -> Double {
    Double(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
  }
  return Color(red: srgb(color.x), green: srgb(color.y), blue: srgb(color.z))
}
