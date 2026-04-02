import CommonCrypto
import Foundation
import SQLite3
import XCTest
@testable import Orbit

private let PROVIDER_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class CopilotNativeProviderTests: XCTestCase {
    override func tearDown() {
        CopilotNativeProviderMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testImportCredentialImportsVSCodeGitHubSession() async throws {
        let passphrase = "test-passphrase"
        let homeURL = try makeVSCodeHome(
            sessions: [
                StoredVSCodeGitHubSession(
                    accessToken: "github_oauth_token",
                    scopes: ["read:user", "user:email", "repo", "workflow"],
                    account: .init(label: "aikilan")
                )
            ],
            passphrase: passphrase
        )
        defer { try? FileManager.default.removeItem(at: homeURL) }

        CopilotNativeProviderMockURLProtocol.requestHandler = { request in
            switch (request.url?.absoluteString, request.value(forHTTPHeaderField: "Authorization")) {
            case ("https://api.github.com/copilot_internal/v2/token", "token github_oauth_token"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2025-04-01")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "token": "copilot_runtime_token",
                        "expires_at": 1_730_000_000,
                        "refresh_in": 3600,
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "login": "aikilan",
                        "endpoints": ["api": "https://api.githubcopilot.com/"],
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", _):
                return unauthorizedResponse(for: request)
            default:
                XCTFail("未预期的请求：\(request.url?.absoluteString ?? "nil")")
                return unauthorizedResponse(for: request)
            }
        }

        let provider = CopilotNativeProvider(
            session: makeMockSession(),
            homeDirectoryURL: homeURL,
            vscodeSafeStoragePassphrase: passphrase
        )

        let credential = try await provider.importCredential(host: "https://github.com", defaultModel: nil)

        XCTAssertEqual(credential.host, "https://github.com")
        XCTAssertEqual(credential.login, "aikilan")
        XCTAssertEqual(credential.githubAccessToken, "github_oauth_token")
        XCTAssertEqual(credential.accessToken, "copilot_runtime_token")
        XCTAssertEqual(credential.source, .localImport)
    }

    func testResolveCredentialUsesVSCodeGitHubSessionWhenStoredCredentialHasNoAccessToken() async throws {
        let passphrase = "test-passphrase"
        let homeURL = try makeVSCodeHome(
            sessions: [
                StoredVSCodeGitHubSession(
                    accessToken: "github_oauth_token",
                    scopes: ["read:user", "user:email", "repo", "workflow"],
                    account: .init(label: "aikilan")
                )
            ],
            passphrase: passphrase
        )
        defer { try? FileManager.default.removeItem(at: homeURL) }

        CopilotNativeProviderMockURLProtocol.requestHandler = { request in
            switch (request.url?.absoluteString, request.value(forHTTPHeaderField: "Authorization")) {
            case ("https://api.github.com/copilot_internal/v2/token", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "token": "copilot_runtime_token",
                        "expires_at": 1_730_000_000,
                        "refresh_in": 3600,
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "login": "aikilan",
                        "endpoints": ["api": "https://api.githubcopilot.com/"],
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", _):
                return unauthorizedResponse(for: request)
            default:
                XCTFail("未预期的请求：\(request.url?.absoluteString ?? "nil")")
                return unauthorizedResponse(for: request)
            }
        }

        let provider = CopilotNativeProvider(
            session: makeMockSession(),
            homeDirectoryURL: homeURL,
            vscodeSafeStoragePassphrase: passphrase
        )

        let resolved = try await provider.resolveCredential(
            CopilotCredential(
                host: "https://github.com",
                login: "aikilan",
                defaultModel: "gpt-5.4"
            )
        )

        XCTAssertEqual(resolved.login, "aikilan")
        XCTAssertEqual(resolved.githubAccessToken, "github_oauth_token")
        XCTAssertEqual(resolved.accessToken, "copilot_runtime_token")
        XCTAssertEqual(resolved.defaultModel, "gpt-5.4")
        XCTAssertEqual(resolved.source, .localImport)
    }

    func testResolveCredentialUsesVSCodeGitHubSessionWhenStoredCredentialHasRuntimeTokenOnly() async throws {
        let passphrase = "test-passphrase"
        let homeURL = try makeVSCodeHome(
            sessions: [
                StoredVSCodeGitHubSession(
                    accessToken: "github_oauth_token",
                    scopes: ["read:user", "user:email", "repo", "workflow"],
                    account: .init(label: "aikilan")
                )
            ],
            passphrase: passphrase
        )
        defer { try? FileManager.default.removeItem(at: homeURL) }

        CopilotNativeProviderMockURLProtocol.requestHandler = { request in
            switch (request.url?.absoluteString, request.value(forHTTPHeaderField: "Authorization")) {
            case ("https://api.github.com/copilot_internal/v2/token", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "token": "fresh_runtime_token",
                        "expires_at": 1_730_000_000,
                        "refresh_in": 3600,
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "login": "aikilan",
                        "endpoints": ["api": "https://api.githubcopilot.com/"],
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "Bearer stale_runtime_token"):
                XCTFail("不应该再用 runtime token 请求 copilot user 接口")
                return unauthorizedResponse(for: request)
            default:
                XCTFail("未预期的请求：\(request.url?.absoluteString ?? "nil")")
                return unauthorizedResponse(for: request)
            }
        }

        let provider = CopilotNativeProvider(
            session: makeMockSession(),
            homeDirectoryURL: homeURL,
            vscodeSafeStoragePassphrase: passphrase
        )

        let resolved = try await provider.resolveCredential(
            CopilotCredential(
                host: "https://github.com",
                login: "aikilan",
                accessToken: "stale_runtime_token",
                defaultModel: "gpt-5.4"
            )
        )

        XCTAssertEqual(resolved.login, "aikilan")
        XCTAssertEqual(resolved.githubAccessToken, "github_oauth_token")
        XCTAssertEqual(resolved.accessToken, "fresh_runtime_token")
        XCTAssertEqual(resolved.defaultModel, "gpt-5.4")
    }

    func testCompleteDeviceLoginExchangesGitHubOAuthTokenBeforeValidation() async throws {
        CopilotNativeProviderMockURLProtocol.requestHandler = { request in
            switch (request.url?.absoluteString, request.httpMethod, request.value(forHTTPHeaderField: "Authorization")) {
            case ("https://github.com/login/oauth/access_token", "POST", nil):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "access_token": "github_oauth_token",
                    ])
                )
            case ("https://api.github.com/copilot_internal/v2/token", "GET", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "token": "copilot_runtime_token",
                        "expires_at": 1_730_000_000,
                        "refresh_in": 3600,
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "GET", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "login": "aikilan",
                        "endpoints": ["api": "https://api.githubcopilot.com/"],
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "GET", "Bearer copilot_runtime_token"):
                XCTFail("不应该用 runtime token 请求 Copilot user 接口")
                return unauthorizedResponse(for: request)
            default:
                XCTFail("未预期的请求：\(request.url?.absoluteString ?? "nil")")
                return unauthorizedResponse(for: request)
            }
        }

        let provider = CopilotNativeProvider(session: makeMockSession())
        let credential = try await provider.completeDeviceLogin(
            CopilotDeviceLoginChallenge(
                host: "https://github.com",
                deviceCode: "device-code",
                userCode: "ABCD-EFGH",
                verificationURL: URL(string: "https://github.com/login/device")!,
                expiresInSeconds: 30,
                intervalSeconds: 1,
                defaultModel: "gpt-5.4"
            )
        )

        XCTAssertEqual(credential.login, "aikilan")
        XCTAssertEqual(credential.githubAccessToken, "github_oauth_token")
        XCTAssertEqual(credential.accessToken, "copilot_runtime_token")
        XCTAssertEqual(credential.defaultModel, "gpt-5.4")
        XCTAssertEqual(credential.source, .orbitOAuth)
    }

    func testImportCredentialImportsVSCodeGitHubSessionFromBlobDatabaseValue() async throws {
        let passphrase = "test-passphrase"
        let homeURL = try makeVSCodeHome(
            sessions: [
                StoredVSCodeGitHubSession(
                    accessToken: "github_oauth_token",
                    scopes: ["read:user", "user:email", "repo", "workflow"],
                    account: .init(label: "aikilan")
                )
            ],
            passphrase: passphrase,
            storageFormat: .blob
        )
        defer { try? FileManager.default.removeItem(at: homeURL) }

        CopilotNativeProviderMockURLProtocol.requestHandler = { request in
            switch (request.url?.absoluteString, request.value(forHTTPHeaderField: "Authorization")) {
            case ("https://api.github.com/copilot_internal/v2/token", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "token": "copilot_runtime_token",
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "login": "aikilan",
                        "endpoints": ["api": "https://api.githubcopilot.com/"],
                    ])
                )
            default:
                XCTFail("未预期的请求：\(request.url?.absoluteString ?? "nil")")
                return unauthorizedResponse(for: request)
            }
        }

        let provider = CopilotNativeProvider(
            session: makeMockSession(),
            homeDirectoryURL: homeURL,
            vscodeSafeStoragePassphrase: passphrase
        )

        let credential = try await provider.importCredential(host: "https://github.com", defaultModel: nil)

        XCTAssertEqual(credential.login, "aikilan")
        XCTAssertEqual(credential.githubAccessToken, "github_oauth_token")
        XCTAssertEqual(credential.accessToken, "copilot_runtime_token")
    }

    func testFetchStatusUsesGitHubTokenForUserInfoAndRuntimeTokenForModels() async throws {
        CopilotNativeProviderMockURLProtocol.requestHandler = { request in
            switch (request.url?.absoluteString, request.value(forHTTPHeaderField: "Authorization")) {
            case ("https://api.github.com/copilot_internal/v2/token", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "token": "copilot_runtime_token",
                        "expires_at": 1_730_000_000,
                        "refresh_in": 3600,
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "token github_oauth_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "login": "aikilan",
                        "endpoints": ["api": "https://api.githubcopilot.com/"],
                        "quota_snapshots": [
                            "chat": [
                                "percent_remaining": 55,
                                "quota_remaining": 11,
                                "overage_count": 0,
                                "overage_permitted": false,
                            ]
                        ],
                    ])
                )
            case ("https://api.githubcopilot.com/models", "Bearer copilot_runtime_token"):
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try jsonData([
                        "data": [
                            ["id": "gpt-5.4", "model_picker_enabled": true],
                            ["id": "gpt-4.1", "model_picker_enabled": true],
                        ]
                    ])
                )
            case ("https://api.github.com/copilot_internal/user", "Bearer copilot_runtime_token"):
                XCTFail("不应该用 runtime token 请求 Copilot user 接口")
                return unauthorizedResponse(for: request)
            default:
                XCTFail("未预期的请求：\(request.url?.absoluteString ?? "nil")")
                return unauthorizedResponse(for: request)
            }
        }

        let provider = CopilotNativeProvider(session: makeMockSession())
        let status = try await provider.fetchStatus(
            using: CopilotCredential(
                host: "https://github.com",
                login: "aikilan",
                githubAccessToken: "github_oauth_token",
                defaultModel: "gpt-5.4"
            )
        )

        XCTAssertEqual(status.currentModel, "gpt-5.4")
        XCTAssertEqual(status.availableModels, ["gpt-5.4", "gpt-4.1"])
        XCTAssertEqual(status.quotaSnapshot?.chat?.remainingPercentage, 55)
    }
}

private struct StoredVSCodeGitHubSession: Encodable {
    struct Account: Encodable {
        let label: String
    }

    let accessToken: String
    let scopes: [String]
    let account: Account
}

private enum VSCodeSecretStorageFormat {
    case bufferJSON
    case blob
}

private final class CopilotNativeProviderMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("CopilotNativeProviderMockURLProtocol.requestHandler 未设置")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CopilotNativeProviderMockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeVSCodeHome(
    sessions: [StoredVSCodeGitHubSession],
    passphrase: String,
    storageFormat: VSCodeSecretStorageFormat = .bufferJSON
) throws -> URL {
    let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let globalStorageURL = homeURL
        .appendingPathComponent("Library/Application Support/Code/User/globalStorage", isDirectory: true)
    try FileManager.default.createDirectory(at: globalStorageURL, withIntermediateDirectories: true)

    let encryptedValue = try encryptVSCodeSecret(
        JSONEncoder().encode(sessions),
        passphrase: passphrase
    )
    try writeVSCodeStateDatabase(
        databaseURL: globalStorageURL.appendingPathComponent("state.vscdb", isDirectory: false),
        encryptedValue: encryptedValue,
        storageFormat: storageFormat
    )
    return homeURL
}

private func writeVSCodeStateDatabase(
    databaseURL: URL,
    encryptedValue: Data,
    storageFormat: VSCodeSecretStorageFormat
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "CopilotNativeProviderTests", code: 1)
    }
    defer { sqlite3_close(database) }

    let createTableSQL = """
    CREATE TABLE ItemTable (
        key TEXT PRIMARY KEY,
        value \(storageFormat == .bufferJSON ? "TEXT" : "BLOB")
    );
    """
    guard sqlite3_exec(database, createTableSQL, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "CopilotNativeProviderTests", code: 2)
    }

    let insertSQL = "INSERT INTO ItemTable (key, value) VALUES (?, ?);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, insertSQL, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "CopilotNativeProviderTests", code: 3)
    }
    defer { sqlite3_finalize(statement) }

    let secretKey = #"secret://{"extensionId":"vscode.github-authentication","key":"github.auth"}"#
    sqlite3_bind_text(statement, 1, secretKey, -1, PROVIDER_SQLITE_TRANSIENT)

    let bindResult: Int32
    switch storageFormat {
    case .bufferJSON:
        let bufferJSON = try JSONSerialization.data(withJSONObject: [
            "type": "Buffer",
            "data": encryptedValue.map(Int.init),
        ])
        bindResult = bufferJSON.withUnsafeBytes { bytes in
            sqlite3_bind_text(
                statement,
                2,
                bytes.bindMemory(to: Int8.self).baseAddress,
                Int32(bufferJSON.count),
                PROVIDER_SQLITE_TRANSIENT
            )
        }
    case .blob:
        bindResult = encryptedValue.withUnsafeBytes { encryptedValueBytes in
            sqlite3_bind_blob(
                statement,
                2,
                encryptedValueBytes.baseAddress,
                Int32(encryptedValue.count),
                PROVIDER_SQLITE_TRANSIENT
            )
        }
    }
    guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "CopilotNativeProviderTests", code: 4)
    }
}

private func encryptVSCodeSecret(_ plaintext: Data, passphrase: String) throws -> Data {
    let key = try deriveElectronKey(passphrase: passphrase)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var encryptedData = Data(count: plaintext.count + kCCBlockSizeAES128)
    var encryptedLength = 0
    let outputLength = encryptedData.count

    let status = encryptedData.withUnsafeMutableBytes { encryptedBytes in
        plaintext.withUnsafeBytes { plaintextBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        plaintextBytes.baseAddress,
                        plaintext.count,
                        encryptedBytes.baseAddress,
                        outputLength,
                        &encryptedLength
                    )
                }
            }
        }
    }

    guard status == kCCSuccess else {
        throw NSError(domain: "CopilotNativeProviderTests", code: 5)
    }

    encryptedData.removeSubrange(encryptedLength..<encryptedData.count)
    return Data("v10".utf8) + encryptedData
}

private func deriveElectronKey(passphrase: String) throws -> Data {
    let password = Data(passphrase.utf8)
    let salt = Data("saltysalt".utf8)
    var derivedKey = Data(count: kCCKeySizeAES128)

    let status = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
        password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1_003,
                    derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                    kCCKeySizeAES128
                )
            }
        }
    }

    guard status == kCCSuccess else {
        throw NSError(domain: "CopilotNativeProviderTests", code: 6)
    }

    return derivedKey
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func unauthorizedResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
        try! JSONSerialization.data(withJSONObject: ["message": "unauthorized"])
    )
}
