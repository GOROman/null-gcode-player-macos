import Foundation

/// Qualitative PLA model. Relative viscosity, not measured Pa·s.
public struct PLAMaterial {
  public var nozzle: Float = 210
  public var ambient: Float = 25
  public var fan: Float = 1
  public var viscosityScale: Float = 1
  public init() {}
  public func cooled(_ temperature: Float, dt: Float) -> Float {
    ambient + (temperature-ambient) * exp(-max(0,dt)*(0.35+max(0,min(1,fan))*0.65))
  }
  public func viscosity(_ temperature: Float) -> Float {
    min(50,max(0.05,viscosityScale * exp((210-temperature)/35)))
  }
  public func hardness(_ temperature: Float) -> Float {
    min(1,max(0,(110-temperature)/50))
  }
}
