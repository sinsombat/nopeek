import Foundation
import Testing

import PWCore

/// Tests for `TrayModel` (spec §6: the menu's "10 events ล่าสุด" list).
///
/// The model is the app layer's (T12) tray state: the newest-first list of
/// non-noise events plus the running `count` of a throttled burst. It is pure
/// logic on purpose — the menu bar UI (T17) reads it, it never touches UI.
@Suite struct TrayModelTests {

    // MARK: - Helpers

    private static let baseDate = Date(timeIntervalSince1970: 1_762_000_000)

    private func event(
        actor: String,
        kind: EventKind = .screenCapture,
        tier: Tier = .normal,
        secondsOffset: TimeInterval = 0,
        count: Int = 1
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: Self.baseDate.addingTimeInterval(secondsOffset),
                source: .logstream,
                kind: kind,
                actor: actor
            ),
            tier: tier,
            reason: "default",
            count: count
        )
    }

    // MARK: - Recording

    @Test func testRecordKeepsNewestFirst() {
        var tray = TrayModel()
        tray.record(event(actor: "one", secondsOffset: 0))
        tray.record(event(actor: "two", secondsOffset: 1))
        tray.record(event(actor: "three", secondsOffset: 2))

        #expect(tray.events.map(\.event.actor) == ["three", "two", "one"])
    }

    @Test func testRecordCapsAtTenAndDropsTheOldest() {
        var tray = TrayModel()
        #expect(TrayModel.capacity == 10)

        for index in 0..<12 {
            tray.record(event(actor: "actor-\(index)", secondsOffset: TimeInterval(index)))
        }

        #expect(tray.events.count == 10)
        #expect(tray.events.first?.event.actor == "actor-11")
        #expect(tray.events.last?.event.actor == "actor-2")
    }

    @Test func testRecordKeepsCountAsGiven() {
        // A NORMAL event reduced to "1" by the caller stays "1"; the model
        // does not reinterpret counts.
        var tray = TrayModel()
        tray.record(event(actor: "capture", count: 1))
        #expect(tray.events.first?.count == 1)
    }

    // MARK: - Aggregation

    @Test func testApplyAggregateUpdatesMostRecentMatchingEntry() {
        var tray = TrayModel()
        tray.record(event(actor: "capture", secondsOffset: 0))
        tray.record(event(actor: "other", kind: .cameraOn, secondsOffset: 1))

        tray.applyAggregate(event(actor: "capture", secondsOffset: 2), count: 5)

        #expect(tray.events.count == 2, "aggregation must not add a row")
        #expect(tray.events.last?.count == 5)
        #expect(tray.events.last?.event.actor == "capture")
        // The original timestamp identifies the row: the burst keeps the time
        // of the event that opened its window.
        #expect(tray.events.last?.event.ts == Self.baseDate)
    }

    @Test func testApplyAggregateTargetsTheNewestOfDuplicateKeys() {
        var tray = TrayModel()
        tray.record(event(actor: "capture", secondsOffset: 0))
        tray.record(event(actor: "other", kind: .micOn, secondsOffset: 1))
        tray.record(event(actor: "capture", secondsOffset: 2))  // same key again

        tray.applyAggregate(event(actor: "capture", secondsOffset: 3), count: 2)

        #expect(tray.events.first?.count == 2)  // the newest "capture" row
        #expect(tray.events.last?.count == 1)  // untouched
    }

    @Test func testApplyAggregateIgnoresDifferentKeys() {
        var tray = TrayModel()
        tray.record(event(actor: "capture", kind: .screenCapture, tier: .normal, secondsOffset: 0))

        // Same actor, different kind / tier: a different notification stream,
        // so a different row.
        tray.applyAggregate(
            event(actor: "capture", kind: .cameraOn, tier: .normal, secondsOffset: 1),
            count: 4
        )
        tray.applyAggregate(
            event(actor: "capture", kind: .screenCapture, tier: .org, secondsOffset: 2),
            count: 4
        )
        #expect(tray.events.first?.count == 1)
        #expect(tray.events.count == 1, "aggregation must not add a row")
    }

    @Test func testApplyAggregateWithoutMatchingEntryIsNoOp() {
        var tray = TrayModel()
        tray.applyAggregate(event(actor: "never-seen", secondsOffset: 0), count: 3)

        #expect(tray.events.isEmpty)

        // The window's first row may have been pushed out of the 10 by other
        // events; a later aggregate for it then has nothing to fold into and
        // must not resurrect a stale row.
        for index in 0..<12 {
            tray.record(event(actor: "actor-\(index)", secondsOffset: TimeInterval(index)))
        }
        let before = tray.events
        tray.applyAggregate(event(actor: "actor-0", secondsOffset: 20), count: 9)
        #expect(tray.events == before)
    }
}
