import Foundation

enum TelemetryPreferences {
    private static let collectionEnabledKey = "telemetry.collectionEnabled"

    static var isCollectionEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: collectionEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: collectionEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: collectionEnabledKey)
        }
    }
}
