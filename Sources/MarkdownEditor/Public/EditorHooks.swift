import AppKit

/// Callbacks into the host. Everything that touches the host's files or network goes here.
public struct EditorHooks {
  /// ⌘-click on a link the editor doesn't handle itself (other files; web links if set).
  public var openLink: @MainActor (LinkTarget) -> Void = { target in
    if case .web(let url) = target { NSWorkspace.shared.open(url) }
  }
  /// Where to save a pasted/dropped image when no copy-to-folder rule applies. `nil` refuses.
  public var imageStore: @MainActor (PastedImage) async -> URL? = { _ in nil }
  /// Upload local images; returns their remote URLs in order. `nil` hides Upload commands.
  public var uploadImages: (@MainActor ([URL]) async throws -> [URL])?
  public var onError: @MainActor (EditorError) -> Void = { _ in }
  /// File mode: decide what happens when another app changes the file while the buffer has
  /// unsaved edits. `nil` shows the built-in Reload / Keep My Changes sheet.
  public var resolveExternalChange: (@MainActor (ExternalChange) async -> ExternalChangeChoice)?

  public init() {}
}

public struct ExternalChange: Sendable, Equatable {
  public let url: URL
  public let diskText: String
}

public enum ExternalChangeChoice: Sendable, Equatable { case reload, keepMine }

public enum LinkTarget: Sendable, Equatable {
  case web(URL)
  case file(URL, heading: String?, exists: Bool)
}

public struct PastedImage: Sendable {
  public var data: Data
  /// Suggested file extension (`png`, `jpg`, …).
  public var fileExtension: String
}

public enum EditorError: Error, Sendable, Equatable {
  case imageRefused(String)
  case imageOperation(String)
  case themeFile(String)
  case fileUnreadable(URL)
  case fileDeleted(URL)
  case fileWrite(String)
}
