import Foundation

public enum PandocFormat: String, CaseIterable, Sendable {
  case docx, odt, rtf, epub, latex, mediawiki, rst, textile, opml, markdown
}

public enum ExportFormat: Hashable, Sendable {
  case html(styled: Bool)
  case pdf, png
  case pandoc(PandocFormat)
}

public struct ExportOptions: Sendable, Equatable {
  public init() {}
}

public enum ExportError: Error, Sendable {
  case pandocMissing
  case pandoc(status: Int32, stderr: String)
  case write(String)
  case render(String)
}

@MainActor
struct Exporter {
  let coordinator: EditorCoordinator
  static var availableFormats: [ExportFormat] {
    [.html(styled: true), .html(styled: false), .pdf, .png]
  }
  func export(_ format: ExportFormat, to url: URL, options: ExportOptions) async throws {}
}
