# swift-markdown-editor

A native macOS markdown editor component in the style of Typora. It is a single pane: markdown renders
inline as you type, and when the caret enters a rendered element its markdown source shows again for editing.
It is built on TextKit 2, with no web view involved in editing.

The text the host binds is the markdown itself. The editor never reformats it: open a file, close it without
typing, and you get back the same bytes.

## Embedding

```swift
import MarkdownEditor
import SwiftUI

struct NoteView: View {
  @State private var text = "# Hello\n\nWrite **markdown** here."
  @State private var controller = MarkdownEditorController()

  var body: some View {
    MarkdownEditor(text: $text, documentURL: fileURL, controller: controller)
      .focusedSceneValue(\.markdownEditorController, controller)
  }
}

// In your App: add Typora's Paragraph / Format / View menus and shortcuts.
WindowGroup { NoteView() }.commands { MarkdownEditorCommands() }
```

`MarkdownEditorController` lets the host:
- switch modes (`mode`, `isFocusMode`, `isTypewriterMode`, `zoom`),
- read `outline`, `currentHeading`, `stats` and `selectedRange`,
- run any `EditorCommand`,
- show find, and
- `export(_:to:)`.

`EditorHooks` is where the host decides how links open, where pasted images are stored, and how uploads
happen. `EditorPreferences` mirrors Typora's Markdown and Editor preferences, with the same defaults.

## Demo

```sh
make demo                     # built-in feature tour
make demo FILE=README.md      # edit a file; ⌘S saves
```

## Development

```sh
make format-check build test demo-test
```

The package targets macOS 14+ and Swift 6. It depends on:

| Package | Used for |
|---------|----------|
| [CodeEditLanguages](https://github.com/CodeEditApp/CodeEditLanguages) | markdown, markdown-inline and about 40 code grammars (tree-sitter) |
| [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) | incremental parsing |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | native LaTeX typesetting |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | HTML sanitising and HTML → markdown paste |
| [Yams](https://github.com/jpsim/Yams) | YAML front matter |
| [TOMLKit](https://github.com/LebJe/TOMLKit) | theme files |

## How it works

The text storage holds the raw markdown. Everything you see rendered is presentation on top of it:
- Syntax markers get a near-zero font in a clear colour, and reappear while the caret is inside their element.
- Bullets, checkboxes, emoji and inline math are drawn over hidden source by a custom `NSTextLayoutFragment`.
- Blocks (math, diagrams, images, tables) reserve space with paragraph spacing and are drawn into it.

Because the stored text is the markdown, undo, find, spell check and source mode all work on that same text.

## License

Apache 2.0. Bundled data: gemoji (MIT), in `Sources/MarkdownEditor/Resources/gemoji`.
