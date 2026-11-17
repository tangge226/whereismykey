import Foundation

public final class MetadataStore {
    public let directoryURL: URL
    public let fileURL: URL

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else if let override = ProcessInfo.processInfo.environment["WHEREKEY_DATA_DIR"], !override.isEmpty {
            self.directoryURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directoryURL = support.appendingPathComponent("WhereKey", isDirectory: true)
        }
        self.fileURL = self.directoryURL.appendingPathComponent("metadata.json")
    }

    public func load() throws -> MetadataState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return MetadataState() }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
        guard version == 1 || version == 2 else {
            throw WhereKeyError.storage("不支持的数据版本：\(version)")
        }
        var state = try decoder.decode(MetadataState.self, from: data)
        if version == 1 {
            // Keep IDs and Keychain accounts unchanged. Back up before replacing v1.
            let backup = directoryURL.appendingPathComponent("metadata.v1.backup.json")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: backup.path, isDirectory: &isDirectory) {
                guard !isDirectory.boolValue else { throw WhereKeyError.storage("元数据备份路径被目录占用，已保留原数据") }
            } else {
                try data.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            state.schemaVersion = 2
            try save(state)
        }
        return state
    }

    private struct Version: Decodable { let schemaVersion: Int }

    public func save(_ state: MetadataState) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let temporary = directoryURL.appendingPathComponent("metadata.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}
