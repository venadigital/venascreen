import AppKit
import Combine
import SwiftUI

/// One editor window per capture. Edits are written back to the file when
/// the window closes, so the photo on the line shows them.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [String: EditorWindowController] = [:]

    private let model: EditorModel
    private let canvas: EditorCanvas
    private let onWrite: (URL) -> Void
    private let onSave: () -> Void
    private let onSaveAs: () -> Void
    private var cancellables = Set<AnyCancellable>()

    /// Opens the editor for a file, or brings its window forward if it is
    /// already open. Falls back to Preview for files it cannot read.
    static func open(url: URL, onWrite: @escaping (URL) -> Void,
                     onSave: @escaping () -> Void, onSaveAs: @escaping () -> Void) {
        let key = url.standardizedFileURL.path
        if let existing = openEditors[key] {
            NSApp.activate(ignoringOtherApps: true)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = EditorModel(url: url) else {
            NSWorkspace.shared.open(url)
            return
        }
        let controller = EditorWindowController(model: model, onWrite: onWrite, onSave: onSave, onSaveAs: onSaveAs)
        openEditors[key] = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
    }

    private init(model: EditorModel, onWrite: @escaping (URL) -> Void,
                 onSave: @escaping () -> Void, onSaveAs: @escaping () -> Void) {
        self.model = model
        self.onWrite = onWrite
        self.onSave = onSave
        self.onSaveAs = onSaveAs
        canvas = EditorCanvas(model: model)

        let window = NSWindow(contentRect: Self.initialFrame(for: model),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = model.url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 420)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let bar = NSHostingView(rootView: EditorToolbar(model: model) { [weak self] in self?.perform($0) })
        let container = NSView()
        for v in [bar, canvas] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 46),
            canvas.topAnchor.constraint(equalTo: bar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        canvas.onCommand = { [weak self] in self?.perform($0) }

        // Clicking a tool in the toolbar must not take the keyboard away
        // from the canvas.
        model.$tool
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.canvas.isEditingText else { return }
                    self.window?.makeFirstResponder(self.canvas)
                }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The capture at its real size when it fits, otherwise as large as the
    /// screen allows, centered on the screen with the pointer.
    private static func initialFrame(for model: EditorModel) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let imageW = model.crop.width / model.unit, imageH = model.crop.height / model.unit
        let w = min(max(imageW + 56, 820), visible.width * 0.9)
        let h = min(max(imageH + 56 + 46, 420), visible.height * 0.9)
        return NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
    }

    // MARK: Commands

    private func perform(_ command: EditorCommand) {
        switch command {
        case .copy:
            copyToPasteboard()
            Toast.show(L("Copied", "Copiado"), symbol: "checkmark")
        case .copyAndClose:
            copyToPasteboard()
            Toast.show(L("Copied", "Copiado"), symbol: "checkmark")
            window?.close()
        case .save:
            writeBack()
            window?.close()
            onSave()
        case .saveAs:
            writeBack()
            window?.close()
            onSaveAs()
        case .close:
            window?.close()
        }
    }

    private func copyToPasteboard() {
        guard let png = model.pngData() else { NSSound.beep(); return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// Burns the marks into the file. Only when something changed, and only
    /// while the file is still there: a capture discarded from the line
    /// must not come back.
    private func writeBack() {
        guard model.isDirty, FileManager.default.fileExists(atPath: model.url.path),
              let data = model.pngData() else { return }
        do {
            try data.write(to: model.url, options: .atomic)
            model.markClean()
            onWrite(model.url)
        } catch {
            log.error("Could not write edits: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    func windowWillClose(_ notification: Notification) {
        canvas.finishEditing()
        writeBack()
        Self.openEditors[model.url.standardizedFileURL.path] = nil
    }
}
