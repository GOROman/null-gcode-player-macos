import Foundation
import simd

public struct Move: Sendable {
  public var a: SIMD3<Float>, b: SIMD3<Float>
  public var start: Double, end: Double
  public var line: Int, layer: Int, tool: Int
  public var width: Float, height: Float, deposit: Bool
}
public struct PrintFile: Sendable {
  public var name: String, lines: [String], moves: [Move], colors: [SIMD4<Float>]
  public var bed: SIMD4<Float>, layerCount: Int, toolChanges: Int
  public var duration: Double { moves.last?.end ?? 0 }
  public var usedTools: [Int]
  public var toolChangeTimes: [Double]
  public var filamentUsage: FilamentUsage
  public func toolChanges(at time: Double) -> Int {
    var lo = 0
    var hi = toolChangeTimes.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if toolChangeTimes[mid] <= time { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }
  public func filamentColor(tool: Int) -> SIMD4<Float> {
    colors.indices.contains(tool) ? colors[tool] : SIMD4(0.38, 0.87, 0.76, 1)
  }
  public func index(at time: Double) -> Int {
    var lo = 0
    var hi = moves.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if moves[mid].end <= time { lo = mid + 1 } else { hi = mid }
    }
    return min(lo, max(0, moves.count - 1))
  }
}
public enum LoadError: LocalizedError {
  case noMoves
  case archive(String)
  public var errorDescription: String? {
    switch self {
    case .noMoves: return "No printable movement found. Slice the model in Bambu Studio first."
    case .archive(let text): return text
    }
  }
}
// ASCII numeric scanner avoids regex and per-command dictionaries in the hot loop.
private struct Scan {
  let bytes: [UInt8]
  var index = 0
  mutating func whitespace() {
    while index < bytes.count && (bytes[index] == 32 || bytes[index] == 9) { index += 1 }
  }
  mutating func number() -> Double? {
    whitespace()
    var sign = 1.0
    var value = 0.0
    var scale = 1.0
    var found = false
    if index < bytes.count && (bytes[index] == 45 || bytes[index] == 43) {
      if bytes[index] == 45 { sign = -1 }
      index += 1
    }
    while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 {
      found = true
      value = value * 10 + Double(bytes[index] - 48)
      index += 1
    }
    if index < bytes.count && bytes[index] == 46 {
      index += 1
      while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 {
        found = true
        scale *= 0.1
        value += Double(bytes[index] - 48) * scale
        index += 1
      }
    }
    return found ? sign * value : nil
  }
}
public enum GCodeParser {
  public static func parse(_ text: String, name: String = "Untitled.gcode") throws -> PrintFile {
    let lines = text.components(separatedBy: .newlines)
    let explicit =
      text.contains("; CHANGE_LAYER") || text.contains(";LAYER_CHANGE")
      || text.contains("; LAYER_CHANGE") || text.contains(";LAYER:") || text.contains("; LAYER:")
    var moves = [Move]()
    moves.reserveCapacity(lines.count * 2)
    var x = 0.0
    var y = 0.0
    var z = 0.0
    var e = 0.0
    var feed = 1800.0
    var unit = 1.0
    var absolute = true
    var eAbsolute = true
    var arcAbsolute = false
    var plane = 17
    var tool = 0
    var layer = -1
    var clock = 0.0
    var width: Float = 0.42
    var height: Float = 0.2
    var lastPrintZ = -Double.infinity
    var colors = [SIMD4<Float>(0.38, 0.87, 0.76, 1)]
    var bed = SIMD4<Float>(0, 0, 256, 256)
    var changes = 0
    var usage = FilamentUsage()
    var retractDebt = [Int: Double]()
    var previousTool: Int?
    var changeTimes = [Double]()
    var pendingToolTime: Double?
    func append(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ deposit: Bool, _ line: Int) {
      let length = simd_length(b - a)
      guard length > 0.0000001 && layer >= 0 else { return }
      let start = clock
      clock += length / max(feed / 60, 0.01)
      if deposit {
        if let previous = previousTool, previous != tool {
          changes += 1
          changeTimes.append(pendingToolTime ?? start)
        }
        pendingToolTime = nil
        previousTool = tool
      }
      moves.append(
        Move(
          a: SIMD3(Float(a.x), Float(a.z), Float(-a.y)),
          b: SIMD3(Float(b.x), Float(b.z), Float(-b.y)), start: start, end: clock, line: line,
          layer: layer, tool: tool, width: width, height: height, deposit: deposit))
    }
    for (line, source) in lines.enumerated() {
      let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
      if raw.hasPrefix(";") {
        let comment = raw.dropFirst().trimmingCharacters(in: .whitespaces)
        if comment.hasPrefix("CHANGE_LAYER") || comment.hasPrefix("LAYER_CHANGE")
          || comment.hasPrefix("LAYER:")
        {
          layer += 1
          continue
        }
        if let range = comment.range(of: "="),
          comment.hasPrefix("filament_colour =") || comment.hasPrefix("filament_color =")
        {
          colors = comment[range.upperBound...].split(separator: ";").map {
            color(String($0).trimmingCharacters(in: .whitespaces))
          }
        }
        if let range = comment.range(of: "="), comment.hasPrefix("printable_area") {
          let points = comment[range.upperBound...].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Float($0) }
          }.filter { $0.count == 2 }
          if !points.isEmpty {
            bed = SIMD4(
              points.map { $0[0] }.min()!, points.map { $0[1] }.min()!, points.map { $0[0] }.max()!,
              points.map { $0[1] }.max()!)
          }
        }
        for key in ["LINE_WIDTH:", "LAYER_HEIGHT:"] where comment.hasPrefix(key) {
          if let v = Float(comment.dropFirst(key.count).trimmingCharacters(in: .whitespaces)), v > 0
          {
            if key == "LINE_WIDTH:" { width = v } else { height = v }
          }
        }
        continue
      }
      var scanner = Scan(bytes: Array(raw.utf8))
      scanner.whitespace()
      if scanner.index < scanner.bytes.count && scanner.bytes[scanner.index] == 78 {
        scanner.index += 1
        _ = scanner.number()
        scanner.whitespace()
      }
      guard scanner.index < scanner.bytes.count else { continue }
      let letter = scanner.bytes[scanner.index]
      scanner.index += 1
      guard let command = scanner.number() else { continue }
      if letter == 84 {
        if command >= 0 && command < 255 {
          if tool != Int(command) { pendingToolTime = clock }
          tool = Int(command)
        }
        continue
      }
      guard letter == 71 || letter == 77 else { continue }
      if letter == 71 {
        switch command {
        case 90:
          absolute = true
          continue
        case 91:
          absolute = false
          continue
        case 90.1:
          arcAbsolute = true
          continue
        case 91.1:
          arcAbsolute = false
          continue
        case 20:
          unit = 25.4
          continue
        case 21:
          unit = 1
          continue
        case 17, 18, 19:
          plane = Int(command)
          continue
        default: break
        }
      } else {
        if command == 82 { eAbsolute = true }
        if command == 83 { eAbsolute = false }
        continue
      }
      var p = [Double?](repeating: nil, count: 26)
      while scanner.index < scanner.bytes.count {
        scanner.whitespace()
        if scanner.index >= scanner.bytes.count { break }
        let key = scanner.bytes[scanner.index]
        scanner.index += 1
        if key == 59 || key == 42 { break }
        if key == 40 {
          while scanner.index < scanner.bytes.count && scanner.bytes[scanner.index] != 41 {
            scanner.index += 1
          }
          scanner.index = min(scanner.index + 1, scanner.bytes.count)
          continue
        }
        if key >= 65 && key <= 90, let value = scanner.number() { p[Int(key - 65)] = value }
      }
      let px = p[23]
      let py = p[24]
      let pz = p[25]
      let pe = p[4]
      if command == 92 {
        if let v = px { x = v * unit }
        if let v = py { y = v * unit }
        if let v = pz { z = v * unit }
        if let v = pe { e = v * unit }
        continue
      }
      guard command == 0 || command == 1 || command == 2 || command == 3 else { continue }
      if let f = p[5], f > 0 { feed = f * unit }
      let nx = px.map { absolute ? $0 * unit : x + $0 * unit } ?? x
      let ny = py.map { absolute ? $0 * unit : y + $0 * unit } ?? y
      let nz = pz.map { absolute ? $0 * unit : z + $0 * unit } ?? z
      let ne = pe.map { eAbsolute ? $0 * unit : e + $0 * unit } ?? e
      let deposit =
        ne - e > 0.000001
        && (hypot(nx - x, ny - y) > 0.000001
          || ((command == 2 || command == 3) && (p[8] != nil || p[9] != nil)))
      let extrusionDelta = ne - e
      let debt = retractDebt[tool] ?? 0
      let used = max(0, extrusionDelta - debt)
      retractDebt[tool] = max(0, debt - extrusionDelta)
      let motionStart = clock
      if !explicit && deposit && (layer < 0 || nz > lastPrintZ + 0.001) {
        layer += 1
        lastPrintZ = nz
      }
      if command == 2 || command == 3, plane == 17 {
        var center: SIMD2<Double>?
        if p[8] != nil || p[9] != nil {
          center = SIMD2(
            arcAbsolute ? (p[8] ?? x / unit) * unit : x + (p[8] ?? 0) * unit,
            arcAbsolute ? (p[9] ?? y / unit) * unit : y + (p[9] ?? 0) * unit)
        } else if let radius = p[17] {
          let dx = nx - x
          let dy = ny - y
          let d = hypot(dx, dy)
          let r = abs(radius * unit)
          if d > 0 && d <= 2 * r {
            let h =
              sqrt(max(0, r * r - d * d / 4)) * (command == 2 ? -1.0 : 1.0)
              * (radius < 0 ? -1.0 : 1.0)
            center = SIMD2((x + nx) / 2 - dy / d * h, (y + ny) / 2 + dx / d * h)
          }
        }
        if let c = center {
          let a = atan2(y - c.y, x - c.x)
          let b = atan2(ny - c.y, nx - c.x)
          let r = hypot(x - c.x, y - c.y)
          var sweep = b - a
          if command == 3 && sweep <= 1e-9 { sweep += .pi * 2 }
          if command == 2 && sweep >= (-1e-9) { sweep -= .pi * 2 }
          let steps = min(
            4096, max(2, Int(ceil(abs(sweep) * r / 0.6)), Int(ceil(abs(sweep) / 0.1))))
          var previous = SIMD3(x, y, z)
          for j in 1...steps {
            let t = Double(j) / Double(steps)
            let angle = a + sweep * t
            let next =
              j == steps
              ? SIMD3(nx, ny, nz)
              : SIMD3(c.x + r * cos(angle), c.y + r * sin(angle), z + (nz - z) * t)
            append(previous, next, deposit, line)
            previous = next
          }
        } else {
          append(SIMD3(x, y, z), SIMD3(nx, ny, nz), deposit, line)
        }
      } else {
        append(SIMD3(x, y, z), SIMD3(nx, ny, nz), deposit, line)
      }
      if deposit { usage.append(tool: tool, start: motionStart, end: clock, millimeters: used) }
      x = nx
      y = ny
      z = nz
      e = ne
    }
    guard !moves.isEmpty else { throw LoadError.noMoves }
    return PrintFile(
      name: name, lines: lines, moves: moves, colors: colors.isEmpty ? [color("#62dec2")] : colors,
      bed: bed, layerCount: layer + 1, toolChanges: changes,
      usedTools: Array(Set(moves.filter { $0.deposit }.map { $0.tool })).sorted(),
      toolChangeTimes: changeTimes, filamentUsage: usage)
  }
  public static func color(_ hex: String) -> SIMD4<Float> {
    let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard text.count >= 6, let value = UInt32(text.prefix(6), radix: 16) else {
      return SIMD4(0.38, 0.87, 0.76, 1)
    }
    // Store linear colors for the Metal lighting pipeline.
    func linear(_ c: UInt32) -> Float {
      let s = Float(c) / 255
      return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return SIMD4(linear((value >> 16) & 255), linear((value >> 8) & 255), linear(value & 255), 1)
  }
}
public enum PrintLoader {
  public static func load(_ url: URL) throws -> PrintFile {
    if ["3mf", "zip"].contains(url.pathExtension.lowercased()) {
      let listing = Pipe()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
      process.arguments = ["-Z1", url.path]
      process.standardOutput = listing
      process.standardError = FileHandle.nullDevice
      try process.run()
      let bytes = listing.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let plates = (String(data: bytes, encoding: .utf8) ?? "").split(separator: "\n").map(
        String.init
      ).filter { $0.lowercased().hasSuffix(".gcode") }.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
      guard let plate = plates.first else { throw LoadError.noMoves }
      let output = Pipe()
      let extract = Process()
      extract.executableURL = process.executableURL
      extract.arguments = ["-p", url.path, plate]
      extract.standardOutput = output
      extract.standardError = FileHandle.nullDevice
      try extract.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      extract.waitUntilExit()
      guard extract.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
        throw LoadError.archive("Could not read the sliced archive.")
      }
      return try GCodeParser.parse(text, name: url.lastPathComponent + " / " + plate)
    }
    return try GCodeParser.parse(
      String(contentsOf: url, encoding: .utf8), name: url.lastPathComponent)
  }
}
