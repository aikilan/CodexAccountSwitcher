import Foundation

enum ClaudeProfileSnapshotManagerError: LocalizedError, Equatable {
    case missingCurrentProfile
    case missingSnapshot

    var errorDescription: String? {
        switch self {
        case .missingCurrentProfile:
            return L10n.tr("没有找到当前 Claude Profile。")
        case .missingSnapshot:
            return L10n.tr("没有找到已保存的 Claude Profile 快照。")
        }
    }
}

struct ClaudeProfileSnapshotManager: @unchecked Sendable {
    private let paths: AppPaths
    private let fileManager: FileManager

    init(paths: AppPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func currentProfileExists() -> Bool {
        let claudePaths = paths.paths(for: .claude)
        let hasHome = fileManager.fileExists(atPath: claudePaths.homeURL.path)
        let hasSettings = claudePaths.userSettingsFileURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        return hasHome || hasSettings
    }

    func importCurrentProfile() throws -> ClaudeProfileSnapshotRef {
        guard currentProfileExists() else {
            throw ClaudeProfileSnapshotManagerError.missingCurrentProfile
        }

        let snapshotRef = ClaudeProfileSnapshotRef(snapshotID: UUID().uuidString)
        let snapshotRootURL = snapshotRootURL(for: snapshotRef)
        try fileManager.createDirectory(at: snapshotRootURL, withIntermediateDirectories: true)
        try materializeCurrentProfile(at: snapshotRootURL)
        return snapshotRef
    }

    func activateProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws {
        let snapshotRootURL = snapshotRootURL(for: snapshotRef)
        guard fileManager.fileExists(atPath: snapshotRootURL.path) else {
            throw ClaudeProfileSnapshotManagerError.missingSnapshot
        }

        let claudePaths = paths.paths(for: .claude)
        try replaceDirectory(
            sourceURL: snapshotHomeURL(for: snapshotRootURL),
            destinationURL: claudePaths.homeURL,
            createIfMissing: true
        )
        try replaceFile(
            sourceURL: snapshotSettingsURL(for: snapshotRootURL),
            destinationURL: claudePaths.userSettingsFileURL
        )
    }

    func deleteProfile(_ snapshotRef: ClaudeProfileSnapshotRef) throws {
        let snapshotRootURL = snapshotRootURL(for: snapshotRef)
        guard fileManager.fileExists(atPath: snapshotRootURL.path) else { return }
        try fileManager.removeItem(at: snapshotRootURL)
    }

    func prepareIsolatedProfileRoot(for accountID: UUID, snapshotRef: ClaudeProfileSnapshotRef) throws -> URL {
        let rootURL = isolatedRootURL(for: accountID, modeName: "profile")
        try prepareEmptyRoot(at: rootURL)
        let snapshotRootURL = snapshotRootURL(for: snapshotRef)
        guard fileManager.fileExists(atPath: snapshotRootURL.path) else {
            throw ClaudeProfileSnapshotManagerError.missingSnapshot
        }
        try materializeSnapshot(from: snapshotRootURL, to: rootURL)
        return rootURL
    }

    func prepareIsolatedAPIKeyRoot(for accountID: UUID) throws -> URL {
        let rootURL = isolatedRootURL(for: accountID, modeName: "api-key")
        try prepareEmptyRoot(at: rootURL)
        try materializeCurrentProfile(at: rootURL)
        return rootURL
    }

    private func materializeCurrentProfile(at rootURL: URL) throws {
        let claudePaths = paths.paths(for: .claude)
        try copyDirectory(
            from: claudePaths.homeURL,
            to: snapshotHomeURL(for: rootURL),
            createIfMissing: true
        )
        try copyFile(
            from: claudePaths.userSettingsFileURL,
            to: snapshotSettingsURL(for: rootURL)
        )
    }

    private func materializeSnapshot(from snapshotRootURL: URL, to rootURL: URL) throws {
        try copyDirectory(
            from: snapshotHomeURL(for: snapshotRootURL),
            to: rootURL.appendingPathComponent(".claude", isDirectory: true),
            createIfMissing: true
        )
        try copyFile(
            from: snapshotSettingsURL(for: snapshotRootURL),
            to: rootURL.appendingPathComponent(".claude.json")
        )
    }

    private func prepareEmptyRoot(at rootURL: URL) throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func replaceDirectory(sourceURL: URL, destinationURL: URL, createIfMissing: Bool) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try copyDirectory(from: sourceURL, to: destinationURL, createIfMissing: createIfMissing)
    }

    private func replaceFile(sourceURL: URL, destinationURL: URL?) throws {
        guard let destinationURL else { return }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try copyFile(from: sourceURL, to: destinationURL)
    }

    private func copyDirectory(from sourceURL: URL, to destinationURL: URL, createIfMissing: Bool) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            if createIfMissing {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            }
            return
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func copyFile(from sourceURL: URL?, to destinationURL: URL?) throws {
        guard let sourceURL, let destinationURL, fileManager.fileExists(atPath: sourceURL.path) else { return }
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func snapshotRootURL(for snapshotRef: ClaudeProfileSnapshotRef) -> URL {
        paths.appSupportDirectoryURL
            .appendingPathComponent("claude-profiles", isDirectory: true)
            .appendingPathComponent(snapshotRef.snapshotID, isDirectory: true)
    }

    private func snapshotHomeURL(for rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".claude", isDirectory: true)
    }

    private func snapshotSettingsURL(for rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".claude.json")
    }

    private func isolatedRootURL(for accountID: UUID, modeName: String) -> URL {
        paths.appSupportDirectoryURL
            .appendingPathComponent("isolated-claude-cli", isDirectory: true)
            .appendingPathComponent(accountID.uuidString, isDirectory: true)
            .appendingPathComponent(modeName, isDirectory: true)
    }
}

extension ClaudeProfileSnapshotManager: ClaudeProfileManaging {}
