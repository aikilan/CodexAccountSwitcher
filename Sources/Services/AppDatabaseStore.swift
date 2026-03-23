import Foundation

actor AppDatabaseStore {
    private let databaseURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(databaseURL: URL, fileManager: FileManager = .default) {
        self.databaseURL = databaseURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> AppDatabase {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: databaseURL)
        return try decoder.decode(AppDatabase.self, from: data)
    }

    func save(_ database: AppDatabase) throws {
        let data = try encoder.encode(database)
        try data.write(to: databaseURL, options: [.atomic])
    }
}
