#if os(iOS)
import UIKit
#endif
import Foundation

enum Haptics {
    #if os(iOS)
    @MainActor private static let impactGenerator = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let successGenerator = UINotificationFeedbackGenerator()
    @MainActor private static let errorGenerator = UINotificationFeedbackGenerator()
    #endif

    @MainActor
    static func prime() {
        #if os(iOS)
        impactGenerator.prepare()
        successGenerator.prepare()
        errorGenerator.prepare()
        #endif
    }

    @MainActor
    static func impact() {
        #if os(iOS)
        impactGenerator.impactOccurred()
        impactGenerator.prepare()
        #endif
    }

    @MainActor
    static func success() {
        #if os(iOS)
        successGenerator.notificationOccurred(.success)
        successGenerator.prepare()
        #endif
    }

    @MainActor
    static func error() {
        #if os(iOS)
        errorGenerator.notificationOccurred(.error)
        errorGenerator.prepare()
        #endif
    }
}
