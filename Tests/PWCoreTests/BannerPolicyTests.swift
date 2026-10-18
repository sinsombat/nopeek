import Foundation
import Testing

import PWCore

/// Tests for `BannerPolicy` (spec §5–§6: the red banner's per-actor cooldown,
/// plan T16).
///
/// The policy is the *second* of the two independent banner controls: the
/// `Pipeline` decides per tier whether a banner is even eligible (ORG always,
/// REMOTE per `bannerOnForRemote`, spec §5), and this policy decides whether an
/// eligible banner shows now or is folded into an actor's cooldown window.
/// Nothing here touches the notification path — the paired Pipeline test at the
/// bottom of this file pins that a suppressed banner never suppresses a
/// notification.
///
/// Time is hand-held: the policy's only clock is the injected `now` closure.
@Suite struct BannerPolicyTests {

    // MARK: - Helpers

    /// A hand-driven clock: the only source of "now" the policy can see.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_762_000_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    /// One classified event, built directly: the policy reads only `actor` and
    /// `tier`, so these tests do not need a `Classifier` in the way.
    private func event(
        actor: String,
        tier: Tier,
        kind: EventKind = .screenCapture
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: Date(timeIntervalSince1970: 1_762_000_000),
                source: .logstream,
                kind: kind,
                actor: actor
            ),
            tier: tier,
            reason: "test"
        )
    }

    // MARK: - Cooldown semantics

    @Test func testFirstShows() {
        let clock = TestClock()
        let policy = BannerPolicy(cooldown: 60, now: { clock.now })

        // The first event of an actor is never inside a window: ORG and REMOTE
        // both show immediately (spec §5/§6).
        #expect(policy.shouldShow(event(actor: "TeamViewer", tier: .org)))
        #expect(policy.shouldShow(event(actor: "screensharingd", tier: .remote)))
    }

    @Test func testRepeatWithinCooldownSuppressed() {
        let clock = TestClock()
        let policy = BannerPolicy(cooldown: 60, now: { clock.now })

        #expect(policy.shouldShow(event(actor: "TeamViewer", tier: .org)))

        // Repeats inside the 60 s window are suppressed — the banner fired
        // once for this actor (spec §5), the notification path is elsewhere.
        clock.advance(5)
        #expect(!policy.shouldShow(event(actor: "TeamViewer", tier: .org)))

        clock.advance(54) // 59 s after the show: still strictly inside
        #expect(!policy.shouldShow(event(actor: "TeamViewer", tier: .org)))

        // A different kind from the same actor is the same banner — the key is
        // the actor, not the event.
        clock.advance(0)
        #expect(!policy.shouldShow(event(actor: "TeamViewer", tier: .org, kind: .remoteControlProcess)))
    }

    @Test func testDifferentActorSeparate() {
        let clock = TestClock()
        let policy = BannerPolicy(cooldown: 60, now: { clock.now })

        #expect(policy.shouldShow(event(actor: "TeamViewer", tier: .org)))

        // Another actor has its own window: it shows even though TeamViewer's
        // is still open — and it does not disturb TeamViewer's.
        clock.advance(5)
        #expect(policy.shouldShow(event(actor: "AnyDesk", tier: .org)))
        #expect(!policy.shouldShow(event(actor: "TeamViewer", tier: .org)))
        // The key spans both admitting tiers: a REMOTE actor is tracked the
        // same way.
        #expect(policy.shouldShow(event(actor: "screensharingd", tier: .remote)))
        #expect(!policy.shouldShow(event(actor: "AnyDesk", tier: .org)))
    }

    @Test func testAfterCooldownShowsAgain() {
        let clock = TestClock()
        let policy = BannerPolicy(cooldown: 60, now: { clock.now })

        #expect(policy.shouldShow(event(actor: "TeamViewer", tier: .org)))

        // Suppressed repeats must not push the window forward: the cooldown is
        // measured from the last *shown* banner, not the last event.
        clock.advance(30)
        #expect(!policy.shouldShow(event(actor: "TeamViewer", tier: .org)))
        clock.advance(20) // 50 s total
        #expect(!policy.shouldShow(event(actor: "TeamViewer", tier: .org)))

        // Exactly 60 s after the show the actor is due again ("within" the
        // cooldown is strictly less than it).
        clock.advance(10)
        #expect(policy.shouldShow(event(actor: "TeamViewer", tier: .org)))
    }

    @Test func testNonOrgRemoteTiersNeverBanner() {
        let clock = TestClock()
        let policy = BannerPolicy(cooldown: 60, now: { clock.now })

        // Only ORG and REMOTE are banner tiers (spec §5): NORMAL, SYSTEM_NOISE
        // and ALLOWLIST are refused, repeatedly.
        for tier in [Tier.normal, .systemNoise, .allowlist] {
            #expect(!policy.shouldShow(event(actor: "Safari", tier: tier)))
        }

        // Refused events are not recorded: a later ORG event for the same
        // actor is still a first show, not a repeat.
        #expect(policy.shouldShow(event(actor: "Safari", tier: .org)))
    }

    // MARK: - Paired with the Pipeline (the pinned pairing test)

    @Test func testOrgBannerCooldownSuppressesRepeatButNotNotification() {
        // AppController's real wiring, as a pair: the Pipeline emits `.banner`
        // for every ORG event (it does not throttle banners), and the sink asks
        // the policy whether to actually show one. A suppressed banner is
        // silent *there only* — the notification path must be unaffected
        // (spec §5: "event ระหว่าง cooldown ยังได้ notification").
        final class Recorder {
            var actions: [Action] = []
            var bannersShown = 0

            func record(_ action: Action) {
                actions.append(action)
            }

            func reset() {
                actions.removeAll()
            }
        }

        let clock = TestClock()
        let classifier = Classifier(org: ["TeamViewer"], noise: [], allowlist: [], remote: [])
        let policy = BannerPolicy(cooldown: 60, now: { clock.now })
        let recorder = Recorder()

        let pipeline = Pipeline(
            classifier: classifier,
            throttler: Throttler(window: 60, now: { clock.now }),
            sink: { action in
                recorder.record(action)
                if case .banner(let event) = action, policy.shouldShow(event) {
                    recorder.bannersShown += 1
                }
            },
            remoteBannerEnabled: { true }
        )

        func raw() -> RawEvent {
            RawEvent(
                ts: Date(timeIntervalSince1970: 1_762_000_000),
                source: .logstream,
                kind: .screenCapture,
                actor: "TeamViewer"
            )
        }

        let first = raw()
        pipeline.handle(first)

        let expected = classifier.classify(first)
        #expect(expected.tier == .org)
        #expect(recorder.bannersShown == 1)
        #expect(recorder.actions == [
            .appendLog(expected),
            .notify(expected),
            .banner(expected),
            .trayUpdate(expected),
        ])

        // 5 s later: inside both windows. The Pipeline still emits the banner
        // (its job is eligibility, not cooldown) and the notification path
        // still fires — as an aggregate of the running count, never muted.
        clock.advance(5)
        recorder.reset()
        pipeline.handle(raw())

        #expect(recorder.bannersShown == 1) // the cooldown suppressed the show…
        #expect(recorder.actions == [
            .appendLog(expected),
            .aggregated(expected, count: 2),
            .banner(expected),
            .trayUpdate(expected),
        ])
    }
}
