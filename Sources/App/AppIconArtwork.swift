import AppKit
import SwiftUI

@MainActor
enum AppIconArtwork {
    static let appIcon: NSImage = IconRenderer.makeAppIcon()

    static let menuBarIcon: NSImage = {
        let image = IconRenderer.makeMenuBarIcon()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    static func applyApplicationIcon() {
        NSApp.applicationIconImage = appIcon
    }

    static func exportAssets(to directoryURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        try writePNG(appIcon, to: directoryURL.appending(path: "AppIcon-master.png"))
        try writePNG(menuBarIcon, to: directoryURL.appending(path: "MenuBarIcon-template.png"))
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw IconExportError.failedToEncodePNG(url.lastPathComponent)
        }

        try pngData.write(to: url, options: .atomic)
    }
}

@MainActor
struct MenuBarStatusIcon: View {
    var body: some View {
        Image(nsImage: AppIconArtwork.menuBarIcon)
            .renderingMode(.template)
            .foregroundStyle(.primary)
            .frame(width: 18, height: 18)
            .accessibilityLabel(L10n.tr("Orbit"))
            .help(L10n.tr("Orbit"))
    }
}

struct IconExportRequest {
    let outputDirectory: URL

    static var current: IconExportRequest? {
        let arguments = CommandLine.arguments

        guard let flagIndex = arguments.firstIndex(of: "--export-icons") else {
            return nil
        }

        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        let outputPath = arguments[valueIndex]
        return IconExportRequest(outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true))
    }
}

enum IconExportError: LocalizedError {
    case failedToEncodePNG(String)

    var errorDescription: String? {
        switch self {
        case .failedToEncodePNG(let filename):
            L10n.tr("无法编码 PNG: %@", filename)
        }
    }
}

private enum IconRenderer {
    private enum GlyphTone {
        case branded
        case template
    }

    private enum Palette {
        static let tileBase = NSColor(hex: 0x081018)
        static let tileGradientStart = NSColor(hex: 0x081420)
        static let tileGradientEnd = NSColor(hex: 0x12374E)
        static let tileBorder = NSColor.white.withAlphaComponent(0.08)
        static let orbitBase = NSColor(hex: 0x283548)
        static let orbitAccent = NSColor(hex: 0x71DAFF)
        static let coreFillTop = NSColor(hex: 0xF7FBFF)
        static let coreFillBottom = NSColor(hex: 0xD9E7F5)
        static let coreStroke = NSColor.white.withAlphaComponent(0.42)
        static let nodeFill = NSColor(hex: 0x71DAFF)
        static let nodeHalo = NSColor(hex: 0x71DAFF, alpha: 0.22)
        static let templateInk = NSColor.black
    }

    static func makeAppIcon() -> NSImage {
        makeImage(pixelWidth: 1024, pixelHeight: 1024) { rect in
            drawAppIcon(in: rect)
        }
    }

    static func makeMenuBarIcon() -> NSImage {
        makeImage(pixelWidth: 72, pixelHeight: 72) { rect in
            drawMenuBarIcon(in: rect.insetBy(dx: 2, dy: 2))
        }
    }

    private static func makeImage(
        pixelWidth: Int,
        pixelHeight: Int,
        drawing: (CGRect) -> Void
    ) -> NSImage {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
        }

        bitmap.size = NSSize(width: pixelWidth, height: pixelHeight)

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.setShouldAntialias(true)

        NSGraphicsContext.saveGraphicsState()
        drawing(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.current = previousContext

        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func drawAppIcon(in rect: CGRect) {
        let tileRect = rect.insetBy(dx: rect.width * 0.085, dy: rect.height * 0.085)
        let tileRadius = tileRect.width * 0.235
        let tilePath = NSBezierPath(roundedRect: tileRect, xRadius: tileRadius, yRadius: tileRadius)

        withShadow(color: NSColor.black.withAlphaComponent(0.3), blur: rect.width * 0.075, offset: NSSize(width: 0, height: -rect.height * 0.022)) {
            Palette.tileBase.setFill()
            tilePath.fill()
        }

        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        NSGradient(colors: [Palette.tileGradientStart, Palette.tileGradientEnd])?.draw(in: tilePath, angle: -42)
        drawGlow(
            center: CGPoint(x: tileRect.minX + tileRect.width * 0.34, y: tileRect.maxY - tileRect.height * 0.18),
            radius: tileRect.width * 0.44,
            color: Palette.nodeHalo
        )
        drawGlow(
            center: CGPoint(x: tileRect.maxX - tileRect.width * 0.16, y: tileRect.minY + tileRect.height * 0.2),
            radius: tileRect.width * 0.3,
            color: NSColor(hex: 0xA9F0FF, alpha: 0.08)
        )
        NSGraphicsContext.restoreGraphicsState()

        let borderPath = NSBezierPath(
            roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5),
            xRadius: tileRadius - 1.5,
            yRadius: tileRadius - 1.5
        )
        Palette.tileBorder.setStroke()
        borderPath.lineWidth = 2
        borderPath.stroke()

        drawOrbitGlyph(
            in: tileRect.insetBy(dx: tileRect.width * 0.18, dy: tileRect.height * 0.18),
            tone: .branded
        )
    }

    private static func drawMenuBarIcon(in rect: CGRect) {
        drawOrbitGlyph(
            in: rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.14),
            tone: .template
        )
    }

    private static func drawOrbitGlyph(in rect: CGRect, tone: GlyphTone) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let orbitRadius = rect.width * 0.37
        let orbitLineWidth = rect.width * (tone == .template ? 0.11 : 0.094)
        let coreSize = rect.width * (tone == .template ? 0.24 : 0.22)
        let nodeSize = rect.width * (tone == .template ? 0.14 : 0.16)
        let orbitColor = tone == .template ? Palette.templateInk : Palette.orbitBase

        strokeArc(
            center: center,
            radius: orbitRadius,
            startAngle: 138,
            endAngle: 30,
            color: orbitColor,
            lineWidth: orbitLineWidth
        )

        if tone == .branded {
            strokeArc(
                center: center,
                radius: orbitRadius,
                startAngle: 304,
                endAngle: 356,
                color: Palette.orbitAccent,
                lineWidth: orbitLineWidth
            )
        }

        let nodeCenter = point(
            onCircleWithCenter: center,
            radius: orbitRadius,
            angleDegrees: 92
        )

        if tone == .branded {
            drawGlow(center: nodeCenter, radius: rect.width * 0.13, color: Palette.nodeHalo)
            strokeCircle(
                center: nodeCenter,
                diameter: nodeSize * 1.45,
                color: Palette.nodeFill.withAlphaComponent(0.28),
                lineWidth: rect.width * 0.018
            )
        }

        fillCircle(
            center: nodeCenter,
            diameter: nodeSize,
            color: tone == .template ? Palette.templateInk : Palette.nodeFill
        )

        let coreRect = CGRect(
            x: center.x - coreSize / 2,
            y: center.y - coreSize / 2,
            width: coreSize,
            height: coreSize
        )
        let coreRadius = coreSize * 0.24
        let corePath = NSBezierPath(roundedRect: coreRect, xRadius: coreRadius, yRadius: coreRadius)

        if tone == .branded {
            withShadow(color: NSColor.black.withAlphaComponent(0.18), blur: rect.width * 0.05, offset: NSSize(width: 0, height: -rect.width * 0.018)) {
                NSColor.black.withAlphaComponent(0.16).setFill()
                corePath.fill()
            }

            NSGraphicsContext.saveGraphicsState()
            corePath.addClip()
            NSGradient(colors: [Palette.coreFillTop, Palette.coreFillBottom])?.draw(in: corePath, angle: 90)
            NSGraphicsContext.restoreGraphicsState()

            Palette.coreStroke.setStroke()
            corePath.lineWidth = rect.width * 0.01
            corePath.stroke()
        } else {
            Palette.templateInk.setFill()
            corePath.fill()
        }
    }

    private static func drawGlow(center: CGPoint, radius: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(rect: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        path.addClip()
        NSGradient(colors: [color, color.withAlphaComponent(0)])?.draw(
            fromCenter: center,
            radius: 0,
            toCenter: center,
            radius: radius,
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func withShadow(color: NSColor, blur: CGFloat, offset: NSSize, drawing: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = offset
        shadow.set()
        drawing()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func strokeArc(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round

        if endAngle >= startAngle {
            path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle)
        } else {
            path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: 360)
            path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: endAngle)
        }

        color.setStroke()
        path.stroke()
    }

    private static func point(onCircleWithCenter center: CGPoint, radius: CGFloat, angleDegrees: CGFloat) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(
            x: center.x + cos(radians) * radius,
            y: center.y + sin(radians) * radius
        )
    }

    private static func fillCircle(center: CGPoint, diameter: CGFloat, color: NSColor) {
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()
    }

    private static func strokeCircle(center: CGPoint, diameter: CGFloat, color: NSColor, lineWidth: CGFloat) {
        let rect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }
}

private extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
