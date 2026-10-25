import Foundation

enum MathPreprocessor {
  /// The explicit `\tag{…}` of an equation, if any.
  static func tag(in latex: String) -> String? {
    latex.firstMatch(of: #/\\tag\{([^}]*)\}/#).map { String($0.1) }
  }
}
