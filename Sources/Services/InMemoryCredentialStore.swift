import Foundation

final class InMemoryCredentialStore: CredentialStore, AccountCredentialStore {
    private var storage: [UUID: StoredCredential] = [:]
    private let lock = NSLock()

    func preload() throws {}

    func save(_ credential: StoredCredential, for accountID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountID] = credential
    }

    func load(for accountID: UUID) throws -> StoredCredential {
        lock.lock()
        defer { lock.unlock() }
        guard let credential = storage[accountID] else {
            throw CredentialStoreError.itemNotFound
        }
        return credential
    }

    func delete(for accountID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountID)
    }

    func loadLatest(for account: ManagedAccount, authFileManager: any AuthFileManaging) throws -> StoredCredential {
        if account.isActive,
           let payload = try? authFileManager.readCurrentAuth(),
           payload.accountIdentifier == account.accountIdentifier
        {
            let credential = StoredCredential.codex(payload)
            try save(credential, for: account.id)
            return credential
        }

        return try load(for: account.id)
    }
}
