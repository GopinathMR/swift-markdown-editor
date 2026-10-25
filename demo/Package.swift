// swift-tools-version: 6.0
import PackageDescription

// A separate package so the library's consumers never resolve a demo product.
let package = Package(
  name: "MarkdownEditorDemo",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "..")],
  targets: [
    .executableTarget(
      name: "MarkdownEditorDemo",
      dependencies: [.product(name: "MarkdownEditor", package: "swift-markdown-editor")]),
    .testTarget(name: "MarkdownEditorDemoTests", dependencies: ["MarkdownEditorDemo"]),
  ]
)
