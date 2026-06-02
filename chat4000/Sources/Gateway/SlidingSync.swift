import Foundation

/// Builds the sliding-sync request body sent over `GatewayClient.startSync`
/// (the gateway long-polls Tuwunel's simplified-MSC3575 sync and pushes deltas).
///
/// We request:
///  - one list covering all the user's rooms, with the `required_state` the app
///    needs surfaced in sync: `chat4000.room_kind` (control vs session, protocol
///    E), the room name, encryption, and space hierarchy;
///  - the **e2ee** extension (device-list changes + one-time-key counts that
///    `OlmMachine` consumes) and the **to_device** extension (Olm key shares);
///  - account data (mute push rules, read markers).
///
/// NOTE: the exact list params for simplified-MSC3575 must be verified against
/// the deployed Tuwunel; this is the conventional shape and a starting point.
enum SlidingSync {
    static func requestBody(timelineLimit: Int = 20) -> [String: Any] {
        [
            "lists": [
                "all": [
                    "ranges": [[0, 199]],
                    "required_state": [
                        ["m.room.create", ""],
                        ["m.room.name", ""],
                        ["m.room.encryption", ""],
                        // All members: we need the full recipient set to share
                        // the megolm room key (CryptoEngine.shareRoomKey), and
                        // to track users for key queries. Session rooms are
                        // small (user + plugin), so the wildcard is cheap.
                        ["m.room.member", "*"],
                        ["chat4000.room_kind", ""],
                        ["chat4000.status", ""],
                        ["m.space.child", "*"],
                        ["m.space.parent", "*"]
                    ],
                    "timeline_limit": timelineLimit
                ]
            ],
            "extensions": [
                "to_device": ["enabled": true],
                "e2ee": ["enabled": true],
                "account_data": ["enabled": true],
                "receipts": ["enabled": true]
            ]
        ]
    }
}
