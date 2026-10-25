import AppKit
import Testing

@testable import MarkdownEditor

@Test func macrosExpandAcrossBlocks() {
  var macros: [String: MathPreprocessor.Macro] = [:]
  MathPreprocessor.collectMacros(
    #"\newcommand{\R}{\mathbb{R}} \newcommand{\pair}[2]{(#1, #2)}"#, into: &macros)
  MathPreprocessor.collectMacros(#"\def\half#1{\frac{#1}{2}}"#, into: &macros)
  let ctx = MathContext(macros: macros)
  #expect(
    MathPreprocessor.prepare(#"x \in \R, \pair{a}{b}, \half{y}"#, context: ctx, physics: false)
      == #"x \in {\mathbb{R}}, {(a, b)}, {\frac{y}{2}}"#)
  // A block of definitions renders as nothing.
  #expect(
    MathPreprocessor.prepare(#"\newcommand{\R}{\mathbb{R}}"#, context: ctx, physics: false).isEmpty)
}

@Test func tagsLabelsAndReferences() {
  var ctx = MathContext()
  ctx.labels = ["eq:e": "3"]
  #expect(
    MathPreprocessor.prepare(#"E = mc^2 \label{eq:e}"#, context: ctx, physics: false) == "E = mc^2")
  #expect(
    MathPreprocessor.prepare(#"\text{see } \eqref{eq:e}"#, context: ctx, physics: false)
      == #"\text{see } \text{(3)}"#)
  #expect(MathPreprocessor.tag(in: #"a \tag{A1}"#) == "A1")
}

@Test func chemistryAndPhysics() {
  let ctx = MathContext()
  #expect(
    MathPreprocessor.prepare(#"\ce{2H2 + O2 -> 2H2O}"#, context: ctx, physics: false)
      == #"\mathrm{2H_{2} + O_{2} \rightarrow  2H_{2}O}"#)
  #expect(
    MathPreprocessor.prepare(#"\ce{SO4^2-}"#, context: ctx, physics: false)
      == #"\mathrm{SO_{4}^{2-}}"#)
  #expect(
    MathPreprocessor.prepare(#"\dv{f}{x} = \abs{x}"#, context: ctx, physics: true)
      == #"{\frac{d f}{d x}} = {\left| x \right|}"#)
}

@MainActor @Test func numberingFollowsPreference() {
  let text =
    "$$\na\n$$\n\n$$\n\\begin{equation}b\\label{x}\\end{equation}\n$$\n\n$$\nc \\tag{T}\n$$\n"
    as NSString
  let model = MarkdownParser(preferences: .init()).parse(text).model
  let ams = MathContext.build(model, text: text, numbering: .ams)
  #expect(Array(ams.numbers.values).sorted() == ["1", "T"])
  #expect(ams.labels == ["x": "1"])
  let all = MathContext.build(model, text: text, numbering: .all)
  #expect(Array(all.numbers.values).sorted() == ["1", "2", "T"])
}

@MainActor @Test func typesetsAndReportsErrors() {
  let ok = MathRenderer.render(
    latex: #"\frac{\sqrt{\pi}}{2}"#, display: true, dark: false, fontSize: 18, number: "1")
  #expect(ok.image != nil && ok.size.width > 40 && ok.error == nil)
  let inline = MathRenderer.render(
    latex: "x^2", display: false, dark: false, fontSize: 16, number: nil)
  #expect(inline.descent > 0 && inline.descent < inline.size.height)
  let bad = MathRenderer.render(
    latex: #"\frac{a"#, display: true, dark: false, fontSize: 18, number: nil)
  #expect(bad.image == nil && bad.error != nil)
}
