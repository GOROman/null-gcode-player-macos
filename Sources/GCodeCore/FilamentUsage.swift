import Foundation

public struct FilamentSpan: Sendable {
  public var start, end, before, after: Double
}
public struct FilamentUsage: Sendable {
  public var spans: [Int: [FilamentSpan]] = [:]
  public init() {}
  public mutating func append(tool: Int, start: Double, end: Double, millimeters: Double) {
    guard millimeters > 0, end > start else { return }
    let before = spans[tool]?.last?.after ?? 0
    spans[tool, default: []].append(
      FilamentSpan(start: start, end: end, before: before, after: before + millimeters))
  }
  public func millimeters(tool: Int, at time: Double) -> Double {
    guard let events = spans[tool], !events.isEmpty else { return 0 }
    var lo = 0
    var hi = events.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if events[mid].end <= time { lo = mid + 1 } else { hi = mid }
    }
    guard lo < events.count else { return events.last!.after }
    let event = events[lo]
    let fraction = max(0, min(1, (time - event.start) / (event.end - event.start)))
    return event.before + (event.after - event.before) * fraction
  }
  // A nominal 90 mm winding radius provides proportional visual rotation.
  // This does not estimate the physical amount remaining on an unknown spool.
  public static func rotationDegrees(millimeters: Double) -> Double {
    millimeters / (2 * .pi * 90) * 360
  }
}
