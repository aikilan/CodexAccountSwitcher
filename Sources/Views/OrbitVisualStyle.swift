import AppKit
import SwiftUI

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "app_appearance_preference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.tr("跟随系统")
        case .light:
            return L10n.tr("浅色")
        case .dark:
            return L10n.tr("深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func resolved(from rawValue: String) -> AppAppearancePreference {
        AppAppearancePreference(rawValue: rawValue) ?? .system
    }
}

enum OrbitSpacing {
    static let compact: CGFloat = 8
    static let tight: CGFloat = 12
    static let regular: CGFloat = 16
    static let section: CGFloat = 24
    static let page: CGFloat = 32
}

enum OrbitRadius {
    static let row: CGFloat = 10
    static let panel: CGFloat = 14
    static let hero: CGFloat = 20
}

enum OrbitPalette {
    static let background = dynamicColor(
        light: rgba(0.972, 0.976, 0.986),
        dark: rgba(0.066, 0.074, 0.095)
    )
    static let sidebar = dynamicColor(
        light: rgba(0.938, 0.946, 0.962),
        dark: rgba(0.086, 0.096, 0.123)
    )
    static let workspace = dynamicColor(
        light: rgba(1, 1, 1, 0.88),
        dark: rgba(0.138, 0.153, 0.188, 0.98)
    )
    static let panel = dynamicColor(
        light: rgba(1, 1, 1, 0.92),
        dark: rgba(0.162, 0.179, 0.22, 0.98)
    )
    static let panelMuted = dynamicColor(
        light: rgba(0.958, 0.966, 0.982),
        dark: rgba(0.205, 0.225, 0.276)
    )
    static let floatingPanelDisabled = dynamicColor(
        light: rgba(1, 1, 1, 0.4),
        dark: rgba(0.158, 0.175, 0.219, 0.68)
    )
    static let floatingPanel = dynamicColor(
        light: rgba(1, 1, 1, 0.78),
        dark: rgba(0.178, 0.197, 0.243, 0.92)
    )
    static let floatingPanelHover = dynamicColor(
        light: rgba(1, 1, 1, 0.95),
        dark: rgba(0.208, 0.228, 0.282, 0.96)
    )
    static let divider = dynamicColor(
        light: rgba(0, 0, 0, 0.07),
        dark: rgba(1, 1, 1, 0.075)
    )
    static let hoverBorder = dynamicColor(
        light: rgba(0, 0, 0, 0.08),
        dark: rgba(1, 1, 1, 0.115)
    )
    static let accent = dynamicColor(
        light: rgba(0.15, 0.41, 0.9),
        dark: rgba(0.52, 0.72, 1)
    )
    static let accentSoft = dynamicColor(
        light: rgba(0.15, 0.41, 0.9, 0.1),
        dark: rgba(0.52, 0.72, 1, 0.16)
    )
    static let accentStrong = dynamicColor(
        light: rgba(0.15, 0.41, 0.9, 0.18),
        dark: rgba(0.52, 0.72, 1, 0.28)
    )
    static let chromeFill = dynamicColor(
        light: rgba(0, 0, 0, 0.05),
        dark: rgba(1, 1, 1, 0.08)
    )
    static let chromeSubtle = dynamicColor(
        light: rgba(0, 0, 0, 0.025),
        dark: rgba(1, 1, 1, 0.045)
    )
    static let selectionFill = dynamicColor(
        light: rgba(0.15, 0.41, 0.9, 0.08),
        dark: rgba(0.32, 0.45, 0.72, 0.28)
    )
    static let successSoft = dynamicColor(
        light: NSColor.systemGreen.withAlphaComponent(0.12),
        dark: NSColor.systemGreen.withAlphaComponent(0.2)
    )
    static let warningSoft = dynamicColor(
        light: NSColor.systemYellow.withAlphaComponent(0.15),
        dark: NSColor.systemYellow.withAlphaComponent(0.22)
    )
    static let dangerSoft = dynamicColor(
        light: NSColor.systemRed.withAlphaComponent(0.12),
        dark: NSColor.systemRed.withAlphaComponent(0.18)
    )

    private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                switch appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) {
                case .darkAqua, .vibrantDark:
                    return dark
                default:
                    return light
                }
            }
        )
    }
}

enum OrbitSurfaceTone {
    case neutral
    case accent
    case success
    case warning
    case danger
}

private struct OrbitSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tone: OrbitSurfaceTone
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background(shape.fill(baseFillStyle))
            .overlay(shape.fill(tintFillStyle))
            .overlay(shape.strokeBorder(strokeColor, lineWidth: 1))
    }

    private var baseFillStyle: AnyShapeStyle {
        switch tone {
        case .neutral:
            return AnyShapeStyle(OrbitPalette.panel)
        case .accent:
            return AnyShapeStyle(OrbitPalette.accentSoft)
        case .success:
            return AnyShapeStyle(isDarkScheme ? OrbitPalette.panel : OrbitPalette.successSoft)
        case .warning:
            return AnyShapeStyle(isDarkScheme ? OrbitPalette.panel : OrbitPalette.warningSoft)
        case .danger:
            return AnyShapeStyle(isDarkScheme ? OrbitPalette.panel : OrbitPalette.dangerSoft)
        }
    }

    private var tintFillStyle: AnyShapeStyle {
        switch tone {
        case .neutral:
            return AnyShapeStyle(Color.clear)
        case .accent:
            return AnyShapeStyle(Color.clear)
        case .success:
            return AnyShapeStyle(isDarkScheme ? OrbitPalette.successSoft.opacity(0.38) : Color.clear)
        case .warning:
            return AnyShapeStyle(isDarkScheme ? OrbitPalette.warningSoft.opacity(0.42) : Color.clear)
        case .danger:
            return AnyShapeStyle(isDarkScheme ? OrbitPalette.dangerSoft.opacity(0.42) : Color.clear)
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .neutral:
            return OrbitPalette.divider
        case .accent:
            return OrbitPalette.accent.opacity(0.18)
        case .success:
            return Color.green.opacity(0.18)
        case .warning:
            return Color.yellow.opacity(0.18)
        case .danger:
            return Color.red.opacity(0.18)
        }
    }

    private var isDarkScheme: Bool {
        colorScheme == .dark
    }
}

extension View {
    func orbitSurface(_ tone: OrbitSurfaceTone = .neutral, radius: CGFloat = OrbitRadius.panel) -> some View {
        modifier(OrbitSurfaceModifier(tone: tone, radius: radius))
    }
}
