import Foundation

/// Typora's Markdown and Editor preferences. Defaults match Typora's.
public struct EditorPreferences: Sendable, Equatable {
  public enum MathNumbering: Sendable, Equatable { case off, ams, all }

  public enum ImageInsertRule: Sendable, Equatable {
    case none
    /// Folder path, absolute or relative to the document (`./assets`, `${filename}.assets`).
    case copy(toFolder: String)
    case upload
  }

  public var strictMode = false
  public var inlineMath = false
  public var highlight = false
  public var superscript = false
  public var `subscript` = false
  public var diagrams = true
  public var mathNumbering: MathNumbering = .off
  public var physicsPackage = false
  public var codeLineNumbers = false
  public var tabSize = 4
  public var autoPairBrackets = true
  public var autoPairMarkdown = false
  public var smartPunctuation = false
  public var imageInsert: ImageInsertRule = .none
  public var preferRelativePaths = true
  public var ensureDotSlash = false
  public var escapeImageURL = true
  public var typewriterCentersOnClick = true
  public var readingSpeedWPM = 382
  public var frontMatterOverridesExport = false

  public init() {}
}
