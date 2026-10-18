import SwiftUI
import AppKit
import QuartzCore
import KittyCore

enum CatMood {
    case sleeping
    case idle
    case working
    case finishing
    case alert
}

@MainActor
struct CatView: View {
    @ObservedObject var model: CatModel
    @ObservedObject private var l10n = L10n.shared

    private let panelWidth: CGFloat = 260
    private let panelHeight: CGFloat = 280
    private let catSize: CGFloat = 200

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            CatSurface(model: model)
                .frame(width: catSize, height: catSize)
                .position(x: panelWidth / 2, y: panelHeight - catSize / 2)

            VStack(spacing: 0) {
                if model.showBubble {
                    BubbleView(
                        headline: model.bubbleHeadline,
                        subtitle: model.bubbleSubtitle,
                        count: model.unreviewedReview.count,
                        followLine: model.runningCount > 0 ? l10n.p("bubble.follow", model.runningCount) : nil
                    )
                    .onTapGesture { model.bubbleTapped() }
                    .transition(.scale(scale: 0.88, anchor: .bottom).combined(with: .opacity))
                } else if model.showWorkingPill {
                    WorkingPill(label: l10n.p("status.working", model.runningCount))
                        .onTapGesture { model.catTapped() }
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 5)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.showBubble)
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(Color.clear)
        .onAppear { model.requestRefresh() }
    }
}

// MARK: - Bubble

@MainActor
struct BubbleView: View {
    let headline: String
    let subtitle: String?
    let count: Int
    let followLine: String?

    private let bubbleColor = Color(red: 0.13, green: 0.11, blue: 0.16).opacity(0.95)

    var body: some View {
        VStack(spacing: -1) {
            HStack(alignment: .center, spacing: 9) {
                ZStack {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.49, blue: 0.26))
                        .frame(width: 30, height: 30)
                    Text("\(max(count, 1))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let followLine {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(red: 0.36, green: 0.58, blue: 1.0))
                                .frame(width: 5, height: 5)
                            Text(followLine)
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: 238)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(bubbleColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.30), radius: 9, y: 4)

            BubbleTail()
                .fill(bubbleColor)
                .frame(width: 13, height: 7)
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(headline). \(subtitle ?? "")")
    }
}

@MainActor
struct WorkingPill: View {
    let label: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(red: 0.36, green: 0.58, blue: 1.0))
                .frame(width: 7, height: 7)
                .opacity(pulse ? 1.0 : 0.30)
                .scaleEffect(pulse ? 1.0 : 0.72)
                .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.09, green: 0.12, blue: 0.20).opacity(0.93))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color(red: 0.36, green: 0.58, blue: 1.0).opacity(0.40), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 7, y: 3)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.midX + 1, y: rect.maxY * 0.65)
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - AppKit surface

struct CatSurface: NSViewRepresentable {
    let model: CatModel

    func makeNSView(context: Context) -> CatNSView {
        let view = CatNSView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: CatNSView, context: Context) {
        nsView.model = model
    }
}

final class CatNSView: NSView {
    weak var model: CatModel?
    private var renderTask: Task<Void, Never>?
    private var occlusionObserver: NSObjectProtocol?
    private var startedAt = CACurrentMediaTime()
    private var badgeCache: [String: NSImage] = [:]
    private var generatedCache: [String: NSImage?] = [:]
    private var generatedChecked = false
    private var generatedAvailable = false
    private var noteImage: NSImage?
    private var zImages: [NSImage] = []
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var didDrag = false
    private var tickCount = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        let status = model?.statusLine ?? ""
        return status.isEmpty ? L10n.shared.t("a11y.cat.label") : "\(L10n.shared.t("a11y.cat.label")): \(status)"
    }
    override func accessibilityHelp() -> String? { L10n.shared.t("a11y.cat.help") }
    override func accessibilityPerformPress() -> Bool {
        model?.catTapped()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if window == nil {
            stopRenderLoop()
        } else {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.window?.occlusionState.contains(.visible) == true {
                        self.startRenderLoop()
                    } else {
                        self.stopRenderLoop()
                    }
                }
            }
            startRenderLoop()
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        renderTask?.cancel()
    }

    private func stopRenderLoop() {
        renderTask?.cancel()
        renderTask = nil
    }

    private func startRenderLoop() {
        stopRenderLoop()
        guard window?.occlusionState.contains(.visible) == true else { return }
        renderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.window?.occlusionState.contains(.visible) == true else {
                    self?.renderTask = nil
                    return
                }
                self.tickCount += 1
                let mood = self.model?.mood(at: Date()) ?? .idle
                let every: Int
                switch mood {
                case .alert, .working, .finishing: every = 1
                case .idle: every = 2
                case .sleeping: every = 3
                }
                if self.tickCount % every == 0 {
                    self.needsDisplay = true
                }
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let period: UInt64 = reduceMotion ? 500_000_000 : 66_666_667 * UInt64(every)
                try? await Task.sleep(nanoseconds: period)
            }
        }
    }

    // MARK: Mouse / drag

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startMouse = dragStartMouse, let startOrigin = dragStartOrigin, let model else {
            return
        }
        let mouse = NSEvent.mouseLocation
        if !didDrag {
            if hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) < 4 { return }
            didDrag = true
            model.isDragging = true
        }
        let origin = NSPoint(
            x: startOrigin.x + (mouse.x - startMouse.x),
            y: startOrigin.y + (mouse.y - startMouse.y)
        )
        window.setFrameOrigin(model.clamped(origin))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartMouse = nil
            dragStartOrigin = nil
        }
        guard let model else { return }
        if didDrag {
            model.isDragging = false
            model.savePosition()
        } else {
            model.catTapped()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)

        let scale = min(bounds.width, bounds.height) / 200.0
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineJoin(.round)

        let now = CACurrentMediaTime()
        let time = now - startedAt
        if !drawGenerated(ctx: ctx, time: time) {
            drawCat(ctx: ctx, time: time, now: now)
        }
        ctx.restoreGState()
    }

    private func generatedImage(_ name: String) -> NSImage? {
        if let cached = generatedCache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            generatedCache[name] = .some(nil)
            return nil
        }
        let image = NSImage(contentsOf: url)
        generatedCache[name] = .some(image)
        return image
    }

    private func checkGeneratedAssets() {
        guard !generatedChecked else { return }
        generatedChecked = true
        generatedAvailable = ["cat_idle", "cat_working", "cat_alert", "cat_sleep"]
            .allSatisfy { generatedImage($0) != nil }
    }

    private func drawGenerated(ctx: CGContext, time: TimeInterval) -> Bool {
        checkGeneratedAssets()
        guard generatedAvailable, let model else { return false }

        let mood = model.mood(at: Date())
        let name: String
        switch mood {
        case .idle: name = "cat_idle"
        case .working: name = "cat_working"
        case .finishing: name = "cat_alert"
        case .alert: name = "cat_alert"
        case .sleeping: name = "cat_sleep"
        }
        guard let image = generatedImage(name) else { return false }

        let remaining = model.celebrateUntil.timeIntervalSinceNow
        var bounce: CGFloat = 0
        if remaining > 0 {
            let decay = CGFloat(min(1, remaining / 1.5))
            bounce = -abs(CGFloat(sin(time * 7.0))) * 13 * decay
        }

        if mood == .sleeping {
            fill(ctx, CGPath(ellipseIn: CGRect(x: 32, y: 189, width: 136, height: 7), transform: nil),
                 NSColor.black.withAlphaComponent(0.14))
        } else {
            fill(ctx, CGPath(ellipseIn: CGRect(x: 54, y: 187, width: 92, height: 9), transform: nil),
                 NSColor.black.withAlphaComponent(0.15))
        }

        ctx.saveGState()
        switch mood {
        case .idle:
            let breath = CGFloat(sin(time * 1.6))
            ctx.translateBy(x: 100, y: 200)
            ctx.scaleBy(x: 1.0 + 0.004 * breath, y: 1.0 + 0.012 * breath)
            ctx.translateBy(x: -100, y: -200)
            ctx.translateBy(x: 0, y: 0.7 * breath)
        case .working:
            ctx.translateBy(x: CGFloat(sin(time * 4.5)) * 0.5, y: CGFloat(sin(time * 6.0)) * 2.0)
        case .finishing:
            let decay = CGFloat(min(1, max(0, model.finishingUntil.timeIntervalSinceNow / 1.4)))
            let hop = -abs(CGFloat(sin(time * 9.0))) * 18 * (0.35 + 0.65 * decay)
            ctx.translateBy(x: 0, y: hop)
        case .alert:
            ctx.translateBy(x: 0, y: bounce + CGFloat(sin(time * 2.0)) * 0.6)
        case .sleeping:
            let breath = CGFloat(sin(time * 1.2))
            ctx.translateBy(x: 100, y: 200)
            ctx.scaleBy(x: 1.0 + 0.002 * breath, y: 1.0 + 0.008 * breath)
            ctx.translateBy(x: -100, y: -200)
        }

        let rect: CGRect
        if mood == .sleeping {
            let w: CGFloat = 196
            let h = w * image.size.height / max(image.size.width, 1)
            rect = CGRect(x: (200 - w) / 2, y: 200 - h, width: w, height: h)
        } else {
            let h: CGFloat = 196
            let w = h * image.size.width / max(image.size.height, 1)
            rect = CGRect(x: (200 - w) / 2, y: 200 - h, width: w, height: h)
        }
        draw(image: image, in: rect)

        switch mood {
        case .idle:
            drawBlinkIfNeeded(ctx: ctx, time: time, imageRect: rect)
        case .working:
            drawTypingOverlay(ctx: ctx, time: time, imageRect: rect)
        case .finishing:
            let decay = CGFloat(min(1, max(0, model.finishingUntil.timeIntervalSinceNow / 1.4)))
            drawSparkles(ctx: ctx, alpha: decay)
        case .sleeping:
            drawSleepZzz(ctx: ctx, time: time, imageRect: rect)
        case .alert:
            break
        }

        if mood != .sleeping {
            let shownReview = model.unreviewedReview
            if !shownReview.isEmpty {
                let badge = badgeImage(count: shownReview.count, color: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.22, alpha: 1))
                draw(image: badge, in: CGRect(x: 134, y: 36, width: 34, height: 34))
            }
        }

        ctx.restoreGState()
        return true
    }

    private func drawBlinkIfNeeded(ctx: CGContext, time: TimeInterval, imageRect: CGRect) {
        let cycle = time.truncatingRemainder(dividingBy: 4.8)
        guard cycle < 0.12 else { return }
        let fur = NSColor(srgbRed: 0.95, green: 0.63, blue: 0.30, alpha: 1)
        let ink = NSColor(srgbRed: 0.23, green: 0.17, blue: 0.15, alpha: 1)
        for nx in [0.314, 0.561] {
            let center = CGPoint(
                x: imageRect.minX + imageRect.width * nx,
                y: imageRect.minY + imageRect.height * 0.293
            )
            let eye = CGRect(
                x: center.x - imageRect.width * 0.082,
                y: center.y - imageRect.height * 0.064,
                width: imageRect.width * 0.164,
                height: imageRect.height * 0.128
            )
            fill(ctx, CGPath(ellipseIn: eye, transform: nil), fur)
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: center.x - imageRect.width * 0.060, y: center.y))
            lid.addQuadCurve(
                to: CGPoint(x: center.x + imageRect.width * 0.060, y: center.y),
                control: CGPoint(x: center.x, y: center.y + imageRect.height * 0.022)
            )
            stroke(ctx, lid, ink, 2.6)
        }
    }

    private func drawTypingOverlay(ctx: CGContext, time: TimeInterval, imageRect: CGRect) {
        let x0 = imageRect.minX + imageRect.width * 0.375
        let x1 = imageRect.minX + imageRect.width * 0.850
        let y0 = imageRect.minY + imageRect.height * 0.690
        let y1 = imageRect.minY + imageRect.height * 0.885

        let screen = CGMutablePath()
        screen.move(to: CGPoint(x: x0 + 3, y: y0 + 3))
        screen.addLine(to: CGPoint(x: x1 - 3, y: y0))
        screen.addLine(to: CGPoint(x: x1 - 1, y: y1))
        screen.addLine(to: CGPoint(x: x0 + 6, y: y1 + 1))
        screen.closeSubpath()

        ctx.saveGState()
        ctx.addPath(screen)
        ctx.clip()
        let span = max(1, y1 - y0 - 4)
        for index in 0..<4 {
            let travel = (time * 18.0 + Double(index) * 9.0).truncatingRemainder(dividingBy: Double(span))
            let barY = y0 + 4 + CGFloat(travel)
            let barWidth = (x1 - x0 - 18) * (0.28 + 0.12 * CGFloat(index % 3))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.13).cgColor)
            ctx.fill(CGRect(x: x0 + 8 + CGFloat(index % 2) * 9, y: barY, width: barWidth, height: 1.6))
        }
        let scanY = y0 + 3 + CGFloat((time * 15.0).truncatingRemainder(dividingBy: Double(span)))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.fill(CGRect(x: x0 + 4, y: scanY, width: x1 - x0 - 10, height: 2.2))
        if Int(time * 2.2) % 2 == 0 {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.65).cgColor)
            ctx.fill(CGRect(x: x0 + 8, y: y1 - 7, width: 6, height: 2.2))
        }
        ctx.restoreGState()

        let tap = CGFloat(max(0, sin(time * 7.0)))
        ctx.setStrokeColor(NSColor(srgbRed: 1.0, green: 0.86, blue: 0.42, alpha: 0.30 + 0.50 * tap).cgColor)
        ctx.setLineWidth(2.2)
        ctx.setLineCap(.round)
        for (tx, ty) in [(0.50, 0.925), (0.62, 0.915), (0.74, 0.905)] {
            let x = imageRect.minX + imageRect.width * CGFloat(tx)
            let y = imageRect.minY + imageRect.height * CGFloat(ty)
            ctx.move(to: CGPoint(x: x - 4, y: y))
            ctx.addLine(to: CGPoint(x: x + 4, y: y - 2 - tap * 2))
            ctx.strokePath()
        }
    }

    private func drawSleepZzz(ctx: CGContext, time: TimeInterval, imageRect: CGRect) {
        for index in 0..<3 {
            let phase = CGFloat((time * 0.22 + Double(index) / 3.0).truncatingRemainder(dividingBy: 1.0))
            let image = zImage(index: index)
            ctx.saveGState()
            ctx.setAlpha(0.66 * (1.0 - phase))
            draw(image: image, in: CGRect(
                x: 148 + CGFloat(index) * 7 + phase * 9,
                y: 62 - phase * 24,
                width: image.size.width,
                height: image.size.height
            ))
            ctx.restoreGState()
        }
    }

    private func drawSparkles(ctx: CGContext, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha * 0.9)
        for (x, y, size) in ([(54.0, 44.0, 5.0), (151.0, 78.0, 4.0), (38.0, 120.0, 3.5), (164.0, 147.0, 4.5)] as [(CGFloat, CGFloat, CGFloat)]) {
            let star = CGMutablePath()
            star.move(to: CGPoint(x: x, y: y - size))
            star.addQuadCurve(to: CGPoint(x: x + size, y: y), control: CGPoint(x: x + size * 0.2, y: y - size * 0.2))
            star.addQuadCurve(to: CGPoint(x: x, y: y + size), control: CGPoint(x: x + size * 0.2, y: y + size * 0.2))
            star.addQuadCurve(to: CGPoint(x: x - size, y: y), control: CGPoint(x: x - size * 0.2, y: y + size * 0.2))
            star.addQuadCurve(to: CGPoint(x: x, y: y - size), control: CGPoint(x: x - size * 0.2, y: y - size * 0.2))
            fill(ctx, star, NSColor(srgbRed: 1.0, green: 0.82, blue: 0.35, alpha: 1))
        }
        ctx.restoreGState()
    }

    private func drawCat(ctx: CGContext, time: TimeInterval, now: CFTimeInterval) {
        guard let model else { return }

        let mood = model.mood(at: Date())
        let breathing = CGFloat(sin(time * 1.8)) * 0.5
        let blinkCycle = time.truncatingRemainder(dividingBy: 4.6)
        let blinking = blinkCycle < 0.11 || (blinkCycle > 0.19 && blinkCycle < 0.30)
        let sleeping = mood == .sleeping
        let finishing = mood == .finishing
        let alert = mood == .alert || finishing
        let working = mood == .working

        let celebrateRemaining = model.celebrateUntil.timeIntervalSinceNow
        let celebrating = celebrateRemaining > 0
        var bounce: CGFloat = 0
        if celebrating {
            let decay = CGFloat(min(1, celebrateRemaining / 1.5))
            bounce = -abs(CGFloat(sin(time * 7.0))) * 13 * decay
        }
        let finishRemaining = model.finishingUntil.timeIntervalSinceNow
        if finishRemaining > 0 {
            let decay = CGFloat(min(1, finishRemaining / 1.4))
            bounce = -abs(CGFloat(sin(time * 9.0))) * 18 * (0.35 + 0.65 * decay)
        }

        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounce)

        let orange = NSColor(srgbRed: 0.96, green: 0.67, blue: 0.38, alpha: 1)
        let orangeMid = NSColor(srgbRed: 0.90, green: 0.56, blue: 0.27, alpha: 1)
        let orangeDark = NSColor(srgbRed: 0.78, green: 0.43, blue: 0.18, alpha: 1)
        let cream = NSColor(srgbRed: 1.0, green: 0.92, blue: 0.80, alpha: 1)
        let pink = NSColor(srgbRed: 0.95, green: 0.58, blue: 0.58, alpha: 1)
        let ink = NSColor(srgbRed: 0.23, green: 0.17, blue: 0.15, alpha: 1)
        let blue = NSColor(srgbRed: 0.29, green: 0.45, blue: 0.93, alpha: 1)

        // Shadow.
        fill(ctx, CGPath(ellipseIn: CGRect(x: 55, y: 184, width: 90, height: 11), transform: nil),
             NSColor.black.withAlphaComponent(0.16))

        // Tail.
        let tailSpeed = alert ? 2.8 : (working ? 2.2 : 1.15)
        let sway = CGFloat(sin(time * tailSpeed)) * (alert ? 8 : 5)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 132, y: 170))
        tail.addCurve(
            to: CGPoint(x: 180 + sway, y: 136 + breathing * 0.4),
            control1: CGPoint(x: 170, y: 175),
            control2: CGPoint(x: 191 + sway, y: 160)
        )
        stroke(ctx, tail, orangeDark, 14)

        // Body.
        let bodyLift = breathing * 0.6
        let bodyRect = CGRect(x: 57, y: 113 + bodyLift, width: 86, height: 72)
        fillStroke(ctx, CGPath(ellipseIn: bodyRect, transform: nil), orange, orangeMid, 1.2)

        fill(ctx, CGPath(ellipseIn: CGRect(x: 58, y: 142, width: 48, height: 40), transform: nil),
             orangeDark.withAlphaComponent(0.14))
        fill(ctx, CGPath(ellipseIn: CGRect(x: 72, y: 131 + bodyLift, width: 56, height: 50), transform: nil),
             cream.withAlphaComponent(0.96))

        // Paws.
        for x in [63.0, 109.0] {
            let pawPath = CGPath(roundedRect: CGRect(x: x, y: 178, width: 28, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil)
            fillStroke(ctx, pawPath, cream, orangeMid.withAlphaComponent(0.55), 1)
            let toes = CGMutablePath()
            toes.move(to: CGPoint(x: x + 10, y: 184))
            toes.addLine(to: CGPoint(x: x + 10, y: 190))
            toes.move(to: CGPoint(x: x + 18, y: 184))
            toes.addLine(to: CGPoint(x: x + 18, y: 190))
            stroke(ctx, toes, orangeDark.withAlphaComponent(0.35), 1)
        }

        // Head.
        let headRect = CGRect(x: 55, y: 44, width: 90, height: 90)
        fillStroke(ctx, CGPath(ellipseIn: headRect, transform: nil), orange, orangeMid, 1.2)

        // Ears.
        let earTilt: CGFloat = alert ? 4 : (sleeping ? -4 : 0)
        let leftEar = CGMutablePath()
        leftEar.move(to: CGPoint(x: 61, y: 64 + earTilt))
        leftEar.addLine(to: CGPoint(x: 58 - earTilt, y: 22))
        leftEar.addQuadCurve(to: CGPoint(x: 95, y: 51 + earTilt), control: CGPoint(x: 78, y: 31))
        leftEar.closeSubpath()
        fillStroke(ctx, leftEar, orange, orangeMid, 1.2)

        let rightEar = CGMutablePath()
        rightEar.move(to: CGPoint(x: 139, y: 64 + earTilt))
        rightEar.addLine(to: CGPoint(x: 142 + earTilt, y: 22))
        rightEar.addQuadCurve(to: CGPoint(x: 105, y: 51 + earTilt), control: CGPoint(x: 122, y: 31))
        rightEar.closeSubpath()
        fillStroke(ctx, rightEar, orange, orangeMid, 1.2)

        let leftInner = CGMutablePath()
        leftInner.move(to: CGPoint(x: 66, y: 58 + earTilt))
        leftInner.addLine(to: CGPoint(x: 64, y: 32))
        leftInner.addLine(to: CGPoint(x: 86, y: 50 + earTilt))
        leftInner.closeSubpath()
        fill(ctx, leftInner, pink.withAlphaComponent(0.85))

        let rightInner = CGMutablePath()
        rightInner.move(to: CGPoint(x: 134, y: 58 + earTilt))
        rightInner.addLine(to: CGPoint(x: 136, y: 32))
        rightInner.addLine(to: CGPoint(x: 114, y: 50 + earTilt))
        rightInner.closeSubpath()
        fill(ctx, rightInner, pink.withAlphaComponent(0.85))

        // Forehead stripes.
        for (index, x) in ([91.0, 100.0, 109.0] as [CGFloat]).enumerated() {
            let height: CGFloat = index == 1 ? 13 : 9
            let stripe = CGMutablePath()
            stripe.move(to: CGPoint(x: x, y: 54))
            stripe.addLine(to: CGPoint(x: x, y: 54 + height))
            stroke(ctx, stripe, orangeDark.withAlphaComponent(0.55), 2.4)
        }

        // Cheeks.
        fill(ctx, CGPath(ellipseIn: CGRect(x: 62, y: 93, width: 30, height: 23), transform: nil), cream.withAlphaComponent(0.92))
        fill(ctx, CGPath(ellipseIn: CGRect(x: 108, y: 93, width: 30, height: 23), transform: nil), cream.withAlphaComponent(0.92))

        // Eyes.
        let eyeY: CGFloat = 89
        let eyeHeight: CGFloat = alert ? 13 : (working ? 10 : 11)
        for direction in [-1.0, 1.0] {
            let centerX = 100 + CGFloat(direction) * 17
            if sleeping || blinking {
                let closed = CGMutablePath()
                closed.move(to: CGPoint(x: centerX - 7, y: eyeY))
                closed.addQuadCurve(to: CGPoint(x: centerX + 7, y: eyeY), control: CGPoint(x: centerX, y: eyeY + 5))
                stroke(ctx, closed, ink, 2.8)
            } else {
                fill(ctx, CGPath(ellipseIn: CGRect(x: centerX - 4, y: eyeY - eyeHeight / 2, width: 8, height: eyeHeight), transform: nil), ink)
                fill(ctx, CGPath(ellipseIn: CGRect(x: centerX - 2.4, y: eyeY - eyeHeight / 2 + 2, width: 3, height: 3), transform: nil), NSColor.white.withAlphaComponent(0.9))
            }
        }

        // Nose.
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: 96, y: 101))
        nose.addLine(to: CGPoint(x: 104, y: 101))
        nose.addLine(to: CGPoint(x: 100, y: 106))
        nose.closeSubpath()
        fill(ctx, nose, pink)

        // Mouth.
        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: 100, y: 106))
        mouth.addQuadCurve(to: CGPoint(x: 93, y: 111), control: CGPoint(x: 97, y: 111))
        mouth.move(to: CGPoint(x: 100, y: 106))
        mouth.addQuadCurve(to: CGPoint(x: 107, y: 111), control: CGPoint(x: 103, y: 111))
        stroke(ctx, mouth, ink.withAlphaComponent(0.8), 1.6)

        // Whiskers.
        let whiskers = CGMutablePath()
        for (side, baseX) in [(CGFloat(-1), CGFloat(80)), (CGFloat(1), CGFloat(120))] {
            for offset in ([-4.0, 0.0, 4.0] as [CGFloat]) {
                whiskers.move(to: CGPoint(x: baseX, y: 102 + offset))
                whiskers.addLine(to: CGPoint(x: baseX + side * 25, y: 98 + offset * 1.7))
            }
        }
        stroke(ctx, whiskers, NSColor.white.withAlphaComponent(0.85), 1.1)

        // Blush.
        fill(ctx, CGPath(ellipseIn: CGRect(x: 68, y: 105, width: 12, height: 7), transform: nil), pink.withAlphaComponent(0.35))
        fill(ctx, CGPath(ellipseIn: CGRect(x: 120, y: 105, width: 12, height: 7), transform: nil), pink.withAlphaComponent(0.35))

        // Collar and bell.
        let collar = CGMutablePath()
        collar.move(to: CGPoint(x: 68, y: 130))
        collar.addQuadCurve(to: CGPoint(x: 132, y: 130), control: CGPoint(x: 100, y: 142))
        stroke(ctx, collar, NSColor(srgbRed: 0.86, green: 0.29, blue: 0.31, alpha: 1), 7)
        let bell = CGPath(ellipseIn: CGRect(x: 94, y: 135, width: 12, height: 12), transform: nil)
        fillStroke(ctx, bell, NSColor(srgbRed: 0.98, green: 0.79, blue: 0.31, alpha: 1), NSColor(srgbRed: 0.72, green: 0.51, blue: 0.12, alpha: 1), 1)
        fill(ctx, CGPath(ellipseIn: CGRect(x: 98, y: 139, width: 4, height: 4), transform: nil), NSColor(srgbRed: 0.55, green: 0.36, blue: 0.08, alpha: 1))

        // Headphones while working.
        if working {
            let band = CGMutablePath()
            band.move(to: CGPoint(x: 61, y: 66))
            band.addQuadCurve(to: CGPoint(x: 139, y: 66), control: CGPoint(x: 100, y: 18))
            stroke(ctx, band, blue, 5)
            for x in [49.0, 137.0] {
                let cup = CGPath(roundedRect: CGRect(x: x, y: 76, width: 15, height: 27), cornerWidth: 7, cornerHeight: 7, transform: nil)
                fillStroke(ctx, cup, blue, blue.withAlphaComponent(0.55), 1)
                let inner = CGPath(roundedRect: CGRect(x: x + 4, y: 81, width: 7, height: 17), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
                fill(ctx, inner, NSColor.white.withAlphaComponent(0.35))
            }
            let notePhase = (time * 0.8).truncatingRemainder(dividingBy: 1.0)
            let note = noteImage(for: blue)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(1.0 - notePhase))
            draw(image: note, in: CGRect(x: 148, y: 34 - CGFloat(notePhase) * 18, width: 20, height: 20))
            ctx.restoreGState()
        }

        // Zzz while sleeping.
        if sleeping {
            for index in 0..<3 {
                let phase = CGFloat((time * 0.22 + Double(index) / 3.0).truncatingRemainder(dividingBy: 1.0))
                let image = zImage(index: index)
                ctx.saveGState()
                ctx.setAlpha(0.62 * (1.0 - phase))
                draw(image: image, in: CGRect(
                    x: 148 + CGFloat(index) * 7 + phase * 9,
                    y: 66 - phase * 26,
                    width: image.size.width,
                    height: image.size.height
                ))
                ctx.restoreGState()
            }
        }

        // Badge.
        let pendingCount = model.unreviewedReview.count
        if pendingCount > 0 {
            let image = badgeImage(count: pendingCount, color: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.22, alpha: 1))
            draw(image: image, in: CGRect(x: 134, y: 36, width: 34, height: 34))
        } else if model.runningCount > 0 {
            let image = badgeImage(count: model.runningCount, color: blue)
            draw(image: image, in: CGRect(x: 134, y: 36, width: 34, height: 34))
        }

        // Sparkles.
        if finishing {
            let decay = CGFloat(min(1, max(0, finishRemaining / 1.4)))
            drawSparkles(ctx: ctx, alpha: decay)
        } else if alert, time.truncatingRemainder(dividingBy: 3.4) < 1.4 {
            let sparklePhase = time.truncatingRemainder(dividingBy: 3.4)
            drawSparkles(ctx: ctx, alpha: CGFloat(max(0, 1 - sparklePhase / 1.4)))
        }

        ctx.restoreGState()
    }

    // MARK: Drawing helpers

    private func fill(_ ctx: CGContext, _ path: CGPath, _ color: NSColor) {
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    private func fillStroke(
        _ ctx: CGContext,
        _ path: CGPath,
        _ fillColor: NSColor,
        _ strokeColor: NSColor,
        _ width: CGFloat
    ) {
        ctx.addPath(path)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    private func stroke(
        _ ctx: CGContext,
        _ path: CGPath,
        _ color: NSColor,
        _ width: CGFloat
    ) {
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    private func draw(image: NSImage, in rect: CGRect) {
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    // MARK: Cached text

    private func badgeImage(count: Int, color: NSColor) -> NSImage {
        let key = "\(count)-\(color == NSColor(srgbRed: 0.29, green: 0.45, blue: 0.93, alpha: 1) ? "blue" : "orange")"
        if let cached = badgeCache[key] { return cached }

        let size = NSSize(width: 34, height: 34)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 34, height: 34)).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 28, height: 28)).fill()

            let text = "\(count)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .heavy),
                .foregroundColor: NSColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                withAttributes: attributes
            )
            return true
        }
        badgeCache[key] = image
        return image
    }

    private func noteImage(for color: NSColor) -> NSImage {
        if let noteImage { return noteImage }
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: true) { rect in
            let text = "♪" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: color
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                withAttributes: attributes
            )
            return true
        }
        noteImage = image
        return image
    }

    private func zImage(index: Int) -> NSImage {
        if zImages.count > index { return zImages[index] }
        let sizes: [CGFloat] = [11, 14, 17]
        let size = NSSize(width: 18, height: 20)
        let imageFor: (CGFloat) -> NSImage = { fontSize in
            NSImage(size: size, flipped: true) { rect in
                let text = "z" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: NSColor.white
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(
                    at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                    withAttributes: attributes
                )
                return true
            }
        }
        while zImages.count <= index {
            zImages.append(imageFor(sizes[min(zImages.count, sizes.count - 1)]))
        }
        return zImages[index]
    }
}
