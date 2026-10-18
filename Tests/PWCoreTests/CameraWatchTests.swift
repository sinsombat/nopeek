import Foundation
import Testing

import PWCore

/// Tests for `CameraWatch` (spec §4-D: "กล้องถูกใช้" — camera in use).
///
/// Every behavioural test drives the watch with a **hand-held camera state**
/// (the injected `inUse` closure) and a **hand-held clock** (the injected
/// `now` closure), so the two things that decide the emissions — the on/off
/// edge and the off-debounce — are set by the test and never by wall-clock
/// time or by the real camera.
///
/// The one test that touches the real machine is
/// `testSmokeDefaultProbeAnswersInsteadOfTrapping`: it drives the pinned
/// default (`CameraWatch.systemInUse`, the AVFoundation device probe) through
/// the public API, without asserting the value — that value is machine state
/// (a camera in use elsewhere legitimately makes it `true`) and the production
/// half of it is the human check of plan T14 step 5.
@Suite struct CameraWatchTests {

    // MARK: - Helpers

    /// The clock the watch reads; the tests advance it explicitly.
    private static let t0 = Date(timeIntervalSince1970: 1_762_000_000)

    /// The pinned off-debounce (spec §3: 5 s), spelled once so a change to the
    /// default surfaces in every test that reasons about the window.
    private static let debounce: TimeInterval = 5

    /// A hand-held camera: tests flip `inUse` between ticks to simulate an app
    /// starting and stopping the camera.
    private final class Camera {
        var inUse: Bool

        init(_ inUse: Bool = false) {
            self.inUse = inUse
        }
    }

    /// A hand-held clock, advanced by the tests in the same steps a 2 s timer
    /// would take it.
    private final class Clock {
        var now: Date

        init(_ start: Date = CameraWatchTests.t0) {
            self.now = start
        }

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    private func watch(_ camera: Camera, _ clock: Clock) -> CameraWatch {
        CameraWatch(
            inUse: { camera.inUse },
            now: { clock.now }
        )
    }

    /// One poll followed by the wait until the next one — what the app's timer
    /// does around `tick()`.
    private func tick(_ watch: CameraWatch, _ clock: Clock) -> RawEvent? {
        let event = watch.tick()
        clock.advance(watch.interval)
        return event
    }

    /// The emitted kinds of a run of ticks, with `nil` for the silent ones.
    private func kinds(_ events: [RawEvent?]) -> [EventKind?] {
        events.map { $0?.kind }
    }

    // MARK: - On edge

    @Test func testOnEdgeEmitsOnce() {
        // Spec §3/plan T14: an edge, never a level. A camera that stays in use
        // across ticks is not news: three ticks of `true`, exactly one event,
        // on the first of them.
        let camera = Camera(true)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        let events = [tick(watch, clock), tick(watch, clock), tick(watch, clock)]

        #expect(kinds(events) == [.cameraOn, nil, nil])
    }

    @Test func testSecondSpellEmitsOnEdgeAgain() {
        // Start the camera again after it was reported off: that is a second
        // appearance, not a repeat of the first one.
        let camera = Camera(true)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        #expect(tick(watch, clock)?.kind == .cameraOn)

        camera.inUse = false
        _ = tick(watch, clock)                       // off observed, debounce armed
        clock.advance(CameraWatchTests.debounce)     // …now past the window
        #expect(tick(watch, clock)?.kind == .cameraOff)

        camera.inUse = true
        #expect(tick(watch, clock)?.kind == .cameraOn)
        #expect(tick(watch, clock) == nil)
    }

    // MARK: - Off debounce

    @Test func testOffDebounce() {
        // `false` for less than the 5 s debounce, then `true` again: one
        // continuous usage spell. No `cameraOff` — and no second `cameraOn`
        // either, because from the watch's point of view nothing ended.
        let camera = Camera(true)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        #expect(tick(watch, clock)?.kind == .cameraOn)

        camera.inUse = false
        let firstOffTick = tick(watch, clock)
        let secondOffTick = tick(watch, clock)       // 4 s of observed idle total

        camera.inUse = true
        let backOnTick = tick(watch, clock)

        #expect(firstOffTick == nil)
        #expect(secondOffTick == nil)
        #expect(backOnTick == nil)
    }

    @Test func testOffAfterDebounce() {
        // `false` and staying `false` past the window: exactly one `cameraOff`,
        // on the first tick past it, then silence.
        let camera = Camera(true)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        #expect(tick(watch, clock)?.kind == .cameraOn)

        camera.inUse = false
        let events = [
            tick(watch, clock),   // 2 s observed idle — debounce armed here
            tick(watch, clock),   // 4 s
            tick(watch, clock),   // 6 s
            tick(watch, clock),   // 8 s — first tick past the window
            tick(watch, clock),   // already reported
        ]

        #expect(kinds(events) == [nil, nil, nil, .cameraOff, nil])
    }

    @Test func testOffDebounceIsStrictlyMoreThanTheWindow() {
        // The rule reads "continuously false for **more than** offDebounce":
        // exactly 5 s of observed idle is not enough, the tick after it is.
        let camera = Camera(true)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        #expect(watch.tick()?.kind == .cameraOn)     // t0

        camera.inUse = false
        clock.advance(2)
        #expect(watch.tick() == nil)                 // t0+2: off observed
        clock.advance(CameraWatchTests.debounce)     // t0+7: exactly 5 s idle

        #expect(watch.tick() == nil)

        clock.advance(0.001)                         // t0+7.001: just past it
        #expect(watch.tick()?.kind == .cameraOff)
    }

    // MARK: - Idle

    @Test func testNoEventWhenIdle() {
        // A camera that is never in use is never news — not at boot, not after
        // a minute of polling.
        let camera = Camera(false)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        let events = (0..<30).map { _ in tick(watch, clock) }

        #expect(events.allSatisfy { $0 == nil })
    }

    // MARK: - Emitted events

    @Test func testOnEventShape() {
        // The full `RawEvent` is pinned literally: the camera tier has no app
        // attribution in v1 (the log-stream predicate carries no camera lines —
        // see the report), so the actor is the literal "camera", there is no
        // path and no pid, and `ts` comes from the tick's injected clock.
        let camera = Camera(true)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        #expect(
            watch.tick() == RawEvent(
                ts: Self.t0,
                source: .camera,
                kind: .cameraOn,
                actor: "camera",
                rawSummary: "กล้องถูกใช้ (poll)"
            )
        )
    }

    @Test func testOffEventShape() {
        let camera = Camera(true)
        let clock = Clock()
        let watch = self.watch(camera, clock)

        #expect(watch.tick()?.kind == .cameraOn)     // t0
        camera.inUse = false

        // The 2 s cadence: off observed at t0+2, and the first tick that is
        // strictly past the 5 s window is t0+8 (6 s of observed idle).
        clock.advance(2)
        #expect(watch.tick() == nil)                 // t0+2
        clock.advance(2)
        #expect(watch.tick() == nil)                 // t0+4
        clock.advance(2)
        #expect(watch.tick() == nil)                 // t0+6
        clock.advance(2)

        #expect(
            watch.tick() == RawEvent(                // t0+8
                ts: Self.t0.addingTimeInterval(2 + CameraWatchTests.debounce + 1),
                source: .camera,
                kind: .cameraOff,
                actor: "camera",
                rawSummary: "กล้องว่างแล้ว"
            )
        )
    }

    // MARK: - Configuration

    @Test func testIntervalIsExposedForTheAppTimer() {
        // The watch does not own a timer — the app does — and it carries the
        // cadence so the two cannot drift apart: the pinned default is 2 s.
        #expect(CameraWatch(inUse: { false }).interval == 2)
        #expect(CameraWatch(interval: 7, inUse: { false }).interval == 7)
    }

    // MARK: - Real device probe (smoke)

    @Test func testSmokeDefaultProbeAnswersInsteadOfTrapping() {
        // Drives the pinned default (`CameraWatch.systemInUse` — the
        // AVFoundation device probe, no TCC permission and no prompt) through
        // the public API on the real machine. The *value* is not asserted: it
        // is machine state, true whenever another app is using the camera. What
        // this pins is that the probe answers, and that a camera that happens to
        // be in use is reported with the same shape as any other `cameraOn`.
        let watch = CameraWatch(now: { Self.t0 })

        if let event = watch.tick() {
            #expect(event == RawEvent(
                ts: Self.t0,
                source: .camera,
                kind: .cameraOn,
                actor: "camera",
                rawSummary: "กล้องถูกใช้ (poll)"
            ))
        }
    }
}
