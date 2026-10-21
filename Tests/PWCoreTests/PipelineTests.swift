import Foundation
import Testing

import PWCore

/// Tests for `Pipeline` (spec §5–§6 tier routing, plan T11).
///
/// The pipeline has no clock of its own: the only time it reads is the
/// injected `Throttler`'s, which every test drives through a hand-held
/// `TestClock`. A `Recorder` sink captures the exact, ordered `Action` list
/// for each event, so the tests pin the routing table literally instead of
/// inferring it from counts.
///
/// The pinned order per event is
/// `appendLog` → `notify`/`aggregated` (throttled) → `banner` → `trayUpdate`,
/// with `.appendLog` always present and always first.
@Suite struct PipelineTests {

    // MARK: - Helpers

    /// A hand-driven clock: the only source of "now" the pipeline can see
    /// (through its `Throttler`).
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_762_000_000)

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    /// Records every action the sink receives, in emission order.
    private final class Recorder {
        private(set) var actions: [Action] = []

        func record(_ action: Action) {
            actions.append(action)
        }

        func reset() {
            actions.removeAll()
        }
    }

    /// One pipeline wired to a recording sink and a hand-held clock, plus the
    /// classifier it uses so a test can compute the expected `ClassifiedEvent`
    /// without duplicating classification logic.
    private func makePipeline(
        remoteBannerEnabled: @escaping () -> Bool = { true }
    ) -> (pipeline: Pipeline, classifier: Classifier, recorder: Recorder, clock: TestClock) {
        let classifier = Classifier(
            org: ["TeamViewer"],
            noise: ["WindowManager"],
            allowlist: ["1Password"],
            remote: ["screensharingd"]
        )
        let recorder = Recorder()
        let clock = TestClock()
        let pipeline = Pipeline(
            classifier: classifier,
            throttler: Throttler(window: 60, now: { clock.now }),
            sink: { recorder.record($0) },
            remoteBannerEnabled: remoteBannerEnabled
        )
        return (pipeline, classifier, recorder, clock)
    }

    private func raw(
        actor: String,
        kind: EventKind = .screenCapture,
        source: EventSource = .logstream
    ) -> RawEvent {
        RawEvent(
            ts: Date(timeIntervalSince1970: 1_762_000_000),
            source: source,
            kind: kind,
            actor: actor
        )
    }

    // MARK: - ORG: never suppressed

    @Test func testOrgAlwaysNotifiesEvenWhenPaused() {
        let (pipeline, classifier, recorder, _) = makePipeline()
        pipeline.setPaused(true)

        let rawEvent = raw(actor: "TeamViewer")
        pipeline.handle(rawEvent)

        let expected = classifier.classify(rawEvent)
        #expect(expected.tier == .org)
        // Spec §5: Pause never touches ORG. Logged, notified, banner and tray,
        // in that order, even while paused.
        #expect(recorder.actions == [
            .appendLog(expected),
            .notify(expected),
            .banner(expected),
            .trayUpdate(expected),
        ])
    }

    @Test func testRemoteNotifiesEvenWhenPaused() {
        // Spec §5: Pause suppresses NORMAL only — REMOTE stays live.
        let (pipeline, classifier, recorder, _) = makePipeline()
        pipeline.setPaused(true)

        let rawEvent = raw(actor: "screensharingd")
        pipeline.handle(rawEvent)

        let expected = classifier.classify(rawEvent)
        #expect(expected.tier == .remote)
        #expect(recorder.actions == [
            .appendLog(expected),
            .notify(expected),
            .banner(expected),
            .trayUpdate(expected),
        ])
    }

    // MARK: - NORMAL: pause suppresses the notification, not the record

    @Test func testNormalSuppressedWhenPausedButLogged() {
        let (pipeline, classifier, recorder, _) = makePipeline()
        pipeline.setPaused(true)

        let rawEvent = raw(actor: "Safari")
        pipeline.handle(rawEvent)

        let expected = classifier.classify(rawEvent)
        #expect(expected.tier == .normal)
        // Logged, and still fed to the tray (the menu's "last 10 events"
        // list, spec §6), but no notification of any kind — not even an
        // aggregate.
        #expect(recorder.actions == [.appendLog(expected), .trayUpdate(expected)])
    }

    @Test func testUnpauseNotifiesFreshAfterSuppressedNormal() {
        let (pipeline, classifier, recorder, clock) = makePipeline()

        pipeline.setPaused(true)
        pipeline.handle(raw(actor: "Safari"))
        recorder.reset()

        // Still inside a 60 s window, had the suppressed event opened one.
        clock.advance(5)
        pipeline.setPaused(false)
        let resumedRaw = raw(actor: "Safari")
        pipeline.handle(resumedRaw)

        // The suppressed event must not have opened a throttle window: the
        // first event after unpause is a fresh `.notify` (count 1), not an
        // aggregate of a notification the user never saw.
        let expected = classifier.classify(resumedRaw)
        #expect(recorder.actions == [
            .appendLog(expected),
            .notify(expected),
            .trayUpdate(expected),
        ])
    }

    // MARK: - NOISE / ALLOWLIST: appendLog only

    @Test func testNoiseOnlyLogs() {
        let (pipeline, classifier, recorder, _) = makePipeline()
        // Pause must not shift these tiers either way.
        pipeline.setPaused(true)

        for actor in ["WindowManager", "1Password"] {
            recorder.reset()
            let rawEvent = raw(actor: actor)
            pipeline.handle(rawEvent)

            let expected = classifier.classify(rawEvent)
            #expect(expected.tier == .systemNoise || expected.tier == .allowlist)
            #expect(recorder.actions == [.appendLog(expected)])
        }
    }

    // MARK: - Off-events are log-only (R20)

    @Test func testOffEventsAreLogOnly() {
        // Spec §5 (R20): `cameraOff` / `micOff` mark the *end* of an
        // observation, not a new one. They are logged and fed to the tray —
        // and that is all: no `.notify`/`.aggregated` (so they never touch the
        // Throttler either) and no `.banner`. Pause is irrelevant to them, so
        // both pause states must produce the identical list: the gate sits
        // before the tier routing, not inside the NORMAL branch.
        let (pipeline, classifier, recorder, _) = makePipeline()

        let cases: [(actor: String, kind: EventKind, source: EventSource)] = [
            ("Photo Booth", .cameraOff, .logstream),   // camera stopRunning line (T14)
            ("VoiceMemos", .micOff, .logstream),       // coreaudiod recorder stop (v1.1)
        ]

        for paused in [false, true] {
            pipeline.setPaused(paused)
            for testCase in cases {
                recorder.reset()
                let rawEvent = raw(actor: testCase.actor, kind: testCase.kind, source: testCase.source)
                pipeline.handle(rawEvent)

                let expected = classifier.classify(rawEvent)
                #expect(expected.tier == .normal)
                #expect(recorder.actions == [.appendLog(expected), .trayUpdate(expected)])
            }
        }
    }

    @Test func testRealMicLogReplayThroughPipeline() throws {
        // Controlled replay of the two real probe lines through the shipped
        // parser *and* this pipeline: the start is a NORMAL notification
        // (`appendLog` → `notify` → `trayUpdate`), the stop is R20 log-only
        // (`appendLog` → `trayUpdate`). This is the v1.1 replacement path for
        // the removed MicWatch poll, exercised end to end without a recorder.
        let parser = LogLineParser(resolveClient: { pid in
            pid == 15522
                ? (name: "VoiceMemos", path: "/System/Applications/VoiceMemos.app/Contents/MacOS/VoiceMemos")
                : nil
        })
        let fixture = try #require(
            Bundle.module.url(
                forResource: "probe-mic-2026-10-21",
                withExtension: "ndjson",
                subdirectory: "Fixtures"
            )
        )
        let lines = try String(contentsOf: fixture, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        let startLine = try #require(
            lines.first { $0.contains("PublishRecordingClientInfo") && $0.contains("running: yes") }
        )
        let stopLine = try #require(
            lines.first { $0.contains("PublishRecordingClientInfo") && $0.contains("running: no") }
        )

        let (pipeline, classifier, recorder, _) = makePipeline()

        let start = try #require(parser.parse(line: startLine))
        #expect(start.kind == .micOn)
        #expect(start.actor == "VoiceMemos")
        pipeline.handle(start)
        let startExpected = classifier.classify(start)
        #expect(startExpected.tier == .normal)
        #expect(recorder.actions == [
            .appendLog(startExpected),
            .notify(startExpected),
            .trayUpdate(startExpected),
        ])

        recorder.reset()
        let stop = try #require(parser.parse(line: stopLine))
        #expect(stop.kind == .micOff)
        #expect(stop.actor == "VoiceMemos")
        pipeline.handle(stop)
        let stopExpected = classifier.classify(stop)
        #expect(recorder.actions == [.appendLog(stopExpected), .trayUpdate(stopExpected)])
    }

    // MARK: - REMOTE banner follows the live config closure

    @Test func testRemoteBannerRespectsConfig() {
        var bannerOn = false
        let (pipeline, classifier, recorder, _) = makePipeline(remoteBannerEnabled: { bannerOn })
        // REMOTE is not suppressed by pause; this test also pins that on the
        // way past.
        pipeline.setPaused(true)

        let offRaw = raw(actor: "screensharingd")
        pipeline.handle(offRaw)
        let off = classifier.classify(offRaw)
        #expect(off.tier == .remote)
        #expect(recorder.actions == [.appendLog(off), .notify(off), .trayUpdate(off)])

        // The closure is read live per event: a config reload that flips
        // `bannerOnForRemote` takes effect on the next REMOTE event without
        // rebuilding the pipeline. (Different kind → different throttle key,
        // so the second event notifies rather than aggregates.)
        bannerOn = true
        recorder.reset()
        let onRaw = raw(actor: "screensharingd", kind: .remoteControlProcess)
        pipeline.handle(onRaw)
        let on = classifier.classify(onRaw)
        #expect(recorder.actions == [
            .appendLog(on),
            .notify(on),
            .banner(on),
            .trayUpdate(on),
        ])
    }

    // MARK: - Live classifier swap (T23)

    @Test func testSetClassifierSwapsTheRulesInPlace() {
        // The app rebuilds the `Classifier` when the config changes (T23) and
        // hands it to the pipeline that is already running: no new pipeline,
        // no lost state. The swap must apply to the *next* event, both ways —
        // a name that just joined the watchlist becomes REMOTE, and a rule the
        // new classifier does not carry is gone (a merge would keep it).
        let (pipeline, _, recorder, _) = makePipeline()

        // An actor nobody knows: NORMAL — logged, notified, trayed, no banner.
        let beforeRaw = raw(actor: "before-swap")
        pipeline.handle(beforeRaw)
        let before = Classifier(remote: ["screensharingd"]).classify(beforeRaw)
        #expect(before.tier == .normal)
        #expect(recorder.actions == [.appendLog(before), .notify(before), .trayUpdate(before)])

        // Swap in a classifier that watches a brand-new name — and does *not*
        // carry the remote watchlist the old one had.
        let swapped = Classifier(remote: ["new-agent"])
        pipeline.setClassifier(swapped)
        recorder.reset()

        let joinedRaw = raw(actor: "new-agent")
        pipeline.handle(joinedRaw)
        let joined = swapped.classify(joinedRaw)
        #expect(joined.tier == .remote)
        #expect(recorder.actions == [
            .appendLog(joined),
            .notify(joined),
            .banner(joined),
            .trayUpdate(joined),
        ])

        // The replaced rule is really gone: `screensharingd` classified REMOTE
        // before the swap and is NORMAL after it.
        recorder.reset()
        let droppedRaw = raw(actor: "screensharingd")
        pipeline.handle(droppedRaw)
        let dropped = swapped.classify(droppedRaw)
        #expect(dropped.tier == .normal)
        #expect(recorder.actions == [.appendLog(dropped), .notify(dropped), .trayUpdate(dropped)])
    }

    // MARK: - Throttler gates `.notify` only

    @Test func testAggregatedActionAfterThrottle() {
        let (pipeline, classifier, recorder, clock) = makePipeline()

        let rawEvent = raw(actor: "Safari")
        let expected = classifier.classify(rawEvent)

        pipeline.handle(rawEvent)
        #expect(recorder.actions == [
            .appendLog(expected),
            .notify(expected),
            .trayUpdate(expected),
        ])

        recorder.reset()
        clock.advance(5) // same key, inside the 60 s window

        pipeline.handle(raw(actor: "Safari"))
        // Exactly one notification-side action for the repeat — an aggregate
        // carrying the running count — and never a second `.notify`.
        #expect(recorder.actions == [
            .appendLog(expected),
            .aggregated(expected, count: 2),
            .trayUpdate(expected),
        ])
    }

    @Test func testOrgRepeatAggregatesButStillBanners() {
        // The Throttler gates `.notify` only. A repeated ORG event inside the
        // window still emits `.banner`: T16's BannerPolicy owns the per-actor
        // banner cooldown (`orgBannerCooldownSeconds`), so the pipeline must
        // not apply the notification throttle to banners here.
        let (pipeline, classifier, recorder, clock) = makePipeline()

        let orgRaw = raw(actor: "TeamViewer")
        pipeline.handle(orgRaw)
        recorder.reset()

        clock.advance(5)
        pipeline.handle(raw(actor: "TeamViewer"))

        let expected = classifier.classify(orgRaw)
        #expect(recorder.actions == [
            .appendLog(expected),
            .aggregated(expected, count: 2),
            .banner(expected),
            .trayUpdate(expected),
        ])
    }

    // MARK: - Ordering invariant

    @Test func testAppendLogIsAlwaysFirst() {
        let (pipeline, classifier, recorder, _) = makePipeline()

        let cases: [(actor: String, paused: Bool)] = [
            ("TeamViewer", true),      // ORG while paused
            ("screensharingd", true),  // REMOTE while paused
            ("Safari", false),         // NORMAL
            ("Safari", true),          // NORMAL while paused
            ("WindowManager", false),  // SYSTEM_NOISE
            ("1Password", false),      // ALLOWLIST
        ]

        for testCase in cases {
            recorder.reset()
            pipeline.setPaused(testCase.paused)

            let rawEvent = raw(actor: testCase.actor)
            pipeline.handle(rawEvent)
            let expected = classifier.classify(rawEvent)

            #expect(recorder.actions.first == .appendLog(expected))
            // Exactly one evidence action per event, whatever the tier.
            #expect(recorder.actions.filter { $0 == .appendLog(expected) }.count == 1)
        }
    }

    // MARK: - Burst performance (Review Focus #5)

    @Test func testBurstKeepsProcessingUnder1s() {
        // Production-classifier cost: the real spec §7 lists, not toy ones,
        // so "10,000 events through `handle`" measures what the app will run.
        let classifier = Classifier(
            org: NoPeekConfig.defaultOrgPatterns,
            noise: NoPeekConfig.defaultSystemNoise,
            allowlist: [],
            remote: NoPeekConfig.defaultRemoteControl
        )

        func event(at i: Int) -> RawEvent {
            let actors = [
                "TeamViewer", "screensharingd", "WindowManager",
                "Safari", "PhotoBooth", "mic",
            ]
            let kinds: [EventKind] = [.screenCapture, .cameraOn, .micOn, .remoteControlProcess]
            return raw(actor: actors[i % actors.count], kind: kinds[i % kinds.count])
        }

        // Expected tier mix, computed once outside the measured loop so the
        // assertions stay exact without paying for a second classification of
        // every event inside the timed section.
        let tiers = (0..<10_000).map { classifier.classify(event(at: $0)).tier }
        let notifyTierCount = tiers.filter { [.org, .remote, .normal].contains($0) }.count
        let expectedBanners = tiers.filter { $0 == .org || $0 == .remote }.count
        #expect(tiers.contains(.org))
        #expect(tiers.contains(.remote))
        #expect(tiers.contains(.normal))
        #expect(tiers.contains(.systemNoise))
        #expect(notifyTierCount < 10_000) // the noise actor really was filtered

        final class Tally {
            var appendLogs = 0
            var notificationActions = 0
            var notifies = 0
            var banners = 0
            var trayUpdates = 0
        }
        let tally = Tally()
        let clock = TestClock()
        let pipeline = Pipeline(
            classifier: classifier,
            throttler: Throttler(window: 60, now: { clock.now }),
            sink: { action in
                switch action {
                case .appendLog: tally.appendLogs += 1
                case .notify:
                    tally.notifies += 1
                    tally.notificationActions += 1
                case .aggregated: tally.notificationActions += 1
                case .banner: tally.banners += 1
                case .trayUpdate: tally.trayUpdates += 1
                }
            },
            remoteBannerEnabled: { true }
        )

        let stopwatch = ContinuousClock()
        let elapsed = stopwatch.measure {
            for i in 0..<10_000 {
                pipeline.handle(event(at: i))
                clock.advance(0.01) // 100 s of events overall
            }
        }

        // Correctness under load: every event was logged exactly once, the
        // notify path produced exactly one action per notifying-tier event,
        // the tray saw exactly those tiers, banners fired for ORG + REMOTE —
        // and the throttler really grouped, i.e. not every notifying event
        // surfaced as `.notify`.
        #expect(tally.appendLogs == 10_000)
        #expect(tally.notificationActions == notifyTierCount)
        #expect(tally.trayUpdates == notifyTierCount)
        #expect(tally.banners == expectedBanners)
        #expect(tally.notifies > 0 && tally.notifies < notifyTierCount)
        // And it stayed well inside the Review Focus #5 budget.
        #expect(elapsed < .seconds(1), "10,000-event burst took \(elapsed)")
    }
}
