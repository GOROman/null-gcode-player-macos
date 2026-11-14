import simd

public enum GeometryLOD: Int, Sendable { case detailed, balanced, distant }
public struct LODDrawRange: Sendable {
  public var range: Range<Int>
  public var detail: GeometryLOD
}
public struct LODPlanner {
  private var history = [Int: GeometryLOD]()
  public init() {}
  public mutating func plan(
    blocks: [RenderBlock], count: Int, eye: SIMD3<Float>, height: Float, fov: Float,
    frustum: ViewFrustum? = nil, forceDetailedIndex: Int? = nil, override: GeometryLOD? = nil
  ) -> [LODDrawRange] {
    var result = [LODDrawRange]()
    let projection = height / (2 * tan(fov / 2))
    for block in blocks {
      guard block.first < count else { break }
      if let frustum, !frustum.intersects(block.bounds) { continue }
      let nearest = simd_clamp(eye, block.bounds.low, block.bounds.high)
      let pixels = block.beadWidth * projection / max(0.1, simd_length(eye - nearest))
      var detail: GeometryLOD
      if let override {
        detail = override
      } else if let forced = forceDetailedIndex,
        forced >= block.first && forced < block.first + block.count
      {
        detail = .detailed
      } else {
        switch history[block.first] {
        case .detailed?: detail = pixels >= 4.3 ? .detailed : (pixels >= 1.7 ? .balanced : .distant)
        case .balanced?: detail = pixels > 5.7 ? .detailed : (pixels < 1.7 ? .distant : .balanced)
        case .distant?: detail = pixels <= 2.3 ? .distant : (pixels > 5.7 ? .detailed : .balanced)
        case nil: detail = pixels >= 5 ? .detailed : (pixels >= 2 ? .balanced : .distant)
        }
      }
      history[block.first] = detail
      let end = min(count, block.first + block.count)
      if let previous = result.last,
        previous.detail == detail && previous.range.upperBound == block.first
      {
        result[result.count - 1].range = previous.range.lowerBound..<end
      } else {
        result.append(LODDrawRange(range: block.first..<end, detail: detail))
      }
    }
    return result
  }
}
