import AppKit
import Combine

enum EditorCommand {
    case copy, copyAndClose, save, saveAs, close
}

/// The image you draw on. Shows the cropped image fitted to the window and
/// turns mouse and keyboard into marks on the model.
@MainActor
final class EditorCanvas: NSView, NSTextFieldDelegate {
    let model: EditorModel
    var onCommand: (EditorCommand) -> Void = { _ in }

    private var cancellables = Set<AnyCancellable>()

    private enum Drag {
        case none
        case draw
        case move(id: UUID, last: CGPoint, started: Bool)
        case crop(start: CGPoint)
    }
    private var drag = Drag.none
    /// The mark being drawn, shown before it becomes part of the model.
    private var draft: Annotation?

    private var textField: NSTextField?
    private var editingID: UUID?
    private var editingPoint = CGPoint.zero

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.needsDisplay = true
                    self.window?.invalidateCursorRects(for: self)
                }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Fitting the image

    private var scale: CGFloat {
        let c = model.crop
        let area = bounds.insetBy(dx: 28, dy: 28)
        guard c.width > 0, c.height > 0, area.width > 0, area.height > 0 else { return 1 }
        // Never larger than the capture's real size on screen.
        return min(area.width / c.width, area.height / c.height, 1 / model.unit)
    }

    private var origin: CGPoint {
        let s = scale, c = model.crop
        return CGPoint(x: bounds.midX - c.width * s / 2, y: bounds.midY - c.height * s / 2)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let s = scale, o = origin, c = model.crop
        return CGPoint(x: (p.x - o.x) / s + c.minX, y: (p.y - o.y) / s + c.minY)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let s = scale, o = origin, c = model.crop
        return CGPoint(x: (p.x - c.minX) * s + o.x, y: (p.y - c.minY) * s + o.y)
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        let c = model.crop
        return CGPoint(x: min(max(p.x, c.minX), c.maxX), y: min(max(p.y, c.minY), c.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = scale, o = origin, c = model.crop

        // A soft shadow under the picture, like a sheet on a desk.
        let frame = CGRect(x: o.x, y: o.y, width: c.width * s, height: c.height * s)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 14,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(frame)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -c.minX, y: -c.minY)
        ctx.clip(to: c)

        let visible = model.annotations.filter { $0.id != editingID }
        EditorRenderer.drawAll(base: model.base, pixelated: model.pixelated, annotations: visible,
                               imageRect: model.imageRect, in: ctx)
        if let draft {
            EditorRenderer.draw(draft, pixelated: model.pixelated, imageRect: model.imageRect, in: ctx)
        }

        if let sel = model.selected, sel.id != editingID {
            let r = EditorRenderer.bounds(sel).insetBy(dx: -3 / s, dy: -3 / s)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 / s)
            ctx.setLineDash(phase: 0, lengths: [5 / s, 3 / s])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if let p = model.pendingCrop {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.addRect(c)
            ctx.addRect(p)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5 / s)
            ctx.stroke(p)
        }
        ctx.restoreGState()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .select ? .arrow : .crosshair)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        endTextEditing(commit: true)
    }

    // MARK: Mouse

    private var tolerance: CGFloat { 6 / scale }

    private func topHit(_ p: CGPoint, areas: Bool) -> Annotation? {
        model.annotations.reversed().first {
            EditorRenderer.hit($0, p, tolerance: tolerance, areas: areas)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil { endTextEditing(commit: true) }
        window?.makeFirstResponder(self)
        let p = toImage(convert(event.locationInWindow, from: nil))

        if model.tool == .crop {
            model.pendingCrop = nil
            drag = .crop(start: clamped(p))
            return
        }

        // Grabbing an existing mark moves it, with any tool.
        if let hit = topHit(p, areas: model.tool == .select) {
            model.selectedID = hit.id
            if event.clickCount == 2, hit.kind == .text {
                beginTextEditing(existing: hit)
                return
            }
            drag = .move(id: hit.id, last: p, started: false)
            return
        }
        model.selectedID = nil

        switch model.tool {
        case .select, .crop:
            break
        case .text:
            beginTextEditing(at: clamped(p))
        case .step:
            var step = model.newAnnotation(.step, at: clamped(p))
            step.number = model.nextStepNumber
            model.add(step)
        default:
            guard let kind = model.tool.dragKind else { return }
            draft = model.newAnnotation(kind, at: clamped(p))
            drag = .draw
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = toImage(convert(event.locationInWindow, from: nil))
        let p = clamped(raw)
        switch drag {
        case .draw:
            draft?.b = event.modifierFlags.contains(.shift) ? constrained(p) : p
            needsDisplay = true
        case let .move(id, last, started):
            if !started { model.checkpoint() }
            if let a = model.annotations.first(where: { $0.id == id }) {
                model.replace(a.moved(by: raw.x - last.x, raw.y - last.y))
            }
            drag = .move(id: id, last: raw, started: true)
        case let .crop(start):
            model.pendingCrop = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                       width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .none:
            break
        }
    }

    /// Shift keeps arrows at 45° steps and boxes square.
    private func constrained(_ p: CGPoint) -> CGPoint {
        guard let d = draft else { return p }
        let dx = p.x - d.a.x, dy = p.y - d.a.y
        if d.kind == .arrow {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: d.a.x + cos(angle) * len, y: d.a.y + sin(angle) * len)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: d.a.x + (dx < 0 ? -side : side), y: d.a.y + (dy < 0 ? -side : side))
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .draw:
            if let d = draft {
                let big = d.kind == .arrow
                    ? hypot(d.b.x - d.a.x, d.b.y - d.a.y) > 4 * model.unit
                    : d.rect.width > 3 * model.unit && d.rect.height > 3 * model.unit
                if big { model.add(d) }
            }
            draft = nil
            needsDisplay = true
        case .crop:
            if let p = model.pendingCrop, p.width < 4 || p.height < 4 { model.pendingCrop = nil }
        default:
            break
        }
        drag = .none
    }

    // MARK: Text

    private func beginTextEditing(at p: CGPoint) {
        editingID = nil
        editingPoint = p
        showField(text: "", at: p, color: model.color, fontSize: model.fontSize)
    }

    private func beginTextEditing(existing a: Annotation) {
        editingID = a.id
        editingPoint = a.a
        showField(text: a.text, at: a.a, color: a.color, fontSize: a.fontSize)
        needsDisplay = true
    }

    private func showField(text: String, at p: CGPoint, color: NSColor, fontSize: CGFloat) {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85)
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize * scale, weight: .bold)
        field.textColor = color
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        addSubview(field)
        textField = field
        layoutField()
        window?.makeFirstResponder(field)
    }

    private func layoutField() {
        guard let field = textField else { return }
        field.sizeToFit()
        let origin = toView(editingPoint)
        field.frame = CGRect(x: origin.x, y: origin.y,
                             width: max(80, field.frame.width + 16), height: field.frame.height)
    }

    func controlTextDidChange(_ obj: Notification) { layoutField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endTextEditing(commit: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endTextEditing(commit: true)
    }

    private func endTextEditing(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        let id = editingID
        editingID = nil
        if commit {
            if let id {
                if text.isEmpty {
                    model.remove(id)
                } else {
                    model.change { model.mutate(id) { $0.text = text } }
                }
            } else if !text.isEmpty {
                var a = model.newAnnotation(.text, at: editingPoint)
                a.text = text
                model.add(a)
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    var isEditingText: Bool { textField != nil }

    /// Keeps the text being typed when the window closes.
    func finishEditing() { endTextEditing(commit: true) }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            if model.pendingCrop != nil { model.pendingCrop = nil } else { onCommand(.copyAndClose) }
        case 36, 76: // Return, Enter
            if model.pendingCrop != nil { model.applyCrop() }
        case 51, 117: // Delete
            if let id = model.selectedID { model.remove(id) }
        default:
            guard let ch = event.charactersIgnoringModifiers?.lowercased(),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            if let tool = EditorTool.allCases.first(where: { $0.key == ch }) {
                model.tool = tool
            } else if let n = Int(ch), (1...EditorPalette.colors.count).contains(n) {
                model.setColor(EditorPalette.colors[n - 1])
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if model.pendingCrop != nil { model.pendingCrop = nil } else { onCommand(.copyAndClose) }
    }

    /// ⌘ shortcuts. The app has no menu bar of its own, so they are handled
    /// here, including copy and paste while typing a text mark.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let ch = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = flags.contains(.shift)

        if isEditingText {
            let action: Selector? = switch ch {
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": shift ? Selector(("redo:")) : Selector(("undo:"))
            default: nil
            }
            if let action { return NSApp.sendAction(action, to: nil, from: self) }
            return super.performKeyEquivalent(with: event)
        }

        switch ch {
        case "z": shift ? model.redo() : model.undo()
        case "c": onCommand(.copy)
        case "s": onCommand(shift ? .saveAs : .save)
        case "w": onCommand(.close)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
