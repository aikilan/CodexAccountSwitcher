import Darwin
import Foundation

enum CodexLocalThreadMaterializerError: LocalizedError {
    case appServerError(String)
    case invalidResponse(String)
    case processExited(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .appServerError(message):
            return L10n.tr("Codex app-server 返回错误：%@", message)
        case let .invalidResponse(message):
            return L10n.tr("Codex app-server 响应格式无效：%@", message)
        case let .processExited(message):
            return L10n.tr("Codex app-server 已退出：%@", message)
        case let .timedOut(message):
            return L10n.tr("Codex app-server 等待超时：%@", message)
        }
    }
}

final class CodexLocalThreadMaterializer: @unchecked Sendable {
    private let fileManager: FileManager
    private let executableURL: @Sendable () -> URL
    private let baseArguments: @Sendable () -> [String]
    private let loginShellSearchPath: @Sendable () -> String?
    private let runProcess: @Sendable (Process) throws -> Void

    init(
        fileManager: FileManager = .default,
        executableURL: @escaping @Sendable () -> URL = { URL(fileURLWithPath: "/usr/bin/env", isDirectory: false) },
        baseArguments: @escaping @Sendable () -> [String] = { ["codex"] },
        loginShellSearchPath: @escaping @Sendable () -> String? = { resolveCodexLoginShellSearchPath() },
        runProcess: @escaping @Sendable (Process) throws -> Void = { try $0.run() }
    ) {
        self.fileManager = fileManager
        self.executableURL = executableURL
        self.baseArguments = baseArguments
        self.loginShellSearchPath = loginShellSearchPath
        self.runProcess = runProcess
    }
}

extension CodexLocalThreadMaterializer: CodexLocalThreadMaterializing {
    func materializeCopilotSessionQueueItem(
        _ item: CopilotSessionQueueItem,
        context: ResolvedCodexLocalThreadMaterializationContext,
        initialPrompt: String,
        developerInstructions: String
    ) async throws -> MaterializedCodexThread {
        try await Task.detached(priority: .userInitiated) {
            try self.materializeCopilotSessionQueueItemSync(
                item,
                context: context,
                initialPrompt: initialPrompt,
                developerInstructions: developerInstructions
            )
        }.value
    }
}

private extension CodexLocalThreadMaterializer {
    func materializeCopilotSessionQueueItemSync(
        _ item: CopilotSessionQueueItem,
        context: ResolvedCodexLocalThreadMaterializationContext,
        initialPrompt: String,
        developerInstructions: String
    ) throws -> MaterializedCodexThread {
        let client = try makeClient(context: context)
        defer { client.close() }

        _ = try client.send(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "orbit",
                    "title": "Orbit",
                    "version": "1",
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ]
        )

        let startResult = try client.send(
            method: "thread/start",
            params: [
                "cwd": item.workspacePath,
                "serviceName": "Orbit Copilot Handoff",
                "developerInstructions": developerInstructions,
                "ephemeral": false,
                "experimentalRawEvents": false,
                "persistExtendedHistory": true,
            ]
        )
        let thread = try materializedThread(from: startResult)

        _ = try client.send(
            method: "thread/name/set",
            params: [
                "threadId": thread.id,
                "name": item.title,
            ]
        )

        let turnResult = try client.send(
            method: "turn/start",
            params: turnStartParams(
                threadID: thread.id,
                item: item,
                startResult: startResult,
                initialPrompt: initialPrompt
            )
        )
        let turnID = try materializedTurnID(from: turnResult)
        do {
            try client.waitForUserMessageCompleted(threadID: thread.id, turnID: turnID)
        } catch CodexLocalThreadMaterializerError.timedOut {
            guard try client.threadHasTurn(threadID: thread.id, turnID: turnID) else {
                throw CodexLocalThreadMaterializerError.timedOut("first user message materialization")
            }
        }
        _ = try client.send(
            method: "turn/interrupt",
            params: [
                "threadId": thread.id,
                "turnId": turnID,
            ]
        )
        do {
            try client.waitForTurnCompleted(threadID: thread.id, turnID: turnID)
        } catch CodexLocalThreadMaterializerError.timedOut {
            try client.waitForReadableCompletedTurn(threadID: thread.id, turnID: turnID)
        }
        try client.verifyThreadReadable(threadID: thread.id, turnID: turnID)

        return thread
    }

    func makeClient(context: ResolvedCodexLocalThreadMaterializationContext) throws -> CodexAppServerJSONLClient {
        let process = Process()
        process.executableURL = executableURL()
        process.arguments = baseArguments() + [
            "app-server",
            "--listen",
            "stdio://",
            "--session-source",
            "vscode",
        ]
        process.currentDirectoryURL = context.workingDirectoryURL
        process.environment = try environment(for: context)

        return try CodexAppServerJSONLClient(process: process, runProcess: runProcess)
    }

    func environment(for context: ResolvedCodexLocalThreadMaterializationContext) throws -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in context.environmentVariables {
            environment[key] = value
        }
        environment["PATH"] = executableSearchPath(inheritedPath: environment["PATH"])

        if let codexHomeURL = context.codexHomeURL {
            try CodexManagedHomeWriter(fileManager: fileManager).prepareManagedHome(
                codexHomeURL: codexHomeURL,
                authPayload: context.authPayload,
                configFileContents: context.configFileContents,
                modelCatalogSnapshot: context.modelCatalogSnapshot
            )
            environment["CODEX_HOME"] = codexHomeURL.path
        }

        return environment
    }

    func executableSearchPath(inheritedPath: String?) -> String {
        joinedSearchPath([
            inheritedPath,
            loginShellSearchPath(),
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ])
    }

    func materializedThread(from result: [String: Any]) throws -> MaterializedCodexThread {
        guard let thread = result["thread"] as? [String: Any] else {
            throw CodexLocalThreadMaterializerError.invalidResponse("thread/start 缺少 thread")
        }
        guard let id = thread["id"] as? String, !id.isEmpty else {
            throw CodexLocalThreadMaterializerError.invalidResponse("thread/start 缺少 thread.id")
        }
        return MaterializedCodexThread(
            id: id,
            path: thread["path"] as? String
        )
    }

    func materializedTurnID(from result: [String: Any]) throws -> String {
        guard let turn = result["turn"] as? [String: Any] else {
            throw CodexLocalThreadMaterializerError.invalidResponse("turn/start 缺少 turn")
        }
        guard let id = turn["id"] as? String, !id.isEmpty else {
            throw CodexLocalThreadMaterializerError.invalidResponse("turn/start 缺少 turn.id")
        }
        return id
    }

    func turnStartParams(
        threadID: String,
        item: CopilotSessionQueueItem,
        startResult: [String: Any],
        initialPrompt: String
    ) -> [String: Any] {
        [
            "threadId": threadID,
            "input": [
                [
                    "type": "text",
                    "text": initialPrompt,
                    "text_elements": [],
                ],
            ],
            "cwd": startResult["cwd"] as? String ?? item.workspacePath,
            "approvalPolicy": "never",
            "sandboxPolicy": [
                "type": "readOnly",
            ],
            "model": startResult["model"] ?? NSNull(),
            "effort": startResult["reasoningEffort"] ?? NSNull(),
            "serviceTier": startResult["serviceTier"] ?? NSNull(),
            "summary": "auto",
            "personality": NSNull(),
            "outputSchema": NSNull(),
            "collaborationMode": NSNull(),
        ]
    }

    func joinedSearchPath(_ searchPaths: [String?]) -> String {
        var seen = Set<String>()
        var paths: [String] = []
        for searchPath in searchPaths {
            for path in searchPath?.split(separator: ":").map(String.init) ?? [] {
                guard !path.isEmpty, seen.insert(path).inserted else { continue }
                paths.append(path)
            }
        }
        return paths.joined(separator: ":")
    }
}

private final class CodexAppServerJSONLClient {
    private static let userMessageWaitTimeout: TimeInterval = 60
    private static let turnCompletedNotificationWaitTimeout: TimeInterval = 5
    private static let readableTurnWaitTimeout: TimeInterval = 10

    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var requestCounter = 0
    private var notifications: [[String: Any]] = []

    init(
        process: Process,
        runProcess: (Process) throws -> Void
    ) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        stdin = inputPipe.fileHandleForWriting
        stdout = outputPipe.fileHandleForReading
        stderr = errorPipe.fileHandleForReading

        try runProcess(process)
    }

    func send(method: String, params: [String: Any]) throws -> [String: Any] {
        requestCounter += 1
        let id = "orbit-\(requestCounter)"
        try write([
            "id": id,
            "method": method,
            "params": params,
        ])

        while true {
            guard let line = readLine() else {
                throw CodexLocalThreadMaterializerError.processExited(stderrText())
            }
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            guard (object["id"] as? String) == id else {
                if object["method"] is String {
                    notifications.append(object)
                }
                continue
            }
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? String(describing: error)
                throw CodexLocalThreadMaterializerError.appServerError(message)
            }
            guard let result = object["result"] as? [String: Any] else {
                throw CodexLocalThreadMaterializerError.invalidResponse(method)
            }
            return result
        }
    }

    func waitForUserMessageCompleted(threadID: String, turnID: String) throws {
        try waitForNotification(
            description: "userMessage item/completed",
            timeout: Self.userMessageWaitTimeout,
            matches: { object in
                guard object["method"] as? String == "item/completed",
                      let params = object["params"] as? [String: Any],
                      params["threadId"] as? String == threadID,
                      let item = params["item"] as? [String: Any],
                      item["type"] as? String == "userMessage"
                else {
                    return false
                }
                let notificationTurnID = params["turnId"] as? String
                return notificationTurnID == nil || notificationTurnID == turnID
            }
        )
    }

    func waitForTurnCompleted(threadID: String, turnID: String) throws {
        try waitForNotification(
            description: "turn/completed",
            timeout: Self.turnCompletedNotificationWaitTimeout,
            matches: { object in
                guard object["method"] as? String == "turn/completed",
                      let params = object["params"] as? [String: Any],
                      params["threadId"] as? String == threadID,
                      let turn = params["turn"] as? [String: Any],
                      turn["id"] as? String == turnID
                else {
                    return false
                }
                return true
            }
        )
    }

    func verifyThreadReadable(threadID: String, turnID: String) throws {
        let status = try readTurnStatus(threadID: threadID, turnID: turnID)
        guard status != "inProgress" else {
            throw CodexLocalThreadMaterializerError.timedOut("turn/completed")
        }
    }

    func waitForReadableCompletedTurn(threadID: String, turnID: String) throws {
        let deadline = Date().addingTimeInterval(Self.readableTurnWaitTimeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                try verifyThreadReadable(threadID: threadID, turnID: turnID)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        if let lastError {
            throw lastError
        }
        throw CodexLocalThreadMaterializerError.timedOut("turn/completed")
    }

    func threadHasTurn(threadID: String, turnID: String) throws -> Bool {
        do {
            let result = try readThread(threadID: threadID)
            guard let thread = result["thread"] as? [String: Any],
                  let turns = thread["turns"] as? [[String: Any]]
            else {
                throw CodexLocalThreadMaterializerError.invalidResponse("thread/read 缺少 turns")
            }
            return turns.contains { $0["id"] as? String == turnID }
        } catch CodexLocalThreadMaterializerError.appServerError(let message)
            where message.contains("not materialized yet") {
            return false
        }
    }

    func close() {
        try? stdin.close()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func waitForNotification(
        description: String,
        timeout: TimeInterval,
        matches: ([String: Any]) -> Bool
    ) throws {
        if let index = notifications.firstIndex(where: matches) {
            notifications.remove(at: index)
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let line = readLine(deadline: deadline) else {
                if process.isRunning {
                    throw CodexLocalThreadMaterializerError.timedOut(description)
                }
                throw CodexLocalThreadMaterializerError.processExited(stderrText())
            }
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if matches(object) {
                return
            }
            if object["method"] is String {
                notifications.append(object)
            }
        }

        throw CodexLocalThreadMaterializerError.timedOut(description)
    }

    private func readThread(threadID: String) throws -> [String: Any] {
        try send(
            method: "thread/read",
            params: [
                "threadId": threadID,
                "includeTurns": true,
            ]
        )
    }

    private func readTurnStatus(threadID: String, turnID: String) throws -> String {
        let result = try readThread(threadID: threadID)
        guard let thread = result["thread"] as? [String: Any],
              let turns = thread["turns"] as? [[String: Any]],
              let turn = turns.first(where: { $0["id"] as? String == turnID })
        else {
            throw CodexLocalThreadMaterializerError.invalidResponse("thread/read 缺少已创建的 turn")
        }
        guard let status = turn["status"] as? String else {
            throw CodexLocalThreadMaterializerError.invalidResponse("thread/read 缺少 turn.status")
        }
        return status
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        stdin.write(data)
        stdin.write(Data([0x0A]))
    }

    private func readLine(deadline: Date? = nil) -> String? {
        var data = Data()
        while true {
            if let deadline, !waitForReadableByte(until: deadline) {
                return nil
            }
            let byte = stdout.readData(ofLength: 1)
            if byte.isEmpty {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if byte[byte.startIndex] == 0x0A {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
    }

    private func waitForReadableByte(until deadline: Date) -> Bool {
        var descriptor = pollfd(fd: stdout.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            let timeoutMs = max(1, Int(deadline.timeIntervalSinceNow * 1000))
            let result = poll(&descriptor, 1, Int32(timeoutMs))
            if result > 0 {
                return descriptor.revents & Int16(POLLIN) != 0
            }
            if result == 0 {
                return false
            }
            if errno != EINTR {
                return false
            }
        }
        return false
    }

    private func stderrText() -> String {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        return String(data: stderr.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? L10n.tr("未知错误")
    }
}

private func resolveCodexLoginShellSearchPath() -> String? {
    let shellPath = ProcessInfo.processInfo.environment["SHELL"]?.nilIfEmpty ?? "/bin/zsh"
    guard FileManager.default.isExecutableFile(atPath: shellPath) else { return nil }

    let marker = "__ORBIT_LOGIN_PATH__"
    let process = Process()
    let stdoutPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: shellPath, isDirectory: false)
    process.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)%s\\n' \"$PATH\""]
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    guard process.terminationStatus == 0 else { return nil }
    let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output
        .split(separator: "\n")
        .last { $0.hasPrefix(marker) }
        .map { String($0.dropFirst(marker.count)) }?
        .nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
