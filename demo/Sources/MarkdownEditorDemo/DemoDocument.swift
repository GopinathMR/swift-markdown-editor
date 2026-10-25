import AppKit
import Observation

/// Which file the demo shows. The editor reads, watches and saves it (file mode).
@MainActor @Observable
final class DemoDocument {
  var url: URL

  init(url: URL) { self.url = url }

  /// `-file <path>` opens that file; otherwise the built-in tour, written to Caches.
  static func fromLaunchArguments() -> DemoDocument {
    if let path = UserDefaults.standard.string(forKey: "file") {
      return DemoDocument(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
    return DemoDocument(
      url: DemoSample.install() ?? URL(fileURLWithPath: NSTemporaryDirectory() + "tour.md"))
  }

  func openPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "md")!, .plainText]
    guard panel.runModal() == .OK, let u = panel.url else { return }
    url = u
  }
}
