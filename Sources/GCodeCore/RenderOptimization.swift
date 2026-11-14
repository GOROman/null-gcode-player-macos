import Foundation
import simd

public struct DepositRun: Sendable {
  public var a, b: SIMD3<Float>
  public var start, end: Double
  public var width, height: Float
  public var tool, layer: Int
}

public enum DepositCompactor {
  // Merge only continuous straight runs with identical material and feedrate.
  // Source moves remain unchanged for Step, subtitles, head motion and seeking.
  public static func compact(_ moves: [Move]) -> [DepositRun] {
    var runs = [DepositRun]()
    runs.reserveCapacity(moves.count / 2)
    var previousWasDeposit = false
    for move in moves {
      guard move.deposit else {
        previousWasDeposit = false
        continue
      }
      if previousWasDeposit, let previous = runs.last,
        previous.tool == move.tool, previous.layer == move.layer,
        previous.width == move.width, previous.height == move.height,
        abs(previous.end - move.start) < 1e-7,
        simd_length_squared(previous.b - move.a) < 1e-10
      {
        let first = previous.b - previous.a
        let next = move.b - move.a
        let length = simd_length(first)
        let nextLength = simd_length(next)
        if length > 0, nextLength > 0,
          simd_dot(first, next) > 0,
          simd_length(simd_cross(first / length, next / nextLength)) < 1e-6,
          abs(
            Double(length) / (previous.end - previous.start)
              - Double(nextLength) / (move.end - move.start)) < 1e-4
        {
          runs[runs.count - 1].b = move.b
          runs[runs.count - 1].end = move.end
          continue
        }
      }
      runs.append(
        DepositRun(
          a: move.a, b: move.b, start: move.start, end: move.end,
          width: move.width, height: move.height, tool: move.tool, layer: move.layer))
      previousWasDeposit = true
    }
    return runs
  }
}

public struct RenderBounds: Sendable {
  public var low, high: SIMD3<Float>
  public init(low: SIMD3<Float>, high: SIMD3<Float>) {
    self.low = low
    self.high = high
  }
}
public struct RenderBlock: Sendable {
  public var first, count: Int
  public var bounds: RenderBounds
  public var beadWidth: Float
  public init(first: Int, count: Int, bounds: RenderBounds, beadWidth: Float = 0.42) {
    self.beadWidth = beadWidth
    self.first = first
    self.count = count
    self.bounds = bounds
  }
}
public struct ViewFrustum {
  var planes: [SIMD4<Float>]
  public init(_ matrix: simd_float4x4) {
    let rows = matrix.transpose
    planes = [
      rows[3] + rows[0], rows[3] - rows[0], rows[3] + rows[1], rows[3] - rows[1],
      rows[2], rows[3] - rows[2],
    ]
  }
  public func intersects(_ bounds: RenderBounds) -> Bool {
    for plane in planes {
      let p = SIMD3(
        plane.x >= 0 ? bounds.high.x : bounds.low.x,
        plane.y >= 0 ? bounds.high.y : bounds.low.y, plane.z >= 0 ? bounds.high.z : bounds.low.z)
      if simd_dot(SIMD3(plane.x, plane.y, plane.z), p) + plane.w < 0 { return false }
    }
    return true
  }
  public func contains(_ bounds: RenderBounds) -> Bool {
    for plane in planes {
      let p = SIMD3(
        plane.x >= 0 ? bounds.low.x : bounds.high.x,
        plane.y >= 0 ? bounds.low.y : bounds.high.y, plane.z >= 0 ? bounds.low.z : bounds.high.z)
      if simd_dot(SIMD3(plane.x, plane.y, plane.z), p) + plane.w < 0 { return false }
    }
    return true
  }
  public func visibleRanges(_ blocks: [RenderBlock], count: Int) -> [Range<Int>] {
    var ranges = [Range<Int>]()
    for block in blocks {
      guard block.first < count else { break }
      guard intersects(block.bounds) else { continue }
      let end = min(count, block.first + block.count)
      if let last = ranges.last, last.upperBound == block.first {
        ranges[ranges.count - 1] = last.lowerBound..<end
      } else {
        ranges.append(block.first..<end)
      }
    }
    return ranges
  }
}

public struct AdaptiveRenderQuality {
  public private(set) var scale = 1.0
  private var average = 0.0, slow = 0, fast = 0
  public init() {}
  public mutating func sample(milliseconds: Double, active: Bool) {
    guard active else {
      scale = 1
      average = 0
      slow = 0
      fast = 0
      return
    }
    guard milliseconds.isFinite, milliseconds > 0 else { return }
    average = average == 0 ? milliseconds : average * 0.92 + milliseconds * 0.08
    if average > 7 {
      slow += 1
      fast = 0
    } else if average < 4.5 {
      fast += 1
      slow = 0
    } else {
      slow = 0
      fast = 0
    }
    if slow >= 40 {
      scale = max(0.7, scale - 0.1)
      slow = 0
    }
    if fast >= 180 {
      scale = min(1, scale + 0.05)
      fast = 0
    }
  }
}
