import Darwin
import Foundation
import Testing

import PWCore

/// Tests for `ProcessWatch` (spec §4-B: remote-control processes) and
/// `SystemProcesses` (spec §3: sysctl `KERN_PROC_ALL` + `proc_pidpath`).
///
/// Every behavioural test drives the watch with a **fixed fixture** through
/// the injected `lister` — no test depends on a real process existing, and the
/// edge-trigger rules are pinned by literal tick sequences. The one exception
/// is `testSmokeListsSelf`, which asks the real sysctl table for exactly two
/// things: there are a lot of processes, and one of them is this test runner
/// (matched by pid, never by name — the runner's process name is a toolchain
/// detail).
@Suite struct ProcessWatchTests {

    // MARK: - Helpers

    /// The clock the watch reads; fixed so the emitted `ts` is pinned.
    private static let fixedNow = Date(timeIntervalSince1970: 1_762_000_000)

    /// A hand-held process table: tests mutate `procs` between ticks to
    /// simulate processes appearing and disappearing.
    private final class Listing {
        var procs: [ProcInfo]

        init(_ procs: [ProcInfo] = []) {
            self.procs = procs
        }
    }

    private func proc(_ pid: Int32, _ name: String, _ path: String? = nil) -> ProcInfo {
        ProcInfo(pid: pid, name: name, path: path)
    }

    private func watch(
        names: @escaping () -> [String],
        listing: Listing
    ) -> ProcessWatch {
        ProcessWatch(
            names: names,
            lister: { listing.procs },
            now: { Self.fixedNow }
        )
    }

    // MARK: - Edge trigger

    @Test func testEdgeTriggerEmitsOnce() {
        // Spec §3/plan T13: one appearance is one event. A process that stays
        // present across ticks is not news — three identical listings, one
        // emission, on the first tick.
        let listing = Listing([proc(501, "screensharingd", "/System/Library/CoreServices/RemoteManagement/screensharingd")])
        let watch = watch(names: { ["screensharingd"] }, listing: listing)

        #expect(watch.tick().count == 1)
        #expect(watch.tick().isEmpty)
        #expect(watch.tick().isEmpty)
    }

    @Test func testReappearAfterGoneEmitsAgain() {
        // Gone and back is a second appearance: kill + relaunch / reconnect
        // must be visible, so the "already reported" state has to be cleared
        // by an absence, not by time.
        let listing = Listing([proc(501, "screensharingd")])
        let watch = watch(names: { ["screensharingd"] }, listing: listing)

        #expect(watch.tick().count == 1)

        listing.procs = []
        #expect(watch.tick().isEmpty)

        listing.procs = [proc(777, "screensharingd")]
        let again = watch.tick()
        #expect(again.count == 1)
        #expect(again.first?.pid == 777)
    }

    @Test func testAbsenceOfOtherProcessesDoesNotResetTheEdge() {
        // Only the watched name's own absence clears its edge: other
        // processes churning around it must not make a steady actor re-fire.
        let listing = Listing([proc(501, "screensharingd")])
        let watch = watch(names: { ["screensharingd"] }, listing: listing)

        #expect(watch.tick().count == 1)
        listing.procs = [proc(501, "screensharingd"), proc(502, "Google Chrome")]
        #expect(watch.tick().isEmpty)
        listing.procs = [proc(501, "screensharingd")]
        #expect(watch.tick().isEmpty)
    }

    @Test func testSameNameAcrossTicksIsOnePresence() {
        // Identity is the process *name*: a same-named respawn between two
        // ticks is a continuation, not a new appearance. (Pid-set tracking
        // would instead re-fire whenever one of several same-named helper
        // processes exits — e.g. `remoting_host` instances — which is noise.)
        let listing = Listing([proc(501, "screensharingd")])
        let watch = watch(names: { ["screensharingd"] }, listing: listing)

        #expect(watch.tick().count == 1)
        listing.procs = [proc(999, "screensharingd")] // same name, new pid
        #expect(watch.tick().isEmpty)
    }

    // MARK: - Match rules

    @Test func testPathBestEffort() {
        // root-owned / other-user processes may yield a name-only `ProcInfo`
        // (spec §4-B): a nil path must still match on the name.
        let watch = watch(names: { ["AnyDesk"] }, listing: Listing([proc(700, "AnyDesk")]))

        let events = watch.tick()
        #expect(events.count == 1)
        #expect(events.first?.actor == "AnyDesk")
        #expect(events.first?.actorPath == nil)
    }

    @Test func testPathOnlyMatchEmitsProcessNameAsActor() {
        // A watchlist entry that only matches through the path (the default
        // list carries `RemoteManagement`) still reports the *process* name,
        // which is what the user sees in the evidence log.
        let info = proc(
            9,
            "ARDAgent",
            "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent"
        )
        let watch = watch(names: { ["RemoteManagement"] }, listing: Listing([info]))

        let events = watch.tick()
        #expect(events.count == 1)
        #expect(events.first?.actor == "ARDAgent")
        #expect(events.first?.actorPath == info.path)
    }

    @Test func testMatchIsCaseInsensitiveAndSubstring() {
        // Same rule as the Classifier, deliberately: a process this watch
        // flags must classify as REMOTE, not fall through to NORMAL because
        // the two matchers disagreed about case or about substrings.
        let listing = Listing([
            proc(11, "RustDesk"),
            proc(12, "TeamViewer_Service"),
            proc(13, "screensharingd_helper"),
        ])
        let watch = watch(names: { ["rustdesk", "teamviewer", "screensharingd"] }, listing: listing)

        #expect(watch.tick().map(\.actor) == ["RustDesk", "TeamViewer_Service", "screensharingd_helper"])
    }

    @Test func testEmptyPatternsAreIgnored() {
        // `contains("")` is vacuously true: an empty entry must never turn
        // every process on the machine into a REMOTE event.
        let listing = Listing([proc(1, "launchd"), proc(2, "sleep")])
        let watch = watch(names: { ["", "sleep"] }, listing: listing)

        #expect(watch.tick().map(\.actor) == ["sleep"])
    }

    @Test func testMultipleMatchesEmitEach() {
        // Two watched names present in one tick → two events, in listing
        // order, each carrying its own pid/path; the unmatched process is
        // ignored.
        let listing = Listing([
            proc(101, "screensharingd"),
            proc(102, "Google Chrome"),
            proc(103, "TeamViewer", "/Applications/TeamViewer.app/Contents/MacOS/TeamViewer"),
        ])
        let watch = watch(names: { ["screensharingd", "TeamViewer"] }, listing: listing)

        let events = watch.tick()
        #expect(events.count == 2)
        #expect(events.map(\.actor) == ["screensharingd", "TeamViewer"])
        #expect(events.map(\.pid) == [101, 103])
        #expect(events[0].actorPath == nil)
        #expect(events[1].actorPath == "/Applications/TeamViewer.app/Contents/MacOS/TeamViewer")
    }

    @Test func testDuplicateNameInOneTickEmitsOnce() {
        // Two live instances of the same name are one presence — one event,
        // pinned to the first instance the listing returned.
        let listing = Listing([proc(201, "remoting_host"), proc(202, "remoting_host")])
        let watch = watch(names: { ["remoting_host"] }, listing: listing)

        let events = watch.tick()
        #expect(events.count == 1)
        #expect(events.first?.pid == 201)
        #expect(watch.tick().isEmpty)
    }

    @Test func testWatchlistIsReadLivePerTick() {
        // T17's config reload swaps the watchlist without restarting the app:
        // the closure is consulted on every tick, and a name that leaves the
        // list stops being "present" (so it can fire again if it returns).
        let listing = Listing([proc(301, "screensharingd"), proc(302, "TeamViewer")])
        var watched = ["screensharingd"]
        let watch = watch(names: { watched }, listing: listing)

        #expect(watch.tick().map(\.actor) == ["screensharingd"])

        watched = ["TeamViewer"]
        #expect(watch.tick().map(\.actor) == ["TeamViewer"])

        watched = ["screensharingd"]
        #expect(watch.tick().map(\.actor) == ["screensharingd"])
    }

    // MARK: - Emitted event

    @Test func testEmittedEventIsARemoteControlProcessRawEvent() {
        // The full `RawEvent` shape is pinned literally: source, kind, actor,
        // path, pid — and the tick's timestamp from the injected clock.
        let info = proc(4242, "screensharingd", "/usr/libexec/screensharingd")
        let watch = watch(names: { ["screensharingd"] }, listing: Listing([info]))

        #expect(watch.tick() == [
            RawEvent(
                ts: Self.fixedNow,
                source: .processwatch,
                kind: .remoteControlProcess,
                actor: "screensharingd",
                actorPath: "/usr/libexec/screensharingd",
                pid: 4242
            ),
        ])
    }

    // MARK: - Real process table (smoke)

    @Test func testSmokeListsSelf() {
        // The only test that touches the real machine: `KERN_PROC_ALL` must
        // return a plausible table (a healthy macOS has hundreds of processes,
        // so 50 is a floor, not a measurement) and it must contain the pid
        // running this test — matched by pid, because the runner's process
        // name is a toolchain detail we do not want to pin.
        let procs = SystemProcesses.list()

        #expect(procs.count > 50)
        #expect(procs.contains { $0.pid == getpid() })
    }
}
