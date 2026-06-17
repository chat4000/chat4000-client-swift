import UIKit
import UniformTypeIdentifiers

/// Share Sheet entry point. Saves images shared from other apps (Google Photos,
/// Safari, …) into the App Group inbox, then dismisses. The chat4000 app picks them
/// up on its next foreground — it scans the shared inbox and runs the in-app session
/// picker. We ALSO make a best-effort attempt to foreground the host app (see
/// `openHostApp`), but a share extension cannot reliably launch its container app on
/// modern iOS, so the self-detect-on-foreground path above is the real mechanism.
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

    /// Bytes + metadata pulled from a shared item (a struct, not a 3-tuple, to
    /// satisfy the large_tuple lint).
    private struct ExtractedImage {
        let data: Data
        let mimeType: String
        let ext: String
    }

    /// Deep link the host app opens itself with; `chat4000App.handleIncomingURL`
    /// routes it to the shared-image flow (which reads the App Group inbox).
    private static let hostAppURL = URL(string: "chat4000://share-image")

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task {
            await saveSharedImages()
            // Bring chat4000 to the foreground so it sends the just-saved image
            // immediately (auto-send for one session, one-tap picker for several).
            await openHostApp()
            complete()
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// Launch the host app. Primary path is `NSExtensionContext.open` (a share
    /// extension has no `UIApplication`, so a responder-chain walk usually finds
    /// nothing — that was why the first attempt didn't open the app). Fall back to
    /// the responder-chain `openURL:` technique if `open` reports failure. Best
    /// effort either way: if neither works the image is already in the App Group
    /// inbox and the app sends it on next foreground.
    private func openHostApp() async {
        guard let url = Self.hostAppURL, let context = extensionContext else { return }
        let opened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.open(url) { success in continuation.resume(returning: success) }
        }
        if !opened { openViaResponderChain(url) }
    }

    private func openViaResponderChain(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }

    private func saveSharedImages() async {
        var attachmentCount = 0
        var savedCount = 0
        if let items = extensionContext?.inputItems as? [NSExtensionItem] {
            for item in items {
                for provider in item.attachments ?? [] {
                    attachmentCount += 1
                    guard let image = await Self.extractImage(provider), !image.data.isEmpty else { continue }
                    if Self.store(data: image.data, mimeType: image.mimeType, fileExtension: image.ext) {
                        savedCount += 1
                    }
                }
            }
        }
        Self.recordDiagnostics(attachments: attachmentCount, saved: savedCount)
    }

    /// Leave a breadcrumb the host app can read + log, so we can tell from a pulled
    /// log whether the extension ran AND whether App Group sharing actually works
    /// (if the app sees `containerOK`/`lastRunAt`, the group is wired; if not, the
    /// extension's App ID is missing the App Group entitlement). Also NSLog'd
    /// (numbers survive unified-log redaction) as a backup.
    private static func recordDiagnostics(attachments: Int, saved: Int) {
        let containerOK = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) != nil
        NSLog("chat4000 ShareExt ran attachments=%d saved=%d containerOK=%d",
              attachments, saved, containerOK ? 1 : 0)
        guard let defaults = UserDefaults(suiteName: appGroupId) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "chat4000.shareExt.lastRunAt")
        defaults.set(containerOK, forKey: "chat4000.shareExt.containerOK")
        defaults.set(attachments, forKey: "chat4000.shareExt.attachmentCount")
        defaults.set(saved, forKey: "chat4000.shareExt.savedCount")
    }

    /// Pull image bytes from a provider, trying the representations real apps use —
    /// crucially more than one, because the first attempt (data rep for a concrete
    /// image UTI) is exactly what failed for Google Photos. Order:
    ///   1. Concrete image UTI (public.jpeg/png/…) via loadFileRepresentation, which
    ///      handles both in-memory and file-backed items (loadDataRepresentation
    ///      alone misses file-backed providers — the likely Google Photos case).
    ///   2. Same UTI via loadDataRepresentation (in-memory fallback).
    ///   3. A file URL whose extension is an image (some apps share by reference).
    private static func extractImage(_ provider: NSItemProvider) async -> ExtractedImage? {
        if let typeId = imageTypeIdentifier(provider) {
            let type = UTType(typeId)
            let mimeType = type?.preferredMIMEType ?? "image/jpeg"
            let ext = type?.preferredFilenameExtension ?? "jpg"
            if let data = await loadFileRepresentation(provider, typeId: typeId), !data.isEmpty {
                return ExtractedImage(data: data, mimeType: mimeType, ext: ext)
            }
            if let data = await loadData(provider, typeId: typeId), !data.isEmpty {
                return ExtractedImage(data: data, mimeType: mimeType, ext: ext)
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(provider),
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return ExtractedImage(
                    data: data,
                    mimeType: type.preferredMIMEType ?? "image/jpeg",
                    ext: type.preferredFilenameExtension ?? "jpg")
            }
        }
        return nil
    }

    /// First registered type that is an image (e.g. `public.jpeg`, `public.png`).
    private static func imageTypeIdentifier(_ provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
    }

    private static func loadFileRepresentation(_ provider: NSItemProvider, typeId: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            // The handed URL is valid only for the duration of this completion, so
            // read it here rather than returning the URL.
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
            }
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadData(_ provider: NSItemProvider, typeId: String) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    @discardableResult
    private static func store(data: Data, mimeType: String, fileExtension: String) -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return false }
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let filename = "\(id).\(fileExtension)"
        let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            return false
        }

        guard let defaults = UserDefaults(suiteName: appGroupId) else { return false }
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
        return true
    }

    private static func loadManifest(_ defaults: UserDefaults) -> [ManifestItem] {
        guard let data = defaults.data(forKey: manifestKey),
              let items = try? JSONDecoder().decode([ManifestItem].self, from: data) else {
            return []
        }
        return items
    }
}
