import AppKit
import CoreGraphics

/// Takes screenshots with the `screencapture` tool that ships with macOS,
/// so the selection is the native one: crosshair, Space to pick a window,
/// Esc to cancel. Captures go straight to VenaScreen's own folder and hang
/// on the line; nothing lands on the Desktop or in Downloads unless saved.
@MainActor
enum Capture {
    enum Mode {
        /// Drag to select an area, or Space to pick a window.
        case area
        /// The whole screen under the pointer.
        case screen
    }

    private static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")
    private static var running = false

    /// Where captures live until you keep or discard them.
    static var folder: URL { Inbox.folder }

    /// Where "Save" keeps a capture: Downloads/Capturas.
    static let saveFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/Capturas", isDirectory: true)

    /// Captures into VenaScreen's folder and calls back with the new file,
    /// or nil if the selection was cancelled.
    static func take(_ mode: Mode, completion: @escaping @MainActor (URL?) -> Void) {
        guard ensurePermission() else { completion(nil); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        run(mode, to: folder.appendingPathComponent(fileName()), completion: completion)
    }

    /// Selects an area into a temporary file, for OCR. The caller deletes it.
    static func takeTemporary(completion: @escaping @MainActor (URL?) -> Void) {
        guard ensurePermission() else { completion(nil); return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("venascreen-ocr-\(UUID().uuidString).png")
        run(.area, to: url, completion: completion)
    }

    private static func run(_ mode: Mode, to url: URL, completion: @escaping @MainActor (URL?) -> Void) {
        // A second press while selecting would stack two crosshairs.
        guard !running else { return }
        running = true

        var args = ["-x", "-t", "png"]   // -x: no shutter sound, the line has its own
        switch mode {
        case .area:
            args.append("-i")
        case .screen:
            if let display = displayNumberUnderPointer() { args += ["-D", String(display)] }
        }
        args.append(url.path)

        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                running = false
                // Esc during the selection leaves no file behind.
                completion(FileManager.default.fileExists(atPath: url.path) ? url : nil)
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            log.error("screencapture failed to start: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }

    /// "Captura 2026-10-07 a las 14.35.02.png", like macOS in Spanish.
    private static func fileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        let stamp = f.string(from: Date())
        let base = L("Screenshot \(stamp.replacingOccurrences(of: "a las", with: "at"))", "Captura \(stamp)")
        var name = base + ".png"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base) \(n).png"
            n += 1
        }
        return name
    }

    /// `screencapture -D` counts displays from 1, main display first, in the
    /// same order as NSScreen.screens.
    private static func displayNumberUnderPointer() -> Int? {
        let mouse = NSEvent.mouseLocation
        guard let i = NSScreen.screens.firstIndex(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return nil }
        return i + 1
    }

    // MARK: Screen Recording permission

    private static let requestedKey = "screenCaptureRequested"

    /// macOS asks once for Screen Recording, and a permission granted while
    /// the app is running only applies after it reopens. So: the first time,
    /// let macOS show its own prompt; after that, explain and offer to reopen.
    private static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !UserDefaults.standard.bool(forKey: requestedKey) {
            UserDefaults.standard.set(true, forKey: requestedKey)
            // Adds VenaScreen to the list in System Settings and shows the prompt.
            if CGRequestScreenCaptureAccess() { return true }
            return false
        }
        let alert = NSAlert()
        alert.messageText = L("VenaScreen needs Screen Recording",
                              "VenaScreen necesita permiso de Grabación de pantalla")
        alert.informativeText = L(
            "Turn on VenaScreen in System Settings › Privacy & Security › Screen & System Audio Recording. If it is already on, VenaScreen only needs to reopen.",
            "Activa VenaScreen en Ajustes del Sistema › Privacidad y seguridad › Grabación de pantalla y audio del sistema. Si ya está activado, solo hace falta reabrir VenaScreen.")
        alert.addButton(withTitle: L("Reopen VenaScreen", "Reabrir VenaScreen"))
        alert.addButton(withTitle: L("Open Settings", "Abrir Ajustes"))
        alert.addButton(withTitle: L("Later", "Más tarde"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relaunch()
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
        return false
    }

    /// Quits and opens again. A small shell waits for this instance to exit,
    /// so the new one can take the keyboard shortcuts.
    static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
