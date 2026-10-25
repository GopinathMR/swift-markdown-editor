import AppKit

enum TOCRenderer {
  @MainActor static func image(_ headings: [HeadingInfo], theme: ResolvedTheme, width: CGFloat) -> (
    image: NSImage?, size: CGSize, rows: [(CGRect, String)]
  ) {
    (nil, .zero, [])
  }
}
