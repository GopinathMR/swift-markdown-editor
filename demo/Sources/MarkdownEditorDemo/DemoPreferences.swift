import Foundation
import MarkdownEditor

enum DemoPreferences {
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
