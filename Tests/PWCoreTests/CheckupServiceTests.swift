import Foundation
import Testing

import PWCore

/// Tests for `CheckupService` and its live runner (plan T19, spec §6
/// `System Checkup…`, acceptance 11: "รัน → report ตรงกับความจริงบนเครื่อง").
///
/// Every behavioural test drives the service through the **injected runner**
/// (a fake `CommandRunner` keyed by the full command line) and an injected
/// process list, so no test depends on this machine's services or on a real
/// listener being open. The two exceptions are deliberate and named:
/// `testLiveRunnerCapturesOutput` runs one harmless `/bin/echo`, and
/// `testSmokeRunsOnThisMachine` runs the real probes to print the report that
/// the human E2E compares against System Settings.
@Suite struct CheckupServiceTests {

    // MARK: - Fixtures

    /// The clock the report is stamped with; fixed so `generatedAt` is pinned.
    private static let fixedNow = Date(timeIntervalSince1970: 1_762_000_000)

    /// Canned command output, keyed by the full command line
    /// (`"<launchPath> <args…>"`). A key that is absent means the command
    /// could not be run at all (`nil`), which is how the live runner reports a
    /// spawn failure.
    private struct FakeRunner: CommandRunner {
        var outputs: [String: String] = [:]

        func run(launchPath: String, args: [String]) -> String? {
            outputs[Self.key(launchPath, args)]
        }

        static func key(_ launchPath: String, _ args: [String]) -> String {
            ([launchPath] + args).joined(separator: " ")
        }
    }

    private static func key(_ launchPath: String, _ args: String...) -> String {
        FakeRunner.key(launchPath, args)
    }

    /// A `launchctl print-disabled system` body. The state spelling is the
    /// caller's business: macOS 26/27 writes `enabled`/`disabled`, the plan
    /// pinned the older database's `false`/`true`, and both are real.
    private static func printDisabled(_ entries: [(label: String, state: String)]) -> String {
        let rows = entries.map { "\t\t\"\($0.label)\" => \($0.state)" }.joined(separator: "\n")
        return "\tdisabled services = {\n\(rows)\n\t}\n"
    }

    /// `netstat -an -p tcp`'s refusal to name a service, as `launchctl print`
    /// prints it for a job that is not in the system domain.
    private static func notLoaded(_ label: String) -> String {
        "Bad request.\nCould not find service \"\(label)\" in domain for system"
    }

    /// Rows of `netstat -an -p tcp` with nothing reachable from another
    /// machine: an IPv6 listener and three IPv4 ones, all loopback (including
    /// loopback addresses outside 127.0.0.1, which are still this Mac only).
    private static let loopbackOnlyNetstat = """
    tcp4       0      0  127.0.0.1.5900         *.*                    LISTEN
    tcp6       0      0  ::1.9223               *.*                    LISTEN
    tcp4       0      0  127.0.2.3.53           *.*                    LISTEN
    tcp4       0      0  127.0.0.1.52914        192.168.1.10.51000     ESTABLISHED

    """

    /// Every probe of a quiet machine: Screen Sharing and ARD off (no override,
    /// service not loaded, no daemon), no org processes, no listeners.
    private static func quietOutputs() -> [String: String] {
        [
            key("/bin/launchctl", "print-disabled", "system"): printDisabled([]),
            key("/bin/launchctl", "print", "system/com.apple.screensharing"):
                notLoaded("com.apple.screensharing"),
            key("/bin/launchctl", "print", "system/com.apple.RemoteDesktop"):
                notLoaded("com.apple.RemoteDesktop"),
            key("/usr/bin/pgrep", "screensharingd"): "",
            key("/usr/bin/pgrep", "ARDAgent"): "",
            key("/usr/sbin/netstat", "-an", "-p", "tcp"): loopbackOnlyNetstat,
        ]
    }

    private func service(
        outputs: [String: String],
        orgPatterns: @escaping @Sendable () -> [String] = { [] },
        procs: [ProcInfo] = [],
        language: Language = .th
    ) -> CheckupService {
        CheckupService(
            runner: FakeRunner(outputs: outputs),
            orgPatterns: orgPatterns,
            processLister: { procs },
            language: { language },
            now: { Self.fixedNow }
        )
    }

    /// The four pinned check titles, in order.
    private static func itemTitles(_ language: Language = .th) -> [String] {
        [
            Strings.t("checkup.item.screensharing", language),
            Strings.t("checkup.item.remoteManagement", language),
            Strings.t("checkup.item.orgAgents", language),
            Strings.t("checkup.item.listeners", language),
        ]
    }

    // MARK: - The pinned tests

    @Test func testRunnerOutputsProduceExpectedItems() throws {
        // The plan's headline case: an injected runner's output drives every
        // item. Screen Sharing is explicitly disabled → `.ok`; a ManageEngine
        // agent is running → `.attention`; ARD is off and nothing is listening
        // → `.ok`. The four items keep the pinned check order, and the report
        // carries the run's own timestamp.
        var outputs = Self.quietOutputs()
        outputs[Self.key("/bin/launchctl", "print-disabled", "system")] =
            Self.printDisabled([(label: "com.apple.screensharing", state: "disabled")])

        let report = service(
            outputs: outputs,
            orgPatterns: { ["/Library/ManageEngine/"] },
            procs: [
                ProcInfo(pid: 1, name: "launchd", path: "/sbin/launchd"),
                ProcInfo(
                    pid: 846,
                    name: "dcagentservice",
                    path: "/Library/ManageEngine/UEMS_Agent/bin/dcagentservice"
                ),
            ]
        ).run()

        #expect(report.generatedAt == Self.fixedNow)
        #expect(report.items.map(\.title) == Self.itemTitles())
        #expect(report.items.map(\.severity) == [.ok, .ok, .attention, .ok])
        #expect(report.items[2].detail.contains("dcagentservice"))
        #expect(report.findingCount == 1)
    }

    @Test func testScreensharingEnabledYieldsWarn() throws {
        // print-disabled carries the older `false` spelling of "explicitly
        // enabled", and nobody is connected yet: the channel is open, which is
        // a `.warn` — not the `.attention` a live session gets. The ARD item
        // is untouched by the Screen Sharing override.
        var outputs = Self.quietOutputs()
        outputs[Self.key("/bin/launchctl", "print-disabled", "system")] =
            Self.printDisabled([(label: "com.apple.screensharing", state: "false")])

        let report = service(outputs: outputs).run()

        #expect(report.items[0].severity == .warn)
        #expect(report.items[1].severity == .ok)
    }

    @Test func testOrgProcessPresentYieldsAttention() throws {
        // Matched exactly the way `Classifier` and `ProcessWatch` match — a
        // case-insensitive substring of the process name *or* its path — so a
        // process this checkup names is one the pipeline would file as ORG.
        // Empty patterns never match, and the detail names what was found
        // without dragging in the processes that were not.
        let procs = [
            ProcInfo(pid: 1, name: "launchd", path: "/sbin/launchd"),
            ProcInfo(
                pid: 846,
                name: "dcagentservice",
                path: "/Library/ManageEngine/UEMS_Agent/bin/dcagentservice"
            ),
            ProcInfo(
                pid: 900,
                name: "ARDAgent",
                path: "/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/MacOS/ARDAgent"
            ),
        ]
        let report = service(
            outputs: Self.quietOutputs(),
            orgPatterns: { ["", "manageengine"] },
            procs: procs
        ).run()

        let item = report.items[2]
        #expect(item.severity == .attention)
        #expect(item.detail.contains("dcagentservice"))
        #expect(!item.detail.contains("ARDAgent"))
        #expect(!item.detail.contains("launchd"))
    }

    @Test func testListenerFilterExcludesLoopback() throws {
        // Only listeners another machine could reach count. `127.0.0.1` is the
        // pinned case; the rest of `127.0.0.0/8` (`127.0.2.3`), `::1`, and the
        // established connection's port are the same "this Mac talking to
        // itself" and must not appear either.
        var outputs = Self.quietOutputs()
        outputs[Self.key("/usr/sbin/netstat", "-an", "-p", "tcp")] = """
        tcp4       0      0  127.0.0.1.5900         *.*                    LISTEN
        tcp6       0      0  ::1.9223               *.*                    LISTEN
        tcp4       0      0  127.0.2.3.53           *.*                    LISTEN
        tcp4       0      0  *.6768                 *.*                    LISTEN
        tcp4       0      0  192.168.1.10.8787      *.*                    LISTEN
        tcp4       0      0  127.0.0.1.52914        192.168.1.10.51000     ESTABLISHED

        """

        let report = service(outputs: outputs).run()
        let item = report.items[3]
        #expect(item.severity == .warn)
        #expect(item.detail.contains("6768"))
        #expect(item.detail.contains("8787"))
        #expect(!item.detail.contains("5900"))
        #expect(!item.detail.contains("9223"))
        #expect(!item.detail.contains("53"))
        #expect(!item.detail.contains("52914"))
        #expect(!item.detail.contains("51000"))

        // A loopback-only listener on a sharing service's own port is not that
        // service: Screen Sharing's rfb socket is bound on every interface, so
        // the fixture's `127.0.0.1.5900` must leave the Screen Sharing item
        // quiet rather than warn about a channel nobody can reach.
        #expect(report.items[0].severity == .ok)
    }

    @Test func testReportHasSettingsLinks() throws {
        // The three items with a surface in System Settings carry the deep
        // links verified on this macOS 27 (the Sharing pane and the Screen &
        // System Audio Recording page); the listener item has no pane, so its
        // link is nil and its button will not exist.
        let report = service(outputs: Self.quietOutputs()).run()

        let sharing = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")
        let screenRecording = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )

        #expect(report.items[0].settingsURL == sharing)
        #expect(report.items[1].settingsURL == sharing)
        #expect(report.items[2].settingsURL == screenRecording)
        #expect(report.items[3].settingsURL == nil)
    }

    @Test func testBoundedListenerDetail() throws {
        // Eight open ports, listed newest-first by netstat. The detail shows
        // the six smallest ports in numeric order — deduplicated, so a port
        // listening on both tcp4 and tcp6 appears once — and says how many it
        // left out.
        var outputs = Self.quietOutputs()
        outputs[Self.key("/usr/sbin/netstat", "-an", "-p", "tcp")] = (1...8).reversed()
            .map { "tcp4       0      0  *.400\($0)                *.*                    LISTEN" }
            .joined(separator: "\n")

        let item = service(outputs: outputs).run().items[3]
        #expect(item.severity == .warn)
        #expect(item.detail.contains("4001"))
        #expect(item.detail.contains("4006"))
        #expect(!item.detail.contains("4007"))
        #expect(!item.detail.contains("4008"))
        #expect(item.detail.contains(String(format: Strings.t("checkup.list.more"), "2")))
    }

    // MARK: - Service state (checks 1–2)

    @Test func testActiveSharingDaemonYieldsAttention() throws {
        // A live `screensharingd` is somebody looking at this screen now: the
        // strongest answer the checkup can give, and it outranks a "disabled"
        // override — the process is the evidence. ARD is a different daemon,
        // whose pgrep result stays empty.
        var outputs = Self.quietOutputs()
        outputs[Self.key("/bin/launchctl", "print-disabled", "system")] =
            Self.printDisabled([(label: "com.apple.screensharing", state: "disabled")])
        outputs[Self.key("/usr/bin/pgrep", "screensharingd")] = "4242\n"

        let report = service(outputs: outputs).run()
        #expect(report.items[0].severity == .attention)
        #expect(report.items[0].detail.contains("4242"))
        #expect(report.items[1].severity == .ok)
    }

    @Test func testLoadedServiceWithoutAnOverrideYieldsWarn() throws {
        // macOS 26/27's resting state for a switched-off sharing service is
        // "not in the override database and not loaded": the plist's own
        // `Disabled` default keeps it out of `print-disabled`. So an override
        // that is absent means `launchctl print` decides — and a job launchd
        // has loaded is an open channel, `.warn`.
        var outputs = Self.quietOutputs()
        outputs[Self.key("/bin/launchctl", "print", "system/com.apple.screensharing")] =
            "system/com.apple.screensharing = {\n\tactive count = 1\n\tpath = /System/Library/LaunchDaemons/com.apple.screensharing.plist\n}"

        let report = service(outputs: outputs).run()
        #expect(report.items[0].severity == .warn)
        #expect(report.items[1].severity == .ok)
    }

    @Test func testServiceListeningOnItsPortYieldsWarn() throws {
        // The `enabled`/`disabled` spelling, plus independent evidence: the
        // port itself is open. Either signal is enough for `.warn`.
        var outputs = Self.quietOutputs()
        outputs[Self.key("/bin/launchctl", "print-disabled", "system")] =
            Self.printDisabled([(label: "com.apple.RemoteDesktop", state: "enabled")])
        outputs[Self.key("/usr/sbin/netstat", "-an", "-p", "tcp")] =
            "tcp4       0      0  *.3283                 *.*                    LISTEN"

        let report = service(outputs: outputs).run()
        #expect(report.items[0].severity == .ok)
        #expect(report.items[1].severity == .warn)
        #expect(report.items[1].detail.contains("3283"))
    }

    // MARK: - Quiet and degraded machines

    @Test func testQuietMachineReportsAllOk() throws {
        // Every probe answering "nothing here" is an all-`.ok` report with no
        // findings — and each item still explains itself.
        let report = service(outputs: Self.quietOutputs()).run()

        #expect(report.items.map(\.severity) == [.ok, .ok, .ok, .ok])
        #expect(report.findingCount == 0)
        #expect(report.items.allSatisfy { !$0.detail.isEmpty })
    }

    @Test func testFailedProbesDoNotInventFindings() throws {
        // A runner that cannot run anything (every command `nil`) must not
        // turn into alarms, and must not cost the report its shape: four items,
        // the three links still there.
        let report = service(outputs: [:]).run()

        #expect(report.items.count == 4)
        #expect(report.items.map(\.severity) == [.ok, .ok, .ok, .ok])
        #expect(report.items[0].settingsURL != nil)
        #expect(report.items[3].settingsURL == nil)
    }

    @Test func testCopyFollowsTheConfiguredLanguage() throws {
        // The severity is a fact about the machine, never a translation; the
        // copy around it follows the config. (The two sharing items keep their
        // English jargon in `th` by design, so the difference is pinned on the
        // items that are really translated.)
        let en = service(outputs: Self.quietOutputs(), language: .en).run()

        #expect(en.items.map(\.title) == Self.itemTitles(.en))
        #expect(en.items.map(\.severity) == [.ok, .ok, .ok, .ok])
        #expect(en.items[0].title == "Screen Sharing")
        #expect(en.items[0].title != Strings.t("checkup.item.screensharing", .th))
        #expect(en.items[2].title != Strings.t("checkup.item.orgAgents", .th))
        #expect(en.items[3].title != Strings.t("checkup.item.listeners", .th))
    }

    // MARK: - The live runner (only real I/O here)

    @Test func testLiveRunnerCapturesOutput() throws {
        // The one non-fake piece, and the only thing the tests cannot pin with
        // fixtures: `Process` really does hand back the child's output, and a
        // path that cannot be spawned degrades to `nil` instead of throwing.
        let runner = LiveCommandRunner()

        #expect(runner.run(launchPath: "/bin/echo", args: ["nopeek"]) == "nopeek\n")
        #expect(runner.run(launchPath: "/nonexistent/nopeek", args: ["checkup"]) == nil)
        #expect(runner.run(launchPath: "/usr/bin/pgrep", args: ["nopeek-no-such-process"]) == "")
    }

    // MARK: - Live smoke (the automated half of acceptance 11)

    @Test func testSmokeRunsOnThisMachine() throws {
        // The only test that runs the real probes — launchctl, pgrep, netstat
        // and the live process table, with the built-in org patterns. Shape
        // only: the severities are *this* machine's business (the human E2E
        // compares them against System Settings), and the printed report is
        // T19's automated acceptance evidence.
        let report = CheckupService(
            runner: LiveCommandRunner(),
            orgPatterns: { NoPeekConfig.default.effectiveOrgPatterns },
            processLister: SystemProcesses.list
        ).run()

        #expect(report.items.count == 4)
        #expect(report.items.map(\.title) == Self.itemTitles())
        #expect(report.items.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        #expect(report.items[0].settingsURL != nil)
        #expect(report.items[2].settingsURL != nil)
        #expect(report.items[3].settingsURL == nil)

        print("System Checkup — \(report.generatedAt)")
        for item in report.items {
            let link = item.settingsURL?.absoluteString ?? "—"
            print("[\(item.severity.rawValue)] \(item.title): \(item.detail) [\(link)]")
        }
    }
}
