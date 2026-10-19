import Foundation
import Testing

import PWCore

/// Tests for `StartupPlan` (plan T24, spec §3/§4).
///
/// The plan is the startup sequence as one call — read the log's last
/// activity, record the boot, purge retention, measure the gap — with every
/// step injected, so the whole contract is testable without a file, a clock or
/// a notification centre.
///
/// The order is the point. `lastActivity()` must be read **before** the
/// `monitor-started` line is written: the write makes the log fresh, so a
/// check that read it afterwards would measure a zero gap on every launch and
/// the silence this feature exists to surface (machine asleep, or the app not
/// running) would never be reported. `testStartupOrderIsReadThenBootThenPurge`
/// pins the order, and `testGapIsMeasuredFromTheValueReadBeforeTheBootLine`
/// pins its consequence — the order test alone would pass on an
/// implementation that read the log twice, once before and once after.
@Suite struct StartupPlanTests {

    // MARK: - Helpers

    /// Fixed "now", the anchor `GapDetectorTests` uses.
    private let now = Date(timeIntervalSince1970: 1_762_000_000)

    /// A stand-in evidence log with exactly the behaviour the ordering rule
    /// exists for: a read that reports the last activity, and a boot write that
    /// makes the log's activity fresh.
    private final class Log {
        private(set) var lastActivity: Date?
        private(set) var calls: [String] = []
        private let clock: Date

        init(lastActivity: Date?, clock: Date) {
            self.lastActivity = lastActivity
            self.clock = clock
        }

        func read() -> Date? {
            calls.append("read")
            return lastActivity
        }

        func appendBoot() {
            calls.append("monitor-started")
            lastActivity = clock
        }

        func purge() {
            calls.append("purge")
        }
    }

    private func plan(minutes: Int = 15) -> StartupPlan {
        let anchor = now
        return StartupPlan(gapAlertThresholdMinutes: minutes, now: { anchor })
    }

    /// The real wiring as one call: `AppController.start()` passes the log's
    /// three bodies and nothing else; `StartupPlan` supplies the order.
    private func run(_ plan: StartupPlan, on log: Log) -> GapReport? {
        plan.run(
            lastActivity: { log.read() },
            appendMonitorStarted: { log.appendBoot() },
            purgeOldFiles: { log.purge() }
        )
    }

    // MARK: - The pinned order (spec §3/§4)

    @Test func testStartupOrderIsReadThenBootThenPurge() {
        let log = Log(lastActivity: now.addingTimeInterval(-20 * 60), clock: now)

        let gap = run(plan(), on: log)

        // The order the plan's T24 interface pins: the read, then the boot
        // line, then retention.
        #expect(log.calls == ["read", "monitor-started", "purge"])
        // 20 minutes of silence is over the 15-minute threshold, so the run's
        // fourth step (the decision) reports it — the measurement itself is the
        // next test's subject.
        #expect(gap != nil)
    }

    @Test func testGapIsMeasuredFromTheValueReadBeforeTheBootLine() {
        // The edge case the order exists for: the boot line becomes the newest
        // activity, so an implementation that read the log after writing it
        // would always see a fresh log. The report must span the silence that
        // preceded this launch, exactly.
        let lastActivity = now.addingTimeInterval(-20 * 60)
        let log = Log(lastActivity: lastActivity, clock: now)

        let gap = run(plan(), on: log)

        #expect(gap?.from == lastActivity)
        #expect(gap?.to == now)
        #expect(gap?.duration == 1200.0)
        // And the boot write really did land, so the value above cannot be the
        // log's current activity — that one is `now`.
        #expect(log.lastActivity == now)
    }

    @Test func testStepsRunOnEveryLaunch() {
        // A fresh install: no last activity, so no gap to report — but the
        // boot line and the purge are unconditional. Only the report is not.
        let log = Log(lastActivity: nil, clock: now)

        #expect(run(plan(), on: log) == nil)
        #expect(log.calls == ["read", "monitor-started", "purge"])
        #expect(log.lastActivity == now)
    }

    // MARK: - The gap decision

    @Test func testSilenceAtTheThresholdIsNotAGap() {
        // `gapAlertThresholdMinutes` is minutes (spec §7) while `GapDetector`
        // takes seconds: exactly one minute of silence is quiet, one minute and
        // one second is a gap.
        let quiet = Log(lastActivity: now.addingTimeInterval(-60), clock: now)
        #expect(run(plan(minutes: 1), on: quiet) == nil)

        let over = Log(lastActivity: now.addingTimeInterval(-61), clock: now)
        #expect(run(plan(minutes: 1), on: over)?.duration == 61.0)
    }

    @Test func testMinutesAreConvertedToSeconds() {
        // 5 minutes of silence (300 s) under the default 15-minute threshold:
        // not a gap. Had the threshold been read as 15 *seconds*, this would
        // report one — the discriminating assertion.
        let five = Log(lastActivity: now.addingTimeInterval(-5 * 60), clock: now)
        #expect(run(plan(), on: five) == nil)

        let over = Log(lastActivity: now.addingTimeInterval(-(15 * 60 + 1)), clock: now)
        #expect(run(plan(), on: over)?.duration == 901.0)
    }

    @Test func testClockMovedBackwardsIsNotAGap() {
        // `lastActivity` in the future of `now` (the clock stepped backwards):
        // `GapDetector`'s pinned rule, reached through the plan unchanged.
        let log = Log(lastActivity: now.addingTimeInterval(60 * 60), clock: now)
        #expect(run(plan(), on: log) == nil)
    }
}
