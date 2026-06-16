import Foundation
import UniformTypeIdentifiers

struct SharedImagePayload: Equatable {
    let id: String
    let data: Data
    let mimeType: String
    let filename: String
}

private struct SharedImageManifestItem: Codable, Equatable {
    let id: String
    let filename: String
    let mimeType: String
    let createdAt: Date
}

enum SharedImageInbox {
    private static let directoryName = "PendingSharedImages"
    private static let manifestKey = "chat4000.pendingSharedImages"
    private static let defaultMimeType = "image/jpeg"
    private static let maxStoredItems = 10

    /// Shared container between the app and the Share Extension. The extension
    /// writes incoming images here; the app reads them. MUST match the App Group id
    /// in both targets' entitlements (and registered in the Apple Developer portal).
    static let appGroupId = "group.com.neonnode.chat94app"

    /// The UserDefaults suite shared with the extension via the App Group. Falls
    /// back to `.standard` when the group isn't provisioned yet (pre-portal / older
    /// builds), so behavior degrades gracefully instead of crashing.
    static var sharedDefaults: UserDefaults { UserDefaults(suiteName: appGroupId) ?? .standard }

    static func enqueue(
        fileURL: URL,
        baseURL: URL? = nil,
        defaults: UserDefaults = SharedImageInbox.sharedDefaults
    ) -> Result<SharedImagePayload, AppError> {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = Self.mimeType(for: fileURL)
            return enqueue(
                data: data,
                suggestedFilename: fileURL.lastPathComponent,
                mimeType: mimeType,
                baseURL: baseURL,
                defaults: defaults
            )
        } catch {
            return .failure(.storage("shared image read: \(error.localizedDescription)"))
        }
    }

    static func enqueue(
        data: Data,
        suggestedFilename: String?,
        mimeType: String?,
        baseURL: URL? = nil,
        defaults: UserDefaults = SharedImageInbox.sharedDefaults
    ) -> Result<SharedImagePayload, AppError> {
        guard !data.isEmpty else {
            return .failure(.storage("shared image is empty"))
        }

        switch pendingDirectory(baseURL: baseURL) {
        case .success(let directory):
            let id = UUID().uuidString
            let resolvedMimeType = sanitizedMimeType(mimeType)
            let filename = storedFilename(
                id: id,
                suggestedFilename: suggestedFilename,
                mimeType: resolvedMimeType
            )
            let fileURL = directory.appendingPathComponent(filename, isDirectory: false)

            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                return .failure(.storage("shared image write: \(error.localizedDescription)"))
            }

            var items = loadManifest(defaults: defaults)
            items.append(SharedImageManifestItem(
                id: id,
                filename: filename,
                mimeType: resolvedMimeType,
                createdAt: .now
            ))
            if items.count > maxStoredItems {
                let dropCount = items.count - maxStoredItems
                let dropped = Array(items.prefix(dropCount))
                items.removeFirst(dropCount)
                for item in dropped {
                    removeFile(item, baseURL: baseURL)
                }
            }
            saveManifest(items, defaults: defaults)

            return .success(SharedImagePayload(
                id: id,
                data: data,
                mimeType: resolvedMimeType,
                filename: filename
            ))

        case .failure(let error):
            return .failure(error)
        }
    }

    static func consumeNext(
        baseURL: URL? = nil,
        defaults: UserDefaults = SharedImageInbox.sharedDefaults
    ) -> Result<SharedImagePayload?, AppError> {
        var items = loadManifest(defaults: defaults)

        while let item = items.first {
            switch pendingDirectory(baseURL: baseURL) {
            case .success(let directory):
                let fileURL = directory.appendingPathComponent(item.filename, isDirectory: false)
                do {
                    // Read the bytes BEFORE committing the manifest removal, so a
                    // crash mid-consume leaves the item re-consumable rather than
                    // silently lost. (Durability after this point is the caller's
                    // outbox: the returned payload becomes a persisted `.sending`
                    // row, so dropping it from this inbox here is safe.)
                    let data = try Data(contentsOf: fileURL)
                    items.removeFirst()
                    saveManifest(items, defaults: defaults)
                    try? FileManager.default.removeItem(at: fileURL)
                    return .success(SharedImagePayload(
                        id: item.id,
                        data: data,
                        mimeType: item.mimeType,
                        filename: item.filename
                    ))
                } catch {
                    // Unreadable (missing / corrupt) — drop just this entry so the
                    // queue can still drain; keeping it would loop on the bad item.
                    ErrorReporter.capture(error, context: "SharedImageInbox.consumeNext")
                    items.removeFirst()
                    saveManifest(items, defaults: defaults)
                    try? FileManager.default.removeItem(at: fileURL)
                    continue
                }

            case .failure(let error):
                return .failure(error)
            }
        }

        return .success(nil)
    }

    static func hasPendingImage(defaults: UserDefaults = SharedImageInbox.sharedDefaults) -> Bool {
        !loadManifest(defaults: defaults).isEmpty
    }

    private static func pendingDirectory(baseURL: URL?) -> Result<URL, AppError> {
        let root: URL
        if let baseURL {
            root = baseURL
        } else if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            // Shared with the extension once the App Group is provisioned.
            root = group
        } else if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            root = support
        } else {
            return .failure(.storage("application support directory unavailable"))
        }

        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return .success(directory)
        } catch {
            return .failure(.storage("shared image directory: \(error.localizedDescription)"))
        }
    }

    private static func loadManifest(defaults: UserDefaults) -> [SharedImageManifestItem] {
        guard let data = defaults.data(forKey: manifestKey) else { return [] }
        do {
            return try JSONDecoder().decode([SharedImageManifestItem].self, from: data)
        } catch {
            ErrorReporter.capture(error, context: "SharedImageInbox.loadManifest")
            defaults.removeObject(forKey: manifestKey)
            return []
        }
    }

    private static func saveManifest(
        _ items: [SharedImageManifestItem],
        defaults: UserDefaults
    ) {
        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: manifestKey)
        } catch {
            ErrorReporter.capture(error, context: "SharedImageInbox.saveManifest")
        }
    }

    private static func removeFile(_ item: SharedImageManifestItem, baseURL: URL?) {
        guard case .success(let directory) = pendingDirectory(baseURL: baseURL) else { return }
        let fileURL = directory.appendingPathComponent(item.filename, isDirectory: false)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func mimeType(for fileURL: URL) -> String {
        if let values = try? fileURL.resourceValues(forKeys: [.contentTypeKey]),
           let mimeType = values.contentType?.preferredMIMEType {
            return mimeType
        }

        let ext = fileURL.pathExtension
        if !ext.isEmpty,
           let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType {
            return mimeType
        }

        return defaultMimeType
    }

    private static func sanitizedMimeType(_ mimeType: String?) -> String {
        guard let mimeType = mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              mimeType.hasPrefix("image/") else {
            return defaultMimeType
        }
        return mimeType
    }

    private static func storedFilename(
        id: String,
        suggestedFilename: String?,
        mimeType: String
    ) -> String {
        let ext = fileExtension(for: mimeType)
        guard let suggestedFilename,
              !suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(id).\(ext)"
        }

        let sanitized = suggestedFilename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let name = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
        let trimmedName = String(name.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "\(id).\(ext)" }
        return "\(id)-\(trimmedName).\(ext)"
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }
}
