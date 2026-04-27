import Foundation
import XCTest
@testable import Orbit

final class CodexLocalThreadMaterializerTests: XCTestCase {
    func testMaterializeUsesAppServerThreadStartAndNameRequests() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scriptURL = root.appendingPathComponent("fake-codex-app-server.sh", isDirectory: false)
        let captureURL = root.appendingPathComponent("requests.log", isDirectory: false)
        let codexHomeURL = root.appendingPathComponent("codex-home", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("next-erp-h5", isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf 'ARGS:%s\\n' "$*" > "$CAPTURE_PATH"
        printf 'CODEX_HOME:%s\\n' "$CODEX_HOME" >> "$CAPTURE_PATH"
        printf 'PATH:%s\\n' "$PATH" >> "$CAPTURE_PATH"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$CAPTURE_PATH"
          case "$line" in
            *'"id":"orbit-1"'*) printf '{"id":"orbit-1","result":{"userAgent":"test","platformFamily":"unix","platformOs":"macos"}}\\n' ;;
            *'"id":"orbit-2"'*) printf '{"method":"thread/started","params":{"thread":{"id":"ignored"}}}\\n'; printf '{"id":"orbit-2","result":{"thread":{"id":"thread-local-1","path":"/tmp/thread-local-1.jsonl"}}}\\n' ;;
            *'"id":"orbit-3"'*) printf '{"id":"orbit-3","result":{}}\\n' ;;
            *'"id":"orbit-4"'*) printf '{"id":"orbit-4","result":{"turn":{"id":"turn-local-1","items":[],"status":"inProgress","error":null}}}\\n'; printf '{"method":"item/completed","params":{"threadId":"thread-local-1","item":{"type":"userMessage","id":"item-local-1","content":[]}}}\\n' ;;
            *'"id":"orbit-5"'*) printf '{"id":"orbit-5","result":{}}\\n'; printf '{"method":"turn/completed","params":{"threadId":"thread-local-1","turn":{"id":"turn-local-1","items":[],"status":"interrupted","error":null}}}\\n' ;;
            *'"id":"orbit-6"'*) printf '{"id":"orbit-6","result":{"thread":{"id":"thread-local-1","turns":[{"id":"turn-local-1","items":[{"type":"userMessage","id":"item-local-1","content":[]}],"status":"interrupted","error":null}]}}}\\n' ;;
          esac
        done
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let materializer = CodexLocalThreadMaterializer(
            fileManager: fileManager,
            executableURL: { scriptURL },
            baseArguments: { [] },
            loginShellSearchPath: { "/orbit/login-bin" }
        )
        let item = CopilotSessionQueueItem(
            id: UUID(),
            workspacePath: workspaceURL.path,
            workspaceStorageID: "storage",
            sessionID: "session",
            title: "修复 tiptap markdown 白屏",
            createdAt: nil,
            lastMessageAt: Date(timeIntervalSince1970: 1_710_000_000),
            importedAt: Date(timeIntervalSince1970: 1_710_000_010),
            status: .pending,
            handoffDirectoryPath: root.appendingPathComponent("handoff", isDirectory: true).path,
            handoffFilePath: root.appendingPathComponent("handoff/handoff.md", isDirectory: false).path,
            rawSessionFilePath: nil,
            editingStateFilePath: nil
        )
        let context = ResolvedCodexLocalThreadMaterializationContext(
            accountID: UUID(),
            workingDirectoryURL: workspaceURL,
            codexHomeURL: codexHomeURL,
            authPayload: nil,
            modelCatalogSnapshot: ResolvedCodexModelCatalogSnapshot(availableModels: ["gpt-5.4"]),
            configFileContents: "model = \"gpt-5.4\"\n",
            environmentVariables: [
                "CAPTURE_PATH": captureURL.path,
                "PATH": "/orbit/app-bin",
            ]
        )

        let thread = try await materializer.materializeCopilotSessionQueueItem(
            item,
            context: context,
            initialPrompt: "请读取 \(item.handoffFilePath)",
            developerInstructions: "读取 handoff.md"
        )

        XCTAssertEqual(thread, MaterializedCodexThread(id: "thread-local-1", path: "/tmp/thread-local-1.jsonl"))
        let lines = try String(contentsOf: captureURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "ARGS:app-server --listen stdio:// --session-source vscode")
        XCTAssertEqual(lines[1], "CODEX_HOME:\(codexHomeURL.path)")
        XCTAssertEqual(
            lines[2],
            "PATH:/orbit/app-bin:/orbit/login-bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        )
        let requests = try lines.dropFirst(3).map { try jsonObject($0) }
        XCTAssertEqual(
            requests.map { $0["method"] as? String },
            ["initialize", "thread/start", "thread/name/set", "turn/start", "turn/interrupt", "thread/read"]
        )

        let initializeParams = try XCTUnwrap(requests[0]["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(initializeParams["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)

        let startParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(startParams["cwd"] as? String, workspaceURL.path)
        XCTAssertEqual(startParams["serviceName"] as? String, "Orbit Copilot Handoff")
        XCTAssertEqual(startParams["developerInstructions"] as? String, "读取 handoff.md")
        XCTAssertEqual(startParams["ephemeral"] as? Bool, false)
        XCTAssertEqual(startParams["experimentalRawEvents"] as? Bool, false)
        XCTAssertEqual(startParams["persistExtendedHistory"] as? Bool, true)

        let nameParams = try XCTUnwrap(requests[2]["params"] as? [String: Any])
        XCTAssertEqual(nameParams["threadId"] as? String, "thread-local-1")
        XCTAssertEqual(nameParams["name"] as? String, item.title)

        let turnParams = try XCTUnwrap(requests[3]["params"] as? [String: Any])
        XCTAssertEqual(turnParams["threadId"] as? String, "thread-local-1")
        let input = try XCTUnwrap(turnParams["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "text")
        XCTAssertTrue((input.first?["text"] as? String)?.contains(item.handoffFilePath) == true)

        let interruptParams = try XCTUnwrap(requests[4]["params"] as? [String: Any])
        XCTAssertEqual(interruptParams["threadId"] as? String, "thread-local-1")
        XCTAssertEqual(interruptParams["turnId"] as? String, "turn-local-1")

        let readParams = try XCTUnwrap(requests[5]["params"] as? [String: Any])
        XCTAssertEqual(readParams["threadId"] as? String, "thread-local-1")
        XCTAssertEqual(readParams["includeTurns"] as? Bool, true)
        XCTAssertTrue(fileManager.fileExists(atPath: codexHomeURL.appendingPathComponent("config.toml").path))
        XCTAssertTrue(fileManager.fileExists(atPath: codexHomeURL.appendingPathComponent("model-catalog.json").path))
    }

    private func jsonObject(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}
