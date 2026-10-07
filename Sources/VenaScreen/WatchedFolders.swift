import AppKit

/// Extra folders to watch besides the one macOS saves screenshots to.
/// Any image that lands in one of them hangs on the line: captures from
/// another tool, files saved from the browser, AirDrop, exports.
/// The files are never moved or deleted by the line itself.
enum WatchedFolders {
    private static let key = "watchedFolders"
    private static let seededKey = "watchedFoldersSeeded"

    static let downloads = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
    /// A common place for captures from other tools, watched by default when it exists.
    static let capturas = downloads.appendingPathComponent("capturas", isDirectory: true)

    /// Folders the user has chosen, in the order they were added.
    static var folders: [URL] {
        get {
            seedIfNeeded()
            let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        set {
            UserDefaults.standard.set(newValue.map(\.path), forKey: key)
        }
    }

    /// The first time, start with Downloads/capturas when it exists.
    private static func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: capturas.path, isDirectory: &isDir), isDir.boolValue {
            UserDefaults.standard.set([capturas.path], forKey: key)
        }
    }

    static func contains(_ url: URL) -> Bool {
        folders.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    static func toggle(_ url: URL) {
        if contains(url) {
            folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        } else {
            folders.append(url)
        }
    }

    /// Lets the user pick any folder with the standard dialog.
    @MainActor
    static func askForFolder(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch", "Vigilar")
        panel.message = L("Images saved in this folder will hang on the line.",
                          "Las imágenes guardadas en esta carpeta se colgarán en la línea.")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// A short name for the menu: "capturas" or "Descargas/capturas".
    static func label(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(home + "/") {
            return String(path.dropFirst(home.count + 1))
        }
        return url.lastPathComponent
    }
}
