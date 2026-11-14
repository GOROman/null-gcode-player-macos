import GCodeCore
import MetalKit
import simd

struct GPUInstance { var a, b, color, timing: SIMD4<Float> }
private struct Uniforms {
  var vp, lightVP: simd_float4x4
  var head, eye, clock, filament, flow, beadShape: SIMD4<Float>
}
final class Renderer: NSObject, MTKViewDelegate {
  let player: Player, device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState,
    transparentPipeline: MTLRenderPipelineState, ribbonPipeline: MTLRenderPipelineState,
    headPipeline: MTLRenderPipelineState, transparentHeadPipeline: MTLRenderPipelineState,
    moltenPipeline: MTLRenderPipelineState,
    depth: MTLDepthStencilState,
    transparentDepth: MTLDepthStencilState
  var balancedIndices: MTLBuffer!
  var lodPlanner = LODPlanner(), cachedPlan = [LODDrawRange](), cachedLODHeight: Float = -1,
    cachedLODMode = -1, cachedForcedIndex = -1
  var beadIndices: MTLBuffer!, ribbonIndices: MTLBuffer!, shadowIndices: MTLBuffer!,
    meniscusIndices: MTLBuffer!
  var cachedCullVP = matrix_identity_float4x4, cachedCullCount = -1
  let inFlight = DispatchSemaphore(value: 3)
  var shadowPipeline: MTLRenderPipelineState!, shadowTexture: MTLTexture!,
    shadowVP = matrix_identity_float4x4, lastShadowTime = -Double.infinity
  var blocks = [RenderBlock](), modelBounds = RenderBounds(low: .zero, high: .zero)
  var quality = AdaptiveRenderQuality(), movingUntil = 0.0, previousEye = SIMD3<Float>.zero,
    previousTarget = SIMD3<Float>.zero, lastShadowWall = -Double.infinity, shadowWasMoving = false
  var lowShadowTexture: MTLTexture!
  var headShadowPipeline: MTLRenderPipelineState!
  var opaqueHead: MTLBuffer?, transparentHead: MTLBuffer?, opaqueHeadCount = 0,
    transparentHeadCount = 0
  var beads: MTLBuffer?, plate: MTLBuffer?, times = [Double](),
    starts = [Double]()
  var clearanceMesh: MTLBuffer?
  var clearanceVertexCount = 0
  var followNozzle = false
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
    descriptor.vertexFunction = library.makeFunction(name: "toolhead")
    transparentHeadPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.colorAttachments[0].isBlendingEnabled = false
    headPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.vertexFunction = library.makeFunction(name: "moltenJoin")
    moltenPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
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
    shadowDescriptor.vertexFunction = library.makeFunction(name: "toolhead")
    headShadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDescriptor)
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
    textureDescriptor.usage = [.renderTarget, .shaderRead]
    textureDescriptor.storageMode = .private
    shadowTexture = device.makeTexture(descriptor: textureDescriptor)!
    textureDescriptor.width = 1024
    textureDescriptor.height = 1024
    lowShadowTexture = device.makeTexture(descriptor: textureDescriptor)!
    super.init()
    player.discoverGPU(device.name)
    func indices(_ values: [UInt16]) -> MTLBuffer {
      values.withUnsafeBytes {
        device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
      }
    }
    balancedIndices = indices(MeshTopology.balanced)
    beadIndices = indices(MeshTopology.bead)
    ribbonIndices = indices(MeshTopology.ribbon)
    shadowIndices = indices(MeshTopology.crossedRibbon)
    meniscusIndices = indices(MeshTopology.meniscus)
    let wire = HeadEnvelope.wireVertices()
    clearanceVertexCount = wire.count
    clearanceMesh = wire.withUnsafeBytes {
      device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
    }
    let mesh = H3CHeadMesh()
    opaqueHeadCount = mesh.opaque.count
    transparentHeadCount = mesh.transparent.count
    opaqueHead = mesh.opaque.withUnsafeBytes {
      device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
    }
    transparentHead = mesh.transparent.withUnsafeBytes {
      device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
    }
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
      var width: Float = 0.01
      var blockLow = SIMD3<Float>(repeating: .infinity)
      var blockHigh = SIMD3<Float>(repeating: -.infinity)
      for index in first..<end {
        let m = runs[index]
        width = max(width, max(m.width, m.height))
        let padding = SIMD3<Float>(repeating: max(m.width, m.height) * 0.8 + 0.04)
        blockLow = simd_min(blockLow, simd_min(m.a, m.b) - padding)
        blockHigh = simd_max(blockHigh, simd_max(m.a, m.b) + padding)
      }
      blocks.append(
        RenderBlock(
          first: first, count: end - first, bounds: RenderBounds(low: blockLow, high: blockHigh),
          beadWidth: width))
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
    followNozzle = false
    cachedCullCount = -1
    lodPlanner = LODPlanner()
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
    if low.x.isFinite {
      target = (low + high) / 2
      distance = max(100, simd_length(high - low) * 1.65)
    } else {
      target = center
      distance = max(width, depth) * 1.7
    }
    // Fit all receiver/caster bounds tightly in light space. The nozzle outlet
    // and frame remain included even at the highest printed layer.
    let sceneLow = simd_min(low, SIMD3(bed.x, -2, -bed.w)) - SIMD3<Float>(34, 0, 34)
    let sceneHigh = simd_max(high, SIMD3(bed.z, 0, -bed.y)) + SIMD3<Float>(34, 90, 34)
    let lightCenter = (sceneLow + sceneHigh) / 2
    let lightDistance = max(width, depth) * 3 + sceneHigh.y
    let lightView = lookAt(
      lightCenter + simd_normalize(SIMD3<Float>(-0.4, 1, 0.5)) * lightDistance, lightCenter)
    var lightLow = SIMD3<Float>(repeating: .infinity)
    var lightHigh = SIMD3<Float>(repeating: -.infinity)
    for x in [sceneLow.x, sceneHigh.x] {
      for y in [sceneLow.y, sceneHigh.y] {
        for z in [sceneLow.z, sceneHigh.z] {
          let p = lightView * SIMD4(x, y, z, 1)
          let v = SIMD3(p.x, p.y, p.z)
          lightLow = simd_min(lightLow, v)
          lightHigh = simd_max(lightHigh, v)
        }
      }
    }
    shadowVP = shadowOrthographic(lightLow, lightHigh) * lightView
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
    if CommandLine.arguments.contains("--front-preview") {
      player.seek(file.duration)
      yaw = 0
      pitch = 0.08
    }
    if CommandLine.arguments.contains("--head-preview"),
      let move = file.moves.first(where: { $0.deposit })
    {
      player.seek(move.start)
      target = move.a + SIMD3<Float>(0, 39, 0)
      distance = 150
      yaw = 0.5
      pitch = 0.16
    }
    if CommandLine.arguments.contains("--melt-preview"),
      let move = file.moves.first(where: { $0.deposit })
    {
      player.seek(move.start + (move.end - move.start) * 0.6)
      inspectNozzle()
    }
  }
  func viewReport(_ file: PrintFile, _ count: Int) {
    print(
      "Metal GPU: \(device.name)\nMoves: \(file.moves.count), extrusion instances: \(count), GPU geometry: \(count*64) bytes, full-detail triangles: \(count*32)\nLoad: \(String(format:"%0.1f",player.loadMS)) ms"
    )
  }
  func fit() {
    followNozzle = false
    yaw = 0.65
    pitch = 0.7
    if let file = player.file {
      let bed = file.bed
      distance = max(150, max(bed.z - bed.x, bed.w - bed.y) * 1.4)
    }
  }
  func setShadowResolution(_ size: Int) {
    let size = [1024, 2048, 4096].contains(size) ? size : 2048
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    shadowTexture = device.makeTexture(descriptor: descriptor)
    descriptor.width = size / 2
    descriptor.height = size / 2
    lowShadowTexture = device.makeTexture(descriptor: descriptor)
    lastShadowTime = -.infinity
  }
  func inspectNozzle() {
    followNozzle = true
    distance = 8
    yaw = 0.55
    pitch = 0.38
  }
  func top() {
    followNozzle = false
    pitch = 1.56
  }
  func pan(_ x: Float, _ y: Float) {
    followNozzle = false
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
    var headPosition = SIMD3<Float>(0, 0, 0)
    var filamentColor = SIMD4<Float>(0.38, 0.87, 0.76, 1)
    var flow = SIMD4<Float>.zero
    var beadShape = SIMD4<Float>(0.42, 0.2, 0, 0)
    if let file = player.file {
      let move = file.moves[file.index(at: player.clock)]
      let t = Float(
        max(0, min(1, (player.clock - move.start) / max(0.000001, move.end - move.start))))
      headPosition = simd_mix(move.a, move.b, SIMD3(repeating: t))
      filamentColor = file.filamentColor(tool: move.tool)
      if player.melt && move.deposit && player.clock < file.duration {
        let direction = move.b - move.a
        let length = simd_length(direction)
        if length > 0.00001 {
          let emitted = length * t
          let fade = min(1, emitted / max(0.01, move.width * 0.3))
          flow = SIMD4(direction / length, fade)
          beadShape = SIMD4(move.width, move.height, 0, 0)
        }
      }
    }
    if followNozzle {
      target =
        headPosition - SIMD3(flow.x, flow.y, flow.z) * beadShape.x * 0.3 + SIMD3<Float>(0, -0.05, 0)
    }
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
    var uniforms = Uniforms(
      vp: perspective(
        Float.pi / 4.5, Float(view.drawableSize.width / max(1, view.drawableSize.height)), 0.1, 5000
      ) * lookAt(eye, target), lightVP: shadowVP,
      head: SIMD4(headPosition, player.shadows ? (moving ? 0.5 : 1) : 0),
      eye: SIMD4(eye, 1),
      clock: SIMD4(Float(player.clock), Float(player.speed), player.melt ? 1 : 0, 0),
      filament: filamentColor, flow: flow, beadShape: beadShape)
    var visibleCount = 0
    var hi = starts.count
    while visibleCount < hi {
      let mid = (visibleCount + hi) / 2
      if starts[mid] <= player.clock { visibleCount = mid + 1 } else { hi = mid }
    }
    let pixel = 2 * distance * tan(Float.pi / 9) / Float(max(1, view.drawableSize.height))
    let lod = pixel > 0.16
    uniforms.clock.w = lod ? 1 : 0
    let sameCamera =
      uniforms.vp.columns.0 == cachedCullVP.columns.0
      && uniforms.vp.columns.1 == cachedCullVP.columns.1
      && uniforms.vp.columns.2 == cachedCullVP.columns.2
      && uniforms.vp.columns.3 == cachedCullVP.columns.3
    let forcedIndex = player.melt && flow.w > 0 ? visibleCount - 1 : -1
    let renderHeight = Float(view.drawableSize.height)
    if cachedCullCount != visibleCount || !sameCamera || cachedLODHeight != renderHeight
      || cachedLODMode != player.lodMode || cachedForcedIndex != forcedIndex
    {
      let frustum = ViewFrustum(uniforms.vp)
      cachedPlan = lodPlanner.plan(
        blocks: blocks, count: visibleCount, eye: eye, height: renderHeight, fov: Float.pi / 4.5,
        frustum: frustum.contains(modelBounds) ? nil : frustum,
        forceDetailedIndex: forcedIndex >= 0 ? forcedIndex : nil,
        override: player.lodMode > 0 ? GeometryLOD(rawValue: player.lodMode - 1) : nil)
      cachedCullCount = visibleCount
      cachedCullVP = uniforms.vp
      cachedLODHeight = renderHeight
      cachedLODMode = player.lodMode
      cachedForcedIndex = forcedIndex
    }
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
        shadowUniforms.clock.w = moving || lod ? 1 : 0
        shadowEncoder.setRenderPipelineState(shadowPipeline)
        shadowEncoder.setDepthStencilState(depth)
        shadowEncoder.setVertexBytes(
          &shadowUniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if let beads, visibleCount > 0 {
          shadowEncoder.setVertexBuffer(beads, offset: 0, index: 0)
          let simple = moving || lod
          shadowEncoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: simple ? MeshTopology.crossedRibbon.count : MeshTopology.bead.count,
            indexType: .uint16, indexBuffer: simple ? shadowIndices : beadIndices,
            indexBufferOffset: 0, instanceCount: visibleCount)
        }
        if player.file != nil {
          shadowEncoder.setRenderPipelineState(headShadowPipeline)
          if let opaqueHead {
            shadowEncoder.setVertexBuffer(opaqueHead, offset: 0, index: 0)
            shadowEncoder.drawPrimitives(
              type: .triangle, vertexStart: 0, vertexCount: opaqueHeadCount)
          }
          if let transparentHead {
            shadowEncoder.setVertexBuffer(transparentHead, offset: 0, index: 0)
            shadowEncoder.drawPrimitives(
              type: .triangle, vertexStart: 0, vertexCount: transparentHeadCount)
          }
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
    uniforms.clock.w = 0
    encoder.setRenderPipelineState(pipeline)
    encoder.setDepthStencilState(depth)
    encoder.setCullMode(.none)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encoder.setFragmentTexture(selectedShadow, index: 0)
    var submittedVertices = 0
    var submittedTriangles = 0
    if let plate {
      var solid = uniforms
      solid.clock.w = 0
      encoder.setVertexBytes(&solid, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setVertexBuffer(plate, offset: 0, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 60, instanceCount: 1)
      submittedVertices += 60
      submittedTriangles += 20
    }
    if let beads, visibleCount > 0 {
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setVertexBuffer(beads, offset: 0, index: 0)
      for plan in cachedPlan {
        let count: Int
        let vertices: Int
        let indices: MTLBuffer
        switch plan.detail {
        case .detailed:
          count = MeshTopology.bead.count
          vertices = MeshTopology.beadVertices
          indices = beadIndices
        case .balanced:
          count = MeshTopology.balanced.count
          vertices = MeshTopology.balancedVertices
          indices = balancedIndices
        case .distant:
          count = MeshTopology.ribbon.count
          vertices = MeshTopology.ribbonVertices
          indices = ribbonIndices
        }
        encoder.setRenderPipelineState(plan.detail == .distant ? ribbonPipeline : pipeline)
        encoder.drawIndexedPrimitives(
          type: .triangle, indexCount: count, indexType: .uint16, indexBuffer: indices,
          indexBufferOffset: 0, instanceCount: plan.range.count, baseVertex: 0,
          baseInstance: plan.range.lowerBound)
        submittedVertices += vertices * plan.range.count
        submittedTriangles += count / 3 * plan.range.count
      }
    }
    if player.melt && flow.w > 0 && pixel < 0.2 {
      encoder.setRenderPipelineState(moltenPipeline)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.drawIndexedPrimitives(
        type: .triangle, indexCount: MeshTopology.meniscus.count, indexType: .uint16,
        indexBuffer: meniscusIndices, indexBufferOffset: 0)
      submittedVertices += MeshTopology.meniscusVertices
      submittedTriangles += MeshTopology.meniscus.count / 3
    }
    if player.file != nil {
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      if let opaqueHead {
        encoder.setRenderPipelineState(headPipeline)
        encoder.setVertexBuffer(opaqueHead, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: opaqueHeadCount)
        submittedVertices += opaqueHeadCount
        submittedTriangles += opaqueHeadCount / 3
      }
      if let transparentHead {
        encoder.setRenderPipelineState(transparentHeadPipeline)
        encoder.setDepthStencilState(transparentDepth)
        encoder.setVertexBuffer(transparentHead, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: transparentHeadCount)
        submittedVertices += transparentHeadCount
        submittedTriangles += transparentHeadCount / 3
      }
    }
    if player.showClearance, player.file != nil, let clearanceMesh {
      encoder.setRenderPipelineState(headPipeline)
      encoder.setDepthStencilState(transparentDepth)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
      encoder.setVertexBuffer(clearanceMesh, offset: 0, index: 0)
      encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: clearanceVertexCount)
      submittedVertices += clearanceVertexCount
    }
    encoder.endEncoding()
    let benchmark = CommandLine.arguments.contains("--benchmark") && player.file != nil
    frameCount += 1
    frames += 1
    if now - lastStats >= 0.5 {
      player.renderScale = scale
      player.renderedVertices = submittedVertices
      player.renderedTriangles = submittedTriangles
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

private func shadowOrthographic(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> simd_float4x4 {
  let near = -high.z
  let far = -low.z
  let w = max(1, high.x - low.x)
  let h = max(1, high.y - low.y)
  return simd_float4x4(
    SIMD4(2 / w, 0, 0, 0), SIMD4(0, 2 / h, 0, 0), SIMD4(0, 0, 1 / (near - far), 0),
    SIMD4(-(high.x + low.x) / w, -(high.y + low.y) / h, near / (near - far), 1))
}
