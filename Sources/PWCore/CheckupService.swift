import Foundation

// MARK: - Severity

/// How much attention one checkup item deserves (plan T19).
///
/// - `.ok` — the channel is closed: nothing to see.
/// - `.warn` — the channel is open but idle: a sharing service is enabled or
///   listening, a port is reachable from the network. Worth knowing, nothing
///   happening right now.
/// - `.attention` — something is happening *now*, or an org / RMM agent is
///   running: a live `screensharingd`, a ManageEngine agent in the process
///   table.
public enum Severity: String, Codable, Equatable, Sendable {
    case ok
    case warn
    case attention
}

// MARK: - CheckupReport

/// One System Checkup run: when it was generated and what each check found
/// (plan T19, spec §6 `System Checkup…`, acceptance 11).
///
/// The report is a **snapshot by construction** — `generatedAt` is the run's
/// own timestamp, and the window draws it, so a report opened later cannot be
/// mistaken for live truth.
public struct CheckupReport: Equatable, Sendable {

    /// One check's finding.
    public struct Item: Equatable, Sendable {

        /// Localized check name (`Strings` key `checkup.item.*`), e.g.
        /// "แชร์หน้าจอ (Screen Sharing)".
        public let title: String

        /// How much attention the finding deserves; the window colors the row
        /// from this.
        public let severity: Severity

        /// The finding in one line — the state, and the evidence for it
        /// ("ปิดอยู่ — ไม่มี screensharingd …", "พบ 3 พอร์ต: 5900, 6768, …").
        public let detail: String

        /// The System Settings pane that inspects this channel, when one
        /// exists — the window's `เปิด System Settings` button. `nil` for an
        /// item with no such surface (the network listeners), which is why the
        /// button is drawn from this and not from an index.
        public let settingsURL: URL?

        public init(title: String, severity: Severity, detail: String, settingsURL: URL?) {
            self.title = title
            self.severity = severity
            self.detail = detail
            self.settingsURL = settingsURL
        }
    }

    /// The moment the run looked at the machine.
    public let generatedAt: Date

    /// The findings, in the pinned check order: Screen Sharing → Remote
    /// Management → org agents → network listeners.
    public let items: [Item]

    public init(generatedAt: Date, items: [Item]) {
        self.generatedAt = generatedAt
        self.items = items
    }

    /// How many items want the user's eye — the window's summary line.
    public var findingCount: Int {
        items.count { $0.severity != .ok }
    }
}

// MARK: - CommandRunner

/// Runs one short-lived command and returns what it printed (plan T19).
///
/// This is the checkup's only I/O seam: every probe — `launchctl`, `pgrep`,
/// `netstat` — goes through it, so the tests drive canned output and never
/// depend on this machine's services. `nil` means the command could not be run
/// at all; a command that ran and printed nothing returns `""` (which is the
/// quiet answer for `pgrep`, not an error).
public protocol CommandRunner: Sendable {
    func run(launchPath: String, args: [String]) -> String?
}

/// The production runner: `Process`, with stdout and stderr on one pipe.
///
/// All three probes print a handful of lines, so one combined pipe is enough
/// and the exit status is deliberately ignored — `pgrep` exits 1 when it
/// matches nothing, which is a normal finding, and the checkup reads state out
/// of the text either way.
public struct LiveCommandRunner: CommandRunner {

    public init() {}

    public func run(launchPath: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            // A path that is not there, or not executable: the probe is
            // unavailable, which the service reads as "nothing found".
            return nil
        }

        // Read to EOF *before* waiting: a child whose output outgrew the pipe
        // buffer would otherwise deadlock against this parent waiting for it to
        // exit. EOF arrives when the child exits and its end of the pipe closes.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - CheckupService

/// The System Checkup's four read-only probes (plan T19, spec §3/§6).
///
/// **What it answers.** "Which observation channels does this Mac have open?"
/// — in the pinned order:
///
/// | Check | Probe | `.ok` | `.warn` | `.attention` |
/// |---|---|---|---|---|
/// | Screen Sharing | `launchctl print-disabled system`, `launchctl print system/com.apple.screensharing`, `pgrep screensharingd`, port 5900 | nothing enabled, nothing listening | enabled / loaded / listening | a live `screensharingd` |
/// | Remote Management (ARD) | the same four for `com.apple.RemoteDesktop` / `ARDAgent` / port 3283 | as above | as above | a live `ARDAgent` |
/// | Org agents | the live process table vs `orgPatterns()` | no match | — | one or more matches |
/// | Listeners | `netstat -an -p tcp` | only loopback | any non-loopback port | — |
///
/// **Read-only, no TCC.** Every probe is a query: `launchctl` and `netstat`
/// need no privilege, `pgrep` sees the invoking user's processes, and the
/// process table is the `sysctl` listing `ProcessWatch` already uses. Nothing
/// here changes a service, kills a process, or asks for a permission — which is
/// the whole point of a checkup the user can run freely.
///
/// **Two databases, one answer.** `launchctl print-disabled system` lists only
/// services with an *explicit* override, and macOS 26/27 spells the state
/// `enabled`/`disabled` (the older database wrote `false`/`true`; both are
/// parsed). A sharing service switched off in System Settings is not in that
/// list at all — its plist's own `Disabled` default keeps it out, and launchd
/// simply does not load the job. So an absent override is answered by
/// `launchctl print system/<label>`: "Could not find service" is the off state,
/// a loaded job is an open channel. That second probe is what makes this
/// checkup agree with what System Settings shows on this OS.
///
/// **Failing probes are quiet, never alarming.** A probe that cannot run
/// (`nil`), or that prints nothing, reads as "nothing found" for that check —
/// a broken `netstat` must not invent open ports. The exception is evidence
/// found *alongside* a failure: a pid or a port that was really there is
/// reported as found.
///
/// **Threading.** `run()` is stateless — every probe and the process listing
/// happen inside the call — so the whole class is `Sendable` and the window may
/// run it off the main thread. The injected closures are read live, so a config
/// reload changes the next run and never a report already drawn.
public final class CheckupService: Sendable {

    // MARK: - The pinned services

    /// One sharing service as checks 1–2 see it.
    private struct RemoteService {
        /// The `Strings` key for the item's title.
        let titleKey: String
        /// The launchd job label.
        let label: String
        /// The daemon's process name, for `pgrep` and for the copy.
        let process: String
        /// The TCP ports that mean "this channel is listening".
        let ports: [String]
        /// The System Settings link that opens this service's own row.
        let settingsURL: URL?
    }

    /// Screen Sharing: `screensharingd` serves the rfb/VNC listener (5900).
    private static let screensharing = RemoteService(
        titleKey: "checkup.item.screensharing",
        label: "com.apple.screensharing",
        process: "screensharingd",
        ports: ["5900"],
        settingsURL: sharingSettingsURL("Services_ScreenSharing")
    )

    /// Remote Management / Apple Remote Desktop: `ARDAgent` serves ARD (3283).
    private static let remoteManagement = RemoteService(
        titleKey: "checkup.item.remoteManagement",
        label: "com.apple.RemoteDesktop",
        process: "ARDAgent",
        ports: ["3283"],
        settingsURL: sharingSettingsURL("Services_ARDService")
    )

    /// How many names or ports a detail line lists before it counts the rest
    /// (plan T19 bounds the listener detail; the same bound keeps an RMM-heavy
    /// process table readable).
    private static let listLimit = 6

    private static let launchctl = "/bin/launchctl"
    private static let pgrep = "/usr/bin/pgrep"
    private static let netstat = "/usr/sbin/netstat"

    /// The Sharing pane (General → Sharing on macOS 26/27), where Screen
    /// Sharing and Remote Management are switched, with the anchor that selects
    /// the service's own row: `?Services_ScreenSharing`, `?Services_ARDService`
    /// (the 26+ pane mapping; the base URL alone just lands on the pane).
    private static func sharingSettingsURL(_ anchor: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension?\(anchor)")
    }

    /// Privacy & Security → Screen & System Audio Recording, the list the
    /// org-agent item points at (spec §13: a deep link instead of reading that
    /// list, which needs Full Disk Access).
    ///
    /// Acceptance fix (macOS 26/27): the anchor is `Privacy_AudioCapture` — the
    /// pane renamed the page and the older `Privacy_ScreenCapture` anchor no
    /// longer resolves, so Settings opened at the Privacy & Security root.
    /// (`NSWorkspace.open` is the mechanism that still honours these links on
    /// 26+; the shell's `open` no longer navigates to the anchor.)
    private static let screenRecordingSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"
    )

    // MARK: - Dependencies

    private let runner: any CommandRunner
    private let orgPatterns: @Sendable () -> [String]
    private let processLister: @Sendable () -> [ProcInfo]
    private let language: @Sendable () -> Language
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - runner: the command seam (production: `LiveCommandRunner`).
    ///   - orgPatterns: the org / RMM patterns, read **per run** so a config
    ///     reload lands on the next checkup (production:
    ///     `config.effectiveOrgPatterns`).
    ///   - processLister: the process table (production:
    ///     `SystemProcesses.list`, the same listing `ProcessWatch` polls).
    ///   - language: the UI language for the item copy, read per run.
    ///   - now: the report's `generatedAt`; injected so tests pin it.
    public init(
        runner: any CommandRunner,
        orgPatterns: @escaping @Sendable () -> [String],
        processLister: @escaping @Sendable () -> [ProcInfo] = SystemProcesses.list,
        language: @escaping @Sendable () -> Language = { Strings.defaultLanguage },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.orgPatterns = orgPatterns
        self.processLister = processLister
        self.language = language
        self.now = now
    }

    // MARK: - Running the checkup

    /// Takes the snapshot: every check, in the pinned order, stamped with
    /// `now()`. Synchronous and side-effect free apart from spawning the three
    /// short-lived probes — the window calls it off the main thread.
    public func run() -> CheckupReport {
        let language = self.language()

        // Each probe is read once per run and shared by the checks that need
        // it: the override database and the listener table answer both service
        // checks and the listener check. The listener table is filtered to what
        // another machine could reach, so a loopback-only listener can neither
        // warn about a sharing service nor add a port to the listener item.
        let overrides = disabledOverrides()
        let listeners = tcpListeners().filter { !$0.isLoopback }

        return CheckupReport(
            generatedAt: now(),
            items: [
                serviceItem(Self.screensharing, overrides: overrides, listeners: listeners, language: language),
                serviceItem(Self.remoteManagement, overrides: overrides, listeners: listeners, language: language),
                orgAgentsItem(language: language),
                listenersItem(listeners, language: language),
            ]
        )
    }

    // MARK: - Checks 1–2: sharing services

    /// One sharing service's verdict.
    ///
    /// The order is the evidence order: a running daemon outranks everything
    /// (that is a session, not a possibility), an open port is next (something
    /// really is listening on the service's port, reachable from off this Mac),
    /// and only then an explicit/derived "enabled" — a service that could open
    /// a channel but has not yet.
    private func serviceItem(
        _ service: RemoteService,
        overrides: [String: Bool],
        listeners: [TCPListener],
        language: Language
    ) -> CheckupReport.Item {
        let pids = runningProcesses(service.process)
        let port = listeners.first { service.ports.contains($0.port) }?.port
        let isEnabled = serviceIsEnabled(service.label, overrides: overrides)

        let severity: Severity
        let detail: String
        if !pids.isEmpty {
            severity = .attention
            detail = String(
                format: Strings.t("checkup.detail.service.active", language),
                service.process,
                pids.joined(separator: ", ")
            )
        } else if let port {
            severity = .warn
            detail = String(format: Strings.t("checkup.detail.service.listening", language), port)
        } else if isEnabled {
            severity = .warn
            detail = Strings.t("checkup.detail.service.enabled", language)
        } else {
            severity = .ok
            detail = String(format: Strings.t("checkup.detail.service.off", language), service.process)
        }

        return CheckupReport.Item(
            title: Strings.t(service.titleKey, language),
            severity: severity,
            detail: detail,
            settingsURL: service.settingsURL
        )
    }

    /// Whether launchd would run `label`: an explicit "enabled" override counts
    /// even when the job is not loaded yet, an explicit "disabled" never does,
    /// and an absent override is decided by the job being loaded (see the class
    /// note on the two databases).
    private func serviceIsEnabled(_ label: String, overrides: [String: Bool]) -> Bool {
        switch overrides[label.lowercased()] {
        case .some(true): false
        case .some(false): true
        case nil: isLoaded(label)
        }
    }

    /// Whether launchd has the job loaded. `launchctl print` refuses with
    /// "Could not find service …" for a job that is not in the system domain —
    /// the off state — and prints a block starting `system/<label> = {` when it
    /// is loaded.
    private func isLoaded(_ label: String) -> Bool {
        guard let output = runner.run(launchPath: Self.launchctl, args: ["print", "system/\(label)"]),
              !output.isEmpty
        else { return false }
        return !output.contains("Could not find service")
    }

    /// `launchctl print-disabled system` → `label: isDisabled`, lowercased
    /// labels, for every service with an explicit override.
    ///
    /// Both spellings in the wild parse: `"com.apple.screensharing" => false`
    /// (the older launchd database, which the plan pinned) and
    /// `"com.apple.screensharing" => enabled` (macOS 26/27). Any other line —
    /// the `disabled services = {` header, another key's row — is ignored.
    private func disabledOverrides() -> [String: Bool] {
        guard let output = runner.run(
            launchPath: Self.launchctl,
            args: ["print-disabled", "system"]
        ) else { return [:] }
        return Self.parseDisabledOverrides(output)
    }

    private static func parseDisabledOverrides(_ output: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard row.hasPrefix("\""),
                  let closingQuote = row.dropFirst().firstIndex(of: "\""),
                  let arrow = row.range(of: "=>")
            else { continue }

            let label = row[row.index(after: row.startIndex)..<closingQuote].lowercased()
            let state = row[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            switch state {
            case "true", "disabled": overrides[label] = true
            case "false", "enabled": overrides[label] = false
            default: continue
            }
        }
        return overrides
    }

    /// The pids `pgrep` printed for `name`, or `[]` — including when `pgrep`
    /// itself could not run, which reads as "not running" rather than as an
    /// alarm (see the class note on failing probes).
    private func runningProcesses(_ name: String) -> [String] {
        guard let output = runner.run(launchPath: Self.pgrep, args: [name]) else { return [] }
        return output.split(whereSeparator: { $0 == "\n" || $0 == " " }).map(String.init)
    }

    // MARK: - Check 3: org agents

    /// What `orgPatterns()` matches in the live process table.
    ///
    /// Matching is the Classifier's rule verbatim — a case-insensitive
    /// substring of the process name or of its path, with empty entries
    /// ignored — so a process this checkup names is one the pipeline files as
    /// ORG. Only distinct names are listed: `remoting_host` spawning one helper
    /// per session is one agent to the reader.
    private func orgAgentsItem(language: Language) -> CheckupReport.Item {
        let patterns = orgPatterns().filter { !$0.isEmpty }
        var names: [String] = []
        var seen: Set<String> = []
        for proc in processLister() where Self.matches(proc, patterns: patterns) {
            guard seen.insert(proc.name).inserted else { continue }
            names.append(proc.name)
        }

        let severity: Severity = names.isEmpty ? .ok : .attention
        let detail = names.isEmpty
            ? Strings.t("checkup.detail.orgAgents.none", language)
            : String(
                format: Strings.t("checkup.detail.orgAgents.found", language),
                String(names.count),
                Self.boundedList(names, language: language)
            )

        return CheckupReport.Item(
            title: Strings.t("checkup.item.orgAgents", language),
            severity: severity,
            detail: detail,
            settingsURL: Self.screenRecordingSettingsURL
        )
    }

    /// The Classifier's match rule (spec §5), reused rather than reinvented: a
    /// case-insensitive substring test against the process name and, when
    /// present, its path.
    private static func matches(_ proc: ProcInfo, patterns: [String]) -> Bool {
        let name = proc.name.lowercased()
        let path = proc.path?.lowercased()
        return patterns.contains { pattern in
            let needle = pattern.lowercased()
            return name.contains(needle) || path?.contains(needle) == true
        }
    }

    // MARK: - Check 4: network listeners

    /// The ports another machine could connect to.
    private func listenersItem(_ listeners: [TCPListener], language: Language) -> CheckupReport.Item {
        let ports = Self.openPorts(listeners)

        let severity: Severity = ports.isEmpty ? .ok : .warn
        let detail = ports.isEmpty
            ? Strings.t("checkup.detail.listeners.none", language)
            : String(
                format: Strings.t("checkup.detail.listeners.found", language),
                String(ports.count),
                Self.boundedList(ports, language: language)
            )

        return CheckupReport.Item(
            title: Strings.t("checkup.item.listeners", language),
            severity: severity,
            detail: detail,
            settingsURL: nil  // no System Settings pane lists TCP listeners
        )
    }

    // MARK: - netstat

    /// One TCP listener as `netstat -an -p tcp` reports it.
    private struct TCPListener: Equatable {
        /// The host part of the local address: `127.0.0.1`, `*`, `::1`, …
        let address: String
        /// The port, already a string: netstat prints it that way and the
        /// detail line wants it verbatim.
        let port: String

        /// Whether only this Mac can reach it. `127.0.0.0/8` is the whole IPv4
        /// loopback block (the plan pinned `127.0.0.1`; `127.0.2.3` is the same
        /// thing), `::1` the IPv6 one, `localhost` how netstat spells the name
        /// when it cannot resolve numerically, and a `%lo0` scope is the
        /// loopback interface. A loopback listener is not an open door, and on
        /// a sharing service's own port it is something other than that service
        /// — Screen Sharing's rfb socket is bound on every interface.
        var isLoopback: Bool {
            let host = address.lowercased()
            return host == "::1"
                || host == "localhost"
                || host.hasPrefix("127.")
                || host.hasSuffix("%lo0")
        }
    }

    /// The TCP table, read once per run.
    private func tcpListeners() -> [TCPListener] {
        guard let output = runner.run(
            launchPath: Self.netstat,
            args: ["-an", "-p", "tcp"]
        ) else { return [] }
        return Self.parseListeners(output)
    }

    /// `netstat -an -p tcp`'s LISTEN rows.
    ///
    /// Columns are `Proto Recv-Q Send-Q Local-Address Foreign-Address State`;
    /// the state is the last field. Rows in any other state are skipped —
    /// established connections are the everyday case (every page load opens
    /// several) and are not an open door.
    private static func parseListeners(_ output: String) -> [TCPListener] {
        var listeners: [TCPListener] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 5, fields[0].hasPrefix("tcp") else { continue }
            guard fields[fields.count - 1].uppercased() == "LISTEN" else { continue }

            let local = String(fields[3])
            guard let separator = local.lastIndex(of: ".") else { continue }
            listeners.append(
                TCPListener(
                    address: String(local[..<separator]),
                    port: String(local[local.index(after: separator)...])
                )
            )
        }
        return listeners
    }

    /// The distinct ports of `listeners` — expected to be the reachable ones
    /// (`run()` has already dropped loopback) — smallest first: a port listening
    /// on both tcp4 and tcp6 is one open port, and the detail reads
    /// `5900, 6768, …` rather than netstat's row order.
    private static func openPorts(_ listeners: [TCPListener]) -> [String] {
        var seen: Set<String> = []
        var ports: [String] = []
        for listener in listeners {
            guard seen.insert(listener.port).inserted else { continue }
            ports.append(listener.port)
        }
        return ports.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    // MARK: - Copy helpers

    /// At most `listLimit` entries, joined with ", ", plus a tail saying how
    /// many were left out — the pinned bound on the listener detail line, and
    /// what keeps a busy machine's report a report rather than a dump.
    private static func boundedList(_ entries: [String], language: Language) -> String {
        let shown = entries.prefix(listLimit)
        var text = shown.joined(separator: ", ")
        if entries.count > shown.count {
            text += " " + String(
                format: Strings.t("checkup.list.more", language),
                String(entries.count - shown.count)
            )
        }
        return text
    }
}
