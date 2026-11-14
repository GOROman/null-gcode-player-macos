import Foundation
import GCodeCore

let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
  fputs("Usage: gcode-benchmark FILE.gcode|FILE.3mf\n", stderr)
  exit(1)
}
do {
  let start = ProcessInfo.processInfo.systemUptime
  let file = try PrintLoader.load(URL(fileURLWithPath: path))
  let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
  print(
    "\(file.name)\n\(file.moves.count) moves · \(file.layerCount) layers · \(file.toolChanges) tool changes\nMotion time: \(file.duration) s\nParse + archive: \(String(format:"%0.2f",elapsed)) ms"
  )
} catch {
  fputs("\(error.localizedDescription)\n", stderr)
  exit(1)
}
