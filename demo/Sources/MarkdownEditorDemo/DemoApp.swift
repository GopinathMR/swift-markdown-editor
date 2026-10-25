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
      CommandGroup(after: .saveItem) { ExportMenu() }
    }
  }
}

/// File ▸ Export, driven through the focused editor's controller.
struct ExportMenu: View {
  @FocusedValue(\.markdownEditorController) private var controller

  var body: some View {
    Menu("Export") {
      ForEach(controller?.availableExportFormats ?? [], id: \.self) { format in
        Button(title(format)) { export(format) }
      }
    }
    .disabled(controller == nil)
  }

  private func title(_ f: ExportFormat) -> String {
    switch f {
    case .html(let styled): return styled ? "HTML" : "HTML (without styles)"
    case .pdf: return "PDF"
    case .png: return "Image"
    case .pandoc(let p): return "\(p.rawValue) (pandoc)"
    }
  }

  private func export(_ f: ExportFormat) {
    guard let controller else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Export.\(f.fileExtension)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do { try await controller.export(f, to: url) } catch { NSAlert(error: error).runModal() }
    }
  }
}
