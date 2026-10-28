import AppKit
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI
import NotesCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line(restoring: false)
    private var notes: NotesStore!
    private var workspace: NotesWorkspace!
    private var loadingWindow: NSWindow?
    private var renderedNotes: [UUID: NoteDocument] = [:]
    private var noteAppearanceSignature = ""
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
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

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("application-launch")
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        let loading = NotesWorkspace.makeWindow(title: "正在打开闪念", size: NSSize(width: 340, height: 90), minimum: NSSize(width: 340, height: 90))
        loading.contentView = NSHostingView(rootView: HStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text("正在打开闪念…").font(.system(size: 14))
            Spacer()
            NotesIconButton(symbol: "xmark", label: "取消打开 · Esc") { NSApp.terminate(nil) }
        }.padding(22).foregroundStyle(NotesTheme.text).background(NotesTheme.shell).clipShape(RoundedRectangle(cornerRadius: 22)))
        (loading as? NotesWindow)?.onEscape = { NSApp.terminate(nil) }
        loadingWindow = loading
        loading.makeKeyAndOrderFront(nil)
        LaunchTrace.mark("loading-visible")
        DispatchQueue.main.async { LaunchTrace.mark("first-ui-responsive") }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !LaunchOptions.demo {
                LaunchTrace.mark("screenshots-start")
                await self.line.restorePhotos()
                LaunchTrace.mark("screenshots-ready")
            }
            LaunchTrace.mark("store-start")
            guard await self.setUpNotes() else { NSApp.terminate(nil); return }
            LaunchTrace.mark("store-ready")
            self.finishLaunching()
        }
    }

    private func finishLaunching() {
        setUpApplicationMenu()
        if !LaunchOptions.demo {
            if Inbox.isEnabled { Inbox.apply() }
            restoreSettingsOnTermination()
            startWatcher()
        }
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if !LaunchOptions.demo && ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        if !LaunchOptions.demo { registerShortcut() }

        setUpStatusItem()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.onClearScreenshots = { [weak self] batch in self?.startScreenshotClear(batch) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

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

        if LaunchOptions.demo || LaunchOptions.testBuild || notes.documents.isEmpty || !UserDefaults.standard.bool(forKey: "welcomed") {
            if !LaunchOptions.demo { UserDefaults.standard.set(true, forKey: "welcomed") }
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if LaunchOptions.demoRope {
                    self.loadingWindow?.orderOut(nil); self.loadingWindow = nil
                    return
                }
                if LaunchOptions.demo, let first = self.notes.documents.first(where: { $0.title == "把灵感留下来" && $0.deletedAt == nil }) ?? self.notes.documents.first(where: { $0.deletedAt == nil }) {
                    LaunchTrace.mark("editor-start")
                    self.workspace.open(first.id)
                    LaunchTrace.mark("editor-created")
                } else { self.workspace.showLibrary(); LaunchTrace.mark("library-created") }
                self.loadingWindow?.orderOut(nil); self.loadingWindow = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    LaunchTrace.mark("ui-responsive")
                }
            }
        } else { loadingWindow?.orderOut(nil); loadingWindow = nil }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if LaunchOptions.demoRope {
            keepOpen = true; wanted = true; refresh(); reveal(pinned: true)
            return true
        }
        if workspace != nil, !workspace.hasVisibleEditor { workspace.showLibrary() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        line.screenshotSweep.complete()
        if !LaunchOptions.demo && Inbox.isEnabled { Inbox.restore() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        workspace == nil || workspace.prepareToQuit() ? .terminateNow : .terminateCancel
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        guard !LaunchOptions.demo, UserDefaults.standard.bool(forKey: "notesWatchScreenshots") else { return }
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
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        guard !LaunchOptions.demo else { return }
        if on { UserDefaults.standard.set(true, forKey: "notesWatchScreenshots") }
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    private func setScreenshotWatching(_ enabled: Bool) {
        guard !LaunchOptions.demo else { return }
        UserDefaults.standard.set(enabled, forKey: "notesWatchScreenshots")
        startWatcher()
    }

    /// Watching the clipboard is opt in, from Preferences or the menu bar.
    private func setClipboard(_ on: Bool) {
        guard !LaunchOptions.demo else { return }
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
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

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        guard line.liveCount == 0, !keepOpen, line.screenshotClear == nil else { return }
        let delay = max(0.7, peekUntil.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen, self.line.screenshotClear == nil else { return }
            guard Date() >= self.peekUntil else { self.itemsChanged(); return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        if line.screenshotClear != nil, panel.screen != (screen ?? LinePanel.screenUnderPointer()) {
            line.screenshotSweep.complete()
        }
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen)
        guard let id = line.hang(url, flying: from != nil) else {
            // Nothing hung after all, so an empty line goes away again.
            itemsChanged()
            return
        }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id && $0.flying && !$0.falling }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen, id: id) { [weak self] in
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

    private func startScreenshotClear(_ batch: ScreenshotClearBatch) {
        guard isPresent, isRevealed else { line.finishScreenshotClear(batch.id); return }
        CaptureFlight.settle(batch.targetIDs)
        // Also land captures whose delayed flight has not started yet.
        for item in batch.targets where item.flying { line.land(item.id) }
        let width = panel.frame.width
        let contentWidth = max(300, width - Layout.controlsWidth)
        let targets = batch.targets.compactMap { item -> ScreenshotSweepPlan.Target? in
            let x = line.hangingX(for: item.id, width: width)
            guard x > 12, x < contentWidth - 12 else { return nil }
            return .init(id: item.id, x: x)
        }
        awaySince = nil
        line.screenshotSweep.start(.init(width: width, targets: targets), reduced: HangingMotion.reduced,
            onContact: { [weak self] id in self?.line.releaseScreenshot(id, in: batch.id) },
            onFinish: { [weak self] in
                guard let self else { return }
                self.line.finishScreenshotClear(batch.id)
                if self.isPresent, self.isRevealed { self.reveal(peekFor: 6) }
            })
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = line.hangingX(for: id, width: width)
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
        let blocked = panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false
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
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
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
        if !on {
            line.screenshotSweep.complete()
            NotesMenuPresenter.shared.dismiss(ifAnchoredTo: panel)
        }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent { panel.orderFrontRegardless() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
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
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
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
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if Self.opensFromMenuBar, let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreen.blocksLine(on: screen) {
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

        let busy = LaunchOptions.demoRope || pinned || GrabView.isDragging || GrabView.isShowingMenu || NotesMenuPresenter.shared.isPresented
            || line.pressedID != nil || line.screenshotClear != nil || now < peekUntil
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
        let overPhoto = line.acceptsPointer(at: flipped)
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        // Off while recording, so pressing the current one records it
        // instead of showing the line.
        hotKey = nil
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                // Taken by another app: keep the one that worked.
                if result != nil && self.hotKey == nil {
                    Shortcut.current = previous
                    let alert = NSAlert()
                    alert.messageText = "无法使用这个全局快捷键"
                    alert.informativeText = "这个组合暂时无法注册，可能已被其他应用占用。已恢复先前设置，请换一个组合。"
                    alert.addButton(withTitle: "知道了")
                    alert.runModal()
                }
            }
            self.registerShortcut()
        }
    }

    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        line.screenshotSweep.complete()
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        if let width = line.screenshotSweep.width, width != panel.frame.width { line.screenshotSweep.complete() }
        let usable = panel.frame.width - (96 + Layout.controlsWidth)
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        line.maxItems = max(fits, Line.keepOnLine ?? fits)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showStatusMenu)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu(title: LaunchOptions.appName)
        menu.autoenablesItems = false
        menuNeedsUpdate(menu)
        NotesMenuPresenter.shared.toggle(menu, from: button, alignment: .trailing)
    }

    /// The development note icon adds a badge when clipboard capture is on.
    private func updateStatusIcon() {
        let on = !LaunchOptions.demo && ClipboardWatcher.isEnabled
        let description = on ? LaunchOptions.appName + " · 正在挂上复制的图片" : LaunchOptions.appName
        let image = NSImage(systemSymbolName: on ? "note.text.badge.plus" : "note.text", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        if let button = statusItem.button {
            button.toolTip = nil
            button.setAccessibilityHelp(description)
            let help = button.subviews.compactMap { $0 as? NotesTooltipAnchor.AnchorView }.first
                ?? NotesTooltipAnchor.AnchorView(frame: button.bounds)
            help.text = description
            help.autoresizingMask = [.width, .height]
            if help.superview == nil { button.addSubview(help) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(ClosureMenuItem("新建闪念", key: "n") { [weak self] in self?.workspace.newNote() })
        menu.addItem(ClosureMenuItem("全部闪念", key: "f") { [weak self] in self?.workspace.showLibrary() })
        menu.addItem(ClosureMenuItem("闪念设置…", key: ",") { [weak self] in self?.workspace.showSettings() })
        menu.addItem(.separator())

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let watching = ClosureMenuItem("启用截图监听") { [weak self] in
            self?.setScreenshotWatching(!UserDefaults.standard.bool(forKey: "notesWatchScreenshots"))
        }
        watching.state = !LaunchOptions.demo && UserDefaults.standard.bool(forKey: "notesWatchScreenshots") ? .on : .off
        watching.isEnabled = !LaunchOptions.demo
        menu.addItem(watching)

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.isEnabled = !LaunchOptions.demo
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.isEnabled = !LaunchOptions.demo
        menu.addItem(clipboard)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests in the menu bar")) {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        folderItem.isEnabled = !LaunchOptions.demo
        menu.addItem(folderItem)

        let keepItem = NSMenuItem(title: L("Keep on line"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        let fit = ClosureMenuItem(L("As many as fit")) { [weak self] in self?.setKeep(nil) }
        fit.state = Line.keepOnLine == nil ? .on : .off
        keeps.addItem(fit)
        for n in Line.keepChoices {
            let item = ClosureMenuItem(String(format: L("%d photos"), n)) { [weak self] in self?.setKeep(n) }
            item.state = Line.keepOnLine == n ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        var shortcutStatus = Shortcut.current?.display ?? L("None")
        if LaunchOptions.demo { shortcutStatus += " · 演示模式未注册" }
        else if Shortcut.current != nil && hotKey == nil { shortcutStatus += " · 暂未注册" }
        let current = NSMenuItem(title: shortcutStatus, action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcutItem.submenu = shortcuts
        shortcutItem.isEnabled = !LaunchOptions.demo
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher?.folder ?? ScreenshotWatcher.desktop)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = !LaunchOptions.demo
        menu.addItem(login)

        // The app never connects to anything, so it cannot tell when a new
        // version is out. The website can: it is opened with this version
        // and language, and says whether there is a newer one.
        let version = NSMenuItem(title: LaunchOptions.appName + " " + LaunchOptions.version + " · 基于 Tendedero 1.5.0", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出 " + LaunchOptions.appName, key: "q") {
            NSApp.terminate(nil)
        })
        let symbols = ["新建闪念": "square.and.pencil", "全部闪念": "square.grid.2x2", "闪念设置…": "slider.horizontal.3",
                       L("Show line"): "arrow.down.to.line", L("Hide line"): "arrow.up.to.line",
                       L("Take everything down"): "tray.and.arrow.down", "启用截图监听": "camera.viewfinder",
                       L("Also watch folders"): "folder", L("Keep on line"): "pin", L("Size"): "rectangle.expand.vertical",
                       L("Shortcut"): "keyboard", L("Open screenshots folder"): "folder", "退出 " + LaunchOptions.appName: "power"]
        for item in menu.items { if let symbol = symbols[item.title] { item.notesSymbol(symbol) } }
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = "将 " + LaunchOptions.appName + " 放入应用程序文件夹后再试。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}

// The original strip owns motion. Documents only supply their stable identity
// and rendered contents, so autosaving never creates a second hanging card.
private extension AppDelegate {
    func setUpNotes() async -> Bool {
        do {
            notes = try await NotesStore.open(directory: LaunchOptions.directory)
            if LaunchOptions.demo { try DemoNotes.seed(notes) }
            workspace = NotesWorkspace(store: notes)
            workspace.settingsActions = NotesSettingsActions(
                systemAvailable: !LaunchOptions.demo,
                read: { [weak self] in
                    NotesSettingsSnapshot(
                        watchesScreenshots: !LaunchOptions.demo && UserDefaults.standard.bool(forKey: "notesWatchScreenshots"),
                        copiesImages: !LaunchOptions.demo && ClipboardWatcher.isEnabled,
                        loginEnabled: !LaunchOptions.demo && SMAppService.mainApp.status == .enabled,
                        loginNeedsApproval: !LaunchOptions.demo && SMAppService.mainApp.status == .requiresApproval,
                        screenshotFolder: self?.watcher?.folder ?? ScreenshotWatcher.screenshotFolder(),
                        extraFolders: Self.extraFolders,
                        capacity: Line.keepOnLine,
                        shortcut: (Shortcut.current?.display ?? "未设置") + (LaunchOptions.demo ? " · 验收模式未注册" : ""))
                },
                watchScreenshots: { [weak self] enabled in self?.setScreenshotWatching(enabled) },
                copyImages: { [weak self] enabled in self?.setClipboard(enabled) },
                toggleLogin: { guard !LaunchOptions.demo else { return }; Self.toggleLaunchAtLogin() },
                chooseFolder: { [weak self] in guard !LaunchOptions.demo else { return }; self?.chooseExtraFolder() },
                removeFolder: { [weak self] folder in
                    guard !LaunchOptions.demo else { return }
                    Self.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                },
                setCapacity: { [weak self] value in self?.setKeep(value) },
                changeShortcut: { [weak self] in guard !LaunchOptions.demo else { return }; self?.changeShortcut() })
            workspace.onFocus = { [weak self] id in self?.line.selectedNoteID = id }
            workspace.editorTransitionAnchor = { [weak self] noteID in
                guard let self, self.line.revealed, self.panel.isVisible, let content = self.panel.contentView else { return nil }
                let note = self.line.items.first { $0.noteID == noteID && !$0.falling }
                let rect = note.flatMap { self.line.hitRects[$0.id] } ?? self.line.hitRects[LineControl.libraryID]
                guard let rect, !rect.isEmpty else { return nil }
                let local = NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
                return self.panel.convertToScreen(content.convert(local, to: nil))
            }
            workspace.onHang = { [weak self] _ in
                self?.syncNotes()
                self?.comeDown(on: nil)
            }
            workspace.onTakeOff = { [weak self] _ in self?.syncNotes() }
            line.onNewNote = { [weak self] template in
                self?.workspace.newNote(template: NoteTemplate(rawValue: template) ?? .text)
            }
            line.onShowNotes = { [weak self] in self?.workspace.showLibrary() }
            line.onOpenNote = { [weak self] in self?.workspace.open($0) }
            line.onCopyNote = { [weak self] in self?.workspace.copy($0) }
            line.onDuplicateNote = { [weak self] in self?.workspace.duplicate($0) }
            line.onExportNote = { [weak self] in self?.workspace.export($0) }
            line.onDeleteNote = { [weak self] in self?.workspace.requestTrash($0) }
            line.onTakeOffNote = { [weak self] id in
                self?.workspace.takeOff(id) ?? false
            }
            line.noteDragURL = { [weak self] id in
                guard let self else { return nil }
                do {
                    try self.workspace.commit(id)
                    guard let note = self.notes.document(id: id) else { return nil }
                    let session = FileManager.default.temporaryDirectory
                        .appendingPathComponent("LineNotes-Drag", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
                    let name = String(note.displayTitle.components(separatedBy: unsafe).joined(separator: "-").prefix(80))
                    let folder = session.appendingPathComponent(name == "." || name == ".." ? "闪念" : name, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent("闪念.md")
                    try self.notes.exportMarkdown(id, to: file)
                    // Finder must copy the container, including the relative
                    // attachment directory; a lone .md would have broken links.
                    return folder
                } catch { self.presentNotesError(error); return nil }
            }
            syncNotes(quietly: true)
            notes.$documents.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.syncNotes()
            }.store(in: &cancellables)
            notes.$saveState.receive(on: RunLoop.main).sink { [weak self] state in
                if state == .saved { self?.syncNotes() }
            }.store(in: &cancellables)
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main).sink { [weak self] _ in
                    self?.refreshNoteAppearance()
                }.store(in: &cancellables)
            NSApp.publisher(for: \.effectiveAppearance).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshNoteAppearance() }
                .store(in: &cancellables)
            if LaunchOptions.demo {
                for name in ["DemoGallery", "DemoArchitecture"] {
                    if let url = Bundle.main.url(forResource: name, withExtension: "png") {
                        line.hang(url, quietly: true)
                    }
                }
            }
            line.restoreOrdering()
            refreshNoteAppearance()
            return true
        } catch {
            presentNotesOpenFailure(error)
            return false
        }
    }

    func presentNotesOpenFailure(_ error: Error) {
        let directory = LaunchOptions.directory
        loadingWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法打开闪念资料库"
        alert.informativeText = error.localizedDescription + "\n\n原有资料仍保留在本机，未被替换。你可以查看资料文件夹，或关闭应用后重试。"
        alert.addButton(withTitle: "查看资料文件夹")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(directory)
        }
    }

    func syncNotes(quietly: Bool = false) {
        guard notes.saveState == .saved else { return }
        let hanging = notes.documents.filter { $0.onLine && $0.deletedAt == nil }
        let ids = Set(hanging.map(\.id))
        for item in line.items where item.noteID != nil && !item.falling {
            if let id = item.noteID, !ids.contains(id) { line.removeNote(id) }
        }
        for note in hanging {
            var thumbnailDocument = note
            thumbnailDocument.editorPaper = nil
            guard renderedNotes[note.id] != thumbnailDocument || !line.items.contains(where: { $0.noteID == note.id && !$0.falling }) else { continue }
            line.hangNote(note.id, thumbnail: workspace.thumbnail(for: note), title: note.displayTitle, quietly: quietly)
            renderedNotes[note.id] = thumbnailDocument
        }
        renderedNotes = renderedNotes.filter { ids.contains($0.key) }
    }

    func refreshNoteAppearance() {
        let signature = (UserDefaults.standard.string(forKey: "notesTheme") ?? "system")
            + ":" + NSApp.effectiveAppearance.name.rawValue
        guard signature != noteAppearanceSignature else { return }
        noteAppearanceSignature = signature
        NotesAppIcon.refresh()
        panel?.appearance = NotesTheme.appearance()
        renderedNotes.removeAll()
        syncNotes(quietly: true)
    }

    func presentNotesError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "闪念操作未完成"
        alert.informativeText = error.localizedDescription + "\n文件保留在：" + LaunchOptions.directory.path
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func setUpApplicationMenu() {
        let main = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu(title: LaunchOptions.appName)
        appMenu.addItem(ClosureMenuItem("闪念设置…", key: ",") { [weak self] in self?.workspace.showSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem("退出 " + LaunchOptions.appName, key: "q") { NSApp.terminate(nil) })
        app.submenu = appMenu
        main.addItem(app)
        let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(ClosureMenuItem("新建闪念", key: "n") { [weak self] in self?.workspace.newNote() })
        fileMenu.addItem(ClosureMenuItem("全部闪念", key: "f") { [weak self] in self?.workspace.showLibrary() })
        fileMenu.addItem(ClosureMenuItem("显示或收起挂绳", key: "L") { [weak self] in self?.toggle() })
        fileMenu.addItem(.separator())
        fileMenu.addItem(ClosureMenuItem("收起当前窗口", key: "w") { NSApp.keyWindow?.performClose(nil) })
        file.submenu = fileMenu
        main.addItem(file)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        let commands: [(String, Selector, String)] = [
            ("撤销", Selector(("undo:")), "z"), ("重做", Selector(("redo:")), "Z"),
            ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")
        ]
        for (title, action, key) in commands { editMenu.addItem(withTitle: title, action: action, keyEquivalent: key) }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }
}
