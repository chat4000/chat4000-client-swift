import Foundation
import SwiftData

@Model
final class MatrixRoomSnapshot {
    @Attribute(.unique) var userId: String
    var schemaVersion: Int
    var snapshotData: Data
    var updatedAt: Date

    init(
        userId: String,
        schemaVersion: Int,
        snapshotData: Data,
        updatedAt: Date = .now
    ) {
        self.userId = userId
        self.schemaVersion = schemaVersion
        self.snapshotData = snapshotData
        self.updatedAt = updatedAt
    }
}
