import AppKit

/// Side profile of an AWD robot mower, drawn as vector art rather than shipped
/// as a bitmap so it stays crisp at menu bar sizes and scales up for the app icon.
///
/// Design space is 206 × 99, origin bottom-left, machine facing left. The
/// proportions are measured off a reference side view: wheels of radius 29 on a
/// common centre line at y = 29 (front cx 42, rear cx 174), a slim shell whose
/// underside sits at y = 12 and whose roof runs 68 → 84 → 72 front to back, and
/// the vision pod at x 75–105 reaching y = 99.
///
/// Two renderings share that geometry:
/// - `mower(size:color:)` — flat single-colour silhouette for the menu bar.
/// - `drawDetailed(in:)` — shaded, outlined artwork for the app icon.
enum MowerIcon {

    /// Tight bounds of the artwork inside the design space.
    private static let box = NSRect(x: 0, y: 0, width: 206, height: 99)
    static var aspectRatio: CGFloat { box.width / box.height }

    // MARK: - Geometry

    private struct Map {
        let s: CGFloat, dx: CGFloat, dy: CGFloat

        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: dx + x * s, y: dy + y * s) }

        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: dx + x * s, y: dy + y * s, width: w * s, height: h * s)
        }

        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: r * s, yRadius: r * s)
        }

        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: rect(cx - r, cy - r, r * 2, r * 2))
        }

        static func fit(_ rect: NSRect) -> Map {
            let s = min(rect.width / box.width, rect.height / box.height)
            return Map(s: s,
                       dx: rect.minX + (rect.width - box.width * s) / 2 - box.minX * s,
                       dy: rect.minY + (rect.height - box.height * s) / 2 - box.minY * s)
        }
    }

    private static let frontWheel = (x: CGFloat(42), y: CGFloat(29), r: CGFloat(29), hub: CGFloat(11))
    private static let rearWheel = (x: CGFloat(174), y: CGFloat(29), r: CGFloat(29), hub: CGFloat(11))

    /// Clearance cut around each tyre in the flat silhouette, so the wheels read
    /// as wheels instead of merging into the body.
    private static let wheelClearance: CGFloat = 4

    /// Outline of the whole body: a slim wedge, nose well behind the front axle.
    private static func shell(_ m: Map) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: m.p(60, 48))
        p.curve(to: m.p(80, 68), controlPoint1: m.p(66, 56), controlPoint2: m.p(72, 64))     // nose
        p.curve(to: m.p(112, 76), controlPoint1: m.p(92, 71), controlPoint2: m.p(102, 74))   // long low roof
        p.curve(to: m.p(158, 84), controlPoint1: m.p(128, 78), controlPoint2: m.p(144, 82))  // rise to the rear
        p.curve(to: m.p(196, 79), controlPoint1: m.p(172, 86), controlPoint2: m.p(186, 82))  // shoulder
        p.curve(to: m.p(206, 58), controlPoint1: m.p(203, 77), controlPoint2: m.p(206, 70))  // near-vertical tail
        p.line(to: m.p(206, 28))
        p.curve(to: m.p(188, 12), controlPoint1: m.p(206, 18), controlPoint2: m.p(198, 12))
        p.line(to: m.p(72, 12))                                                              // flat underside
        p.curve(to: m.p(60, 48), controlPoint1: m.p(64, 13), controlPoint2: m.p(57, 30))     // front face
        p.close()
        return p
    }

    /// Mast and cap of the vision pod — the detail that stops the silhouette
    /// reading as a generic robot.
    private static func pod(_ m: Map) -> NSBezierPath {
        let p = NSBezierPath()
        p.append(m.rounded(81, 58, 17, 28, 4))
        p.append(m.rounded(74, 82, 32, 17, 6))
        return p
    }

    /// Blade guard, ahead of the front wheel.
    private static func bladeGuard(_ m: Map) -> NSBezierPath {
        m.rounded(0, 22, 10, 16, 4)
    }

    // MARK: - Flat silhouette (menu bar)

    /// Uses `.clear` compositing for the wheel clearance and hubs, so it must be
    /// rendered into its own transparent image before being placed on any
    /// background.
    private static func drawFlat(in rect: NSRect, color: NSColor) {
        let m = Map.fit(rect)

        color.setFill()
        shell(m).fill()
        pod(m).fill()

        knockOut(m.circle(frontWheel.x, frontWheel.y, frontWheel.r + wheelClearance))
        knockOut(m.circle(rearWheel.x, rearWheel.y, rearWheel.r + wheelClearance))

        color.setFill()
        m.circle(frontWheel.x, frontWheel.y, frontWheel.r).fill()
        m.circle(rearWheel.x, rearWheel.y, rearWheel.r).fill()

        knockOut(m.circle(frontWheel.x, frontWheel.y, frontWheel.hub))
        knockOut(m.circle(rearWheel.x, rearWheel.y, rearWheel.hub))

        // Drawn last so the clearance cut around the front tyre does not eat it.
        color.setFill()
        bladeGuard(m).fill()
    }

    private static func knockOut(_ path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func mower(size: NSSize, color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            drawFlat(in: rect, color: color)
            return true
        }
    }

    // MARK: - Detailed artwork (app icon)

    private enum Palette {
        static let ink = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1)
        static let shellTop = NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1)
        static let shellBottom = NSColor(srgbRed: 0.85, green: 0.86, blue: 0.88, alpha: 1)
        static let chassis = NSColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1)
        static let skirt = NSColor(srgbRed: 0.68, green: 0.70, blue: 0.72, alpha: 1)
        static let tyre = NSColor(srgbRed: 0.20, green: 0.21, blue: 0.23, alpha: 1)
        static let tread = NSColor(srgbRed: 0.28, green: 0.29, blue: 0.31, alpha: 1)
        static let rim = NSColor.white
        static let hub = NSColor(srgbRed: 0.55, green: 0.57, blue: 0.60, alpha: 1)
        static let podBody = NSColor(srgbRed: 0.31, green: 0.32, blue: 0.34, alpha: 1)
        static let podCap = NSColor(srgbRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
    }

    /// Shaded rendering for the app icon. Unlike the flat silhouette this paints
    /// real colours and outlines, so it composites straight onto a background.
    private static func drawDetailed(in rect: NSRect) {
        let m = Map.fit(rect)
        let stroke = max(0.75, 1.7 * m.s)
        let body = shell(m)

        // Shell, shaded top to bottom.
        NSGradient(starting: Palette.shellTop, ending: Palette.shellBottom)?
            .draw(in: body, angle: -90)

        // Dark chassis and light skirt, clipped to the body outline. The belt
        // line follows the shell's lower edge — sloping up towards the rear —
        // rather than cutting straight across.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()

        let belt = NSBezierPath()
        belt.move(to: m.p(50, 10))
        belt.line(to: m.p(50, 30))
        belt.curve(to: m.p(120, 42), controlPoint1: m.p(78, 37), controlPoint2: m.p(100, 41))
        belt.curve(to: m.p(208, 52), controlPoint1: m.p(152, 44), controlPoint2: m.p(182, 50))
        belt.line(to: m.p(208, 10))
        belt.close()
        Palette.chassis.setFill()
        belt.fill()

        Palette.skirt.setFill()
        NSBezierPath(rect: m.rect(0, 12, 206, 7)).fill()
        NSGraphicsContext.restoreGraphicsState()

        Palette.ink.setStroke()
        body.lineWidth = stroke
        body.stroke()

        drawPod(m, stroke: stroke)
        drawWheel(m, frontWheel, stroke: stroke)
        drawWheel(m, rearWheel, stroke: stroke)

        let guardPath = bladeGuard(m)
        Palette.skirt.setFill()
        guardPath.fill()
        guardPath.lineWidth = stroke
        Palette.ink.setStroke()
        guardPath.stroke()
    }

    private static func drawPod(_ m: Map, stroke: CGFloat) {
        let mast = m.rounded(81, 58, 17, 28, 4)
        Palette.podBody.setFill()
        mast.fill()
        mast.lineWidth = stroke
        Palette.ink.setStroke()
        mast.stroke()

        let cap = m.rounded(74, 82, 32, 17, 6)
        Palette.podBody.setFill()
        cap.fill()
        cap.lineWidth = stroke
        cap.stroke()

        // Lens band across the cap.
        Palette.podCap.setFill()
        m.rounded(80, 87, 20, 6, 2.5).fill()
    }

    private static func drawWheel(_ m: Map, _ wheel: (x: CGFloat, y: CGFloat, r: CGFloat, hub: CGFloat),
                                  stroke: CGFloat) {
        // Tread lugs first, so they read as bumps around the tyre edge.
        Palette.tread.setFill()
        let lugs = 16
        for i in 0..<lugs {
            let angle = CGFloat(i) / CGFloat(lugs) * 2 * .pi
            let cx = wheel.x + cos(angle) * (wheel.r - 1.5)
            let cy = wheel.y + sin(angle) * (wheel.r - 1.5)
            let lug = m.rounded(cx - 3.4, cy - 3.4, 6.8, 6.8, 1.8)
            lug.fill()
        }

        let tyre = m.circle(wheel.x, wheel.y, wheel.r - 1.5)
        Palette.tyre.setFill()
        tyre.fill()
        Palette.ink.setStroke()
        tyre.lineWidth = stroke
        tyre.stroke()

        // White rim ring between tyre and hub.
        Palette.rim.setFill()
        m.circle(wheel.x, wheel.y, wheel.r * 0.60).fill()
        Palette.tyre.setFill()
        m.circle(wheel.x, wheel.y, wheel.r * 0.52).fill()

        let hub = m.circle(wheel.x, wheel.y, wheel.hub)
        Palette.hub.setFill()
        hub.fill()
        Palette.ink.setStroke()
        hub.lineWidth = stroke * 0.8
        hub.stroke()

        // Lug bolts.
        Palette.rim.setFill()
        for i in 0..<5 {
            let angle = CGFloat(i) / 5 * 2 * .pi - .pi / 2
            let cx = wheel.x + cos(angle) * (wheel.hub * 0.58)
            let cy = wheel.y + sin(angle) * (wheel.hub * 0.58)
            m.circle(cx, cy, 1.5).fill()
        }
    }

    // MARK: - Menu bar

    /// The status item image.
    ///
    /// With no badge this is a template image, so macOS tints it correctly for
    /// light, dark and reduced-transparency menu bars. A badge forces a literal
    /// image, which is why the caller has to supply an already-resolved tint.
    static func menuBarImage(height: CGFloat, tint: NSColor, badge: NSColor?) -> NSImage {
        let mowerWidth = (height * aspectRatio).rounded()
        let badgeSize = badge == nil ? 0 : max(5, (height * 0.42).rounded())
        let size = NSSize(width: mowerWidth + (badgeSize * 0.5).rounded(), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            mower(size: NSSize(width: mowerWidth, height: height), color: tint)
                .draw(in: NSRect(x: 0, y: 0, width: mowerWidth, height: height))

            if let badge {
                let dot = NSRect(x: size.width - badgeSize, y: size.height - badgeSize,
                                 width: badgeSize, height: badgeSize)
                knockOut(NSBezierPath(ovalIn: dot.insetBy(dx: -1.2, dy: -1.2)))
                badge.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = (badge == nil)
        image.accessibilityDescription = badge == nil ? AppInfo.name : "\(AppInfo.name) — attention needed"
        return image
    }

    /// Small filled circle used to flag each mower's health in the menu.
    static func dot(_ color: NSColor, diameter: CGFloat = 9) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    // MARK: - App icon

    /// macOS app icon: the detailed mower on a green squircle, sized and inset
    /// to the platform's proportions so it sits correctly next to system icons
    /// in Finder, the Dock and permission dialogs.
    private static func drawAppIcon(in rect: NSRect) {
        let plate = rect.insetBy(dx: rect.width * 0.095, dy: rect.width * 0.095)
        let squircle = NSBezierPath(roundedRect: plate,
                                    xRadius: plate.width * 0.2237, yRadius: plate.width * 0.2237)

        NSGradient(colors: [
            NSColor(srgbRed: 0.42, green: 0.76, blue: 0.36, alpha: 1),
            NSColor(srgbRed: 0.20, green: 0.55, blue: 0.26, alpha: 1),
            NSColor(srgbRed: 0.08, green: 0.34, blue: 0.17, alpha: 1)
        ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: squircle, angle: -90)

        // Mown stripes across the lower third, clipped to the plate.
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSColor(white: 1, alpha: 0.045).setFill()
        let stripe = plate.height * 0.075
        var y = plate.minY
        while y < plate.minY + plate.height * 0.38 {
            NSBezierPath(rect: NSRect(x: plate.minX, y: y, width: plate.width, height: stripe)).fill()
            y += stripe * 2
        }
        NSGraphicsContext.restoreGraphicsState()

        // Soft top highlight for a little depth.
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSGradient(starting: NSColor(white: 1, alpha: 0.20), ending: NSColor(white: 1, alpha: 0))?
            .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let width = plate.width * 0.76
        let height = width / aspectRatio
        let art = NSRect(x: plate.midX - width / 2,
                         y: plate.midY - height / 2 - plate.height * 0.01,
                         width: width, height: height)

        // Contact shadow under the machine.
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSColor(white: 0, alpha: 0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: art.minX + art.width * 0.02, y: art.minY - art.height * 0.09,
                                    width: art.width * 0.96, height: art.height * 0.20)).fill()
        NSGraphicsContext.restoreGraphicsState()

        drawDetailed(in: art)
    }

    /// Renders the `.iconset` PNGs consumed by `iconutil` during the build.
    static func writeIconSet(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let data = appIconPNG(pixels: pixels) else { continue }
                try data.write(to: directory.appendingPathComponent(name))
            }
        }
    }

    static func appIconPNG(pixels: Int) -> Data? {
        render(width: pixels, height: pixels) {
            drawAppIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }

    /// Debug helper: menu-bar rendering blown up so the artwork can be eyeballed
    /// without launching the app (`--render-icons DIR`).
    static func previewPNG(height: CGFloat, scale: CGFloat, badge: NSColor?) -> Data? {
        let mowerWidth = (height * aspectRatio).rounded() * scale
        let badgeSize = badge == nil ? 0 : max(5, (height * 0.42).rounded()) * scale
        let width = mowerWidth + (badgeSize * 0.5).rounded()

        return render(width: Int(width), height: Int(height * scale)) {
            mower(size: NSSize(width: mowerWidth, height: height * scale), color: .black)
                .draw(in: NSRect(x: 0, y: 0, width: mowerWidth, height: height * scale))
            if let badge {
                let dot = NSRect(x: width - badgeSize, y: height * scale - badgeSize,
                                 width: badgeSize, height: badgeSize)
                knockOut(NSBezierPath(ovalIn: dot.insetBy(dx: -1.2 * scale, dy: -1.2 * scale)))
                badge.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    private static func render(width: Int, height: Int, _ body: () -> Void) -> Data? {
        guard width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        body()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
