// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "NullGCodePlayer", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "NullGCodePlayer", targets: ["GCodePlayer"]),
    .executable(name: "gcode-benchmark", targets: ["GCodeBenchmark"]),
  ],
  targets: [
    .target(name: "GCodeCore"),
    .executableTarget(
      name: "GCodePlayer", dependencies: ["GCodeCore"], resources: [.copy("Shaders")]),
    .executableTarget(name: "GCodeBenchmark", dependencies: ["GCodeCore"]),
    .executableTarget(
      name: "GCodeChecks", dependencies: ["GCodeCore"], path: "Tests/GCodeCoreTests"),
  ])
