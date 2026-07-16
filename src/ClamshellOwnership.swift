import Foundation

struct ClamshellOwnershipRecord: Codable, Equatable {
    let token: String
    let processID: Int32
    let startedAt: Date
}

struct ClamshellOwnershipStore {
    let url: URL

    static func defaultStore() -> ClamshellOwnershipStore {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return ClamshellOwnershipStore(
            url: base
                .appendingPathComponent("SteamPack", isDirectory: true)
                .appendingPathComponent("clamshell-owner.json")
        )
    }

    func read() -> ClamshellOwnershipRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClamshellOwnershipRecord.self, from: data)
    }

    func write(_ record: ClamshellOwnershipRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    func matches(token: String) -> Bool {
        read()?.token == token
    }

    func clearIfMatching(token: String) {
        guard matches(token: token) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func clearStaleRecord() {
        guard let record = read(), !Self.isProcessAlive(record.processID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func isProcessAlive(_ processID: Int32) -> Bool {
        processID > 0 && kill(processID, 0) == 0
    }
}
