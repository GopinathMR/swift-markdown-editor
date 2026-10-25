# swift-markdown-editor Memory

Repo-specific facts. One per line, terse.

## Build, test, demo
- `make format-check build test demo-test`. Stock `swift format` (2-space), so there is no `.swift-format` file. `make build/test` filter the linker's
  "unable to open object file" lines: CodeEditLanguages' prebuilt xcframework ships without object files. That's noise, not an error.
- Perf budgets only assert in release: `swift test -c release -Xswiftc -enable-testing --filter largeDocument`
  (1.9 MB fixture: open ~0.93 s, keystroke p95 ~8.5 ms). Debug builds are ~4x slower; don't judge them.
- Adding a NEW source file to the library leaves `demo/.build` stale. The demo build then says "cannot find X in scope".
  Touching `Package.swift` doesn't help; `rm -rf demo/.build` (≈25 s rebuild) does.
- Demo launch args (`UserDefaults` argument domain): `-file <path>`, `-heading <slug>` (scroll to it), `-caret <n>`,
  `-find <text>`, `-focus YES`, `-light YES`, `-theme <file.toml>`, `-lineNumbers YES`, `-outline NO`. With no `-file`, the
  tour plus a generated `assets/hero.png` are written to `~/Library/Caches/MarkdownEditorDemo/` so that relative images resolve.
- Screenshots: launch the demo binary, get its window id via `CGWindowListCopyWindowInfo`, then `screencapture -l`.

## Architecture invariants
- The text storage IS the markdown. Rendering is attributes only: `Styler.hide` uses a 0.01 pt clear font with `.mdHidden`, plus
  `.kern` and paragraph spacing to reserve space. `MarkdownLayoutFragment` draws `mdInline`/`mdBlock` decorations.
  Styling never goes through undo. Never touch `textView.layoutManager`, because it flips the view to TextKit 1 (a test asserts this).
- Blocks are context-free values with ranges relative to their entry start. The parse cache is keyed on
  `nodeType + "\0" + text`: the same text can parse as a different node type in another context (`# x` as an ATX heading or
  as a paragraph).
- Edits reparse a WINDOW of top-level entries plus one untouched probe each side, widening until both probes match.
  tree-sitter-markdown's own incremental reparse re-lexes the whole document once lists, code or math exist (~250 ms on 1.9 MB).
  `incrementalMatchesFullParse` (600 random edits) is the guard: run it many times after touching the parser.
- A full parse fans `BlockBuilder` out over `concurrentPerform`, one builder (and inline parser) per worker.
  The `NSString` is only safe to share because `load()` blocks the main thread meanwhile.
- Overlays (table grids, AVPlayerView, iframe WKWebView) are text-view subviews, built only for blocks near the viewport.
  Their frames come from `textLayoutFragment(for:)` without layout from the document start, and they are re-placed on
  `layout()`, scroll and restyle.
- Finished renders restyle ONLY the entries recorded in `Styler.waiting` (debounced diagram previews included).
  Restyling everything per render janked math-heavy files.
- Anything that collects overlay or label positions must derive them from the model at query time. The styler often
  restyles only some entries, so per-pass records go stale.
- Async renders resize blocks: wrap such restyles in `keepingViewport { }`, or a heading jump lands in the wrong place.
- `NSAttributedString(html:)` (block HTML, RTF copy) runs on the main thread only, and only on sanitised HTML (remote `<img>` is
  stripped, since it would load synchronously).

## Library quirks
- CodeEditLanguages' own query loader builds `<resourceURL>/Resources/tree-sitter-x/…`. In a SwiftPM bundle `resourceURL`
  already ends in `Resources` (NSBundle picks the folder), so it finds nothing. `CodeHighlighter` loads the queries itself.
- CodeEditLanguages already contains the markdown and markdown-inline grammars; adding tree-sitter-markdown separately
  would duplicate symbols.
- tree-sitter-markdown misses a thematic break on the last line without a trailing newline (`***`). `classifyParagraph`
  fixes it up.
- SwiftMath: `MTTypesetter.createLineForMathList` and `displayList.position` are internal. Typeset with an `MTMathUILabel`,
  draw it with `cacheDisplay` into a 2x rep, and take the baseline from `displayList.descent`.
- js-sequence-diagrams needs a global `WebFont` even for the "simple" theme. A local shim in `render.html` covers it.
- `NSAccessibilityCustomRotor.SearchParameters()` defaults to `.previous`, not `.next`.
- `UserDefaults` argument-domain values are strings: `object(forKey:) as? Int/Bool` fails. Use `integer(forKey:)`/`bool(forKey:)`.
