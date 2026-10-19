import Darwin
import Foundation

// MARK: - KillTarget

/// The identity of the process a kill would hit (spec §6d): the actor an event
/// named, its executable path when the watcher captured one, and its pid.
///
/// Carried by the tray row actions and the notification actions, and handed to
/// `KillController` — which re-checks the **name** against the pid before it
/// signals anything, because this struct is a snapshot and the pid may already
/// belong to somebody else.
public struct KillTarget: Equatable, Sendable {

    /// What the evidence log calls the actor (the kernel's short process name).
    public var actor: String

    /// The executable path, when there was one (spec §4-B: often there is not).
    public var actorPath: String?

    /// The pid as captured. Without one there is nothing to kill — the row
    /// simply offers no `Kill` action.
    public var pid: Int32?

    public init(actor: String, actorPath: String? = nil, pid: Int32? = nil) {
        self.actor = actor
        self.actorPath = actorPath
        self.pid = pid
    }

    /// The target an event names.
    public init(_ event: ClassifiedEvent) {
        self.init(
            actor: event.event.actor,
            actorPath: event.event.actorPath,
            pid: event.event.pid
        )
    }

    /// Whether a kill may be offered for this target at all: there has to be a
    /// pid, and it must not be this very process — NoPeek never kills itself
    /// (T21 global constraint; the app's flows re-check it, and this is what
    /// keeps the row from offering what the flow would refuse).
    public var isKillable: Bool {
        guard let pid, pid > 0 else { return false }
        return pid != getpid()
    }
}

// MARK: - Row action availability (spec §6 / §6d)

extension ClassifiedEvent {

    /// Whether the tray / History row for this event may offer `Kill`
    /// (spec §6: the REMOTE and ORG rows carry it) and the target is killable.
    public var offersKillAction: Bool {
        guard tier == .remote || tier == .org else { return false }
        return KillTarget(self).isKillable
    }

    /// Whether the row may offer `เปิดตำแหน่ง` (spec §6d: any row with a path).
    /// A pid alone is enough — `ProcessLocation` resolves it through
    /// `proc_pidpath` — but a row with neither has nothing to reveal.
    public var offersLocationAction: Bool {
        if let path = event.actorPath, !path.isEmpty { return true }
        guard let pid = event.pid else { return false }
        return pid > 0
    }
}

// MARK: - KillOutcome

/// What happened to one kill attempt (spec §6d, plan T21).
///
/// Every case is recorded in the evidence log as a `process-kill` line, so the
/// enum is deliberately total over "what the user needs to know later": which
/// signal actually stopped the process, whether the escalation was needed,
/// whether the pid-reuse guard refused, whether it was a permissions problem
/// (EPERM), whether the process was already gone, or whether the syscall failed
/// for some other reason.
public enum KillOutcome: Equatable, Sendable {
    /// The signal was delivered and the process is gone: `SIGTERM` for the
    /// ordinary path, `SIGKILL` when `force` was asked for.
    case terminated(signal: Int32)
    /// `SIGTERM` was delivered, the process survived the wait, and `SIGKILL`
    /// finished the job.
    case escalated
    /// The pid no longer belongs to `expectedName` — nothing was signalled.
    case refusedNameMismatch
    /// `EPERM`: the process belongs to someone else (root). Manual kills may
    /// offer the macOS admin prompt; auto-kill never does.
    case noPermission
    /// `ESRCH`: there is no such process (any more).
    case noSuchProcess
    /// Any other `kill(2)` failure, with its `errno`.
    case failed(errno: Int32)
}

/// Who asked for the kill. Decides the evidence summary's wording (`manual:` /
/// `auto-kill:`) and whether a failure may offer the admin prompt.
public enum KillInitiator: String, Equatable, Sendable {
    /// The confirm dialog — the tray row, the History window, a notification
    /// action.
    case manual = "manual"
    /// The auto-kill engine (spec §6d opt-in).
    case auto = "auto-kill"
}

// MARK: - KillController

/// Signals one process, with the pid-reuse guard and the TERM→wait→KILL
/// escalation (spec §6d, plan T21 — Review Focus #6).
///
/// **The guard is the whole point.** A pid is not an identity: between the
/// moment a watcher captured `(actor, pid)` and the moment the user presses
/// `Kill`, the process can die and its pid be recycled. Every signal this type
/// sends is therefore preceded by `processName(pid) == expectedName` — both
/// before the `SIGTERM` and again before the escalated `SIGKILL`, which happens
/// up to three seconds later. A mismatch returns `.refusedNameMismatch` and
/// **no signal is sent at all** (not even a signal-0 probe, which is itself a
/// permission question). The guard compares the kernel's short process name
/// against the event's actor, which is the same field `ProcessWatch` read — so
/// the comparison is like with like.
///
/// **The escalation** (spec §6d): `force == false` sends `SIGTERM` and waits up
/// to `termWait` seconds, polling aliveness with `kill(pid, 0)`; a survivor
/// gets `SIGKILL` and reports `.escalated`. `force == true` sends `SIGKILL`
/// directly — no wait. `EPERM`/`ESRCH`/other failures map to
/// `.noPermission`/`.noSuchProcess`/`.failed(errno:)` on the spot: waiting for a
/// process we may not signal would only delay the answer.
///
/// **Never your own pid.** `kill(0, …)` and `kill(-1, …)` are not processes at
/// all — they are "my process group" / "everything I can signal" — and this
/// type refuses any non-positive pid with `.failed(errno: EINVAL)` before it
/// does anything else. NoPeek's own pid is guarded one layer up, in
/// `AppController`, because that is where "not NoPeek itself" can also *tell*
/// the user why; the controller here is a mechanism with no UI opinion.
///
/// **Threading.** Values in, values out: no mutable state, so callers may run
/// one from any queue. `Thread.sleep` in the wait loop blocks that queue for up
/// to `termWait` — the app runs kills off its pipeline's queue for exactly that
/// reason.
public struct KillController: @unchecked Sendable {

    /// How long a `SIGTERM` gets before the `SIGKILL` (spec §6d: 3 s).
    public static let termWait: TimeInterval = 3

    /// Aliveness poll interval during that wait. Binary-exact (⅛ s), which
    /// makes the 3 s budget exactly 24 polls — pinned by a test.
    public static let pollInterval: TimeInterval = 0.125

    /// `kill(2)`-shaped signal delivery, injected so no test ever signals a
    /// process. Must set `errno` when it returns −1, exactly like `kill(2)`.
    private let signaller: (Int32, Int32) -> Int32

    /// pid → kernel short name, injected for the pid-reuse guard. Production is
    /// `systemName`.
    private let processName: (Int32) -> String?

    /// The wait, injected so the 3 s escalation is asserted instead of
    /// experienced. Production is `Thread.sleep`.
    private let sleeper: (TimeInterval) -> Void

    /// Source of "now" for the wait's deadline, injected with the sleeper.
    private let now: () -> Date

    public init(
        signaller: @escaping (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
        processName: @escaping (Int32) -> String? = KillController.systemName,
        sleeper: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.signaller = signaller
        self.processName = processName
        self.sleeper = sleeper
        self.now = now
    }

    // MARK: - Killing

    /// One attempt against `pid`, which must still be named `expectedName`.
    public func kill(pid: Int32, expectedName: String, force: Bool) -> KillOutcome {
        // A non-positive pid is not a process: `kill(0, …)` targets this
        // process's whole group and `kill(-1, …)` everything this user may
        // signal. Refused before the guard or any signal.
        guard pid > 0 else { return .failed(errno: EINVAL) }

        if let refusal = guardOutcome(pid: pid, expectedName: expectedName) { return refusal }

        if force {
            if let failure = signal(SIGKILL, to: pid) { return failure }
            return .terminated(signal: SIGKILL)
        }

        if let failure = signal(SIGTERM, to: pid) { return failure }

        let deadline = now().addingTimeInterval(Self.termWait)
        while now() < deadline {
            sleeper(Self.pollInterval)
            if !isAlive(pid) { return .terminated(signal: SIGTERM) }
        }

        // The pid may have been recycled while we waited: the guard runs again
        // before the second signal.
        if let refusal = guardOutcome(pid: pid, expectedName: expectedName) { return refusal }

        if let failure = signal(SIGKILL, to: pid) { return failure }
        return .escalated
    }

    /// Sends one signal and translates the failure, or `nil` when it was
    /// delivered.
    private func signal(_ signal: Int32, to pid: Int32) -> KillOutcome? {
        guard signaller(pid, signal) != 0 else { return nil }
        // Read immediately: nothing may run between the call and this read
        // without the chance of clobbering `errno`.
        let code = errno
        switch code {
        case EPERM: return .noPermission
        case ESRCH: return .noSuchProcess
        default: return .failed(errno: code)
        }
    }

    /// `kill(pid, 0)`: 0 is alive, `ESRCH` is gone, and anything else (`EPERM`
    /// for another user's process) means "still there, not ours" — which is
    /// alive, not dead.
    private func isAlive(_ pid: Int32) -> Bool {
        if signaller(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    /// The pid-reuse guard: `nil` when the pid may be signalled, else the
    /// outcome that explains the refusal.
    ///
    /// A pid with no name has no process behind it (`systemName` reads the
    /// kernel's own name and answers for every live process, root's included),
    /// so that is `.noSuchProcess`; a name that differs is `.refusedNameMismatch`
    /// and the pid is left strictly alone.
    private func guardOutcome(pid: Int32, expectedName: String) -> KillOutcome? {
        guard let actual = processName(pid) else { return .noSuchProcess }
        return actual == expectedName ? nil : .refusedNameMismatch
    }

    // MARK: - Real kernel reads

    /// The kernel's short process name for `pid` — `kinfo_proc.kp_proc.p_comm`,
    /// the same field `ProcessWatch` reports as an event's actor (truncated by
    /// the kernel to `MAXCOMLEN`, 16 characters).
    ///
    /// Read through `sysctl(KERN_PROC_PID)`, which answers for *any* pid
    /// including root's — unlike `proc_name`, which returns nothing for another
    /// user's process. That is what lets `launchd` (pid 1) pass the guard and
    /// reach the EPERM path (acceptance 16) instead of being mistaken for a
    /// dead pid. A pid that does not exist reads as `nil`.
    public static func systemName(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }

    /// The display name of a signal: `SIGTERM` / `SIGKILL`, or `signal N` for
    /// anything else (this app only ever sends the first two).
    public static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        default: "signal \(signal)"
        }
    }
}

// MARK: - AutoKillDecision

/// The auto-kill engine's answer for one appearance of one process name
/// (spec §6d, plan T21).
public enum AutoKillDecision: Equatable, Sendable {
    /// Under quota: the caller may kill, and has just spent one slot.
    case kill
    /// Nothing to decide: no usable name, or the quota is switched off.
    case skip
    /// The name has used its whole quota inside the rolling hour: do not kill
    /// again until the window slides.
    case halted
}

// MARK: - AutoKillEngine

/// The loop guard (spec §6d): a rolling, per-name kill quota.
///
/// A process that something respawns (launchd, an org agent's watchdog, a
/// self-restarting helper) would otherwise be killed every 3 s forever, and
/// that fight helps nobody. `maxPerHour` kills per **name** inside the rolling
/// hour are allowed; the next appearance is `.halted`, and stays halted until
/// the oldest kill ages out — then the name is killable again. Names are
/// completely independent: a halted `dwagent` never holds back a fresh
/// `rustdesk`.
///
/// Two reads support the app's one-notification policy: `takeHaltNotice(actor:)`
/// answers `true` exactly once per halted *episode*, so a 3 s poll cannot turn
/// the guard into a notification storm, and `killCount(actor:)` supplies the
/// "killed N times this hour" figure the notification shows.
///
/// **Threading.** Mutable state across calls, deliberately not thread-safe:
/// one owner drives it (in the app, the reader's serial callback queue, where
/// the auto-kill hook runs).
public final class AutoKillEngine {

    /// The rolling window: one hour (spec §6d "ต่อชั่วโมง").
    public static let window: TimeInterval = 60 * 60

    /// The configured quota (`autoKillMaxPerHour`, spec §7 default 5).
    public let maxPerHour: Int

    private let now: () -> Date

    /// Per-name kill timestamps, pruned to the window on every read.
    private var kills: [String: [Date]] = [:]

    /// Names currently in a halted episode — the transition into this set is
    /// what arms a notice, so a repeated `.halted` does not re-arm one.
    private var haltedNames: Set<String> = []

    /// Halted episodes whose notification has not been taken yet.
    private var pendingNotices: Set<String> = []

    public init(maxPerHour: Int = 5, now: @escaping () -> Date = Date.init) {
        self.maxPerHour = maxPerHour
        self.now = now
    }

    // MARK: - Decisions

    /// One appearance of `actor`: may it be killed?
    ///
    /// A `.kill` answer **records the kill** — the guard counts attempts, not
    /// successes, because an attempt means something brought the process back,
    /// which is exactly the loop the guard exists to stop.
    public func evaluate(actor: String) -> AutoKillDecision {
        let name = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxPerHour > 0, !name.isEmpty else { return .skip }

        let recent = recentKills(name, at: now())
        guard recent.count < maxPerHour else {
            if haltedNames.insert(name).inserted {
                pendingNotices.insert(name)
            }
            return .halted
        }

        // A fresh kill is allowed: the episode is over (or never started).
        haltedNames.remove(name)
        pendingNotices.remove(name)
        kills[name] = recent + [now()]
        return .kill
    }

    /// How many kills of `actor` are inside the current rolling hour — the
    /// figure the guard's notification shows.
    public func killCount(actor: String) -> Int {
        recentKills(normalized(actor), at: now()).count
    }

    /// `true` the first time it is asked inside a halted episode; `false` on
    /// every later ask (and `false` for a name that is not halted). Taking a
    /// notice is what makes the next `.halted` silent, until the window slides
    /// and a new episode begins.
    public func takeHaltNotice(actor: String) -> Bool {
        let name = normalized(actor)
        guard !name.isEmpty, haltedNames.contains(name) else { return false }
        return pendingNotices.remove(name) != nil
    }

    // MARK: - Internals

    /// Kills inside `window` before `date`. The window is half-open: a kill
    /// exactly one hour old has aged out.
    private func recentKills(_ name: String, at date: Date) -> [Date] {
        guard !name.isEmpty else { return [] }
        let cutoff = date.addingTimeInterval(-Self.window)
        return (kills[name] ?? []).filter { $0 > cutoff }
    }

    private func normalized(_ actor: String) -> String {
        actor.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - KillCopy

/// The copy around a kill (spec §6d, §8, §10): one source for the user-facing
/// status line and the evidence line, so the two can never drift apart.
///
/// The two are deliberately different languages of the same fact:
/// - `outcomeLine` / `adminResultLine` are **user-facing** and localized th/en
///   through `Strings` (spec §10);
/// - `logSummary` is the **evidence `rawSummary`** — one English line in the
///   spec §8 spirit (`manual: SIGTERM delivered to sleep (pid 4242)`), because
///   the log is the artefact an admin greps.
public enum KillCopy {

    // MARK: - Evidence (rawSummary)

    /// One line describing the outcome, tagged with who asked for it.
    public static func logSummary(
        _ outcome: KillOutcome,
        name: String,
        pid: Int32,
        initiator: KillInitiator
    ) -> String {
        let prefix = initiator.rawValue
        switch outcome {
        case .terminated(let signal):
            return "\(prefix): \(KillController.signalName(signal)) delivered to \(name) (pid \(pid))"
        case .escalated:
            return "\(prefix): SIGTERM did not stop \(name) (pid \(pid)) — SIGKILL escalated"
        case .refusedNameMismatch:
            return "\(prefix): pid-reuse guard refused \(pid) for \(name) — no signal sent"
        case .noPermission:
            let tail = initiator == .manual ? "needs admin" : "no admin path (v1)"
            return "\(prefix): EPERM on \(name) (pid \(pid)) — \(tail)"
        case .noSuchProcess:
            return "\(prefix): \(name) (pid \(pid)) is already gone"
        case .failed(let code):
            return "\(prefix): kill \(name) (pid \(pid)) failed (errno \(code))"
        }
    }

    /// The admin prompt's second line: what the elevation did (spec §6d: even
    /// a cancelled prompt is recorded).
    public static func adminLogSummary(success: Bool, name: String, pid: Int32, signal: Int32) -> String {
        if success {
            return "manual: admin elevation authorized — "
                + "\(KillController.signalName(signal)) delivered to \(name) (pid \(pid))"
        }
        return "manual: admin elevation cancelled or failed — \(name) (pid \(pid)) not killed"
    }

    /// The loop guard's line: the name's hour is full, so nothing more will be
    /// killed until the window slides (spec §6d).
    public static func haltLogSummary(name: String, count: Int) -> String {
        "auto-kill loop guard halted \(name) at \(count)/hour — no kill"
    }

    // MARK: - Status lines (user-facing)

    /// The menu's status-line confirmation for a manual attempt (spec §6d,
    /// T17's `showConfirmation` pattern).
    public static func outcomeLine(_ outcome: KillOutcome, name: String, language: Language) -> String {
        switch outcome {
        case .terminated(let signal):
            return String(
                format: Strings.t("kill.done.terminated", language),
                KillController.signalName(signal),
                name
            )
        case .escalated:
            return String(format: Strings.t("kill.done.escalated", language), name)
        case .refusedNameMismatch:
            return String(format: Strings.t("kill.done.refused", language), name)
        case .noPermission:
            return String(format: Strings.t("kill.done.noPermission", language), name)
        case .noSuchProcess:
            return String(format: Strings.t("kill.done.noSuchProcess", language), name)
        case .failed(let code):
            return String(format: Strings.t("kill.done.failed", language), name, String(code))
        }
    }

    /// The line for "the user closed the admin prompt" (spec §6d: cancel is a
    /// legitimate outcome, and it is not a failure of anything).
    public static func adminCancelledLine(language: Language) -> String {
        Strings.t("kill.admin.cancelled", language)
    }

    /// The line for the admin attempt's result.
    public static func adminResultLine(success: Bool, name: String, language: Language) -> String {
        let key = success ? "kill.admin.done" : "kill.admin.failed"
        return String(format: Strings.t(key, language), name)
    }

    // MARK: - Auto-kill notifications

    /// The notification an auto-kill attempt deserves, or `nil` for the
    /// outcomes that are logged silently: a refusal or a miss is not worth a
    /// banner, and a respawn loop must never become a notification loop.
    public static func autoKillNotification(
        _ outcome: KillOutcome,
        name: String,
        pid: Int32,
        language: Language
    ) -> NotificationCopy? {
        switch outcome {
        case .terminated(let signal):
            return NotificationCopy(
                title: String(format: Strings.t("notif.autokill.killed.title", language), name),
                body: String(
                    format: Strings.t("notif.autokill.killed.body", language),
                    KillController.signalName(signal),
                    String(pid)
                )
            )
        case .escalated:
            return NotificationCopy(
                title: String(format: Strings.t("notif.autokill.killed.title", language), name),
                body: String(
                    format: Strings.t("notif.autokill.escalated.body", language),
                    String(pid)
                )
            )
        case .noPermission:
            // The pinned notice: "kill ไม่ได้ (ต้องสิทธิ์)" — auto-kill never
            // raises the admin prompt (spec §6d).
            return NotificationCopy(
                title: Strings.t("notif.autokill.denied.title", language),
                body: String(
                    format: Strings.t("notif.autokill.denied.body", language),
                    name,
                    String(pid)
                )
            )
        case .refusedNameMismatch, .noSuchProcess, .failed:
            return nil
        }
    }

    /// The one notification a halted loop guard produces (spec §6d).
    public static func haltNotification(name: String, count: Int, language: Language) -> NotificationCopy {
        NotificationCopy(
            title: Strings.t("notif.autokill.halted.title", language),
            body: String(
                format: Strings.t("notif.autokill.halted.body", language),
                name,
                String(count)
            )
        )
    }
}
