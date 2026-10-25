import AppKit

/// Draws what the styler asked for: block decorations behind the text, then the text, then
/// inline substitutes (bullets, checkboxes, emoji, inline math) over hidden source.
final class MarkdownLayoutFragment: NSTextLayoutFragment {
  /// Hook for focus mode: alpha for this paragraph (1 = normal).

  private var paragraph: NSAttributedString? { (textElement as? NSTextParagraph)?.attributedString }

  private var containerWidth: CGFloat {
    textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
  }

  private var padding: CGFloat { textLayoutManager?.textContainer?.lineFragmentPadding ?? 5 }

  override var renderingSurfaceBounds: CGRect {
    let f = layoutFragmentFrame
    // Reach into the left margin too: heading numbers and list markers draw there.
    let full = CGRect(x: -f.minX - 80, y: 0, width: containerWidth + 120, height: f.height)
    return super.renderingSurfaceBounds.union(full)
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    let deco = paragraph.flatMap {
      $0.length > 0 ? $0.attribute(.mdBlock, at: 0, effectiveRange: nil) as? BlockDecoration : nil
    }
    if let deco { drawBlock(deco, at: point, in: context, behind: true) }
    NSGraphicsContext.restoreGraphicsState()

    super.draw(at: point, in: context)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    if let deco { drawBlock(deco, at: point, in: context, behind: false) }
    drawInline(at: point)
    NSGraphicsContext.restoreGraphicsState()
  }

  /// Container x → local drawing x.
  private func x(_ containerX: CGFloat, _ point: CGPoint) -> CGFloat {
    point.x + containerX - layoutFragmentFrame.minX
  }

  private func drawBlock(_ d: BlockDecoration, at point: CGPoint, in ctx: CGContext, behind: Bool) {
    let lines = textLineFragments
    let frame = layoutFragmentFrame
    let top = lines.first?.typographicBounds.minY ?? 0
    let bottom = lines.last?.typographicBounds.maxY ?? frame.height
    if behind {
      if let bg = d.background {
        let left = x(padding + d.inset, point)
        let right = x(containerWidth - padding, point)
        // Middle lines fill the whole fragment so line spacing doesn't stripe the box.
        let y0 = d.roundTop ? top - 6 : 0
        let y1 = d.roundBottom ? bottom + 6 : frame.height
        let r = CGRect(x: left, y: point.y + y0, width: right - left, height: y1 - y0)
        bg.setFill()
        roundedPath(r, top: d.roundTop, bottom: d.roundBottom, radius: 6).fill()
      }
      for bar in d.bars {
        bar.color.setFill()
        NSRect(x: x(padding + bar.x, point), y: point.y, width: 3, height: frame.height).fill()
      }
      return
    }
    if let color = d.rule {
      let y = point.y + bottom + (frame.height - bottom) / 2
      let path = NSBezierPath()
      path.move(to: CGPoint(x: x(padding + d.inset, point), y: y))
      path.line(to: CGPoint(x: x(containerWidth - padding, point), y: y))
      path.lineWidth = d.ruleDashed ? 1 : 2
      if d.ruleDashed { path.setLineDash([5, 4], count: 2, phase: 0) }
      color.setStroke()
      path.stroke()
      if let label = d.ruleLabel {
        let f = NSFont.systemFont(ofSize: 10)
        let s = NSAttributedString(
          string: " \(label) ",
          attributes: [
            .font: f, .foregroundColor: color, .backgroundColor: NSColor.textBackgroundColor,
          ])
        let w = s.size().width
        s.draw(at: CGPoint(x: x((containerWidth - w) / 2, point), y: y - 7))
      }
    }
    if d.renderSize != .zero || d.renderError != nil {
      let y = point.y + bottom + max(4, (frame.height - bottom - d.renderSize.height) / 2)
      let avail = containerWidth - 2 * padding - d.inset
      let left =
        d.renderCentered
        ? padding + d.inset + max(0, (avail - d.renderSize.width) / 2) : padding + d.inset
      if let img = d.render {
        img.draw(
          in: CGRect(
            x: x(left, point), y: y, width: d.renderSize.width, height: d.renderSize.height),
          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      } else if let err = d.renderError {
        let s = NSAttributedString(
          string: "⚠︎ " + err,
          attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed])
        s.draw(at: CGPoint(x: x(padding + d.inset + 8, point), y: point.y + bottom + 4))
      }
    }
    if let label = d.label, let first = lines.first {
      let s = NSAttributedString(
        string: label,
        attributes: [
          .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: d.labelColor,
        ])
      let w = s.size().width
      s.draw(
        at: CGPoint(
          x: x(containerWidth - padding - 10 - w, point),
          y: point.y + first.typographicBounds.minY + 1))
    }
    if let n = d.lineNumber, let first = lines.first, let f = d.gutterFont {
      let s = NSAttributedString(
        string: "\(n)", attributes: [.font: f, .foregroundColor: NSColor.tertiaryLabelColor])
      let w = s.size().width
      let baseline = first.typographicBounds.minY + first.glyphOrigin.y
      s.draw(
        at: CGPoint(x: x(padding + d.inset + 30 - w, point), y: point.y + baseline - f.ascender))
    }
    if let (text, font, color) = d.prefix, let first = lines.first {
      let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
      let baseline = first.typographicBounds.minY + first.glyphOrigin.y
      let startX = first.locationForCharacter(at: 0).x
      s.draw(
        at: CGPoint(
          x: point.x + first.typographicBounds.minX + startX - s.size().width,
          y: point.y + baseline - font.ascender))
    }
  }

  private func drawInline(at point: CGPoint) {
    guard let p = paragraph, p.length > 0 else { return }
    p.enumerateAttribute(.mdInline, in: NSRange(location: 0, length: p.length)) { value, range, _ in
      guard let d = value as? InlineDecoration else { return }
      guard
        let line = textLineFragments.first(where: {
          NSLocationInRange(range.location, $0.characterRange)
            || range.location == $0.characterRange.upperBound
        })
      else { return }
      let local = line.locationForCharacter(at: range.location)
      let ox = point.x + line.typographicBounds.minX + local.x + d.dx
      let baseline = point.y + line.typographicBounds.minY + line.glyphOrigin.y
      switch d.kind {
      case .text(let s, let font, let color, let raise):
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
          .draw(at: CGPoint(x: ox, y: baseline - font.ascender - raise))
      case .checkbox(let checked, let color):
        let r = CGRect(x: ox + 2, y: baseline - 12, width: 13, height: 13)
        let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        if checked {
          color.setFill()
          path.fill()
          let tick = NSBezierPath()
          tick.move(to: CGPoint(x: r.minX + 3, y: r.midY))
          tick.line(to: CGPoint(x: r.minX + 5.5, y: r.maxY - 3))
          tick.line(to: CGPoint(x: r.maxX - 3, y: r.minY + 3))
          tick.lineWidth = 1.8
          NSColor.white.setStroke()
          tick.stroke()
        } else {
          path.lineWidth = 1.2
          NSColor.secondaryLabelColor.setStroke()
          path.stroke()
        }
      case .image(let img, let size, let descent):
        let r = CGRect(
          x: ox, y: baseline + descent - size.height, width: size.width, height: size.height)
        img.draw(
          in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      }
    }
  }

  private func roundedPath(_ r: CGRect, top: Bool, bottom: Bool, radius: CGFloat) -> NSBezierPath {
    guard top || bottom else { return NSBezierPath(rect: r) }
    if top && bottom { return NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
    let path = NSBezierPath()
    // Flipped coordinates: minY is the top edge.
    let tr = top ? radius : 0
    let br = bottom ? radius : 0
    path.move(to: CGPoint(x: r.minX + tr, y: r.minY))
    path.line(to: CGPoint(x: r.maxX - tr, y: r.minY))
    if tr > 0 {
      path.curve(
        to: CGPoint(x: r.maxX, y: r.minY + tr), controlPoint1: CGPoint(x: r.maxX, y: r.minY),
        controlPoint2: CGPoint(x: r.maxX, y: r.minY))
    }
    path.line(to: CGPoint(x: r.maxX, y: r.maxY - br))
    if br > 0 {
      path.curve(
        to: CGPoint(x: r.maxX - br, y: r.maxY), controlPoint1: CGPoint(x: r.maxX, y: r.maxY),
        controlPoint2: CGPoint(x: r.maxX, y: r.maxY))
    }
    path.line(to: CGPoint(x: r.minX + br, y: r.maxY))
    if br > 0 {
      path.curve(
        to: CGPoint(x: r.minX, y: r.maxY - br), controlPoint1: CGPoint(x: r.minX, y: r.maxY),
        controlPoint2: CGPoint(x: r.minX, y: r.maxY))
    }
    path.line(to: CGPoint(x: r.minX, y: r.minY + tr))
    if tr > 0 {
      path.curve(
        to: CGPoint(x: r.minX + tr, y: r.minY), controlPoint1: CGPoint(x: r.minX, y: r.minY),
        controlPoint2: CGPoint(x: r.minX, y: r.minY))
    }
    path.close()
    return path
  }
}
