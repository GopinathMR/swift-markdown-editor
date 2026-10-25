enum DemoSample {
  static let text = #"""
    ---
    title: Feature tour
    author: swift-markdown-editor
    ---

    # Feature tour

    [toc]

    ## Writing

    Markdown renders **as you type**. Move the caret into *any* element and its source reappears: try `inline code`, ~~strikethrough~~, ==highlight==, H~2~O, x^2^, <u>underline</u>, <kbd>⌘</kbd> + <kbd>B</kbd>, <span style="color:#d14">coloured text</span>, &copy; entities and emoji :tada: :rocket:.

    Links: [inline](https://example.com), [reference][docs], <https://autolink.dev> and bare www.typora.io. A footnote[^1] too.

    [docs]: https://github.com

    > A blockquote stays quiet,
    > > and nests.

    > [!TIP]
    > Callouts use GitHub's alert syntax.

    ## Lists

    - [x] Inline rendering
    - [ ] Click a box to toggle it
    - Bullets
      - nest
        - deeper
    1. Ordered
    2. Lists
       1. renumber for display

    ## Code

    ```swift
    struct Greeter {
      let name: String
      func greet() -> String { "Hello, \(name)!" }
    }
    ```

    ## Math

    Inline math like $e^{i\pi} + 1 = 0$ sits in the text.

    $$
    \int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
    $$

    ## Tables

    | Feature | Status | Notes |
    |:--------|:------:|------:|
    | Tables  | ✅ | Tab between cells |
    | Math    | ✅ | Native typesetting |

    ## Diagrams

    ```mermaid
    graph LR
      A[Write] --> B{Render}
      B --> C[Read]
      B --> D[Edit]
    ```

    ---

    [^1]: Footnotes render at the bottom, with a hover preview.
    """#
}
