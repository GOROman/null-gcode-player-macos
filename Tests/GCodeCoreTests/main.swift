import Foundation
import GCodeCore
import Metal

var count = 0
func check(_ name: String, _ body: () throws -> Void) rethrows {
  print("RUN: \(name)")
  fflush(stdout)
  try body()
  count += 1
  print("PASS: \(name)")
}
func equal(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) {
  precondition(abs(a - b) < tolerance, "\(a) != \(b)")
}
do {
  try check("Relative extrusion and G92") {
    let d = try GCodeParser.parse(
      "G90\nM83\nG1 X0 Z.2\nG1 X10 E1 F600\nG92 E0\nG1 Y10 E1\nG1 X0 E-1")
    precondition(d.moves.count == 3)
    equal(d.duration, 3)
    precondition(d.moves.map { $0.deposit } == [true, true, false])
  }
  try check("Relative XYZ and inches") {
    let d = try GCodeParser.parse("G20\nG91\nM83\nG1 X1 E1 F60\nG1 Y1 E1")
    equal(Double(d.moves[0].b.x), 25.4)
    equal(d.duration, 2)
  }
  try check("G3 arc") {
    let d = try GCodeParser.parse("G90\nM83\nG1 X10 Y0 Z.2\nG3 X0 Y10 I-10 J0 E1 F600")
    precondition(d.moves.count > 10)
    equal(d.duration, Double.pi / 2, 0.002)
    equal(Double(d.moves.last!.b.z), -10)
  }
  try check("Bambu colors, tools, layers and boundary seeking") {
    let d = try GCodeParser.parse(
      "; filament_colour = #FF0000;#0000FF\nG90\nM83\n; CHANGE_LAYER\nT0\nG1 X10 E1 F600\nT1\nG1 X20 E1\n; CHANGE_LAYER\nG1 X30 Z.4 E1"
    )
    precondition(
      d.colors.count == 2 && d.colors[1].z == 1 && d.layerCount == 2 && d.toolChanges == 1
        && d.index(at: 1) == 1)
  }
  check("Empty file rejected") {
    do {
      _ = try GCodeParser.parse("G28\nM106 S128")
      preconditionFailure()
    } catch {}
  }
  try check("Full circle and radius arcs") {
    let d = try GCodeParser.parse(
      "G90\nM83\nG1 X10 Z.2\nG2 X10 Y0 I-10 J0 E1 F600\nG3 X-10 Y0 R10 E1")
    equal(d.duration, 3 * Double.pi, 0.005)
  }
  if let path = CommandLine.arguments.dropFirst().first {
    try check("Metal shader compiles on the real GPU") {
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw LoadError.archive("No Metal device")
      }
      let lib = try device.makeLibrary(
        source: String(contentsOfFile: path, encoding: .utf8), options: nil)
      precondition(lib.makeFunction(name: "bead") != nil && lib.makeFunction(name: "shaded") != nil)
    }
  }
  print("\(count) checks passed")
} catch {
  fputs("FAIL: \(error)\n", stderr)
  exit(1)
}
