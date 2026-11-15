import simd

/// Bounded viscoplastic strand approximation with dissipative contact and cooling.
/// This models visual failure, not material adhesion or a calibrated thermal process.
public struct Spaghetti {
  public private(set) var colors: [SIMD4<Float>] = []
  private var born: [Float] = []
  private var restLengths: [Float] = []
  public var material = PLAMaterial()
  public var gpuContacts = false
  public var friction: Float = 0.45
  public static func frictionVelocity(_ velocity: SIMD3<Float>, normal: SIMD3<Float>, load: Float, coefficient: Float) -> SIMD3<Float> {
    let normalSpeed = simd_dot(velocity,normal)
    let tangent = velocity-normal*normalSpeed
    let length = simd_length(tangent)
    let reduction = max(0,coefficient)*max(0,load)
    return normal*max(0,normalSpeed) + tangent*max(0,1-reduction/max(0.000001,length))
  }
  private mutating func contact(_ i: Int, normal: SIMD3<Float>, depth: Float) {
    let velocity = points[i]-previous[i]
    previous[i] = points[i]-Self.frictionVelocity(velocity,normal:normal,load:max(depth,-simd_dot(velocity,normal)),coefficient:friction)
  }
  public mutating func applyContacts(_ corrected: [SIMD3<Float>]) {
    guard corrected.count == points.count else { return }
    for i in points.indices {
      let delta = corrected[i]-points[i]
      points[i] = corrected[i]; previous[i] += delta
      let displacement = simd_length(delta)
      if displacement > 0.00001 { contact(i,normal:delta/displacement,depth:displacement) }
      let key = SIMD2(Int(floor(points[i].x)),Int(floor(points[i].z)))
      let floor = max(0.22,(surface[key] ?? 0)+0.22)
      if points[i].y < floor {
        let penetration = floor-points[i].y
        points[i].y = floor; previous[i].y += penetration
        contact(i,normal:SIMD3(0,1,0),depth:penetration)
      }
    }
  }
  public private(set) var temperatures: [Float] = []
  private var surface: [SIMD2<Int>: Float] = [:]
  public mutating func setObstacle(_ moves: [Move], through time: Double) {
    surface.removeAll(keepingCapacity: true)
    for m in moves where m.deposit && m.start < time {
      let t = Float(min(1, (time-m.start)/max(0.000001,m.end-m.start)))
      let end = simd_mix(m.a,m.b,SIMD3(repeating:t))
      let count = max(1,Int(ceil(simd_length(end-m.a)*2)))
      for j in 0...count {
        let p = simd_mix(m.a,end,SIMD3(repeating:Float(j)/Float(count)))
        let radius = max(m.width,m.height)*0.5 + 0.2
        for x in Int(floor(p.x-radius))...Int(floor(p.x+radius)) {
          for z in Int(floor(p.z-radius))...Int(floor(p.z+radius)) {
            let key = SIMD2(x,z)
            surface[key] = max(surface[key] ?? 0,p.y + m.height*0.5)
          }
        }
      }
    }
  }
  public func hardness(at index: Int) -> Float { material.hardness(temperatures[index]) }

  public private(set) var points: [SIMD3<Float>] = []
  private var previous: [SIMD3<Float>] = []
  private var accumulator: Float = 0
  private var age: Float = 0
  private var nextEmission: Float = 0
  public init() {}
  public mutating func advance(dt: Float, nozzle: SIMD3<Float>, emitting: Bool, color: SIMD4<Float> = SIMD4(0.4,0.9,0.7,1)) {
    accumulator += min(max(dt, 0), 0.05)
    let step: Float = 1 / 120
    while accumulator >= step {
      accumulator -= step; age += step
      if emitting && age >= nextEmission {
        // Retire the oldest strand instead of stopping extrusion at the capacity.
        if points.count >= 1200 {
          points.removeFirst(); previous.removeFirst(); colors.removeFirst(); born.removeFirst(); temperatures.removeFirst(); restLengths.removeFirst()
        }
        nextEmission = age + 0.025
        let p = nozzle
        restLengths.append(points.last.map { max(0.15,simd_distance($0,p)) } ?? 0.8)
        points.append(p); colors.append(color); born.append(age); temperatures.append(material.nozzle); previous.append(p)
      }
      for i in points.indices {
        temperatures[i] = material.cooled(temperatures[i], dt: step)
        if hardness(at: i) >= 1 { continue }
        let p = points[i]
        points[i] += (p - previous[i]) * exp(-step * (18 + material.viscosity(temperatures[i])*2)) + SIMD3(0, -180 * step * step, 0)
        previous[i] = p
      }
      for _ in 0..<5 {
        if points.count > 1 {
          for i in 1..<points.count {
            let d = points[i] - points[i-1], length = simd_length(d)
            if length > 0.00001 {
              let wa = 1-hardness(at: i-1), wb = 1-hardness(at: i)
              // Hot material creeps toward its deformed length, retaining deformation.
              // Never push compressed links apart: that made the old model springy.
              let viscosity = material.viscosity(temperatures[i])
              let plastic = (1-hardness(at:i)) * (1-exp(-step/(5*max(0.08,viscosity))))
              restLengths[i] += (length-restLengths[i])*plastic
              let extensionAmount = max(0,length-restLengths[i])
              let correction = d * (extensionAmount/length) * 0.18 / max(0.00001,wa+wb)
              let da = correction*wa, db = -correction*wb
              points[i-1] += da; previous[i-1] += da
              points[i] += db; previous[i] += db
            }
          }
        }
        for i in points.indices where hardness(at: i) < 1 {
          let key = SIMD2(Int(floor(points[i].x)),Int(floor(points[i].z)))
          let floor = max(0.22,(surface[key] ?? 0)+0.22)
          if points[i].y < floor {
        let penetration = floor-points[i].y
        points[i].y = floor; previous[i].y += penetration
        contact(i,normal:SIMD3(0,1,0),depth:penetration)
      }
        }
        // Spatial hash: collide non-neighbor rope particles, preserving hardened points.
        if !gpuContacts {
        var cells: [SIMD3<Int>: [Int]] = [:]
        let diameter: Float = 0.44
        for i in points.indices {
          let p = points[i]
          let cell = SIMD3<Int>(Int(floor(p.x/diameter)),Int(floor(p.y/diameter)),Int(floor(p.z/diameter)))
          for x in -1...1 { for y in -1...1 { for z in -1...1 {
            for j in cells[cell &+ SIMD3(x,y,z)] ?? [] where i-j > 2 {
              let delta = points[i]-points[j], distance = simd_length(delta)
              if distance < diameter {
                let wi = 1-hardness(at:i), wj = 1-hardness(at:j), sum = wi+wj
                if sum > 0.00001 {
                  let direction = distance > 0.00001 ? delta/distance : SIMD3<Float>(1,0,0)
                  let push = direction*(diameter-distance)/sum
                  points[i] += push*wi; previous[i] += push*wi; points[j] -= push*wj; previous[j] -= push*wj
                }
              }
            }
          } } }
          cells[cell,default:[]].append(i)
        }
        }
        for i in points.indices {
          let key = SIMD2(Int(floor(points[i].x)),Int(floor(points[i].z)))
          let limit = max(0.22,(surface[key] ?? 0)+0.22)
          if points[i].y < limit { let depth = limit-points[i].y; points[i].y = limit; previous[i].y += depth; contact(i,normal:SIMD3(0,1,0),depth:depth) }
        }
        if emitting, !points.isEmpty, hardness(at: points.count-1) < 1 { let last = points.count-1; previous[last] += nozzle-points[last]; points[last] = nozzle }
      }
    }
  }
}
