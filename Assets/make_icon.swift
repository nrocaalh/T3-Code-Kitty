import AppKit

let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S), flipped: true) { _ in
    // Background
    let bgRect = NSRect(x: 56, y: 56, width: S - 112, height: S - 112)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 220, yRadius: 220)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 1.00, green: 0.87, blue: 0.68, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.68, blue: 0.36, alpha: 1)
    ])!
    gradient.draw(in: bg, angle: -55)

    // Ground shadow
    NSColor.black.withAlphaComponent(0.10).setFill()
    NSBezierPath(ovalIn: NSRect(x: 238, y: 790, width: 548, height: 64)).fill()

    // Ears
    let orange = NSColor(srgbRed: 0.96, green: 0.67, blue: 0.38, alpha: 1)
    let orangeMid = NSColor(srgbRed: 0.90, green: 0.56, blue: 0.27, alpha: 1)
    let orangeDark = NSColor(srgbRed: 0.78, green: 0.43, blue: 0.18, alpha: 1)
    let cream = NSColor(srgbRed: 1.0, green: 0.94, blue: 0.84, alpha: 1)
    let pink = NSColor(srgbRed: 0.95, green: 0.58, blue: 0.58, alpha: 1)
    let ink = NSColor(srgbRed: 0.23, green: 0.17, blue: 0.15, alpha: 1)

    func fill(_ path: NSBezierPath, _ color: NSColor) {
        color.setFill(); path.fill()
    }
    func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
        color.setStroke(); path.lineWidth = width
        path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
    }

    let leftEar = NSBezierPath()
    leftEar.move(to: NSPoint(x: 250, y: 480))
    leftEar.line(to: NSPoint(x: 292, y: 205))
    leftEar.curve(to: NSPoint(x: 478, y: 405), controlPoint1: NSPoint(x: 352, y: 285), controlPoint2: NSPoint(x: 416, y: 345))
    leftEar.close()
    fill(leftEar, orange)
    stroke(leftEar, orangeMid, 8)

    let rightEar = NSBezierPath()
    rightEar.move(to: NSPoint(x: 774, y: 480))
    rightEar.line(to: NSPoint(x: 732, y: 205))
    rightEar.curve(to: NSPoint(x: 546, y: 405), controlPoint1: NSPoint(x: 672, y: 285), controlPoint2: NSPoint(x: 608, y: 345))
    rightEar.close()
    fill(rightEar, orange)
    stroke(rightEar, orangeMid, 8)

    let leftInner = NSBezierPath()
    leftInner.move(to: NSPoint(x: 300, y: 430))
    leftInner.line(to: NSPoint(x: 324, y: 280))
    leftInner.line(to: NSPoint(x: 432, y: 380))
    leftInner.close()
    fill(leftInner, pink.withAlphaComponent(0.85))

    let rightInner = NSBezierPath()
    rightInner.move(to: NSPoint(x: 724, y: 430))
    rightInner.line(to: NSPoint(x: 700, y: 280))
    rightInner.line(to: NSPoint(x: 592, y: 380))
    rightInner.close()
    fill(rightInner, pink.withAlphaComponent(0.85))

    // Head
    let head = NSBezierPath(ovalIn: NSRect(x: 202, y: 350, width: 620, height: 540))
    fill(head, orange)
    stroke(head, orangeMid, 8)

    // Forehead stripes
    for (x, h) in [(462.0, 70.0), (512.0, 96.0), (562.0, 70.0)] {
        let stripe = NSBezierPath()
        stripe.move(to: NSPoint(x: x, y: 380))
        stripe.line(to: NSPoint(x: x, y: 380 + h))
        stroke(stripe, orangeDark.withAlphaComponent(0.55), 14)
    }

    // Cheeks
    fill(NSBezierPath(ovalIn: NSRect(x: 292, y: 600, width: 180, height: 130)), cream.withAlphaComponent(0.94))
    fill(NSBezierPath(ovalIn: NSRect(x: 552, y: 600, width: 180, height: 130)), cream.withAlphaComponent(0.94))

    // Eyes
    for cx in [412.0, 612.0] {
        fill(NSBezierPath(ovalIn: NSRect(x: cx - 28, y: 570, width: 56, height: 82)), ink)
        fill(NSBezierPath(ovalIn: NSRect(x: cx - 14, y: 588, width: 20, height: 20)), .white.withAlphaComponent(0.92))
    }

    // Nose + mouth
    let nose = NSBezierPath()
    nose.move(to: NSPoint(x: 484, y: 648))
    nose.line(to: NSPoint(x: 540, y: 648))
    nose.line(to: NSPoint(x: 512, y: 690))
    nose.close()
    fill(nose, pink)

    let mouth = NSBezierPath()
    mouth.move(to: NSPoint(x: 512, y: 690))
    mouth.curve(to: NSPoint(x: 458, y: 726), controlPoint1: NSPoint(x: 492, y: 722), controlPoint2: NSPoint(x: 478, y: 726))
    mouth.move(to: NSPoint(x: 512, y: 690))
    mouth.curve(to: NSPoint(x: 566, y: 726), controlPoint1: NSPoint(x: 532, y: 722), controlPoint2: NSPoint(x: 546, y: 726))
    stroke(mouth, ink.withAlphaComponent(0.8), 10)

    // Whiskers
    for side in [-1.0, 1.0] {
        for offset in [-22.0, 0.0, 22.0] {
            let baseX = side < 0 ? 300.0 : 724.0
            let w = NSBezierPath()
            w.move(to: NSPoint(x: baseX, y: 620 + offset))
            w.line(to: NSPoint(x: baseX + side * 150, y: 596 + offset * 1.7))
            stroke(w, NSColor.white.withAlphaComponent(0.9), 9)
        }
    }

    // Blush
    fill(NSBezierPath(ovalIn: NSRect(x: 330, y: 690, width: 84, height: 42)), pink.withAlphaComponent(0.30))
    fill(NSBezierPath(ovalIn: NSRect(x: 610, y: 690, width: 84, height: 42)), pink.withAlphaComponent(0.30))

    // Collar
    let collar = NSBezierPath()
    collar.move(to: NSPoint(x: 262, y: 880))
    collar.curve(to: NSPoint(x: 762, y: 880), controlPoint1: NSPoint(x: 420, y: 950), controlPoint2: NSPoint(x: 604, y: 950))
    stroke(collar, NSColor(srgbRed: 0.86, green: 0.29, blue: 0.31, alpha: 1), 34)

    let bell = NSBezierPath(ovalIn: NSRect(x: 472, y: 906, width: 80, height: 80))
    fill(bell, NSColor(srgbRed: 0.98, green: 0.79, blue: 0.31, alpha: 1))
    stroke(bell, NSColor(srgbRed: 0.72, green: 0.51, blue: 0.12, alpha: 1), 6)
    fill(NSBezierPath(ovalIn: NSRect(x: 500, y: 934, width: 24, height: 24)), NSColor(srgbRed: 0.55, green: 0.36, blue: 0.08, alpha: 1))
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("No image") }
try! png.write(to: URL(fileURLWithPath: "Assets/icon_1024.png"))
print("wrote Assets/icon_1024.png")
