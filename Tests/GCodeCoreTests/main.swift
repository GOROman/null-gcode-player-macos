import Foundation
import GCodeCore
import Metal
import simd

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
  try check("Straight-run compaction preserves timing and source moves") {
    let file = try GCodeParser.parse("G90\nM83\nG1 X0 Z.2\nG1 X1 E.1 F60\nG1 X2 E.1\nG1 X3 E.1")
    let runs = DepositCompactor.compact(file.moves)
    precondition(file.moves.count == 3 && runs.count == 1)
    equal(runs[0].start, 0)
    equal(runs[0].end, 3)
    equal(Double(runs[0].b.x), 3)
    for t in [0.5, 1.5, 2.5] {
      let source = file.moves[file.index(at: t)]
      let sourceX =
        Double(source.a.x) + (Double(source.b.x - source.a.x)) * (t - source.start)
        / (source.end - source.start)
      let compactX =
        Double(runs[0].a.x) + Double(runs[0].b.x - runs[0].a.x) * (t - runs[0].start)
        / (runs[0].end - runs[0].start)
      equal(sourceX, compactX)
    }
  }
  try check("Compaction keeps corners, feed changes, colors, layers and travel boundaries") {
    let prefix = "G90\nM83\nG1 X0 Z.2\nG1 X1 E.1 F60\n"
    for suffix in [
      "G1 Y1 E.1", "G1 X2 E.1 F120", "T1\nG1 X2 E.1", "G1 X2 Z.4 E.1", "G1 X2\nG1 X3 E.1",
    ] {
      let file = try GCodeParser.parse(prefix + suffix)
      precondition(DepositCompactor.compact(file.moves).count == 2)
    }
  }
  check("Metal frustum handles all six planes and boundary intersections") {
    let frustum = ViewFrustum(matrix_identity_float4x4)
    let inside = RenderBounds(low: SIMD3(-0.5, -0.5, 0.1), high: SIMD3(0.5, 0.5, 0.9))
    precondition(frustum.contains(inside) && frustum.intersects(inside))
    for offset: SIMD3<Float> in [
      SIMD3(3, 0, 0), SIMD3(-3, 0, 0), SIMD3(0, 3, 0), SIMD3(0, -3, 0), SIMD3(0, 0, -3),
      SIMD3(0, 0, 3),
    ] {
      precondition(
        !frustum.intersects(RenderBounds(low: inside.low + offset, high: inside.high + offset)))
    }
    let edge = RenderBounds(low: SIMD3(0.8, -0.5, 0.1), high: SIMD3(1.2, 0.5, 0.9))
    precondition(frustum.intersects(edge) && !frustum.contains(edge))
  }
  check("Block culling clips partial playback and coalesces adjacent visible ranges") {
    let inside = RenderBounds(low: SIMD3(-0.5, -0.5, 0.1), high: SIMD3(0.5, 0.5, 0.9))
    let outside = RenderBounds(low: SIMD3(2, 0, 0), high: SIMD3(3, 1, 1))
    let blocks = [
      RenderBlock(first: 0, count: 256, bounds: inside),
      RenderBlock(first: 256, count: 256, bounds: outside),
      RenderBlock(first: 512, count: 256, bounds: inside),
      RenderBlock(first: 768, count: 256, bounds: inside),
    ]
    let frustum = ViewFrustum(matrix_identity_float4x4)
    precondition(frustum.visibleRanges(blocks, count: 590) == [0..<256, 512..<590])
    precondition(frustum.visibleRanges(blocks, count: 1000) == [0..<256, 512..<1000])
    precondition(frustum.visibleRanges(blocks, count: 0).isEmpty)
  }
  check("Adaptive quality ignores isolated spikes, has a floor and restores paused detail") {
    var quality = AdaptiveRenderQuality()
    for _ in 0..<30 { quality.sample(milliseconds: 3, active: true) }
    quality.sample(milliseconds: 20, active: true)
    precondition(quality.scale == 1)
    for _ in 0..<400 { quality.sample(milliseconds: 12, active: true) }
    precondition(quality.scale >= 0.7 && quality.scale < 0.8)
    for _ in 0..<1500 { quality.sample(milliseconds: 2, active: true) }
    equal(quality.scale, 1)
    for _ in 0..<100 { quality.sample(milliseconds: 12, active: true) }
    quality.sample(milliseconds: 10, active: false)
    equal(quality.scale, 1)
  }
  try check("Tool-change counter follows seeking and ignores unused switches") {
    let file = try GCodeParser.parse(
      "G90\nM83\nG1 X0 Z.2\nT0\nG1 X1 E1 F60\nT1\nG1 X2 E1\nT2\nT1\nG1 X3 E1\nT0\nG1 X4 E1")
    precondition(file.toolChanges == 2)
    precondition(file.toolChanges(at: 0) == 0 && file.toolChanges(at: 0.99) == 0)
    precondition(file.toolChanges(at: 1) == 1 && file.toolChanges(at: 2.5) == 1)
    precondition(file.toolChanges(at: 3) == 2 && file.toolChanges(at: file.duration) == 2)
    precondition(file.toolChanges(at: 0.5) == 0)
  }
  try check("Spool consumption interpolates by tool and does not count unretraction twice") {
    let file = try GCodeParser.parse(
      "G90\nM83\nG1 X0 Z.2\nG1 X10 E2 F600\nG1 E-1\nG1 E1\nT1\nG1 X20 E3\nT0\nG1 X30 E1")
    equal(file.filamentUsage.millimeters(tool: 0, at: 0.5), 1)
    equal(file.filamentUsage.millimeters(tool: 0, at: 2.5), 2.5)
    equal(file.filamentUsage.millimeters(tool: 1, at: 1.5), 1.5)
    equal(file.filamentUsage.millimeters(tool: 0, at: file.duration), 3)
    equal(file.filamentUsage.millimeters(tool: 1, at: file.duration), 3)
    equal(file.filamentUsage.millimeters(tool: 0, at: 0.25), 0.5)
    equal(FilamentUsage.rotationDegrees(millimeters: 2 * .pi * 90), 360)
  }
  try check("Spool usage handles absolute E, G92, inch units and tessellated arcs") {
    let absolute = try GCodeParser.parse(
      "G90\nM82\nG1 X0 Z.2\nG1 X10 E2 F600\nG1 X20 E4\nG92 E0\nG1 X30 E2")
    equal(absolute.filamentUsage.millimeters(tool: 0, at: absolute.duration), 6)
    let inches = try GCodeParser.parse("G20\nM83\nG1 X1 E.1 F60")
    equal(inches.filamentUsage.millimeters(tool: 0, at: inches.duration), 2.54)
    let arc = try GCodeParser.parse("G90\nM83\nG1 X10 Z.2\nG2 X10 Y0 I-10 J0 E10 F600")
    equal(arc.filamentUsage.millimeters(tool: 0, at: arc.duration), 10)
    equal(arc.filamentUsage.millimeters(tool: 0, at: arc.duration / 2), 5)
  }
  check("H3C mesh has finite geometry, an outlet at the origin and separate transparent parts") {
    let mesh = H3CHeadMesh()
    precondition(!mesh.opaque.isEmpty && !mesh.transparent.isEmpty)
    precondition(MemoryLayout<HeadVertex>.stride == 48)
    precondition(mesh.opaque.count % 3 == 0 && mesh.transparent.count % 3 == 0)
    let vertices = mesh.opaque + mesh.transparent
    precondition(vertices.count < 50000)
    for vertex in vertices {
      precondition(
        vertex.position.x.isFinite && vertex.position.y.isFinite && vertex.position.z.isFinite)
      equal(Double(simd_length(SIMD3(vertex.normal.x, vertex.normal.y, vertex.normal.z))), 1)
      precondition(vertex.position.y >= (-0.001) && vertex.position.y <= 88)
    }
    precondition(
      vertices.contains {
        $0.position.y < 0.01 && abs($0.position.x) < 0.21 && abs($0.position.z) < 0.21
      })
    precondition(mesh.opaque.contains { $0.color.w < 0 })
  }
  if let path = CommandLine.arguments.dropFirst().first {
    try check("Metal shader compiles on the real GPU") {
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw LoadError.archive("No Metal device")
      }
      let lib = try device.makeLibrary(
        source: String(contentsOfFile: path, encoding: .utf8), options: nil)
      precondition(
        lib.makeFunction(name: "bead") != nil && lib.makeFunction(name: "shaded") != nil
          && lib.makeFunction(name: "ribbon") != nil && lib.makeFunction(name: "toolhead") != nil)
    }
  }
  print("\(count) checks passed")
} catch {
  fputs("FAIL: \(error)\n", stderr)
  exit(1)
}
