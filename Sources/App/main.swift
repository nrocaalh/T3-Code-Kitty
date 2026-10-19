import AppKit
import SwiftUI
import Combine
import ServiceManagement
import KittyCore

// MARK: - Model

@MainActor
final class CatModel: ObservableObject {
    @Published var review: [T3Thread] = []
    @Published var runningCount = 0
    @Published var t3Running = true
    @Published var hasSnapshot = false
    @Published var celebrateUntil = Date.distantPast
    @Published var finishingUntil = Date.distantPast
    @Published var bubbleMutedUntil = Date.distantPast
    @Published var acknowledgedKeys: Set<String> {
        didSet { UserDefaults.standard.set(Array(acknowledgedKeys), forKey: KittyDefaults.acknowledgedReviewKeys) }
    }
    @Published var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: KittyDefaults.alertsEnabled) }
    }
    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: KittyDefaults.soundEnabled) }
    }

    weak var panel: NSPanel?
    var openT3: (@MainActor () -> Void)?
    var refreshHandler: (@MainActor () -> Void)?

    init() {
        let defaults = UserDefaults.standard
        alertsEnabled = defaults.object(forKey: KittyDefaults.alertsEnabled) as? Bool ?? true
        soundEnabled = defaults.object(forKey: KittyDefaults.soundEnabled) as? Bool ?? true
        acknowledgedKeys = Set(defaults.stringArray(forKey: KittyDefaults.acknowledgedReviewKeys) ?? [])
        defaults.removeObject(forKey: KittyDefaults.legacyAcknowledgementUntil)
        defaults.removeObject(forKey: KittyDefaults.legacyReviewedEpisodes)
    }

    var unreviewedReview: [T3Thread] {
        review.filter { !$0.isReviewedByVisit && !acknowledgedKeys.contains($0.alertKey) }
    }

    var reviewedReview: [T3Thread] {
        review.filter(\.isReviewedByVisit)
    }

    var showBubble: Bool {
        !unreviewedReview.isEmpty && Date() >= bubbleMutedUntil && alertsEnabled
    }

    var bubbleHeadline: String {
        L10n.shared.p("bubble.review", unreviewedReview.count)
    }

    var bubbleSubtitle: String? {
        let list = unreviewedReview
        guard let first = list.first else { return nil }
        if list.count == 1 {
            let project = first.projectTitle.isEmpty ? "" : "\(first.projectTitle) · "
            return shorten(project + first.title, limit: 46)
        }
        return L10n.shared.t("bubble.open")
    }

    var statusLine: String {
        let l = L10n.shared
        guard t3Running else { return l.t("status.closed") }
        guard hasSnapshot else { return l.t("status.waiting") }
        let pending = unreviewedReview
        if pending.isEmpty {
            return runningCount > 0 ? l.p("status.working", runningCount) : l.t("status.allgood")
        }
        let reviewText = l.p("status.review", pending.count)
        if runningCount > 0 {
            return "\(reviewText) · " + l.p("status.working", runningCount)
        }
        return reviewText
    }

    func mood(at now: Date) -> CatMood {
        guard t3Running else { return .sleeping }
        if now < finishingUntil { return .finishing }
        if runningCount > 0 { return .working }
        if !unreviewedReview.isEmpty { return .alert }
        return .idle
    }

    var showWorkingPill: Bool {
        t3Running && !showBubble && runningCount > 0
    }

    func dismissFinalized() {
        guard !unreviewedReview.isEmpty else { return }
        acknowledgedKeys.formUnion(unreviewedReview.map(\.alertKey))
        finishingUntil = Date.distantPast
    }

    func catTapped() {
        dismissFinalized()
        openT3?()
    }

    func bubbleTapped() {
        dismissFinalized()
        openT3?()
    }

    func requestRefresh() {
        refreshHandler?()
    }

    var isDragging = false

    func clamped(_ origin: CGPoint) -> CGPoint {
        guard let panel else { return origin }
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return origin }
        return CGPoint(
            x: min(max(origin.x, visible.minX - 30), visible.maxX - size.width + 30),
            y: min(max(origin.y, visible.minY - 20), visible.maxY - size.height + 20)
        )
    }

    func savePosition() {
        guard let panel else { return }
        let origin = panel.frame.origin
        UserDefaults.standard.set(origin.x, forKey: KittyDefaults.catX)
        UserDefaults.standard.set(origin.y, forKey: KittyDefaults.catY)
    }

    func resetPosition() {
        guard let panel, let visible = NSScreen.main?.visibleFrame else { return }
        let origin = CGPoint(
            x: visible.maxX - panel.frame.width - 22,
            y: visible.minY + 4
        )
        panel.setFrameOrigin(origin)
        savePosition()
    }

    private func shorten(_ value: String, limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
    }
}

// MARK: - Panel

final class CatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = CatModel()
    private var panel: CatPanel!
    private var statusItem: NSStatusItem!
    private var watcher: T3Watcher!
    private var hitTestTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var didLoadSnapshot = false
    private var previousUnreviewedKeys = Set<String>()
    private var lastFingerprint = ""

    private let t3BundleID = "com.t3tools.t3code"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: L10n.shared.t("activity.reason")
        )

        createPanel()
        createStatusItem()

        watcher = T3Watcher()
        model.refreshHandler = { [weak self] in
            guard let watcher = self?.watcher else { return }
            Task { await watcher.refreshNow() }
        }
        let startedWatcher = watcher
        if let startedWatcher {
            Task {
                await startedWatcher.start(onUpdate: { [weak self] snapshot in
                    Task { @MainActor [weak self] in self?.apply(snapshot) }
                })
            }
        }

        startHitTestTimer()
        removeLegacyLoginItem()
        KittyLog.write("T3 Code Kitty started")
        model.resetPositionIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        KittyLog.write("T3 Code Kitty stopped")
    }

    // MARK: Setup

    private func createPanel() {
        let size = NSSize(width: 260, height: 280)
        let origin = model.savedOrigin(size: size)
        panel = CatPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: CatView(model: model))
        panel.orderFrontRegardless()
        model.panel = panel
        model.openT3 = { [weak self] in self?.openT3() }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "T3 Code Kitty")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 11, weight: .bold)
            button.toolTip = "T3 Code Kitty"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func startHitTestTimer() {
        hitTestTask?.cancel()
        hitTestTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                guard let self else { return }
                self.updateHitTest()
            }
        }
    }

    private func updateHitTest() {
        if model.bubbleMutedUntil != .distantPast, model.bubbleMutedUntil <= Date() {
            model.bubbleMutedUntil = .distantPast
        }
        guard let panel else { return }
        if model.isDragging {
            panel.ignoresMouseEvents = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let catRect = NSRect(x: frame.minX + 28, y: frame.minY - 2, width: 204, height: 204)
        let bubbleRect = NSRect(x: frame.minX + 8, y: frame.maxY - 122, width: 244, height: 122)
        let topVisible = model.showBubble || model.showWorkingPill
        let inside = catRect.contains(mouse) || (topVisible && bubbleRect.contains(mouse))
        panel.ignoresMouseEvents = !inside
    }

    // MARK: State

    private func apply(_ snapshot: T3Snapshot?) {
        let running = t3IsRunning()
        let threads = snapshot?.threads ?? []
        let review = threads
            .filter(\.needsReview)
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        let runningThreads = threads.filter(\.isRunning)
        let visitSignature = review
            .map { "\($0.id):\($0.lastVisitedAt?.timeIntervalSince1970 ?? 0)" }
            .joined(separator: ",")
        let fingerprint = "\(running)|\(snapshot != nil)|\(review.map(\.alertKey).joined(separator: ","))|\(runningThreads.count)|\(visitSignature)"
        if fingerprint == lastFingerprint {
            return
        }
        lastFingerprint = fingerprint
        model.t3Running = running

        guard running else {
            model.review = []
            model.runningCount = 0
            model.hasSnapshot = false
            updateStatusItem()
            return
        }

        guard let snapshot else {
            model.review = []
            model.runningCount = 0
            model.hasSnapshot = false
            updateStatusItem()
            return
        }

        model.review = review
        model.runningCount = runningThreads.count
        model.hasSnapshot = true
        model.acknowledgedKeys = model.acknowledgedKeys.intersection(Set(review.map(\.alertKey)))

        let unreviewedKeys = Set(model.unreviewedReview.map(\.alertKey))
        if !didLoadSnapshot {
            didLoadSnapshot = true
            previousUnreviewedKeys = unreviewedKeys
        } else {
            let newKeys = unreviewedKeys.subtracting(previousUnreviewedKeys)
            previousUnreviewedKeys = unreviewedKeys
            if !newKeys.isEmpty, model.alertsEnabled {
                model.finishingUntil = Date().addingTimeInterval(1.4)
                model.celebrateUntil = Date().addingTimeInterval(1.7)
                model.bubbleMutedUntil = .distantPast
                if model.soundEnabled {
                    NSSound(named: NSSound.Name("Glass"))?.play()
                }
            }
        }

        KittyLog.write("apply seq=\(snapshot.sequence) review=\(review.count) pending=\(model.unreviewedReview.count) running=\(runningThreads.count) t3=\(running)")
        updateStatusItem()
    }

    private func t3IsRunning() -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: t3BundleID).isEmpty {
            return true
        }
        return NSWorkspace.shared.runningApplications.contains {
            ($0.localizedName ?? "").hasPrefix("T3 Code")
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let count = model.unreviewedReview.count
        button.title = count > 0 ? " \(count)" : ""
        button.appearsDisabled = !model.t3Running
        button.toolTip = "T3 Code Kitty — \(model.statusLine)"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let l = L10n.shared

        let summary = NSMenuItem(title: model.statusLine, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let open = NSMenuItem(title: l.t("menu.open"), action: #selector(openT3Action), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let pending = model.unreviewedReview
        if !pending.isEmpty {
            let parent = NSMenuItem(title: l.t("menu.pending"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for thread in pending.prefix(8) {
                let item = NSMenuItem(title: thread.title, action: #selector(openT3Action), keyEquivalent: "")
                item.target = self
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)

            let muted = model.bubbleMutedUntil > Date()
            let mute = NSMenuItem(
                title: muted ? l.t("menu.unmute") : l.t("menu.mute"),
                action: #selector(muteAction),
                keyEquivalent: ""
            )
            mute.target = self
            menu.addItem(mute)
        }

        let reviewed = model.reviewedReview
        if !reviewed.isEmpty {
            let parent = NSMenuItem(title: l.p("menu.reviewed", reviewed.count), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for thread in reviewed.prefix(8) {
                let item = NSMenuItem(title: thread.title, action: #selector(openT3Action), keyEquivalent: "")
                item.target = self
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }

        menu.addItem(.separator())

        let alerts = NSMenuItem(title: l.t("menu.alerts"), action: #selector(toggleAlerts), keyEquivalent: "")
        alerts.target = self
        alerts.state = model.alertsEnabled ? .on : .off
        menu.addItem(alerts)

        let sound = NSMenuItem(title: l.t("menu.sound"), action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = model.soundEnabled ? .on : .off
        menu.addItem(sound)

        let langParent = NSMenuItem(title: l.t("menu.language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in AppLanguage.allCases {
            let item = NSMenuItem(title: lang == .es ? "Español" : "English", action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = L10n.shared.language == lang ? .on : .off
            langMenu.addItem(item)
        }
        langParent.submenu = langMenu
        menu.addItem(langParent)

        let login = NSMenuItem(title: l.t("menu.login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemInstalled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let reset = NSMenuItem(title: l.t("menu.resetPos"), action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let refresh = NSMenuItem(title: l.t("menu.refresh"), action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: l.t("menu.quit"), action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = AppLanguage(rawValue: raw) else { return }
        L10n.shared.language = lang
        model.objectWillChange.send()
        updateStatusItem()
    }

    @objc private func openT3Action() { openT3() }
    @objc private func refreshAction() {
        guard let watcher else { return }
        Task { await watcher.refreshNow() }
    }

    @objc private func muteAction() {
        if model.bubbleMutedUntil > Date() {
            model.bubbleMutedUntil = .distantPast
        } else {
            model.bubbleMutedUntil = Date().addingTimeInterval(900)
        }
    }

    @objc private func toggleAlerts() {
        model.alertsEnabled.toggle()
    }

    @objc private func toggleSound() {
        model.soundEnabled.toggle()
    }

    @objc private func resetPosition() {
        model.resetPosition()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func openT3() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t3BundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                if let error { self?.kittyOpenFailure(error) }
            }
            return
        }
        // Fall back to the registered URL scheme before any hardcoded path.
        if let scheme = URL(string: "t3code://"), NSWorkspace.shared.open(scheme) { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let fallback = URL(fileURLWithPath: "/Applications/T3 Code (Alpha).app")
        NSWorkspace.shared.openApplication(at: fallback, configuration: configuration) { [weak self] _, error in
            if let error { self?.kittyOpenFailure(error) }
        }
    }

    private func kittyOpenFailure(_ error: Error) {
        KittyLog.write("Failed to open T3 Code: \(error.localizedDescription)")
    }

    // MARK: Login item

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.t3codekitty.app.plist")
    }

    private var loginItemInstalled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func removeLegacyLoginItem() {
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }
        try? FileManager.default.removeItem(at: agentURL)
        KittyLog.write("Removed legacy LaunchAgent login item")
    }

    @objc private func toggleLoginItem() {
        do {
            if loginItemInstalled {
                try SMAppService.mainApp.unregister()
                KittyLog.write("Login item removed")
            } else {
                removeLegacyLoginItem()
                try SMAppService.mainApp.register()
                KittyLog.write("Login item installed")
            }
        } catch {
            KittyLog.write("Failed to toggle login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

extension CatModel {
    func savedOrigin(size: NSSize) -> CGPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: KittyDefaults.catX) != nil, defaults.object(forKey: KittyDefaults.catY) != nil {
            let point = CGPoint(
                x: defaults.double(forKey: KittyDefaults.catX),
                y: defaults.double(forKey: KittyDefaults.catY)
            )
            let rect = CGRect(origin: point, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                return point
            }
        }
        return defaultOrigin(size: size)
    }

    func resetPositionIfNeeded() {
        guard let panel else { return }
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { return }
        let origin = defaultOrigin(size: panel.frame.size)
        panel.setFrameOrigin(origin)
        savePosition()
    }

    private func defaultOrigin(size: NSSize) -> CGPoint {
        let visible = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: visible.maxX - size.width - 22, y: visible.minY + 4)
    }
}

// MARK: - Entry point

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
