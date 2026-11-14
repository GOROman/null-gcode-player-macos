import GCodeCore
import MetalKit
import simd

struct GPUInstance { var a, b, color, timing: SIMD4<Float> }
private struct Uniforms {
  var vp, lightVP: simd_float4x4
  var head, eye, clock: SIMD4<Float>
}
final class Renderer: NSObject, MTKViewDelegate {
  let player: Player, device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
    transparentPipeline: MTLRenderPipelineState, ribbonPipeline: MTLRenderPipelineState,
    depth: MTLDepthStencilState,
    transparentDepth: MTLDepthStencilState
  let inFlight = DispatchSemaphore(value: 3)
  var shadowPipeline: MTLRenderPipelineState!, shadowTexture: MTLTexture!,
    shadowVP = matrix_identity_float4x4, lastShadowTime = -Double.infinity
  var blocks = [RenderBlock](), modelBounds = RenderBounds(low: .zero, high: .zero)
  var quality = AdaptiveRenderQuality(), movingUntil = 0.0, previousEye = SIMD3<Float>.zero,
    previousTarget = SIMD3<Float>.zero, lastShadowWall = -Double.infinity, shadowWasMoving = false
  var lowShadowTexture: MTLTexture!
  var beads: MTLBuffer?, plate: MTLBuffer?, head: MTLBuffer?, headCount = 0, times = [Double](),
    starts = [Double]()
  var yaw: Float = 0.65, pitch: Float = 0.7, distance: Float = 400,
    target = SIMD3<Float>(128, 0, -128)
  var lastStats = ProcessInfo.processInfo.systemUptime, frames = 0, frameCount = 0,
    gpuSamples = [Double](), capturePending = false, lastGPUUI = 0.0
  init(view: MTKView, player: Player) throws {
    guard let device = view.device, let queue = device.makeCommandQueue() else {
      throw LoadError.archive("Metal is unavailable on this Mac.")
    }
    self.device = device
    self.queue = queue
    self.player = player
    let url = Bundle.module.url(
      forResource: "Preview", withExtension: "metal", subdirectory: "Shaders")!
    let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "bead")
    descriptor.fragmentFunction = library.makeFunction(name: "shaded")
    descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
    descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
    descriptor.rasterSampleCount = view.sampleCount
    descriptor.colorAttachments[0].isBlendingEnabled = false
    pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.vertexFunction = library.makeFunction(name: "ribbon")
    ribbonPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.vertexFunction = library.makeFunction(name: "bead")
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    transparentPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let depthDescriptor = MTLDepthStencilDescriptor()
    depthDescriptor.depthCompareFunction = .lessEqual
    depthDescriptor.isDepthWriteEnabled = true
    depth = device.makeDepthStencilState(descriptor: depthDescriptor)!
    depthDescriptor.isDepthWriteEnabled = false
    transparentDepth = device.makeDepthStencilState(descriptor: depthDescriptor)!
    let shadowDescriptor = MTLRenderPipelineDescriptor()
    shadowDescriptor.vertexFunction = library.makeFunction(name: "bead")
    shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
    shadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDescriptor)
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .depth32Float, width: 1024, height: 1024, mipmapped: false)
    textureDescriptor.usage = [.renderTarget, .shaderRead]
    textureDescriptor.storageMode = .private
    shadowTexture = device.makeTexture(descriptor: textureDescriptor)!
    textureDescriptor.width = 512
    textureDescriptor.height = 512
    lowShadowTexture = device.makeTexture(descriptor: textureDescriptor)!
    super.init()
    player.discoverGPU(device.name)
  }
  private func buffer(_ instances: [GPUInstance]) -> MTLBuffer? {
    guard !instances.isEmpty else { return nil }
    return instances.withUnsafeBytes {
      device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
    }
  }
  struct Prepared {
    var buffer: MTLBuffer?, starts: [Double], ends: [Double], low: SIMD3<Float>, high: SIMD3<Float>,
      workers: Int, blocks: [RenderBlock]
  }
  static func prepare(_ file: PrintFile, device: MTLDevice) -> Prepared {
    let runs = DepositCompactor.compact(file.moves)
    let indices = runs.indices
    let workers = min(16, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
    let buffer =
      indices.isEmpty
      ? nil
      : device.makeBuffer(
        length: indices.count * MemoryLayout<GPUInstance>.stride, options: .storageModeShared)
    var low = SIMD3<Float>(repeating: Float.infinity)
    var high = SIMD3<Float>(repeating: -Float.infinity)
    var starts = [Double]()
    var ends = [Double]()
    starts.reserveCapacity(indices.count)
    ends.reserveCapacity(indices.count)
    for index in indices {
      let m = runs[index]
      starts.append(m.start)
      ends.append(m.end)
      low = simd_min(low, simd_min(m.a, m.b))
      high = simd_max(high, simd_max(m.a, m.b))
    }
    if let buffer {
      let output = buffer.contents().bindMemory(to: GPUInstance.self, capacity: indices.count)
      // Disjoint ranges write directly into Apple Silicon shared GPU memory.
      // No concurrent Array mutations, per-frame copies, or main-thread waits.
      DispatchQueue.concurrentPerform(iterations: workers) { worker in
        let first = indices.count * worker / workers
        let last = indices.count * (worker + 1) / workers
        for i in first..<last {
          let m = runs[indices[i]]
          output[i] = GPUInstance(
            a: SIMD4(m.a, m.width), b: SIMD4(m.b, m.height),
            color: file.filamentColor(tool: m.tool),
            timing: SIMD4(Float(m.start), Float(m.end), 0, 0))
        }
      }
    }
    var blocks = [RenderBlock]()
    for first in stride(from: 0, to: runs.count, by: 256) {
      let end = min(first + 256, runs.count)
      var blockLow = SIMD3<Float>(repeating: .infinity)
      var blockHigh = SIMD3<Float>(repeating: -.infinity)
      for index in first..<end {
        let m = runs[index]
        let padding = SIMD3<Float>(repeating: max(m.width, m.height) * 0.8 + 0.04)
        blockLow = simd_min(blockLow, simd_min(m.a, m.b) - padding)
        blockHigh = simd_max(blockHigh, simd_max(m.a, m.b) + padding)
      }
      blocks.append(
        RenderBlock(
          first: first, count: end - first, bounds: RenderBounds(low: blockLow, high: blockHigh)))
    }
    if let first = blocks.first {
      low = first.bounds.low
      high = first.bounds.high
      for block in blocks.dropFirst() {
        low = simd_min(low, block.bounds.low)
        high = simd_max(high, block.bounds.high)
      }
    }
    return Prepared(
      buffer: buffer, starts: starts, ends: ends, low: low, high: high, workers: workers,
      blocks: blocks)
  }
  func load(_ file: PrintFile, prepared: Prepared? = nil) {
    let geometry = prepared ?? Self.prepare(file, device: device)
    beads = geometry.buffer
    blocks = geometry.blocks
    modelBounds = RenderBounds(low: geometry.low, high: geometry.high)
    times = geometry.ends
    starts = geometry.starts
    let low = geometry.low
    let high = geometry.high
    let bed = file.bed
    let width = bed.z - bed.x
    let depth = bed.w - bed.y
    let center = SIMD3((bed.x + bed.z) / 2, Float(-1), (bed.y + bed.w) / (-2))
    plate = buffer([
      GPUInstance(
        a: SIMD4(bed.x, -1, center.z, depth), b: SIMD4(bed.z, -1, center.z, 1.5),
        color: SIMD4(0.002, 0.003, 0.004, 1), timing: SIMD4(0, 0, 0, 1))
    ])
    var pieces = [GPUInstance]()
    func piece(_ y: Float, _ z: Float, _ w: Float, _ h: Float, _ d: Float, _ color: SIMD4<Float>) {
      pieces.append(
        GPUInstance(
          a: SIMD4(-w / 2, y, z, d), b: SIMD4(w / 2, y, z, h), color: color,
          timing: SIMD4(0, 0, 0, 2)))
    }
    piece(35, 0, 21, 48, 16, SIMD4(0.13, 0.16, 0.17, 0.25))
    piece(12, 0, 12, 12, 11, SIMD4(0.025, 0.03, 0.035, 0.65))
    piece(5, 0, 5, 4, 5, SIMD4(0.27, 0.17, 0.04, 0.85))
    piece(1.4, 0, 1.3, 2.8, 1.3, SIMD4(0.45, 0.3, 0.08, 1))
    head = buffer(pieces)
    headCount = pieces.count
    if low.x.isFinite {
      target = (low + high) / 2
      distance = max(100, simd_length(high - low) * 1.65)
    } else {
      target = center
      distance = max(width, depth) * 1.7
    }
    let lightCenter = SIMD3(center.x, max(0, (high.y.isFinite ? high.y : 0)) / 2, center.z)
    let lightDistance = max(width, depth) * 2
    shadowVP =
      orthographic(max(width, depth) * 0.85, 0.1, lightDistance * 3)
      * lookAt(
        lightCenter + simd_normalize(SIMD3<Float>(-0.4, 1, 0.5)) * lightDistance, lightCenter)
    lastShadowTime = -Double.infinity
    lastShadowWall = -Double.infinity
    quality = AdaptiveRenderQuality()
    yaw = 0.65
    pitch = 0.7
    frameCount = 0
    gpuSamples = []
    if CommandLine.arguments.contains("--benchmark") {
      player.seek(file.duration)
      viewReport(file, starts.count)
    }
  }
  func viewReport(_ file: PrintFile, _ count: Int) {
    print(
      "Metal GPU: \(device.name)\nMoves: \(file.moves.count), extrusion instances: \(count), GPU geometry: \(count*64) bytes, triangles: \(count*20)\nLoad: \(String(format:"%0.1f",player.loadMS)) ms"
    )
  }
  func fit() {
    yaw = 0.65
    pitch = 0.7
    if let file = player.file {
      let bed = file.bed
      distance = max(150, max(bed.z - bed.x, bed.w - bed.y) * 1.4)
    }
  }
  func top() { pitch = 1.56 }
  func pan(_ x: Float, _ y: Float) {
    target += SIMD3(-cos(yaw) * x, y, sin(yaw) * x) * (distance / 900)
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    let now = ProcessInfo.processInfo.systemUptime
    player.tick(now)
    inFlight.wait()
    guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
      let command = queue.makeCommandBuffer()
    else {
      inFlight.signal()
      return
    }
    command.addCompletedHandler { [inFlight] _ in inFlight.signal() }
    let eye = target + SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
    if simd_length_squared(eye - previousEye) > 0.0001
      || simd_length_squared(target - previousTarget) > 0.0001
    {
      movingUntil = now + 0.25
    }
    previousEye = eye
    previousTarget = target
    let moving = player.playing || now < movingUntil
    let scale = moving && !CommandLine.arguments.contains("--benchmark") ? quality.scale : 1
    let nativeScale = view.window?.backingScaleFactor ?? 2
    let desiredSize = CGSize(
      width: max(1, (view.bounds.width * nativeScale * scale).rounded()),
      height: max(1, (view.bounds.height * nativeScale * scale).rounded()))
    if view.drawableSize != desiredSize { view.drawableSize = desiredSize }
    let selectedShadow = moving ? lowShadowTexture! : shadowTexture!
    let shadowChanged = moving != shadowWasMoving
    shadowWasMoving = moving
    var headPosition = SIMD3<Float>(0, 0, 0)
    if let file = player.file {
      let move = file.moves[file.index(at: player.clock)]
      let t = Float(
        max(0, min(1, (player.clock - move.start) / max(0.000001, move.end - move.start))))
      headPosition = simd_mix(move.a, move.b, SIMD3(repeating: t))
    }
    var uniforms = Uniforms(
      vp: perspective(
        Float.pi / 4.5, Float(view.drawableSize.width / max(1, view.drawableSize.height)), 0.1, 5000
      ) * lookAt(eye, target), lightVP: shadowVP,
      head: SIMD4(headPosition, player.shadows ? (moving ? 0.5 : 1) : 0),
      eye: SIMD4(eye, 1),
      clock: SIMD4(Float(player.clock), Float(player.speed), player.melt ? 1 : 0, 0))
    var visibleCount = 0
    var hi = starts.count
    while visibleCount < hi {
      let mid = (visibleCount + hi) / 2
      if starts[mid] <= player.clock { visibleCount = mid + 1 } else { hi = mid }
    }
    let pixel = 2 * distance * tan(Float.pi / 9) / Float(max(1, view.drawableSize.height))
    let lod = pixel > 0.16
    uniforms.clock.w = lod ? 1 : 0
    let frustum = ViewFrustum(uniforms.vp)
    let ranges =
      visibleCount == 0
      ? []
      : (frustum.contains(modelBounds)
        ? [0..<visibleCount] : frustum.visibleRanges(blocks, count: visibleCount))
    if player.shadows
      && (lastShadowTime < 0 || shadowChanged
        || (player.clock != lastShadowTime && now - lastShadowWall >= (moving ? 1.0 / 30 : 0)))
    {
      let shadowPass = MTLRenderPassDescriptor()
      shadowPass.depthAttachment.texture = selectedShadow
      shadowPass.depthAttachment.loadAction = .clear
      shadowPass.depthAttachment.storeAction = .store
      shadowPass.depthAttachment.clearDepth = 1
      if let shadowEncoder = command.makeRenderCommandEncoder(descriptor: shadowPass) {
        var shadowUniforms = uniforms
        shadowUniforms.vp = shadowVP
        shadowUniforms.clock.w = 1
        shadowEncoder.setRenderPipelineState(shadowPipeline)
        shadowEncoder.setDepthStencilState(depth)
        shadowEncoder.setVertexBytes(
          &shadowUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let beads, visibleCount > 0 {
          shadowEncoder.setVertexBuffer(beads, offset: 0, index: 0)
          shadowEncoder.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: 12, instanceCount: visibleCount)
        }
        if let head, player.file != nil {
          shadowEncoder.setVertexBuffer(head, offset: 0, index: 0)
          shadowUniforms.clock.w = 0
          shadowEncoder.setVertexBytes(
            &shadowUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
          shadowEncoder.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: 60, instanceCount: headCount)
        }
        shadowEncoder.endEncoding()
        lastShadowTime = player.clock
        lastShadowWall = now
      }
    }
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      inFlight.signal()
      return
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setDepthStencilState(depth)
    encoder.setCullMode(.none)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentTexture(selectedShadow, index: 0)
    var submittedVertices = 0
    let beadVertexCount = lod ? 6 : 60
    if let plate {
      var solid = uniforms
      solid.clock.w = 0
      encoder.setVertexBytes(&solid, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setVertexBuffer(plate, offset: 0, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 60, instanceCount: 1)
      submittedVertices += 60
    }
    if let beads, visibleCount > 0 {
      encoder.setRenderPipelineState(lod ? ribbonPipeline : pipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setVertexBuffer(beads, offset: 0, index: 0)
      for range in ranges {
        encoder.drawPrimitives(
          type: .triangle, vertexStart: 0, vertexCount: beadVertexCount, instanceCount: range.count,
          baseInstance: range.lowerBound)
        submittedVertices += beadVertexCount * range.count
      }
    }
    if let head, player.file != nil {
      var solid = uniforms
      solid.clock.w = 0
      encoder.setVertexBytes(&solid, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setRenderPipelineState(transparentPipeline)
      encoder.setDepthStencilState(transparentDepth)
      encoder.setVertexBuffer(head, offset: 0, index: 0)
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0, vertexCount: 60, instanceCount: headCount)
      submittedVertices += 60 * headCount
    }
    encoder.endEncoding()
    let benchmark = CommandLine.arguments.contains("--benchmark") && player.file != nil
    frameCount += 1
    frames += 1
    if now - lastStats >= 0.5 {
      player.renderScale = scale
      player.renderedVertices = submittedVertices
      player.renderedTriangles = submittedVertices / 3
      player.fps = Double(frames) / (now - lastStats)
      frames = 0
      lastStats = now
    }
    command.addCompletedHandler { [weak self] completed in
      let elapsed = (completed.gpuEndTime - completed.gpuStartTime) * 1000
      DispatchQueue.main.async {
        guard let self else { return }
        self.quality.sample(milliseconds: elapsed, active: moving)
        if now - self.lastGPUUI > 0.25 {
          self.player.gpuMS = elapsed
          self.lastGPUUI = now
        }
        if benchmark && self.frameCount > 30 { self.gpuSamples.append(elapsed) }
        if benchmark && self.gpuSamples.count == 180 {
          let sorted = self.gpuSamples.sorted()
          print(
            String(
              format: "GPU mean %0.3f ms; p95 %0.3f ms; screen %0.1f FPS",
              sorted.reduce(0, +) / Double(sorted.count), sorted[Int(Double(sorted.count) * 0.95)],
              self.player.fps))
          fflush(stdout)
        }
      }
    }
    command.present(drawable)
    command.commit()
  }
}
private func perspective(_ fov: Float, _ aspect: Float, _ near: Float, _ far: Float)
  -> simd_float4x4
{
  let y = 1 / tan(fov / 2)
  let x = y / aspect
  let z = far / (near - far)
  return simd_float4x4(
    SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0))
}
private func lookAt(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
  let z = simd_normalize(eye - target)
  let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z))
  let y = simd_cross(z, x)
  return simd_float4x4(
    SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
    SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1))
}

private func orthographic(_ half: Float, _ near: Float, _ far: Float) -> simd_float4x4 {
  simd_float4x4(
    SIMD4(1 / half, 0, 0, 0), SIMD4(0, 1 / half, 0, 0), SIMD4(0, 0, 1 / (near - far), 0),
    SIMD4(0, 0, near / (near - far), 1))
}
