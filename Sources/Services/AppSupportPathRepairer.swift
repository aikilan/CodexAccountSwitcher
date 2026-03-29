import Foundation

struct AppSupportPathRepairer: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func repairLegacyAbsolutePaths(in appSupportDirectoryURL: URL) throws -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: appSupportDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return false
        }

        let replacements = legacyRootReplacements(for: appSupportDirectoryURL)
        var didChange = false

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            guard shouldRepair(fileURL, in: appSupportDirectoryURL) else { continue }

            let permissions = try filePermissions(for: fileURL)
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let updatedContents = replacements.reduce(contents) { partialResult, replacement in
                partialResult.replacingOccurrences(of: replacement.legacyRoot, with: replacement.currentRoot)
            }
            guard updatedContents != contents else { continue }

            try updatedContents.write(to: fileURL, atomically: true, encoding: .utf8)
            if relativePathComponents(for: fileURL, in: appSupportDirectoryURL).suffix(2).elementsEqual(["bin", "claude"]),
               let permissions
            {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: fileURL.path)
            }
            didChange = true
        }

        return didChange
    }

    private func shouldRepair(_ fileURL: URL, in appSupportDirectoryURL: URL) -> Bool {
        let relativePath = relativePathComponents(for: fileURL, in: appSupportDirectoryURL)

        if relativePath.first == "claude-patched-runtimes",
           relativePath.suffix(2).elementsEqual(["bin", "claude"])
        {
            return true
        }

        if relativePath.first == "account-cli",
           relativePath.suffix(2).elementsEqual(["codex-home", "config.toml"])
        {
            return true
        }

        if relativePath.suffix(3).elementsEqual([".claude", "plugins", "known_marketplaces.json"]) {
            return true
        }

        return relativePath.last == "skills-curated-cache.json"
    }

    private func relativePathComponents(for fileURL: URL, in appSupportDirectoryURL: URL) -> [String] {
        Array(fileURL.standardizedFileURL.pathComponents.dropFirst(appSupportDirectoryURL.standardizedFileURL.pathComponents.count))
    }

    private func legacyRootReplacements(for appSupportDirectoryURL: URL) -> [(legacyRoot: String, currentRoot: String)] {
        let applicationSupportRoot = appSupportDirectoryURL.deletingLastPathComponent()
        return ["LLMAccountSwitcher", "CodexAccountSwitcher"].map { legacyDirectoryName in
            (
                applicationSupportRoot.appendingPathComponent(legacyDirectoryName, isDirectory: true).path,
                appSupportDirectoryURL.path
            )
        }
    }

    private func filePermissions(for fileURL: URL) throws -> NSNumber? {
        try fileManager.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
    }
}

extension AppSupportPathRepairer: AppSupportPathRepairing {}
