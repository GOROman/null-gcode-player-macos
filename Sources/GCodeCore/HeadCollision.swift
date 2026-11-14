import simd

public struct HeadEnvelope: Sendable {
  public var low, high: SIMD3<Float>
  // Approximate visual-model envelopes, including clearance, in viewer coordinates.
  // Not manufacturer CAD; the nozzle's immediate deposition zone is excluded.
  public static let zones: [HeadEnvelope] = [
    .init(low: SIMD3(-2.5, 0.8, -2.5), high: SIMD3(2.5, 4, 2.5)),
    .init(low: SIMD3(-4, 3.5, -4), high: SIMD3(4, 14, 4)),
    .init(low: SIMD3(-12, 4, -7), high: SIMD3(12, 24, 13)),
    .init(low: SIMD3(-18, 14, -57), high: SIMD3(18, 70, 12)),
    .init(low: SIMD3(-7, 68, -5), high: SIMD3(7, 89, 6)),
  ]
  public static func wireVertices() -> [HeadVertex] {
    var result = [HeadVertex]()
    for zone in zones {
      let points = (0..<8).map { i in
        SIMD3<Float>(
          i & 1 == 0 ? zone.low.x : zone.high.x,
          i & 2 == 0 ? zone.low.y : zone.high.y,
          i & 4 == 0 ? zone.low.z : zone.high.z)
      }
      for i in 0..<8 {
        for bit in [1, 2, 4] where i & bit == 0 {
          for index in [i, i | bit] {
            result.append(
              HeadVertex(
                position: SIMD4(points[index], 1),
                normal: SIMD4(0, 1, 0, 0), color: SIMD4(1, 0.12, 0.02, 1)))
          }
        }
      }
    }
    return result
  }
}

public struct HeadCollision: Sendable {
  public var moveIndex: Int
  public var printedMoveIndex: Int
  public var line: Int
  public var start, end: Double
}

public enum HeadCollisionCheck {
  private struct Node {
    var low, high: SIMD3<Float>
    var range: Range<Int>
    var left = -1, right = -1
  }
  // Conservative swept boxes: diagonal sweeps can over-report. Checks only material
  // deposited BEFORE each movement. Travel and retractions are checked as well.
  public static func analyze(_ moves: [Move]) -> [HeadCollision] {
    let ids = moves.indices.filter { moves[$0].deposit }
    guard !ids.isEmpty else { return [] }
    var nodes = [Node]()
    func radius(_ m: Move) -> SIMD3<Float> {
      SIMD3(repeating: max(m.width, m.height) * 0.75 + 0.02)
    }
    func build(_ range: Range<Int>) -> Int {
      let n = nodes.count
      nodes.append(
        Node(low: SIMD3(repeating: .infinity), high: SIMD3(repeating: -.infinity), range: range))
      if range.count <= 16 {
        for k in range {
          let m = moves[ids[k]]
          let r = radius(m)
          nodes[n].low = simd_min(nodes[n].low, simd_min(m.a, m.b) - r)
          nodes[n].high = simd_max(nodes[n].high, simd_max(m.a, m.b) + r)
        }
      } else {
        let mid = range.lowerBound + range.count / 2
        let l = build(range.lowerBound..<mid)
        let r = build(mid..<range.upperBound)
        nodes[n].left = l
        nodes[n].right = r
        nodes[n].low = simd_min(nodes[l].low, nodes[r].low)
        nodes[n].high = simd_max(nodes[l].high, nodes[r].high)
      }
      return n
    }
    _ = build(0..<ids.count)
    func intersects(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ low: SIMD3<Float>, _ high: SIMD3<Float>)
      -> Bool
    {
      var enter: Float = 0
      var exit: Float = 1
      for axis in 0..<3 {
        let d = b[axis] - a[axis]
        if abs(d) < 0.000001 {
          if a[axis] < low[axis] || a[axis] > high[axis] { return false }
        } else {
          let t1 = (low[axis] - a[axis]) / d
          let t2 = (high[axis] - a[axis]) / d
          enter = max(enter, min(t1, t2))
          exit = min(exit, max(t1, t2))
          if enter > exit { return false }
        }
      }
      return true
    }
    func query(_ n: Int, _ before: Int, _ low: SIMD3<Float>, _ high: SIMD3<Float>) -> Int? {
      let node = nodes[n]
      if ids[node.range.lowerBound] >= before { return nil }
      for axis in 0..<3 {
        if node.high[axis] < low[axis] || node.low[axis] > high[axis] { return nil }
      }
      if node.left >= 0 {
        return query(node.left, before, low, high) ?? query(node.right, before, low, high)
      }
      for k in node.range where ids[k] < before {
        let m = moves[ids[k]]
        let r = radius(m)
        if intersects(m.a, m.b, low - r, high + r) { return ids[k] }
      }
      return nil
    }
    var hits = [HeadCollision]()
    for (i, move) in moves.enumerated() {
      for zone in HeadEnvelope.zones {
        let low = simd_min(move.a, move.b) + zone.low
        let high = simd_max(move.a, move.b) + zone.high
        if let other = query(0, i, low, high) {
          hits.append(
            HeadCollision(
              moveIndex: i, printedMoveIndex: other, line: move.line,
              start: move.start, end: move.end))
          break
        }
      }
    }
    return hits
  }
}
