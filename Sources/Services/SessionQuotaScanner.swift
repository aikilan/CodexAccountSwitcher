import Foundation

final class SessionQuotaScanner: @unchecked Sendable {
    private let sessionsDirectoryURL: URL
    private let fileManager: FileManager
    private let startedAt: Date
    private var offsetsByPath: [String: UInt64] = [:]
    private var remainderByPath: [String: Data] = [:]

    init(sessionsDirectoryURL: URL, fileManager: FileManager = .default, startedAt: Date = Date()) {
        self.sessionsDirectoryURL = sessionsDirectoryURL
        self.fileManager = fileManager
        self.startedAt = startedAt
    }

    func seedOffsets() {
        for file in recentSessionFiles(limit: 40) {
            offsetsByPath[file.path] = fileSize(at: file)
        }
    }

    func latestExistingSnapshot() -> QuotaSnapshot? {
        for file in recentSessionFiles(limit: 30) {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n").reversed() {
                if let snapshot = snapshot(from: String(line), source: .importedBootstrap) {
                    return snapshot
                }
            }
        }
        return nil
    }

    func pollNewSnapshots() -> [QuotaSnapshot] {
        var snapshots: [QuotaSnapshot] = []

        for file in recentSessionFiles(limit: 40) {
            let path = file.path
            let fileSize = fileSize(at: file)

            if offsetsByPath[path] == nil {
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                offsetsByPath[path] = modDate > startedAt ? 0 : fileSize
            }

            let previousOffset = min(offsetsByPath[path] ?? 0, fileSize)
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }

            do {
                try handle.seek(toOffset: previousOffset)
                var data = remainderByPath[path] ?? Data()
                data.append(try handle.readToEnd() ?? Data())
                guard !data.isEmpty else { continue }

                let text = String(decoding: data, as: UTF8.self)
                let endedWithNewline = text.hasSuffix("\n")
                var lines = text.components(separatedBy: "\n")
                let trailing = endedWithNewline ? nil : lines.popLast()
                remainderByPath[path] = trailing.map { Data($0.utf8) } ?? Data()
                offsetsByPath[path] = fileSize - UInt64(remainderByPath[path]?.count ?? 0)

                for line in lines where !line.isEmpty {
                    if let snapshot = snapshot(from: line, source: .sessionTokenCount) {
                        snapshots.append(snapshot)
                    }
                }
            } catch {
                continue
            }
        }

        return snapshots.sorted(by: { $0.capturedAt < $1.capturedAt })
    }

    private func recentSessionFiles(limit: Int) -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: sessionsDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let files = enumerator.compactMap { element -> URL? in
            guard let url = element as? URL else { return nil }
            guard url.pathExtension == "jsonl" else { return nil }
            return url
        }

        return files
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .prefix(limit)
            .map { $0 }
    }

    private func fileSize(at url: URL) -> UInt64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func snapshot(from line: String, source: QuotaSnapshotSource) -> QuotaSnapshot? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let event = try? JSONDecoder().decode(SessionTokenCountEnvelope.self, from: data) else { return nil }
        guard event.payload.type == "token_count", let rateLimits = event.payload.rateLimits else { return nil }

        return QuotaSnapshot(
            primary: RateLimitWindowSnapshot(
                usedPercent: rateLimits.primary.usedPercent,
                windowMinutes: rateLimits.primary.windowMinutes,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(rateLimits.primary.resetsAt))
            ),
            secondary: RateLimitWindowSnapshot(
                usedPercent: rateLimits.secondary.usedPercent,
                windowMinutes: rateLimits.secondary.windowMinutes,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(rateLimits.secondary.resetsAt))
            ),
            credits: rateLimits.credits.map {
                CreditsSnapshot(hasCredits: $0.hasCredits, unlimited: $0.unlimited, balance: $0.balance)
            },
            planType: rateLimits.planType,
            capturedAt: CodexDateCoding.parse(event.timestamp) ?? Date(),
            source: source
        )
    }
}

private struct SessionTokenCountEnvelope: Decodable {
    let timestamp: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    struct RateLimits: Decodable {
        let primary: Window
        let secondary: Window
        let credits: Credits?
        let planType: String?

        struct Window: Decodable {
            let usedPercent: Double
            let windowMinutes: Int
            let resetsAt: Int

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }
        }

        struct Credits: Decodable {
            let hasCredits: Bool
            let unlimited: Bool
            let balance: Double?

            enum CodingKeys: String, CodingKey {
                case hasCredits = "has_credits"
                case unlimited
                case balance
            }
        }

        enum CodingKeys: String, CodingKey {
            case primary
            case secondary
            case credits
            case planType = "plan_type"
        }
    }
}
