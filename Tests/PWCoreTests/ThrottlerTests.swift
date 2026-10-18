import Foundation
import Testing

import PWCore

/// Tests for `Throttler` (spec §5 grouping, plan T7).
///
/// Every test drives the clock through a hand-held `TestClock`, so "time" only
/// moves when a test tells it to: no test sleeps, none depends on the wall
/// clock, and each decision is fully deterministic.
///
/// The pinned rule under test is the *fixed* window: the 60 s window for a key
/// runs from that key's last `notify`, not from its most recent event, so a
/// key that keeps firing never pushes the next notification forward. The
/// window is half-open — a `notify` at `t` covers `[t, t + 60)`, and an event
/// landing exactly on `t + 60` opens a new window. That keeps any two
/// notifications for one key at least 60 s apart.
@Suite struct ThrottlerTests {

    // MARK: - Helpers

    /// A hand-driven clock: the only source of "now" the Throttler ever sees.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_762_000_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    /// One NORMAL-tier screen-capture event, `count` already 1 as the
    /// Classifier produces it. `ts` is cosmetic for the Throttler: it reads its
    /// own injected clock, never the event's timestamp.
    private func classified(
        actor: String = "screencaptureui",
        kind: EventKind = .screenCapture,
        tier: Tier = .normal
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: Date(timeIntervalSince1970: 1_762_000_000),
                source: .logstream,
                kind: kind,
                actor: actor
            ),
            tier: tier,
            reason: "default"
        )
    }

    private func makeThrottler(_ clock: TestClock, window: TimeInterval = 60) -> Throttler {
        Throttler(window: window, now: { clock.now })
    }

    // MARK: - First event of a window

    @Test func testFirstEmitsNotify() {
        let clock = TestClock()
        let throttler = makeThrottler(clock)
        #expect(throttler.window == 60)

        let event = classified()
        #expect(throttler.process(event) == .notify(event))
    }

    @Test func testNotifyAlwaysCarriesCountOne() {
        // `.notify` means "first event of a window". Even if a caller hands
        // over an event carrying a stale count, the decision carries 1.
        let clock = TestClock()
        let throttler = makeThrottler(clock)

        var stale = classified()
        stale.count = 7
        #expect(throttler.process(stale) == .notify(classified()))
    }

    // MARK: - Grouping inside a window

    @Test func testSameKeyWithinWindowAggregates() {
        let clock = TestClock()
        let throttler = makeThrottler(clock)

        let first = classified()
        #expect(throttler.process(first) == .notify(first))

        clock.advance(5)
        #expect(throttler.process(classified()) == .aggregated(count: 2))

        clock.advance(5) // 10 s after the notify: still the same window
        #expect(throttler.process(classified()) == .aggregated(count: 3))

        // A fourth event at the same instant keeps counting; the window does
        // not slide on every event.
        #expect(throttler.process(classified()) == .aggregated(count: 4))
    }

    @Test func testDifferentActorSeparate() {
        let clock = TestClock()
        let throttler = makeThrottler(clock)

        let ui = classified(actor: "screencaptureui")
        let replayd = classified(actor: "replayd")

        #expect(throttler.process(ui) == .notify(ui))
        #expect(throttler.process(replayd) == .notify(replayd))
        // Each key keeps its own count.
        #expect(throttler.process(ui) == .aggregated(count: 2))
        #expect(throttler.process(replayd) == .aggregated(count: 2))
    }

    @Test func testDifferentKindSeparate() {
        let clock = TestClock()
        let throttler = makeThrottler(clock)

        let capture = classified(kind: .screenCapture)
        let camera = classified(kind: .cameraOn)

        #expect(throttler.process(capture) == .notify(capture))
        #expect(throttler.process(camera) == .notify(camera))
        #expect(throttler.process(capture) == .aggregated(count: 2))
    }

    @Test func testDifferentTierSeparate() {
        // The same observation classified twice (e.g. the watchlist changed
        // between events) must not share a window: tier is part of the key.
        let clock = TestClock()
        let throttler = makeThrottler(clock)

        let normal = classified(tier: .normal)
        let remote = classified(tier: .remote)

        #expect(throttler.process(normal) == .notify(normal))
        #expect(throttler.process(remote) == .notify(remote))
        #expect(throttler.process(normal) == .aggregated(count: 2))
        #expect(throttler.process(remote) == .aggregated(count: 2))
    }

    // MARK: - Window expiry

    @Test func testAfterWindowEmitsAgain() {
        let clock = TestClock()
        let throttler = makeThrottler(clock)

        let first = classified()
        #expect(throttler.process(first) == .notify(first))

        clock.advance(10)
        #expect(throttler.process(classified()) == .aggregated(count: 2))

        // 61 s after the notify: the window is over, so this key notifies
        // again and its count starts over at 1 — not 3.
        clock.advance(51)
        let second = classified()
        #expect(throttler.process(second) == .notify(second))

        clock.advance(4)
        #expect(throttler.process(classified()) == .aggregated(count: 2))
    }

    @Test func testWindowBoundaryIsHalfOpen() {
        // The window is `[notify, notify + 60)`. 59.5 s after the notify is
        // still inside; exactly 60.0 s opens a new window.
        let clock = TestClock()
        let throttler = makeThrottler(clock)

        let first = classified()
        #expect(throttler.process(first) == .notify(first))

        clock.advance(59.5)
        #expect(throttler.process(classified()) == .aggregated(count: 2))

        clock.advance(0.5) // exactly 60.0 s after the notify
        let next = classified()
        #expect(throttler.process(next) == .notify(next))
    }

    @Test func testCustomWindowHonoured() {
        let clock = TestClock()
        let throttler = makeThrottler(clock, window: 5)

        let first = classified()
        #expect(throttler.process(first) == .notify(first))

        clock.advance(4)
        #expect(throttler.process(classified()) == .aggregated(count: 2))

        clock.advance(1)
        let next = classified()
        #expect(throttler.process(next) == .notify(next))
    }

    // MARK: - Burst performance (Review Focus #5)

    @Test func testBurstPerformance() {
        // A "Mission Control hammered" burst: 10,000 events over 300 live keys
        // with the clock moving forward the whole time, so the run also forces
        // window expiry, re-notify and re-grouping. The Throttler must do
        // fixed-size dictionary bookkeeping per event; anything that rescans
        // the known keys would blow up here. Each key fires every 300 events =
        // 3 s of this clock, so one 60 s window holds 20 of its events.
        let clock = TestClock()
        let throttler = makeThrottler(clock)
        let kinds: [EventKind] = [.screenCapture, .cameraOn, .micOn, .remoteControlProcess]
        let tiers: [Tier] = [.normal, .remote, .org]

        /// The 300 recurring streams, as indices so the bookkeeping below is
        /// cheap enough not to distort the measurement.
        struct Stream: Hashable {
            let actor: Int
            let kind: Int
            let tier: Int
        }

        // `.aggregated(count:)` is the running window total, so the delta
        // against the key's previous decision is what this event contributed.
        var lastCounts: [Stream: Int] = [:]
        var accounted = 0
        var notifies = 0
        var largestCount = 0

        let stopwatch = ContinuousClock()
        let elapsed = stopwatch.measure {
            for i in 0..<10_000 {
                let stream = Stream(actor: i % 50, kind: i % kinds.count, tier: i % tiers.count)
                let event = classified(
                    actor: "actor\(stream.actor)",
                    kind: kinds[stream.kind],
                    tier: tiers[stream.tier]
                )

                switch throttler.process(event) {
                case .notify(let first):
                    notifies += 1
                    accounted += first.count
                    lastCounts[stream] = first.count
                case .aggregated(let count):
                    accounted += count - (lastCounts[stream] ?? 0)
                    lastCounts[stream] = count
                    largestCount = max(largestCount, count)
                }
                clock.advance(0.01) // 100 s of events overall
            }
        }

        // Correctness under load: each event is folded in exactly once...
        #expect(accounted == 10_000)
        // ...the burst really grouped (notifies are rare, and a key fires
        // every 3 s here, so a 60 s window holds 20 of its events; 21 only
        // because 10,000 stacked `+0.01` additions leave the 60.0 s occurrence
        // ~60 µs inside the window — a clock-drift artifact of the test, not a
        // Throttler rule; the exact boundary is pinned in
        // testWindowBoundaryIsHalfOpen)...
        #expect(notifies > 0 && notifies < 1_000)
        #expect((20...21).contains(largestCount))
        // ...and it stayed well inside the budget (Review Focus #5).
        #expect(elapsed < .seconds(1), "10,000-event burst took \(elapsed)")
    }
}
