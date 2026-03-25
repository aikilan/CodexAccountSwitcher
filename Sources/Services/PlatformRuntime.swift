import Foundation

struct PlatformCapabilities: Equatable, Sendable {
    let supportsAccountAddition: Bool
    let supportsStatusRefresh: Bool
    let supportsCLILaunch: Bool
    let supportsDesktopLaunch: Bool
    let supportsQuotaMonitoring: Bool
    let supportsRuntimeInspection: Bool

    static let codex = PlatformCapabilities(
        supportsAccountAddition: true,
        supportsStatusRefresh: true,
        supportsCLILaunch: true,
        supportsDesktopLaunch: true,
        supportsQuotaMonitoring: true,
        supportsRuntimeInspection: true
    )

    static let placeholder = PlatformCapabilities(
        supportsAccountAddition: false,
        supportsStatusRefresh: false,
        supportsCLILaunch: false,
        supportsDesktopLaunch: false,
        supportsQuotaMonitoring: false,
        supportsRuntimeInspection: false
    )
}

protocol PlatformRuntime: Sendable {
    var platform: PlatformKind { get }
    var displayName: String { get }
    var capabilities: PlatformCapabilities { get }
}

struct CodexPlatformRuntime: PlatformRuntime {
    let platform: PlatformKind = .codex
    let displayName = "Codex"
    let capabilities = PlatformCapabilities.codex
}

struct ClaudePlatformRuntime: PlatformRuntime {
    let platform: PlatformKind = .claude
    let displayName = "Claude"
    let capabilities = PlatformCapabilities.placeholder
}
