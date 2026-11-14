import AppKit
import SwiftUI

@main
struct NullGCodePlayer: App {
  @StateObject var player = Player()
  var body: some Scene {
    WindowGroup("NULL — G-Code Player / Metal") {
      ContentView(player: player).onAppear {
        if let arg = CommandLine.arguments.dropFirst().first {
          player.load(URL(fileURLWithPath: arg))
        }
      }.onOpenURL { player.load($0) }
    }.commands {
      CommandGroup(replacing: .newItem) {
        Button("Open…", action: player.open).keyboardShortcut("o")
      }
    }
  }
}
