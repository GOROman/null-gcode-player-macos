// Indices address the procedural vertex IDs used by the Metal shader. Repeated
// references allow Metal's post-transform cache to reuse generated vertices.
public enum MeshTopology {
  public static let bead: [UInt16] = {
    var indices = [UInt16]()
    for face in 0..<8 {
      let a = face * 6
      let b = ((face + 1) % 8) * 6
      indices += [a, a + 1, b, b, a + 1, b + 1].map(UInt16.init)
    }
    for base in [48, 72] {
      for face in 0..<8 {
        indices += [base, base + 1 + face * 3, base + 1 + ((face + 1) % 8) * 3].map(UInt16.init)
      }
    }
    return indices
  }()
  public static let balanced: [UInt16] = {
    var indices = [UInt16]()
    for face in stride(from: 0, to: 8, by: 2) {
      let a = face * 6
      let b = ((face + 2) % 8) * 6
      indices += [a, a + 1, b, b, a + 1, b + 1].map(UInt16.init)
    }
    for base in [48, 72] {
      for face in stride(from: 0, to: 8, by: 2) {
        indices += [base, base + 1 + face * 3, base + 1 + ((face + 2) % 8) * 3].map(UInt16.init)
      }
    }
    return indices
  }()
  public static let balancedVertices = Set(balanced).count
  public static let ribbon: [UInt16] = [0, 1, 2, 2, 1, 5]
  public static let crossedRibbon: [UInt16] = [0, 1, 2, 2, 1, 5, 6, 7, 8, 8, 7, 11]
  public static let meniscus: [UInt16] = {
    func reference(_ x: Int, _ y: Int) -> UInt16 {
      if y == 0 { return 0 }
      if y == 8 { return UInt16(7 * 16 * 6 + 2) }
      return UInt16((y * 16 + x % 16) * 6)
    }
    var indices = [UInt16]()
    for y in 0..<8 {
      for x in 0..<16 {
        let a = reference(x, y)
        let b = reference(x + 1, y)
        let c = reference(x, y + 1)
        let d = reference(x + 1, y + 1)
        if y > 0 { indices += [a, b, c] }
        if y < 7 { indices += [c, b, d] }
      }
    }
    return indices
  }()
  public static let beadVertices = Set(bead).count
  public static let ribbonVertices = Set(ribbon).count
  public static let meniscusVertices = Set(meniscus).count
}
