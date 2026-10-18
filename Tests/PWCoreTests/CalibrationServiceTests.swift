import Foundation
import Testing

import PWCore

/// Tests for `CalibrationService` (plan T18; spec §6 `Calibration Wizard…`,
/// acceptance 12).
///
/// The service is the wizard's state machine and nothing else: it walks
/// `CalibrationStep.allCases` in order, passes a step on the one event kind
/// that proves that detector works on this machine, and resolves a step as
/// `.timedOut` when its own window elapses. The clock is injected, so every
/// test drives time by hand — no wall-clock waiting, no real capture, camera or
/// microphone, and no TCC-protected API anywhere.
///
/// Two rules are worth naming up front:
///
/// - **R16:** a `.screenCapture` event whose actor is `WindowManager` — Mission
///   Control's signal (ruling R14) — never satisfies the screen step. Only a
///   real capture, the user's explicit ⌘⇧5, does.
/// - **Timeouts advance the run.** A step that runs out of time is recorded
///   `.timedOut` and the next detector gets its own window, so all three steps
///   always end up in the summary (acceptance 12 wants three verdicts, not a
///   run that stopped at the first problem). Cancelling, by contrast, ends the
///   run with a `.failed(reason:)` on the step in flight and is never announced
///   as a completion — an abandoned run is not persisted.
@Suite struct CalibrationServiceTests {

    // MARK: - Helpers

    /// The hand-held clock's start. On the millisecond grid on purpose: the
    /// summary's `date` travels through the same ISO8601 coding as every other
    /// timestamp on disk (spec §8), and the round-trip test pins that it comes
    /// back exactly.
    private static let t0 = Date(timeIntervalSince1970: 1_762_000_000.25)

    /// The pinned per-step window (spec: 60 s per detector).
    private static let timeout: TimeInterval = 60

    /// A clock the tests advance by hand.
    private final class Clock {
        var now: Date

        init(_ start: Date = CalibrationServiceTests.t0) {
            self.now = start
        }

        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    private func service(
        clock: Clock,
        timeout: TimeInterval = CalibrationServiceTests.timeout
    ) -> CalibrationService {
        CalibrationService(timeout: timeout, now: { clock.now })
    }

    private func event(
        _ kind: EventKind,
        actor: String = "screencaptureui",
        source: EventSource = .logstream
    ) -> RawEvent {
        RawEvent(ts: Self.t0, source: source, kind: kind, actor: actor)
    }

    /// A real ⌘⇧5: the log stream reports it with actor `screencaptureui`
    /// (with `replayd` / `screencapture` lines beside it — R15).
    private func capture(actor: String = "screencaptureui") -> RawEvent {
        event(.screenCapture, actor: actor)
    }

    /// Mission Control's `.screenCapture` echo (R14) — must never count (R16).
    private func missionControl() -> RawEvent {
        capture(actor: "WindowManager")
    }

    private func cameraOn() -> RawEvent {
        event(.cameraOn, actor: "Photo Booth")
    }

    /// The mic watch's shape (T15): source `.mic`, actor `mic`.
    private func micOn() -> RawEvent {
        event(.micOn, actor: "mic", source: .mic)
    }

    /// Passes the screen step so the next assertion can talk about camera.
    private func passScreen(_ service: CalibrationService) {
        service.ingest(capture())
    }

    /// Runs screen → camera → mic to completion.
    private func passAll(_ service: CalibrationService) {
        passScreen(service)
        service.ingest(cameraOn())
        service.ingest(micOn())
    }

    /// A `calibration.json` path inside a directory that does not exist yet —
    /// the production parent (`~/Library/Application Support/NoPeek/`) may not
    /// exist on a fresh Mac, so `persist` has to create it.
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nopeek-calibration-\(UUID().uuidString)")
            .appendingPathComponent("calibration.json")
    }

    // MARK: - Step order

    @Test func testStepOrderIsScreenCameraMic() {
        // The pinned order: the wizard walks the detectors in the order their
        // instructions make sense (capture → camera → mic) and the summary is
        // read in the same order.
        #expect(CalibrationStep.allCases == [.screen, .camera, .mic])
    }

    @Test func testTimeoutDefaultIsSixtySeconds() {
        // Spec: 60 s per detector. Pinned so a change to the production
        // default surfaces here, not in a wizard that quietly gives up sooner.
        #expect(CalibrationService().timeout == 60)
    }

    // MARK: - Pass rules

    @Test func testScreenPassesOnCaptureEvent() {
        // Every capture actor the log stream really produces passes the screen
        // step: `screencaptureui` (⌘⇧5's UI process), `replayd` (R15's session
        // line) and `screencapture` are all real captures. The actor travels
        // into the result so the wizard can name who captured.
        for actor in ["screencaptureui", "replayd", "screencapture"] {
            let clock = Clock()
            let service = self.service(clock: clock)
            service.start()

            service.ingest(capture(actor: actor))

            #expect(service.summary().results[.screen] == .passed(actor: actor))
            #expect(service.status().currentStep == .camera)
        }
    }

    @Test func testScreenIgnoresWindowManagerActor() {
        // R16: Mission Control logs `.screenCapture` too (R14 — the WM's
        // "Change expose mode" line), so a kind-only check would let a Mission
        // Control gesture "prove" screen capture detection. The actor check is
        // what forces the explicit ⌘⇧5 the wizard asks for.
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()

        service.ingest(missionControl())

        #expect(service.status().currentStep == .screen)      // still waiting
        #expect(service.summary().results.isEmpty)

        // …and the real capture still passes right after the noise.
        passScreen(service)
        #expect(service.summary().results[.screen] == .passed(actor: "screencaptureui"))
    }

    @Test func testCameraPassesOnCameraOn() {
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        passScreen(service)

        service.ingest(cameraOn())

        #expect(service.summary().results[.camera] == .passed(actor: "Photo Booth"))
        #expect(service.status().currentStep == .mic)
    }

    @Test func testMicPassesOnMicOn() {
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        passScreen(service)
        service.ingest(cameraOn())

        service.ingest(micOn())

        let status = service.status()
        #expect(status.results[.mic] == .passed(actor: "mic"))
        #expect(status.currentStep == nil)
        #expect(status.isRunning == false)
    }

    // MARK: - Step order progression

    @Test func testStepOrderProgression() {
        // One step at a time, in order: an event that belongs to a later step
        // is ignored while an earlier step is still waiting (the wizard's
        // instructions are sequential — a camera that was already open when
        // step 1 was up must not count as step 2's proof).
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()

        service.ingest(cameraOn())
        service.ingest(micOn())
        #expect(service.status().currentStep == .screen)

        passScreen(service)
        #expect(service.status().currentStep == .camera)
        service.ingest(micOn())                               // too early
        #expect(service.status().currentStep == .camera)

        service.ingest(cameraOn())
        #expect(service.status().currentStep == .mic)

        service.ingest(micOn())
        let status = service.status()
        #expect(status.isRunning == false)
        #expect(status.currentStep == nil)

        let summary = service.summary()
        #expect(summary.results == [
            .screen: .passed(actor: "screencaptureui"),
            .camera: .passed(actor: "Photo Booth"),
            .mic: .passed(actor: "mic"),
        ])
        #expect(summary.isComplete)
        #expect(summary.allPassed)
    }

    // MARK: - Timeouts

    @Test func testTimeoutFailsStep() {
        // Each step has its own 60 s window, counted from the moment that step
        // became current. A step whose window elapses is recorded `.timedOut`
        // and the run moves on — the summary always holds one verdict per
        // detector (acceptance 12).
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()

        // 59 s in: still inside the screen step's window.
        clock.advance(59)
        #expect(service.status().results.isEmpty)
        #expect(service.status().currentStep == .screen)
        #expect(service.status().remaining == 1)

        // At exactly 60 s the window is over — the boundary is the window, not
        // a grace period. The camera step then gets a fresh 60 s of its own.
        clock.advance(1)
        let afterScreen = service.status()
        #expect(afterScreen.results[.screen] == .timedOut)
        #expect(afterScreen.currentStep == .camera)
        #expect(afterScreen.isRunning)
        #expect(afterScreen.remaining == CalibrationServiceTests.timeout)

        // A late event inside the new window still counts: timing out advances
        // the run, it does not end it.
        clock.advance(30)
        service.ingest(cameraOn())
        #expect(service.summary().results[.camera] == .passed(actor: "Photo Booth"))
        #expect(service.status().currentStep == .mic)

        // The last step can time out too; the run then completes with all
        // three results on record.
        clock.advance(60)
        let finished = service.status()
        #expect(finished.results == [
            .screen: .timedOut,
            .camera: .passed(actor: "Photo Booth"),
            .mic: .timedOut,
        ])
        #expect(finished.isRunning == false)
        #expect(finished.currentStep == nil)
        #expect(finished.remaining == nil)
    }

    @Test func testUninterruptedRunTimesOutAllThreeSteps() {
        // Nobody interacts: consulting the status once, long after the fact,
        // resolves every elapsed window in one go (the steps' windows are
        // chained from the deadlines, not from when someone looked).
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()

        clock.advance(3 * CalibrationServiceTests.timeout)

        let status = service.status()
        #expect(status.results.count == 3)
        #expect(CalibrationStep.allCases.allSatisfy { status.results[$0] == .timedOut })
        #expect(status.isRunning == false)
        #expect(service.summary().allPassed == false)
    }

    // MARK: - Unrelated events

    @Test func testIgnoresUnrelatedEvents() {
        // Everything NoPeek sees that is not the step's proof is ignored — no
        // advancing, no results, no state change. `.cameraOff` / `.micOff` are
        // in here on purpose (R20): the end of an observation is not a new one.
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()

        service.ingest(event(.screenCaptureApproval, actor: "ScreenCaptureApprovalUI"))
        service.ingest(event(.remoteControlProcess, actor: "screensharingd"))
        service.ingest(event(.remoteControlSession, actor: "screensharingd"))
        service.ingest(event(.monitorStarted, actor: "nopeek", source: .system))
        service.ingest(cameraOn())
        service.ingest(micOn())
        service.ingest(event(.cameraOff, actor: "Photo Booth"))
        service.ingest(event(.micOff, actor: "mic", source: .mic))

        #expect(service.status().currentStep == .screen)
        #expect(service.summary().results.isEmpty)

        // Same discipline once the camera step is current: an off-event never
        // satisfies its detector, and a capture event is behind us.
        passScreen(service)
        service.ingest(event(.cameraOff, actor: "Photo Booth"))
        service.ingest(capture(actor: "replayd"))
        service.ingest(event(.micOff, actor: "mic", source: .mic))

        #expect(service.status().currentStep == .camera)
        #expect(service.summary().results.count == 1)

        // And the mic step ignores a camera event.
        service.ingest(cameraOn())
        service.ingest(event(.micOff, actor: "mic", source: .mic))
        #expect(service.status().currentStep == .mic)

        service.ingest(micOn())
        #expect(service.summary().allPassed)
    }

    // MARK: - Life cycle

    @Test func testStartClearsAPreviousRun() {
        // `start()` is the menu's re-run: a second run is a fresh story, not a
        // continuation of the first one's results.
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        service.ingest(capture())

        service.start()

        let status = service.status()
        #expect(status.results.isEmpty)
        #expect(status.currentStep == .screen)
        #expect(status.isRunning)

        // The old run's screen event cannot be reused for the new one.
        service.ingest(capture(actor: "replayd"))
        #expect(service.summary().results[.screen] == .passed(actor: "replayd"))
    }

    @Test func testIngestAfterCompletionIsIgnored() {
        // Once the run is over its verdicts are frozen: nothing that arrives
        // later can rewrite them.
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        passAll(service)

        let summary = service.summary()
        service.ingest(capture())
        service.ingest(cameraOn())
        service.ingest(micOn())

        #expect(service.summary() == summary)
        #expect(service.status().currentStep == nil)
    }

    @Test func testCancelEndsTheRunWithAFailedStep() {
        // The user closed the wizard's window: the run stops, the step that
        // was in flight reads as `.failed(reason:)`, and the app is not told
        // the run completed — an abandoned run is never persisted.
        let clock = Clock()
        let service = self.service(clock: clock)
        var completions: [CalibrationSummary] = []
        service.onComplete = { completions.append($0) }

        service.start()
        passScreen(service)
        service.cancel()

        let status = service.status()
        #expect(status.isRunning == false)
        #expect(status.currentStep == nil)
        #expect(status.results[.screen] == .passed(actor: "screencaptureui"))
        #expect(status.results[.camera] == .failed(reason: "cancelled"))
        #expect(completions.isEmpty)
    }

    @Test func testOnCompleteFiresOnceWithTheFullSummary() {
        // The app persists and logs exactly once, when the last step resolves
        // — that is what the wizard's `calibration-result` evidence line and
        // `calibration.json` hang off.
        let clock = Clock()
        let service = self.service(clock: clock)
        var completions: [CalibrationSummary] = []
        service.onComplete = { completions.append($0) }

        service.start()
        service.ingest(capture())
        service.ingest(cameraOn())
        #expect(completions.isEmpty)                       // mic still waiting

        service.ingest(micOn())
        #expect(completions.count == 1)
        #expect(completions.first?.allPassed == true)
        #expect(completions.first?.results.count == 3)

        // Later events do not re-announce it.
        service.ingest(capture())
        #expect(completions.count == 1)
    }

    @Test func testTimeoutsAnnounceCompletionAsWell() {
        // A run that failed every step is still *complete*: the wizard says so
        // on screen and the app persists the verdict (acceptance 12's file is
        // the record of what happened, good or bad).
        let clock = Clock()
        let service = self.service(clock: clock)
        var completions: [CalibrationSummary] = []
        service.onComplete = { completions.append($0) }

        service.start()
        clock.advance(3 * CalibrationServiceTests.timeout)
        _ = service.status()

        #expect(completions.count == 1)
        #expect(completions.first?.isComplete == true)
        #expect(completions.first?.allPassed == false)
    }

    // MARK: - Persistence

    @Test func testAllStepsSummaryRoundTrip() throws {
        // Acceptance 12: a completed run lands in `calibration.json` and reads
        // back unchanged. `persist` creates the directory (the production path
        // may not exist yet) and `load` returns exactly what was written.
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        passAll(service)

        let summary = service.summary()
        #expect(summary.date == Self.t0)                   // dated by the run
        #expect(summary.isComplete)
        #expect(summary.allPassed)

        let url = temporaryURL()
        try service.persist(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let loaded = try CalibrationService.load(from: url)
        #expect(loaded == summary)
    }

    @Test func testEveryResultKindRoundTripsThroughDisk() throws {
        // All three `StepResult` shapes survive the file: passed (with actor),
        // timed out (no payload), failed (with reason).
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        service.ingest(capture())                          // screen: passed
        clock.advance(Self.timeout)
        #expect(service.status().currentStep == .mic)       // camera: timed out
        service.cancel()                                   // mic: failed

        let summary = service.summary()
        #expect(summary.results == [
            .screen: .passed(actor: "screencaptureui"),
            .camera: .timedOut,
            .mic: .failed(reason: "cancelled"),
        ])

        let url = temporaryURL()
        try service.persist(summary, to: url)
        #expect(try CalibrationService.load(from: url) == summary)
    }

    @Test func testSummaryFileShapeIsReadableAndInStepOrder() throws {
        // The spec §9 state file is a user-facing record, so its shape is
        // pinned like the evidence log's: an ISO8601 date and one flat object
        // per step, in `CalibrationStep` order — readable with `jq`, and
        // stable for anything that reads it later.
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        passAll(service)

        let url = temporaryURL()
        try service.persist(to: url)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )

        let date = try #require(object["date"] as? String)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(parser.date(from: date) != nil, "date is not an ISO8601 string: \(date)")

        let results = try #require(object["results"] as? [[String: Any]])
        #expect(results.map { $0["step"] as? String } == ["screen", "camera", "mic"])
        #expect(results.allSatisfy { $0["status"] as? String == "passed" })
        #expect(results[0]["actor"] as? String == "screencaptureui")
        #expect(results[1]["actor"] as? String == "Photo Booth")
        #expect(results[2]["actor"] as? String == "mic")
    }

    @Test func testLoadReturnsNilWhenTheFileIsMissing() throws {
        // "No calibration yet" is the normal first-launch state, not an error:
        // the app's auto-start gate reads `nil` and runs the wizard.
        #expect(try CalibrationService.load(from: temporaryURL()) == nil)
    }

    @Test func testLoadThrowsOnACorruptFile() throws {
        // A file that is not a summary must be loud, not silently treated as a
        // completed calibration.
        let url = temporaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not a summary".utf8).write(to: url)

        var threw = false
        do {
            _ = try CalibrationService.load(from: url)
        } catch {
            threw = true
        }
        #expect(threw)
    }

    // MARK: - Threading (smoke)

    @Test func testConcurrentIngestAndStatusReadsStayConsistent() async {
        // The app's shape: `ingest` is called on the log reader's serial queue
        // while the wizard window polls `status()` from the main thread. This
        // is not a race detector — it is a smoke test that the service
        // serializes both sides without trapping or losing the step it was on.
        let clock = Clock()
        let service = self.service(clock: clock)
        service.start()
        let capture = self.capture()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<200 { service.ingest(capture) }
            }
            group.addTask {
                for _ in 0..<200 { _ = service.status() }
            }
        }

        let status = service.status()
        #expect(status.results[.screen] == .passed(actor: "screencaptureui"))
        #expect(status.currentStep == .camera)
    }
}
