import Foundation
import Metal
import simd

/// GPU Jacobi contact projection. Completed positions are consumed on the next frame;
/// the render thread never waits for GPU readback.
final class GPUFilamentContacts {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  private let lock = NSLock()
  private var busy = false
  private var ready: [SIMD3<Float>]?
  init(device: MTLDevice, library: MTLLibrary) throws {
    self.device = device
    pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "filamentContacts")!)
  }
  var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return busy }
  func consume() -> (waiting: Bool, points: [SIMD3<Float>]?) {
    lock.lock(); defer { lock.unlock() }
    let points = ready; ready = nil
    return (busy, points)
  }
  func encode(command: MTLCommandBuffer, positions: [SIMD3<Float>], mobility: [Float]) {
    guard positions.count > 3 else { return }
    let values = positions.enumerated().map { SIMD4($0.element, mobility[$0.offset]) }
    guard let a = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
          let b = device.makeBuffer(length: values.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
    else { return }
    lock.lock(); busy = true; lock.unlock()
    var count = UInt32(values.count)
    var input = a, output = b
    for _ in 0..<4 {
      guard let encoder = command.makeComputeCommandEncoder() else { break }
      encoder.setComputePipelineState(pipeline)
      encoder.setBuffer(input, offset: 0, index: 0)
      encoder.setBuffer(output, offset: 0, index: 1)
      encoder.setBytes(&count, length: 4, index: 2)
      encoder.dispatchThreads(MTLSize(width: values.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(128,pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
      encoder.endEncoding()
      swap(&input, &output)
    }
    let result = input
    command.addCompletedHandler { [self] command in
      let ptr = result.contents().bindMemory(to: SIMD4<Float>.self, capacity: values.count)
      let points = command.status == .completed ? (0..<values.count).map { SIMD3(ptr[$0].x,ptr[$0].y,ptr[$0].z) } : nil
      lock.lock(); ready = points; busy = false; lock.unlock()
    }
  }
}
