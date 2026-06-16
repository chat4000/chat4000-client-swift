import UIKit
import UniformTypeIdentifiers

/// Share Sheet entry point. Saves images shared from other apps (Google Photos,
/// Safari, …) into the App Group inbox, then dismisses. The chat4000 app picks them
/// up on its next foreground — it scans the shared inbox and runs the in-app session
/// picker. We deliberately do NOT try to launch the host app from here (unreliable
/// and App-Review-risky for a share extension); the app self-detects instead.
///
/// The on-disk format MUST match `SharedImageInbox` in the app target:
///   - App Group container subdir `PendingSharedImages/`
///   - `UserDefaults(suiteName:)` key `chat4000.pendingSharedImages`
///   - a JSON array of `{ id, filename, mimeType, createdAt }` (default JSONEncoder)
/// Keep these in lock-step with `SharedImageInbox` if either changes.
final class ShareViewController: UIViewController {
    private static let appGroupId = "group.com.neonnode.chat94app"
    private static let directoryName = "PendingSharedImages"
    private static let manifestKey = "chat4000.pendingSharedImages"
    private static let maxStoredItems = 10

    /// Mirrors `SharedImageInbox`'s private manifest item — same field names so the
    /// app decodes what we encode here.
    private struct ManifestItem: Codable {
        let id: String
        let filename: String
        let mimeType: String
        let createdAt: Date
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task {
            await saveSharedImages()
            complete()
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func saveSharedImages() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        for item in items {
            for provider in item.attachments ?? [] {
                guard let typeId = Self.imageTypeIdentifier(provider),
                      let data = await Self.loadData(provider, typeId: typeId),
                      !data.isEmpty else { continue }
                let type = UTType(typeId)
                let mimeType = type?.preferredMIMEType ?? "image/jpeg"
                let ext = type?.preferredFilenameExtension ?? "jpg"
                Self.store(data: data, mimeType: mimeType, fileExtension: ext)
            }
        }
    }

    /// First registered type that is an image (e.g. `public.jpeg`, `public.png`).
    private static func imageTypeIdentifier(_ provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    private static func loadData(_ provider: NSItemProvider, typeId: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func store(data: Data, mimeType: String, fileExtension: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return }
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let filename = "\(id).\(fileExtension)"
        let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return
        }

        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        var items = loadManifest(defaults)
        items.append(ManifestItem(id: id, filename: filename, mimeType: mimeType, createdAt: Date()))
        if items.count > maxStoredItems {
            let dropCount = items.count - maxStoredItems
            for old in items.prefix(dropCount) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.filename))
            }
            items.removeFirst(dropCount)
        }
        if let encoded = try? JSONEncoder().encode(items) {
            defaults.set(encoded, forKey: manifestKey)
        }
    }

    private static func loadManifest(_ defaults: UserDefaults) -> [ManifestItem] {
        guard let data = defaults.data(forKey: manifestKey),
              let items = try? JSONDecoder().decode([ManifestItem].self, from: data) else {
            return []
        }
        return items
    }
}
