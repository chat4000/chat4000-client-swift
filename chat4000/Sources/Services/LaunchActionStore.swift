import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LaunchAction: String {
    case startVoiceRecording
    case openComposer
    case sendSharedImage
}

enum LaunchActionStore {
    private static let key = "chat4000.pendingLaunchAction"
    static let recordingURL: URL = requireURL("chat4000://record")
    static let composerURL: URL = requireURL("chat4000://compose")
    static let didSetNotification = Notification.Name("chat4000.pendingLaunchActionDidSet")

    static func set(_ action: LaunchAction) {
        AppLog.log("🎯 LaunchActionStore.set action=%@", action.rawValue)
        UserDefaults.standard.set(action.rawValue, forKey: key)
        NotificationCenter.default.post(name: didSetNotification, object: action.rawValue)
    }

    static func peek() -> LaunchAction? {
        guard let rawValue = UserDefaults.standard.string(forKey: key) else { return nil }
        return LaunchAction(rawValue: rawValue)
    }

    static func consume() -> LaunchAction? {
        guard let rawValue = UserDefaults.standard.string(forKey: key),
              let action = LaunchAction(rawValue: rawValue)
        else {
            return nil
        }

        AppLog.log("🎯 LaunchActionStore.consume action=%@", action.rawValue)
        UserDefaults.standard.removeObject(forKey: key)
        return action
    }

    static func action(for url: URL) -> LaunchAction? {
        AppLog.log("🎯 LaunchActionStore.action url=%@", url.absoluteString)
        if url.isFileURL {
            switch SharedImageInbox.enqueue(fileURL: url) {
            case .success(let payload):
                AppLog.log(
                    "🎯 LaunchActionStore.action queued shared image id=%@ bytes=%d",
                    payload.id,
                    payload.data.count
                )
                return .sendSharedImage
            case .failure(let error):
                AppLog.log("🎯 LaunchActionStore.action shared image failed=%@", error.message)
                return nil
            }
        }

        guard url.scheme?.lowercased() == "chat4000" else { return nil }

        let host = url.host?.lowercased()
        let firstPathComponent = url.pathComponents.dropFirst().first?.lowercased()

        switch (host, firstPathComponent) {
        case ("record", _), (_, "record"):
            AppLog.log("🎯 LaunchActionStore.action resolved=startVoiceRecording")
            return .startVoiceRecording
        case ("compose", _), (_, "compose"):
            AppLog.log("🎯 LaunchActionStore.action resolved=openComposer")
            return .openComposer
        case ("share-image", _), (_, "share-image"):
            #if DEBUG
            if enqueueDebugSharedImageFixture(from: url) {
                AppLog.log("🎯 LaunchActionStore.action resolved=sendSharedImage debug_fixture")
                return .sendSharedImage
            }
            #endif
            guard SharedImageInbox.hasPendingImage() else {
                AppLog.log("🎯 LaunchActionStore.action share-image had no queued image")
                return nil
            }
            AppLog.log("🎯 LaunchActionStore.action resolved=sendSharedImage")
            return .sendSharedImage
        default:
            AppLog.log("🎯 LaunchActionStore.action resolved=nil")
            return nil
        }
    }

    #if DEBUG
    private static func enqueueDebugSharedImageFixture(from url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "fixture" && $0.value == "png" }) == true,
              let data = debugPNGFixtureData()
        else {
            return false
        }

        switch SharedImageInbox.enqueue(
            data: data,
            suggestedFilename: "debug-fixture.png",
            mimeType: "image/png"
        ) {
        case .success(let payload):
            AppLog.log(
                "🎯 LaunchActionStore.action queued debug shared image id=%@ bytes=%d",
                payload.id,
                payload.data.count
            )
            return true
        case .failure(let error):
            AppLog.log("🎯 LaunchActionStore.action debug shared image failed=%@", error.message)
            return false
        }
    }

    static func debugPNGFixtureData() -> Data? {
        let width = 64
        let height = 64
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                pixels[offset] = UInt8((x * 37 + y * 91 + (x * y) % 251) % 256)
                pixels[offset + 1] = UInt8((x * 19 + y * 53 + ((x + 7) * (y + 11)) % 241) % 256)
                pixels[offset + 2] = UInt8((x * 101 + y * 13 + ((x + y) * 29) % 223) % 256)
                pixels[offset + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    #endif
}
