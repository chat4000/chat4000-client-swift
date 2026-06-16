import Foundation
import ImageIO
import Testing
@testable import chat4000

struct SharedImageInboxTests {
    @Test func enqueuedDataConsumesOnce() throws {
        let harness = try InboxHarness()
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        let stored = try harness.requireSuccess(SharedImageInbox.enqueue(
            data: data,
            suggestedFilename: "photo.png",
            mimeType: "image/png",
            baseURL: harness.baseURL,
            defaults: harness.defaults
        ))

        #expect(stored.data == data)
        #expect(stored.mimeType == "image/png")
        #expect(stored.filename.hasSuffix("-photo.png"))
        #expect(SharedImageInbox.hasPendingImage(defaults: harness.defaults))

        let consumed = try #require(try harness.requireSuccess(SharedImageInbox.consumeNext(
            baseURL: harness.baseURL,
            defaults: harness.defaults
        )))
        #expect(consumed.id == stored.id)
        #expect(consumed.data == data)
        #expect(consumed.mimeType == "image/png")
        #expect(!SharedImageInbox.hasPendingImage(defaults: harness.defaults))

        let empty = try harness.requireSuccess(SharedImageInbox.consumeNext(
            baseURL: harness.baseURL,
            defaults: harness.defaults
        ))
        #expect(empty == nil)
    }

    @Test func fileURLEnqueueInfersImageMimeType() throws {
        let harness = try InboxHarness()
        let source = harness.baseURL.appendingPathComponent("shared.gif")
        let data = Data([0x47, 0x49, 0x46])
        try data.write(to: source)

        let stored = try harness.requireSuccess(SharedImageInbox.enqueue(
            fileURL: source,
            baseURL: harness.baseURL,
            defaults: harness.defaults
        ))

        #expect(stored.data == data)
        #expect(stored.mimeType == "image/gif")
        #expect(stored.filename.hasSuffix("-shared.gif"))
    }

    @Test func nonImageMimeTypeFallsBackToJPEG() throws {
        let harness = try InboxHarness()
        let stored = try harness.requireSuccess(SharedImageInbox.enqueue(
            data: Data([1, 2, 3]),
            suggestedFilename: "not-text.txt",
            mimeType: "text/plain",
            baseURL: harness.baseURL,
            defaults: harness.defaults
        ))

        #expect(stored.mimeType == "image/jpeg")
        #expect(stored.filename.hasSuffix("-not-text.jpg"))
    }

    @Test func imageFilenameMatchesMimeType() {
        #expect(MatrixSession.imageFilename(mimeType: "image/png") == "image.png")
        #expect(MatrixSession.imageFilename(mimeType: "image/gif") == "image.gif")
        #expect(MatrixSession.imageFilename(mimeType: "image/heic") == "image.heic")
        #expect(MatrixSession.imageFilename(mimeType: "image/jpeg") == "image.jpg")
    }

    #if DEBUG
    @Test func debugPNGFixtureIsNormalSizedImage() throws {
        let data = try #require(LaunchActionStore.debugPNGFixtureData())
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)

        #expect(data.count > 1_000)
        #expect(width == 64)
        #expect(height == 64)
    }
    #endif
}

private struct InboxHarness {
    let baseURL: URL
    let defaults: UserDefaults

    init() throws {
        let id = UUID().uuidString
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat4000-shared-image-tests-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: "chat4000-shared-image-tests-\(id)"))
        defaults.removePersistentDomain(forName: "chat4000-shared-image-tests-\(id)")
    }

    func requireSuccess<T>(_ result: Result<T, AppError>) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            Issue.record("Expected success, got \(error.message)")
            throw error
        }
    }
}
