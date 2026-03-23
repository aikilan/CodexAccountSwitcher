import Foundation

final class InMemoryCredentialStore: CredentialStore, AccountCredentialStore {
    private var storage: [UUID: CodexAuthPayload] = [:]
    private let lock = NSLock()

    func preload() throws {}

    func save(_ payload: CodexAuthPayload, for accountID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountID] = payload
    }

    func load(for accountID: UUID) throws -> CodexAuthPayload {
        lock.lock()
        defer { lock.unlock() }
        guard let payload = storage[accountID] else {
            throw CredentialStoreError.itemNotFound
        }
        return payload
    }

    func delete(for accountID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }

    func loadLatest(for account: ManagedAccount, authFileManager: any AuthFileManaging) throws -> CodexAuthPayload {
        if account.isActive,
           let payload = try? authFileManager.readCurrentAuth(),
           payload.accountIdentifier == account.codexAccountID
        {
            try save(payload, for: account.id)
            return payload
        }

        return try load(for: account.id)
    }
}
