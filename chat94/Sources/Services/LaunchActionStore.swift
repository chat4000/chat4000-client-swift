import Foundation

enum LaunchAction: String {
    case startVoiceRecording
}

enum LaunchActionStore {
    private static let key = "chat94.pendingLaunchAction"
    static let recordingURL = URL(string: "chat94://record")!
    static let didSetNotification = Notification.Name("chat94.pendingLaunchActionDidSet")

    static func set(_ action: LaunchAction) {
        DevLog.log("🎯 LaunchActionStore.set action=%@", action.rawValue)
        UserDefaults.standard.set(action.rawValue, forKey: key)
        NotificationCenter.default.post(name: didSetNotification, object: action.rawValue)
    }

    static func consume() -> LaunchAction? {
        guard let rawValue = UserDefaults.standard.string(forKey: key),
              let action = LaunchAction(rawValue: rawValue)
        else {
            return nil
        }

        DevLog.log("🎯 LaunchActionStore.consume action=%@", action.rawValue)
        UserDefaults.standard.removeObject(forKey: key)
        return action
    }

    static func action(for url: URL) -> LaunchAction? {
        DevLog.log("🎯 LaunchActionStore.action url=%@", url.absoluteString)
        guard url.scheme?.lowercased() == "chat94" else { return nil }

        let host = url.host?.lowercased()
        let firstPathComponent = url.pathComponents.dropFirst().first?.lowercased()

        switch (host, firstPathComponent) {
        case ("record", _), (_, "record"):
            DevLog.log("🎯 LaunchActionStore.action resolved=startVoiceRecording")
            return .startVoiceRecording
        default:
            DevLog.log("🎯 LaunchActionStore.action resolved=nil")
            return nil
        }
    }
}
