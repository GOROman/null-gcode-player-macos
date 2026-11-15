import AppKit
import GCodeCore
import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.48, green: 0.94, blue: 0.76)
private let ink = Color(red: 0.035, green: 0.045, blue: 0.052)
private let panel = Color(red: 0.067, green: 0.083, blue: 0.09)

struct ContentView: View {
  @ObservedObject var player: Player
  var body: some View {
    VStack(spacing: 0) {
      header
      ZStack(alignment: .topLeading) {
        MetalPreview(player: player)
        if let file = player.file { overlay(file) } else if !player.loading { emptyState }
        if player.loading {
          VStack(spacing: 14) {
            ProgressView().controlSize(.small).tint(accent)
            Text("READING TOOLPATH").font(.system(size: 10, weight: .medium, design: .monospaced))
              .tracking(2)
            Text(player.message).font(.system(size: 11)).foregroundStyle(.secondary)
          }
          .padding(28).background(panel, in: RoundedRectangle(cornerRadius: 16)).frame(
            maxWidth: .infinity, maxHeight: .infinity)
        }
      }.background(ink).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 16)
      if let file = player.file { tools(file) }
      transport
      footer
    }.background(ink).preferredColorScheme(.dark).tint(accent).frame(minWidth: 1000, minHeight: 720)
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
  private var header: some View {
    HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.1)).frame(width: 36, height: 36)
        Image(systemName: "cube.transparent").font(.system(size: 20, weight: .light))
          .foregroundStyle(accent)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("NULL").font(.system(size: 18, weight: .black, design: .rounded)).tracking(3)
        Text("G-CODE PLAYER").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(
          2.5
        ).foregroundStyle(.secondary)
      }
      Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 23).padding(.horizontal, 8)
      HStack(spacing: 5) {
        Circle().fill(accent).frame(width: 4, height: 4)
        Text("METAL NATIVE").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(
          1.5
        ).foregroundStyle(accent)
      }
      Spacer(minLength: 10)
      pill("terminal", "G-Code", active: player.showCode) { player.showCode.toggle() }
      pill("drop", "Melt", active: player.melt) { player.melt.toggle() }
      pill("scribble", "モジャ", active: player.moja) { player.moja.toggle() }
        .disabled(player.file == nil)
      Menu {
        Toggle("Show approximate head envelope", isOn: $player.showClearance)
        Button(player.checkingClearance ? "Checking…" : "Check deposited-material clearance") {
          player.checkClearance()
        }.disabled(player.file == nil || player.checkingClearance)
        Button("Jump to next potential collision") {
          if let hit = player.collisionHits.first(where: { $0.start > player.clock + 0.001 })
            ?? player.collisionHits.first
          {
            player.playing = false
            player.seek(hit.start)
          }
        }.disabled(player.collisionHits.isEmpty)
      } label: {
        Label("Clearance", systemImage: "exclamationmark.shield")
          .font(.system(size: 10, weight: .medium))
      }.menuStyle(.borderlessButton).fixedSize()

      Menu {
        Picker("Geometry detail", selection: $player.lodMode) {
          Text("Automatic · distance-based").tag(0)
          Text("High · rounded beads").tag(1)
          Text("Balanced · simplified beads").tag(2)
          Text("Fast · ribbons").tag(3)
        }
      } label: {
        Label("Detail", systemImage: "cube").font(.system(size: 10, weight: .medium))
      }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(0.04), in: Capsule())
      Button { player.environmentOpen.toggle() } label: {
        Label("Environment", systemImage: "thermometer.medium")
          .font(.system(size: 10, weight: .medium))
      }.buttonStyle(.plain).popover(isPresented: $player.environmentOpen) {
        VStack(alignment: .leading) {
          Text("PLA · SIMULATED ENVIRONMENT")
          Text("Nozzle: \(Int(player.nozzleTemperature)) °C")
          Slider(value: $player.nozzleTemperature, in: 170...250)
          Text("Cooling fan: \(Int(player.coolingFan*100)) %")
          Slider(value: $player.coolingFan, in: 0...1)
          Text(String(format: "Relative viscosity: ×%.2f", player.viscosityScale))
          Slider(value: $player.viscosityScale, in: 0.25...4)
          Text(String(format: "Contact friction: %.2f", player.contactFriction))
          Slider(value: $player.contactFriction, in: 0...1.2)
          Text("Qualitative model · not measured rheology").font(.caption2).foregroundStyle(.secondary)
          Text("Plate: \(Int(player.plateTemperature)) °C")
          Slider(value: $player.plateTemperature, in: 0...110)
          Text("Ambient: \(Int(player.roomTemperature)) °C")
          Slider(value: $player.roomTemperature, in: 5...45)
          Text("Humidity: \(Int(player.humidity)) %")
          Slider(value: $player.humidity, in: 0...100)
          Gauge(value: player.peelRisk) { Text("Peeling tendency (approx.)") }
          Toggle("Simulate adhesion failure", isOn: $player.simulateAdhesion)
        }.padding(12).frame(width: 240)
      }
      Menu {
        Toggle("Shadows", isOn: $player.shadows)
        Picker("Shadow map", selection: $player.shadowResolution) {
          Text("1K · Fast").tag(1024)
          Text("2K · High").tag(2048)
          Text("4K · Ultra").tag(4096)
        }
      } label: {
        Label("Lighting", systemImage: "sun.max").font(.system(size: 10, weight: .medium))
      }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(0.04), in: Capsule())
      Button(action: player.open) {
        Label("Open file", systemImage: "plus").font(.system(size: 11, weight: .semibold)).padding(
          .horizontal, 14
        ).padding(.vertical, 9).foregroundStyle(ink).background(accent, in: Capsule())
      }.buttonStyle(.plain).keyboardShortcut("o")
    }.padding(.horizontal, 20).padding(.vertical, 14)
  }
  private func pill(_ icon: String, _ title: String, active: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Label(title, systemImage: icon).font(.system(size: 10, weight: .medium)).padding(
        .horizontal, 11
      ).padding(.vertical, 8).foregroundStyle(active ? accent : Color.secondary).background(
        active ? accent.opacity(0.1) : .white.opacity(0.03), in: Capsule()
      ).overlay(
        Capsule().stroke(active ? accent.opacity(0.25) : .white.opacity(0.06), lineWidth: 0.5))
    }.buttonStyle(.plain)
  }
  private func overlay(_ file: PrintFile) -> some View {
    let move = file.moves[file.index(at: player.displayTime)]
    let progress = player.displayTime / max(file.duration, 0.001)
    return ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: 8) {
        Text("PRINT TIME").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(
          2.5
        ).foregroundStyle(.secondary)
        Text(formatTime(player.displayTime)).font(
          .system(size: 31, weight: .light, design: .monospaced)
        ).tracking(1).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.47))
        HStack(spacing: 12) {
          Text("LAYER \(move.layer+1) / \(file.layerCount)")
          Text("T\(move.tool+1)").foregroundStyle(accent)
        }.font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
      }.padding(22).allowsHitTesting(false)
      if player.showClearance {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            player.checkingClearance
              ? "CHECKING CLEARANCE…"
              : (player.clearanceChecked
                ? "\(player.collisionHits.count) POTENTIAL COLLISION MOVES"
                : "HEAD ENVELOPE · NOT CHECKED"))
          if let hit = player.collisionHits.first(where: {
            player.displayTime >= $0.start && player.displayTime <= $0.end
          }) {
            Text("POTENTIAL CONTACT · G-CODE LINE \(hit.line + 1)").foregroundStyle(.red)
          }
          Text("Approximate geometry / conservative sweep · not a safety certification")
            .foregroundStyle(.secondary)
        }.font(.system(size: 9, weight: .medium, design: .monospaced))
          .foregroundStyle(.orange).padding(10).background(.black.opacity(0.7))
          .padding(.leading, 22).padding(.top, 100).allowsHitTesting(false)
      }
      if player.showCode {
        source(file, line: move.line).padding(.leading, 22).padding(
          .top, player.showClearance ? 185 : 132
        ).allowsHitTesting(
          false)
      }
      VStack {
        HStack {
          Spacer()
          VStack(alignment: .trailing, spacing: 7) {
            Text(player.gpuInfo.uppercased()).font(
              .system(size: 8, weight: .medium, design: .monospaced)
            ).tracking(0.5).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
              Text(String(format: "%.0f", player.fps)).font(
                .system(size: 27, weight: .light, design: .monospaced))
              Text("FPS").font(.system(size: 8, design: .monospaced))
              Text(String(format: " / %.2f ms", player.gpuMS)).font(
                .system(size: 9, design: .monospaced)
              ).foregroundStyle(.secondary)
            }.foregroundStyle(accent)
            Text("CPU \(player.cpuCores) CORES · \(player.preparationWorkers) WORKERS").font(
              .system(size: 7, design: .monospaced)
            ).foregroundStyle(.secondary)
            HStack(spacing: 10) {
              metric("POLYGONS", player.renderedTriangles)
              metric("VERTICES", player.renderedVertices)
            }
            Text(
              "RES \(Int((player.renderScale*100).rounded()))% · LOD \(["AUTO","HIGH","MID","FAST"][player.lodMode]) · SHADOW \(player.shadowResolution/1024)K"
            ).font(.system(size: 7, design: .monospaced)).foregroundStyle(.secondary)
          }.padding(18).background(ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
        Spacer()
        HStack {
          HStack(spacing: 6) {
            Circle().fill(player.playing ? accent : .gray).frame(width: 4, height: 4)
            Text(player.playing ? "PRINTING" : "PAUSED").font(
              .system(size: 7, weight: .medium, design: .monospaced)
            ).tracking(2)
          }.foregroundStyle(.secondary)
          Spacer()
          Button {
            player.renderer?.inspectNozzle()
          } label: {
            Image(systemName: "drop.circle").font(.system(size: 14)).padding(9)
          }.help("Follow nozzle / inspect melt")
          Button {
            player.renderer?.top()
          } label: {
            Image(systemName: "square.stack.3d.up").font(.system(size: 12)).padding(9)
          }.help("Top view")
          Button {
            player.renderer?.fit()
          } label: {
            Image(systemName: "viewfinder").font(.system(size: 12)).padding(9)
          }.help("Fit model")
          HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(String(format: "%.1f", progress * 100)).font(
              .system(size: 22, weight: .light, design: .monospaced))
            Text("%").font(.system(size: 9, design: .monospaced))
          }.foregroundStyle(accent).padding(.leading, 12)
        }.buttonStyle(.plain).padding(.horizontal, 22).padding(.bottom, 18)
      }
    }
  }
  private func metric(_ title: String, _ count: Int) -> some View {
    VStack(alignment: .trailing, spacing: 3) {
      Text(title).font(.system(size: 6, weight: .medium, design: .monospaced)).tracking(1.2)
        .foregroundStyle(.secondary)
      Text(count.formatted()).font(.system(size: 9, design: .monospaced)).foregroundStyle(
        accent.opacity(0.85))
    }
  }
  private func source(_ file: PrintFile, line: Int) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("LIVE SOURCE / \(line+1)").font(.system(size: 7, weight: .medium, design: .monospaced))
        .tracking(1.5).foregroundStyle(accent.opacity(0.45)).padding(.bottom, 7)
      ForEach(max(0, line - 3)..<min(file.lines.count, line + 9), id: \.self) { index in
        Text("\(String(format:"%06d",index+1))  \(file.lines[index])").font(
          .system(size: 10, weight: index == line ? .medium : .regular, design: .monospaced)
        ).foregroundStyle(
          index == line
            ? Color.green.opacity(0.95) : Color(red: 0.38, green: 0.92, blue: 0.57).opacity(0.56)
        ).lineLimit(2).fixedSize(horizontal: false, vertical: true)
      }
    }.frame(maxWidth: 410, alignment: .leading).padding(12).background(
      ink.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }
  private func tools(_ file: PrintFile) -> some View {
    HStack(spacing: 8) {
      Text("FILAMENTS").font(.system(size: 7, weight: .medium, design: .monospaced)).tracking(1.5)
        .foregroundStyle(.secondary).padding(.trailing, 5)
      ForEach(file.usedTools, id: \.self) { tool in
        let active = file.moves[file.index(at: player.displayTime)].tool == tool
        let used = file.filamentUsage.millimeters(tool: tool, at: player.displayTime)
        HStack(spacing: 7) {
          SpoolGraphic(
            color: swatch(file.filamentColor(tool: tool)),
            rotation: FilamentUsage.rotationDegrees(millimeters: used)
          ).frame(width: 32, height: 32).animation(
            player.playing ? .linear(duration: 0.1) : nil, value: used)
          VStack(alignment: .leading, spacing: 3) {
            Text("T\(tool+1)").font(.system(size: 9, weight: .semibold, design: .monospaced))
              .foregroundStyle(active ? accent : .white.opacity(0.65))
            Text(String(format: "%.2f m", used / 1000)).font(.system(size: 7, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }.padding(.horizontal, 7).padding(.vertical, 6).background(
          active ? accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8)
        ).overlay(
          RoundedRectangle(cornerRadius: 8).stroke(
            active ? accent.opacity(0.22) : .clear, lineWidth: 0.5))
      }
      Spacer(minLength: 4)
      VStack(alignment: .trailing, spacing: 4) {
        Text("TOOL CHANGES").font(.system(size: 7, design: .monospaced)).tracking(1.4)
          .foregroundStyle(.secondary)
        Text(
          "\(file.toolChanges(at:player.displayTime).formatted()) / \(file.toolChanges.formatted())"
        ).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(accent)
      }
    }.padding(.horizontal, 22).padding(.vertical, 10)
  }
  private var transport: some View {
    VStack(spacing: 12) {
      TimelineTrack(
        value: Binding(get: { player.displayTime }, set: { player.seek($0) }),
        total: max(0.001, player.file?.duration ?? 1)
      ).frame(height: 16).disabled(player.file == nil)
      HStack(spacing: 15) {
        Button {
          player.togglePlayback()
        } label: {
          Image(systemName: player.playing ? "pause.fill" : "play.fill").font(
            .system(size: 15, weight: .semibold)
          ).foregroundStyle(ink).frame(width: 44, height: 44).background(accent, in: Circle())
        }.keyboardShortcut(.space, modifiers: []).disabled(player.file == nil)
        Button {
          player.seek(0)
        } label: {
          Image(systemName: "backward.end").font(.system(size: 14)).frame(width: 24, height: 28)
        }.help("Restart")
        Button(action: player.step) {
          Image(systemName: "forward.end").font(.system(size: 14)).frame(width: 24, height: 28)
        }.keyboardShortcut(.rightArrow, modifiers: []).help("Step")
        VStack(alignment: .leading, spacing: 3) {
          Text(formatTime(player.displayTime)).font(
            .system(size: 12, weight: .medium, design: .monospaced))
          Text("/ " + formatTime(player.file?.duration ?? 0)).font(
            .system(size: 8, design: .monospaced)
          ).foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: 2) {
          ForEach([1.0, 5, 10, 25, 50, 100], id: \.self) { rate in
            Button {
              player.speed = rate
            } label: {
              Text("×\(Int(rate))").font(
                .system(
                  size: 10, weight: player.speed == rate ? .semibold : .regular, design: .monospaced
                )
              ).foregroundStyle(player.speed == rate ? ink : Color.secondary).frame(
                width: 43, height: 29
              ).background(
                player.speed == rate ? accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
          }
        }.padding(4).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        Button {
          NSApp.keyWindow?.toggleFullScreen(nil)
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13)).frame(
            width: 28, height: 28)
        }.keyboardShortcut("f", modifiers: []).help("Fullscreen")
      }.buttonStyle(.plain)
    }.padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 14)
  }
  private var footer: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text").foregroundStyle(accent.opacity(0.6))
      Text(player.file?.name ?? "No file loaded").lineLimit(1).truncationMode(.middle)
      Spacer()
      if let file = player.file {
        Text("\(file.moves.count.formatted()) MOVES  /  \(Int(player.loadMS)) ms LOAD").lineLimit(1)
      }
    }.font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary).padding(
      .horizontal, 22
    ).padding(.vertical, 11).background(.white.opacity(0.02))
  }
  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "square.stack.3d.up").font(.system(size: 42, weight: .ultraLight))
        .foregroundStyle(accent.opacity(0.55))
      Text("Open a sliced model.").font(.system(size: 23, weight: .light))
      Text("Drop a sliced 3MF or G-Code file to begin.").font(.system(size: 11)).foregroundStyle(
        .secondary)
      Button("Open file", action: player.open).buttonStyle(.bordered).padding(.top, 8)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
private struct TimelineTrack: View {
  @Binding var value: Double
  let total: Double
  var body: some View {
    GeometryReader { geo in
      let progress = max(0, min(1, value / total))
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.08)).frame(height: 3)
        Capsule().fill(accent).frame(width: max(0, geo.size.width * progress), height: 3)
        Circle().fill(accent).frame(width: 7, height: 7).offset(
          x: max(0, geo.size.width * progress - 3.5))
      }.frame(height: geo.size.height).contentShape(Rectangle()).gesture(
        DragGesture(minimumDistance: 0).onChanged {
          value =
            Double(max(0, min(geo.size.width, $0.location.x)) / max(1, geo.size.width)) * total
        })
    }.accessibilityLabel("Playback position").accessibilityValue(formatTime(value))
      .accessibilityAdjustableAction { direction in
        value = max(0, min(total, value + (direction == .increment ? 5 : -5)))
      }
  }
}
private struct SpoolGraphic: View {
  let color: Color, rotation: Double
  var body: some View {
    ZStack {
      Circle().fill(color.opacity(0.65)).padding(3)
      Circle().stroke(.white.opacity(0.14), lineWidth: 1)
      ForEach(0..<3, id: \.self) { index in
        Circle().stroke(.black.opacity(0.22), lineWidth: 0.7).padding(CGFloat(4 + index * 2))
      }
      ZStack {
        ForEach(0..<6, id: \.self) { index in
          Capsule().fill(.white.opacity(0.28)).frame(width: 2, height: 8).offset(y: -9)
            .rotationEffect(.degrees(Double(index) * 60))
        }
      }.rotationEffect(.degrees(rotation))
      Circle().fill(ink).frame(width: 10, height: 10).overlay(
        Circle().stroke(.white.opacity(0.25), lineWidth: 1))
      Circle().fill(.white.opacity(0.3)).frame(width: 3, height: 3)
    }
  }
}
