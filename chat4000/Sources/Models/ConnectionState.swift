import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)

    var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting: true
        default: false
        }
    }
}
