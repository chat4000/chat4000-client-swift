import Foundation
import Testing
@testable import chat4000

/// Covers the trickiest v2 logic (worth 8–9): edit-based streaming, the
/// history-vs-live decision, and self-echo sender tagging.
struct MatrixTimelineMapperTests {
    // History backfill → finalized text (worth 8).
    @Test
    func historyEmitsFinalizedText() {
        var m = MatrixTimelineMapper()
        let e = m.ingest(eventId: "$1", body: "hello", senderId: "@p:x", isOwn: false, live: false)
        #expect(e == [.text(id: "$1", body: "hello", senderId: "@p:x", isOwn: false)])
    }

    // Live agent message streams; deltas carry only the new suffix (worth 9).
    @Test
    func liveAgentStreamsSuffixDeltas() {
        var m = MatrixTimelineMapper()
        let e1 = m.ingest(eventId: "$1", body: "Hel", senderId: "@p:x", isOwn: false, live: true)
        #expect(e1 == [.delta(streamId: "$1", delta: "Hel", senderId: "@p:x")])
        let e2 = m.ingest(eventId: "$1", body: "Hello", senderId: "@p:x", isOwn: false, live: true)
        #expect(e2 == [.delta(streamId: "$1", delta: "lo", senderId: "@p:x")])
    }

    // Non-prefix edit (a correction) settles with the full text (worth 9).
    @Test
    func nonPrefixEditSettlesWithFullText() {
        var m = MatrixTimelineMapper()
        _ = m.ingest(eventId: "$1", body: "abc", senderId: "@p:x", isOwn: false, live: true)
        let e = m.ingest(eventId: "$1", body: "xyz", senderId: "@p:x", isOwn: false, live: true)
        #expect(e == [.end(streamId: "$1", body: "xyz", senderId: "@p:x")])
    }

    // A new live stream settles the previous one first (worth 9).
    @Test
    func newStreamFinalizesPrevious() {
        var m = MatrixTimelineMapper()
        _ = m.ingest(eventId: "$1", body: "one", senderId: "@p:x", isOwn: false, live: true)
        let e = m.ingest(eventId: "$2", body: "two", senderId: "@p:x", isOwn: false, live: true)
        #expect(e == [
            .end(streamId: "$1", body: "one", senderId: "@p:x"),
            .delta(streamId: "$2", delta: "two", senderId: "@p:x"),
        ])
    }

    // Our own live message is plain text (suppressed downstream), not a stream.
    @Test
    func ownLiveMessageIsText() {
        var m = MatrixTimelineMapper()
        let e = m.ingest(eventId: "$1", body: "hi", senderId: "@me:x", isOwn: true, live: true)
        #expect(e == [.text(id: "$1", body: "hi", senderId: "@me:x", isOwn: true)])
    }

    // Unchanged body (e.g. a receipt update) emits nothing.
    @Test
    func unchangedBodyEmitsNothing() {
        var m = MatrixTimelineMapper()
        _ = m.ingest(eventId: "$1", body: "hello", senderId: "@p:x", isOwn: false, live: false)
        #expect(m.ingest(eventId: "$1", body: "hello", senderId: "@p:x", isOwn: false, live: true).isEmpty)
    }

    // Protocol final edit settles the addressed stream once.
    @Test
    func finalEditSettlesAddressedStreamOnce() {
        var m = MatrixTimelineMapper()
        _ = m.ingest(eventId: "$1", body: "streaming", senderId: "@p:x", isOwn: false, live: true)
        #expect(m.finalize(streamId: "$1", senderId: "@p:x") == .end(streamId: "$1", body: "streaming", senderId: "@p:x"))
        #expect(m.finalize(streamId: "$1", senderId: "@p:x") == nil)
    }

    @Test
    func streamDecisionFollowsPushFlag() {
        #expect(MatrixTimelineMapper.shouldStream(live: true, isOwn: false, isEdit: false, pushFlag: false))
        #expect(!MatrixTimelineMapper.shouldStream(live: true, isOwn: false, isEdit: false, pushFlag: nil))
        #expect(!MatrixTimelineMapper.shouldStream(live: true, isOwn: false, isEdit: false, pushFlag: true))
        #expect(MatrixTimelineMapper.shouldStream(live: true, isOwn: false, isEdit: true, pushFlag: true))
        #expect(!MatrixTimelineMapper.shouldStream(live: true, isOwn: true, isEdit: true, pushFlag: true))
    }

    @Test
    func finalEditRequiresExplicitTruePushFlag() {
        #expect(MatrixTimelineMapper.isFinalEdit(isEdit: true, pushFlag: true))
        #expect(!MatrixTimelineMapper.isFinalEdit(isEdit: true, pushFlag: false))
        #expect(!MatrixTimelineMapper.isFinalEdit(isEdit: true, pushFlag: nil))
        #expect(!MatrixTimelineMapper.isFinalEdit(isEdit: false, pushFlag: true))
    }

    // Self-echo sender tagging (worth 8).
    @Test
    func senderTagging() {
        let own = MatrixTimelineMapper.sender(matrixUserId: "@me:x", isOwn: true)
        #expect(own.role == .app)
        #expect(own.deviceId == DeviceIdentity.currentDeviceId)

        let agent = MatrixTimelineMapper.sender(matrixUserId: "@plugin:x", isOwn: false)
        #expect(agent.role == .plugin)
        #expect(agent.deviceId == "@plugin:x")
    }
}
