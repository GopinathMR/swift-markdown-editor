import AppKit
import Observation

/// The file the demo edits. The editor never touches disk; this does.
@MainActor @Observable
final class DemoDocument {
  var text: String
  var url: URL?
  var savedText: String

  init(text: String, url: URL?) {
    self.text = text
    self.url = url
    self.savedText = text
  }

  var isDirty: Bool { text != savedText }

  /// `-file <path>` opens that file; otherwise a built-in sample.
  static func fromLaunchArguments() -> DemoDocument {
    if let path = UserDefaults.standard.string(forKey: "file") {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      return DemoDocument(text: text, url: url)
    }
    return DemoDocument(text: DemoSample.text, url: nil)
  }

  func save() {
    guard let url else { return saveAs() }
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
      savedText = text
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  func saveAs() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.init(filenameExtension: "md")!]
    panel.nameFieldStringValue = "Untitled.md"
    guard panel.runModal() == .OK, let u = panel.url else { return }
    url = u
    save()
  }

  func openPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "md")!, .plainText]
    guard panel.runModal() == .OK, let u = panel.url,
      let s = try? String(contentsOf: u, encoding: .utf8)
    else { return }
    url = u
    text = s
    savedText = s
  }
}
