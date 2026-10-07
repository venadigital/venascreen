import AppKit

/// Draws the image and its marks into a context whose coordinates are
/// image pixels with the origin at the top left. The canvas and the final
/// export both go through here, so what you see is what you get.
enum EditorRenderer {
    static func drawAll(base: CGImage, pixelated: CGImage, annotations: [Annotation],
                        imageRect: CGRect, in ctx: CGContext) {
        drawImage(base, in: imageRect, ctx: ctx)
        for a in annotations {
            draw(a, pixelated: pixelated, imageRect: imageRect, in: ctx)
        }
    }

    /// CGContext draws images bottom-up; flip locally for a top-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, pixelated: CGImage, imageRect: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch a.kind {
        case .pixelate:
            ctx.clip(to: a.rect)
            drawImage(pixelated, in: imageRect, ctx: ctx)

        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.withAlphaComponent(0.5).cgColor)
            ctx.fill(a.rect)

        case .rect:
            softShadow(ctx)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width)
            ctx.setLineJoin(.round)
            let r = a.rect
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(a.width, r.width / 2),
                               cornerHeight: min(a.width, r.height / 2), transform: nil))
            ctx.strokePath()

        case .oval:
            softShadow(ctx)
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.width)
            ctx.strokeEllipse(in: a.rect)

        case .arrow:
            softShadow(ctx)
            drawArrow(a, ctx)

        case .text:
            drawText(a, ctx)

        case .step:
            softShadow(ctx)
            let r = stepRadius(a)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillEllipse(in: CGRect(x: a.a.x - r, y: a.a.y - r, width: 2 * r, height: 2 * r))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: contrasting(a.color),
            ]
            let s = NSAttributedString(string: "\(a.number)", attributes: attrs)
            let size = s.size()
            withAppKit(ctx) { s.draw(at: CGPoint(x: a.a.x - size.width / 2, y: a.a.y - size.height / 2)) }
        }
    }

    // MARK: Shapes

    private static func drawArrow(_ a: Annotation, _ ctx: CGContext) {
        let dx = a.b.x - a.a.x, dy = a.b.y - a.a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length
        let head = min(length, a.width * 4.5)
        let half = head * 0.48
        let base = CGPoint(x: a.b.x - ux * head, y: a.b.y - uy * head)

        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // The shaft runs a little into the head so they join without a gap.
        ctx.move(to: a.a)
        ctx.addLine(to: CGPoint(x: base.x + ux * head * 0.3, y: base.y + uy * head * 0.3))
        ctx.strokePath()

        ctx.move(to: a.b)
        ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        ctx.closePath()
        ctx.setLineWidth(a.width * 0.5)
        ctx.drawPath(using: .fillStroke)
    }

    static func stepRadius(_ a: Annotation) -> CGFloat { a.fontSize * 0.72 }

    // MARK: Text

    static func textAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold),
            .foregroundColor: a.color,
        ]
    }

    /// A halo in the opposite tone, drawn under the letters, keeps text
    /// readable on any background without eating into the glyphs.
    private static func haloAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .bold),
            .foregroundColor: NSColor.clear,
            .strokeColor: contrasting(a.color).withAlphaComponent(0.9),
            .strokeWidth: 14.0,
        ]
    }

    static func textBounds(_ a: Annotation) -> CGRect {
        let size = NSAttributedString(string: a.text.isEmpty ? " " : a.text, attributes: textAttributes(a)).size()
        return CGRect(origin: a.a, size: size)
    }

    private static func drawText(_ a: Annotation, _ ctx: CGContext) {
        let halo = NSAttributedString(string: a.text, attributes: haloAttributes(a))
        let s = NSAttributedString(string: a.text, attributes: textAttributes(a))
        withAppKit(ctx) {
            halo.draw(at: a.a)
            s.draw(at: a.a)
        }
    }

    /// Lets AppKit text drawing use a top-down Core Graphics context.
    private static func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func softShadow(_ ctx: CGContext) {
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    }

    static func contrasting(_ c: NSColor) -> NSColor {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    // MARK: Geometry for selection

    /// The area a mark covers, used for the selection outline.
    static func bounds(_ a: Annotation) -> CGRect {
        switch a.kind {
        case .text: textBounds(a)
        case .step:
            CGRect(x: a.a.x - stepRadius(a), y: a.a.y - stepRadius(a),
                   width: 2 * stepRadius(a), height: 2 * stepRadius(a))
        case .arrow: a.rect.insetBy(dx: -a.width * 2.5, dy: -a.width * 2.5)
        default: a.rect.insetBy(dx: -a.width / 2, dy: -a.width / 2)
        }
    }

    /// Whether a point grabs the mark. Shapes are grabbed by their outline,
    /// so you can still draw inside a rectangle. Filled areas only count
    /// when `areas` is on, in the select tool.
    static func hit(_ a: Annotation, _ p: CGPoint, tolerance t: CGFloat, areas: Bool) -> Bool {
        switch a.kind {
        case .text, .step:
            return bounds(a).insetBy(dx: -t, dy: -t).contains(p)
        case .highlight, .pixelate:
            return areas && a.rect.contains(p)
        case .arrow:
            return distance(p, segment: a.a, a.b) <= t + a.width / 2
        case .rect:
            let r = a.rect
            let outer = r.insetBy(dx: -t - a.width / 2, dy: -t - a.width / 2)
            let inner = r.insetBy(dx: t + a.width / 2, dy: t + a.width / 2)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p) || areas)
        case .oval:
            let r = a.rect
            let rx = max(r.width / 2, 1), ry = max(r.height / 2, 1)
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            let d = sqrt(nx * nx + ny * ny)
            if areas && d <= 1 { return true }
            return abs(d - 1) * min(rx, ry) <= t + a.width / 2
        }
    }

    private static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
