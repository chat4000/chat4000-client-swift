import Foundation

enum KeychainService {
    private static var configFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("chat4000", isDirectory: true)
            .appendingPathComponent(AppEnvironment.current.storageNamespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("group-config.json")
    }

    static func save(_ config: GroupConfig) throws {
        guard let groupKey = config.groupKey, groupKey.count == 32 else {
            throw CocoaError(.coderInvalidValue)
        }
        let scopedConfig = GroupConfig(
            groupKey: groupKey
        )
        let data = try JSONEncoder().encode(scopedConfig)
        try data.write(to: configFileURL, options: [.atomic, .completeFileProtection])
        DevLog.log("💾 Group config saved for \(AppEnvironment.current.kind.rawValue)")
    }

    static func load() -> GroupConfig? {
        guard let data = try? Data(contentsOf: configFileURL),
              let config = try? JSONDecoder().decode(GroupConfig.self, from: data),
              let groupKey = config.groupKey,
              groupKey.count == 32
        else { return nil }
        return GroupConfig(groupKey: groupKey)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: configFileURL)
        DevLog.log("💾 Group config deleted for \(AppEnvironment.current.kind.rawValue)")
    }
}
