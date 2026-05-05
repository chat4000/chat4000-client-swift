import Foundation

enum LaunchAction: String {
    case startVoiceRecording
}

enum LaunchActionStore {
    private static let key = "chat4000.pendingLaunchAction"
    static let recordingURL = URL(string: "chat4000://record")!
    static let didSetNotification = Notification.Name("chat4000.pendingLaunchActionDidSet")

    static func set(_ action: LaunchAction) {
        AppLog.log("🎯 LaunchActionStore.set action=%@", action.rawValue)
        UserDefaults.standard.set(action.rawValue, forKey: key)
        NotificationCenter.default.post(name: didSetNotification, object: action.rawValue)
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
        guard url.scheme?.lowercased() == "chat4000" else { return nil }

        let host = url.host?.lowercased()
        let firstPathComponent = url.pathComponents.dropFirst().first?.lowercased()

        switch (host, firstPathComponent) {
        case ("record", _), (_, "record"):
            AppLog.log("🎯 LaunchActionStore.action resolved=startVoiceRecording")
            return .startVoiceRecording
        default:
            AppLog.log("🎯 LaunchActionStore.action resolved=nil")
            return nil
        }
    }
}
