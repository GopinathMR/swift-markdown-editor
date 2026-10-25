import AppKit

/// Dispatches a render request to the renderer for its kind.
@MainActor
enum Renderers {
  static func render(_ req: RenderRequest, darkMode: Bool) async -> RenderResult {
    RenderResult(image: nil, size: .zero, error: "Rendering not available yet")
  }
}
