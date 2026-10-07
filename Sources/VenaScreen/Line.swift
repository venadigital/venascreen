import AppKit
import UniformTypeIdentifiers
import Combine
import os

let log = Logger(subsystem: "com.venadigital.VenaScreen", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    /// Being read by OCR right now.
    @Published var readingID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    var maxItems = 8


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init() {
        restore()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    /// Files just saved by VenaScreen itself. If they land in a watched
    /// folder, the watcher must not hang them a second time.
    private var justSaved = Set<String>()

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        if justSaved.remove(url.standardizedFileURL.path) != nil { return nil }
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        // A full line lets the oldest photo fall off the far end.
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            // A capture of VenaScreen's own that nobody kept would sit in
            // its folder forever. It goes to the Trash, where it can still
            // be recovered. Files from other folders are left alone.
            if isInInbox(oldest.id) {
                trash(oldest.id, quietly: true)
            } else {
                drop(oldest.id, quietly: true)
            }
        }
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        if let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    /// Double click or press and hold: VenaScreen's own editor. Closing it
    /// writes the edits into the file and refreshes the photo on the line.
    func edit(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        EditorWindowController.open(
            url: item.url,
            onWrite: { [weak self] url in self?.reloadThumbnail(for: url) },
            onSave: { [weak self] in self?.saveToCapturas(id) },
            onSaveAs: { [weak self] in self?.saveAs(id) })
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Reads the text in the photo on the Mac and puts it on the pasteboard.
    func copyText(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        readingID = id
        TextRecognition.recognize(item.url) { [weak self] text in
            guard let self else { return }
            if self.readingID == id { self.readingID = nil }
            guard let text else {
                log.notice("No text found in \(item.url.lastPathComponent, privacy: .public)")
                NSSound.beep()
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.copiedID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.copiedID == id { self?.copiedID = nil }
            }
        }
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID, quietly: Bool = false) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in VenaScreen's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// Whether the file already sits directly in the given folder.
    func isIn(_ id: UUID, folder: URL) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.deletingLastPathComponent().standardizedFileURL.path.lowercased()
            == folder.standardizedFileURL.path.lowercased()
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        save(id, into: desktop)
    }

    /// Keeps a capture in Downloads/Capturas.
    func saveToCapturas(_ id: UUID) {
        save(id, into: Capture.saveFolder)
    }

    /// Keeps a capture wherever you choose, with the name you choose.
    func saveAs(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.directoryURL = Capture.saveFolder
        panel.allowedContentTypes = [.png]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            MainActor.assumeIsolated { self?.move(id, to: target, replacing: true) }
        }
    }

    private func save(_ id: UUID, into folder: URL) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        move(id, to: uniqueURL(in: folder, for: item.url.lastPathComponent), replacing: false)
    }

    /// Moves the file out of the line. Files that live elsewhere, like an
    /// image from Downloads, are copied instead, so they stay where they were.
    private func move(_ id: UUID, to target: URL, replacing: Bool) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let fm = FileManager.default
        justSaved.insert(target.standardizedFileURL.path)
        do {
            if replacing, fm.fileExists(atPath: target.path) {
                try fm.trashItem(at: target, resultingItemURL: nil)
            }
            if isInInbox(id) {
                try fm.moveItem(at: item.url, to: target)
                drop(id, quietly: true)
            } else {
                try fm.copyItem(at: item.url, to: target)
            }
            play("Tink", volume: 0.25)
            log.notice("Saved \(target.lastPathComponent, privacy: .public)")
        } catch {
            justSaved.remove(target.standardizedFileURL.path)
            log.error("Could not save: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
        // If no watcher picks it up, forget it after a while.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.justSaved.remove(target.standardizedFileURL.path)
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        Markup.shared.edit(item.url)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let paths = items.filter { !$0.falling }.map(\.url.path)
        UserDefaults.standard.set(paths, forKey: storeKey)
    }

    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            hang(URL(fileURLWithPath: path), quietly: true)
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
