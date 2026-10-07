import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// One watcher per extra folder chosen by the user.
    private var extraWatchers: [ScreenshotWatcher] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    /// ⌥1 area, ⌘⇧1 screen, ⌃⌥⌘O text.
    private var areaKey: HotKey?
    private var screenKey: HotKey?
    private var textKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `open -a VenaScreen --args --register-login` turns on "Open at login"
        // the same way the menu item does, so the checkmark stays in sync.
        if CommandLine.arguments.contains("--register-login"),
           SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() }
            catch { log.error("Could not register login item: \(error.localizedDescription, privacy: .public)") }
        }
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()

        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey) { [weak self] in
            self?.toggle()
        }
        registerCaptureKeys()

        // `open -a VenaScreen --args --edit <file>` opens the editor on a file.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                EditorWindowController.open(url: url, onWrite: { _ in }, onSave: {}, onSaveAs: {})
            }
            // `--snapshot <png>` also saves a picture of the editor window,
            // to check its layout without screen recording.
            if let j = args.firstIndex(of: "--snapshot"), j + 1 < args.count {
                let out = URL(fileURLWithPath: args[j + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let view = NSApp.windows.first(where: { $0.title == url.lastPathComponent })?.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                }
            }
        }

        setUpStatusItem()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    // MARK: Capturing

    /// Registers the capture shortcuts. One that another app already owns,
    /// like another screenshot tool, is reported in the menu and retried
    /// each time the menu opens.
    private func registerCaptureKeys() {
        if areaKey?.isRegistered != true {
            areaKey = nil
            areaKey = HotKey(keyCode: kVK_ANSI_1, modifiers: optionKey) { [weak self] in self?.capture(.area) }
        }
        if screenKey?.isRegistered != true {
            screenKey = nil
            screenKey = HotKey(keyCode: kVK_ANSI_1, modifiers: cmdKey | shiftKey) { [weak self] in self?.capture(.screen) }
        }
        if textKey?.isRegistered != true {
            textKey = nil
            textKey = HotKey(keyCode: kVK_ANSI_O, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.captureText() }
        }
    }

    private func capture(_ mode: Capture.Mode) {
        // The line must not end up in its own screenshot.
        if isRevealed { setRevealed(false) }
        Capture.take(mode) { [weak self] url in
            guard let self, let url else { return }
            self.hangCapture(url)
        }
    }

    /// Select an area and its text goes straight to the clipboard. Nothing
    /// hangs on the line and the image is deleted right after reading it.
    private func captureText() {
        if isRevealed { setRevealed(false) }
        Capture.takeTemporary { url in
            guard let url else { return }
            TextRecognition.recognize(url) { text in
                try? FileManager.default.removeItem(at: url)
                guard let text else {
                    NSSound.beep()
                    Toast.show(L("No text found", "No encontré texto"), symbol: "text.magnifyingglass")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Toast.show(L("Text copied", "Texto copiado"), symbol: "checkmark")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        startExtraWatchers()
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
    }

    /// Extra folders: skip any that is already the screenshot folder.
    private func startExtraWatchers() {
        extraWatchers.forEach { $0.stop() }
        extraWatchers = []
        let main = ScreenshotWatcher.screenshotFolder().standardizedFileURL
        for folder in WatchedFolders.folders where folder.standardizedFileURL != main {
            let w = ScreenshotWatcher(
                folder: folder,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            w.start()
            extraWatchers.append(w)
        }
    }

    private func foldersMenu() -> NSMenu {
        let menu = NSMenu()
        var shown: [URL] = []
        for url in [WatchedFolders.capturas, WatchedFolders.downloads] + WatchedFolders.folders
        where !shown.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            shown.append(url)
            let item = ClosureMenuItem(WatchedFolders.label(for: url)) { [weak self] in
                WatchedFolders.toggle(url)
                self?.startExtraWatchers()
            }
            item.state = WatchedFolders.contains(url) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Add folder…", "Agregar carpeta…")) { [weak self] in
            WatchedFolders.askForFolder { url in
                guard let url, !WatchedFolders.contains(url) else { return }
                WatchedFolders.toggle(url)
                self?.startExtraWatchers()
            }
        })
        return menu
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let VenaScreen handle your screenshots?",
                              "¿Quieres que VenaScreen se encargue de tus capturas?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when VenaScreen quits.",
            "Las capturas se colgarán al instante, sin la miniatura flotante, y no se acumularán en el Escritorio. Arrastra una a una carpeta para guardarla, o descártala con la cruz. Puedes desactivarlo desde la barra de menús, y tus ajustes vuelven a ser los de antes al salir de VenaScreen.")
        alert.addButton(withTitle: L("Turn on", "Activar"))
        alert.addButton(withTitle: L("Not now", "Ahora no"))
        if let icon = NSImage(named: "VenaScreen") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount {
            panel.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil), let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.isActive(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.isActive(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { Self.menuBarBand(of: $0).contains(p) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { Self.menuBarBand(of: $0).contains(mouse) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreen.isActive(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        line.maxItems = max(3, min(12, Int(usable / Layout.spacing)))
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The Vena Digital logo in full colour. Falls back to a symbol if the
        // bundle is missing it, like when run straight from swift build.
        if let image = Bundle.main.image(forResource: "menubar") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            statusItem.button?.image = image
        } else {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "VenaScreen")
            image?.isTemplate = true
            statusItem.button?.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line", "Ocultar línea")
                                                 : L("Show line", "Mostrar línea")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        registerCaptureKeys()
        let captureItems: [(String, String, HotKey?, String, NSEvent.ModifierFlags, () -> Void)] = [
            ("Capture area", "Capturar área", areaKey, "1", [.option], { [weak self] in self?.capture(.area) }),
            ("Capture screen", "Capturar pantalla", screenKey, "1", [.command, .shift], { [weak self] in self?.capture(.screen) }),
            ("Capture text", "Capturar texto", textKey, "o", [.control, .option, .command], { [weak self] in self?.captureText() }),
        ]
        var anyTaken = false
        for (en, es, key, char, mods, action) in captureItems {
            // Run after the menu closes, or the menu would be in the shot.
            let item = ClosureMenuItem(L(en, es)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { action() }
            }
            item.keyEquivalent = char
            item.keyEquivalentModifierMask = mods
            if key?.isRegistered != true {
                anyTaken = true
                item.toolTip = L("Another app is using this shortcut",
                                 "Otra app está usando este atajo")
            }
            menu.addItem(item)
        }
        if anyTaken {
            let note = NSMenuItem(title: L("Some shortcuts are taken by another app",
                                           "Algunos atajos los usa otra app"),
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        let clearItem = ClosureMenuItem(L("Take everything down", "Descolgar todo")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let inbox = ClosureMenuItem(L("Handle screenshots", "Encargarse de las capturas")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop",
                          "Las capturas se cuelgan al instante y no pasan por el Escritorio")
        menu.addItem(inbox)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder", "Abrir carpeta de capturas")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        let folders = NSMenuItem(title: L("Also watch", "Vigilar también"), action: nil, keyEquivalent: "")
        folders.submenu = foldersMenu()
        menu.addItem(folders)

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds", "Sonidos")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login", "Abrir al iniciar sesión")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit VenaScreen", "Salir de VenaScreen"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting", "No se pudo cambiar el inicio de sesión")
            alert.informativeText = L("Move VenaScreen to the Applications folder and try again.",
                                      "Mueve VenaScreen a la carpeta Aplicaciones y vuelve a intentarlo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
