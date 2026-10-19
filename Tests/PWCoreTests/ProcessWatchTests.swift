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

    // MARK: - Memoised verdicts (perf fix)

    @Test func testVerdictCacheIsInvalidatedWhenANameChangesForTheSamePid() {
        // The cache is keyed by pid and validated against the name: a recycled
        // pid is a different process, and a name that now matches must fire
        // even though the same pid was seen (and did not match) last tick.
        let listing = Listing([proc(700, "Google Chrome")])
        let watch = watch(names: { ["TeamViewer"] }, listing: listing)

        #expect(watch.tick().isEmpty)

        listing.procs = [proc(700, "TeamViewer")] // same pid, new process
        #expect(watch.tick().map(\.actor) == ["TeamViewer"])
    }

    @Test func testVerdictCacheIsInvalidatedWhenAPathAppearsForTheSamePid() {
        // Same trap on the other half of the key: the verdict for a name-only
        // entry cannot answer for the same name once its path is readable.
        let info = proc(800, "helper")
        let listing = Listing([info])
        let watch = watch(names: { ["AnyDesk"] }, listing: listing)

        #expect(watch.tick().isEmpty)

        listing.procs = [proc(800, "helper", "/Applications/AnyDesk.app/Contents/MacOS/helper")]
        #expect(watch.tick().map(\.actor) == ["helper"])
    }

    @Test func testVerdictCacheIsDroppedWhenTheWatchlistChanges() {
        // A verdict computed for one watchlist must never answer for another:
        // narrowing the watchlist while a process stays put has to silence it,
        // and widening it has to catch what was already running.
        let listing = Listing([proc(900, "TeamViewer"), proc(901, "AnyDesk")])
        var watched = ["TeamViewer"]
        let watch = watch(names: { watched }, listing: listing)

        #expect(watch.tick().map(\.actor) == ["TeamViewer"])
        #expect(watch.tick().isEmpty)

        watched = ["AnyDesk"]
        #expect(watch.tick().map(\.actor) == ["AnyDesk"])

        watched = []
        #expect(watch.tick().isEmpty)

        watched = ["TeamViewer"]
        #expect(watch.tick().map(\.actor) == ["TeamViewer"])
    }

    // MARK: - Matching parity table

    @Test func testMatchingParityTable() {
        // The matching rule is shared with the Classifier (case-insensitive
        // substring over name and path), and this table pins it as such: each
        // row is one tick against a one-process table. The optimisation caches
        // this function's verdicts, so every row here must keep behaving
        // identically — including the rows that only match through the path and
        // the rows that must not match at all.
        let defaults = NoPeekConfig.defaultRemoteControl
        let cases: [(name: String, path: String?, watchlist: [String], matches: Bool)] = [
            // exact name (lowercase watchlist entry, kernel spelling verbatim)
            ("screensharingd", nil, defaults, true),
            // case variants, both directions
            ("Screensharingd", nil, ["screensharingd"], true),
            ("RustDesk", nil, ["rustdesk"], true),
            ("rustdesk", nil, ["RustDesk"], true),
            // substring hit on the name
            ("screensharingd_helper", nil, ["screensharingd"], true),
            ("TeamViewer_Service", nil, ["teamviewer"], true),
            // path-only hit: the actor name itself matches nothing
            (
                "ARDAgent",
                "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent",
                ["RemoteManagement"],
                true
            ),
            ("helper", "/Applications/AnyDesk.app/Contents/MacOS/helper", ["AnyDesk"], true),
            // needle longer than the (16-char-truncated) name: no substring can fit
            ("short", nil, ["much_longer_needle"], false),
            // the empty entry is ignored, not matched
            ("anything", nil, [""], false),
            // no hit on either field
            (
                "Google Chrome He",
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                defaults,
                false
            ),
            ("sleep", nil, defaults, false),
            (
                "mdworker_shared",
                "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework",
                defaults,
                false
            ),
        ]

        for testCase in cases {
            let watch = watch(
                names: { testCase.watchlist },
                listing: Listing([proc(1, testCase.name, testCase.path)])
            )
            let events = watch.tick()
            #expect(
                events.count == (testCase.matches ? 1 : 0),
                "\(testCase.name) [\(testCase.path ?? "no path")] vs \(testCase.watchlist) — expected \(testCase.matches ? "a match" : "no match")"
            )
        }
    }

    // MARK: - Budget

    @Test func testMatchingStaysUnderBudgetForAFullProcessTable() {
        // The idle-CPU acceptance (app + `log` child < 1 %) is dominated by
        // this poll: ~600 processes × the 12-entry watchlist, every 3 s. The
        // budget is 2 ms per *warm* tick — the steady state the acceptance
        // measures, where the memoised verdicts answer for every process that
        // has not changed. The cold first tick pays the full substring scan
        // once and must still be bounded (generous bound: it is a one-off).
        //
        // The fixture is pre-built and handed back unchanged, so the measured
        // window is matching + bookkeeping only; decoding the table from the
        // kernel (`SystemProcesses.list`, ~1 ms) lives outside this test.
        let (watch, watched, total) = Self.fullProcessTable()
        let clock = ContinuousClock()

        var firstEvents: [RawEvent] = []
        let cold = clock.measure { firstEvents = watch.tick() }
        #expect(firstEvents.count == watched, "the fixture's watched processes must all fire on the first tick")
        #expect(cold < .seconds(1), "cold matching pass took \(cold)")

        let iterations = 200
        var totalWarm = Duration.zero
        for _ in 0..<iterations {
            let tick = clock.measure { _ = watch.tick() }
            #expect(tick < .seconds(1))
            totalWarm += tick
        }
        let warm = totalWarm / iterations

        // Printed so the numbers land in the test log: `make test` shows them
        // next to the assertion.
        print("ProcessWatch budget: \(total) processes, \(watched) watched — cold \(cold), warm average \(warm)")

        #expect(
            warm < .milliseconds(2),
            "warm matching of \(total) processes took \(warm) per tick (budget 2 ms)"
        )
    }

    /// A synthetic table the size and shape of a real Mac's: ~600 processes
    /// with kernel-length names (≤ 16 chars, mixed case), most with paths, a
    /// few without, and every entry of the default watchlist present exactly
    /// once plus one path-only match.
    ///
    /// Returns the watch, how many processes must fire on the first tick, and
    /// the fixture size.
    private static func fullProcessTable() -> (ProcessWatch, Int, Int) {
        var procs: [ProcInfo] = []
        var pid: Int32 = 1000
        var watched = 0

        for needle in NoPeekConfig.defaultRemoteControl {
            // One live instance per watchlist entry (name spelled the way the
            // kernel would: the entry's own casing).
            procs.append(ProcInfo(pid: pid, name: needle, path: "/Applications/\(needle).app/Contents/MacOS/\(needle)"))
            pid += 1
            watched += 1
        }
        // One path-only match: the name is ordinary, only the path carries a
        // watchlist entry.
        procs.append(ProcInfo(
            pid: pid,
            name: "helper",
            path: "/Applications/ScreenConnect.app/Contents/MacOS/helper"
        ))
        pid += 1
        watched += 1

        // The rest: typical macOS churn that matches nothing, in the kernel's
        // 16-char-truncated shape, some without a path.
        let patterns = [
            "Google Chrome He", "mdworker_shared", "kernel_task", "WindowServer",
            "launchd", "python3", "bash", "node", "swift-frontend", "coreaudiod",
            "com.apple.WebKit", "diskarbitrationd", "notifyd", "cfprefsd",
        ]
        var index = 0
        while procs.count < 600 {
            let base = patterns[index % patterns.count]
            let name = "\(base)_\(index)".count <= 16 ? "\(base)_\(index)" : base
            if index % 7 == 0 {
                procs.append(ProcInfo(pid: pid, name: name)) // name-only: path refused
            } else {
                procs.append(ProcInfo(
                    pid: pid,
                    name: name,
                    path: "/System/Library/CoreServices/\(name)/Contents/MacOS/\(name)"
                ))
            }
            pid += 1
            index += 1
        }

        let listing = Listing(procs)
        let watch = ProcessWatch(
            names: { NoPeekConfig.defaultRemoteControl },
            lister: { listing.procs },
            now: { Self.fixedNow }
        )
        return (watch, watched, procs.count)
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
