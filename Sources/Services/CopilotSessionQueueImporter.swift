import Foundation
import SQLite3

struct CopilotSessionCandidate: Identifiable, Equatable, Sendable {
    var workspacePath: String
    var workspaceStorageID: String
    var workspaceStoragePath: String
    var sessionID: String
    var title: String
    var createdAt: Date?
    var lastMessageAt: Date
    var modelID: String?
    var hasPendingEdits: Bool
    var lastResponseState: String?

    var id: String {
        "\(workspacePath)|\(sessionID)|\(lastMessageAt.timeIntervalSince1970)"
    }
}

enum CopilotSessionQueueImporterError: LocalizedError, Equatable {
    case workspaceStorageNotFound(String)
    case sessionIndexNotFound(String)
    case sessionFileNotFound(String)
    case sqliteReadFailed(String)
    case invalidIndex

    var errorDescription: String? {
        switch self {
        case let .workspaceStorageNotFound(path):
            return L10n.tr("没有找到 VSCode Stable 的 workspaceStorage 记录：%@", path)
        case let .sessionIndexNotFound(path):
            return L10n.tr("没有找到该目录的 Copilot Chat session 索引：%@", path)
        case let .sessionFileNotFound(sessionID):
            return L10n.tr("没有找到 Copilot session 文件：%@", sessionID)
        case let .sqliteReadFailed(message):
            return L10n.tr("读取 VSCode 状态数据库失败：%@", message)
        case .invalidIndex:
            return L10n.tr("Copilot Chat session 索引格式无法识别。")
        }
    }
}

final class CopilotSessionQueueImporter: @unchecked Sendable, CopilotSessionQueueImporting {
    private static let sessionIndexKey = "chat.ChatSessionStore.index"

    private let homeDirectoryURL: URL
    private let appSupportDirectoryURL: URL
    private let fileManager: FileManager

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSupportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.appSupportDirectoryURL = appSupportDirectoryURL
        self.fileManager = fileManager
    }

    func sessions(for workspaceURL: URL) throws -> [CopilotSessionCandidate] {
        let workspace = try workspaceStorage(for: workspaceURL)
        let stateURL = workspace.storageURL.appendingPathComponent("state.vscdb", isDirectory: false)
        guard let indexData = try sqliteValue(forKey: Self.sessionIndexKey, databaseURL: stateURL) else {
            throw CopilotSessionQueueImporterError.sessionIndexNotFound(workspace.workspacePath)
        }

        return try parseCandidates(
            indexData: indexData,
            workspacePath: workspace.workspacePath,
            workspaceStorageID: workspace.storageID,
            workspaceStoragePath: workspace.storageURL.path
        )
    }

    func importSession(_ candidate: CopilotSessionCandidate) throws -> CopilotSessionQueueItem {
        let queueID = UUID()
        let queueDirectoryURL = appSupportDirectoryURL
            .appendingPathComponent("copilot-session-queue", isDirectory: true)
            .appendingPathComponent(queueID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: queueDirectoryURL, withIntermediateDirectories: true)

        let workspaceStorageURL = URL(fileURLWithPath: candidate.workspaceStoragePath, isDirectory: true)
        let rawSessionURL = try copyRawSession(
            sessionID: candidate.sessionID,
            from: workspaceStorageURL,
            to: queueDirectoryURL
        )
        let editingStateURL = try copyEditingState(
            sessionID: candidate.sessionID,
            from: workspaceStorageURL,
            to: queueDirectoryURL
        )
        let handoffURL = queueDirectoryURL.appendingPathComponent("handoff.md", isDirectory: false)
        let handoff = try buildHandoff(
            candidate: candidate,
            rawSessionURL: rawSessionURL,
            editingStateURL: editingStateURL
        )
        try handoff.write(to: handoffURL, atomically: true, encoding: .utf8)

        return CopilotSessionQueueItem(
            id: queueID,
            workspacePath: candidate.workspacePath,
            workspaceStorageID: candidate.workspaceStorageID,
            sessionID: candidate.sessionID,
            title: candidate.title,
            createdAt: candidate.createdAt,
            lastMessageAt: candidate.lastMessageAt,
            importedAt: Date(),
            status: .pending,
            handoffDirectoryPath: queueDirectoryURL.path,
            handoffFilePath: handoffURL.path,
            rawSessionFilePath: rawSessionURL?.path,
            editingStateFilePath: editingStateURL?.path,
            lastSentAt: nil,
            lastExecutionTarget: nil
        )
    }

    private struct WorkspaceStorageMatch {
        let workspacePath: String
        let storageID: String
        let storageURL: URL
    }

    private func workspaceStorage(for workspaceURL: URL) throws -> WorkspaceStorageMatch {
        let normalizedPath = workspaceURL.standardizedFileURL.path
        let storageRootURL = homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Code", isDirectory: true)
            .appendingPathComponent("User", isDirectory: true)
            .appendingPathComponent("workspaceStorage", isDirectory: true)

        let storageURLs = try fileManager.contentsOfDirectory(
            at: storageRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for storageURL in storageURLs {
            guard try storageURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                continue
            }
            let workspaceJSONURL = storageURL.appendingPathComponent("workspace.json", isDirectory: false)
            guard let recordedPath = try workspacePath(in: workspaceJSONURL), recordedPath == normalizedPath else {
                continue
            }
            return WorkspaceStorageMatch(
                workspacePath: recordedPath,
                storageID: storageURL.lastPathComponent,
                storageURL: storageURL
            )
        }

        throw CopilotSessionQueueImporterError.workspaceStorageNotFound(normalizedPath)
    }

    private func workspacePath(in workspaceJSONURL: URL) throws -> String? {
        guard fileManager.fileExists(atPath: workspaceJSONURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: workspaceJSONURL)
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let uri = object["folder"] as? String ?? object["workspace"] as? String
        else {
            return nil
        }
        guard let url = URL(string: uri), url.isFileURL else {
            return nil
        }
        return url.standardizedFileURL.path
    }

    private func sqliteValue(forKey key: String, databaseURL: URL) throws -> Data? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? databaseURL.path
            throw CopilotSessionQueueImporterError.sqliteReadFailed(message)
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CopilotSessionQueueImporterError.sqliteReadFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        if let bytes = sqlite3_column_blob(statement, 0) {
            let length = Int(sqlite3_column_bytes(statement, 0))
            return Data(bytes: bytes, count: length)
        }
        if let text = sqlite3_column_text(statement, 0) {
            return Data(String(cString: text).utf8)
        }
        return nil
    }

    private func parseCandidates(
        indexData: Data,
        workspacePath: String,
        workspaceStorageID: String,
        workspaceStoragePath: String
    ) throws -> [CopilotSessionCandidate] {
        guard
            let root = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
            let entriesObject = root["entries"]
        else {
            throw CopilotSessionQueueImporterError.invalidIndex
        }

        let entries: [(String, [String: Any])]
        if let dictionary = entriesObject as? [String: Any] {
            entries = dictionary.compactMap { key, value in
                (value as? [String: Any]).map { (key, $0) }
            }
        } else if let array = entriesObject as? [[String: Any]] {
            entries = array.compactMap { value in
                guard let sessionID = value["sessionId"] as? String else { return nil }
                return (sessionID, value)
            }
        } else {
            throw CopilotSessionQueueImporterError.invalidIndex
        }

        return entries.compactMap { key, value in
            let sessionID = value["sessionId"] as? String ?? key
            guard (value["isEmpty"] as? Bool) != true else { return nil }
            let lastMessageAt = date(from: value["lastMessageDate"]) ?? .distantPast
            return CopilotSessionCandidate(
                workspacePath: workspacePath,
                workspaceStorageID: workspaceStorageID,
                workspaceStoragePath: workspaceStoragePath,
                sessionID: sessionID,
                title: (value["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? L10n.tr("未命名 Copilot Session"),
                createdAt: date(from: value["creationDate"] ?? nestedValue(value["timing"], key: "startTime")),
                lastMessageAt: lastMessageAt,
                modelID: value["modelId"] as? String,
                hasPendingEdits: value["hasPendingEdits"] as? Bool ?? false,
                lastResponseState: value["lastResponseState"].map { "\($0)" }
            )
        }
        .sorted { $0.lastMessageAt > $1.lastMessageAt }
    }

    private func copyRawSession(
        sessionID: String,
        from workspaceStorageURL: URL,
        to queueDirectoryURL: URL
    ) throws -> URL? {
        let sessionsDirectoryURL = workspaceStorageURL.appendingPathComponent("chatSessions", isDirectory: true)
        let candidates = [
            sessionsDirectoryURL.appendingPathComponent("\(sessionID).jsonl", isDirectory: false),
            sessionsDirectoryURL.appendingPathComponent("\(sessionID).json", isDirectory: false),
        ]
        guard let sourceURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw CopilotSessionQueueImporterError.sessionFileNotFound(sessionID)
        }

        let destinationURL = queueDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func copyEditingState(
        sessionID: String,
        from workspaceStorageURL: URL,
        to queueDirectoryURL: URL
    ) throws -> URL? {
        let sourceURL = workspaceStorageURL
            .appendingPathComponent("chatEditingSessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return nil
        }

        let destinationURL = queueDirectoryURL
            .appendingPathComponent("chatEditingSessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func buildHandoff(
        candidate: CopilotSessionCandidate,
        rawSessionURL: URL?,
        editingStateURL: URL?
    ) throws -> String {
        let transcript = rawSessionURL.flatMap { try? parseTranscript(from: $0) } ?? []
        let rawSessionText = rawSessionURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let editingStateText = editingStateURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

        var sections = [String]()
        sections.append("# Copilot Session Handoff")
        sections.append("""
        ## 元数据
        - Workspace: \(candidate.workspacePath)
        - Workspace Storage: \(candidate.workspaceStorageID)
        - Session ID: \(candidate.sessionID)
        - Title: \(candidate.title)
        - Created At: \(format(candidate.createdAt))
        - Last Message At: \(format(candidate.lastMessageAt))
        - Model: \(candidate.modelID ?? L10n.tr("未知"))
        - Pending Edits: \(candidate.hasPendingEdits ? "true" : "false")
        - Last Response State: \(candidate.lastResponseState ?? L10n.tr("未知"))
        - Raw Session File: \(rawSessionURL?.path ?? L10n.tr("无"))
        - Editing State File: \(editingStateURL?.path ?? L10n.tr("无"))
        """)
        sections.append("""
        ## 待接手说明
        请在同一 workspace 目录中继续这个 VSCode Copilot Chat session 的任务。不要把下面内容当成摘要；下方先给出按事件解析的对话与工具/编辑线索，随后附上原始 session JSONL 和编辑状态 JSON。
        """)

        if transcript.isEmpty {
            sections.append("## 解析后的对话\n未能从 session 文件解析出结构化对话，请直接查看后面的原始 session JSONL。")
        } else {
            sections.append("## 解析后的对话\n" + transcript.map(renderTranscriptRequest).joined(separator: "\n\n"))
        }

        sections.append("""
        ## 原始 session JSONL
        ```jsonl
        \(rawSessionText)
        ```
        """)

        if let editingStateText {
            sections.append("""
            ## 原始编辑状态
            ```json
            \(editingStateText)
            ```
            """)
        } else {
            sections.append("## 原始编辑状态\n没有找到对应的 `chatEditingSessions/<session>/state.json`。")
        }

        return sections.joined(separator: "\n\n") + "\n"
    }

    private struct TranscriptRequest {
        var index: Int
        var requestID: String?
        var timestamp: Date?
        var agent: String?
        var modelID: String?
        var message: String
        var contentReferences: [String]
        var editedFileEvents: [String]
        var responseItems: [String]
    }

    private func parseTranscript(from url: URL) throws -> [TranscriptRequest] {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard url.pathExtension == "jsonl" else {
            return [TranscriptRequest(
                index: 0,
                requestID: nil,
                timestamp: nil,
                agent: nil,
                modelID: nil,
                message: text,
                contentReferences: [],
                editedFileEvents: [],
                responseItems: []
            )]
        }

        var requests: [Int: TranscriptRequest] = [:]
        var nextRequestIndex = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard
                let data = String(line).data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let kind = event["kind"] as? Int
            else {
                continue
            }

            if kind == 0, let value = event["v"] as? [String: Any], let initialRequests = value["requests"] as? [[String: Any]] {
                for (index, requestObject) in initialRequests.enumerated() {
                    requests[index] = transcriptRequest(from: requestObject, index: index)
                    nextRequestIndex = max(nextRequestIndex, index + 1)
                }
                continue
            }

            guard let path = event["k"] as? [Any] else {
                continue
            }
            if kind == 2, isRequestsPath(path) {
                let values = arrayOrSingleDictionary(event["v"])
                for value in values {
                    requests[nextRequestIndex] = transcriptRequest(from: value, index: nextRequestIndex)
                    nextRequestIndex += 1
                }
            } else if isResponsePath(path), let requestIndex = path[safe: 1] as? Int {
                let items = arrayOrSingleValue(event["v"]).map(responseItemText)
                var request = requests[requestIndex] ?? TranscriptRequest(
                    index: requestIndex,
                    requestID: nil,
                    timestamp: nil,
                    agent: nil,
                    modelID: nil,
                    message: L10n.tr("未记录用户请求正文"),
                    contentReferences: [],
                    editedFileEvents: [],
                    responseItems: []
                )
                request.responseItems.append(contentsOf: items.filter { !$0.isEmpty })
                requests[requestIndex] = request
            }
        }

        return requests.keys.sorted().compactMap { requests[$0] }
    }

    private func transcriptRequest(from object: [String: Any], index: Int) -> TranscriptRequest {
        let message = textValue(object["message"]).nilIfEmpty
            ?? textValue(object["request"]).nilIfEmpty
            ?? prettyJSONString(object["message"] ?? object).nilIfEmpty
            ?? L10n.tr("未记录用户请求正文")
        return TranscriptRequest(
            index: index,
            requestID: object["requestId"] as? String,
            timestamp: date(from: object["timestamp"]),
            agent: object["agent"] as? String,
            modelID: object["modelId"] as? String,
            message: message,
            contentReferences: arrayOrSingleValue(object["contentReferences"]).compactMap(referenceText),
            editedFileEvents: arrayOrSingleValue(object["editedFileEvents"]).compactMap(referenceText),
            responseItems: arrayOrSingleValue(object["response"]).map(responseItemText).filter { !$0.isEmpty }
        )
    }

    private func renderTranscriptRequest(_ request: TranscriptRequest) -> String {
        var lines = [String]()
        lines.append("### Request \(request.index + 1)")
        if let requestID = request.requestID {
            lines.append("- Request ID: \(requestID)")
        }
        if let timestamp = request.timestamp {
            lines.append("- Timestamp: \(format(timestamp))")
        }
        if let agent = request.agent {
            lines.append("- Agent: \(agent)")
        }
        if let modelID = request.modelID {
            lines.append("- Model: \(modelID)")
        }
        lines.append("\n#### 用户请求\n\(request.message)")
        if !request.contentReferences.isEmpty {
            lines.append("\n#### 文件/内容引用\n" + request.contentReferences.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !request.editedFileEvents.isEmpty {
            lines.append("\n#### 编辑事件\n" + request.editedFileEvents.map { "- \($0)" }.joined(separator: "\n"))
        }
        if request.responseItems.isEmpty {
            lines.append("\n#### Copilot 回复\n未记录回复正文。")
        } else {
            lines.append("\n#### Copilot 回复与工具调用\n" + request.responseItems.joined(separator: "\n\n"))
        }
        return lines.joined(separator: "\n")
    }

    private func responseItemText(_ value: Any) -> String {
        guard let object = value as? [String: Any] else {
            return textValue(value).nilIfEmpty ?? prettyJSONString(value).nilIfEmpty ?? ""
        }

        var parts = [String]()
        if let kind = object["kind"] {
            parts.append("类型: \(kind)")
        }
        if let toolName = object["toolName"] as? String ?? object["name"] as? String {
            parts.append("工具: \(toolName)")
        }
        if let valueText = textValue(object["value"]).nilIfEmpty {
            parts.append(valueText)
        }
        if let toolData = object["toolSpecificData"], let pretty = prettyJSONString(toolData).nilIfEmpty {
            parts.append("工具数据:\n```json\n\(pretty)\n```")
        }
        if parts.count <= 1, let pretty = prettyJSONString(object).nilIfEmpty {
            parts.append("```json\n\(pretty)\n```")
        }
        return parts.joined(separator: "\n")
    }

    private func referenceText(_ value: Any) -> String? {
        if let text = textValue(value).nilIfEmpty {
            return text
        }
        return prettyJSONString(value).nilIfEmpty
    }

    private func isRequestsPath(_ path: [Any]) -> Bool {
        path.count == 1 && (path.first as? String) == "requests"
    }

    private func isResponsePath(_ path: [Any]) -> Bool {
        path.count == 3
            && (path[0] as? String) == "requests"
            && (path[2] as? String) == "response"
    }

    private func arrayOrSingleDictionary(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        if let dictionary = value as? [String: Any] {
            return [dictionary]
        }
        return []
    }

    private func arrayOrSingleValue(_ value: Any?) -> [Any] {
        if let array = value as? [Any] {
            return array
        }
        guard let value else { return [] }
        return [value]
    }

    private func textValue(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String {
            return string
        }
        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["text", "value", "content", "message"]
            let preferred = preferredKeys
                .map { textValue(dictionary[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !preferred.isEmpty {
                return preferred.joined(separator: "\n")
            }
            if let parts = dictionary["parts"] as? [Any] {
                return parts.map(textValue).filter { !$0.isEmpty }.joined(separator: "\n")
            }
            return ""
        }
        if let array = value as? [Any] {
            return array.map(textValue).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return "\(value)"
    }

    private func prettyJSONString(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            return ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func nestedValue(_ value: Any?, key: String) -> Any? {
        (value as? [String: Any])?[key]
    }

    private func date(from value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        }
        if let double = value as? Double {
            return Date(timeIntervalSince1970: double / 1000)
        }
        if let int = value as? Int {
            return Date(timeIntervalSince1970: Double(int) / 1000)
        }
        if let string = value as? String, let double = Double(string) {
            return Date(timeIntervalSince1970: double / 1000)
        }
        return nil
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return L10n.tr("未知") }
        return ISO8601DateFormatter().string(from: date)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
