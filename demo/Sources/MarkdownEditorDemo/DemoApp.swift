import AppKit
import MarkdownEditor
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // `swift run` launches without a Dock icon or focus otherwise.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DemoApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @State private var document = DemoDocument.fromLaunchArguments()

  var body: some Scene {
    WindowGroup("Markdown Editor") {
      ContentView(document: document)
        .frame(minWidth: 700, minHeight: 500)
    }
    .defaultSize(width: 1100, height: 800)
    .commands {
      MarkdownEditorCommands()
      CommandGroup(replacing: .saveItem) {
        Button("Save") { document.save() }.keyboardShortcut("s")
      }
      CommandGroup(after: .newItem) {
        Button("Open…") { document.openPanel() }.keyboardShortcut("o")
      }
    }
  }
}
