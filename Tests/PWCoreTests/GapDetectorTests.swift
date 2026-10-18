import Foundation
import Testing

import PWCore

/// Tests for `GapDetector` (plan T9, spec §4 monitor-gap, Review Focus #4).
///
/// The detector is pure arithmetic over its arguments — it never reads a
/// clock itself — so every test is a fixed pair of `Date`s, fully
/// deterministic. The pinned rule under test: a gap is reported exactly when
/// `lastActivity` exists and `now - lastActivity > threshold`. The boundary
/// is strict: `duration == threshold` is *not* a gap, and a negative
/// duration (the clock moved backwards) is never a gap.
@Suite struct GapDetectorTests {

    // MARK: - Helpers

    /// One fixed instant, used as "now" unless a test says otherwise.
    private let now = Date(timeIntervalSince1970: 1_762_000_000)

    private func makeDetector(threshold: TimeInterval = 15 * 60) -> GapDetector {
        GapDetector(threshold: threshold)
    }

    // MARK: - No gap

    @Test func testNoGapWithinThreshold() {
        // 5 minutes of silence with a 15-minute threshold: the monitor was
        // merely quiet, not gone.
        let detector = makeDetector()
        let lastActivity = now.addingTimeInterval(-5 * 60)

        #expect(detector.detect(now: now, lastActivity: lastActivity) == nil)
    }

    @Test func testDurationExactlyThresholdIsNotAGap() {
        // The pinned boundary is `duration <= threshold → nil`: exactly 15
        // minutes of silence does not yet cross it.
        let detector = makeDetector()
        let lastActivity = now.addingTimeInterval(-15 * 60)

        #expect(detector.detect(now: now, lastActivity: lastActivity) == nil)
    }

    @Test func testNilLastActivity() {
        // No log at all (fresh install): nothing to compare against, so no
        // gap can be claimed.
        #expect(makeDetector().detect(now: now, lastActivity: nil) == nil)
    }

    // MARK: - Gap

    @Test func testGapOverThreshold() {
        let detector = makeDetector()
        let lastActivity = now.addingTimeInterval(-30 * 60)

        let report = detector.detect(now: now, lastActivity: lastActivity)

        #expect(report != nil)
        // The report spans the whole silence: from the last known activity to
        // now, with the duration matching the span exactly.
        #expect(report?.from == lastActivity)
        #expect(report?.to == now)
        // Explicit doubles: `30 * 60` alone infers as `Int` and compares as
        // one, which is not the type `duration` carries.
        #expect(report?.duration == 1800.0)
    }

    // MARK: - Clock moving backwards (Review Focus #4)

    @Test func testNegativeDurationReturnsNil() {
        // `lastActivity` in the future of `now`: the clock jumped backwards
        // (NTP correction, manual change, DST-style jump). A negative gap is
        // nonsense, so the detector reports nothing rather than an absurd
        // report.
        let detector = makeDetector()
        let lastActivity = now.addingTimeInterval(60 * 60)

        #expect(detector.detect(now: now, lastActivity: lastActivity) == nil)
    }

    // MARK: - Zero threshold

    @Test func testZeroThreshold() {
        let detector = makeDetector(threshold: 0)

        // Any positive silence is a gap...
        let oneSecondAgo = now.addingTimeInterval(-1)
        let report = detector.detect(now: now, lastActivity: oneSecondAgo)
        #expect(report?.duration == 1.0)

        // ...but zero silence is not (`duration <= threshold` semantics): an
        // activity stamped at `now` exactly is the boundary, not a gap.
        #expect(detector.detect(now: now, lastActivity: now) == nil)
    }
}
