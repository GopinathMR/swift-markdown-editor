// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MarkdownEditor",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "MarkdownEditor", targets: ["MarkdownEditor"])
  ],
  dependencies: [
    // Markdown, markdown-inline, YAML, HTML and ~40 code grammars in one xcframework.
    .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", from: "0.1.20"),
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
    .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.0"),
    .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.7.0"),
    .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
    .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
  ],
  targets: [
    .target(
      name: "MarkdownEditor",
      dependencies: [
        "CodeEditLanguages", "SwiftTreeSitter", "SwiftMath", "SwiftSoup", "Yams", "TOMLKit",
      ],
      resources: [.copy("Resources")]),
    .testTarget(name: "MarkdownEditorTests", dependencies: ["MarkdownEditor"]),
  ]
)
