import Foundation
import MarkdownEditor

enum DemoPreferences {
  /// `-theme <file.toml>` loads a theme file; errors print and fall back to the default.
  static func launchTheme() -> EditorTheme {
    guard let path = UserDefaults.standard.string(forKey: "theme") else { return .default }
    do {
      return try EditorTheme.load(
        toml: String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8))
    } catch {
      print("Theme error: \(error)")
      return .default
    }
  }

  /// Everything optional on, so the demo shows every feature.
  static func launchPreferences() -> EditorPreferences {
    var p = EditorPreferences()
    p.inlineMath = true
    p.highlight = true
    p.superscript = true
    p.subscript = true
    p.mathNumbering = .ams
    p.codeLineNumbers = UserDefaults.standard.bool(forKey: "lineNumbers")
    p.autoPairMarkdown = true
    p.smartPunctuation = true
    p.imageInsert = .copy(toFolder: "./assets")
    return p
  }
}
