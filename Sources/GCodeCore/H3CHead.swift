import simd

public struct HeadVertex: Sendable { public var position, normal, color: SIMD4<Float> }
public struct H3CHeadMesh: Sendable {
  public var opaque: [HeadVertex] = [], transparent: [HeadVertex] = []
  public init() {
    // Visual reconstruction from the supplied PrintTool photo, not manufacturer CAD.
    // Outlet is the local origin. Frame width is approximately 32 mm; the lower
    // and upper bearing references follow the web player's documented calibration.
    let shell = SIMD4<Float>(0.28, 0.32, 0.33, 0.25)
    let black = SIMD4<Float>(0.018, 0.023, 0.027, 0.78)
    let rubber = SIMD4<Float>(0.01, 0.014, 0.017, 0.9)
    let metal = SIMD4<Float>(0.47, 0.53, 0.55, 1)
    let steel = SIMD4<Float>(0.08, 0.095, 0.11, 1)
    let orange = SIMD4<Float>(0.55, 0.27, 0.045, 1)
    for side: Float in [-1, 1] {
      box(3.8, 44, 4, side * 13.5, 39, -53.2, shell)
      box(3.2, 39, 3, side * 14, 37, 7, shell)
      box(4.8, 3.5, 14, side * 12, 17, 1, shell)
      box(3.5, 2.8, 50, side * 14, 57, -23, shell)
      for y: Float in [28.8, 48.8] {
        tube(SIMD3(side * 12.3, y, -53.2), SIMD3(side * 16, y, -53.2), 2.8, 2.8, metal, 16)
        tube(SIMD3(side * 16.01, y, -53.2), SIMD3(side * 16.06, y, -53.2), 2, 2, rubber, 16)
      }
      for y: Float in [18, 55] {
        tube(SIMD3(side * 12, y, 8.5), SIMD3(side * 12, y, 9), 0.7, 0.7, steel, 10)
      }
    }
    box(31, 3.5, 14, 0, 58, 2, shell)
    box(29, 3, 3, 0, 55, -53.2, shell)
    box(14, 32, 9.5, 0, 38, 1, black)
    box(11.5, 27, 2, 0, 37, 7.2, rubber)
    box(8.5, 8.7, 0.9, 0, 47.5, 8.6, orange)
    box(6.7, 6.5, 1.1, 0, 47.6, 9.4, rubber)
    box(7.8, 21, 7.5, 0, 64, 1, black)
    box(3, 11, 3.5, 3.7, 69, 1, black)
    tube(SIMD3(2.4, 74, 1), SIMD3(2.4, 87, 1), 0.7, 0.7, SIMD4(0.5, 0.63, 0.67, 0.24), 12)
    tube(SIMD3(2.4, 74, 1), SIMD3(2.4, 87, 1), 0.28, 0.28, SIMD4(1, 1, 1, -1), 10)
    for side: Float in [-1, 1] { box(3.2, 2.6, 0.7, side * 4, 30, 8.6, metal) }
    box(2.3, 7, 0.8, 0, 27.8, 8.7, steel)
    box(7.2, 2.5, 0.4, 0, 37, 8.45, SIMD4(0.45, 0.51, 0.51, 0.7))
    for y: Float in [24, 34, 41, 54] {
      tube(SIMD3(0, y, 8.3), SIMD3(0, y, 9.1), 0.65, 0.65, steel, 10)
    }
    for index in 0..<6 { box(12, 0.65, 10, 0, 14.1 + Float(index) * 1.35, 1, black) }
    box(10.5, 1.8, 10.5, 0, 22, 1, black)
    tube(SIMD3(0, 9.5, 0), SIMD3(0, 15, 0), 1.1, 1.1, steel, 12)
    tube(SIMD3(0, 3.7, 0), SIMD3(0, 12.8, 0), 2.8, 3.6, rubber, 20)
    tube(SIMD3(0, 1.7, 0), SIMD3(0, 3.7, 0), 2.2, 3, metal, 20)
    tube(SIMD3(0, 0.1, 0), SIMD3(0, 1.7, 0), 0.32, 2.2, steel, 24)
    tube(SIMD3(0, 0, 0), SIMD3(0, 0.11, 0), 0.2, 0.2, rubber, 16)
    for side: Float in [-1, 1] { box(2.1, 2.2, 5, side * 5.6, 13.2, 1, metal) }
    // Open cooling duct and side fan preserve visibility of the active nozzle.
    for side: Float in [-1, 1] {
      tube(SIMD3(side * 9, 12, -4), SIMD3(side * 9, 7, 7), 1.45, 1.45, rubber, 12)
      tube(SIMD3(side * 9, 7, 7), SIMD3(side * 4, 6, 10), 1.45, 1.45, rubber, 12)
    }
    for index in 0..<20 {
      let a = Float(index) * 2 * .pi / 20
      let b = Float(index + 1) * 2 * .pi / 20
      tube(
        SIMD3(15.6, 19 + cos(a) * 4.8, sin(a) * 4.8), SIMD3(15.6, 19 + cos(b) * 4.8, sin(b) * 4.8),
        0.45, 0.45, black, 8)
    }
    tube(SIMD3(15, 19, 0), SIMD3(16, 19, 0), 1.3, 1.3, black, 12)
    for index in 0..<7 {
      let angle = Float(index) * 2 * .pi / 7
      tube(SIMD3(15.5, 19, 0), SIMD3(15.5, 19 + cos(angle) * 4, sin(angle) * 4), 0.5, 0.5, black, 8)
    }
    for index in 0..<8 {
      box(
        3.5, 2.1, 2.7, -4 + Float(index) * 3, 62 + sin(Float(index) / 7 * .pi) * 6,
        -35 - Float(index) * 0.5, black)
    }
  }
  private mutating func triangle(
    _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ na: SIMD3<Float>, _ nb: SIMD3<Float>,
    _ nc: SIMD3<Float>, _ color: SIMD4<Float>
  ) {
    let vertices = [
      HeadVertex(position: SIMD4(a, 1), normal: SIMD4(na, 0), color: color),
      HeadVertex(position: SIMD4(b, 1), normal: SIMD4(nb, 0), color: color),
      HeadVertex(position: SIMD4(c, 1), normal: SIMD4(nc, 0), color: color),
    ]
    if color.w >= 1 || color.w < 0 {
      opaque.append(contentsOf: vertices)
    } else {
      transparent.append(contentsOf: vertices)
    }
  }
  private mutating func box(
    _ w: Float, _ h: Float, _ d: Float, _ x: Float, _ y: Float, _ z: Float, _ color: SIMD4<Float>
  ) {
    let center = SIMD3(x, y, z)
    let half = SIMD3(w, h, d) * 0.5
    for axis in 0..<3 {
      for sign: Float in [-1, 1] {
        var normal = SIMD3<Float>.zero
        normal[axis] = sign
        let u = (axis + 1) % 3
        let v = (axis + 2) % 3
        var p = [SIMD3<Float>]()
        for corner in [SIMD2<Float>(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)] {
          var point = center
          point[axis] += sign * half[axis]
          point[u] += corner.x * half[u]
          point[v] += corner.y * half[v]
          p.append(point)
        }
        triangle(p[0], p[1], p[2], normal, normal, normal, color)
        triangle(p[0], p[2], p[3], normal, normal, normal, color)
      }
    }
  }
  private mutating func tube(
    _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ bottom: Float, _ top: Float, _ color: SIMD4<Float>,
    _ sides: Int
  ) {
    let axis = simd_normalize(b - a)
    let reference = abs(axis.y) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
    let u = simd_normalize(simd_cross(axis, reference))
    let v = simd_cross(axis, u)
    let slope = (bottom - top) / simd_length(b - a)
    for index in 0..<sides {
      let x = Float(index) * 2 * .pi / Float(sides)
      let y = Float(index + 1) * 2 * .pi / Float(sides)
      let r = u * cos(x) + v * sin(x)
      let s = u * cos(y) + v * sin(y)
      let n = simd_normalize(r + axis * slope)
      let m = simd_normalize(s + axis * slope)
      let p = a + r * bottom
      let q = a + s * bottom
      let t = b + r * top
      let k = b + s * top
      triangle(p, q, t, n, m, n, color)
      triangle(t, q, k, n, m, m, color)
      triangle(a, q, p, -axis, -axis, -axis, color)
      triangle(b, t, k, axis, axis, axis, color)
    }
  }
}
