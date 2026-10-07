import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The tools in the editor, in toolbar order, each with its key.
enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, rect, oval, text, highlight, pixelate, step, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .oval: "circle"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .pixelate: "square.grid.3x3.fill"
        case .step: "1.circle"
        case .crop: "crop"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rect: "r"
        case .oval: "o"
        case .text: "t"
        case .highlight: "h"
        case .pixelate: "b"
        case .step: "n"
        case .crop: "c"
        }
    }

    var title: String {
        switch self {
        case .select: L("Select", "Seleccionar")
        case .arrow: L("Arrow", "Flecha")
        case .rect: L("Rectangle", "Rectángulo")
        case .oval: L("Oval", "Óvalo")
        case .text: L("Text", "Texto")
        case .highlight: L("Highlight", "Resaltador")
        case .pixelate: L("Pixelate", "Pixelar")
        case .step: L("Numbered steps", "Pasos numerados")
        case .crop: L("Crop", "Recortar")
        }
    }

    /// The kind of mark the tool draws, if it draws one by dragging.
    var dragKind: Annotation.Kind? {
        switch self {
        case .arrow: .arrow
        case .rect: .rect
        case .oval: .oval
        case .highlight: .highlight
        case .pixelate: .pixelate
        default: nil
        }
    }
}

enum EditorPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1), // black
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
    ]
}

/// One mark on the image, in image pixel coordinates with the origin at
/// the top left.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable { case arrow, rect, oval, text, highlight, pixelate, step }

    var id = UUID()
    var kind: Kind
    /// Start point. For text, its top left corner. For a step, its center.
    var a: CGPoint
    /// End point for shapes. Unused for text and steps.
    var b: CGPoint
    var color: NSColor
    var width: CGFloat
    var fontSize: CGFloat
    var text = ""
    var number = 0

    var rect: CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    func moved(by dx: CGFloat, _ dy: CGFloat) -> Annotation {
        var m = self
        m.a = CGPoint(x: a.x + dx, y: a.y + dy)
        m.b = CGPoint(x: b.x + dx, y: b.y + dy)
        return m
    }
}

/// Everything the editor knows about one image: the picture, the marks on
/// it, the crop, and the history for undo.
@MainActor
final class EditorModel: ObservableObject {
    let url: URL
    let base: CGImage
    /// The whole image pixelated once; pixelate marks show a clip of it.
    let pixelated: CGImage
    /// Image pixels per screen point: 2 for a Retina screenshot.
    let unit: CGFloat

    @Published var tool: EditorTool = .arrow {
        didSet {
            if tool != .crop { pendingCrop = nil }
            if tool != .select && oldValue == .select { selectedID = nil }
        }
    }
    @Published private(set) var color: NSColor = EditorPalette.colors[0]
    /// 0 small, 1 medium, 2 large.
    @Published private(set) var size = 1
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var crop: CGRect
    @Published var selectedID: UUID?
    @Published var pendingCrop: CGRect?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private(set) var isDirty = false

    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var imageRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.url = url
        base = image
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        unit = dpi > 72.5 ? CGFloat(dpi / 72) : (NSScreen.main?.backingScaleFactor ?? 2)
        pixelated = Self.pixelate(image, block: 10 * unit) ?? image
        crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    // MARK: Style

    var strokeWidth: CGFloat { [2.5, 4, 7][size] * unit }
    var fontSize: CGFloat { [15, 21, 30][size] * unit }

    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    /// Picks a color, and recolors the selected mark if there is one.
    func setColor(_ c: NSColor) {
        color = c
        if let s = selected, s.kind != .pixelate {
            change { self.mutate(s.id) { $0.color = c } }
        }
    }

    func setSize(_ s: Int) {
        size = s
        if let sel = selected {
            let w = strokeWidth, f = fontSize
            change { self.mutate(sel.id) { $0.width = w; $0.fontSize = f } }
        }
    }

    func newAnnotation(_ kind: Annotation.Kind, at p: CGPoint) -> Annotation {
        Annotation(kind: kind, a: p, b: p, color: color, width: strokeWidth, fontSize: fontSize)
    }

    var nextStepNumber: Int {
        (annotations.filter { $0.kind == .step }.map(\.number).max() ?? 0) + 1
    }

    // MARK: Changes

    /// Records the current state for undo, then applies the change.
    func change(_ body: () -> Void) {
        checkpoint()
        body()
        isDirty = true
    }

    /// Records the current state once, before a drag that changes it
    /// continuously, like moving a mark.
    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        redoStack.removeAll()
        updateFlags()
    }

    func add(_ a: Annotation) {
        change { annotations.append(a) }
    }

    /// Changes a mark without a new undo step. Pair it with `checkpoint()`.
    func replace(_ a: Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == a.id }) else { return }
        annotations[i] = a
        isDirty = true
    }

    func mutate(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&annotations[i])
    }

    func remove(_ id: UUID) {
        change { annotations.removeAll { $0.id == id } }
        if selectedID == id { selectedID = nil }
    }

    func applyCrop() {
        defer { pendingCrop = nil }
        guard let p = pendingCrop?.intersection(crop).integral, p.width > 4, p.height > 4 else { return }
        change { crop = p }
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        annotations = s.annotations
        crop = s.crop
        selectedID = nil
        pendingCrop = nil
        isDirty = true
        updateFlags()
    }

    private func updateFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func markClean() { isDirty = false }

    // MARK: Output

    /// The final picture: crop applied and every mark burned in.
    func render() -> CGImage? {
        let c = crop.integral
        let w = Int(c.width), h = Int(c.height)
        let space = (base.colorSpace?.supportsOutput == true ? base.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Same top-left coordinates as the canvas, so both draw identically.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -c.minX, y: -c.minY)
        EditorRenderer.drawAll(base: base, pixelated: pixelated, annotations: annotations,
                               imageRect: imageRect, in: ctx)
        return ctx.makeImage()
    }

    /// PNG with the original density, so a Retina capture keeps its size.
    func pngData() -> Data? {
        guard let image = render() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        let dpi = 72 * unit
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi,
                                                 kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func pixelate(_ image: CGImage, block: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(block, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }
}
