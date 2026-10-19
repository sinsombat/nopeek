import Darwin
import Foundation
import Testing

import PWCore

/// Tests for `KillController` (spec §6d, plan T21 — Review Focus #6).
///
/// **No test ever signals a process.** The controller's whole signal surface
/// arrives through the injected `signaller`, and the two clocks
/// (`sleeper` + `now`) are injected too, so the TERM→wait→KILL escalation runs
/// in microseconds with exact, assertable timing. The one real-system test is
/// `KillController.systemName`'s smoke check (it only *reads* the kernel's name
/// for this test runner).
///
/// The pid-reuse guard is the point of the suite: every refusal test asserts
/// not only the outcome but also that the signaller was **never called**.
@Suite struct KillControllerTests {

    // MARK: - Doubles

    /// Records every `kill(2)`-shaped call and answers from a script. Sets
    /// `errno` exactly as `kill(2)` would when it returns −1, which is the
    /// contract `KillController` reads.
    private final class SignallerSpy {
        private(set) var calls: [(pid: Int32, signal: Int32)] = []
        var respond: (Int32, Int32) -> (rc: Int32, errno: Int32) = { _, _ in (0, 0) }

        func signal(_ pid: Int32, _ sig: Int32) -> Int32 {
            calls.append((pid, sig))
            let (rc, e) = respond(pid, sig)
            if rc == -1 { errno = e }
            return rc
        }

        var signals: [Int32] { calls.map(\.signal) }
        var pids: [Int32] { calls.map(\.pid) }
    }

    /// A hand-driven clock: `sleeper` advances it, so "wait up to 3 s" is
    /// asserted, not experienced.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_762_000_000)
        private(set) var slept: TimeInterval = 0

        func sleep(_ interval: TimeInterval) {
            slept += interval
            now = now.addingTimeInterval(interval)
        }
    }

    private func controller(
        spy: SignallerSpy,
        clock: Clock,
        name: @escaping (Int32) -> String? = { _ in "sleep" }
    ) -> KillController {
        KillController(
            signaller: { spy.signal($0, $1) },
            processName: name,
            sleeper: { clock.sleep($0) },
            now: { clock.now }
        )
    }

    // MARK: - Pid-reuse guard (name must match before any signal)

    @Test func testNameMismatchRefusesWithoutSignalling() {
        // The guard is the first thing that happens: a pid that now belongs to
        // another process must not receive even a signal-0 probe from this
        // path.
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock, name: { _ in "Google Chrome" })

        let outcome = controller.kill(pid: 4242, expectedName: "sleep", force: false)

        #expect(outcome == .refusedNameMismatch)
        #expect(spy.calls.isEmpty)
        #expect(clock.slept == 0)
    }

    @Test func testUnresolvableProcessIsNoSuchProcess() {
        // The pid carried no name at all (it is gone): nothing is signalled,
        // and the outcome says why.
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock, name: { _ in nil })

        #expect(controller.kill(pid: 4242, expectedName: "sleep", force: false) == .noSuchProcess)
        #expect(spy.calls.isEmpty)
    }

    @Test func testTheGuardRunsAgainBeforeTheEscalationSignal() {
        // The pid can be recycled *while* we wait out the 3 s: the second
        // signal gets its own name check, and a mismatch there must refuse
        // rather than SIGKILL a stranger.
        let spy = SignallerSpy()
        let clock = Clock()
        var nameReads = 0
        let controller = controller(spy: spy, clock: clock) { _ in
            nameReads += 1
            // First read: the process we mean. Every later read: someone else.
            return nameReads == 1 ? "sleep" : "recycled"
        }
        spy.respond = { _, _ in (0, 0) } // alive and signalable throughout

        let outcome = controller.kill(pid: 4242, expectedName: "sleep", force: false)

        #expect(outcome == .refusedNameMismatch)
        #expect(spy.signals.first == SIGTERM)
        #expect(!spy.signals.contains(SIGKILL)) // the second guard refused first
        #expect(clock.slept == 3) // the full wait happened, then the guard said no
        #expect(nameReads == 2)
    }

    @Test func testForceStillRefusesOnNameMismatch() {
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock, name: { _ in "recycled" })

        #expect(controller.kill(pid: 4242, expectedName: "sleep", force: true) == .refusedNameMismatch)
        #expect(spy.calls.isEmpty)
    }

    @Test func testNonPositivePidsAreRefusedBeforeAnythingElse() {
        // `kill(0, …)` means "my whole process group" and `kill(-1, …)`
        // "everything I may signal" — neither is a process an event can name,
        // so no name lookup and no signal may happen for them.
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock)

        #expect(controller.kill(pid: 0, expectedName: "kernel_task", force: false) == .failed(errno: EINVAL))
        #expect(controller.kill(pid: -1, expectedName: "sleep", force: true) == .failed(errno: EINVAL))
        #expect(spy.calls.isEmpty)
    }

    // MARK: - Signal outcomes

    @Test func testPermissionDeniedIsNoPermission() {
        // EPERM on SIGTERM: the process is someone else's (root), which is
        // exactly the case the app offers the macOS admin prompt for.
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock, name: { _ in "launchd" })
        spy.respond = { _, _ in (-1, EPERM) }

        #expect(controller.kill(pid: 1, expectedName: "launchd", force: false) == .noPermission)
        #expect(spy.calls.map(\.signal) == [SIGTERM])
        #expect(clock.slept == 0) // no point waiting after a refusal
    }

    @Test func testGoneProcessIsNoSuchProcess() {
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock)
        spy.respond = { _, _ in (-1, ESRCH) }

        #expect(controller.kill(pid: 4242, expectedName: "sleep", force: false) == .noSuchProcess)
        #expect(spy.calls.map(\.signal) == [SIGTERM])
    }

    @Test func testUnexpectedErrnoIsFailedWithTheErrno() {
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock)
        spy.respond = { _, _ in (-1, EIO) }

        #expect(controller.kill(pid: 4242, expectedName: "sleep", force: false) == .failed(errno: EIO))
    }

    // MARK: - TERM → wait → KILL

    @Test func testTerminatedBySigtermWhenTheProcessDies() {
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock)
        // SIGTERM is delivered; the first aliveness check finds it gone.
        spy.respond = { _, sig in
            if sig == 0 { return (-1, ESRCH) }
            return (0, 0)
        }

        let outcome = controller.kill(pid: 4242, expectedName: "sleep", force: false)

        #expect(outcome == .terminated(signal: SIGTERM))
        #expect(spy.calls.map(\.signal) == [SIGTERM, 0])
        #expect(clock.slept > 0)
        #expect(clock.slept <= 3)
    }

    @Test func testEscalatesToSigkillWhenTheProcessSurvivesTheWait() {
        // The pinned escalation: SIGTERM → wait up to 3 s → SIGKILL. The wait
        // is driven by the injected sleeper, and the poll budget is asserted
        // exactly (24 × 0.125 s).
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock)
        spy.respond = { _, _ in (0, 0) } // alive and signalable throughout

        let outcome = controller.kill(pid: 4242, expectedName: "sleep", force: false)

        #expect(outcome == .escalated)
        #expect(spy.signals.first == SIGTERM)
        #expect(spy.signals.last == SIGKILL)
        #expect(spy.signals.filter { $0 == SIGKILL }.count == 1)
        #expect(spy.signals.filter { $0 == SIGTERM }.count == 1)
        #expect(clock.slept == 3)
    }

    @Test func testEscalationReportsErrnoWhenTheSigkillIsRefused() {
        // The process changed owner during the wait (unlikely, but the map must
        // not lie): the SIGKILL's EPERM is reported as EPERM.
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock)
        spy.respond = { _, sig in
            sig == SIGKILL ? (-1, EPERM) : (0, 0)
        }

        #expect(controller.kill(pid: 4242, expectedName: "sleep", force: false) == .noPermission)
        #expect(spy.signals.last == SIGKILL)
    }

    @Test func testForceSendsSigkillImmediately() {
        let spy = SignallerSpy()
        let clock = Clock()
        let controller = controller(spy: spy, clock: clock)

        let outcome = controller.kill(pid: 4242, expectedName: "sleep", force: true)

        #expect(outcome == .terminated(signal: SIGKILL))
        #expect(spy.calls.map(\.signal) == [SIGKILL])
        #expect(clock.slept == 0) // force means no wait at all
    }

    // MARK: - Names

    @Test func testSignalNameSpelling() {
        #expect(KillController.signalName(SIGTERM) == "SIGTERM")
        #expect(KillController.signalName(SIGKILL) == "SIGKILL")
        #expect(KillController.signalName(2) == "signal 2")
    }

    // MARK: - The guard as a question (the elevated-kill path)

    @Test func testGuardPassesAnswersForEveryPidState() {
        // `KillController.guardPasses` is the pid-reuse guard for the **root**
        // signal (`AdminKiller`'s `kill(1)` after the admin prompt), which never
        // travels through `kill(pid:expectedName:force:)`. Same rule, same
        // answer table — and a query, so there is no signaller to spy on.
        #expect(KillController.guardPasses(pid: 4242, expectedName: "sleep", processName: { _ in "sleep" }))
        #expect(!KillController.guardPasses(pid: 4242, expectedName: "sleep", processName: { _ in "recycled" }))
        #expect(!KillController.guardPasses(pid: 4242, expectedName: "sleep", processName: { _ in nil }))
        #expect(!KillController.guardPasses(pid: 4242, expectedName: "sleep", processName: { _ in "" }))
        // No pid at all is never a passing guard, whatever the name source says.
        #expect(!KillController.guardPasses(pid: 0, expectedName: "kernel_task", processName: { _ in "kernel_task" }))
        #expect(!KillController.guardPasses(pid: -1, expectedName: "sleep", processName: { _ in "sleep" }))
    }

    @Test func testGuardPassesAgainstThisMachine() {
        // The real name source, read-only: this runner passes its own guard,
        // and asks for nothing that is not this process.
        let mine = KillController.systemName(getpid())
        #expect(mine != nil)
        #expect(KillController.guardPasses(pid: getpid(), expectedName: mine ?? ""))
        #expect(!KillController.guardPasses(pid: getpid(), expectedName: "some-other-process"))
        // A root process answers `true` for its real name (what acceptance 16
        // needs) and `false` for anything else.
        #expect(KillController.guardPasses(pid: 1, expectedName: "launchd"))
        #expect(!KillController.guardPasses(pid: 1, expectedName: "sleep"))
    }

    @Test func testSmokeSystemNameReadsThisRunner() {
        // The real `p_comm` source (the same field `ProcessWatch` reports as an
        // event's actor). Read-only, and the only real-machine call in the
        // suite.
        let name = KillController.systemName(getpid())
        #expect(name != nil)
        #expect(name?.isEmpty == false)
        #expect(KillController.systemName(999_999) == nil) // no such pid
        print("KillController smoke — pid \(getpid()) → \(name ?? "nil")")
    }

    @Test func testSmokeSystemNameReadsARootProcess() {
        // pid 1 belongs to root, is signalable by nobody but root — and its
        // name is still readable, which is what lets the guard pass and the
        // EPERM path (acceptance 16) be reached at all.
        #expect(KillController.systemName(1) == "launchd")
    }

    // MARK: - Row action availability (spec §6)

    private func event(
        tier: Tier,
        actor: String = "screensharingd",
        path: String? = nil,
        pid: Int32? = nil
    ) -> ClassifiedEvent {
        ClassifiedEvent(
            event: RawEvent(
                ts: Date(timeIntervalSince1970: 1_762_000_000),
                source: .processwatch,
                kind: .remoteControlProcess,
                actor: actor,
                actorPath: path,
                pid: pid
            ),
            tier: tier,
            reason: "default"
        )
    }

    @Test func testKillIsOfferedForRemoteAndOrgRowsWithAPid() {
        #expect(event(tier: .remote, pid: 4242).offersKillAction)
        #expect(event(tier: .org, pid: 4242).offersKillAction)

        // No pid → nothing to signal; NORMAL/ALLOWLIST rows are not kill rows
        // (spec §6 lists REMOTE/ORG only).
        #expect(!event(tier: .remote).offersKillAction)
        #expect(!event(tier: .normal, pid: 4242).offersKillAction)
        #expect(!event(tier: .allowlist, pid: 4242).offersKillAction)
        #expect(!event(tier: .systemNoise, pid: 4242).offersKillAction)
    }

    @Test func testNoPeekNeverOffersToKillItself() {
        // The app can be matched by name like any other process; the row must
        // not offer what the flow refuses.
        let selfTarget = KillTarget(actor: "NoPeek", pid: getpid())
        #expect(!selfTarget.isKillable)
        #expect(!event(tier: .remote, actor: "NoPeek", pid: getpid()).offersKillAction)
        #expect(KillTarget(actor: "sleep").isKillable == false) // no pid
        #expect(KillTarget(actor: "sleep", pid: -5).isKillable == false)
        #expect(KillTarget(actor: "sleep", pid: 4242).isKillable)
    }

    @Test func testLocationIsOfferedForRowsWithAPathOrPid() {
        #expect(event(tier: .normal, path: "/usr/sbin/screencapture").offersLocationAction)
        #expect(event(tier: .normal, pid: 4242).offersLocationAction)
        #expect(event(tier: .normal, path: "", pid: 4242).offersLocationAction)
        #expect(!event(tier: .normal, path: "").offersLocationAction)
        #expect(!event(tier: .normal).offersLocationAction)
    }

    @Test func testKillTargetCarriesTheEventIdentity() {
        let target = KillTarget(event(tier: .remote, actor: "AnyDesk", path: "/Applications/AnyDesk.app/Contents/MacOS/AnyDesk", pid: 9))
        #expect(target == KillTarget(
            actor: "AnyDesk",
            actorPath: "/Applications/AnyDesk.app/Contents/MacOS/AnyDesk",
            pid: 9
        ))
    }
}
