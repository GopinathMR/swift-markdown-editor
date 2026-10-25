import AppKit
import Testing

@MainActor
func lineWidths(_ attr: NSAttributedString) -> (widths: [CGFloat], frames: [CGRect], tk2: Bool) {
  let tv = NSTextView(usingTextLayoutManager: true)
  tv.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
  tv.textStorage!.setAttributedString(attr)
  let lm = tv.textLayoutManager!
  lm.ensureLayout(for: lm.documentRange)
  var widths: [CGFloat] = []
  var frames: [CGRect] = []
  lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
    frames.append(f.layoutFragmentFrame)
    for l in f.textLineFragments { widths.append(l.typographicBounds.width) }
    return true
  }
  return (widths, frames, tv.textLayoutManager != nil)
}

@MainActor @Test func hiddenMarkersCollapse() {
  let font = NSFont.systemFont(ofSize: 16)
  let hidden: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear,
  ]
  let plain = NSAttributedString(
    string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
  let md = NSMutableAttributedString(
    string: "**bold**", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
  md.setAttributes(hidden, range: NSRange(location: 0, length: 2))
  md.setAttributes(hidden, range: NSRange(location: 6, length: 2))
  let a = lineWidths(plain).widths[0]
  let b = lineWidths(md).widths[0]
  print("plain \(a) hidden \(b)")
  #expect(abs(a - b) < 0.5)
  // kern reserve: hidden shortcode + kern on last char reserves 30pt
  let emoji = NSMutableAttributedString(string: "a:smile:b", attributes: [.font: font])
  emoji.setAttributes(hidden, range: NSRange(location: 1, length: 7))
  emoji.addAttribute(.kern, value: 30, range: NSRange(location: 7, length: 1))
  let ab = lineWidths(NSAttributedString(string: "ab", attributes: [.font: font])).widths[0]
  let e = lineWidths(emoji).widths[0]
  print("ab \(ab) reserved \(e)")
  #expect(abs(e - ab - 30) < 1)
  // block reserve: paragraphSpacingBefore
  let ps = NSMutableParagraphStyle()
  ps.paragraphSpacingBefore = 120
  let block = NSMutableAttributedString(string: "one\n$$\nx\n$$\n", attributes: [.font: font])
  block.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 4, length: 3))
  let r = lineWidths(block)
  print("frames", r.frames)
  #expect(r.frames[1].height > 100)
  #expect(r.tk2)
}

@MainActor @Test func hiddenLinesCollapse() {
  let font = NSFont.systemFont(ofSize: 16)
  let tiny = NSFont.systemFont(ofSize: 0.01)
  let s = NSMutableAttributedString(string: "one\n$$\nx\n$$\ntwo", attributes: [.font: font])
  s.addAttributes(
    [.font: tiny, .foregroundColor: NSColor.clear], range: NSRange(location: 4, length: 8))
  let ps = NSMutableParagraphStyle()
  ps.paragraphSpacing = 100
  s.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 9, length: 3))
  let r = lineWidths(s)
  print("frames", r.frames)
}
