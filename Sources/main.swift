import AppKit
import SwiftUI
import Combine

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
        didSet { UserDefaults.standard.set(Array(acknowledgedKeys), forKey: "acknowledgedReviewKeys") }
    }
    @Published var alertsEnabled: Bool {
        didSet { UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled") }
    }
    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    weak var panel: NSPanel?
    var openT3: (() -> Void)?
    var refreshHandler: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        alertsEnabled = defaults.object(forKey: "alertsEnabled") as? Bool ?? true
        soundEnabled = defaults.object(forKey: "soundEnabled") as? Bool ?? true
        acknowledgedKeys = Set(defaults.stringArray(forKey: "acknowledgedReviewKeys") ?? [])
        defaults.removeObject(forKey: "acknowledgementUntil")
        defaults.removeObject(forKey: "reviewedEpisodes")
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
        let list = unreviewedReview
        return list.count == 1 ? "1 sesión para revisar" : "\(list.count) sesiones para revisar"
    }

    var bubbleSubtitle: String? {
        let list = unreviewedReview
        guard let first = list.first else { return nil }
        if list.count == 1 {
            let project = first.projectTitle.isEmpty ? "" : "\(first.projectTitle) · "
            return shorten(project + first.title, limit: 46)
        }
        return "Toca para abrir T3 Code"
    }

    var statusLine: String {
        guard t3Running else { return "T3 Code está cerrado" }
        guard hasSnapshot else { return "Esperando datos de T3 Code…" }
        let pending = unreviewedReview
        if pending.isEmpty {
            return runningCount > 0 ? "\(runningCount) trabajando" : "Todo al día"
        }
        let reviewText = pending.count == 1 ? "1 por revisar" : "\(pending.count) por revisar"
        if runningCount > 0 {
            return "\(reviewText) · \(runningCount) trabajando"
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
        let mood = mood(at: Date())
        if mood == .alert || mood == .finishing { dismissFinalized() }
        openT3?()
    }

    func bubbleTapped() {
        let mood = mood(at: Date())
        if mood == .alert || mood == .finishing { dismissFinalized() }
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
        UserDefaults.standard.set(origin.x, forKey: "catX")
        UserDefaults.standard.set(origin.y, forKey: "catY")
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
    private var hitTimer: Timer?
    private var activity: NSObjectProtocol?
    private var didLoadSnapshot = false
    private var previousUnreviewedKeys = Set<String>()
    private var lastFingerprint = ""

    private let t3BundleID = "com.t3tools.t3code"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled],
            reason: "Mostrar el estado de T3 Code en el escritorio"
        )

        createPanel()
        createStatusItem()
        model.refreshHandler = { [weak self] in self?.watcher.refreshNow() }

        watcher = T3Watcher()
        watcher.onUpdate = { [weak self] snapshot in
            MainActor.assumeIsolated {
                self?.apply(snapshot)
            }
        }
        watcher.start()

        startHitTestTimer()
        Log.write("T3 Code Kitty iniciado")
        model.resetPositionIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        Log.write("T3 Code Kitty terminado")
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
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHitTest()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hitTimer = timer
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

        Log.write("apply seq=\(snapshot.sequence) review=\(review.count) pending=\(model.unreviewedReview.count) running=\(runningThreads.count) t3=\(running)")
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

        let summary = NSMenuItem(title: model.statusLine, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Abrir T3 Code", action: #selector(openT3Action), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let pending = model.unreviewedReview
        if !pending.isEmpty {
            let parent = NSMenuItem(title: "Sesiones por revisar", action: nil, keyEquivalent: "")
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
                title: muted ? "Mostrar burbuja ahora" : "Silenciar burbuja 15 min",
                action: #selector(muteAction),
                keyEquivalent: ""
            )
            mute.target = self
            menu.addItem(mute)
        }

        let reviewed = model.reviewedReview
        if !reviewed.isEmpty {
            let parent = NSMenuItem(title: "Revisadas (\(reviewed.count))", action: nil, keyEquivalent: "")
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

        let alerts = NSMenuItem(title: "Avisos", action: #selector(toggleAlerts), keyEquivalent: "")
        alerts.target = self
        alerts.state = model.alertsEnabled ? .on : .off
        menu.addItem(alerts)

        let sound = NSMenuItem(title: "Sonido", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self
        sound.state = model.soundEnabled ? .on : .off
        menu.addItem(sound)

        let login = NSMenuItem(title: "Abrir al iniciar sesión", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemInstalled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let reset = NSMenuItem(title: "Reiniciar posición", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let refresh = NSMenuItem(title: "Actualizar ahora", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Salir de T3 Code Kitty", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func openT3Action() { openT3() }
    @objc private func refreshAction() { watcher.refreshNow() }

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
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t3BundleID)
            ?? URL(fileURLWithPath: "/Applications/T3 Code (Alpha).app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Log.write("No se pudo abrir T3 Code: \(error.localizedDescription)") }
        }
    }

    // MARK: Login item

    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.t3codekitty.app.plist")
    }

    private var loginItemInstalled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    @objc private func toggleLoginItem() {
        if loginItemInstalled {
            try? FileManager.default.removeItem(at: agentURL)
            return
        }
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": "com.t3codekitty.app",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        do {
            try FileManager.default.createDirectory(
                at: agentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL)
            Log.write("Login item instalado")
        } catch {
            Log.write("No se pudo instalar el login item: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

extension CatModel {
    func savedOrigin(size: NSSize) -> CGPoint {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "catX") != nil, defaults.object(forKey: "catY") != nil {
            let point = CGPoint(
                x: defaults.double(forKey: "catX"),
                y: defaults.double(forKey: "catY")
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

enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/T3CodeKitty.log")
    private static let queue = DispatchQueue(label: "com.t3codekitty.app.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        queue.async {
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
